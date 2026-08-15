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

    /// Commits in a revision range, newest first.
    ///
    /// Fields are separated by unit-separator so subjects containing any
    /// printable character parse intact. `--shortstat` follows each record so
    /// the ship panel can show +/− without a second git call per commit.
    public func commits(
        range: String, in directory: URL? = nil, limit: Int = 50
    ) async throws -> [CommitInfo] {
        let output = try await run([
            "log", "--max-count=\(limit)",
            "--format=%H%x1f%h%x1f%s%x1f%an%x1f%aI",
            "--shortstat",
            range,
        ], in: directory)
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
        }
    }
}
