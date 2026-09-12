import OreProtocol
import Testing

@testable import OreMac

/// Ordering of a message that was queued behind a running turn.
///
/// The transcript is a plain array rendered in insertion order, and a queued
/// row is appended the moment the user presses send — but the turn already
/// running keeps appending after it. So the row's position is only correct
/// while it is hidden inside the "Queued messages" group; the instant it goes
/// inline it appears above everything that streamed while it waited, which
/// reads as the agent replying before it was asked.
@Suite("A queued message lands after the reply it waited on")
@MainActor
struct QueuedMessageOrderTests {
    /// Streams a chunk of assistant text into the open turn.
    private func streamText(_ state: ChatState, turn: TurnID, block: String, _ text: String) {
        state.apply(
            .textDelta(BlockDelta(turnID: turn, blockID: BlockID(rawValue: block), text: text))
        )
    }

    @Test("Dispatching a queued message moves it below the previous response")
    func queuedMessageLandsLast() {
        let state = ChatState()
        let firstTurn = TurnID(rawValue: "turn-1")

        // A turn is running and has said something.
        state.appendUserMessage("first question", comments: [])
        state.apply(.turnStarted(TurnStarted(turnID: firstTurn)))
        streamText(state, turn: firstTurn, block: "b1", "beginning of the answer")

        // The user queues a follow-up while it is still working.
        #expect(state.willQueueNextMessage, "a running turn should queue the next message")
        state.appendUserMessage("second question", comments: [])
        #expect(state.rows.last?.isQueued == true)

        // The first turn keeps working after the message was queued, and
        // produces new rows — a fresh text block and a tool call. This is the
        // part that used to strand the queued row mid-transcript.
        //
        // It has to be new *rows*: a delta with the same block id mutates the
        // previous row in place rather than appending, so reusing "b1" here
        // would leave the queued message legitimately last and the test would
        // pass against the bug.
        streamText(state, turn: firstTurn, block: "b2", "…and the rest of the answer")
        state.apply(
            .toolCall(
                ToolCall(
                    turnID: firstTurn,
                    id: ToolCallID(rawValue: "tc-1"),
                    name: "Search",
                    input: .null
                )
            )
        )
        state.apply(.turnCompleted(TurnResult(turnID: firstTurn, outcome: .completed)))

        // The queued message is now dispatched.
        state.apply(.turnStarted(TurnStarted(turnID: TurnID(rawValue: "turn-2"))))

        let queuedIndex = try? #require(
            state.rows.firstIndex { $0.kind == .userMessage && $0.text == "second question" }
        )
        let lastAssistantIndex = state.rows.lastIndex { $0.kind != .userMessage }

        #expect(state.rows.first(where: { $0.text == "second question" })?.isQueued == false)
        if let queuedIndex, let lastAssistantIndex {
            #expect(
                queuedIndex > lastAssistantIndex,
                "the dispatched message must sit below the reply it waited on, not above it"
            )
        }
    }

    /// Two messages queued back to back must keep their relative order when
    /// they are dispatched one turn at a time.
    @Test("Several queued messages keep their order")
    func queueOrderIsStable() {
        let state = ChatState()
        let firstTurn = TurnID(rawValue: "turn-1")
        state.appendUserMessage("first", comments: [])
        state.apply(.turnStarted(TurnStarted(turnID: firstTurn)))

        state.appendUserMessage("queued A", comments: [])
        state.appendUserMessage("queued B", comments: [])
        streamText(state, turn: firstTurn, block: "b1", "answering the first")
        state.apply(.turnCompleted(TurnResult(turnID: firstTurn, outcome: .completed)))

        state.apply(.turnStarted(TurnStarted(turnID: TurnID(rawValue: "turn-2"))))
        streamText(state, turn: TurnID(rawValue: "turn-2"), block: "b2", "answering A")
        state.apply(.turnCompleted(TurnResult(turnID: TurnID(rawValue: "turn-2"), outcome: .completed)))
        state.apply(.turnStarted(TurnStarted(turnID: TurnID(rawValue: "turn-3"))))

        let a = state.rows.firstIndex { $0.text == "queued A" }
        let b = state.rows.firstIndex { $0.text == "queued B" }
        #expect(a != nil && b != nil)
        if let a, let b { #expect(a < b, "queued messages must dispatch oldest first") }
    }

    // MARK: - Which message was actually sent

    private func dispatch(_ state: ChatState, _ submissionID: String, _ text: String) {
        state.applyPromptSubmission(PromptSubmission(
            submissionID: submissionID, text: text, isQueued: false
        ))
    }

    /// Position is not identity. With two messages queued and the first one
    /// deleted, the turn that starts belongs to the second — claiming the
    /// oldest queued row instead marked a message as sent that never was.
    @Test("Deleting the first queued message does not misattribute the next turn")
    func deletingTheFirstQueuedMessage() {
        let state = ChatState()
        let first = TurnID(rawValue: "turn-1")
        state.appendUserMessage("first", comments: [])
        state.apply(.turnStarted(TurnStarted(turnID: first)))

        state.appendUserMessage("queued A", comments: [], submissionID: "a")
        state.appendUserMessage("queued B", comments: [], submissionID: "b")
        state.removeQueuedRow(submissionID: "a")
        #expect(!state.rows.contains { $0.text == "queued A" }, "a deleted message leaves nothing")

        state.apply(.turnCompleted(TurnResult(turnID: first, outcome: .completed)))
        dispatch(state, "b", "queued B")
        state.apply(.turnStarted(TurnStarted(turnID: TurnID(rawValue: "turn-2"))))

        let sent = state.rows.filter { $0.kind == .userMessage && !$0.isQueued }
        #expect(sent.map(\.text) == ["first", "queued B"])
        #expect(!state.rows.contains { $0.isQueued }, "nothing is left marked queued")
    }

    /// An edited queued message is the message that gets sent, so the row has
    /// to say what the agent was given.
    @Test("Editing a queued message updates the row that is dispatched")
    func editingAQueuedMessage() {
        let state = ChatState()
        let first = TurnID(rawValue: "turn-1")
        state.appendUserMessage("first", comments: [])
        state.apply(.turnStarted(TurnStarted(turnID: first)))

        state.appendUserMessage("queued A", comments: [], submissionID: "a")
        state.updateQueuedRow(submissionID: "a", text: "queued A, but better")

        state.apply(.turnCompleted(TurnResult(turnID: first, outcome: .completed)))
        dispatch(state, "a", "queued A, but better")
        state.apply(.turnStarted(TurnStarted(turnID: TurnID(rawValue: "turn-2"))))

        let texts = state.rows.filter { $0.kind == .userMessage }.map(\.text)
        #expect(texts == ["first", "queued A, but better"])
        #expect(texts.filter { $0.hasPrefix("queued A") }.count == 1, "and only once")
    }

    /// The queue does not have to drain in the order it was filled — the
    /// engine sends whichever row it dequeued, and says which one that was.
    @Test("The dispatched message is the one the engine names")
    func theEngineDecidesWhichQueuedMessageWasSent() {
        let state = ChatState()
        let first = TurnID(rawValue: "turn-1")
        state.appendUserMessage("first", comments: [])
        state.apply(.turnStarted(TurnStarted(turnID: first)))
        state.appendUserMessage("queued A", comments: [], submissionID: "a")
        state.appendUserMessage("queued B", comments: [], submissionID: "b")
        state.apply(.turnCompleted(TurnResult(turnID: first, outcome: .completed)))

        dispatch(state, "b", "queued B")
        state.apply(.turnStarted(TurnStarted(turnID: TurnID(rawValue: "turn-2"))))

        #expect(state.rows.first { $0.text == "queued B" }?.isQueued == false)
        #expect(state.rows.first { $0.text == "queued A" }?.isQueued == true)
        #expect(state.rows.last?.text == "queued B", "the sent message goes to the end")
    }

    /// The engine re-announces the same submission when the queue lets it
    /// through, and a window that reconnects can see it again. Neither may
    /// add a second copy.
    @Test("A repeated announcement never duplicates the message")
    func aRepeatedAnnouncementIsIgnored() {
        let state = ChatState()
        state.appendUserMessage("first", comments: [])
        state.apply(.turnStarted(TurnStarted(turnID: TurnID(rawValue: "turn-1"))))
        state.appendUserMessage("queued A", comments: [], submissionID: "a")

        dispatch(state, "a", "queued A")
        dispatch(state, "a", "queued A")
        state.apply(.turnStarted(TurnStarted(turnID: TurnID(rawValue: "turn-2"))))
        dispatch(state, "a", "queued A")

        #expect(state.rows.filter { $0.text == "queued A" }.count == 1)
        #expect(state.rows.first { $0.text == "queued A" }?.isQueued == false)
    }

    /// The ordinary path must be untouched: a message sent to an idle agent
    /// is never queued and never moves.
    @Test("An unqueued message is unaffected")
    func normalSendIsUnchanged() {
        let state = ChatState()
        state.appendUserMessage("hello", comments: [])
        #expect(state.rows.count == 1)
        #expect(state.rows[0].isQueued == false)
        state.apply(.turnStarted(TurnStarted(turnID: TurnID(rawValue: "turn-1"))))
        #expect(state.rows.count == 1, "a normal send must not duplicate or move its row")
        #expect(state.rows[0].text == "hello")
    }
}
