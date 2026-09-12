import Foundation
import Testing
import OreProtocol

@testable import OreMac

struct VoiceFinishPhraseTests {
    @Test func canonicalPhraseAtTheEndFinishesAndIsRemoved() throws {
        let match = try #require(VoiceFinishPhrase.match(
            in: "Please run the focused tests. Yip yap yip yip."
        ))
        #expect(match.request == "Please run the focused tests.")
        #expect(match.confidence == .exact)
    }

    @Test func punctuationAndNarrowYipRecognitionVariantsStillMatch() throws {
        let hyphenated = try #require(VoiceFinishPhrase.match(
            in: "Show me the diff; yip-yap, yip-yip!"
        ))
        #expect(hyphenated.request == "Show me the diff;")
        #expect(hyphenated.confidence == .exact)

        let yep = try #require(VoiceFinishPhrase.match(
            in: "Check it yep yap yep yep"
        ))
        #expect(yep.request == "Check it")
        #expect(yep.confidence == .exact)
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

    // MARK: Fuzzy tier — one recognizer slip, always with a request in front.

    @Test func mergedTokensMatchFuzzilyByJoinedEditDistance() throws {
        let match = try #require(VoiceFinishPhrase.match(
            in: "Run the tests yipyap yip yip"
        ))
        #expect(match.request == "Run the tests")
        #expect(match.confidence == .fuzzy)
    }

    @Test func aSingleSlippedSlotMatchesFuzzily() throws {
        let slipped = try #require(VoiceFinishPhrase.match(
            in: "Run the tests yip yep yip yip"
        ))
        #expect(slipped.request == "Run the tests")
        #expect(slipped.confidence == .fuzzy)

        let confused = try #require(VoiceFinishPhrase.match(
            in: "Run the tests hip yap yip yip"
        ))
        #expect(confused.request == "Run the tests")
        #expect(confused.confidence == .fuzzy)
    }

    @Test func multipleSlotConfusionsNeverMatch() {
        for phrase in [
            "Run the tests hip app tip yep",
            "Run the tests hip yap hip yip",
        ] {
            #expect(VoiceFinishPhrase.match(in: phrase) == nil)
        }
    }

    @Test func aDroppedFinalRepetitionMatchesFuzzily() throws {
        let match = try #require(VoiceFinishPhrase.match(
            in: "Run the tests yip yap yip"
        ))
        #expect(match.request == "Run the tests")
        #expect(match.confidence == .fuzzy)
    }

    @Test func aStutteredExtraRepetitionIsExcisedWhole() throws {
        let match = try #require(VoiceFinishPhrase.match(
            in: "Run the tests yip yap yip yip yip"
        ))
        #expect(match.request == "Run the tests")
        #expect(match.confidence == .fuzzy)
    }

    @Test func bareFuzzyPhrasesNeverMatch() {
        for phrase in ["yipyap yip yip", "hip yap yip yip", "yip yap yip yip yip"] {
            #expect(
                VoiceFinishPhrase.match(in: phrase) == nil,
                "\(phrase) alone must not match — only the exact phrase may stand bare"
            )
        }
    }

    @Test func proseEndingsNeverMatchAtAnyTier() {
        for phrase in [
            "yes",
            "yep",
            "you know",
            "that's it",
            "hip hop music",
            "okay do it now",
            "no problem",
            "send it when you're ready",
            "yes yes",
            "tip top shape",
            "happy happy happy happy",
            "the app is ready",
            "yak yak yak",
            "I said yep yep yep yep",
            "we can compare yip and yap later",
        ] {
            #expect(VoiceFinishPhrase.match(in: phrase) == nil, "\(phrase) must not submit")
        }
    }

    // MARK: Enrolled variants and custom phrases.

    @Test func anEnrolledVariantMatchesExactly() throws {
        var model = FinishPhraseModel.standard
        model.enrolledVariants = [["hip", "hop", "hip", "hip"]]
        let match = try #require(VoiceFinishPhrase.match(
            in: "Deploy the fix hip hop, hip hip!", model: model
        ))
        #expect(match.request == "Deploy the fix")
        #expect(match.confidence == .exact)
        // Without enrollment the same speech stays a near-miss at best.
        #expect(VoiceFinishPhrase.match(in: "Deploy the fix hip hop hip hip") == nil)
    }

    @Test func aLongEnrolledVariantIsExcisedBeforeItsCanonicalTail() throws {
        var model = FinishPhraseModel.standard
        model.enrolledVariants = [["noise", "yip", "yap", "yip", "yip"]]
        let match = try #require(VoiceFinishPhrase.match(
            in: "Deploy the fix noise yip yap yip yip", model: model
        ))
        #expect(match.request == "Deploy the fix")
        #expect(match.confidence == .exact)
    }

    @Test func enrollmentDoesNotInventCrossProductVariants() {
        var model = FinishPhraseModel.standard
        model.enrolledVariants = [
            ["hip", "yap", "yip", "yip"],
            ["yip", "hop", "yip", "yip"],
        ]
        #expect(VoiceFinishPhrase.match(
            in: "Deploy the fix hip hop yip yip", model: model
        ) == nil)
    }

    @Test func aCustomPhraseMatchesExactAndOneEditOff() throws {
        let model = FinishPhraseModel(
            spoken: "purple banana split",
            canonicalTokens: ["purple", "banana", "split"],
            slotAlternatives: [["purple"], ["banana"], ["split"]],
            enrolledVariants: []
        )
        let exact = try #require(VoiceFinishPhrase.match(
            in: "Open the diff purple banana split", model: model
        ))
        #expect(exact.request == "Open the diff")
        #expect(exact.confidence == .exact)

        let slipped = try #require(VoiceFinishPhrase.match(
            in: "Open the diff purple bananna split", model: model
        ))
        #expect(slipped.request == "Open the diff")
        #expect(slipped.confidence == .fuzzy)
    }

    // MARK: Near-misses inform, never send.

    @Test func aGarbledAttemptIsANearMissNotAMatch() {
        let evaluation = VoiceFinishPhrase.evaluate(in: "Run the tests yep yep yep yep")
        #expect(evaluation.match == nil)
        #expect(evaluation.nearMiss)
    }

    @Test func unrelatedSpeechIsNotEvenANearMiss() {
        let evaluation = VoiceFinishPhrase.evaluate(in: "Run the focused parser tests")
        #expect(evaluation.match == nil)
        #expect(!evaluation.nearMiss)
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

    @Test func aFuzzyMatchNeedsTheLongerSettle() {
        var guardState = HandsFreeListeningGuard(startedAt: start)
        let phrase = "Run the tests yip yap yip"
        #expect(guardState.evaluate(transcript: phrase, at: start) == .none)
        #expect(guardState.evaluate(
            transcript: phrase,
            at: start.advanced(by: HandsFreeListeningGuard.fuzzySettle - .milliseconds(1))
        ) == .none)
        #expect(guardState.evaluate(
            transcript: phrase,
            at: start.advanced(by: HandsFreeListeningGuard.fuzzySettle)
        ) == .finish("Run the tests"))
    }

    @Test func punctuationChurnInEarlierWordsDoesNotResetTheSettle() {
        var guardState = HandsFreeListeningGuard(startedAt: start)
        #expect(guardState.evaluate(
            transcript: "Run the tests yip yap yip yip", at: start
        ) == .none)
        // The recognizer re-punctuates the prefix; the words are unchanged.
        #expect(guardState.evaluate(
            transcript: "Run the tests, yip yap yip yip.",
            at: start.advanced(by: .milliseconds(200))
        ) == .none)
        #expect(guardState.evaluate(
            transcript: "Run the tests, yip yap yip yip.",
            at: start.advanced(by: HandsFreeListeningGuard.finishSettle)
        ) == .finish("Run the tests,"))
    }

    @Test func aChangedRequestWordRestartsTheSettle() {
        var guardState = HandsFreeListeningGuard(startedAt: start)
        _ = guardState.evaluate(
            transcript: "Explain it yip yap yip yip", at: start
        )
        #expect(guardState.evaluate(
            transcript: "Explain why yip yap yip yip",
            at: start.advanced(by: .milliseconds(200))
        ) == .none)
        #expect(guardState.evaluate(
            transcript: "Explain why yip yap yip yip",
            at: start.advanced(by: HandsFreeListeningGuard.finishSettle)
        ) == .none)
        #expect(guardState.evaluate(
            transcript: "Explain why yip yap yip yip",
            at: start.advanced(by: .milliseconds(550))
        ) == .finish("Explain why"))
    }

    @Test func aChangedPhraseHypothesisRestartsTheSettle() {
        var guardState = HandsFreeListeningGuard(startedAt: start)
        _ = guardState.evaluate(
            transcript: "Run the tests yip yap yip yip", at: start
        )
        _ = guardState.evaluate(
            transcript: "Run the tests yep yap yep yep",
            at: start.advanced(by: .milliseconds(200))
        )
        #expect(guardState.evaluate(
            transcript: "Run the tests yep yap yep yep",
            at: start.advanced(by: HandsFreeListeningGuard.finishSettle)
        ) == .none)
        #expect(guardState.evaluate(
            transcript: "Run the tests yep yap yep yep",
            at: start.advanced(by: .milliseconds(550))
        ) == .finish("Run the tests"))
    }

    @Test func aFuzzyFinalRecognizerResultStillNeedsStability() {
        var guardState = HandsFreeListeningGuard(startedAt: start)
        #expect(guardState.evaluate(
            transcript: "Run the tests yipyap yip yip",
            at: start,
            isFinal: true
        ) == .none)
        #expect(guardState.evaluate(
            transcript: "Run the tests yipyap yip yip",
            at: start.advanced(by: HandsFreeListeningGuard.fuzzySettle),
            isFinal: true
        ) == .finish("Run the tests"))
    }

    @Test func aStableNearMissRaisesTheHintAndNeverSubmits() {
        var guardState = HandsFreeListeningGuard(startedAt: start)
        let garbled = "Run the tests yep yep yep yep"
        for poll in 0..<HandsFreeListeningGuard.nearMissStablePolls {
            #expect(guardState.evaluate(
                transcript: garbled,
                at: start.advanced(by: .milliseconds(poll * 100))
            ) == .none)
        }
        #expect(guardState.nearMissHint)
        // Still only a hint after any amount of time.
        #expect(guardState.evaluate(
            transcript: garbled, at: start.advanced(by: .seconds(5))
        ) == .none)
        #expect(guardState.nearMissHint)
    }

    @Test func theHintClearsWhenTheUserSaysSomethingElse() {
        var guardState = HandsFreeListeningGuard(startedAt: start)
        for poll in 0..<HandsFreeListeningGuard.nearMissStablePolls {
            _ = guardState.evaluate(
                transcript: "Run the tests yep yep yep yep",
                at: start.advanced(by: .milliseconds(poll * 100))
            )
        }
        #expect(guardState.nearMissHint)
        _ = guardState.evaluate(
            transcript: "Run the tests and also lint",
            at: start.advanced(by: .milliseconds(400))
        )
        #expect(!guardState.nearMissHint)
    }

    @Test func aTimeoutStillFiresDuringANearMiss() {
        var guardState = HandsFreeListeningGuard(startedAt: start)
        #expect(guardState.evaluate(
            transcript: "Run the tests yep yep yep yep",
            at: start.advanced(by: HandsFreeListeningGuard.maximumDuration)
        ) == .timeout)
    }

    @Test func aTunedModelFinishesOnItsOwnPhrase() {
        var model = FinishPhraseModel.standard
        model.enrolledVariants = [["hip", "hop", "hip", "hip"]]
        var guardState = HandsFreeListeningGuard(startedAt: start, model: model)
        let phrase = "Ship the release hip hop hip hip"
        #expect(guardState.evaluate(transcript: phrase, at: start) == .none)
        #expect(guardState.evaluate(
            transcript: phrase,
            at: start.advanced(by: HandsFreeListeningGuard.finishSettle)
        ) == .finish("Ship the release"))
    }

    @Test func silenceAutoFinishWarnsThenSends() {
        var guardState = HandsFreeListeningGuard(
            startedAt: start, silenceAutoFinish: .seconds(3)
        )
        #expect(guardState.evaluate(transcript: "Run the tests", at: start) == .none)
        #expect(guardState.evaluate(
            transcript: "Run the tests",
            at: start.advanced(by: .seconds(2) - .milliseconds(1))
        ) == .none)
        #expect(guardState.evaluate(
            transcript: "Run the tests.",
            at: start.advanced(by: .seconds(2))
        ) == .silenceWarning)
        #expect(guardState.silenceWarningActive)
        #expect(guardState.evaluate(
            transcript: "Run the tests.",
            at: start.advanced(by: .seconds(3))
        ) == .finishAfterSilence("Run the tests."))
    }

    @Test func newWordsCancelAndRestartTheSilenceCountdown() {
        var guardState = HandsFreeListeningGuard(
            startedAt: start, silenceAutoFinish: .seconds(3)
        )
        _ = guardState.evaluate(transcript: "Run the tests", at: start)
        #expect(guardState.evaluate(
            transcript: "Run the tests", at: start.advanced(by: .seconds(2))
        ) == .silenceWarning)
        #expect(guardState.evaluate(
            transcript: "Run all the tests", at: start.advanced(by: .milliseconds(2_500))
        ) == .none)
        #expect(!guardState.silenceWarningActive)
        #expect(guardState.evaluate(
            transcript: "Run all the tests", at: start.advanced(by: .milliseconds(4_499))
        ) == .none)
        #expect(guardState.evaluate(
            transcript: "Run all the tests", at: start.advanced(by: .milliseconds(4_500))
        ) == .silenceWarning)
    }

    @Test func silenceFinishStripsOnlyCrediblePhraseDebris() {
        var guardState = HandsFreeListeningGuard(
            startedAt: start, silenceAutoFinish: .seconds(3)
        )
        _ = guardState.evaluate(transcript: "Run the tests yip yap", at: start)
        #expect(guardState.evaluate(
            transcript: "Run the tests yip yap", at: start.advanced(by: .seconds(3))
        ) == .finishAfterSilence("Run the tests"))
        #expect(VoiceFinishPhrase.strippingTrailingPhraseArtifacts("Open the app") == "Open the app")
    }
}

@Suite(.serialized)
struct FinishPhraseEnrollmentTests {
    private let canonical = ["yip", "yap", "yip", "yip"]

    @Test func slippedSlotsBecomeCompleteVariants() {
        let derived = FinishPhraseEnrollment.derive(
            from: ["hip hop hip hip", "yip yap yip yep"],
            canonical: canonical
        )
        #expect(derived.variants == [
            ["hip", "hop", "hip", "hip"],
            ["yip", "yap", "yip", "yep"],
        ])
        #expect(derived.warnings.isEmpty)
    }

    @Test func mergedTakesStayWholeSequenceVariants() {
        let derived = FinishPhraseEnrollment.derive(
            from: ["yipyap yip yip"], canonical: canonical
        )
        #expect(derived.variants == [["yipyap", "yip", "yip"]])
    }

    @Test func perfectTakesTeachNothingAndDuplicatesCollapse() {
        let derived = FinishPhraseEnrollment.derive(
            from: ["yip yap yip yip", "Yip yap, yip yip!", "hip yap yip yip", "hip yap yip yip"],
            canonical: canonical
        )
        #expect(derived.variants == [["hip", "yap", "yip", "yip"]])
        #expect(derived.warnings.contains(.identicalToCanonical))
    }

    @Test func takesLeaningOnEverydayWordsAreFlagged() {
        let derived = FinishPhraseEnrollment.derive(
            from: ["you know you know"], canonical: canonical
        )
        #expect(derived.variants == [["you", "know", "you", "know"]])
        #expect(derived.warnings.contains(.commonWords(["know", "you"])))
    }

    @Test func silenceIsReportedNotEnrolled() {
        let derived = FinishPhraseEnrollment.derive(
            from: ["", "  "], canonical: canonical
        )
        #expect(derived.variants.isEmpty)
        #expect(derived.warnings == [.nothingHeard])
    }

    @Test func veryShortVariantsAreFlagged() {
        let derived = FinishPhraseEnrollment.derive(
            from: ["yo"], canonical: canonical
        )
        #expect(derived.variants == [["yo"]])
        #expect(derived.warnings.contains(.tooShort(["yo"])))
    }

    @Test func theVariantCapHolds() {
        let takes = (0..<12).map { "word\($0) yap yip yip" }
        let derived = FinishPhraseEnrollment.derive(from: takes, canonical: canonical)
        #expect(derived.variants.count == FinishPhraseEnrollment.variantCap)
    }

    @Test func aCustomPhraseGetsCommonWordAndLengthWarnings() {
        #expect(!FinishPhraseEnrollment.phraseWarnings(for: "send it").isEmpty)
        #expect(!FinishPhraseEnrollment.phraseWarnings(
            for: "purple monkey dishwasher dances over seven rivers"
        ).isEmpty)
        #expect(FinishPhraseEnrollment.phraseWarnings(for: "purple monkey dishwasher").isEmpty)
    }

    @Test func theStoreRoundTripsAndClearsToStock() {
        let defaults = UserDefaults(suiteName: "VoiceAssistantTests.store")!
        defaults.removePersistentDomain(forName: "VoiceAssistantTests.store")
        defer { defaults.removePersistentDomain(forName: "VoiceAssistantTests.store") }
        var model = FinishPhraseModel.standard
        model.enrolledVariants = [["hip", "hop", "hip", "hip"]]
        FinishPhraseStore.save(model, defaults: defaults)
        #expect(FinishPhraseStore.load(defaults: defaults) == model)
        FinishPhraseStore.clear(defaults: defaults)
        #expect(FinishPhraseStore.load(defaults: defaults) == nil)
    }

    @Test func persistedModelsDiscardImplicitSlotCrossProducts() {
        let suite = "VoiceAssistantTests.crossProducts"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var model = FinishPhraseModel.standard
        model.slotAlternatives[0].append("hip")
        FinishPhraseStore.save(model, defaults: defaults)
        #expect(FinishPhraseStore.load(defaults: defaults)?.slotAlternatives
            == FinishPhraseModel.standard.slotAlternatives)
    }

    @Test func malformedStoredModelsAreIgnored() throws {
        let suite = "VoiceAssistantTests.malformed"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let malformed = FinishPhraseModel(
            spoken: "send",
            canonicalTokens: ["send"],
            slotAlternatives: [["send"]],
            enrolledVariants: []
        )
        defaults.set(try JSONEncoder().encode(malformed), forKey: FinishPhraseStore.key)
        #expect(FinishPhraseStore.load(defaults: defaults) == nil)
    }

    @Test func debugLoggingKeepsOnlyTheTranscriptTail() {
        #expect(FinishPhraseDebugLog.suffix(
            of: "one two three four five six seven eight nine ten"
        ) == "three four five six seven eight nine ten")
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

/// Which turn a spoken question is allowed to hear back from.
///
/// The assistant chat is shared, so "an event from this chat" is not the same
/// as "the answer to what I just asked". These are the cases where those two
/// differ — and where ORE used to read another turn's prose aloud.
struct VoiceSpokenTurnTests {
    private let chat = ChatID(rawValue: "assistant")
    private func turn(_ id: String) -> TurnID { TurnID(rawValue: id) }

    @Test func nothingIsOursUntilATurnStarts() {
        let awaiting = VoiceSpokenTurn(chatID: chat)

        // A digest already streaming in the same chat when the question went
        // out. Its text is not the answer, however much it looks like one.
        #expect(!awaiting.owns(turn("already-running")))
        #expect(awaiting.turnID == nil)
    }

    @Test func theFirstTurnToStartAfterTheQuestionIsTheAnswer() {
        var awaiting = VoiceSpokenTurn(chatID: chat)

        let adopted = awaiting.adopt(turn("answer"))

        #expect(adopted)
        #expect(awaiting.owns(turn("answer")))
    }

    /// The queued case: the spoken prompt sits behind an open turn, so the
    /// turn that starts next is ours and the one it waited on never was.
    @Test func aQueuedPromptAdoptsTheTurnThatEventuallyRunsIt() {
        var awaiting = VoiceSpokenTurn(chatID: chat)
        let queuedBehind = turn("digest")

        #expect(!awaiting.owns(queuedBehind))
        let adopted = awaiting.adopt(turn("answer"))
        #expect(adopted)
        #expect(!awaiting.owns(queuedBehind), "the turn we waited on is still not ours")
        #expect(awaiting.owns(turn("answer")))
    }

    /// Whatever the user does next — types a follow-up, a watch digest fires
    /// — starts its own turn, and that one is not being waited on by ear.
    @Test func aLaterTurnInTheSameChatIsNotAdopted() {
        var awaiting = VoiceSpokenTurn(chatID: chat)
        _ = awaiting.adopt(turn("answer"))

        let adoptedAgain = awaiting.adopt(turn("typed-follow-up"))

        #expect(!adoptedAgain)
        #expect(awaiting.owns(turn("answer")))
        #expect(!awaiting.owns(turn("typed-follow-up")))
    }

    @Test func aStaleCompletionFromAnotherTurnIsNotTheAnswer() {
        var awaiting = VoiceSpokenTurn(chatID: chat)
        _ = awaiting.adopt(turn("answer"))

        // The turn the question was queued behind finishing late.
        #expect(!awaiting.owns(turn("digest")))
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
