import Testing

@testable import OreMac

/// A tab's narration used to play with no pill at all, because the pill only
/// followed the assistant's own voice session.
struct HUDVoiceSourceTests {
    @Test func narrationAloneShowsThePill() {
        #expect(HUDVoiceSource.current(isAssistantActive: false, narrationText: "Tests passed") == .narration)
    }

    /// The assistant's session owns the pill whenever it is active — its own
    /// speech already streams through the speaking phase.
    @Test func theAssistantWinsWhenBothAreActive() {
        #expect(HUDVoiceSource.current(isAssistantActive: true, narrationText: "Tests passed") == .assistant)
    }

    @Test func silenceHidesThePill() {
        #expect(HUDVoiceSource.current(isAssistantActive: false, narrationText: nil) == .none)
    }
}

struct HUDVoiceRemainderTests {
    @Test func untouchedSpeechIsShownWhole() {
        #expect(
            HUDVoiceRemainder.text(spoken: "add tests", chrome: .empty, actedOn: "")
                == "add tests"
        )
    }

    @Test func chromeOnlySpeechClearsTheLine() {
        let chrome = VoiceChromeIntents(actions: [.sidebarHide], rewritten: "", changes: [])
        #expect(
            HUDVoiceRemainder.text(
                spoken: "tuck the file list away",
                chrome: chrome,
                actedOn: "tuck the file list away"
            ).isEmpty
        )
    }

    @Test func leftoverWorkStaysAfterChrome() {
        let chrome = VoiceChromeIntents(
            actions: [.sidebarHide], rewritten: "add tests", changes: []
        )
        #expect(
            HUDVoiceRemainder.text(
                spoken: "tuck the file list away and add tests",
                chrome: chrome,
                actedOn: "tuck the file list away and add tests"
            ) == "add tests"
        )
    }

    @Test func wordsAfterADoneActionStayOnThePill() {
        let chrome = VoiceChromeIntents(actions: [.sidebarHide], rewritten: "", changes: [])
        #expect(
            HUDVoiceRemainder.text(
                spoken: "tuck the file list away and add tests",
                chrome: chrome,
                actedOn: "tuck the file list away"
            ) == "and add tests"
        )
    }
}
