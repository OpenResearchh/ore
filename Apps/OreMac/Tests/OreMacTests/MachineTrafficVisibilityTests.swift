import Foundation
import OreProtocol
import Testing

@testable import OreMac

/// ORE talks to its own assistant on a timer — fleet digests and needs-you
/// notices, carrying instructions like "reply with exactly SKIP". That traffic
/// was rendered in the Assistant window as though the user had typed it, in the
/// user's own accent colour, which is the single loudest thing in that window
/// for anyone with a busy fleet.
@MainActor
struct MachineTrafficVisibilityTests {
    private func row(
        _ text: String,
        kind: TranscriptRow.Kind = .userMessage,
        origin: MessageOrigin = .user,
        id: String = "r1"
    ) -> TranscriptRow {
        var row = TranscriptRow(
            id: id, turnID: TurnID(rawValue: "t1"), kind: kind, text: text
        )
        row.origin = origin
        row.isComplete = true
        return row
    }

    private func display(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        TranscriptDisplay.rows(
            from: rows,
            keepLiveTurnExpanded: false,
            expanded: [],
            memo: TranscriptDisplay.Memo(),
            hidingPlanTurnID: nil,
            revision: 1
        )
    }

    @Test func aWatchDigestIsNotDrawnInTheTranscript() {
        let digest = row(
            """
            [ORE watch] Cross-workspace events since the last digest:
            - kailash finished a turn

            Reply with exactly SKIP if none of it deserves interrupting the user.
            """,
            origin: .watch
        )
        #expect(display([digest]).isEmpty)
    }

    @Test func aNeedsYouNoticeIsNotDrawnInTheTranscript() {
        let notice = row(
            "[ORE needs you] A tab wants to run Bash. Do not call "
                + "ResolveChatPermission unless they tell you to.",
            origin: .watch
        )
        #expect(display([notice]).isEmpty)
    }

    @Test func theSkipVerdictIsNotDrawnEither() {
        // The other half of a digest. "SKIP" is a token addressed to ORE.
        #expect(display([row("SKIP", kind: .assistantText)]).isEmpty)
        #expect(display([row("  skip.\n", kind: .assistantText)]).isEmpty)
    }

    @Test func aRealVerdictSurvives() {
        // A digest the assistant judged worth surfacing is the whole point of
        // the feature — it must not be filtered with the SKIPs.
        let verdict = row(
            "Kaguya's agent finished the migration you asked about.",
            kind: .assistantText
        )
        #expect(display([verdict]).count == 1)
    }

    @Test func aReplyThatMerelyMentionsSkippingSurvives() {
        let reply = row(
            "I'd skip that one — it's already covered by the other tab.",
            kind: .assistantText
        )
        #expect(display([reply]).count == 1)
        #expect(!TranscriptDisplay.isSkipVerdict(reply.text))
    }

    @Test func theUsersOwnWordsAreUntouched() {
        let mine = row("what's happening across my workspaces?")
        let assistants = row("Fix the flaky login test", origin: .agent, id: "r2")
        let shown = display([mine, assistants])
        #expect(shown.count == 2)
        #expect(shown.map(\.origin) == [.user, .agent])
    }

    @Test func aLocallyDrawnPromptKeepsTheOriginItWasSentWith() {
        // The engine's echo of this submission is dropped as a duplicate, so
        // the origin set on the optimistic row is the only one the transcript
        // will ever have. Defaulting it to `.user` is what put ORE's words in
        // the user's mouth.
        let state = ChatState()
        state.appendUserMessage("[ORE watch] …", comments: [], origin: .watch)

        #expect(state.rows.count == 1)
        #expect(state.rows[0].origin == .watch)
        #expect(display(state.rows).isEmpty)
    }
}
