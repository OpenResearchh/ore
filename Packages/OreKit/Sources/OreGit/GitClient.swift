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
    /// Last failed fetch, so an offline machine doesn't retry on every tick of
    /// every worktree.
    private var lastFailedRemoteFetch: [String: ContinuousClock.Instant] = [:]
    /// A fetch already on the wire. Every engine of a repository starts at
    /// launch at once; they wait on the one fetch instead of queueing N more.
    private var remoteFetchesInFlight: [String: Task<Void, any Error>] = [:]
    /// How long a successful fetch satisfies non-forced callers. Base sync is
    /// a banner, not a live feed: minutes of lag cost nothing, while a network
    /// fetch per worktree per tick was a steady stream of processes.
    static let remoteFetchCooldown: Duration = .seconds(300)
    static let failedRemoteFetchCooldown: Duration = .seconds(60)
    /// Network fetches actually started. Tests assert coalescing against it.
    private(set) var remoteFetchCount = 0

    /// `merge-base` answers keyed by directory and base branch, valid while
    /// HEAD and both candidate base refs resolve to the same commits.
    private var mergeBaseMemo: [String: (fingerprint: String, result: String?)] = [:]
    /// Full `mergeBase` computations (memo misses). Tests assert against it.
    private(set) var mergeBaseComputationCount = 0

    /// `git remote` and the default branch only change with the repository's
    /// config (or, for the default branch, rarely at all), yet every base-sync
    /// tick and git-action refresh used to ask both again.
    private var configURL: URL??
    private var remoteMemo: (config: ConfigStamp, hasRemote: Bool)?
    private var defaultBranchMemo: (
        config: ConfigStamp, at: ContinuousClock.Instant, branch: String
    )?
    static let defaultBranchMemoLifetime: Duration = .seconds(300)

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

    /// A file's bytes as of `revision`, or nil when it did not exist there or
    /// is larger than `maximumBytes`.
    ///
    /// `run` decodes standard output as UTF-8, which is fine for porcelain and
    /// ruinous for an image, so blob contents take their own binary-safe path.
    /// It is how the review pane shows what a deleted or replaced image was.
    public func fileData(
        atRevision revision: String,
        path: String,
        in directory: URL? = nil,
        maximumBytes: Int = 20_000_000
    ) async -> Data? {
        let object = "\(revision):\(path)"
        guard let size = try? await run(["cat-file", "-s", object], in: directory) else {
            return nil
        }
        guard let bytes = Int(size.trimmedStandardOutput), bytes <= maximumBytes else {
            return nil
        }
        return try? await GitProcess.runData(
            executablePath: executablePath,
            arguments: ["cat-file", "blob", object],
            workingDirectory: directory ?? repositoryURL
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
    ///
    /// Memoized on the commits involved: one `show-ref` tells whether HEAD or
    /// either base ref moved, instead of up to three processes for every diff,
    /// ahead-count and git-action refresh.
    public func mergeBase(with baseBranch: String, in directory: URL? = nil) async -> String? {
        let key = "\((directory ?? repositoryURL).path)\u{0}\(baseBranch)"
        // `show-ref --head` prints HEAD plus whichever of the two refs exist,
        // each with its name, and never fails over a missing one. Not
        // `rev-parse --revs-only`: after the first missing ref it treats the
        // rest as paths and silently drops them from the fingerprint.
        let fingerprint = try? await run(
            ["show-ref", "--head", "refs/heads/\(baseBranch)", "refs/remotes/origin/\(baseBranch)"],
            in: directory
        ).trimmedStandardOutput
        if let fingerprint, let memo = mergeBaseMemo[key], memo.fingerprint == fingerprint {
            return memo.result
        }
        let result = await computeMergeBase(with: baseBranch, in: directory)
        // Only HEAD matched: the base is a sha or some other revision the
        // fingerprint can't see move, so it is never remembered.
        guard let fingerprint, fingerprint.contains("\n") else { return result }
        // One entry per worktree and base; the bound only matters for a very
        // long session with churning base branches.
        if mergeBaseMemo.count > 256 { mergeBaseMemo.removeAll() }
        mergeBaseMemo[key] = (fingerprint, result)
        return result
    }

    private func computeMergeBase(with baseBranch: String, in directory: URL?) async -> String? {
        mergeBaseComputationCount += 1
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
    ///
    /// Remembered for a few minutes while the config is unchanged. Only a
    /// confident answer is kept: the current-branch fallback moves with every
    /// checkout, so it is re-derived each time.
    public func defaultBranch() async -> String {
        let stamp = await configStamp()
        if let stamp, let memo = defaultBranchMemo, memo.config == stamp,
           memo.at.duration(to: .now) < Self.defaultBranchMemoLifetime {
            return memo.branch
        }
        if let branch = await confidentDefaultBranch() {
            if let stamp { defaultBranchMemo = (stamp, .now, branch) }
            return branch
        }
        return (try? await currentBranch()) .flatMap { $0 } ?? "main"
    }

    private func confidentDefaultBranch() async -> String? {
        if let output = try? await run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]) {
            let value = output.trimmedStandardOutput
            if let slash = value.lastIndex(of: "/") {
                return String(value[value.index(after: slash)...])
            }
        }
        for candidate in ["main", "master"] where await branchExists(candidate) {
            return candidate
        }
        return nil
    }

    /// Remotes live in the repository config, so the answer holds until that
    /// file changes — `gh repo create --source` adding `origin` included.
    public func hasRemote() async -> Bool {
        let stamp = await configStamp()
        if let stamp, let memo = remoteMemo, memo.config == stamp {
            return memo.hasRemote
        }
        guard let output = try? await run(["remote"]) else { return false }
        let hasRemote = !output.trimmedStandardOutput.isEmpty
        if let stamp { remoteMemo = (stamp, hasRemote) }
        return hasRemote
    }

    struct ConfigStamp: Equatable {
        var modified: Date?
        var size: Int?
    }

    /// Modification time and size of the shared `config`. nil when it can't
    /// be read, which disables the memos rather than trusting a stale answer.
    private func configStamp() async -> ConfigStamp? {
        if configURL == nil {
            // Resolved once: `--git-path config` lands in the common directory
            // for every worktree, and it never moves. A failure is remembered
            // too, so a non-repository doesn't spawn this on every call.
            let resolved = try? await gitPath("config")
            configURL = .some(resolved)
        }
        guard let url = configURL ?? nil else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return ConfigStamp(
            modified: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.intValue
        )
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
    /// hammer origin every poll: a non-forced call is satisfied by any fetch
    /// that succeeded within `remoteFetchCooldown` (or failed within
    /// `failedRemoteFetchCooldown`), or joins one in flight. `force` is for the
    /// user asking to pull, and always hits the network.
    public func fetchRemoteBranch(_ name: String, force: Bool = false) async throws {
        guard await hasRemote() else { return }
        let key = "origin/\(name)"
        if !force, let last = lastRemoteFetch[key],
           last.duration(to: .now) < Self.remoteFetchCooldown {
            return
        }
        if !force, let failed = lastFailedRemoteFetch[key],
           failed.duration(to: .now) < Self.failedRemoteFetchCooldown {
            return
        }
        if let inFlight = remoteFetchesInFlight[key] {
            // A non-forced caller shares the outcome; a forced one wants a
            // fetch that started after it asked, so it only waits its turn.
            guard force else {
                try await inFlight.value
                return
            }
            _ = try? await inFlight.value
        }
        let fetch = Task { try await self.performRemoteFetch(name, key: key) }
        remoteFetchesInFlight[key] = fetch
        defer {
            if remoteFetchesInFlight[key] == fetch { remoteFetchesInFlight[key] = nil }
        }
        try await fetch.value
    }

    private func performRemoteFetch(_ name: String, key: String) async throws {
        remoteFetchCount += 1
        do {
            try await runSerialized(["fetch", "--quiet", "origin", name])
        } catch {
            lastFailedRemoteFetch[key] = .now
            throw error
        }
        lastRemoteFetch[key] = .now
        lastFailedRemoteFetch[key] = nil
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

    /// `run`, for output that must stay bytes.
    static func runData(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL
    ) async throws -> Data {
        let process = try ChildProcess(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: gitEnvironment()
        )
        async let standardOutput = process.stdoutChunks.collectData()
        async let standardError = process.stderrChunks.collectText()
        process.closeStandardInput()

        let output = await standardOutput
        let errorOutput = await standardError
        let status = await process.waitForExit()
        guard status == 0 else {
            throw GitError.commandFailed(
                arguments: arguments,
                exitCode: status,
                message: errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output
    }

    /// Git's environment, with anything interactive disabled.
    ///
    /// A GUI app has no terminal to type a passphrase into: without this, a
    /// repository whose remote needs credentials hangs forever instead of
    /// failing with something we can show the user.
    static func gitEnvironment() -> [String: String] {
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
