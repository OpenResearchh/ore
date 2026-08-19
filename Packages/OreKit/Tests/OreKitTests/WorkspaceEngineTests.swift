import Foundation
import Testing

@testable import OreCore
@testable import OreGit
@testable import OreHarness
@testable import OrePersistence
@testable import OreProtocol

/// Waits for a condition instead of guessing how long it takes.
///
/// A fixed `Task.sleep` has to be long enough for the slowest machine that will
/// ever run it, which makes it both slow everywhere and still flaky on a loaded
/// CI runner. Polling returns as soon as the work lands and only spends the
/// full timeout when something is genuinely wrong.
func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: () async throws -> Bool
) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return try await condition()
}

/// The engine's job is wiring: checkpoints around turns, the message queue,
/// unread derivation, revert. A scripted harness makes the agent's behaviour an
/// input, so these test the wiring rather than a model's output.
struct WorkspaceEngineTests {
    private struct Harness {
        var fixture: GitFixture
        var store: OreStore
        var engine: WorkspaceEngine
        var harness: FakeHarness
        var workspaceID: WorkspaceID
        var worktree: URL
    }

    private func makeEngine(harnesses suppliedHarnesses: [FakeHarness]? = nil) async throws -> Harness {
        let fixture = try await GitFixture.initialized()
        let store = try OreStore()
        try await store.addRepository(RepositoryRecord(
            path: fixture.repository.path, name: "repo", defaultBranch: "main"
        ))

        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)
        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "engine", baseRevision: "main", baseBranch: "main"
        ))

        let record = WorkspaceRecord(
            id: WorkspaceID.generate(),
            name: "engine",
            repositoryPath: fixture.repository.path,
            worktreePath: worktree.path.path,
            branch: worktree.branch,
            baseBranch: "main",
            harness: .claudeCode
        )
        try await store.saveWorkspace(record)

        let fake = suppliedHarnesses?.first ?? FakeHarness()
        let engine = WorkspaceEngine(
            record: record,
            store: store,
            git: fixture.git,
            harnessRegistry: HarnessRegistry(harnesses: suppliedHarnesses ?? [fake])
        )
        return Harness(
            fixture: fixture, store: store, engine: engine, harness: fake,
            workspaceID: record.workspaceID, worktree: worktree.path
        )
    }

    @Test func chatTabsOwnIndependentSessionsAndTranscripts() async throws {
        let harness = try await makeEngine()
        let second = try await harness.engine.createChat(CreateChatRequest(
            workspaceID: harness.workspaceID, title: "Reviewer", harness: .claudeCode
        ))

        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, text: "implement it"
        ))
        let firstSession = try #require(harness.harness.latestSession)

        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, chatID: second.id, text: "review it"
        ))
        let secondSession = try #require(harness.harness.latestSession)

        #expect(firstSession.id != secondSession.id)
        #expect(harness.harness.allSessions.count == 2)
        #expect(await firstSession.messageTexts() == ["implement it"])
        #expect(await secondSession.messageTexts() == ["review it"])

        firstSession.runTurn(turnID: "first-turn", text: "implemented")
        secondSession.runTurn(turnID: "second-turn", text: "reviewed")
        try await Task.sleep(for: .milliseconds(400))

        #expect(try await harness.store.turns(
            chatID: ChatID(rawValue: harness.workspaceID.rawValue)
        ).compactMap(\.prompt) == ["implement it"])
        #expect(try await harness.store.turns(chatID: second.id).compactMap(\.prompt) == ["review it"])
    }

    @Test func modelChangesApplyLiveToTheSelectedChatOnly() async throws {
        let harness = try await makeEngine()
        _ = try await harness.engine.ensureSession()
        let session = try #require(harness.harness.latestSession)
        let defaultChatID = ChatID(rawValue: harness.workspaceID.rawValue)

        let updated = try await harness.engine.setModel(chatID: defaultChatID, model: "opus")

        #expect(await session.selectedModel == "opus")
        #expect(updated.model == "opus")
        #expect(try await harness.store.chat(defaultChatID)?.model == "opus")
        let transitions = try await harness.store.chatTransitions(chatID: defaultChatID)
        #expect(transitions.map(\.kind) == [.modelChanged])
        #expect(transitions.first?.fromModel == nil)
        #expect(transitions.first?.toModel == "opus")
    }

    @Test func crossHarnessSwitchStartsFreshProviderSessionWithLocalHandoffContext() async throws {
        let claude = FakeHarness(kind: .claudeCode)
        let codex = FakeHarness(kind: .codex)
        let harness = try await makeEngine(harnesses: [claude, codex])
        let chatID = ChatID(rawValue: harness.workspaceID.rawValue)

        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, text: "build the parser"
        ))
        let claudeSession = try #require(claude.latestSession)
        claudeSession.runTurn(turnID: "claude-turn", text: "Parser implemented.")
        try await Task.sleep(for: .milliseconds(400))

        _ = try await harness.engine.switchHarness(
            chatID: chatID, harness: .codex, model: "gpt-5"
        )
        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, chatID: chatID, text: "continue with tests"
        ))
        let codexSession = try #require(codex.latestSession)

        guard case .fresh = codexSession.configuration.resume else {
            Issue.record("a cross-harness handoff must not reuse another provider's id")
            return
        }
        #expect(codexSession.configuration.appendSystemPrompt?.contains("Parser implemented.") == true)
        #expect(codexSession.configuration.appendSystemPrompt?.contains("build the parser") == true)
        #expect(try await harness.store.chatTransitions(chatID: chatID).map(\.kind)
            == [.harnessChanged])

        codexSession.runTurn(turnID: "codex-turn", text: "Tests added.")
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await harness.store.turns(chatID: chatID).compactMap(\.prompt)
            == ["build the parser", "continue with tests"])

        try await harness.engine.revert(to: "claude-turn", chatID: chatID)
        #expect(try await harness.store.turns(chatID: chatID).isEmpty)
        #expect(try await harness.store.chat(chatID)?.harness == HarnessKind.claudeCode.rawValue)
        #expect(claude.allSessions.count == 2, "revert should fork the original provider")
        #expect(try await harness.store.chatTransitions(chatID: chatID).isEmpty)
    }

    @Test func sendingCapturesACheckpointBeforeTheAgentRuns() async throws {
        // Reverting *to* a turn means restoring the state it started from, so
        // the snapshot has to be taken before the agent touches anything.
        let harness = try await makeEngine()
        try harness.fixture.write("before.txt", "original\n", in: harness.worktree)

        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, text: "do the thing"
        ))
        let session = try #require(harness.harness.latestSession)
        session.runTurn(text: "did the thing")
        try await Task.sleep(for: .milliseconds(300))

        let turns = try await harness.store.turns(
            sessionID: SessionID(rawValue: #require(
                try await harness.store.latestSession(for: harness.workspaceID)
            ).id)
        )
        #expect(turns.count == 1)
        #expect(turns[0].prompt == "do the thing")
        #expect(turns[0].checkpointCommit != nil)
    }

    @Test func aMessageSentMidTurnIsQueuedAndDeliveredAfterwards() async throws {
        // A thought that arrives while the agent works shouldn't force a
        // choice between losing it and derailing the agent.
        let harness = try await makeEngine()

        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, text: "first"
        ))
        let session = try #require(harness.harness.latestSession)
        session.emit(.turnStarted(TurnStarted(turnID: TurnID(rawValue: "t1"))))
        try await Task.sleep(for: .milliseconds(150))

        let delivered = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, text: "second"
        ))
        #expect(delivered == false, "a message sent mid-turn must queue")
        #expect(await session.messageTexts() == ["first"])
        #expect(try await harness.store.queuedMessages(
            workspaceID: harness.workspaceID
        ).count == 1)

        // Finishing the turn drains the queue.
        session.emit(.turnCompleted(TurnResult(
            turnID: TurnID(rawValue: "t1"), outcome: .completed
        )))
        _ = await waitUntil { await session.messageTexts().count == 2 }

        #expect(await session.messageTexts() == ["first", "second"])
        #expect(try await harness.store.queuedMessages(
            workspaceID: harness.workspaceID
        ).isEmpty)
    }

    @Test func aQueuedMessageSurvivesTheSessionDyingMidTurn() async throws {
        // The agent can die mid-turn — a model id its provider doesn't recognise
        // is enough. That never produces a `.turnCompleted`, so without an
        // explicit drain the queued message sits in the card forever and the
        // user has to retype it.
        let harness = try await makeEngine()

        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, text: "first"
        ))
        let session = try #require(harness.harness.latestSession)
        session.emit(.turnStarted(TurnStarted(turnID: TurnID(rawValue: "t1"))))
        try await Task.sleep(for: .milliseconds(150))

        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, text: "continue"
        ))
        session.emit(.sessionEnded(SessionEnded(
            sessionID: session.id, exitCode: 1, wasUnexpected: true
        )))

        #expect(await waitUntil { harness.harness.allSessions.count == 2 })
        let replacement = try #require(harness.harness.latestSession)
        #expect(await waitUntil { await replacement.messageTexts() == ["continue"] })
        #expect(try await harness.store.queuedMessages(
            workspaceID: harness.workspaceID
        ).isEmpty)
    }

    @Test func switchingModelAfterStoppingSendsWhatWasQueued() async throws {
        // Stopping the agent and picking a different model is the natural way
        // out of a bad model choice. The message queued behind the stopped turn
        // is what the user wants that new model to work on.
        let harness = try await makeEngine()
        let defaultChatID = ChatID(rawValue: harness.workspaceID.rawValue)

        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, text: "first"
        ))
        let session = try #require(harness.harness.latestSession)
        session.emit(.turnStarted(TurnStarted(turnID: TurnID(rawValue: "t1"))))
        try await Task.sleep(for: .milliseconds(150))

        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, text: "continue"
        ))
        try await harness.engine.interrupt(chatID: defaultChatID)
        _ = try await harness.engine.setModel(chatID: defaultChatID, model: "opus")

        #expect(await waitUntil { await session.messageTexts() == ["first", "continue"] })
        #expect(try await harness.store.queuedMessages(
            workspaceID: harness.workspaceID
        ).isEmpty)
    }

    @Test func permissionModeSwitchesInsideTheRunningChat() async throws {
        // Reaching for Accept Edits happens *because* a turn is underway and
        // the prompts are in the way. Opening a fresh chat to get it would
        // throw away the conversation that motivated the change.
        let harness = try await makeEngine()
        let defaultChatID = ChatID(rawValue: harness.workspaceID.rawValue)

        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, text: "first"
        ))
        let session = try #require(harness.harness.latestSession)
        session.emit(.turnStarted(TurnStarted(turnID: TurnID(rawValue: "t1"))))
        try await Task.sleep(for: .milliseconds(150))

        try await harness.engine.setPermissionMode(.acceptEdits, chatID: defaultChatID)

        #expect(await session.permissionMode == .acceptEdits)
        #expect(harness.harness.allSessions.count == 1)
        #expect(try await harness.store.chat(defaultChatID)?.permissionMode
            == PermissionMode.acceptEdits.rawValue)
    }

    @Test func aSetModeSuggestionUpdatesTheStoredPermissionMode() async throws {
        // "Switch to Accept Edits" on the permission card is applied by the
        // CLI in the same reply. If ORE's stored mode stays Ask, the composer
        // chip lies and the next spawn asks again.
        let harness = try await makeEngine()
        let defaultChatID = ChatID(rawValue: harness.workspaceID.rawValue)
        let requestID = PermissionRequestID(rawValue: "p1")

        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, text: "first"
        ))
        let session = try #require(harness.harness.latestSession)
        session.emit(.turnStarted(TurnStarted(turnID: TurnID(rawValue: "t1"))))
        try await Task.sleep(for: .milliseconds(150))

        try await harness.engine.resolvePermission(
            requestID,
            with: .allowWithSuggestion([
                "type": "setMode",
                "mode": "acceptEdits",
            ]),
            chatID: defaultChatID
        )

        #expect(try await harness.store.chat(defaultChatID)?.permissionMode
            == PermissionMode.acceptEdits.rawValue)
        #expect(await session.permissionMode == nil,
                "the CLI already took the mode via the permission reply")
        #expect(await session.permissionDecisions[requestID] != nil)
    }

    @Test func allowingAToolWithoutAModeSuggestionLeavesTheChipAlone() async throws {
        let harness = try await makeEngine()
        let defaultChatID = ChatID(rawValue: harness.workspaceID.rawValue)

        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, text: "first"
        ))
        try await harness.engine.resolvePermission(
            PermissionRequestID(rawValue: "p1"),
            with: .allow,
            chatID: defaultChatID
        )

        #expect(try await harness.store.chat(defaultChatID)?.permissionMode
            == PermissionMode.default.rawValue)
    }

    @Test func aLaunchOnlyHarnessKeepsThePermissionModeItWasGiven() async throws {
        // The change used to be dropped entirely when the session refused it:
        // the chip showed Accept Edits, the stored mode stayed Ask, and the
        // only way to actually get it was a new chat. Now the choice is
        // recorded and the next session is launched under it.
        let fake = FakeHarness()
        fake.rejectsPermissionModeChange = true
        let harness = try await makeEngine(harnesses: [fake])
        let defaultChatID = ChatID(rawValue: harness.workspaceID.rawValue)

        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, text: "first"
        ))
        let session = try #require(fake.latestSession)
        session.runTurn(turnID: TurnID(rawValue: "t1"))
        try await Task.sleep(for: .milliseconds(150))

        try await harness.engine.setPermissionMode(.acceptEdits, chatID: defaultChatID)

        #expect(try await harness.store.chat(defaultChatID)?.permissionMode
            == PermissionMode.acceptEdits.rawValue)
        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, text: "second"
        ))
        let replacement = try #require(fake.latestSession)
        #expect(replacement.configuration.permissionMode == .acceptEdits)
    }

    @Test func diffCommentsReachTheAgentAnchoredToTheirLines() async throws {
        // A comment is more precise than prose because it carries the file and
        // the line; the agent must not have to guess what "that function" meant.
        let harness = try await makeEngine()

        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID,
            text: "please fix these",
            diffComments: [DiffCommentReference(
                filePath: "Sources/App.swift",
                startLine: 42,
                endLine: 44,
                body: "this needs a nil check",
                context: "+let value = optional!"
            )]
        ))

        let session = try #require(harness.harness.latestSession)
        let sent = try #require(await session.messageTexts().first)
        #expect(sent.contains("please fix these"))
        #expect(sent.contains("Sources/App.swift:42-44"))
        #expect(sent.contains("this needs a nil check"))
        #expect(sent.contains("let value = optional!"))
    }

    @Test func aWorkspaceNeedingInputIsMarkedUnreadUnlessItIsOnScreen() async throws {
        // The sidebar answers "which agent needs me"; the one the user is
        // already looking at does not.
        let harness = try await makeEngine()
        _ = try await harness.engine.ensureSession()
        let session = try #require(harness.harness.latestSession)

        session.emit(.permissionRequest(PermissionRequest(
            turnID: TurnID(rawValue: "t1"),
            id: PermissionRequestID(rawValue: "r1"),
            toolName: "Write",
            input: .object([:])
        )))
        try await Task.sleep(for: .milliseconds(250))

        #expect(await harness.engine.summary().hasUnread)
        #expect(await harness.engine.summary().status == .awaitingInput)

        await harness.engine.setFocused(true)
        #expect(await !harness.engine.summary().hasUnread)

        // While focused, further activity must not re-flag it.
        session.emit(.turnCompleted(TurnResult(
            turnID: TurnID(rawValue: "t1"), outcome: .completed
        )))
        try await Task.sleep(for: .milliseconds(250))
        #expect(await !harness.engine.summary().hasUnread)
    }

    @Test func backgroundChatUnreadStateIsIndependentFromTheVisibleTab() async throws {
        let harness = try await makeEngine()
        let defaultChatID = ChatID(rawValue: harness.workspaceID.rawValue)
        let background = try await harness.engine.createChat(CreateChatRequest(
            workspaceID: harness.workspaceID, title: "Background"
        ))
        _ = try await harness.engine.ensureSession(chatID: background.id)
        let backgroundSession = try #require(harness.harness.latestSession)

        await harness.engine.setFocused(true, chatID: defaultChatID)
        backgroundSession.emit(.turnCompleted(TurnResult(
            turnID: "background-turn", outcome: .completed
        )))
        try await Task.sleep(for: .milliseconds(250))

        let summaries = try await harness.engine.chatSummaries()
        #expect(summaries.first { $0.id == background.id }?.hasUnread == true)
        #expect(summaries.first { $0.id == defaultChatID }?.hasUnread == false)
        #expect(await harness.engine.summary().hasUnread)

        await harness.engine.setFocused(true, chatID: background.id)
        #expect(await !harness.engine.summary().hasUnread)
    }

    @Test func revertRestoresTheTreeAndTruncatesTheTranscript() async throws {
        // Both halves have to move together: restoring the files alone leaves
        // the agent remembering work that no longer exists.
        let harness = try await makeEngine()
        try harness.fixture.write("stable.txt", "keep me\n", in: harness.worktree)

        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, text: "first turn"
        ))
        let session = try #require(harness.harness.latestSession)
        session.runTurn(turnID: TurnID(rawValue: "t1"), text: "first done")
        try await Task.sleep(for: .milliseconds(400))

        // Sending captures the checkpoint; the agent's writes come after it,
        // which is exactly what reverting to this turn should undo.
        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, text: "second turn"
        ))
        try harness.fixture.write("added-later.txt", "should vanish\n", in: harness.worktree)
        session.runTurn(turnID: TurnID(rawValue: "t2"), text: "second done")
        try await Task.sleep(for: .milliseconds(400))

        let sessionID = SessionID(rawValue: try #require(
            try await harness.store.latestSession(for: harness.workspaceID)
        ).id)
        let turns = try await harness.store.turns(sessionID: sessionID)
        #expect(turns.count == 2)

        try await harness.engine.revert(to: turns[1].turnID)

        #expect(harness.fixture.exists("stable.txt", in: harness.worktree))
        #expect(!harness.fixture.exists("added-later.txt", in: harness.worktree))
        #expect(try await harness.store.turns(sessionID: sessionID).count == 1)
    }

    @Test func revertingToATurnWithoutACheckpointFails() async throws {
        // Better an error the UI can show than a revert that silently does
        // nothing.
        let harness = try await makeEngine()
        await #expect(throws: OreCoreError.self) {
            try await harness.engine.revert(to: TurnID(rawValue: "never-existed"))
        }
    }

    @Test func theTranscriptContinuesAcrossSessionRestarts() async throws {
        // Relaunching the app resumes the provider session; the transcript has
        // to continue with it, not restart.
        let harness = try await makeEngine()

        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, text: "first"
        ))
        let first = try #require(harness.harness.latestSession)
        first.runTurn(turnID: TurnID(rawValue: "t1"))
        try await Task.sleep(for: .milliseconds(400))

        await harness.engine.stopSession()

        _ = try await harness.engine.send(SendMessageRequest(
            workspaceID: harness.workspaceID, text: "second"
        ))
        let second = try #require(harness.harness.latestSession)
        #expect(second.id != first.id)
        second.runTurn(turnID: TurnID(rawValue: "t2"))
        try await Task.sleep(for: .milliseconds(400))

        // One session row, two turns — not two sessions of one turn each.
        let sessionID = SessionID(rawValue: try #require(
            try await harness.store.latestSession(for: harness.workspaceID)
        ).id)
        let turns = try await harness.store.turns(sessionID: sessionID)
        #expect(turns.count == 2)
        #expect(turns.map(\.ordinal) == [0, 1])
        #expect(turns.compactMap(\.prompt) == ["first", "second"])
    }

    @Test func resumingReusesTheProviderSessionSoContextIsNotLost() async throws {
        let harness = try await makeEngine()
        _ = try await harness.engine.ensureSession()
        let first = try #require(harness.harness.latestSession)
        let providerSessionID = try #require(await first.providerSessionID)
        try await Task.sleep(for: .milliseconds(200))

        await harness.engine.stopSession()
        _ = try await harness.engine.ensureSession()

        let second = try #require(harness.harness.latestSession)
        guard case .resume(let resumed) = second.configuration.resume else {
            Issue.record("a restarted session must resume, not start fresh")
            return
        }
        #expect(resumed == providerSessionID)
    }

    @Test func theWorktreeIsWhatTheAgentRunsIn() async throws {
        // The isolation that makes N parallel agents safe.
        let harness = try await makeEngine()
        _ = try await harness.engine.ensureSession()
        let session = try #require(harness.harness.latestSession)

        #expect(session.configuration.workingDirectory.path == harness.worktree.path)
        // And it's told where its scratch space is, so `.context` is usable.
        #expect(session.configuration.appendSystemPrompt?.contains(".context/") == true)
        // And it's taught the narration-tag convention the translators strip.
        #expect(session.configuration.appendSystemPrompt?.contains(NarrationTag.open) == true)
    }

    @Test func aMissingHarnessFailsWithSomethingActionable() async throws {
        let fixture = try await GitFixture.initialized()
        let store = try OreStore()
        try await store.addRepository(RepositoryRecord(
            path: fixture.repository.path, name: "repo", defaultBranch: "main"
        ))
        let record = WorkspaceRecord(
            id: WorkspaceID.generate(), name: "no harness",
            repositoryPath: fixture.repository.path,
            worktreePath: fixture.repository.path,
            branch: "ore/x", baseBranch: "main", harness: .codex
        )
        try await store.saveWorkspace(record)

        let engine = WorkspaceEngine(
            record: record, store: store, git: fixture.git,
            harnessRegistry: HarnessRegistry(harnesses: [])
        )
        await #expect(throws: HarnessError.self) {
            _ = try await engine.ensureSession()
        }
    }
}
