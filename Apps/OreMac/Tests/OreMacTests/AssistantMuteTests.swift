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
        // Answers bypass the per-tab speaker and the narration setting; mute
        // still silences audio — captions are tested separately.
        engine.speakAssistant("Your build finished.", chatID: ChatID(rawValue: "mute-test"))
        #expect(!engine.hasAudibleOrQueuedSpeech)
        #expect(NarrationEngine().isMuted)

        engine.setMuted(false)
        #expect(!NarrationEngine().isMuted)
    }

    @Test func mutingStillCaptionsAssistantAnswersInTheHUD() {
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
        let chatID = ChatID(rawValue: "mute-caption-test")
        engine.speakAssistant("Your build finished.", chatID: chatID)
        #expect(!engine.hasAudibleOrQueuedSpeech)
        #expect(engine.currentSpokenText == "Your build finished.")
        #expect(engine.speakingChatID == chatID)
        // The pill streams this; dumping the whole line at once is unreadable.
        #expect(engine.spokenPrefix.isEmpty)
        #expect(engine.spokenCharacterCount == 0)
    }

    @Test func muteCaptionsRevealWholeWordsThenFinish() {
        #expect(
            NarrationEngine.wordEndOffsets(in: "Over in the Sugar Nuclei")
                == [4, 7, 11, 17, 24]
        )
        #expect(
            !NarrationEngine.endingWasLost(
                isAudibleOrQueued: false,
                isMidUtterance: true,
                isSilentCaption: true
            )
        )
        #expect(
            NarrationEngine.endingWasLost(
                isAudibleOrQueued: false,
                isMidUtterance: true,
                isSilentCaption: false
            )
        )
    }
}
