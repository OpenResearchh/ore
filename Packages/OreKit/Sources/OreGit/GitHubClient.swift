import Foundation
import OreProtocol
import OreSupport

/// GitHub, through the user's own `gh` CLI.
///
/// Same principle as the agent harnesses: drive the tool the user already has
/// and is already authenticated with, rather than asking for a token and
/// reimplementing auth, SSO, enterprise hosts and rate limiting.
public actor GitHubClient {
    private let executablePath: String?
    private let repositoryURL: URL

    public init(repositoryURL: URL, executablePath: String? = nil) {
        self.repositoryURL = repositoryURL
        self.executablePath = executablePath ?? ShellEnvironment.locate("gh")
    }

    public var isAvailable: Bool { executablePath != nil }

    public struct Status: Sendable, Hashable {
        public var isInstalled: Bool
        public var isAuthenticated: Bool
        public var version: String?
        public var diagnostic: String?

        public init(
            isInstalled: Bool,
            isAuthenticated: Bool,
            version: String? = nil,
            diagnostic: String? = nil
        ) {
            self.isInstalled = isInstalled
            self.isAuthenticated = isAuthenticated
            self.version = version
            self.diagnostic = diagnostic
        }
    }

    public func status() async -> Status {
        guard executablePath != nil else {
            return Status(
                isInstalled: false,
                isAuthenticated: false,
                diagnostic: "The GitHub CLI (`gh`) is not installed."
            )
        }
        let version = try? await run(["--version"]).lines.first
        let authenticated = (try? await run(["auth", "status"])) != nil
        return Status(
            isInstalled: true,
            isAuthenticated: authenticated,
            version: version,
            diagnostic: authenticated ? nil : "Run `gh auth login` to connect GitHub."
        )
    }

    // MARK: - Account and repositories

    public struct Repository: Sendable, Hashable, Codable, Identifiable {
        public var id: String { nameWithOwner }
        public var nameWithOwner: String
        public var description: String?
        public var isPrivate: Bool
        public var htmlURL: String
        public var defaultBranch: String
        public var pushedAt: String?

        private enum CodingKeys: String, CodingKey {
            case nameWithOwner = "full_name"
            case description
            case isPrivate = "private"
            case htmlURL = "html_url"
            case defaultBranch = "default_branch"
            case pushedAt = "pushed_at"
        }

        func matches(_ lowercasedNeedle: String) -> Bool {
            nameWithOwner.lowercased().contains(lowercasedNeedle)
                || (description?.lowercased().contains(lowercasedNeedle) ?? false)
        }
    }

    /// Browser-based `gh` authentication. Flags remove every question the CLI
    /// would otherwise ask in a GUI process; the account decision remains in
    /// GitHub's own browser page and credential store.
    public func authenticate() async throws {
        guard let executablePath else { throw GitHubError.ghNotInstalled }
        _ = try await GitProcess.run(
            executablePath: executablePath,
            arguments: [
                "auth", "login", "--hostname", "github.com",
                "--git-protocol", "https", "--web", "--clipboard",
            ],
            workingDirectory: repositoryURL,
            stdin: nil,
            environmentOverrides: ["GH_PAGER": "cat"]
        )
    }

    /// Repositories the signed-in account can access: owned, organization, and
    /// collaborator repositories, most recently pushed first.
    ///
    /// Bounded on purpose. An unbounded `--paginate` over a large organisation
    /// is dozens of API calls for a list the caller then truncates, which is
    /// how the repository someone actually meant gets cut off. Pages are taken
    /// one at a time and stop as soon as `limit` matches are in hand.
    public func repositories(
        matching query: String? = nil,
        limit: Int = 50
    ) async throws -> [Repository] {
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pageSize = 100
        // One page is enough to answer "what have I been working on"; a search
        // may have to look past the most recent hundred, but never forever.
        let maximumPages = (needle?.isEmpty ?? true) ? 1 : 5
        var found: [Repository] = []

        for page in 1...maximumPages {
            let output = try await run([
                "api", "--method", "GET", "user/repos",
                "-f", "per_page=\(pageSize)", "-f", "page=\(page)",
                "-f", "sort=pushed", "-f", "direction=desc",
            ])
            let batch = try JSONDecoder().decode(
                [Repository].self, from: Data(output.standardOutput.utf8)
            )
            if let needle, !needle.isEmpty {
                found += batch.filter { $0.matches(needle) }
            } else {
                found += batch
            }
            if batch.count < pageSize || found.count >= limit { break }
        }
        return Array(found.prefix(limit))
    }

    /// Creates a GitHub repository from a local checkout and publishes it.
    ///
    /// `--source` adds `origin` and `--push` publishes the source directory's
    /// current branch, so a local-only repo becomes one the normal push → PR →
    /// merge flow can act on. Private by default: freshly written code is the
    /// last thing to make public by accident, and it's one click to flip on
    /// GitHub afterwards. Returns the new repository's URL.
    @discardableResult
    public func createRepository(
        name: String,
        sourcePath: String,
        isPrivate: Bool = true,
        push: Bool = true
    ) async throws -> String {
        var arguments = [
            "repo", "create", name,
            isPrivate ? "--private" : "--public",
            "--source", sourcePath,
        ]
        if push { arguments.append("--push") }
        let output = try await run(arguments)
        return output.lines.last(where: { $0.hasPrefix("http") }) ?? output.trimmedStandardOutput
    }

    public func clone(repository reference: String, to destination: URL) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw GitHubError.destinationExists(destination.path)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await run(["repo", "clone", reference, destination.path])
    }

    // MARK: - Pull requests

    public struct PullRequest: Sendable, Hashable, Codable {
        public var number: Int
        public var title: String
        public var url: String
        public var state: String
        public var isDraft: Bool
        public var baseRefName: String
        public var headRefName: String
        public var mergeable: String?
        public var reviewDecision: String?
        public var checks: [CheckRun]

        public init(
            number: Int,
            title: String = "",
            url: String = "",
            state: String = "OPEN",
            isDraft: Bool = false,
            baseRefName: String = "main",
            headRefName: String = "",
            mergeable: String? = nil,
            reviewDecision: String? = nil,
            checks: [CheckRun] = []
        ) {
            self.number = number
            self.title = title
            self.url = url
            self.state = state
            self.isDraft = isDraft
            self.baseRefName = baseRefName
            self.headRefName = headRefName
            self.mergeable = mergeable
            self.reviewDecision = reviewDecision
            self.checks = checks
        }

        /// GitHub reports `MERGEABLE`, `CONFLICTING` or `UNKNOWN` (still
        /// computing). Unknown is treated as not-yet-ready rather than blocked.
        public var hasConflicts: Bool { mergeable == "CONFLICTING" }
        public var isOpen: Bool { state.uppercased() == "OPEN" }
        public var isMerged: Bool { state.uppercased() == "MERGED" }

        public var failingChecks: [CheckRun] {
            checks.filter { $0.isComplete && !$0.isSuccess }
        }

        public var hasRunningChecks: Bool { checks.contains { !$0.isComplete } }
    }

    public struct CheckRun: Sendable, Hashable, Codable {
        public var name: String
        public var state: String
        public var link: String?
        public var workflow: String?
        /// Present for CheckRun-shaped rollup entries; legacy commit statuses
        /// carry no timestamps, so both stay optional.
        public var startedAt: Date?
        public var completedAt: Date?

        public init(
            name: String,
            state: String,
            link: String? = nil,
            workflow: String? = nil,
            startedAt: Date? = nil,
            completedAt: Date? = nil
        ) {
            self.name = name
            self.state = state
            self.link = link
            self.workflow = workflow
            self.startedAt = startedAt
            self.completedAt = completedAt
        }

        public var duration: TimeInterval? {
            guard let startedAt, let completedAt else { return nil }
            return completedAt.timeIntervalSince(startedAt)
        }

        public var isComplete: Bool {
            !["PENDING", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED"]
                .contains(state.uppercased())
        }

        public var isSuccess: Bool {
            ["SUCCESS", "NEUTRAL", "SKIPPED"].contains(state.uppercased())
        }
    }

    /// The open PR for a branch, if there is one.
    public func pullRequest(forBranch branch: String) async -> PullRequest? {
        let fields = [
            "number", "title", "url", "state", "isDraft",
            "baseRefName", "headRefName", "mergeable", "reviewDecision", "statusCheckRollup",
        ].joined(separator: ",")

        guard let output = try? await run(
            ["pr", "view", branch, "--json", fields]
        ) else { return nil }

        return decodePullRequest(output.standardOutput)
    }

    public func createPullRequest(
        branch: String,
        base: String,
        title: String,
        body: String,
        draft: Bool = false
    ) async throws -> String {
        var arguments = [
            "pr", "create",
            "--head", branch,
            "--base", base,
            "--title", title,
            "--body", body,
        ]
        if draft { arguments.append("--draft") }
        let output = try await run(arguments)
        // `gh pr create` prints the PR URL on success.
        return output.lines.last(where: { $0.hasPrefix("http") }) ?? output.trimmedStandardOutput
    }

    /// Retargets an open PR. Used after a lower PR in a stack merges: its
    /// children were branched from it, so they must point at the base branch
    /// instead of a branch that no longer exists.
    public func retargetPullRequest(number: Int, to base: String) async throws {
        try await run(["pr", "edit", String(number), "--base", base])
    }

    public func merge(number: Int, method: MergeMethod = .squash, deleteBranch: Bool = true) async throws {
        var arguments = ["pr", "merge", String(number), method.flag]
        if deleteBranch { arguments.append("--delete-branch") }
        try await run(arguments)
    }

    public enum MergeMethod: String, Sendable, Codable, CaseIterable {
        case squash, merge, rebase

        var flag: String { "--\(rawValue)" }
    }

    // MARK: - CI logs

    /// The failing part of a CI run, ready to hand to the agent.
    ///
    /// One click from "CI is red" to the agent working on it is the whole
    /// point: the alternative is the user tabbing to a browser, finding the
    /// failing job, scrolling to the error and pasting it back.
    public func failedCheckLogs(forBranch branch: String, limit: Int = 4) async -> String? {
        guard let runs = try? await run([
            "run", "list", "--branch", branch, "--limit", "5",
            "--json", "databaseId,conclusion,name,status",
        ]) else { return nil }

        struct Run: Decodable {
            var databaseId: Int
            var conclusion: String?
            var name: String
            var status: String
        }
        guard let decoded = try? JSONDecoder().decode(
            [Run].self, from: Data(runs.standardOutput.utf8)
        ) else { return nil }

        let failed = decoded.filter { $0.conclusion == "failure" }.prefix(limit)
        guard !failed.isEmpty else { return nil }

        var sections: [String] = []
        for failure in failed {
            guard let log = try? await run(
                ["run", "view", String(failure.databaseId), "--log-failed"]
            ) else { continue }
            // A full CI log can be tens of megabytes; the failing tail is what
            // diagnoses the problem, and the rest just burns the agent's context.
            let tail = log.lines.suffix(200).joined(separator: "\n")
            sections.append("### \(failure.name)\n\n```\n\(tail)\n```")
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    // MARK: - Issues and PRs as workspace seeds

    public struct IssueSeed: Sendable, Hashable {
        public var number: Int
        public var title: String
        public var body: String
        public var url: String
        /// For a PR seed: the branch to check out instead of creating one.
        public var headRefName: String?

        public init(
            number: Int,
            title: String,
            body: String,
            url: String,
            headRefName: String? = nil
        ) {
            self.number = number
            self.title = title
            self.body = body
            self.url = url
            self.headRefName = headRefName
        }
    }

    public func issue(number: Int) async throws -> IssueSeed {
        let output = try await run([
            "issue", "view", String(number), "--json", "number,title,body,url",
        ])
        struct Payload: Decodable {
            var number: Int
            var title: String
            var body: String?
            var url: String
        }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(output.standardOutput.utf8))
        return IssueSeed(
            number: payload.number,
            title: payload.title,
            body: payload.body ?? "",
            url: payload.url
        )
    }

    public struct IssueListItem: Sendable, Hashable, Codable, Identifiable {
        public var id: Int { number }
        public var number: Int
        public var title: String
        public var updatedAt: String?
        public var headRefName: String?

        public init(number: Int, title: String, updatedAt: String? = nil, headRefName: String? = nil) {
            self.number = number
            self.title = title
            self.updatedAt = updatedAt
            self.headRefName = headRefName
        }
    }

    /// Open issues, newest activity first — the New Workspace sheet's picker.
    public func issues(limit: Int = 40) async throws -> [IssueListItem] {
        let output = try await run([
            "issue", "list", "--limit", String(limit),
            "--json", "number,title,updatedAt",
        ])
        return (try? JSONDecoder().decode([IssueListItem].self, from: Data(output.standardOutput.utf8))) ?? []
    }

    /// Open pull requests, newest activity first.
    public func pullRequests(limit: Int = 40) async throws -> [IssueListItem] {
        let output = try await run([
            "pr", "list", "--limit", String(limit),
            "--json", "number,title,updatedAt,headRefName",
        ])
        return (try? JSONDecoder().decode([IssueListItem].self, from: Data(output.standardOutput.utf8))) ?? []
    }

    /// Re-runs the failed jobs of the latest workflow run on this branch.
    public func rerunFailedChecks(forBranch branch: String) async throws {
        guard let runs = try? await run([
            "run", "list", "--branch", branch, "--limit", "5",
            "--json", "databaseId,conclusion,status",
        ]) else { return }

        struct Run: Decodable {
            var databaseId: Int
            var conclusion: String?
            var status: String
        }
        guard let decoded = try? JSONDecoder().decode(
            [Run].self, from: Data(runs.standardOutput.utf8)
        ) else { return }

        let failed = decoded.filter {
            $0.conclusion == "failure" || ($0.status == "completed" && $0.conclusion != "success")
        }
        guard let target = failed.first ?? decoded.first else { return }
        try await run(["run", "rerun", String(target.databaseId), "--failed"])
    }

    /// The failing log tail for one check, when `gh` can map it to a run.
    public func checkLog(named name: String, forBranch branch: String) async -> String? {
        guard let logs = await failedCheckLogs(forBranch: branch, limit: 8) else { return nil }
        let needle = "### \(name)"
        if let range = logs.range(of: needle) {
            let rest = logs[range.lowerBound...]
            if let next = rest.range(of: "\n### ", range: rest.index(after: rest.startIndex)..<rest.endIndex) {
                return String(rest[..<next.lowerBound])
            }
            return String(rest)
        }
        return logs
    }

    public func pullRequestSeed(number: Int) async throws -> IssueSeed {
        let output = try await run([
            "pr", "view", String(number), "--json", "number,title,body,url,headRefName",
        ])
        struct Payload: Decodable {
            var number: Int
            var title: String
            var body: String?
            var url: String
            var headRefName: String
        }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(output.standardOutput.utf8))
        return IssueSeed(
            number: payload.number,
            title: payload.title,
            body: payload.body ?? "",
            url: payload.url,
            headRefName: payload.headRefName
        )
    }

    // MARK: - Plumbing

    private func decodePullRequest(_ json: String) -> PullRequest? {
        struct Payload: Decodable {
            var number: Int
            var title: String
            var url: String
            var state: String
            var isDraft: Bool
            var baseRefName: String
            var headRefName: String
            var mergeable: String?
            var reviewDecision: String?
            var statusCheckRollup: [Rollup]?

            struct Rollup: Decodable {
                var name: String?
                var context: String?
                var status: String?
                var state: String?
                var conclusion: String?
                var detailsUrl: String?
                var targetUrl: String?
                var workflowName: String?
                var startedAt: String?
                var completedAt: String?
            }
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else {
            return nil
        }

        // The rollup mixes two shapes: check runs (status + conclusion) and
        // legacy commit statuses (state). Normalizing here keeps that out of
        // the state machine.
        let timestamps = ISO8601DateFormatter()
        let checks = (payload.statusCheckRollup ?? []).map { entry -> CheckRun in
            let state: String
            if let status = entry.status, status.uppercased() != "COMPLETED" {
                state = status
            } else {
                state = entry.conclusion ?? entry.state ?? "PENDING"
            }
            return CheckRun(
                name: entry.name ?? entry.context ?? "check",
                state: state,
                link: entry.detailsUrl ?? entry.targetUrl,
                workflow: entry.workflowName,
                startedAt: entry.startedAt.flatMap(timestamps.date(from:)),
                completedAt: entry.completedAt.flatMap(timestamps.date(from:))
            )
        }

        return PullRequest(
            number: payload.number,
            title: payload.title,
            url: payload.url,
            state: payload.state,
            isDraft: payload.isDraft,
            baseRefName: payload.baseRefName,
            headRefName: payload.headRefName,
            mergeable: payload.mergeable,
            reviewDecision: payload.reviewDecision,
            checks: checks
        )
    }

    @discardableResult
    private func run(_ arguments: [String]) async throws -> GitOutput {
        guard let executablePath else { throw GitHubError.ghNotInstalled }
        return try await GitProcess.run(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: repositoryURL,
            stdin: nil,
            environmentOverrides: ["GH_PROMPT_DISABLED": "1", "GH_PAGER": "cat"]
        )
    }
}

public enum GitHubError: Error, Sendable, CustomStringConvertible {
    case ghNotInstalled
    case notAuthenticated
    case destinationExists(String)

    public var description: String {
        switch self {
        case .ghNotInstalled:
            return "The GitHub CLI (`gh`) is not installed."
        case .notAuthenticated:
            return "`gh` is not signed in. Run `gh auth login`."
        case .destinationExists(let path):
            return "A repository already exists at \(path)."
        }
    }
}

extension GitHubError: LocalizedError {
    public var errorDescription: String? { description }
}
