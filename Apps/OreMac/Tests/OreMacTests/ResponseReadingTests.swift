import AppKit
import OreProtocol
import Testing

@testable import OreMac

struct ResponseReadingTests {
    @Test func finishedTopLevelAssistantProseIsSpeakable() {
        var row = TranscriptRow(
            id: "a1", turnID: TurnID(rawValue: "t1"),
            kind: .assistantText, text: "The tests pass."
        )
        row.isComplete = true
        #expect(ResponseReading.isSpeakableResponse(row))
    }

    @Test func streamingOrNestedOrEmptyRepliesAreNotSpeakable() {
        var streaming = TranscriptRow(
            id: "a1", turnID: TurnID(rawValue: "t1"),
            kind: .assistantText, text: "Still writing"
        )
        streaming.isComplete = false
        #expect(!ResponseReading.isSpeakableResponse(streaming))

        var nested = TranscriptRow(
            id: "a2", turnID: TurnID(rawValue: "t1"),
            kind: .assistantText, text: "From a subagent."
        )
        nested.isComplete = true
        nested.parentToolCallID = ToolCallID(rawValue: "task-1")
        #expect(!ResponseReading.isSpeakableResponse(nested))

        var empty = TranscriptRow(
            id: "a3", turnID: TurnID(rawValue: "t1"),
            kind: .assistantText, text: "   \n"
        )
        empty.isComplete = true
        #expect(!ResponseReading.isSpeakableResponse(empty))

        var user = TranscriptRow(
            id: "u1", turnID: TurnID(rawValue: "t1"),
            kind: .userMessage, text: "Please do this."
        )
        user.isComplete = true
        #expect(!ResponseReading.isSpeakableResponse(user))
    }

    @Test func fullModeSpeaksProseAndSkipsCodeFences() {
        let markdown = """
        I'll start with the failing tests.

        ```
        swift test --filter Foo
        ```

        Then I'll open a PR.
        """
        let script = ResponseReading.script(
            markdown: markdown, displayed: displayed(markdown), mode: .full
        )
        #expect(script.spokenText.contains("failing tests"))
        #expect(script.spokenText.contains("open a PR"))
        #expect(!script.spokenText.contains("swift test"))
        #expect(!script.spokenText.contains("```"))
    }

    @Test func importantModeKeepsHeadingsListsAndBold() {
        let markdown = """
        # Plan

        A long preamble the ear does not need.

        ## Next

        - Run the suite
        - Open the pull request

        The **crux** is the permission card.
        """
        let script = ResponseReading.script(
            markdown: markdown, displayed: displayed(markdown), mode: .important
        )
        #expect(script.spokenText.contains("Plan"))
        #expect(script.spokenText.contains("Next"))
        #expect(script.spokenText.contains("Run the suite"))
        #expect(script.spokenText.contains("Open the pull request"))
        #expect(script.spokenText.contains("crux"))
        #expect(!script.spokenText.contains("long preamble"))
    }

    @Test func importantModeFallsBackToFullWhenNothingIsMarked() {
        let markdown = "I'll audit the permission cards first."
        let important = ResponseReading.script(
            markdown: markdown, displayed: displayed(markdown), mode: .important
        )
        let full = ResponseReading.script(
            markdown: markdown, displayed: displayed(markdown), mode: .full
        )
        #expect(important.spokenText == full.spokenText)
        #expect(important.spokenText.contains("audit the permission cards first"))
    }

    @Test func highlightFollowsTheSpokenWordThenTheSentence() {
        let markdown = "Kaguya's agent is on it. Then it ships."
        let displayed = displayed(markdown)
        let script = ResponseReading.script(
            markdown: markdown, displayed: displayed, mode: .full
        )
        #expect(!script.spans.isEmpty)

        let firstWord = script.highlightRange(atSpokenUTF16: 8)
        #expect(range(firstWord, in: displayed)?.contains("Kaguya") == true)

        let secondSentenceStart = script.spans.last.map { $0.spoken.location } ?? 0
        let later = script.highlightRange(atSpokenUTF16: secondSentenceStart + 1)
        #expect(range(later, in: displayed)?.contains("ships") == true
                || range(later, in: displayed)?.contains("Then") == true)
    }

    @Test func headingsLocateInTheRenderedString() throws {
        let markdown = "# Plan\n\nI'll start with the failing tests."
        let displayed = displayed(markdown)
        let script = ResponseReading.script(
            markdown: markdown, displayed: displayed, mode: .important
        )
        let heading = try #require(script.spans.first)
        #expect(heading.display.length > 0)
        let shown = (displayed as NSString).substring(with: heading.display)
        #expect(shown.contains("Plan"))
        #expect(!shown.contains("#"))
    }

    @Test func sentencesSplitOnTerminatorsButKeepATrailingFragment() {
        #expect(ResponseReading.sentences(in: "One. Two! Three?") == ["One.", "Two!", "Three?"])
        #expect(ResponseReading.sentences(in: "No terminator yet") == ["No terminator yet"])
        #expect(ResponseReading.sentences(in: "  ") == [])
    }

    @Test func duplicateNeedlesAreLocatedInOrder() {
        let markdown = """
        # Plan

        Do the plan.

        ## Plan
        """
        let displayed = displayed(markdown)
        let script = ResponseReading.script(
            markdown: markdown, displayed: displayed, mode: .important
        )
        let headingSpans = script.spans.filter {
            let text = (displayed as NSString).substring(with: $0.display)
            return text.contains("Plan")
        }
        #expect(headingSpans.count >= 2)
        #expect(headingSpans[0].display.location < headingSpans[1].display.location)
    }
}

@MainActor
struct ResponseReadingMicTests {
    @Test func aTapWhileTheMicIsOpenDoesNotTalkOverDictation() {
        let engine = NarrationEngine()
        engine.setMicActive(true)
        defer {
            engine.stopAll()
            engine.setMicActive(false)
        }
        engine.toggleResponseReading(
            rowID: "row-1",
            chatID: ChatID(rawValue: "response-read-mic"),
            markdown: "The tests pass.",
            displayed: "The tests pass."
        )
        #expect(engine.responsePlaybackPhase == .paused)
        #expect(engine.responsePlaybackRowID == "row-1")
        #expect(!engine.neuralVoice.isSpeaking)
        #expect(!engine.neuralVoice.isPaused)
    }
}

private func displayed(_ markdown: String) -> String {
    MarkdownRenderer(
        baseFont: .systemFont(ofSize: 13),
        textColor: .labelColor
    ).render(markdown).string
}

private func range(_ range: NSRange?, in string: String) -> String? {
    guard let range, range.length > 0 else { return nil }
    let ns = string as NSString
    guard NSMaxRange(range) <= ns.length else { return nil }
    return ns.substring(with: range)
}
