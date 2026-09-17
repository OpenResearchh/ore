import Foundation
import OreProtocol
import OreSupport

/// Creates and removes the isolated worktrees each workspace runs in.
///
/// Worktrees live **outside** the repository, under `~/ore/workspaces/<repo>/<slug>`.
/// Putting them inside the repo is the obvious thing to do and is wrong in three
/// ways at once: they show up in the parent's file watchers and search, `.gitignore`
/// has to be taught about them, and every tool that walks the tree sees N copies
/// of the project. Keeping them outside removes the whole class of problem.
public actor WorktreeManager {
    private let git: GitClient
    private let root: URL
    private let fileManager = FileManager.default

    public init(git: GitClient, root: URL? = nil) {
        self.git = git
        self.root = root ?? WorktreeManager.defaultRoot
    }

    /// `~/ore/workspaces`, or `$ORE_HOME/workspaces`.
    public static var defaultRoot: URL {
        let home = ProcessInfo.processInfo.environment["ORE_HOME"].flatMap { override -> URL? in
            override.isEmpty
                ? nil
                : FilePath.expandingTildeURL(override)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ore", isDirectory: true)
        return home.appendingPathComponent("workspaces", isDirectory: true)
    }

    // MARK: - Creating

    public struct CreateRequest: Sendable {
        public var name: String
        public var branchPrefix: String
        /// The commit-ish the new branch starts at.
        public var baseRevision: String
        /// The branch a PR from this workspace will target. Usually the same as
        /// the base revision; different when stacking on another workspace.
        public var baseBranch: String
        /// Gitignored files to copy in from the main checkout — `.env` and
        /// friends. Without this a fresh worktree can't build, which is the
        /// single most common worktree papercut.
        public var filesToCopy: [String]

        public init(
            name: String,
            branchPrefix: String = "ore",
            baseRevision: String,
            baseBranch: String,
            filesToCopy: [String] = []
        ) {
            self.name = name
            self.branchPrefix = branchPrefix
            self.baseRevision = baseRevision
            self.baseBranch = baseBranch
            self.filesToCopy = filesToCopy
        }
    }

    public struct Worktree: Sendable, Hashable {
        public var path: URL
        public var branch: String
        public var baseBranch: String
        /// Files that were requested but weren't present in the source checkout.
        /// Surfaced rather than swallowed: a missing `.env` shows up as a
        /// mysterious build failure ten minutes later otherwise.
        public var missingCopies: [String]
    }

    public func create(_ request: CreateRequest) async throws -> Worktree {
        let slug = Slug.make(request.name)
        let repositoryName = await repositorySlug()

        let directory = root
            .appendingPathComponent(repositoryName, isDirectory: true)
        let path = try uniquePath(in: directory, preferredSlug: slug)
        let branch = try await uniqueBranch(prefix: request.branchPrefix, slug: path.lastPathComponent)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Clears registrations whose directory is gone.
        //
        // git records every worktree under `.git/worktrees/<name>`, and
        // deleting the directory in Finder — or losing it with an external
        // drive, or a `rm -rf` in a terminal — leaves the record behind. The
        // next `worktree add` at that slug then fails with "already exists",
        // naming a path the user can see is not there. `uniquePath` cannot
        // help: it checks the filesystem, which agrees the path is free.
        //
        // Best-effort on purpose: prune failing is not a reason to refuse to
        // make a worktree, and the `add` below reports anything that matters.
        try? await git.runSerialized(["worktree", "prune"])

        // `baseRevision` can come from a pull request's head branch or from the
        // assistant; ending option parsing keeps a name that starts with a
        // dash from being read as a flag.
        try await git.runSerialized([
            "worktree", "add",
            "-b", branch,
            "--end-of-options",
            path.path,
            request.baseRevision,
        ])

        let missing = await copyFiles(request.filesToCopy, into: path)
        try await createContextDirectory(in: path)

        return Worktree(
            path: path,
            branch: branch,
            baseBranch: request.baseBranch,
            missingCopies: missing
        )
    }

    /// Copies gitignored files the project needs but git won't carry.
    ///
    /// The list comes from the repository's own `ore.toml`, so each entry is
    /// untrusted: it has to name something inside the checkout and land inside
    /// the worktree. Anything that could leave either is reported as missing
    /// instead of followed — the destination is deleted before the copy, and
    /// outside the worktree that would be a real folder like `~/.ssh`.
    private func copyFiles(_ relativePaths: [String], into worktree: URL) async -> [String] {
        var missing: [String] = []
        let source = await git.repositoryURL

        for relativePath in relativePaths {
            guard let from = Self.containedPath(relativePath, in: source, fileManager: fileManager),
                  let to = Self.containedPath(relativePath, in: worktree, fileManager: fileManager),
                  fileManager.fileExists(atPath: from.path)
            else {
                missing.append(relativePath)
                continue
            }
            do {
                try fileManager.createDirectory(
                    at: to.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: to.path) {
                    try fileManager.removeItem(at: to)
                }
                try fileManager.copyItem(at: from, to: to)
            } catch {
                missing.append(relativePath)
            }
        }
        return missing
    }

    /// `relativePath` under `root`, or nil when it could lead out of it: an
    /// absolute path, a `..` component, or a directory along the way that is a
    /// symlink — a repository can commit one pointing anywhere. The last
    /// component may itself be a link; copying and removing handle a link as
    /// the link, never as what it points at.
    static func containedPath(_ relativePath: String, in root: URL, fileManager: FileManager) -> URL? {
        let components = relativePath.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !relativePath.hasPrefix("/"), let last = components.last, !components.contains("..")
        else { return nil }
        var directory = root
        for component in components.dropLast() {
            directory.appendPathComponent(component)
            if (try? fileManager.destinationOfSymbolicLink(atPath: directory.path)) != nil {
                return nil
            }
        }
        return directory.appendingPathComponent(last)
    }

    /// Each workspace gets a `.context` directory: attachments, plans and notes
    /// as ordinary files the agent can read with its own tools, rather than
    /// state trapped inside the app.
    private func createContextDirectory(in worktree: URL) async throws {
        let context = worktree.appendingPathComponent(".context", isDirectory: true)
        try fileManager.createDirectory(
            at: context.appendingPathComponent("attachments", isDirectory: true),
            withIntermediateDirectories: true
        )

        // ORE's scratch space must never turn up in the user's diff, and it is
        // not ours to add to their `.gitignore`. `info/exclude` is the private,
        // per-checkout equivalent — but in a worktree `.git` is a *file*
        // pointing elsewhere, so the path has to come from git itself.
        guard let excludePath = try? await git.gitPath("info/exclude", in: worktree) else { return }
        try? fileManager.createDirectory(
            at: excludePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing = (try? String(contentsOf: excludePath, encoding: .utf8)) ?? ""
        guard !existing.contains(".context/") else { return }
        let updated = existing.isEmpty ? ".context/\n" : existing + "\n.context/\n"
        try? updated.write(to: excludePath, atomically: true, encoding: .utf8)
    }

    // MARK: - Removing

    /// Removes a worktree. Refuses to discard uncommitted work unless forced.
    public func remove(
        at path: URL,
        deleteBranch: String? = nil,
        force: Bool = false
    ) async throws {
        if !force, try await hasUncommittedChanges(at: path) {
            throw GitError.dirtyWorktree(path: path.path)
        }

        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(path.path)
        try await git.runSerialized(arguments)

        if let deleteBranch {
            // A branch that never merged is not ours to destroy quietly, so
            // failure here is not fatal — the worktree is already gone.
            try? await git.runSerialized(["branch", "-D", deleteBranch])
        }
    }

    /// Archiving keeps the branch and the commits; it only reclaims the
    /// checkout. Uncommitted work is stashed onto a ref first so unarchiving
    /// can put the user back exactly where they were.
    public func archive(at path: URL, workspaceID: WorkspaceID) async throws -> String? {
        guard try await hasUncommittedChanges(at: path) else {
            try await remove(at: path, force: true)
            return nil
        }

        let ref = "refs/ore/archive/\(workspaceID.rawValue)"
        let commit = try await CheckpointStore(git: git).captureTree(
            worktree: path,
            ref: ref,
            message: "ore: archived working state"
        )
        try await remove(at: path, force: true)
        return commit
    }

    public func hasUncommittedChanges(at path: URL) async throws -> Bool {
        let output = try await git.run(
            ["status", "--porcelain=v2", "-z", "--untracked-files=normal"],
            in: path
        )
        return !output.standardOutput.isEmpty
    }

    public func list() async throws -> [ExistingWorktree] {
        let output = try await git.run(["worktree", "list", "--porcelain"])
        return ExistingWorktree.parse(output.standardOutput)
    }

    // MARK: - Naming

    private func repositorySlug() async -> String {
        let url = await git.repositoryURL
        return Slug.make(url.lastPathComponent)
    }

    /// Worktree directories must not collide, and a user naming two workspaces
    /// "fix the bug" is normal rather than an error.
    private func uniquePath(in directory: URL, preferredSlug: String) throws -> URL {
        var candidate = directory.appendingPathComponent(preferredSlug, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(preferredSlug)-\(suffix)", isDirectory: true)
            suffix += 1
            if suffix > 999 { throw GitError.worktreeExists(path: candidate.path) }
        }
        return candidate
    }

    private func uniqueBranch(prefix: String, slug: String) async throws -> String {
        let base = prefix.isEmpty ? slug : "\(prefix)/\(slug)"
        var candidate = base
        var suffix = 2
        while await git.branchExists(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
            if suffix > 999 { throw GitError.branchExists(name: base) }
        }
        return candidate
    }
}

public struct ExistingWorktree: Sendable, Hashable {
    public var path: URL
    public var head: String?
    public var branch: String?
    public var isBare: Bool
    public var isDetached: Bool

    static func parse(_ output: String) -> [ExistingWorktree] {
        var result: [ExistingWorktree] = []
        var current: ExistingWorktree?

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                if let current { result.append(current) }
                current = nil
                continue
            }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            switch parts.first {
            case "worktree":
                if let current { result.append(current) }
                current = ExistingWorktree(
                    path: URL(fileURLWithPath: parts.count > 1 ? parts[1] : ""),
                    isBare: false,
                    isDetached: false
                )
            case "HEAD":
                current?.head = parts.count > 1 ? parts[1] : nil
            case "branch":
                // `refs/heads/foo` → `foo`
                current?.branch = (parts.count > 1 ? parts[1] : "")
                    .replacingOccurrences(of: "refs/heads/", with: "")
            case "bare":
                current?.isBare = true
            case "detached":
                current?.isDetached = true
            default:
                break
            }
        }
        if let current { result.append(current) }
        return result
    }
}

public enum Slug {
    /// Turns a workspace name into something safe for a directory and a branch.
    ///
    /// Git refuses a surprising number of branch names — `..`, a trailing dot,
    /// a leading dash, anything with a space or a control character — and the
    /// failure comes back as a raw git error long after the user typed the name.
    public static func make(_ name: String, maximumLength: Int = 48) -> String {
        var slug = ""
        var lastWasSeparator = true  // suppresses a leading separator

        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                slug.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                slug.append("-")
                lastWasSeparator = true
            }
        }

        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > maximumLength {
            slug = String(slug.prefix(maximumLength))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug.isEmpty ? "workspace" : slug
    }
}
