import Testing

@testable import OreMac

/// Spoken answers to pending assistant confirmations. The utterance is the
/// unit — "no problem, go ahead" allows; a leftover "no" still denies.
struct VoiceAssistantDecisionTests {
    @Test func plainAssentGrantsTheTask() {
        for phrase in ["yes", "Yeah, go ahead", "okay do it", "sure", "approve it"] {
            #expect(
                VoiceAssistantController.confirmationDecision(from: phrase) == .allow(.task),
                "\(phrase) should allow for the task"
            )
        }
    }

    @Test func conversationalAssentIsNotADenial() {
        for phrase in [
            "no problem",
            "no problem, go ahead",
            "no worries",
            "yeah no problem",
        ] {
            #expect(
                VoiceAssistantController.confirmationDecision(from: phrase) == .allow(.task),
                "\(phrase) should allow"
            )
        }
    }

    @Test func alwaysWidensTheGrant() {
        #expect(
            VoiceAssistantController.confirmationDecision(from: "yes, always allow that")
                == .allow(.always)
        )
        // "always" without an assent is not a confirmation.
        #expect(VoiceAssistantController.confirmationDecision(from: "I always want that") == nil)
    }

    @Test func denialStillWinsWhenTheUserIsRefusing() {
        for phrase in ["no", "Nope", "no, don't allow it", "cancel that", "stop"] {
            #expect(
                VoiceAssistantController.confirmationDecision(from: phrase) == .deny,
                "\(phrase) should deny"
            )
        }
    }

    @Test func realRequestsAreNotMistakenForAnswers() {
        // Long sentences and unrelated words fall through to a normal message.
        #expect(VoiceAssistantController.confirmationDecision(from: "now show me the diff") == nil)
        #expect(VoiceAssistantController.confirmationDecision(
            from: "yes and after that create a new workspace for the parser and push it"
        ) == nil)
        #expect(VoiceAssistantController.confirmationDecision(from: "what's happening") == nil)
    }
}
