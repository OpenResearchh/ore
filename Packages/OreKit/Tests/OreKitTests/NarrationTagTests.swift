import Foundation
import Testing

@testable import OreProtocol

/// The narration tag is a private wire convention between ORE's system prompt
/// and its translators. Both the whole-text extraction and the streaming
/// suppressor are pinned here, because a delimiter that leaks renders as raw
/// markup in the user's transcript.
struct NarrationTagTests {
    // MARK: - Whole-text extraction

    @Test func extractLeavesUntaggedTextAlone() {
        let text = "I fixed the flaky test and re-ran the suite."
        let (body, narration) = NarrationTag.extract(from: text)
        #expect(body == text)
        #expect(narration == nil)
    }

    @Test func extractSplitsTagAtEnd() {
        let (body, narration) = NarrationTag.extract(
            from: "All three tests pass now.\n\n<narration>I fixed the flaky test.</narration>"
        )
        #expect(body == "All three tests pass now.")
        #expect(narration == "I fixed the flaky test.")
    }

    @Test func extractStripsTagMidMessage() {
        let (body, narration) = NarrationTag.extract(
            from: "Before.\n<narration>Spoken line.</narration>\nAfter."
        )
        #expect(body == "Before.\n\nAfter.")
        #expect(narration == "Spoken line.")
    }

    @Test func extractLastTagWins() {
        let (body, narration) = NarrationTag.extract(
            from: "<narration>First.</narration>Body.<narration>Second.</narration>"
        )
        #expect(body == "Body.")
        #expect(narration == "Second.")
    }

    @Test func extractTreatsUnclosedTrailingOpenerAsNarration() {
        let (body, narration) = NarrationTag.extract(
            from: "Done with the rename.\n<narration>I renamed the module"
        )
        #expect(body == "Done with the rename.")
        #expect(narration == "I renamed the module")
    }

    /// The reported bug, verbatim in shape: an agent explaining ORE's own
    /// narration convention writes the delimiter inside a code span. Scanning
    /// for the *first* opener took that literal as the real tag, paired it with
    /// the closer at the end of the turn, and swallowed everything between —
    /// so the transcript stopped mid-sentence at the backtick, and the line
    /// spoken aloud was the rest of the message.
    @Test func extractIgnoresTheDelimiterWrittenAsProse() {
        let text = """
            Narration tag extraction has no length limit — a long `<narration>` \
            line survives intact.

            The stream filter matches it.

            <narration>I traced the pipeline and fixed the clip.</narration>
            """
        let (body, narration) = NarrationTag.extract(from: text)
        #expect(narration == "I traced the pipeline and fixed the clip.")
        #expect(body.hasSuffix("The stream filter matches it."))
        #expect(body.contains("`<narration>` line survives intact."))
    }

    @Test func extractIgnoresEmptyTag() {
        let (body, narration) = NarrationTag.extract(from: "Body.\n<narration> </narration>")
        #expect(body == "Body.")
        #expect(narration == nil)
    }

    // MARK: - Stream filter

    /// Runs deltas through a fresh filter and returns what a live transcript
    /// would have shown, plus the block's settlement.
    private func run(_ deltas: [String]) -> (shown: String, flush: String, narration: String?) {
        var filter = NarrationTagStreamFilter()
        var shown = ""
        for delta in deltas { shown += filter.filter(delta) }
        let (flush, narration) = filter.finish()
        return (shown, flush, narration)
    }

    @Test func filterPassesPlainTextThrough() {
        let result = run(["Hello ", "there."])
        #expect(result.shown == "Hello there.")
        #expect(result.flush.isEmpty)
        #expect(result.narration == nil)
    }

    @Test func filterSwallowsTagSplitAcrossManyDeltas() {
        let result = run(["Done.", "\n<narr", "ation>I fixed", " it.</narr", "ation>"])
        #expect(result.shown == "Done.\n")
        #expect(result.flush.isEmpty)
        #expect(result.narration == "I fixed it.")
    }

    @Test func filterFlushesFalsePrefix() {
        // "<narr" alone might still become the opener; "<narrow the aisle"
        // cannot, and every character must reappear.
        let result = run(["walk down ", "<narr", "ow the aisle"])
        #expect(result.shown == "walk down <narrow the aisle")
        #expect(result.flush.isEmpty)
        #expect(result.narration == nil)
    }

    @Test func filterFlushesHeldPrefixAtBlockEnd() {
        let result = run(["text ends in <na"])
        #expect(result.shown == "text ends in ")
        #expect(result.flush == "<na")
        #expect(result.narration == nil)
    }

    @Test func filterYieldsUnclosedTagAtBlockEnd() {
        let result = run(["Done.\n<narration>Halfway through a spoken line"])
        #expect(result.shown == "Done.\n")
        #expect(result.flush.isEmpty)
        #expect(result.narration == "Halfway through a spoken line")
    }

    /// The reported bug's streaming half. The live view must reach the same
    /// answer as `extract`, or the message is whole in the transcript and
    /// truncated while it streams.
    @Test func filterGivesBackTheDelimiterWrittenAsProse() {
        let result = run([
            "A long `<narration>", "` line survives.\n\nMore prose.\n\n",
            "<narration>Real spoken line.</narration>",
        ])
        #expect(result.shown.contains("A long `<narration>` line survives."))
        #expect(result.shown.contains("More prose."))
        #expect(result.narration == "Real spoken line.")
    }

    /// The same prose, in a turn that never emits a real tag. The unclosed
    /// opener must not run to the end of the message and swallow it.
    @Test func filterKeepsProseWhenNoRealTagEverArrives() {
        let result = run(["The `<narration>", "` tag is stripped.\n\nThat's the whole convention."])
        #expect(result.shown + result.flush
            == "The `<narration>` tag is stripped.\n\nThat's the whole convention.")
        #expect(result.narration == nil)
    }

    @Test func extractKeepsProseWhenNoRealTagEverArrives() {
        let text = "The `<narration>` tag is stripped.\n\nThat's the whole convention."
        let (body, narration) = NarrationTag.extract(from: text)
        #expect(body == text)
        #expect(narration == nil)
    }

    @Test func filterEmitsProseAfterCloser() {
        let result = run(["<narration>Spoken.</narration>trailing prose"])
        #expect(result.shown == "trailing prose")
        #expect(result.narration == "Spoken.")
    }

    @Test func filterLastTagWinsAcrossOneBlock() {
        let result = run(["<narration>First.</narration>", "<narration>Second.</narration>"])
        #expect(result.shown.isEmpty)
        #expect(result.narration == "Second.")
    }
}
