import Testing
import OreProtocol

@testable import OreMac

struct VoiceFinishPhraseTests {
    @Test func canonicalPhraseAtTheEndFinishesAndIsRemoved() throws {
        let match = try #require(VoiceFinishPhrase.match(
            in: "Please run the focused tests. Yip yap yip yip."
        ))
        #expect(match.request == "Please run the focused tests.")
    }

    @Test func punctuationAndNarrowYipRecognitionVariantsStillMatch() throws {
        let hyphenated = try #require(VoiceFinishPhrase.match(
            in: "Show me the diff; yip-yap, yip-yip!"
        ))
        #expect(hyphenated.request == "Show me the diff;")

        let yep = try #require(VoiceFinishPhrase.match(
            in: "Check it yep yap yep yep"
        ))
        #expect(yep.request == "Check it")
    }

    @Test func ordinarySpeechAndNonterminalMentionsDoNotFalseTrigger() {
        for phrase in [
            "yep yep yep yep",
            "yip yap yip",
            "yip yap yip yip is the phrase I chose",
            "please compare yip and yap",
        ] {
            #expect(VoiceFinishPhrase.match(in: phrase) == nil, "\(phrase) must not submit")
        }
    }
}

struct HandsFreeListeningGuardTests {
    private let start = ContinuousClock.now

    @Test func finishCandidateMustRemainStableBeforeSubmitting() {
        var guardState = HandsFreeListeningGuard(startedAt: start)
        let phrase = "Run the tests yip yap yip yip"
        #expect(guardState.evaluate(transcript: phrase, at: start) == .none)
        #expect(guardState.evaluate(
            transcript: phrase,
            at: start.advanced(by: HandsFreeListeningGuard.finishSettle - .milliseconds(1))
        ) == .none)
        #expect(guardState.evaluate(
            transcript: phrase,
            at: start.advanced(by: HandsFreeListeningGuard.finishSettle)
        ) == .finish("Run the tests"))
    }

    @Test func revisedPartialHypothesisCancelsTheFinishCandidate() {
        var guardState = HandsFreeListeningGuard(startedAt: start)
        _ = guardState.evaluate(transcript: "Explain it yip yap yip yip", at: start)
        #expect(guardState.evaluate(
            transcript: "Explain why yip yap is distinctive",
            at: start.advanced(by: .milliseconds(200))
        ) == .none)
        #expect(guardState.evaluate(
            transcript: "Explain why yip yap is distinctive",
            at: start.advanced(by: .seconds(1))
        ) == .none)
    }

    @Test func finalRecognizerResultDoesNotNeedAnExtraSettleDelay() {
        var guardState = HandsFreeListeningGuard(startedAt: start)
        #expect(guardState.evaluate(
            transcript: "Run the tests yip yap yip yip",
            at: start,
            isFinal: true
        ) == .finish("Run the tests"))
    }

    @Test func emptySessionTimesOutWithoutSubmitting() {
        var guardState = HandsFreeListeningGuard(startedAt: start)
        #expect(guardState.evaluate(
            transcript: "",
            at: start.advanced(by: HandsFreeListeningGuard.noSpeechTimeout)
        ) == .timeout)
    }

    @Test func maximumSessionTimeoutDoesNotSubmitPartialSpeech() {
        var guardState = HandsFreeListeningGuard(startedAt: start)
        #expect(guardState.evaluate(
            transcript: "This request never said the finish phrase",
            at: start.advanced(by: HandsFreeListeningGuard.maximumDuration)
        ) == .timeout)
    }
}

/// Quiet mode and the default voice turn: answers always play, everything else
/// is a chime and the HUD. Mid-turn tool chatter is never spoken.
struct VoiceSpeechPolicyTests {
    @Test func answersAlwaysPlayEvenWhenQuiet() {
        #expect(VoiceSpeechPolicy.shouldSpeakAnswers(quiet: false))
        #expect(VoiceSpeechPolicy.shouldSpeakAnswers(quiet: true))
    }

    @Test func milestonesNeverPlayDuringAVoiceTurn() {
        #expect(!VoiceSpeechPolicy.shouldSpeakMilestones(quiet: false))
        #expect(!VoiceSpeechPolicy.shouldSpeakMilestones(quiet: true))
    }

    @Test func progressPromptsAndAcksStaySilentInQuietMode() {
        #expect(VoiceSpeechPolicy.shouldSpeakNudge(quiet: false))
        #expect(VoiceSpeechPolicy.shouldSpeakPrompts(quiet: false))
        #expect(VoiceSpeechPolicy.shouldSpeakAcks(quiet: false))
        #expect(!VoiceSpeechPolicy.shouldSpeakNudge(quiet: true))
        #expect(!VoiceSpeechPolicy.shouldSpeakPrompts(quiet: true))
        #expect(!VoiceSpeechPolicy.shouldSpeakAcks(quiet: true))
    }
}

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
        for phrase in ["no", "Nope", "no, don't allow it", "cancel that", "stop", "reject"] {
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
        #expect(item.spokenPrompt().contains("main, or develop"))
        #expect(item.spokenPrompt().contains("answer in your own words"))
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
