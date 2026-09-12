import Testing

@testable import OreMac

/// The assistant's opening sentence, lifted out of a reply while it is still
/// streaming. Half a sentence read aloud is worse than the silence it
/// replaced, so nothing is returned until one has actually closed.
struct AssistantOpenerTests {
    @Test func nothingIsSaidUntilASentenceCloses() {
        #expect(AssistantOpener.firstSentence(of: "I'll check the fleet and") == nil)
        #expect(AssistantOpener.firstSentence(of: "") == nil)
    }

    @Test func theFirstClosedSentenceIsTheOpener() {
        let streamed = "I'll check the fleet and report back. Then I'll open a PR."
        #expect(AssistantOpener.firstSentence(of: streamed) == "I'll check the fleet and report back.")
    }

    @Test func aQuestionOrExclamationClosesItToo() {
        #expect(AssistantOpener.firstSentence(of: "Shall I start with the failing tests? Yes.")
            == "Shall I start with the failing tests?")
    }

    /// "Sure." is an acknowledgement, not an opener — worth waiting one more
    /// sentence for something with content in it.
    @Test func aSlightFirstSentenceBorrowsTheNextOne() {
        let streamed = "Sure. I'll audit the permission cards first."
        #expect(AssistantOpener.firstSentence(of: streamed)
            == "Sure. I'll audit the permission cards first.")
    }

    @Test func aSlightSentenceAloneIsStillNotEnough() {
        #expect(AssistantOpener.firstSentence(of: "Sure.") == nil)
    }

    // MARK: - Markdown is what actually arrives

    @Test func aHeadingMarkerIsNotReadOutLoud() {
        #expect(AssistantOpener.firstSentence(of: "## Plan\nI'll start with the failing tests.")
            == "Plan I'll start with the failing tests.")
    }

    @Test func aBulletMarkerIsStrippedFromTheFront() {
        #expect(AssistantOpener.firstSentence(of: "- I'll begin by reading the harness code.")
            == "I'll begin by reading the harness code.")
    }

    @Test func aNumberedListMarkerIsStrippedToo() {
        #expect(AssistantOpener.firstSentence(of: "1. I'll begin by reading the harness code.")
            == "I'll begin by reading the harness code.")
    }

    /// Nobody wants a shell command read to them.
    @Test func aReplyThatOpensWithCodeIsLeftAlone() {
        #expect(AssistantOpener.firstSentence(of: "```\nswift test --filter Foo.\n```") == nil)
    }

    @Test func proseStopsAtTheCodeFence() {
        let streamed = "I'll run the suite and read the failures.\n```\nswift test\n```"
        #expect(AssistantOpener.firstSentence(of: streamed)
            == "I'll run the suite and read the failures.")
    }

    // MARK: - Periods that end nothing

    @Test func anAbbreviationDoesNotCloseASentence() {
        // Would otherwise speak "I'll check the harnesses, e.g." and stop.
        let streamed = "I'll check the harnesses, e.g. Claude and Codex, before deciding."
        #expect(AssistantOpener.firstSentence(of: streamed) == streamed)
    }

    @Test func aDecimalDoesNotCloseASentence() {
        let streamed = "I'll pin the toolchain to 6.1 and rerun the whole suite."
        #expect(AssistantOpener.firstSentence(of: streamed) == streamed)
    }

    @Test func aSentenceLongerThanTheLimitIsLeftToTheWindow() {
        let long = String(repeating: "a lot of words ", count: 40) + "."
        #expect(AssistantOpener.firstSentence(of: long) == nil)
    }

    // MARK: - Not saying it twice

    @Test func theAnswerDropsAnOpeningItAlreadySpoke() {
        let opener = "I'll check the fleet and report back."
        let answer = "I'll check the fleet and report back. Three tabs are green."
        #expect(AssistantOpener.removing(opener, from: answer) == "Three tabs are green.")
    }

    @Test func anAnswerThatSaysSomethingElseIsUntouched() {
        let answer = "Three tabs are green, one is blocked."
        #expect(AssistantOpener.removing("I'll check the fleet.", from: answer) == answer)
    }

    /// If the opener *was* the whole answer, saying it once is better than
    /// saying nothing at all.
    @Test func anAnswerThatIsNothingButTheOpenerSurvives() {
        let opener = "I'll check the fleet and report back."
        #expect(AssistantOpener.removing(opener, from: opener) == opener)
    }

    @Test func nothingSpokenYetMeansNothingToStrip() {
        #expect(AssistantOpener.removing(nil, from: "Three tabs are green.") == "Three tabs are green.")
        #expect(AssistantOpener.removing("An opener.", from: nil) == nil)
    }
}
