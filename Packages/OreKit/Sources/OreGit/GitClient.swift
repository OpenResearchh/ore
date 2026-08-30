import Foundation
import OreProtocol
import OreSupport

/// Runs `git` for one repository.
///
/// ORE shells out to the system `git` rather than linking libgit2: worktrees are
/// fully supported, the user's own config, hooks, credential helpers and LFS all
/// apply, and when something goes wrong the error message is one the user can
/// paste into a search engine. The cost is process spawns, which is why writes
/// are serialized per repository and reads are allowed to overlap.
public actor GitClient {
    public let repositoryURL: URL
    private let executablePath: String

    /// Git refuses to run two index-mutating commands at once, and a worktree
    /// add racing a status read produces nonsense. Writes queue behind this.
    private var writeLocked = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    /// Last successful `fetch origin <branch>`, so sibling worktrees share a
    /// cooldown instead of each hitting the network on every poll.
    private var lastRemoteFetch: [String: ContinuousClock.Instant] = [:]

    public init(repositoryURL: URL, executablePath: String? = nil) throws {
        self.repositoryURL = repositoryURL
        guard let path = executablePath ?? ShellEnvironment.locate("git") else {
            throw GitError.gitNotFound
        }
        self.executablePath = path
    }

    // MARK: - Running git

    /// Runs a read-only git command. Concurrent reads are fine.
    ///
    /// `environmentOverrides` exists for the handful of operations that must
    /// redirect git's own state — `GIT_INDEX_FILE` for checkpoints, most of all.
    @discardableResult
    /// `allowedExitCodes` covers the commands where a non-zero status is an
    /// answer rather than a failure — `diff --no-index` exits 1 to mean "these
    /// differ", which is exactly the case we asked about.
    public func run(
        _ arguments: [String],
        in directory: URL? = nil,
        stdin: String? = nil,
        environmentOverrides: [String: String] = [:],
        allowedExitCodes: Set<Int32> = [0]
    ) async throws -> GitOutput {
        try await GitProcess.run(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: directory ?? repositoryURL,
            stdin: stdin,
            environmentOverrides: environmentOverrides,
            allowedExitCodes: allowedExitCodes
        )
    }

    /// Resolves a path inside the git directory, correctly for a worktree —
    /// where `.git` is a file pointing elsewhere and per-worktree state lives
    /// under the common directory.
    public func gitPath(_ relativePath: String, in directory: URL? = nil) async throws -> URL {
        let output = try await run(
            ["rev-parse", "--path-format=absolute", "--git-path", relativePath],
            in: directory
        )
        return URL(fileURLWithPath: output.trimmedStandardOutput)
    }

    /// Runs a command that mutates the repository, serialized against every
    /// other write to the same repository.
    @discardableResult
    public func runSerialized(
        _ arguments: [String],
        in directory: URL? = nil,
        stdin: String? = nil,
        environmentOverrides: [String: String] = [:]
    ) async throws -> GitOutput {
        await acquireWriteLock()
        do {
            let output = try await run(
                arguments,
                in: directory,
                stdin: stdin,
                environmentOverrides: environmentOverrides
            )
            releaseWriteLock()
            return output
        } catch {
            releaseWriteLock()
            throw error
        }
    }

    private func acquireWriteLock() async {
        if !writeLocked {
            writeLocked = true
            return
        }
        await withCheckedContinuation { writeWaiters.append($0) }
    }

    private func releaseWriteLock() {
        guard !writeWaiters.isEmpty else {
            writeLocked = false
            return
        }
        writeWaiters.removeFirst().resume()
    }

    // MARK: - Repository facts

    /// The repository's common git directory — shared by every worktree, and
    /// where ORE's own refs live.
    public func commonGitDirectory() async throws -> URL {
        let output = try await run(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        return URL(fileURLWithPath: output.trimmedStandardOutput)
    }

    public func topLevel() async throws -> URL {
        let output = try await run(["rev-parse", "--show-toplevel"])
        return URL(fileURLWithPath: output.trimmedStandardOutput)
    }

    public func currentBranch(in directory: URL? = nil) async throws -> String? {
        let output = try await run(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
        let branch = output.trimmedStandardOutput
        return branch == "HEAD" ? nil : branch
    }

    public func resolve(_ revision: String, in directory: URL? = nil) async throws -> String {
        try await run(["rev-parse", "--verify", revision], in: directory).trimmedStandardOutput
    }

    public func branchExists(_ name: String) async -> Bool {
        (try? await run(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"])) != nil
    }

    /// Where a worktree actually diverged from its base branch.
    ///
    /// `...` semantics — compare against the merge base — mean commits landing
    /// on the base while the agent works aren't counted as this workspace's
    /// work. The subtlety is *which* base ref to ask about: the local branch is
    /// only as fresh as the last time the user checked it out, and nothing in
    /// ORE updates it. Once the real base moves ahead, every workspace starts
    /// reporting the base's own commits as its own — the review pane showed 53
    /// changed files where the pull request showed 39, and a workspace that had
    /// committed nothing at all still offered "Create pull request".
    ///
    /// So both the local branch and its remote-tracking ref are considered, and
    /// the one that diverged *later* wins. Taking the later of the two is what
    /// makes this safe in both directions: a stale local ref is ignored, and so
    /// is a stale `origin/` ref when the user is working offline or ahead.
    /// Repositories with no remote are unaffected — the `origin/` lookup simply
    /// fails and the local ref stands.
    public func mergeBase(with baseBranch: String, in directory: URL? = nil) async -> String? {
        var best: String?
        for ref in ["origin/\(baseBranch)", baseBranch] {
            guard let candidate = try? await run(
                ["merge-base", "HEAD", ref], in: directory
            ).trimmedStandardOutput, !candidate.isEmpty else { continue }

            guard let current = best else { best = candidate; continue }
            // `--is-ancestor` exits 0 when the first commit precedes the second,
            // which is exactly "the candidate is the later divergence point".
            let isNewer = (try? await run(
                ["merge-base", "--is-ancestor", current, candidate],
                in: directory,
                allowedExitCodes: [0, 1]
            ).exitCode) == 0
            if isNewer { best = candidate }
        }
        return best
    }

    /// How many commits this worktree has that its base doesn't — measured from
    /// the real divergence point, so a stale local base ref can't credit the
    /// base's own history to the workspace.
    public func commitsAheadOfBase(_ baseBranch: String, in directory: URL? = nil) async -> Int {
        let base = await mergeBase(with: baseBranch, in: directory) ?? baseBranch
        guard let output = try? await run(
            ["rev-list", "--count", "\(base)..HEAD"], in: directory
        ) else { return 0 }
        return Int(output.trimmedStandardOutput) ?? 0
    }

    /// Commits in a revision range, newest first.
    ///
    /// Fields are separated by unit-separator so subjects containing any
    /// printable character parse intact. `--shortstat` follows each record so
    /// the ship panel can show +/− without a second git call per commit.
    public func commits(
        range: String, in directory: URL? = nil, limit: Int = 50
    ) async throws -> [CommitInfo] {
        try await logCommits(revisionArguments: [range], in: directory, limit: limit)
    }

    /// Commits on HEAD that aren't on any remote-tracking branch.
    ///
    /// That's "what `git push` would actually send", not "what's ahead of a
    /// possibly stale `@{upstream}`". Fast-forwarding onto `origin/main` used
    /// to dump that already-published history into the ship panel as if it
    /// were unpushed work.
    ///
    /// With no remotes configured, falls back to `fallbackRange` (typically
    /// `baseBranch..HEAD`).
    public func unpushedCommits(
        fallbackRange: String,
        in directory: URL? = nil,
        limit: Int = 50
    ) async throws -> [CommitInfo] {
        if await hasRemote() {
            return try await logCommits(
                revisionArguments: ["HEAD", "--not", "--remotes"],
                in: directory,
                limit: limit
            )
        }
        return try await commits(range: fallbackRange, in: directory, limit: limit)
    }

    /// How many commits `unpushedCommits` would list. 0 when there is no remote
    /// — the caller should use `baseBranch..HEAD` in that case.
    public func unpushedCommitCount(in directory: URL? = nil) async -> Int {
        guard await hasRemote() else { return 0 }
        guard let output = try? await run(
            ["rev-list", "--count", "HEAD", "--not", "--remotes"],
            in: directory
        ) else { return 0 }
        return Int(output.trimmedStandardOutput) ?? 0
    }

    private func logCommits(
        revisionArguments: [String],
        in directory: URL?,
        limit: Int
    ) async throws -> [CommitInfo] {
        let output = try await run([
            "log", "--max-count=\(limit)",
            "--format=%H%x1f%h%x1f%s%x1f%an%x1f%aI",
            "--shortstat",
        ] + revisionArguments, in: directory)
        return CommitInfo.parseLog(output.standardOutput)
    }

    /// The repository's default branch, in the order a developer would guess:
    /// what the remote says its HEAD is, then the usual names, then whatever is
    /// currently checked out.
    public func defaultBranch() async -> String {
        if let output = try? await run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]) {
            let value = output.trimmedStandardOutput
            if let slash = value.lastIndex(of: "/") {
                return String(value[value.index(after: slash)...])
            }
        }
        for candidate in ["main", "master"] where await branchExists(candidate) {
            return candidate
        }
        return (try? await currentBranch()) .flatMap { $0 } ?? "main"
    }

    public func hasRemote() async -> Bool {
        guard let output = try? await run(["remote"]) else { return false }
        return !output.trimmedStandardOutput.isEmpty
    }

    /// Remote branches (without the `origin/` prefix), for choosing a PR base.
    /// Excludes the symbolic `HEAD` entry.
    public func remoteBranches() async -> [String] {
        guard let output = try? await run([
            "for-each-ref", "--format=%(refname:short)", "refs/remotes/origin",
        ]) else { return [] }
        return output.trimmedStandardOutput
            .split(separator: "\n")
            .map { String($0).replacingOccurrences(of: "origin/", with: "") }
            .filter { !$0.isEmpty && $0 != "HEAD" }
    }

    /// Local branch names, for seeding a workspace from an existing branch.
    public func localBranches() async -> [String] {
        guard let output = try? await run([
            "for-each-ref", "--format=%(refname:short)", "refs/heads",
        ]) else { return [] }
        return output.trimmedStandardOutput
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// How many commits `tip` has that `base` does not (`base..tip`).
    public func commitCount(from base: String, to tip: String, in directory: URL? = nil) async -> Int {
        guard let output = try? await run(
            ["rev-list", "--count", "\(base)..\(tip)"], in: directory
        ) else { return 0 }
        return Int(output.trimmedStandardOutput) ?? 0
    }

    /// Fetch one remote branch. Coalesced so N worktrees of the same repo don't
    /// hammer origin every poll.
    public func fetchRemoteBranch(_ name: String, force: Bool = false) async throws {
        guard await hasRemote() else { return }
        let key = "origin/\(name)"
        if !force, let last = lastRemoteFetch[key], last.duration(to: .now) < .seconds(30) {
            return
        }
        try await runSerialized(["fetch", "--quiet", "origin", name])
        lastRemoteFetch[key] = .now
    }

    /// Whether any working tree — the main checkout included — has this
    /// branch checked out. Moving a checked-out branch with `update-ref`
    /// leaves that checkout's index pointing at the old commit, which reads
    /// as phantom uncommitted changes.
    public func isBranchCheckedOut(_ name: String) async -> Bool {
        guard let output = try? await run(["worktree", "list", "--porcelain"])
            .trimmedStandardOutput else { return false }
        return output.split(separator: "\n").contains { $0 == "branch refs/heads/\(name)" }
    }

    /// Fast-forward a local branch that is not checked out — typical for
    /// worktrees, where `main` lives in the repo but never in this checkout.
    ///
    /// Refuses to move the branch if it isn't an ancestor of `to`, so a
    /// diverged local default isn't silently overwritten.
    public func fastForwardLocalBranch(_ name: String, to remote: String) async throws {
        let remoteSHA = try await resolve(remote)
        if await branchExists(name) {
            let isAncestor = (try? await run(
                ["merge-base", "--is-ancestor", name, remote],
                allowedExitCodes: [0, 1]
            ).exitCode) == 0
            guard isAncestor else {
                throw GitError.notFastForward(branch: name, onto: remote)
            }
            try await runSerialized(["update-ref", "refs/heads/\(name)", remoteSHA])
        } else {
            try await runSerialized(["branch", name, remoteSHA])
        }
    }

    /// Whether merging `other` into HEAD would conflict, without touching the
    /// index or worktree.
    public func mergeWouldConflict(with other: String, in directory: URL? = nil) async -> Bool {
        if let output = try? await run(
            ["merge-tree", "--write-tree", "HEAD", other],
            in: directory,
            allowedExitCodes: [0, 1]
        ) {
            return output.exitCode == 1
        }
        guard let base = try? await run(
            ["merge-base", "HEAD", other], in: directory
        ).trimmedStandardOutput, !base.isEmpty,
        let tree = try? await run(
            ["merge-tree", base, "HEAD", other], in: directory
        ) else { return false }
        return tree.standardOutput.contains("changed in both")
    }

    /// `stem`, then `stem-2`, `stem-3`, … until the name is free.
    public func unusedBranchName(stem: String) async throws -> String {
        if await !branchExists(stem) { return stem }
        var suffix = 2
        while suffix <= 999 {
            let candidate = "\(stem)-\(suffix)"
            if await !branchExists(candidate) { return candidate }
            suffix += 1
        }
        throw GitError.branchExists(name: stem)
    }

    /// Takes `--ours` or `--theirs` for a conflicted path and stages the result.
    public func checkoutConflictSide(
        _ side: ConflictSide,
        path: String,
        in worktree: URL
    ) async throws {
        let flag = side == .ours ? "--ours" : "--theirs"
        try await runSerialized(["checkout", flag, "--", path], in: worktree)
        try await runSerialized(["add", "--", path], in: worktree)
    }
}

/// One commit as the ship panel shows it: enough to recognize the work, not
/// the full object.
public struct CommitInfo: Sendable, Hashable, Codable, Identifiable {
    public var sha: String
    public var shortSHA: String
    public var subject: String
    public var author: String
    public var date: Date
    public var filesChanged: Int
    public var insertions: Int
    public var deletions: Int

    public var id: String { sha }

    public init(
        sha: String,
        shortSHA: String,
        subject: String,
        author: String,
        date: Date,
        filesChanged: Int = 0,
        insertions: Int = 0,
        deletions: Int = 0
    ) {
        self.sha = sha
        self.shortSHA = shortSHA
        self.subject = subject
        self.author = author
        self.date = date
        self.filesChanged = filesChanged
        self.insertions = insertions
        self.deletions = deletions
    }

    /// Parses `git log --format=%H%x1f%h%x1f%s%x1f%an%x1f%aI --shortstat`.
    static func parseLog(_ raw: String) -> [CommitInfo] {
        let formatter = ISO8601DateFormatter()
        var commits: [CommitInfo] = []
        var pending: (
            sha: String, shortSHA: String, subject: String, author: String, date: Date
        )?
        var filesChanged = 0, insertions = 0, deletions = 0

        func flush() {
            guard let pending else { return }
            commits.append(CommitInfo(
                sha: pending.sha,
                shortSHA: pending.shortSHA,
                subject: pending.subject,
                author: pending.author,
                date: pending.date,
                filesChanged: filesChanged,
                insertions: insertions,
                deletions: deletions
            ))
            filesChanged = 0
            insertions = 0
            deletions = 0
        }

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.contains("\u{1f}") {
                flush()
                let fields = value.split(separator: "\u{1f}", omittingEmptySubsequences: false)
                guard fields.count >= 5 else {
                    pending = nil
                    continue
                }
                pending = (
                    String(fields[0]),
                    String(fields[1]),
                    String(fields[2]),
                    String(fields[3]),
                    formatter.date(from: String(fields[4])) ?? Date()
                )
            } else if let stats = Self.parseShortstat(value) {
                filesChanged = stats.files
                insertions = stats.insertions
                deletions = stats.deletions
            }
        }
        flush()
        return commits
    }

    static func parseShortstat(_ line: String) -> (files: Int, insertions: Int, deletions: Int)? {
        let value = line.trimmingCharacters(in: .whitespaces)
        guard value.contains("changed") else { return nil }
        func count(matching pattern: String) -> Int {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: value, range: NSRange(value.startIndex..., in: value)
                  ),
                  let range = Range(match.range(at: 1), in: value)
            else { return 0 }
            return Int(value[range]) ?? 0
        }
        return (
            count(matching: #"(\d+) files? changed"#),
            count(matching: #"(\d+) insertions?\(\+\)"#),
            count(matching: #"(\d+) deletions?\(-\)"#)
        )
    }
}

// MARK: - Process plumbing

public struct GitOutput: Sendable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public var trimmedStandardOutput: String {
        standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits NUL-delimited output. `-z` is used wherever a path could contain
    /// a newline or a quote, which git would otherwise escape into a form that
    /// has to be unquoted.
    public var nulSeparatedFields: [String] {
        standardOutput.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    public var lines: [String] {
        standardOutput.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

enum GitProcess {
    static func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL,
        stdin: String?,
        environmentOverrides: [String: String] = [:],
        allowedExitCodes: Set<Int32> = [0]
    ) async throws -> GitOutput {
        let process = try ChildProcess(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: gitEnvironment().merging(environmentOverrides) { _, override in override }
        )

        // Both pipes must be drained concurrently: git writes progress to
        // stderr while streaming a large diff to stdout, and reading them in
        // sequence deadlocks as soon as either pipe buffer fills.
        async let standardOutput = process.stdoutChunks.collectText()
        async let standardError = process.stderrChunks.collectText()

        if let stdin {
            process.write(Data(stdin.utf8))
        }
        process.closeStandardInput()

        let output = await standardOutput
        let errorOutput = await standardError
        let status = await process.waitForExit()

        guard allowedExitCodes.contains(status) else {
            throw GitError.commandFailed(
                arguments: arguments,
                exitCode: status,
                message: errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return GitOutput(
            exitCode: status,
            standardOutput: output,
            standardError: errorOutput
        )
    }

    /// Git's environment, with anything interactive disabled.
    ///
    /// A GUI app has no terminal to type a passphrase into: without this, a
    /// repository whose remote needs credentials hangs forever instead of
    /// failing with something we can show the user.
    private static func gitEnvironment() -> [String: String] {
        var environment = ShellEnvironment.childEnvironment()
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["LC_ALL"] = "C"
        return environment
    }
}

public enum GitError: Error, Sendable, CustomStringConvertible {
    case gitNotFound
    case commandFailed(arguments: [String], exitCode: Int32, message: String)
    case notARepository(path: String)
    case worktreeExists(path: String)
    case branchExists(name: String)
    case dirtyWorktree(path: String)
    case invalidOutput(String)
    case notFastForward(branch: String, onto: String)

    public var description: String {
        switch self {
        case .gitNotFound:
            return "git was not found on PATH."
        case .commandFailed(let arguments, let exitCode, let message):
            let command = "git " + arguments.joined(separator: " ")
            return message.isEmpty
                ? "`\(command)` failed with status \(exitCode)."
                : "`\(command)` failed: \(message)"
        case .notARepository(let path):
            return "\(path) is not a git repository."
        case .worktreeExists(let path):
            return "A worktree already exists at \(path)."
        case .branchExists(let name):
            return "The branch `\(name)` already exists."
        case .dirtyWorktree(let path):
            return "The worktree at \(path) has uncommitted changes."
        case .invalidOutput(let detail):
            return "Could not parse git output: \(detail)"
        case .notFastForward(let branch, let onto):
            return "Local `\(branch)` has diverged from `\(onto)` and cannot be fast-forwarded. Rebase or reset it before pulling."
        }
    }
}
