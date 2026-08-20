import Foundation
import Testing

@testable import OreCore
@testable import OreGit
@testable import OreHarness
@testable import OrePersistence
@testable import OreProtocol

/// A prompt the assistant sends never passes through a composer, so the only
/// way a window learns about it is the engine saying so. And "the assistant
/// started this" is not recoverable from the text, so it has to be stored.
struct PromptOriginTests {
    private func makeEngine() async throws -> (
        store: OreStore, engine: WorkspaceEngine, fake: FakeHarness, id: WorkspaceID
    ) {
        let fixture = try await GitFixture.initialized()
        let store = try OreStore()
        try await store.addRepository(RepositoryRecord(
            path: fixture.repository.path, name: "repo", defaultBranch: "main"
        ))
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)
        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "origin", baseRevision: "main", baseBranch: "main"
        ))
        let record = WorkspaceRecord(
            id: WorkspaceID.generate(),
            name: "origin",
            repositoryPath: fixture.repository.path,
            worktreePath: worktree.path.path,
            branch: worktree.branch,
            baseBranch: "main",
            harness: .claudeCode
        )
        try await store.saveWorkspace(record)
        let fake = FakeHarness()
        let engine = WorkspaceEngine(
            record: record,
            store: store,
            git: fixture.git,
            harnessRegistry: HarnessRegistry(harnesses: [fake])
        )
        return (store, engine, fake, record.workspaceID)
    }

    /// Collects submissions off the stream so a test can assert on what a
    /// client would have been told.
    private actor Collected {
        private var items: [PromptSubmission] = []
        func append(_ item: PromptSubmission) { items.append(item) }
        var all: [PromptSubmission] { items }
    }

    @Test func theEngineAnnouncesEveryPromptItAccepts() async throws {
        let (_, engine, _, id) = try await makeEngine()
        let collected = Collected()
        let stream = await engine.promptSubmissions()
        let watcher = Task {
            for await routed in stream { await collected.append(routed.submission) }
        }
        defer { watcher.cancel() }

        _ = try await engine.send(SendMessageRequest(
            workspaceID: id, text: "audit the payment retry path",
            origin: .agent, submissionID: "sub-1"
        ))
        _ = await waitUntil { await collected.all.count == 1 }

        let announced = try #require(await collected.all.first)
        #expect(announced.text == "audit the payment retry path")
        #expect(announced.origin == .agent)
        #expect(announced.submissionID == "sub-1")
        #expect(!announced.isQueued)
    }

    @Test func anAssistantPromptIsStoredAsTheAssistants() async throws {
        let (store, engine, fake, id) = try await makeEngine()

        _ = try await engine.send(SendMessageRequest(
            workspaceID: id, text: "bump the dependency", origin: .agent
        ))
        let session = try #require(fake.latestSession)
        session.emit(.turnStarted(TurnStarted(turnID: TurnID(rawValue: "t1"))))
        let chatID = ChatID(rawValue: id.rawValue)
        _ = try await waitUntil { try await store.turns(chatID: chatID).count == 1 }

        #expect(try await store.turns(chatID: chatID).first?.origin == .agent)

        // Completing the turn rewrites the record as a whole. The origin has to
        // survive that, or a finished turn relabels itself as the user's.
        session.emit(.turnCompleted(TurnResult(
            turnID: TurnID(rawValue: "t1"), outcome: .completed
        )))
        _ = try await waitUntil { try await store.turns(chatID: chatID).first?.endedAt != nil }
        #expect(try await store.turns(chatID: chatID).first?.origin == .agent)
    }

    @Test func aPromptTheUserTypedStaysTheUsers() async throws {
        let (store, engine, fake, id) = try await makeEngine()

        _ = try await engine.send(SendMessageRequest(workspaceID: id, text: "hello"))
        let session = try #require(fake.latestSession)
        session.emit(.turnStarted(TurnStarted(turnID: TurnID(rawValue: "t1"))))
        let chatID = ChatID(rawValue: id.rawValue)
        _ = try await waitUntil { try await store.turns(chatID: chatID).count == 1 }

        #expect(try await store.turns(chatID: chatID).first?.origin == .user)
    }

    // An assistant prompt that arrives mid-turn waits in the queue. Both the
    // origin and the id it was drawn under have to come back out, or the client
    // draws the drained message a second time and labels it as the user's.
    @Test func theQueueGivesBackTheOriginAndTheIdItWasGiven() async throws {
        let (store, engine, fake, id) = try await makeEngine()
        let collected = Collected()
        let stream = await engine.promptSubmissions()
        let watcher = Task {
            for await routed in stream { await collected.append(routed.submission) }
        }
        defer { watcher.cancel() }

        _ = try await engine.send(SendMessageRequest(workspaceID: id, text: "first"))
        let session = try #require(fake.latestSession)
        session.emit(.turnStarted(TurnStarted(turnID: TurnID(rawValue: "t1"))))
        try await Task.sleep(for: .milliseconds(150))

        let delivered = try await engine.send(SendMessageRequest(
            workspaceID: id, text: "and then this", origin: .agent, submissionID: "sub-9"
        ))
        #expect(delivered == false, "a prompt sent mid-turn queues")

        let queued = try #require(try await store.queuedMessages(workspaceID: id).first)
        #expect(queued.messageOrigin == .agent)
        #expect(queued.submissionID == "sub-9")

        _ = await waitUntil { await collected.all.count == 2 }
        #expect(await collected.all[1].isQueued, "announced as waiting, not as sent")

        session.emit(.turnCompleted(TurnResult(
            turnID: TurnID(rawValue: "t1"), outcome: .completed
        )))
        _ = await waitUntil { await session.messageTexts().count == 2 }
        _ = await waitUntil { await collected.all.count == 3 }

        let drained = try #require(await collected.all.last)
        #expect(drained.origin == .agent, "the wait must not launder who sent it")
        #expect(
            drained.submissionID == "sub-9",
            "same id as the queued row, so the client recognises it instead of duplicating"
        )
        #expect(!drained.isQueued)
    }
}
