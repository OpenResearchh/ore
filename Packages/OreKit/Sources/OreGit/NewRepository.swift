import Foundation

/// A brand-new local git repository — a project that has no history anywhere
/// yet, as opposed to one the user already has on disk or on GitHub.
///
/// The initial commit is not a nicety. A workspace is a `git worktree add -b
/// <branch> <path> <base>`, and git has nothing to branch *from* until the
/// repository has a HEAD. Without it "start a new project" would create a
/// repository ORE could register but never open a workspace in — the failure
/// arriving one step later, phrased as an unresolvable revision.
public struct NewRepository: Sendable, Hashable {
    public var path: URL
    public var defaultBranch: String
    public var initialCommit: String

    public init(path: URL, defaultBranch: String, initialCommit: String) {
        self.path = path
        self.defaultBranch = defaultBranch
        self.initialCommit = initialCommit
    }
}

public enum NewRepositoryError: Error, Sendable, CustomStringConvertible {
    case emptyName
    case alreadyARepository(path: String)
    case directoryNotEmpty(path: String)
    case parentNotWritable(path: String, underlying: String)

    public var description: String {
        switch self {
        case .emptyName:
            return "A new project needs a name."
        case .alreadyARepository(let path):
            return "\(path) is already a git repository — add it to ORE instead of creating it."
        case .directoryNotEmpty(let path):
            return "\(path) already exists and isn't empty. Choose another project name."
        case .parentNotWritable(let path, let underlying):
            return "Could not create \(path): \(underlying)"
        }
    }
}

/// Creates empty local repositories: `git init`, one seed file, one commit.
public enum RepositoryInitializer {
    /// The directory name a project gets.
    ///
    /// A name that is already a safe path component is kept verbatim, so a
    /// project called `LACE` lands in `LACE` rather than a slugged `lace` the
    /// user then has to explain to their imports. Anything else — spaces,
    /// slashes, punctuation, a leading dot — is slugged, because the name also
    /// has to survive being a directory and, later, part of a branch name.
    public static func directoryName(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let isSafeComponent = !trimmed.isEmpty
            && !trimmed.hasPrefix(".")
            && trimmed.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
        return isSafeComponent ? trimmed : Slug.make(trimmed)
    }

    /// Creates `<parent>/<directoryName(for: name)>` as a git repository with a
    /// single commit on `defaultBranch`.
    ///
    /// An existing *empty* directory is adopted — that is what a user who made
    /// the folder first expects. An existing repository, or a directory with
    /// anything in it, is refused rather than written into.
    public static func create(
        name: String,
        in parent: URL,
        defaultBranch: String = "main",
        executablePath: String? = nil
    ) async throws -> NewRepository {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw NewRepositoryError.emptyName }

        let files = FileManager.default
        let path = parent.appendingPathComponent(directoryName(for: trimmedName), isDirectory: true)

        var isDirectory: ObjCBool = false
        if files.fileExists(atPath: path.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw NewRepositoryError.directoryNotEmpty(path: path.path)
            }
            if files.fileExists(atPath: path.appendingPathComponent(".git").path) {
                throw NewRepositoryError.alreadyARepository(path: path.path)
            }
            let contents = (try? files.contentsOfDirectory(atPath: path.path)) ?? []
            // `.DS_Store` is the Finder's, not the user's: a folder they made
            // and then looked at is still an empty folder.
            guard contents.allSatisfy({ $0 == ".DS_Store" }) else {
                throw NewRepositoryError.directoryNotEmpty(path: path.path)
            }
        } else {
            do {
                try files.createDirectory(at: path, withIntermediateDirectories: true)
            } catch {
                throw NewRepositoryError.parentNotWritable(
                    path: path.path,
                    underlying: error.localizedDescription
                )
            }
        }

        let git = try GitClient(repositoryURL: path, executablePath: executablePath)
        try await git.run(["init", "--quiet", "--initial-branch", defaultBranch])

        // A repository whose only commit is empty reads as broken to every tool
        // that opens it. One README, named after the project, is the smallest
        // thing that makes it a project rather than an artifact.
        let readme = path.appendingPathComponent("README.md")
        if !files.fileExists(atPath: readme.path) {
            try? "# \(trimmedName)\n".write(to: readme, atomically: true, encoding: .utf8)
        }
        try await git.run(["add", "-A"])
        try await git.run(commitArguments(identity: await commitIdentity(git: git)))

        return NewRepository(
            path: try await git.topLevel(),
            defaultBranch: (try? await git.currentBranch()) .flatMap { $0 } ?? defaultBranch,
            initialCommit: try await git.resolve("HEAD")
        )
    }

    /// `-c` overrides for the initial commit.
    ///
    /// Signing is disabled unconditionally: a GUI app runs git with
    /// `GIT_TERMINAL_PROMPT=0`, so a user whose global config signs every commit
    /// would get a failure with no passphrase prompt to answer. The identity
    /// override is only added when the machine has none — borrowing the user's
    /// own name and email is the whole point when they have one.
    static func commitArguments(identity: Bool) -> [String] {
        var arguments = ["-c", "commit.gpgsign=false"]
        if identity {
            arguments += ["-c", "user.name=ORE", "-c", "user.email=ore@localhost"]
        }
        return arguments + ["commit", "--quiet", "-m", "Initial commit"]
    }

    /// True when git has no identity configured, so the commit needs one lent
    /// to it. A fresh machine — and every CI runner — is this case.
    private static func commitIdentity(git: GitClient) async -> Bool {
        let email = try? await git.run(
            ["config", "--get", "user.email"], allowedExitCodes: [0, 1]
        ).trimmedStandardOutput
        return (email ?? "").isEmpty
    }
}
