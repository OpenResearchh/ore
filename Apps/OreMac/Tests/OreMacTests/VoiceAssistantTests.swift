import Testing
import OreProtocol

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
        #expect(
            VoiceAssistantController.confirmationDecision(from: "auto allow this tab")
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

struct VoiceAssistantQuestionTests {
    private let question = AgentQuestion(
        turnID: TurnID(rawValue: "turn"),
        id: QuestionID(rawValue: "question"),
        prompt: "Which branch should I target?",
        options: [
            .init(label: "main"),
            .init(label: "develop"),
        ],
        allowsFreeform: true
    )

    @Test func exactAndOrdinalChoicesReturnProviderLabels() {
        #expect(VoiceAssistantController.questionAnswer(
            from: "Develop", question: question
        ) == "develop")
        #expect(VoiceAssistantController.questionAnswer(
            from: "the second option", question: question
        ) == "develop")
    }

    @Test func freeformAnswersAreNotCollapsedToTheFirstOption() {
        #expect(VoiceAssistantController.questionAnswer(
            from: "Use the release branch instead", question: question
        ) == "Use the release branch instead")
    }

    @Test func aQuestionPromptReadsChoicesAndOffersFreeform() {
        let item = TabNeedsYou.question(.init(
            workspaceID: WorkspaceID(rawValue: "workspace"),
            chatID: ChatID(rawValue: "chat"),
            question: question
        ))
        #expect(item.spokenPrompt.contains("main, or develop"))
        #expect(item.spokenPrompt.contains("say your own answer"))
    }

    @Test func aClosedChoiceRejectsUnlistedSpeech() {
        var closed = question
        closed.allowsFreeform = false
        #expect(VoiceAssistantController.questionAnswer(
            from: "release", question: closed
        ) == nil)
    }
}

struct VoiceAssistantPermissionPromptTests {
    @Test func spokenPermissionKeepsTheRequestIdentity() {
        let id = PermissionRequestID(rawValue: "permission-42")
        let request = PermissionRequest(
            turnID: TurnID(rawValue: "turn"),
            id: id,
            toolName: "Bash",
            displayName: "Run command",
            summary: "run the tests",
            input: .null
        )
        let item = TabNeedsYou.permission(.init(
            workspaceID: WorkspaceID(rawValue: "workspace"),
            chatID: ChatID(rawValue: "chat"),
            request: request
        ))

        #expect(item.narrationKind == .permission(id))
        #expect(item.id == "permission-permission-42")
    }
}
