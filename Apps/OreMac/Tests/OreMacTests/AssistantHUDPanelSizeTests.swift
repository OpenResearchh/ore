import AppKit
import Testing

@testable import OreMac

/// `evaluate()` runs for every word of a narration line, and it used to resize
/// the panel, reposition it, invalidate its shadow and restart its fade-in each
/// time. The skip is now "the size it would want is the size it already has",
/// so that answer has to be a pure function of what the HUD is showing.
struct AssistantHUDPanelSizeTests {
    @Test("The voice-only pill is the small one")
    func voiceOnlyPill() {
        let pill = AssistantVoiceHUD.panelSize(voiceActive: true, actions: false, isQuestion: false)
        #expect(pill == NSSize(width: 380, height: 56))
        // Nothing to show at all falls back to the same pill rather than to a
        // zero size the panel would have to grow out of later.
        #expect(
            AssistantVoiceHUD.panelSize(voiceActive: false, actions: false, isQuestion: false)
                == pill
        )
    }

    @Test("A question is taller than a permission, with or without voice")
    func questionIsTaller() {
        let permission = AssistantVoiceHUD.panelSize(
            voiceActive: false, actions: true, isQuestion: false
        )
        let question = AssistantVoiceHUD.panelSize(
            voiceActive: false, actions: true, isQuestion: true
        )
        #expect(permission.width == question.width)
        #expect(question.height > permission.height)

        // Voice adds the transcript strip above whichever card it is.
        let spoken = AssistantVoiceHUD.panelSize(
            voiceActive: true, actions: true, isQuestion: true
        )
        #expect(spoken.height == question.height + 64)
        #expect(spoken.width == question.width)
    }

    @Test("Same inputs, same size — the skip depends on it")
    func isStable() {
        for voice in [true, false] {
            for actions in [true, false] {
                for question in [true, false] {
                    #expect(
                        AssistantVoiceHUD.panelSize(
                            voiceActive: voice, actions: actions, isQuestion: question
                        ) == AssistantVoiceHUD.panelSize(
                            voiceActive: voice, actions: actions, isQuestion: question
                        )
                    )
                }
            }
        }
    }
}
