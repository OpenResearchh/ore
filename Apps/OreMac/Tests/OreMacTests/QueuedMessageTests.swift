import Foundation
import OreProtocol
import Testing

@testable import OreMac

/// The composer's promise ("send" vs "queue") has to match what the engine
/// actually does with the message, or a sent message appears to vanish.
@MainActor
struct QueuedMessageTests {
    private func started(_ state: ChatState, turn: String = "t1") -> TurnID {
        let id = TurnID(rawValue: turn)
        state.apply(.turnStarted(TurnStarted(turnID: id)))
        return id
    }

    @Test func anIdleChatSendsRatherThanQueues() {
        let state = ChatState()
        #expect(!state.willQueueNextMessage)
        #expect(state.queueHint == nil)
    }

    @Test func aRunningTurnQueuesTheNextMessage() {
        let state = ChatState()
        _ = started(state)
        #expect(state.willQueueNextMessage)
    }

    // The regression this whole change exists for: an agent blocked on a
    // permission prompt reads as not-busy, but its turn is still open, so the
    // engine queues. The composer used to say "Send".
    @Test func awaitingInputStillQueuesEvenThoughTheAgentLooksIdle() {
        let state = ChatState()
        let turnID = started(state)
        state.apply(.permissionRequest(PermissionRequest(
            turnID: turnID,
            id: PermissionRequestID(rawValue: "p1"),
            toolName: "Bash",
            input: .object([:])
        )))

        #expect(state.status == .awaitingInput)
        #expect(!state.isBusy, "an agent waiting on a human is not working")
        #expect(state.willQueueNextMessage, "but its turn is still open")
        #expect(state.queueHint?.contains("waiting on your answer") == true)
    }

    @Test func aQueuedMessageDoesNotFakeARunningTurn() {
        let state = ChatState()
        _ = started(state)
        state.appendUserMessage("second thought", comments: [])

        let row = state.rows.last
        #expect(row?.kind == .userMessage)
        #expect(row?.isQueued == true)
        // The old bug: an optimistic `.requesting` started a spinner and an
        // elapsed timer for a message sitting in a queue.
        #expect(state.status != .requesting)
    }

    @Test func aQueuedRowBecomesRealWhenItsTurnStarts() {
        let state = ChatState()
        let first = started(state)
        state.appendUserMessage("later", comments: [])
        #expect(state.rows.last?.isQueued == true)

        state.apply(.turnCompleted(TurnResult(turnID: first, outcome: .completed)))
        #expect(!state.willQueueNextMessage)

        let second = started(state, turn: "t2")
        let row = state.rows.last
        #expect(row?.isQueued == false)
        #expect(row?.turnID == second, "the drained row joins the turn it became")
    }

    @Test func queuedRowsDrainInTheOrderTheyWereWritten() {
        let state = ChatState()
        let first = started(state)
        state.appendUserMessage("one", comments: [])
        state.appendUserMessage("two", comments: [])
        state.apply(.turnCompleted(TurnResult(turnID: first, outcome: .completed)))

        _ = started(state, turn: "t2")
        let queued = state.rows.filter(\.isQueued).map(\.text)
        #expect(queued == ["two"], "the oldest pending message is the one that drained")
    }

    @Test func sendingWhileIdleClaimsTheTurnBeforeTheHarnessReplies() {
        // The gap between pressing send and `.turnStarted` arriving: a second
        // message typed here must queue, not race the first one to the harness.
        let state = ChatState()
        state.appendUserMessage("first", comments: [])

        #expect(state.rows.last?.isQueued == false)
        #expect(state.status == .requesting)
        #expect(state.willQueueNextMessage, "a second message now has to queue")
    }

    @Test func aDeadSessionStopsQueueingBehindATurnThatWillNeverFinish() {
        let state = ChatState()
        _ = started(state)
        #expect(state.willQueueNextMessage)

        state.apply(.sessionEnded(SessionEnded(
            sessionID: SessionID(rawValue: "s1"), exitCode: 1, wasUnexpected: true
        )))
        #expect(!state.willQueueNextMessage)
    }

    @Test func theServerGateWinsWhenTheClientHasDrifted() {
        let state = ChatState()
        _ = started(state)
        #expect(state.willQueueNextMessage)

        // A turn that ended in a way no event described.
        state.reconcileTurnActive(false)
        #expect(!state.willQueueNextMessage)
    }

    @Test func anOptimisticClaimSurvivesASummaryThatCrossedItInFlight() {
        // The summary was built before our send reached the engine; adopting its
        // stale `false` would let the very next message bypass the queue.
        let state = ChatState()
        state.appendUserMessage("first", comments: [])
        state.reconcileTurnActive(false)
        #expect(state.willQueueNextMessage)
    }
}
