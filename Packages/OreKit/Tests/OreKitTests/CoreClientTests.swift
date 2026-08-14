import Foundation
import Testing

@testable import OreCore
@testable import OreGit
@testable import OreHarness
@testable import OrePersistence
@testable import OreSupport
@testable import OreProtocol

/// Records every `CoreEvent` a client emits, so a test can wait for one
/// without racing the stream.
///
/// Draining into a buffer rather than reading the iterator inline matters:
/// `AsyncStream` has a single consumer, and a test that reads it directly both
/// steals events from other waiters and blocks forever when the event it wants
/// never arrives.
actor CoreEventRecorder {
    private var received: [CoreEvent] = []
    private nonisolated let task: Lockbox<Task<Void, Never>?> = Lockbox(nil)

    init(_ client: InProcessCoreClient) {
        let started = Task { [weak self] in
            for await event in client.events {
                await self?.append(event)
            }
        }
        task.set(started)
    }

    private func append(_ event: CoreEvent) {
        received.append(event)
    }

    func all() -> [CoreEvent] { received }

    /// The first event matching the predicate, waiting up to `timeout`.
    /// Returns nil on timeout so a failure is a failed expectation rather than
    /// a hung suite.
    func waitFor(
        timeout: Duration = .seconds(30),
        matching: (CoreEvent) -> Bool
    ) async -> CoreEvent? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var index = 0
        while ContinuousClock.now < deadline {
            while index < received.count {
                let event = received[index]
                index += 1
                if matching(event) { return event }
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    deinit { task.get()?.cancel() }
}

/// The command/event boundary is what a hosted ORE would run across, so it is
/// exercised the way a client would: send commands, read events, never touch
/// the engine directly.
struct CoreClientTests {
    /// No agent CLI is spawned: these tests are about the boundary and the
    /// git/persistence wiring, and a real harness would make them slow and
    /// dependent on a subscription.
    private func makeClient(_ fixture: GitFixture) throws -> InProcessCoreClient {
        InProcessCoreClient(
            store: try OreStore(),
            harnessRegistry: HarnessRegistry(harnesses: []),
            worktreeRoot: fixture.worktreeRoot
        )
    }

    @Test func addingARepositoryAndCreatingAWorkspaceEmitsASnapshot() async throws {
        let fixture = try await GitFixture.initialized()
        let client = try makeClient(fixture)
        let recorder = CoreEventRecorder(client)

        await client.send(.addRepository(path: fixture.repository.path))
        let snapshot = await recorder.waitFor {
            if case .snapshot = $0 { return true }
            return false
        }
        #expect(snapshot != nil)

        await client.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path,
            name: "Fix the login bug"
        )))

        let added = await recorder.waitFor {
            if case .workspaceAdded = $0 { return true }
            return false
        }
        guard case .workspaceAdded(let summary)? = added else {
            Issue.record("no workspaceAdded event")
            return
        }

        #expect(summary.name == "Fix the login bug")
        #expect(summary.branch == "ore/fix-the-login-bug")
        #expect(summary.baseBranch == "main")
        #expect(!summary.hasUnread)
        #expect(FileManager.default.fileExists(atPath: summary.worktreePath))

        await client.shutdown()
    }

    @Test func oreTomlDrivesBranchPrefixAndCopiedFiles() async throws {
        // The config is checked in so a teammate gets the project's setup
        // without being told; that only works if the core actually reads it.
        let fixture = try await GitFixture.initialized()
        try fixture.write("ore.toml", """
        [scripts]
        setup = "echo setup-ran > setup-marker.txt"

        [files]
        copy = [".env"]

        [agent]
        model = "sonnet"
        """)
        try fixture.write(".env", "SECRET=1\n")

        let client = try makeClient(fixture)
        let recorder = CoreEventRecorder(client)

        await client.send(.addRepository(path: fixture.repository.path))
        await client.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path, name: "configured"
        )))

        let added = await recorder.waitFor {
            if case .workspaceAdded = $0 { return true }
            return false
        }
        guard case .workspaceAdded(let summary)? = added else {
            Issue.record("no workspaceAdded event")
            return
        }

        let worktree = URL(fileURLWithPath: summary.worktreePath)
        #expect(fixture.read(".env", in: worktree) == "SECRET=1\n")
        #expect(summary.model == "sonnet")

        // The setup script runs in the worktree, through a login shell.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline,
              !fixture.exists("setup-marker.txt", in: worktree) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(fixture.exists("setup-marker.txt", in: worktree))

        await client.shutdown()
    }

    @Test func aMissingCopiedFileIsReportedRatherThanSwallowed() async throws {
        let fixture = try await GitFixture.initialized()
        try fixture.write("ore.toml", """
        [files]
        copy = [".env.local"]
        """)

        let client = try makeClient(fixture)
        let recorder = CoreEventRecorder(client)
        await client.send(.addRepository(path: fixture.repository.path))
        await client.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path, name: "missing env"
        )))

        let failure = await recorder.waitFor {
            if case .commandFailed = $0 { return true }
            return false
        }
        guard case .commandFailed(let details)? = failure else {
            Issue.record("a missing file must be reported")
            return
        }
        #expect(details.detail?.contains(".env.local") == true)

        await client.shutdown()
    }

    @Test func stackingAWorkspaceBranchesFromItsParentAndRecordsTheLink() async throws {
        // Stacks are the natural output of sequential agent work, so the
        // relationship has to survive a restart, not just live in the UI.
        let fixture = try await GitFixture.initialized()
        let client = try makeClient(fixture)
        let recorder = CoreEventRecorder(client)

        await client.send(.addRepository(path: fixture.repository.path))
        await client.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path, name: "lower half"
        )))
        guard case .workspaceAdded(let parent)? = await recorder.waitFor(matching: {
                if case .workspaceAdded = $0 { return true }
                return false
            }
        ) else {
            Issue.record("no parent workspace")
            return
        }

        // Commit something so the child has a distinct starting point.
        let parentWorktree = URL(fileURLWithPath: parent.worktreePath)
        try fixture.write("lower.txt", "lower\n", in: parentWorktree)
        try await fixture.run(["add", "-A"], in: parentWorktree)
        try await fixture.commit("lower half", in: parentWorktree)

        await client.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path,
            name: "upper half",
            seed: .workspace(parent.id)
        )))
        guard case .workspaceAdded(let child)? = await recorder.waitFor(matching: {
                if case .workspaceAdded(let summary) = $0 { return summary.name == "upper half" }
                return false
            }
        ) else {
            Issue.record("no child workspace")
            return
        }

        #expect(child.stackedOn == parent.id)
        #expect(child.baseBranch == parent.branch)
        // The child starts from the parent's work, not from main.
        #expect(fixture.exists("lower.txt", in: URL(fileURLWithPath: child.worktreePath)))

        await client.shutdown()
    }

    @Test func archivingPreservesWorkAndUnarchivingRestoresIt() async throws {
        let fixture = try await GitFixture.initialized()
        let client = try makeClient(fixture)
        let recorder = CoreEventRecorder(client)

        await client.send(.addRepository(path: fixture.repository.path))
        await client.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path, name: "archive me"
        )))
        guard case .workspaceAdded(let summary)? = await recorder.waitFor(matching: {
                if case .workspaceAdded = $0 { return true }
                return false
            }
        ) else {
            Issue.record("no workspace")
            return
        }

        let worktree = URL(fileURLWithPath: summary.worktreePath)
        try fixture.write("draft.txt", "half-finished\n", in: worktree)

        await client.send(.archiveWorkspace(summary.id))
        _ = await recorder.waitFor {
            if case .snapshot = $0 { return true }
            return false
        }
        #expect(!FileManager.default.fileExists(atPath: worktree.path))

        await client.send(.unarchiveWorkspace(summary.id))
        _ = await recorder.waitFor {
            if case .workspaceUpdated = $0 { return true }
            return false
        }

        // Back exactly where the user left off, not merely on the right branch.
        #expect(fixture.read("draft.txt", in: worktree) == "half-finished\n")

        await client.shutdown()
    }

    @Test func deletingAWorkspaceRemovesItsWorktreeAndCheckpointRefs() async throws {
        let fixture = try await GitFixture.initialized()
        let client = try makeClient(fixture)
        let recorder = CoreEventRecorder(client)

        await client.send(.addRepository(path: fixture.repository.path))
        await client.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path, name: "delete me"
        )))
        guard case .workspaceAdded(let summary)? = await recorder.waitFor(matching: {
                if case .workspaceAdded = $0 { return true }
                return false
            }
        ) else {
            Issue.record("no workspace")
            return
        }

        // Leave a checkpoint ref behind, so removal has something to clean up.
        let store = CheckpointStore(git: fixture.git)
        _ = try await store.capture(
            worktree: URL(fileURLWithPath: summary.worktreePath),
            workspaceID: summary.id,
            turnID: TurnID(rawValue: "t1")
        )
        #expect(try await store.list(workspaceID: summary.id).count == 1)

        await client.send(.deleteWorkspace(summary.id, deleteBranch: true))
        _ = await recorder.waitFor {
            if case .workspaceRemoved = $0 { return true }
            return false
        }

        #expect(!FileManager.default.fileExists(atPath: summary.worktreePath))
        #expect(try await store.list(workspaceID: summary.id).isEmpty)
        #expect(await !fixture.git.branchExists(summary.branch))

        await client.shutdown()
    }

    @Test func aFailedCommandIsReportedRatherThanThrown() async throws {
        // The UI gets a message it can show, not an exception it has to model.
        let fixture = try await GitFixture.initialized()
        let client = try makeClient(fixture)
        let recorder = CoreEventRecorder(client)

        await client.send(.interruptTurn(WorkspaceID(rawValue: "does-not-exist")))

        guard case .commandFailed(let failure)? = await recorder.waitFor(matching: {
                if case .commandFailed = $0 { return true }
                return false
            }
        ) else {
            Issue.record("no failure event")
            return
        }
        #expect(failure.workspaceID == WorkspaceID(rawValue: "does-not-exist"))
        #expect(failure.message.contains("does-not-exist"))

        await client.shutdown()
    }

    @Test func stateSurvivesARestart() async throws {
        // A relaunch must show the workspaces the user left, with their
        // git state, not an empty sidebar.
        let fixture = try await GitFixture.initialized()
        let databasePath = fixture.root.appendingPathComponent("ore.sqlite")

        let first = InProcessCoreClient(
            store: try OreStore(path: databasePath),
            harnessRegistry: HarnessRegistry(harnesses: []),
            worktreeRoot: fixture.worktreeRoot
        )
        let firstRecorder = CoreEventRecorder(first)
        await first.send(.addRepository(path: fixture.repository.path))
        await first.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path, name: "persistent"
        )))
        _ = await firstRecorder.waitFor {
            if case .workspaceAdded = $0 { return true }
            return false
        }
        await first.shutdown()

        let second = InProcessCoreClient(
            store: try OreStore(path: databasePath),
            harnessRegistry: HarnessRegistry(harnesses: []),
            worktreeRoot: fixture.worktreeRoot
        )
        let secondRecorder = CoreEventRecorder(second)
        try await second.start()

        guard case .snapshot(let snapshot)? = await secondRecorder.waitFor(matching: {
                if case .snapshot = $0 { return true }
                return false
            }
        ) else {
            Issue.record("no snapshot after restart")
            return
        }
        #expect(snapshot.workspaces.map(\.name) == ["persistent"])

        await second.shutdown()
    }
}

struct OreConfigurationTests {
    @Test func aTypicalConfigurationParses() {
        let configuration = OreConfiguration.parse("""
        # ORE configuration
        [scripts]
        setup = "pnpm install"
        run = "pnpm dev"
        archive = "docker compose down"

        [files]
        copy = [".env", ".env.local", "config/secrets.json"]

        [agent]
        harness = "codex"
        model = "gpt-5"
        """)

        #expect(configuration.scripts.setup == "pnpm install")
        #expect(configuration.scripts.run == "pnpm dev")
        #expect(configuration.scripts.archive == "docker compose down")
        #expect(configuration.filesToCopy == [".env", ".env.local", "config/secrets.json"])
        #expect(configuration.defaultHarness == .codex)
        #expect(configuration.defaultModel == "gpt-5")
    }

    @Test func arraysMaySpanSeveralLines() {
        let configuration = OreConfiguration.parse("""
        [files]
        copy = [
          ".env",
          ".env.local",
        ]
        """)
        #expect(configuration.filesToCopy == [".env", ".env.local"])
    }

    @Test func commentsAndBlankLinesAreIgnoredButNotInsideStrings() {
        let configuration = OreConfiguration.parse("""
        # a comment

        [scripts]
        setup = "echo hi"   # trailing comment
        run = "echo '#1 build'"
        """)
        #expect(configuration.scripts.setup == "echo hi")
        #expect(configuration.scripts.run == "echo '#1 build'")
    }

    @Test func anUnreadableOrMalformedFileYieldsDefaults() {
        // A config error must not stop someone opening their project.
        let configuration = OreConfiguration.parse("this is not toml at all {{{")
        #expect(configuration.scripts.setup == nil)
        #expect(configuration.filesToCopy.isEmpty)
        #expect(configuration.branchPrefix == "ore")

        let missing = OreConfiguration.load(
            repositoryPath: URL(fileURLWithPath: "/definitely/not/here")
        )
        #expect(missing.branchPrefix == "ore")
    }

    @Test func unknownKeysAreSkippedRatherThanRejected() {
        // A config written for a newer ORE must still open in an older one.
        let configuration = OreConfiguration.parse("""
        [scripts]
        setup = "make"
        teleport = "not a thing yet"

        [futureFeature]
        enabled = true
        """)
        #expect(configuration.scripts.setup == "make")
    }

    @Test func configurationRoundTripsThroughTOML() {
        let original = OreConfiguration(
            scripts: .init(setup: "pnpm install", run: "pnpm dev"),
            filesToCopy: [".env"],
            defaultHarness: .claudeCode,
            defaultModel: "opus"
        )
        let parsed = OreConfiguration.parse(original.toTOML())

        #expect(parsed.scripts.setup == original.scripts.setup)
        #expect(parsed.scripts.run == original.scripts.run)
        #expect(parsed.filesToCopy == original.filesToCopy)
        #expect(parsed.defaultHarness == original.defaultHarness)
        #expect(parsed.defaultModel == original.defaultModel)
    }

    @Test func escapedCharactersSurviveTheRoundTrip() {
        let original = OreConfiguration(
            scripts: .init(setup: #"echo "hello" && cd C:\path"#)
        )
        #expect(OreConfiguration.parse(original.toTOML()).scripts.setup == original.scripts.setup)
    }
}

struct HarnessRegistryTests {
    @Test func experimentalHarnessesAreHiddenUnlessEnabled() {
        // Shipping an unstable harness silently would mean a user's session
        // failing in ways they can't attribute.
        let disabled = HarnessRegistry.standard()
        #expect(disabled.harness(for: .cursorAgent) == nil)
        #expect(disabled.available.allSatisfy { !$0.kind.isExperimental })

        let enabled = HarnessRegistry(
            harnesses: [ClaudeCodeHarness(), CodexHarness(), CursorAgentHarness()],
            enabledExperimental: [.cursorAgent]
        )
        #expect(enabled.harness(for: .cursorAgent) != nil)
        #expect(enabled.available.count == 3)
    }

    @Test func theStandardRegistryShipsClaudeAndCodex() {
        let registry = HarnessRegistry.standard()
        #expect(registry.harness(for: .claudeCode) != nil)
        #expect(registry.harness(for: .codex) != nil)
    }
}
