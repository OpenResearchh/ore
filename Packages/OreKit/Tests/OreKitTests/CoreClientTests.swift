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

    func checkpoint() -> Int { received.count }

    func all(after checkpoint: Int) -> [CoreEvent] {
        guard checkpoint < received.count else { return [] }
        return Array(received[checkpoint...])
    }

    /// The first event matching the predicate, waiting up to `timeout`.
    /// Returns nil on timeout so a failure is a failed expectation rather than
    /// a hung suite.
    func waitFor(
        after checkpoint: Int = 0,
        timeout: Duration = .seconds(30),
        matching: (CoreEvent) -> Bool
    ) async -> CoreEvent? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var index = checkpoint
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

#if DEBUG
private actor SnapshotEmissionGate {
    private var isPaused = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        isPaused = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilPaused() async {
        while !isPaused {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
#endif

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

    /// A folder that is not a repository used to be accepted: the sidebar got
    /// an entry that looked like every other project, and the mistake only
    /// surfaced as a raw git command line when the first workspace was
    /// attempted, several screens later.
    @Test func addingAFolderThatIsNotARepositoryFailsImmediately() async throws {
        let fixture = try await GitFixture.initialized()
        let plain = fixture.root.appendingPathComponent("just-a-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        let store = try OreStore()
        let client = InProcessCoreClient(
            store: store,
            harnessRegistry: HarnessRegistry(harnesses: []),
            worktreeRoot: fixture.worktreeRoot
        )
        let recorder = CoreEventRecorder(client)

        await client.send(.addRepository(path: plain.path))

        guard case .commandFailed(let failure)? = await recorder.waitFor(matching: {
            if case .commandFailed = $0 { return true }
            return false
        }) else {
            Issue.record("adding a non-repository must be reported")
            return
        }
        #expect(failure.detail?.contains("not a git repository") == true)
        #expect(try await store.repositories().isEmpty, "nothing may be registered")

        await client.shutdown()
    }

    /// `git init` with no commit yet. It is a real repository, so the
    /// not-a-repository check passes — but it has no HEAD, and `git worktree
    /// add` fails on it with "invalid reference: HEAD", which tells the user
    /// nothing about what to do.
    @Test func addingARepositoryWithNoCommitsSaysSoInsteadOfFailingLater() async throws {
        let fixture = try await GitFixture.initialized()
        let empty = fixture.root.appendingPathComponent("unborn", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let git = try GitClient(repositoryURL: empty)
        try await git.run(["init", "-q", "-b", "main"], in: empty)

        let store = try OreStore()
        let client = InProcessCoreClient(
            store: store,
            harnessRegistry: HarnessRegistry(harnesses: []),
            worktreeRoot: fixture.worktreeRoot
        )
        let recorder = CoreEventRecorder(client)

        await client.send(.addRepository(path: empty.path))

        guard case .commandFailed(let failure)? = await recorder.waitFor(matching: {
            if case .commandFailed = $0 { return true }
            return false
        }) else {
            Issue.record("an unborn repository must be reported")
            return
        }
        #expect(failure.detail?.contains("no commits yet") == true)
        #expect(try await store.repositories().isEmpty)

        await client.shutdown()
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

    @Test func hidingTheHostReachesEveryEngineAndTheOnesMadeMeanwhile() async throws {
        let fixture = try await GitFixture.initialized()
        let client = try makeClient(fixture)
        let recorder = CoreEventRecorder(client)

        await client.send(.addRepository(path: fixture.repository.path))
        await client.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path, name: "first"
        )))
        guard case .workspaceAdded(let first)? = await recorder.waitFor(matching: {
            if case .workspaceAdded = $0 { return true }
            return false
        }) else {
            Issue.record("no workspaceAdded event")
            return
        }
        let firstEngine = try await client.engine(for: first.id)
        #expect(await firstEngine.backgroundPollingEnabled)

        await client.setBackgroundPollingEnabled(false)
        #expect(await !firstEngine.backgroundPollingEnabled)

        // An engine created while hidden must not start polling on its own.
        let checkpoint = await recorder.checkpoint()
        await client.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path, name: "second"
        )))
        guard case .workspaceAdded(let second)? = await recorder.waitFor(
            after: checkpoint,
            matching: {
                if case .workspaceAdded = $0 { return true }
                return false
            }
        ) else {
            Issue.record("no second workspaceAdded event")
            return
        }
        let secondEngine = try await client.engine(for: second.id)
        #expect(await !secondEngine.backgroundPollingEnabled)

        await client.setBackgroundPollingEnabled(true)
        #expect(await firstEngine.backgroundPollingEnabled)
        #expect(await secondEngine.backgroundPollingEnabled)

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

        // The script is repository content — after a clone, someone else's —
        // so the approval request takes the place of running it.
        guard case .repositoryScriptsNeedApproval(let approval)? = await recorder.waitFor(matching: {
            if case .repositoryScriptsNeedApproval = $0 { return true }
            return false
        }) else {
            Issue.record("an unapproved setup script must ask before it runs")
            return
        }
        #expect(approval.setup == "echo setup-ran > setup-marker.txt")
        #expect(!fixture.exists("setup-marker.txt", in: worktree))

        // Once allowed, it runs in the worktree, through a login shell.
        await client.send(.approveRepositoryScripts(approval))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline,
              !fixture.exists("setup-marker.txt", in: worktree) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(fixture.exists("setup-marker.txt", in: worktree))

        await client.shutdown()
    }

    @Test func anApprovalOnlyCoversTheScriptTheUserWasShown() async throws {
        // An ore.toml edited while the prompt was open must not inherit the
        // approval: nothing runs, and the new text is asked about instead.
        let fixture = try await GitFixture.initialized()
        try fixture.write("ore.toml", """
        [scripts]
        setup = "echo first > marker.txt"
        """)
        let client = try makeClient(fixture)
        let recorder = CoreEventRecorder(client)
        await client.send(.addRepository(path: fixture.repository.path))
        await client.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path, name: "edited"
        )))

        guard case .workspaceAdded(let summary)? = await recorder.waitFor(matching: {
            if case .workspaceAdded = $0 { return true }
            return false
        }), case .repositoryScriptsNeedApproval(let shown)? = await recorder.waitFor(matching: {
            if case .repositoryScriptsNeedApproval = $0 { return true }
            return false
        }) else {
            Issue.record("expected the workspace and an approval request")
            return
        }
        let worktree = URL(fileURLWithPath: summary.worktreePath)

        try fixture.write("ore.toml", """
        [scripts]
        setup = "echo second > marker.txt"
        """)
        let checkpoint = await recorder.checkpoint()
        await client.send(.approveRepositoryScripts(shown))

        guard case .repositoryScriptsNeedApproval(let again)? = await recorder.waitFor(
            after: checkpoint,
            matching: {
                if case .repositoryScriptsNeedApproval = $0 { return true }
                return false
            }
        ) else {
            Issue.record("an edited script must be asked about again")
            return
        }
        #expect(again.setup == "echo second > marker.txt")
        #expect(!fixture.exists("marker.txt", in: worktree))

        await client.shutdown()
    }

    @Test func aRunScriptWaitsForApprovalBeforeCommandR() async throws {
        // ⌘R runs ore.toml's run script as the user, so it is approved like
        // setup and archive. Allowing it from the terminal doesn't run setup.
        let fixture = try await GitFixture.initialized()
        try fixture.write("ore.toml", """
        [scripts]
        setup = "echo setup > setup-marker.txt"
        run = "echo serving"
        """)
        let client = try makeClient(fixture)
        let recorder = CoreEventRecorder(client)
        await client.send(.addRepository(path: fixture.repository.path))
        await client.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path, name: "runner"
        )))

        guard case .workspaceAdded(let summary)? = await recorder.waitFor(matching: {
            if case .workspaceAdded = $0 { return true }
            return false
        }), case .repositoryScriptsNeedApproval(let shown)? = await recorder.waitFor(matching: {
            if case .repositoryScriptsNeedApproval = $0 { return true }
            return false
        }) else {
            Issue.record("expected the workspace and an approval request")
            return
        }
        #expect(shown.run == "echo serving")

        let unapproved = try await client.workspaceEnvironment(workspaceID: summary.id)
        #expect(unapproved.runScript == "echo serving")
        let request = try #require(unapproved.runScriptApproval)
        #expect(!request.runsSetup)

        await client.send(.approveRepositoryScripts(request))
        var environment = unapproved
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline, environment.runScriptApproval != nil {
            try? await Task.sleep(for: .milliseconds(100))
            environment = try await client.workspaceEnvironment(workspaceID: summary.id)
        }
        #expect(environment.runScriptApproval == nil)
        #expect(!fixture.exists("setup-marker.txt", in: URL(fileURLWithPath: summary.worktreePath)))

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

        let archiveCheckpoint = await recorder.checkpoint()
        await client.send(.archiveWorkspace(summary.id))
        let archived = await recorder.waitFor(after: archiveCheckpoint) {
            if case .workspaceUpdated(let update) = $0 {
                return update.id == summary.id && update.isArchived
            }
            return false
        }
        #expect(archived != nil)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))

        let unarchiveCheckpoint = await recorder.checkpoint()
        await client.send(.unarchiveWorkspace(summary.id))
        let unarchived = await recorder.waitFor(after: unarchiveCheckpoint) {
            if case .workspaceUpdated(let update) = $0 {
                return update.id == summary.id && !update.isArchived
            }
            return false
        }
        #expect(unarchived != nil)

        // Back exactly where the user left off, not merely on the right branch.
        #expect(fixture.read("draft.txt", in: worktree) == "half-finished\n")

        await client.shutdown()
    }

    @Test func aFailedArchiveDoesNotPublishAWorkspaceListMutation() async throws {
        let fixture = try await GitFixture.initialized()
        let client = try makeClient(fixture)
        let recorder = CoreEventRecorder(client)
        let missing = WorkspaceID(rawValue: "missing-archive")
        let checkpoint = await recorder.checkpoint()

        await client.send(.archiveWorkspace(missing))

        let failure = await recorder.waitFor(after: checkpoint) { event in
            if case .commandFailed(let failure) = event {
                return failure.workspaceID == missing
            }
            return false
        }
        #expect(failure != nil)
        let events = await recorder.all(after: checkpoint)
        #expect(!events.contains { event in
            switch event {
            case .workspaceAdded(let summary), .workspaceUpdated(let summary):
                summary.id == missing
            case .workspaceRemoved(let id):
                id == missing
            default:
                false
            }
        })

        await client.shutdown()
    }

    #if DEBUG
    @Test func aSnapshotStartedBeforeArchiveCannotOverwriteTheArchiveEvent() async throws {
        let fixture = try await GitFixture.initialized()
        let client = try makeClient(fixture)
        let recorder = CoreEventRecorder(client)

        await client.send(.addRepository(path: fixture.repository.path))
        await client.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path, name: "race archive"
        )))
        guard case .workspaceAdded(let workspace)? = await recorder.waitFor(matching: {
            if case .workspaceAdded = $0 { return true }
            return false
        }) else {
            Issue.record("no workspace")
            return
        }

        let gate = SnapshotEmissionGate()
        await client.pauseBeforeNextSnapshotEmission { await gate.pause() }
        let checkpoint = await recorder.checkpoint()
        let staleRead = Task { await client.send(.resync(nil)) }
        await gate.waitUntilPaused()

        await client.send(.archiveWorkspace(workspace.id))
        let archived = await recorder.waitFor(after: checkpoint) { event in
            if case .workspaceUpdated(let summary) = event {
                return summary.id == workspace.id && summary.isArchived
            }
            return false
        }
        #expect(archived != nil)

        await gate.resume()
        await staleRead.value
        let refreshed = await recorder.waitFor(after: checkpoint) { event in
            guard case .snapshot(let snapshot) = event else { return false }
            return snapshot.workspaces.contains { $0.id == workspace.id && $0.isArchived }
        }
        #expect(refreshed != nil)

        let events = await recorder.all(after: checkpoint)
        #expect(!events.contains { event in
            guard case .snapshot(let snapshot) = event else { return false }
            return snapshot.workspaces.contains { $0.id == workspace.id && !$0.isArchived }
        })

        await client.shutdown()
    }
    #endif

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

        await client.send(.interruptChatTurn(WorkspaceID(rawValue: "does-not-exist"), ChatID(rawValue: "missing")))

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
        // The assistant workspace rides the snapshot too (tagged by kind, for
        // the Assistant window); the user's own list is everything else.
        #expect(snapshot.workspaces.filter { !$0.isAssistant }.map(\.name) == ["persistent"])

        await second.shutdown()
    }

    @Test func theAssistantWorkspaceIsCreatedHiddenAndProtected() async throws {
        let fixture = try await GitFixture.initialized()
        let databasePath = fixture.root.appendingPathComponent("ore.sqlite")
        let store = try OreStore(path: databasePath)
        let client = InProcessCoreClient(
            store: store,
            harnessRegistry: HarnessRegistry(harnesses: []),
            worktreeRoot: fixture.worktreeRoot
        )
        let recorder = CoreEventRecorder(client)
        try await client.start()

        // The home is created beside the database — a scratch ORE_HOME or a
        // test fixture never touches the real one.
        let home = fixture.root.appendingPathComponent("assistant")
        #expect(FileManager.default.fileExists(
            atPath: home.appendingPathComponent("MEMORY.md").path
        ))

        // Present in the store, absent from the user's lists and pickers.
        let assistant = try #require(try await store.assistantWorkspace())
        #expect(assistant.workspaceKind == .assistant)
        #expect(assistant.model == AssistantManager.defaultModel)
        let assistantChat = try #require(
            try await store.chats(workspaceID: assistant.workspaceID).first
        )
        #expect(assistantChat.model == AssistantManager.defaultModel)
        #expect(try await store.workspaces(includeArchived: true).isEmpty)
        #expect(try await store.repositories().isEmpty)

        // In the snapshot, tagged so the app routes it away from the sidebar.
        guard case .snapshot(let snapshot)? = await recorder.waitFor(matching: {
            if case .snapshot = $0 { return true }
            return false
        }) else {
            Issue.record("no snapshot")
            return
        }
        #expect(snapshot.workspaces.first { $0.isAssistant }?.name == "Assistant")

        // Destructive commands must bounce off it.
        await client.send(.deleteWorkspace(assistant.workspaceID, deleteBranch: false))
        _ = await recorder.waitFor {
            if case .commandFailed = $0 { return true }
            return false
        }
        #expect(try await store.assistantWorkspace() != nil)

        await client.shutdown()
    }

    @Test func ensureAssistantIsIdempotentAndRecoversAMisTaggedHome() async throws {
        let fixture = try await GitFixture.initialized()
        let databasePath = fixture.root.appendingPathComponent("ore.sqlite")
        let store = try OreStore(path: databasePath)

        let first = try #require(try await AssistantManager.ensureAssistant(store: store))
        let second = try #require(try await AssistantManager.ensureAssistant(store: store))
        #expect(first.workspaceID == second.workspaceID)
        #expect(try await store.chats(workspaceID: first.workspaceID).count == 1)
        #expect(try await store.workspaces(includeArchived: true, includeAssistant: true).count == 1)

        _ = try await store.updateWorkspace(first.workspaceID) {
            $0.kind = WorkspaceKind.standard.rawValue
        }
        #expect(try await store.assistantWorkspace() == nil)

        let recovered = try #require(try await AssistantManager.ensureAssistant(store: store))
        #expect(recovered.workspaceID == first.workspaceID)
        #expect(recovered.workspaceKind == .assistant)
        #expect(try await store.chats(workspaceID: recovered.workspaceID).count == 1)
        #expect(try await store.workspaces(includeArchived: true, includeAssistant: true).count == 1)
        #expect(try await store.assistantWorkspace()?.workspaceID == first.workspaceID)
    }

    @Test func restartingTheCoreReusesTheAssistantAndDoesNotMintProjects() async throws {
        let fixture = try await GitFixture.initialized()
        let databasePath = fixture.root.appendingPathComponent("ore.sqlite")
        let firstStore = try OreStore(path: databasePath)

        let first = InProcessCoreClient(
            store: firstStore,
            harnessRegistry: HarnessRegistry(harnesses: []),
            worktreeRoot: fixture.worktreeRoot
        )
        let firstRecorder = CoreEventRecorder(first)
        try await first.start()
        await first.send(.addRepository(path: fixture.repository.path))
        await first.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path, name: "persistent"
        )))
        _ = await firstRecorder.waitFor {
            if case .workspaceAdded = $0 { return true }
            return false
        }

        let assistantID = try #require(try await firstStore.assistantWorkspace()).workspaceID
        let assistantChatIDs = try await firstStore.chats(workspaceID: assistantID).map(\.id)
        let userWorkspaceIDs = try await firstStore.workspaces().map(\.id)
        #expect(assistantChatIDs.count == 1)
        #expect(userWorkspaceIDs.count == 1)
        await first.shutdown()

        let store = try OreStore(path: databasePath)
        let second = InProcessCoreClient(
            store: store,
            harnessRegistry: HarnessRegistry(harnesses: []),
            worktreeRoot: fixture.worktreeRoot
        )
        let secondRecorder = CoreEventRecorder(second)
        try await second.start()

        let assistantAfter = try #require(try await store.assistantWorkspace())
        #expect(assistantAfter.workspaceID == assistantID)
        #expect(try await store.chats(workspaceID: assistantAfter.workspaceID).map(\.id)
            == assistantChatIDs)
        #expect(try await store.workspaces().map(\.id) == userWorkspaceIDs)
        #expect(try await store.workspaces(includeArchived: true, includeAssistant: true).count == 2)

        await second.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path, name: "second-project"
        )))
        _ = await secondRecorder.waitFor {
            if case .workspaceAdded(let summary) = $0 { return summary.name == "second-project" }
            return false
        }
        #expect(try await store.workspaces().count == 2)
        #expect(try await store.assistantWorkspace()?.workspaceID == assistantID)

        await second.shutdown()
    }

    @Test func startupDownshiftsOnlyTheAssistantToTheLeanHarnessProfile() async throws {
        let fixture = try await GitFixture.initialized()
        let databasePath = fixture.root.appendingPathComponent("ore.sqlite")
        let store = try OreStore(path: databasePath)
        let assistant = try #require(try await AssistantManager.ensureAssistant(store: store))
        var assistantChat = try #require(
            try await store.chats(workspaceID: assistant.workspaceID).first
        )
        assistantChat.harness = HarnessKind.codex.rawValue
        assistantChat.model = "gpt-5.6-sol"
        assistantChat.reasoningEffort = ReasoningEffort.xhigh.rawValue
        try await store.saveChat(assistantChat)
        let secondAssistantChatID = ChatID.generate()
        try await store.saveChat(ChatRecord(
            id: secondAssistantChatID,
            workspaceID: assistant.workspaceID,
            title: "Another open conversation",
            harness: .codex,
            model: "gpt-5.6-sol",
            sortIndex: 1,
            reasoningEffort: .xhigh
        ))

        // A project chat can intentionally use Sol. Assistant reconciliation
        // must never turn a fleet-wide cost policy into a project-model change.
        try await store.addRepository(RepositoryRecord(
            path: fixture.repository.path,
            name: "project",
            defaultBranch: "main"
        ))
        let projectID = WorkspaceID.generate()
        try await store.saveWorkspace(WorkspaceRecord(
            id: projectID,
            name: "Project",
            repositoryPath: fixture.repository.path,
            worktreePath: fixture.repository.path,
            branch: "main",
            baseBranch: "main",
            harness: .codex,
            model: "gpt-5.6-sol"
        ))
        let projectChatID = ChatID(rawValue: projectID.rawValue)
        try await store.saveChat(ChatRecord(
            id: projectChatID,
            workspaceID: projectID,
            title: "Project",
            harness: .codex,
            model: "gpt-5.6-sol"
        ))

        let client = InProcessCoreClient(
            store: store,
            harnessRegistry: HarnessRegistry(harnesses: [FakeHarness(
                kind: .codex,
                models: [AgentModel(
                    id: "gpt-5.6-sol", displayName: "Sol", isDefault: true
                )]
            )]),
            worktreeRoot: fixture.worktreeRoot
        )
        let recorder = CoreEventRecorder(client)
        try await client.start()

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var migrated: ChatRecord?
        var secondMigrated: ChatRecord?
        // Wait for the effort too, not just the model. `moveAssistant` writes
        // them with two separate engine calls — `switchHarness` then
        // `setEffort` — so a loop that stops at the model can read the row in
        // the gap between them and see the old effort. That is a race in this
        // wait condition, not in the downshift.
        while ContinuousClock.now < deadline {
            migrated = try await store.chat(assistantChat.chatID)
            secondMigrated = try await store.chat(secondAssistantChatID)
            let settled = [migrated, secondMigrated].allSatisfy {
                $0?.model == "gpt-5.6-luna"
                    && $0?.reasoningEffort == ReasoningEffort.low.rawValue
            }
            if settled { break }
            try? await Task.sleep(for: .milliseconds(25))
        }

        #expect(migrated?.harness == HarnessKind.codex.rawValue)
        #expect(migrated?.model == "gpt-5.6-luna")
        #expect(migrated?.reasoningEffort == ReasoningEffort.low.rawValue)
        #expect(secondMigrated?.harness == HarnessKind.codex.rawValue)
        #expect(secondMigrated?.model == "gpt-5.6-luna")
        #expect(secondMigrated?.reasoningEffort == ReasoningEffort.low.rawValue)
        #expect(try await store.chat(projectChatID)?.model == "gpt-5.6-sol")
        let warning = await recorder.waitFor { event in
            if case .commandFailed(let failure) = event {
                return failure.message == "The Assistant's lean model is unavailable."
            }
            return false
        }
        #expect(warning != nil)

        await client.shutdown()
    }
}

struct AssistantModelPolicyTests {
    @Test func everyHarnessHasAnExplicitLeanAssistantProfile() {
        #expect(AssistantManager.modelProfile(for: .claudeCode) == .init(
            model: "claude-haiku-4-5-20251001",
            reasoningEffort: nil
        ))
        #expect(AssistantManager.modelProfile(for: .codex) == .init(
            model: "gpt-5.6-luna",
            reasoningEffort: .low
        ))
        #expect(AssistantManager.modelProfile(for: .cursorAgent) == .init(
            model: "composer-2.5",
            reasoningEffort: nil
        ))
    }

    @Test func aLiveCatalogCannotSilentlyPromoteTheAssistantToItsDefault() {
        let frontierOnly: [HarnessKind: [AgentModel]] = [
            .codex: [AgentModel(
                id: "gpt-5.6-sol", displayName: "Sol", isDefault: true
            )],
        ]
        #expect(InProcessCoreClient.assistantProfile(
            for: .codex,
            catalog: frontierOnly
        )?.model == nil)

        let withLuna: [HarnessKind: [AgentModel]] = [
            .codex: [
                AgentModel(id: "gpt-5.6-sol", displayName: "Sol", isDefault: true),
                AgentModel(id: "gpt-5.6-luna", displayName: "Luna"),
            ],
        ]
        #expect(InProcessCoreClient.assistantProfile(
            for: .codex,
            catalog: withLuna
        )?.model == "gpt-5.6-luna")
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
            defaultModel: "opus",
            branchPrefix: "feat"
        )
        let parsed = OreConfiguration.parse(original.toTOML())

        #expect(parsed.scripts.setup == original.scripts.setup)
        #expect(parsed.scripts.run == original.scripts.run)
        #expect(parsed.filesToCopy == original.filesToCopy)
        #expect(parsed.defaultHarness == original.defaultHarness)
        #expect(parsed.defaultModel == original.defaultModel)
        #expect(parsed.branchPrefix == "feat")
    }

    @Test func escapedCharactersSurviveTheRoundTrip() {
        let original = OreConfiguration(
            scripts: .init(setup: #"echo "hello" && cd C:\path"#)
        )
        #expect(OreConfiguration.parse(original.toTOML()).scripts.setup == original.scripts.setup)
    }
}

struct HarnessRegistryTests {
    @Test func experimentalHarnessesCanStillBeDisabledByRegistryPolicy() {
        let disabled = HarnessRegistry.standard(enabledExperimental: [])
        #expect(disabled.harness(for: .cursorAgent) == nil)
        #expect(disabled.available.allSatisfy { !$0.kind.isExperimental })

        let enabled = HarnessRegistry(
            harnesses: [ClaudeCodeHarness(), CodexHarness(), CursorAgentHarness()],
            enabledExperimental: [.cursorAgent]
        )
        #expect(enabled.harness(for: .cursorAgent) != nil)
        #expect(enabled.available.count == 3)
    }

    @Test func theStandardRegistryShipsEverySupportedAgent() {
        let registry = HarnessRegistry.standard()
        #expect(registry.harness(for: .claudeCode) != nil)
        #expect(registry.harness(for: .codex) != nil)
        #expect(registry.harness(for: .cursorAgent) != nil)
    }

    @Test func disabledExperimentalHarnessesAreDetectedButNotReady() async throws {
        let cursor = FakeHarness(kind: .cursorAgent)
        let disabled = HarnessRegistry(harnesses: [cursor])
        let disabledProbe = try #require(await disabled.probeAll().first)

        #expect(disabledProbe.isInstalled)
        #expect(disabledProbe.isEnabled == false)
        #expect(!disabledProbe.isReady)
        #expect(disabled.harness(for: .cursorAgent) == nil)

        let enabled = HarnessRegistry(
            harnesses: [cursor], enabledExperimental: [.cursorAgent]
        )
        let enabledProbe = try #require(await enabled.probeAll().first)
        #expect(enabledProbe.isEnabled == true)
        #expect(enabledProbe.isReady)
    }
}
