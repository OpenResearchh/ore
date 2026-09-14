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
