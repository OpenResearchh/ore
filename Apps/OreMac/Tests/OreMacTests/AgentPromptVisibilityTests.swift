import Foundation
import OreProtocol
import Testing

@testable import OreMac

/// A prompt the assistant sends lands in a chat the user was never typing in,
/// so nothing in this window drew it. If the transcript doesn't pick it up from
/// the engine, the tab sits there working on something the user cannot read.
@MainActor
struct AgentPromptVisibilityTests {
    private func submission(
        _ text: String,
        id: String = "s1",
        origin: MessageOrigin = .agent,
        isQueued: Bool = false
    ) -> PromptSubmission {
        PromptSubmission(
            submissionID: id, text: text, origin: origin, isQueued: isQueued
        )
    }

    @Test func anAssistantPromptAppearsInTheTranscript() {
        let state = ChatState()
        state.applyPromptSubmission(submission("Fix the flaky login test"))

        #expect(state.rows.count == 1)
        #expect(state.rows[0].kind == .userMessage)
        #expect(state.rows[0].text == "Fix the flaky login test")
        #expect(state.rows[0].origin == .agent)
    }

    @Test func anAssistantPromptIsLabelledAndTintedApartFromTheUsers() {
        let mine = TranscriptRow(
            id: "a", turnID: TurnID(rawValue: "t1"), kind: .userMessage, text: "hi"
        )
        var theirs = mine
        theirs.origin = .agent

        #expect(TranscriptCell.badgeText(for: mine).isEmpty)
        #expect(TranscriptCell.badgeText(for: theirs) == "SENT BY ORE")
        #expect(
            TranscriptCell.background(for: mine)
                != TranscriptCell.background(for: theirs),
            "the two prompts must not share a bubble colour"
        )
    }

    // The badge costs a line, and the row height is measured separately from the
    // cell that draws it. If the two disagree the label overlaps the prompt.
    @Test func theBadgeIsCountedInTheRowHeight() {
        let mine = TranscriptRow(
            id: "a", turnID: TurnID(rawValue: "t1"), kind: .userMessage, text: "hi"
        )
        var theirs = mine
        theirs.origin = .agent

        #expect(
            TranscriptCell.height(for: theirs, width: 600)
                > TranscriptCell.height(for: mine, width: 600)
        )
    }

    @Test func aQueuedAssistantPromptSaysBothThings() {
        var row = TranscriptRow(
            id: "a", turnID: TurnID(rawValue: "t1"), kind: .userMessage, text: "hi"
        )
        row.origin = .agent
        row.isQueued = true

        let badge = TranscriptCell.badgeText(for: row)
        #expect(badge.contains("ORE"), "who sent it")
        #expect(badge.contains("QUEUED"), "and that it hasn't run yet")
    }

    // The composer draws its own message the moment the user presses send, so
    // the engine's echo of that same submission has to be recognised and
    // dropped — otherwise every message the user types appears twice.
    @Test func theEchoOfAMessageThisWindowSentIsNotDrawnTwice() {
        let state = ChatState()
        state.appendUserMessage(
            "ship it", comments: [], submissionID: "s1"
        )
        #expect(state.rows.count == 1)

        state.applyPromptSubmission(submission("ship it", id: "s1", origin: .user))

        #expect(state.rows.count == 1, "the echo is the row already on screen")
        #expect(state.rows[0].origin == .user)
    }

    // A prompt that arrives behind an open turn is parked by the engine. Drawing
    // it as sent would claim a turn started, and run a spinner and an elapsed
    // timer against a message sitting in a queue.
    @Test func aQueuedAssistantPromptDoesNotClaimATurn() {
        let state = ChatState()
        state.applyPromptSubmission(submission("later", isQueued: true))

        #expect(state.rows[0].isQueued)
        #expect(!state.isTurnActive)
        #expect(state.status != .requesting)
    }

    @Test func anUnqueuedAssistantPromptStartsTheTurnIndicator() {
        let state = ChatState()
        state.applyPromptSubmission(submission("now"))

        #expect(!state.rows[0].isQueued)
        #expect(state.isTurnActive, "the tab must look busy, not idle")
        #expect(state.status == .requesting)
    }

    // The queued row and the send that follows it share one submission id, so
    // the drained message is recognised as the row already on screen rather
    // than added beneath it.
    @Test func aQueuedPromptIsNotRedrawnWhenTheQueueLetsItThrough() {
        let state = ChatState()
        state.applyPromptSubmission(submission("later", id: "s7", isQueued: true))
        state.applyPromptSubmission(submission("later", id: "s7", isQueued: false))

        #expect(state.rows.count == 1)
        #expect(state.rows[0].isQueued, "still queued until a turn claims it")
    }
}
