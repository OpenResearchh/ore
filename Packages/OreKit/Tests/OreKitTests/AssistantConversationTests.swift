import Foundation
import Testing

@testable import OreCore
@testable import OreGit
@testable import OreHarness
@testable import OrePersistence
@testable import OreProtocol

/// The assistant's own conversation is the one transcript nobody was managing:
/// it grew for as long as the app ran, and most of what filled it was ORE
/// talking to itself. These cover the three things that had to become true —
/// a fleet digest is not conversation, a long conversation is retired rather
/// than truncated, and the retired one stays readable.
struct AssistantConversationTests {
    private func makeAssistantEngine() async throws -> (
        store: OreStore, engine: WorkspaceEngine, fake: FakeHarness, id: WorkspaceID
    ) {
        let fixture = try await GitFixture.initialized()
        let store = try OreStore()
        try await store.addRepository(RepositoryRecord(
            path: fixture.repository.path, name: "assistant", defaultBranch: "main"
        ))
        let record = WorkspaceRecord(
            id: WorkspaceID.generate(),
            name: "Assistant",
            repositoryPath: fixture.repository.path,
            worktreePath: fixture.repository.path,
            branch: "main", baseBranch: "main",
            harness: .claudeCode,
            kind: .assistant
        )
        try await store.saveWorkspace(record)
        let fake = FakeHarness()
        let engine = WorkspaceEngine(
            record: record, store: store, git: fixture.git,
            harnessRegistry: HarnessRegistry(harnesses: [fake])
        )
        return (store, engine, fake, record.workspaceID)
    }

    /// Sends one message and drives the fake harness through a whole turn.
    private func runTurn(
        _ text: String,
        origin: MessageOrigin,
        engine: WorkspaceEngine,
        fake: FakeHarness,
        id: WorkspaceID
    ) async throws {
        _ = try await engine.send(SendMessageRequest(
            workspaceID: id, text: text, origin: origin
        ))
        let session = try #require(fake.latestSession)
        session.runTurn(text: "ok")
        _ = await waitUntil {
            await (try? engine.chatSummaries().first?.isTurnActive) == false
        }
    }

    // MARK: - What counts as conversation

    /// The trigger this all hangs on. A busy fleet hands the assistant a digest
    /// every couple of minutes; counting those as conversation had it compacting
    /// itself overnight with nobody at the keyboard.
    @Test func fleetDigestsDoNotCountTowardConversationLength() async throws {
        let (store, engine, fake, id) = try await makeAssistantEngine()

        try await runTurn("what's running?", origin: .user, engine: engine, fake: fake, id: id)
        for _ in 0..<3 {
            try await runTurn(
                "[ORE watch] a turn finished", origin: .watch,
                engine: engine, fake: fake, id: id
            )
        }

        let chatID = try #require(await engine.chatSummaries().first?.id)
        #expect(try await store.turnCount(chatID: chatID) == 4)
        #expect(try await store.turnCount(chatID: chatID, excludingOrigins: [.watch]) == 1)

        // And the number the window shows is the one the person would recognise.
        let summary = try #require(await engine.chatSummaries().first)
        #expect(summary.turnCount == 1)
    }

    /// The digest half of the same problem: a summary built from watch traffic
    /// describes the fleet, not what the user asked for.
    @Test func theSummarizableTranscriptLeavesOutFleetDigests() async throws {
        let (store, engine, fake, id) = try await makeAssistantEngine()

        try await runTurn(
            "remind me why we picked Postgres", origin: .user,
            engine: engine, fake: fake, id: id
        )
        try await runTurn(
            "[ORE watch] kailash finished a turn", origin: .watch,
            engine: engine, fake: fake, id: id
        )

        let chatID = try #require(await engine.chatSummaries().first?.id)
        let transcript = try #require(
            await store.conversationTranscript(chatID: chatID, excludingOrigins: [.watch])
        )
        #expect(transcript.contains("Postgres"))
        #expect(!transcript.contains("[ORE watch]"))
    }

    // MARK: - The verdict

    @Test func aConversationIsCompactedOnTurnsOrOnContext() {
        #expect(!AssistantCompaction.shouldCompact(userTurnCount: 3, usage: nil))
        #expect(AssistantCompaction.shouldCompact(
            userTurnCount: AssistantCompaction.turnCeiling, usage: nil
        ))

        // A harness that reports a window pulls the seam forward.
        let full = UsageReport(inputTokens: 80_000, contextWindow: 100_000)
        #expect(AssistantCompaction.shouldCompact(userTurnCount: 2, usage: full))

        // One that doesn't report a window must not be guessed at — the turn
        // count is the only honest signal left.
        let windowless = UsageReport(inputTokens: 80_000)
        #expect(!AssistantCompaction.shouldCompact(userTurnCount: 2, usage: windowless))
    }

    /// The warning has to precede the event, or the indicator is explaining a
    /// seam the user has already been surprised by.
    @Test func theWarningComesBeforeTheCompaction() {
        let turns = AssistantCompaction.turnCeiling - 1
        #expect(AssistantCompaction.isNearingCompaction(userTurnCount: turns, usage: nil))
        #expect(!AssistantCompaction.shouldCompact(userTurnCount: turns, usage: nil))
    }

    // MARK: - The seam

    @Test func everyNewAssistantConversationUsesTheLeanHarnessProfile() async throws {
        let (store, engine, _, id) = try await makeAssistantEngine()
        let chat = try await engine.createChat(CreateChatRequest(
            workspaceID: id,
            title: "Lean",
            harness: .codex,
            model: "gpt-5.6-sol",
            reasoningEffort: .xhigh
        ))
        let record = try #require(try await store.chat(chat.id))

        #expect(record.harness == HarnessKind.codex.rawValue)
        #expect(record.model == "gpt-5.6-luna")
        #expect(record.reasoningEffort == ReasoningEffort.low.rawValue)
    }

    /// The whole feature end to end. `FakeHarness.supportsAuxiliarySessions` is
    /// false, so this also pins the fallback path: a harness that cannot be
    /// asked for a summary must still be able to compact, because it is the one
    /// with the least headroom to begin with.
    @Test func compactionRetiresTheConversationAndSeedsItsSuccessor() async throws {
        let (store, engine, fake, id) = try await makeAssistantEngine()
        try await runTurn(
            "we're migrating kailash to Postgres this week", origin: .user,
            engine: engine, fake: fake, id: id
        )
        let original = try #require(await engine.chatSummaries().first?.id)

        let successor = try #require(await engine.compactAssistantConversation(chatID: original))
        #expect(successor.id != original)

        // The retired conversation is still there, still readable.
        let chats = try await engine.chatSummaries()
        #expect(chats.count == 2)
        #expect(chats.contains { $0.id == original })
        #expect(try await store.turns(chatID: original).count == 1)

        // Both sides of the seam are marked, so neither transcript reads as
        // having simply stopped or simply begun.
        let retiredMarks = try await store.chatTransitions(chatID: original).map(\.kind)
        let successorMarks = try await store.chatTransitions(chatID: successor.id).map(\.kind)
        #expect(retiredMarks.contains(.compacted))
        #expect(successorMarks.contains(.continuedFromCompaction))

        // And the successor is carrying what it needs to continue.
        let seed = try #require(await store.chat(successor.id)?.seedContext)
        #expect(seed.contains("Postgres"))
        #expect(seed.contains("[ORE conversation summary]"))
    }

    /// The summary is worth nothing if the model never sees it — and it must
    /// not be spent twice, or on a send that failed.
    @Test func theSeedReachesTheModelOnceAndIsThenSpent() async throws {
        let (store, engine, fake, id) = try await makeAssistantEngine()
        try await runTurn("the auth work is in kaguya", origin: .user, engine: engine, fake: fake, id: id)
        let original = try #require(await engine.chatSummaries().first?.id)
        let successor = try #require(await engine.compactAssistantConversation(chatID: original))

        _ = try await engine.send(SendMessageRequest(
            workspaceID: id, chatID: successor.id, text: "where was I?"
        ))
        let session = try #require(fake.latestSession)
        let first = try #require(await session.messageTexts().last)
        #expect(first.contains("[ORE conversation summary]"))
        #expect(first.contains("kaguya"))
        #expect(first.hasSuffix("where was I?"))

        // Spent: the next message is the user's words, not the digest again.
        #expect(try await store.chat(successor.id)?.seedContext == nil)
        session.runTurn(text: "ok")
        _ = await waitUntil {
            await (try? engine.chatSummaries().first { $0.id == successor.id }?.isTurnActive) == false
        }
        _ = try await engine.send(SendMessageRequest(
            workspaceID: id, chatID: successor.id, text: "and now?"
        ))
        let second = try #require(await session.messageTexts().last)
        #expect(!second.contains("[ORE conversation summary]"))
    }

    /// Feature (C). The model cannot see how far into a conversation it is, so
    /// it either re-asks what the user already answered or reports a summary as
    /// recall. Both are told to it, on every turn it might act on.
    @Test func theAssistantIsToldWhereInTheConversationItIs() async throws {
        let (_, engine, fake, id) = try await makeAssistantEngine()

        _ = try await engine.send(SendMessageRequest(workspaceID: id, text: "status?"))
        let session = try #require(fake.latestSession)
        #expect(await session.messageTexts().last?.contains("[ORE conversation state] turn 1") == true)

        session.runTurn(text: "ok")
        _ = await waitUntil { await (try? engine.chatSummaries().first?.isTurnActive) == false }

        _ = try await engine.send(SendMessageRequest(workspaceID: id, text: "and now?"))
        #expect(await session.messageTexts().last?.contains("[ORE conversation state] turn 2") == true)
    }

    /// A digest is machinery, not conversation — telling it which turn it is
    /// would only make the count it is excluded from look wrong.
    @Test func aFleetDigestIsNotGivenTheConversationStateNote() async throws {
        let (_, engine, fake, id) = try await makeAssistantEngine()

        _ = try await engine.send(SendMessageRequest(
            workspaceID: id, text: "[ORE watch] something happened", origin: .watch
        ))
        let session = try #require(fake.latestSession)
        #expect(await session.messageTexts().last?.contains("[ORE conversation state]") == false)
    }

    /// A conversation freshly compacted is most often reached first by a fleet
    /// digest, and "ORE Watch Cross-Workspace Events" tells the user nothing
    /// about what they were talking about.
    @Test func aFleetDigestNeverNamesAConversation() async throws {
        let (_, engine, fake, id) = try await makeAssistantEngine()
        let before = try #require(await engine.chatSummaries().first?.title)

        try await runTurn(
            "[ORE watch] Cross-workspace events since the last digest", origin: .watch,
            engine: engine, fake: fake, id: id
        )
        #expect(try await engine.chatSummaries().first?.title == before)
    }

    // MARK: - Verbosity

    /// Feature (A)'s spoken half depends entirely on this fork: the shared
    /// instruction caps every reply at "one or two short spoken sentences",
    /// which is the right rule for an agent narrating its work and the wrong
    /// one for an assistant being asked a question out loud.
    @Test func theAssistantMayGiveALongSpokenAnswerAndAProjectAgentMayNot() async throws {
        let (_, assistant, assistantHarness, _) = try await makeAssistantEngine()
        _ = try await assistant.ensureSession()
        let assistantPrompt = try #require(
            await assistantHarness.latestSession?.configuration.appendSystemPrompt
        )
        #expect(assistantPrompt.contains("as long as it honestly needs to be"))
        #expect(assistantPrompt.contains("Do not write the answer twice"))
        #expect(!assistantPrompt.contains("One or two short spoken sentences"))

        let fixture = try await GitFixture.initialized()
        let store = try OreStore()
        try await store.addRepository(RepositoryRecord(
            path: fixture.repository.path, name: "repo", defaultBranch: "main"
        ))
        let record = WorkspaceRecord(
            id: WorkspaceID.generate(), name: "project",
            repositoryPath: fixture.repository.path,
            worktreePath: fixture.repository.path,
            branch: "ore/x", baseBranch: "main", harness: .claudeCode
        )
        try await store.saveWorkspace(record)
        let projectHarness = FakeHarness()
        let project = WorkspaceEngine(
            record: record, store: store, git: fixture.git,
            harnessRegistry: HarnessRegistry(harnesses: [projectHarness])
        )
        _ = try await project.ensureSession()
        let projectPrompt = try #require(
            await projectHarness.latestSession?.configuration.appendSystemPrompt
        )
        #expect(projectPrompt.contains("One or two short spoken sentences"))
        #expect(!projectPrompt.contains("Do not write the answer twice"))
    }

    /// The regression that prompted this: a question with any shape to it came
    /// back spoken as "open the Assistant window", so the detail the user
    /// asked for out loud was never said out loud. The written half of the
    /// answer is still allowed to hold what can't be spoken — what is not
    /// allowed is sending the user to read *instead* of answering.
    @Test func theAssistantIsToldToSpeakTheAnswerRatherThanPointAtTheWindow() async throws {
        let (_, assistant, assistantHarness, _) = try await makeAssistantEngine()
        _ = try await assistant.ensureSession()
        let prompt = try #require(
            await assistantHarness.latestSession?.configuration.appendSystemPrompt
        )

        // A nuanced or multi-part question earns the longer spoken answer —
        // not only the literal "explain this to me" the rule used to name.
        #expect(prompt.contains("a question with more than one part"))
        #expect(prompt.contains("Answer every part of a multi-part question out loud"))

        // And the escape hatch is fenced: reading is where detail that can't
        // be spoken goes, never where the answer goes.
        #expect(prompt.contains("Never send the user to the window in place of an answer"))
        #expect(prompt.contains(
            "still say the substance and the verdict out loud before mentioning"
        ))

        // The assistant can inspect and query GitHub from a terminal, but the
        // editor and project implementation still belong to project agents.
        #expect(prompt.contains("terminal for lightweight inspection and GitHub context"))
        let configuration = try #require(await assistantHarness.latestSession?.configuration)
        #expect(configuration.allowedTools == ["mcp__ore"])
        #expect(!configuration.disallowedTools.contains("Bash"))
        for tool in ["Edit", "Write", "Read", "Task", "WebFetch"] {
            #expect(configuration.disallowedTools.contains(tool))
        }
    }
}
