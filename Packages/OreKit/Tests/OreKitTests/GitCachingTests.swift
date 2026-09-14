import Foundation
import Testing

@testable import OreGit

/// The git layer's memos. Each exists to skip processes that ran on every
/// refresh of every workspace, and each must still notice when the thing it
/// remembers moves.
struct GitCachingTests {
    private func fixtureWithOrigin() async throws -> GitFixture {
        let fixture = try await GitFixture.initialized()
        let origin = fixture.root.appendingPathComponent("origin.git", isDirectory: true)
        try await fixture.run(["init", "-q", "--bare", origin.path])
        try await fixture.run(["remote", "add", "origin", origin.path])
        try await fixture.run(["push", "-q", "origin", "main"])
        return fixture
    }

    // MARK: - Fetch coalescing

    @Test func siblingFetchesOfOneBranchShareOneNetworkFetch() async throws {
        // Every worktree of a repository starts its base sync at launch at
        // once; they used to queue one fetch each.
        let fixture = try await fixtureWithOrigin()
        let git = fixture.git
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { try? await git.fetchRemoteBranch("main") }
            }
        }
        try await git.fetchRemoteBranch("main")
        #expect(await git.remoteFetchCount == 1)
    }

    @Test func aForcedFetchAlwaysHitsTheNetwork() async throws {
        let fixture = try await fixtureWithOrigin()
        try await fixture.git.fetchRemoteBranch("main")
        try await fixture.git.fetchRemoteBranch("main", force: true)
        #expect(await fixture.git.remoteFetchCount == 2)
    }

    @Test func addingARemoteIsNoticedDespiteTheMemo() async throws {
        let fixture = try await GitFixture.initialized()
        #expect(await fixture.git.hasRemote() == false)
        #expect(await fixture.git.hasRemote() == false)
        let origin = fixture.root.appendingPathComponent("origin.git", isDirectory: true)
        try await fixture.run(["init", "-q", "--bare", origin.path])
        try await fixture.run(["remote", "add", "origin", origin.path])
        #expect(await fixture.git.hasRemote() == true)
    }

    // MARK: - Merge base

    @Test func mergeBaseIsRememberedUntilHeadOrTheBaseMoves() async throws {
        let fixture = try await GitFixture.initialized()
        let git = fixture.git
        try await fixture.run(["checkout", "-q", "-b", "feature"])
        try fixture.write("feature.txt", "work\n")
        try await fixture.run(["add", "-A"])
        try await fixture.commit("feature work")

        let initialBase = try await git.resolve("main")
        #expect(await git.mergeBase(with: "main") == initialBase)
        #expect(await git.mergeBase(with: "main") == initialBase)
        #expect(await git.commitsAheadOfBase("main") == 1)
        #expect(await git.mergeBaseComputationCount == 1)

        // The local base moves with no `origin/` ref beside it — the shape a
        // `rev-parse --revs-only` fingerprint silently stopped seeing.
        try await fixture.run(["branch", "-f", "main", "feature"])
        let head = try await git.resolve("HEAD")
        #expect(await git.mergeBase(with: "main") == head)
        #expect(await git.mergeBaseComputationCount == 2)

        try fixture.write("more.txt", "more\n")
        try await fixture.run(["add", "-A"])
        try await fixture.commit("more work")
        #expect(await git.commitsAheadOfBase("main") == 1)
        #expect(await git.mergeBaseComputationCount == 3)
    }

    // MARK: - Untracked diffs

    @Test func untrackedFilesReadDirectlyMatchGitsOwnDiff() async throws {
        let fixture = try await GitFixture.initialized()
        let cases: [(name: String, contents: Data)] = [
            ("lines.txt", Data("one\ntwo\n".utf8)),
            ("unterminated.txt", Data("one\ntwo".utf8)),
            ("single.txt", Data("only\n".utf8)),
            ("blank-lines.txt", Data("\n\nx\n".utf8)),
            ("empty.txt", Data()),
            ("binary.dat", Data([0x89, 0x50, 0x00, 0x0A, 0xFF])),
        ]
        for testCase in cases {
            try testCase.contents.write(
                to: fixture.repository.appendingPathComponent(testCase.name)
            )
            let text = try await fixture.git.run(
                [
                    "diff", "--no-color", "--no-ext-diff", "--no-index",
                    "--", "/dev/null", testCase.name,
                ],
                in: fixture.repository,
                allowedExitCodes: [0, 1]
            ).standardOutput
            let expected = try #require(UnifiedDiffParser.parse(text).first)
            let direct = DiffEngine.untrackedFileDiff(
                path: testCase.name, worktree: fixture.repository, maximumBytes: 1_000_000
            )
            #expect(direct.hunks == expected.hunks, "\(testCase.name)")
            #expect(direct.isBinary == expected.isBinary, "\(testCase.name)")
            #expect(direct.status == .untracked)
            #expect(direct.path == testCase.name)
        }
    }

    @Test func crlfLinesStaySeparate() throws {
        let fixture = try GitFixture()
        try Data("a\r\nb\r\n".utf8).write(to: fixture.repository.appendingPathComponent("dos.txt"))
        let diff = DiffEngine.untrackedFileDiff(
            path: "dos.txt", worktree: fixture.repository, maximumBytes: 1_000_000
        )
        #expect(diff.insertions == 2)
        #expect(diff.hunks.first?.newCount == 2)
    }

    @Test func anUntrackedFileOverTheLimitIsTruncatedNotRead() throws {
        let fixture = try GitFixture()
        try fixture.write("big.txt", "hello\n")
        let diff = DiffEngine.untrackedFileDiff(
            path: "big.txt", worktree: fixture.repository, maximumBytes: 3
        )
        #expect(diff.isTruncated)
        #expect(diff.hunks.isEmpty)
    }

    // MARK: - GitHub

    @Test func onlyAuthFailuresForgetTheGitHubStatus() {
        let noPullRequest = GitError.commandFailed(
            arguments: ["pr", "view"], exitCode: 1,
            message: "no pull requests found for branch \"ore/x\""
        )
        let signedOut = GitError.commandFailed(
            arguments: ["pr", "view"], exitCode: 4,
            message: "To get started with GitHub CLI, please run:  gh auth login"
        )
        #expect(!GitHubClient.invalidatesStatus(noPullRequest))
        #expect(GitHubClient.invalidatesStatus(signedOut))
        #expect(GitHubClient.isNoPullRequest(noPullRequest))
        #expect(!GitHubClient.isNoPullRequest(signedOut))
    }

    @Test func aSignedInStatusIsRememberedUntilInvalidated() {
        let cache = GitHubStateCache()
        let path = "/tests/gh"
        #expect(cache.status(for: path) == nil)
        cache.store(GitHubClient.Status(isInstalled: true, isAuthenticated: true), for: path)
        #expect(cache.status(for: path)?.isAuthenticated == true)
        cache.invalidateStatus(for: path)
        #expect(cache.status(for: path) == nil)
    }

    @Test func cachedPullRequestsExpireAndAreForgottenPerRepository() async throws {
        let cache = GitHubStateCache()
        let pullRequest = GitHubClient.PullRequest(number: 7)
        cache.store(pullRequest, for: "/repo-a\u{0}feature")
        cache.store(nil, for: "/repo-b\u{0}feature")
        #expect(
            cache.pullRequest(for: "/repo-a\u{0}feature", maxAge: .seconds(60))?.pullRequest
                == pullRequest
        )
        #expect(cache.pullRequest(for: "/repo-b\u{0}feature", maxAge: .seconds(60)) != nil)

        try await Task.sleep(for: .milliseconds(20))
        #expect(cache.pullRequest(for: "/repo-a\u{0}feature", maxAge: .milliseconds(1)) == nil)

        cache.invalidatePullRequests(withPrefix: "/repo-a\u{0}")
        #expect(cache.pullRequest(for: "/repo-a\u{0}feature", maxAge: .seconds(60)) == nil)
        #expect(cache.pullRequest(for: "/repo-b\u{0}feature", maxAge: .seconds(60)) != nil)
    }

    // MARK: - Status

    @Test func aRecentSnapshotAgreesWithThePublishedRead() async throws {
        let fixture = try await GitFixture.initialized()
        let watcher = StatusWatcher(
            git: fixture.git, worktreeURL: fixture.repository, debounce: .milliseconds(50)
        )
        var iterator = watcher.updates.makeAsyncIterator()
        try fixture.write("new.txt", "hello\n")
        await watcher.start()

        let published = try #require(await iterator.next())
        let recent = try #require(await watcher.recentSnapshot())
        #expect(recent.files.map(\.path) == published.files.map(\.path))
        #expect(recent.files.contains { $0.path == "new.txt" })

        await watcher.stop()
        #expect(await watcher.recentSnapshot() == nil)
    }
}
