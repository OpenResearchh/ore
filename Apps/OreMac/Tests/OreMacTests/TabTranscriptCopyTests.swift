import OreProtocol
import Testing

@testable import OreMac

struct TabTranscriptCopyTests {
    @Test func shortCopyKeepsOnlyTheLatestThreeTurns() {
        let rows = (1...4).flatMap { number in
            let turn = TurnID(rawValue: "t\(number)")
            return [
                TranscriptRow(
                    id: "u\(number)", turnID: turn,
                    kind: .userMessage, text: "question \(number)"
                ),
                TranscriptRow(
                    id: "a\(number)", turnID: turn,
                    kind: .assistantText, text: "answer \(number)"
                ),
            ]
        }

        let copied = TabTranscriptCopy.render(
            tabTitle: "Optics", agentName: "Claude", rows: rows, length: .short
        )

        #expect(!copied.contains("question 1"))
        #expect(copied.contains("question 2"))
        #expect(copied.contains("answer 4"))
        #expect(copied.contains("latest 3 conversational turns"))
    }

    @Test func fullCopyKeepsTheWholeConversationButDropsMachineTraffic() {
        let first = TurnID(rawValue: "t1")
        let second = TurnID(rawValue: "t2")
        var watch = TranscriptRow(
            id: "watch", turnID: first, kind: .userMessage, text: "fleet digest"
        )
        watch.origin = .watch
        let rows = [
            TranscriptRow(id: "u1", turnID: first, kind: .userMessage, text: "start here"),
            TranscriptRow(id: "thinking", turnID: first, kind: .thinking, text: "private thought"),
            TranscriptRow(id: "tool", turnID: first, kind: .toolCall, text: "huge tool payload"),
            TranscriptRow(id: "a1", turnID: first, kind: .assistantText, text: "first answer"),
            watch,
            TranscriptRow(id: "u2", turnID: second, kind: .userMessage, text: "continue"),
            TranscriptRow(id: "a2", turnID: second, kind: .assistantText, text: "finished"),
        ]

        let copied = TabTranscriptCopy.render(
            tabTitle: "Optics", agentName: "Claude", rows: rows, length: .full
        )

        #expect(copied.contains("start here"))
        #expect(copied.contains("finished"))
        #expect(!copied.contains("private thought"))
        #expect(!copied.contains("huge tool payload"))
        #expect(!copied.contains("fleet digest"))
        #expect(copied.contains("full conversational transcript"))
    }

    @Test func consecutiveAssistantBlocksShareOneSpeakerHeading() {
        let turn = TurnID(rawValue: "t1")
        let rows = [
            TranscriptRow(id: "a1", turnID: turn, kind: .assistantText, text: "first"),
            TranscriptRow(id: "a2", turnID: turn, kind: .assistantText, text: "second"),
        ]

        let copied = TabTranscriptCopy.render(
            tabTitle: "Optics", agentName: "Claude", rows: rows, length: .full
        )

        #expect(copied.components(separatedBy: "Claude:\n").count == 2)
        #expect(copied.contains("first\n\nsecond"))
    }
}
