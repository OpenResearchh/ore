import Foundation
import Testing

@testable import OrePersistence
@testable import OreProtocol

struct PersistenceTests {
    private func makeStore() throws -> OreStore { try OreStore() }

    private func seedWorkspace(
        _ store: OreStore,
        id: String = "ws1",
        name: String = "belgrade"
    ) async throws -> WorkspaceRecord {
        try await store.addRepository(RepositoryRecord(
            path: "/repo", name: "repo", defaultBranch: "main"
        ))
        let workspace = WorkspaceRecord(
            id: WorkspaceID(rawValue: id),
            name: name,
            repositoryPath: "/repo",
            worktreePath: "/Users/x/ore/workspaces/repo/\(id)",
            branch: "ore/\(id)",
            baseBranch: "main",
            harness: .claudeCode
        )
        try await store.saveWorkspace(workspace)
        return workspace
    }

    @Test func migrationsRunAndTheSchemaIsUsable() async throws {
        let store = try makeStore()
        let workspace = try await seedWorkspace(store)
        #expect(try await store.workspace(workspace.workspaceID)?.name == "belgrade")
    }

    @Test func defaultChatAdoptsWorkspaceDefaultsAndPersistsTabState() async throws {
        let store = try makeStore()
        var workspace = try await seedWorkspace(store)
        workspace.model = "opus"
        workspace.permissionMode = PermissionMode.acceptEdits.rawValue
        try await store.saveWorkspace(workspace)

        var chat = try await store.ensureDefaultChat(for: workspace)
        #expect(chat.chatID.rawValue == workspace.id)
        #expect(chat.harness == HarnessKind.claudeCode.rawValue)
        #expect(chat.model == "opus")

        chat.draftText = "unfinished thought"
        chat.isClosed = true
        try await store.saveChat(chat)
        let restored = try #require(try await store.chat(chat.chatID))
        #expect(restored.draftText == "unfinished thought")
        #expect(restored.isClosed)
    }

    @Test func chatTranscriptSpansProviderSessionsAndQueuesStayIsolated() async throws {
        let store = try makeStore()
        let workspace = try await seedWorkspace(store)
        let firstChat = try await store.ensureDefaultChat(for: workspace)
        let secondChat = ChatRecord(
            id: ChatID(rawValue: "chat-2"), workspaceID: workspace.workspaceID,
            title: "Reviewer", harness: .codex, sortIndex: 1
        )
        try await store.saveChat(secondChat)

        for (sessionName, ordinal) in [("session-a", 0), ("session-b", 1)] {
            let sessionID = SessionID(rawValue: sessionName)
            try await store.saveSession(SessionRecord(
                id: sessionID, workspaceID: workspace.workspaceID,
                chatID: firstChat.chatID, harness: .claudeCode,
                startedAt: Date(timeIntervalSince1970: TimeInterval(ordinal))
            ))
            try await store.saveTurn(TurnRecord(
                id: TurnID(rawValue: "turn-\(ordinal)"), sessionID: sessionID,
                ordinal: 0, prompt: "prompt \(ordinal)"
            ))
        }
        #expect(try await store.turns(chatID: firstChat.chatID).compactMap(\.prompt)
            == ["prompt 0", "prompt 1"])

        try await store.enqueueMessage(QueuedMessageRecord(
            workspaceID: workspace.workspaceID, chatID: firstChat.chatID, text: "first"
        ))
        try await store.enqueueMessage(QueuedMessageRecord(
            workspaceID: workspace.workspaceID, chatID: secondChat.chatID, text: "second"
        ))
        #expect(try await store.queuedMessages(chatID: firstChat.chatID).map(\.text) == ["first"])
        #expect(try await store.queuedMessages(chatID: secondChat.chatID).map(\.text) == ["second"])
    }

    @Test func migrationsAreIdempotentAcrossReopens() async throws {
        // A second launch must not try to recreate tables.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-\(UUID().uuidString)")
            .appendingPathComponent("ore.sqlite")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        let first = try OreStore(path: path)
        _ = try await seedWorkspace(first)

        let second = try OreStore(path: path)
        #expect(try await second.workspaces().count == 1)
    }

    @Test func sidebarOrderPutsPinnedFirstThenMostRecentlyActive() async throws {
        let store = try makeStore()
        _ = try await seedWorkspace(store, id: "old", name: "old")
        _ = try await seedWorkspace(store, id: "recent", name: "recent")
        _ = try await seedWorkspace(store, id: "pinned", name: "pinned")

        let now = Date()
        _ = try await store.updateWorkspace(WorkspaceID(rawValue: "old")) {
            $0.lastActivityAt = now.addingTimeInterval(-3600)
        }
        _ = try await store.updateWorkspace(WorkspaceID(rawValue: "recent")) {
            $0.lastActivityAt = now
        }
        _ = try await store.updateWorkspace(WorkspaceID(rawValue: "pinned")) {
            $0.isPinned = true
            $0.lastActivityAt = now.addingTimeInterval(-86400)
        }

        let names = try await store.workspaces().map(\.name)
        #expect(names == ["pinned", "recent", "old"])
    }

    @Test func archivedWorkspacesAreHiddenUnlessAskedFor() async throws {
        let store = try makeStore()
        _ = try await seedWorkspace(store, id: "live", name: "live")
        _ = try await seedWorkspace(store, id: "done", name: "done")
        _ = try await store.updateWorkspace(WorkspaceID(rawValue: "done")) {
            $0.isArchived = true
        }

        #expect(try await store.workspaces().map(\.name) == ["live"])
        #expect(try await store.workspaces(includeArchived: true).count == 2)
    }

    @Test func deletingAWorkspaceCascadesToItsTranscript() async throws {
        let store = try makeStore()
        let workspace = try await seedWorkspace(store)
        let sessionID = SessionID(rawValue: "s1")
        try await store.saveSession(SessionRecord(
            id: sessionID, workspaceID: workspace.workspaceID, harness: .claudeCode
        ))
        let turnID = TurnID(rawValue: "t1")
        try await store.saveTurn(TurnRecord(id: turnID, sessionID: sessionID, ordinal: 0))
        try await store.appendBlock(BlockRecord(
            id: "b1", turnID: turnID, ordinal: 0, kind: .text, text: "hello"
        ))

        try await store.deleteWorkspace(workspace.workspaceID)

        #expect(try await store.turns(sessionID: sessionID).isEmpty)
        #expect(try await store.blocks(turnID: turnID).isEmpty)
    }

    @Test func deletingAParentLeavesStackedChildrenIntact() async throws {
        // Work built on top of a deleted workspace is still the user's work.
        let store = try makeStore()
        _ = try await seedWorkspace(store, id: "parent", name: "parent")
        var child = try await seedWorkspace(store, id: "child", name: "child")
        child.stackedOnWorkspaceID = "parent"
        try await store.saveWorkspace(child)

        try await store.deleteWorkspace(WorkspaceID(rawValue: "parent"))

        let surviving = try await store.workspace(WorkspaceID(rawValue: "child"))
        #expect(surviving != nil)
        #expect(surviving?.stackedOnWorkspaceID == nil)
    }

    @Test func revertingATurnRemovesItAndEverythingAfterIt() async throws {
        // The transcript half of a checkpoint revert: the conversation has to
        // end where the code does.
        let store = try makeStore()
        let workspace = try await seedWorkspace(store)
        let sessionID = SessionID(rawValue: "s1")
        try await store.saveSession(SessionRecord(
            id: sessionID, workspaceID: workspace.workspaceID, harness: .claudeCode
        ))

        for ordinal in 0..<4 {
            try await store.saveTurn(TurnRecord(
                id: TurnID(rawValue: "t\(ordinal)"), sessionID: sessionID, ordinal: ordinal
            ))
        }

        try await store.deleteTurnsFrom(sessionID: sessionID, ordinal: 2)

        let remaining = try await store.turns(sessionID: sessionID).map(\.ordinal)
        #expect(remaining == [0, 1])
    }

    @Test func turnOrdinalsIncrementWithoutGaps() async throws {
        let store = try makeStore()
        let workspace = try await seedWorkspace(store)
        let sessionID = SessionID(rawValue: "s1")
        try await store.saveSession(SessionRecord(
            id: sessionID, workspaceID: workspace.workspaceID, harness: .claudeCode
        ))

        #expect(try await store.nextTurnOrdinal(sessionID: sessionID) == 0)
        try await store.saveTurn(TurnRecord(
            id: TurnID(rawValue: "t0"), sessionID: sessionID, ordinal: 0
        ))
        #expect(try await store.nextTurnOrdinal(sessionID: sessionID) == 1)
    }

    @Test func searchFindsTranscriptTextAndReportsItsWorkspace() async throws {
        // With several agents running in parallel, "which workspace was I doing
        // the migration in?" stops being answerable from memory.
        let store = try makeStore()
        let workspace = try await seedWorkspace(store, id: "ws1", name: "the-migration")
        let sessionID = SessionID(rawValue: "s1")
        try await store.saveSession(SessionRecord(
            id: sessionID, workspaceID: workspace.workspaceID, harness: .claudeCode
        ))
        let turnID = TurnID(rawValue: "t1")
        try await store.saveTurn(TurnRecord(id: turnID, sessionID: sessionID, ordinal: 0))
        try await store.appendBlocks([
            BlockRecord(
                id: "b1", turnID: turnID, ordinal: 0, kind: .text,
                text: "I migrated the authentication tables to the new schema."
            ),
            BlockRecord(
                id: "b2", turnID: turnID, ordinal: 1, kind: .text,
                text: "Unrelated: fixed a typo in the README."
            ),
        ])

        let hits = try await store.search("authentication")
        #expect(hits.count == 1)
        #expect(hits[0].workspaceName == "the-migration")
        #expect(hits[0].blockID == "b1")
        #expect(hits[0].snippet.contains("«authentication»"))

        // Prefix matching, because the user types while they think.
        #expect(try await store.search("migrat").count == 1)
    }

    @Test func searchIndexTracksEditsAndDeletions() async throws {
        // The FTS index is external-content, so it only stays correct if the
        // triggers fire on every write path.
        let store = try makeStore()
        let workspace = try await seedWorkspace(store)
        let sessionID = SessionID(rawValue: "s1")
        try await store.saveSession(SessionRecord(
            id: sessionID, workspaceID: workspace.workspaceID, harness: .claudeCode
        ))
        let turnID = TurnID(rawValue: "t1")
        try await store.saveTurn(TurnRecord(id: turnID, sessionID: sessionID, ordinal: 0))
        try await store.appendBlock(BlockRecord(
            id: "b1", turnID: turnID, ordinal: 0, kind: .text, text: "flibbertigibbet"
        ))
        #expect(try await store.search("flibbertigibbet").count == 1)

        // Overwrite the block's text.
        try await store.appendBlock(BlockRecord(
            id: "b1", turnID: turnID, ordinal: 0, kind: .text, text: "something else entirely"
        ))
        #expect(try await store.search("flibbertigibbet").isEmpty)

        try await store.deleteTurnsFrom(sessionID: sessionID, ordinal: 0)
        #expect(try await store.search("entirely").isEmpty)
    }

    @Test func searchIgnoresGarbageQueriesRatherThanThrowing() async throws {
        // FTS5 has its own syntax; a user typing quotes or operators into the
        // palette must not crash the search.
        let store = try makeStore()
        #expect(try await store.search("\"unbalanced").isEmpty)
        #expect(try await store.search("").isEmpty)
        #expect(try await store.search("AND OR NOT").isEmpty)
    }

    @Test func diffCommentsAreDraftedThenSentAsABatch() async throws {
        // Reviewing is a pass over the diff, not one message per note.
        let store = try makeStore()
        let workspace = try await seedWorkspace(store)

        for line in [10, 42] {
            _ = try await store.addDiffComment(DiffCommentRecord(
                workspaceID: workspace.workspaceID,
                filePath: "Sources/App.swift",
                startLine: line,
                endLine: line,
                body: "this needs a test"
            ))
        }

        let pending = try await store.pendingDiffComments(workspaceID: workspace.workspaceID)
        #expect(pending.count == 2)
        #expect(pending.map(\.startLine) == [10, 42])
        #expect(pending.first?.reference.filePath == "Sources/App.swift")

        try await store.markDiffCommentsSent(workspaceID: workspace.workspaceID)
        #expect(try await store.pendingDiffComments(workspaceID: workspace.workspaceID).isEmpty)
    }

    @Test func viewedStateIsKeyedByContentSoChangesResetIt() async throws {
        // A file the agent touches again must stop counting as reviewed.
        let store = try makeStore()
        let workspace = try await seedWorkspace(store)

        try await store.markViewed(ViewedFileRecord(
            workspaceID: workspace.workspaceID, filePath: "a.swift", contentHash: "hash-1"
        ))
        #expect(try await store.viewedFiles(workspaceID: workspace.workspaceID)["a.swift"] == "hash-1")

        try await store.markViewed(ViewedFileRecord(
            workspaceID: workspace.workspaceID, filePath: "a.swift", contentHash: "hash-2"
        ))
        let viewed = try await store.viewedFiles(workspaceID: workspace.workspaceID)
        #expect(viewed["a.swift"] == "hash-2")
        #expect(viewed.count == 1)
    }

    @Test func theMessageQueueIsFIFOAndDrainsExactlyOnce() async throws {
        let store = try makeStore()
        let workspace = try await seedWorkspace(store)

        for text in ["first", "second", "third"] {
            try await store.enqueueMessage(QueuedMessageRecord(
                workspaceID: workspace.workspaceID, text: text
            ))
        }

        var drained: [String] = []
        while let next = try await store.dequeueMessage(workspaceID: workspace.workspaceID) {
            drained.append(next.text)
        }
        #expect(drained == ["first", "second", "third"])
        #expect(try await store.queuedMessages(workspaceID: workspace.workspaceID).isEmpty)
    }

    @Test func queuedAttachmentsRoundTrip() async throws {
        let store = try makeStore()
        let workspace = try await seedWorkspace(store)
        try await store.enqueueMessage(QueuedMessageRecord(
            workspaceID: workspace.workspaceID,
            text: "look at this",
            attachmentPaths: [".context/attachments/plan.md"],
            serviceTier: "fast"
        ))
        let message = try #require(
            try await store.dequeueMessage(workspaceID: workspace.workspaceID)
        )
        #expect(message.paths == [".context/attachments/plan.md"])
        #expect(message.serviceTier == "fast")
    }

    @Test func toolPayloadsSurviveAsJSON() async throws {
        let store = try makeStore()
        let workspace = try await seedWorkspace(store)
        let sessionID = SessionID(rawValue: "s1")
        try await store.saveSession(SessionRecord(
            id: sessionID, workspaceID: workspace.workspaceID, harness: .claudeCode
        ))
        let turnID = TurnID(rawValue: "t1")
        try await store.saveTurn(TurnRecord(id: turnID, sessionID: sessionID, ordinal: 0))

        try await store.appendBlock(BlockRecord(
            id: "tool-1", turnID: turnID, ordinal: 0, kind: .toolCall,
            text: "git status", toolName: "Bash", toolCallID: ToolCallID(rawValue: "t1"),
            payload: ["command": "git status", "timeout": 5]
        ))

        let block = try #require(try await store.blocks(turnID: turnID).first)
        #expect(block.blockKind == .toolCall)
        #expect(block.decodedPayload?["command"]?.stringValue == "git status")
        // Integers must not come back as doubles: the payload is replayed into
        // the harness verbatim.
        #expect(block.decodedPayload?["timeout"] == .integer(5))
    }
}

struct TranscriptWriterTests {
    private func makeWriter() async throws -> (OreStore, TranscriptWriter, SessionID) {
        let store = try OreStore()
        try await store.addRepository(RepositoryRecord(
            path: "/repo", name: "repo", defaultBranch: "main"
        ))
        let workspaceID = WorkspaceID(rawValue: "ws1")
        try await store.saveWorkspace(WorkspaceRecord(
            id: workspaceID, name: "ws", repositoryPath: "/repo",
            worktreePath: "/wt", branch: "ore/ws", baseBranch: "main", harness: .claudeCode
        ))
        let sessionID = SessionID(rawValue: "s1")
        let writer = TranscriptWriter(store: store, sessionID: sessionID)
        await writer.configure(workspaceID: workspaceID)
        return (store, writer, sessionID)
    }

    @Test func aFullTurnIsPersistedAsOrderedBlocks() async throws {
        let (store, writer, sessionID) = try await makeWriter()
        let turnID = TurnID(rawValue: "t1")

        await writer.recordPrompt("add a test", attachments: [
            Attachment(
                relativePath: ".context/attachments/shot.png",
                displayName: "pasted-image.png",
                mimeType: "image/png"
            )
        ])
        for event in [
            AgentEvent.sessionStarted(SessionStarted(
                sessionID: sessionID, providerSessionID: "p1", harness: .claudeCode,
                workingDirectory: "/wt"
            )),
            .turnStarted(TurnStarted(turnID: turnID)),
            .blockCompleted(BlockCompleted(
                turnID: turnID, blockID: "b0", kind: .thinking, text: "considering"
            )),
            .blockCompleted(BlockCompleted(
                turnID: turnID, blockID: "b1", kind: .text, text: "I'll add one."
            )),
            .toolCall(ToolCall(
                turnID: turnID, id: "tool1", name: "Write",
                displayName: "AppTests.swift", input: ["file_path": "AppTests.swift"]
            )),
            .toolResult(ToolResult(
                turnID: turnID, toolCallID: "tool1", isError: false, text: "written"
            )),
            .usage(UsageReport(turnID: turnID, inputTokens: 10, outputTokens: 20)),
            .turnCompleted(TurnResult(
                turnID: turnID, outcome: .completed, summary: "Added the test."
            )),
        ] {
            await writer.handle(event)
        }

        let turns = try await store.turns(sessionID: sessionID)
        #expect(turns.count == 1)
        #expect(turns[0].prompt == "add a test")
        #expect(turns[0].attachments.map(\.relativePath) == [".context/attachments/shot.png"])
        #expect(turns[0].attachments.first?.displayName == "pasted-image.png")
        #expect(turns[0].outcome == "completed")
        #expect(turns[0].summary == "Added the test.")
        #expect(turns[0].inputTokens == 10)
        #expect(turns[0].endedAt != nil)

        let blocks = try await store.blocks(turnID: turnID)
        #expect(blocks.map(\.blockKind) == [.thinking, .text, .toolCall, .toolResult])
        #expect(blocks.map(\.ordinal) == [0, 1, 2, 3])
        #expect(blocks.count == 4)
        #expect(blocks.dropFirst(2).first?.toolName == "Write")
        #expect(blocks.last?.toolCallID == "tool1")
    }

    @Test func streamingDeltasAreNotPersisted() async throws {
        // Hundreds of deltas per paragraph; the authoritative text arrives once.
        let (store, writer, _) = try await makeWriter()
        let turnID = TurnID(rawValue: "t1")

        await writer.handle(.turnStarted(TurnStarted(turnID: turnID)))
        for fragment in ["hel", "lo ", "ore"] {
            await writer.handle(.textDelta(BlockDelta(
                turnID: turnID, blockID: "b1", text: fragment
            )))
        }
        #expect(try await store.blocks(turnID: turnID).isEmpty)

        await writer.handle(.blockCompleted(BlockCompleted(
            turnID: turnID, blockID: "b1", kind: .text, text: "hello ore"
        )))
        let blocks = try await store.blocks(turnID: turnID)
        #expect(blocks.count == 1)
        #expect(blocks.first?.text == "hello ore")
    }

    @Test func hugeToolOutputIsTruncatedBeforeStorage() async throws {
        let (store, writer, _) = try await makeWriter()
        let turnID = TurnID(rawValue: "t1")
        await writer.handle(.turnStarted(TurnStarted(turnID: turnID)))
        await writer.handle(.toolResult(ToolResult(
            turnID: turnID,
            toolCallID: "tool1",
            isError: false,
            text: String(repeating: "x", count: 100_000)
        )))

        let blocks = try await store.blocks(turnID: turnID)
        #expect(blocks.first?.text.count == 16_000)
    }

    @Test func aCheckpointIsLinkedToTheTurnItPrecedes() async throws {
        // Reverting *to* a turn means restoring the state it started from, so
        // the checkpoint has to be attached before the turn opens.
        let (store, writer, sessionID) = try await makeWriter()
        let turnID = TurnID(rawValue: "t1")

        await writer.recordCheckpoint(commit: "abc123", providerSessionID: "p1")
        await writer.handle(.turnStarted(TurnStarted(turnID: turnID)))
        await writer.handle(.turnCompleted(TurnResult(turnID: turnID, outcome: .completed)))

        let turn = try #require(try await store.turns(sessionID: sessionID).first)
        #expect(turn.checkpointCommit == "abc123")
        #expect(turn.checkpointProviderSessionID == "p1")
    }

    @Test func aFailedWriteDoesNotTakeTheSessionDown() async throws {
        // The user would rather keep talking to the agent than lose the session
        // because a write failed.
        let (_, writer, _) = try await makeWriter()

        // No turn has started, so this block references a turn that doesn't
        // exist and violates the foreign key.
        await writer.handle(.sessionStarted(SessionStarted(
            sessionID: SessionID(rawValue: "s1"), providerSessionID: "p1",
            harness: .claudeCode, workingDirectory: "/wt"
        )))
        await writer.handle(.blockCompleted(BlockCompleted(
            turnID: TurnID(rawValue: "ghost"), blockID: "b1", kind: .text, text: "orphan"
        )))

        #expect(await writer.persistenceFailures == 1)
        #expect(await writer.lastPersistenceError != nil)
    }
}
