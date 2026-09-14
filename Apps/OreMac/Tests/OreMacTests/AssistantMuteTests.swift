import Foundation
import OreProtocol
import Testing

@testable import OreMac

@MainActor
struct AssistantMuteTests {
    @Test func mutingSilencesEvenTheAssistantsOwnAnswersAndSurvivesRelaunch() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: NarrationEngine.mutedKey)
        defer {
            if let saved {
                defaults.set(saved, forKey: NarrationEngine.mutedKey)
            } else {
                defaults.removeObject(forKey: NarrationEngine.mutedKey)
            }
        }

        let engine = NarrationEngine()
        engine.setMuted(true)
        // Answers bypass the per-tab speaker and the narration setting; the
        // mute is the one switch they don't.
        engine.speakAssistant("Your build finished.", chatID: ChatID(rawValue: "mute-test"))
        #expect(!engine.hasAudibleOrQueuedSpeech)
        #expect(NarrationEngine().isMuted)

        engine.setMuted(false)
        #expect(!NarrationEngine().isMuted)
    }
}
