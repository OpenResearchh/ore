import AppKit
import Foundation
import Observation
import OreProtocol

/// A deliberately unusual spoken terminator for hands-free requests.
///
/// Detection is suffix-only, token-based, and tiered. Exact means the
/// historical rule or a variant the user enrolled through tuning — the
/// normal settle applies. Fuzzy means one recognizer slip away: a slot from
/// the curated confusion table, a merged token caught by edit distance on
/// the joined suffix, a dropped or stuttered repetition — it needs words
/// before it and a doubled settle, so a bare near-phrase never submits.
/// Anything looser is at most a near-miss: surfaced as a hint, never sent.
enum VoiceFinishPhrase {
    static let spoken = FinishPhraseModel.standard.spoken
    static let vocabulary = FinishPhraseModel.standard.vocabulary

    enum Confidence: Equatable {
        case exact
        case fuzzy
    }

    struct Match: Equatable {
        let request: String
        let confidence: Confidence
        /// Normalized phrase evidence, kept separate from the request so a
        /// revised ASR suffix restarts settling even when the request is stable.
        let signature: String
    }

    struct Evaluation: Equatable {
        let match: Match?
        let nearMiss: Bool

        static let none = Evaluation(match: nil, nearMiss: false)
    }

    private struct Token {
        let value: String
        let range: Range<String.Index>
    }

    static func match(in text: String, model: FinishPhraseModel = .standard) -> Match? {
        evaluate(in: text, model: model).match
    }

    static func evaluate(
        in text: String,
        model: FinishPhraseModel = .standard
    ) -> Evaluation {
        let tokens = tokens(in: text)
        let n = model.canonicalTokens.count
        guard n > 0, !tokens.isEmpty else { return .none }

        // Exact: a complete variant the user approved during tuning, or the
        // slot rule as shipped. Long variants go first so all phrase debris is
        // excised when their tail also happens to look canonical.
        for variant in model.enrolledVariants.sorted(by: { $0.count > $1.count })
        where !variant.isEmpty && tokens.count >= variant.count {
            let window = Array(tokens.suffix(variant.count))
            if window.map(\.value) == variant {
                return matched(.exact, window: window, in: text)
            }
        }

        // The historical stock rule may stand alone — an empty request never
        // sends, so the bare phrase remains the spoken way to close the mic.
        if tokens.count >= n {
            let window = Array(tokens.suffix(n))
            if window.indices.allSatisfy({ model.exactSlotContains(window[$0].value, slot: $0) }) {
                return matched(.exact, window: window, in: text)
            }
        }
        // Fuzzy tiers all require real words before the phrase: someone
        // merely saying "yep yep…" into an open mic must never end the
        // session, and phrase debris alone is not a request.

        // One slot off, from the curated confusion table.
        if tokens.count > n {
            let window = Array(tokens.suffix(n))
            let fuzzySlots = window.indices.filter {
                model.fuzzySlotContains(window[$0].value, slot: $0)
                    && !model.exactSlotContains(window[$0].value, slot: $0)
            }
            if fuzzySlots.count == 1,
               window.indices.allSatisfy({ model.fuzzySlotContains(window[$0].value, slot: $0) }),
               let evaluation = fuzzyMatched(window: window, in: text, model: model) {
                return evaluation
            }
        }
        // A stutter: the exact phrase plus one or two extra phrase tokens.
        // Longest window first, so the whole stutter is excised from the
        // request rather than half of it.
        for extra in [2, 1] where tokens.count > n + extra {
            let window = Array(tokens.suffix(n + extra))
            let head = Array(window.prefix(n))
            let tail = window.dropFirst(n)
            if head.indices.allSatisfy({ model.exactSlotContains(head[$0].value, slot: $0) }),
               tail.allSatisfy({ model.exactSlotContains($0.value, slot: n - 1) }),
               let evaluation = fuzzyMatched(window: window, in: text, model: model) {
                return evaluation
            }
        }
        // A dropped final repetition — recognizers love collapsing "yip yip".
        // Only when the phrase actually ends in a repeat.
        if n >= 3, model.canonicalTokens[n - 1] == model.canonicalTokens[n - 2],
           tokens.count > n - 1 {
            let window = Array(tokens.suffix(n - 1))
            if window.indices.allSatisfy({ model.exactSlotContains(window[$0].value, slot: $0) }),
               let evaluation = fuzzyMatched(window: window, in: text, model: model) {
                return evaluation
            }
        }
        // Merged or slipped tokens: bounded edit distance on the joined
        // suffix ("yipyap yip yip", "yip yep yip yip"). First letter must
        // hold and the window grows from tightest, so a real word just
        // before the phrase stays in the request.
        let joinedTargets = [model.canonicalTokens.joined()]
        for m in 1...min(n + 2, tokens.count) {
            guard tokens.count > m else { break }
            let window = Array(tokens.suffix(m))
            let joined = window.map(\.value).joined()
            // Repeated assent is common prose, not a finish attempt. It is
            // intentionally a near-miss even though changing the middle
            // "yep" to "yap" is only one character edit.
            guard !window.allSatisfy({ $0.value == "yep" }) else { continue }
            let sameShapeMismatchCount = window.count == n
                ? window.indices.filter {
                    !model.exactSlotContains(window[$0].value, slot: $0)
                }.count
                : 0
            guard window.count != n || sameShapeMismatchCount == 1 else { continue }
            for target in joinedTargets
            where joined.first == target.first
                && abs(joined.count - target.count) <= 2
                && FinishPhraseMatching.editDistance(joined, target, limit: 2) <= 2 {
                if let evaluation = fuzzyMatched(window: window, in: text, model: model) {
                    return evaluation
                }
            }
        }

        return Evaluation(
            match: nil,
            nearMiss: isNearMiss(tokens: tokens, model: model, joinedTargets: joinedTargets)
        )
    }

    private static func matched(
        _ confidence: Confidence,
        window: [Token],
        in text: String
    ) -> Evaluation {
        guard let first = window.first else { return .none }
        let request = String(text[..<first.range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Evaluation(
            match: Match(
                request: request,
                confidence: confidence,
                signature: window.map(\.value).joined(separator: " ")
            ),
            nearMiss: false
        )
    }

    /// A fuzzy window only counts when what precedes it holds at least one
    /// word that is not itself phrase vocabulary — a bare or stuttered
    /// near-phrase must neither submit nor leave its debris as the request.
    private static func fuzzyMatched(
        window: [Token],
        in text: String,
        model: FinishPhraseModel
    ) -> Evaluation? {
        guard let first = window.first else { return nil }
        let request = String(text[..<first.range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestTokens = tokens(in: request).map(\.value)
        let phraseTokens = model.phraseTokens
        guard requestTokens.contains(where: { !phraseTokens.contains($0) })
        else { return nil }
        return Evaluation(
            match: Match(
                request: request,
                confidence: .fuzzy,
                signature: window.map(\.value).joined(separator: " ")
            ),
            nearMiss: false
        )
    }

    /// The transcript with trailing phrase debris removed — used when a
    /// silence auto-finish fires after a garbled, unmatched finish attempt,
    /// so "run the tests yip yap" sends "run the tests", not the noise.
    static func strippingTrailingPhraseArtifacts(
        _ text: String,
        model: FinishPhraseModel = .standard
    ) -> String {
        let tokens = tokens(in: text)
        guard !tokens.isEmpty else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let phraseTokens = model.phraseTokens
        var keep = tokens.count
        // Only the tail can be debris; never eat into the request proper.
        let floor = max(0, tokens.count - model.canonicalTokens.count - 2)
        while keep > floor {
            let token = tokens[keep - 1].value
            let isArtifact = phraseTokens.contains(token)
                || phraseTokens.contains { candidate in
                    candidate.count >= 3 && token.count >= 3
                        && token.first == candidate.first
                        && FinishPhraseMatching.editDistance(token, candidate, limit: 1) <= 1
                }
            guard isArtifact else { break }
            keep -= 1
        }
        // A lone phrase-like word may be legitimate request content ("open the
        // app"). Only a run of at least two tokens is credible finish debris.
        guard tokens.count - keep >= 2 else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard keep > 0 else { return "" }
        return String(text[..<tokens[keep].range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Close enough to be the user trying, not close enough to send: at
    /// least half the slots line up, or the joined suffix is within twice
    /// the fuzzy budget. Drives the "almost — say it once more" hint.
    private static func isNearMiss(
        tokens: [Token],
        model: FinishPhraseModel,
        joinedTargets: [String]
    ) -> Bool {
        let n = model.canonicalTokens.count
        let window = Array(tokens.suffix(n))
        let offset = n - window.count
        var hits = 0
        for (index, token) in window.enumerated()
        where model.fuzzySlotContains(token.value, slot: index + offset) {
            hits += 1
        }
        if hits >= 2 { return true }
        for m in 1...min(n + 2, tokens.count) {
            let joined = tokens.suffix(m).map(\.value).joined()
            for target in joinedTargets
            where joined.first == target.first
                && abs(joined.count - target.count) <= 4
                && FinishPhraseMatching.editDistance(joined, target, limit: 4) <= 4 {
                return true
            }
        }
        return false
    }

    private static func tokens(in text: String) -> [Token] {
        var result: [Token] = []
        var start: String.Index?
        for index in text.indices {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if start == nil { start = index }
            } else if let tokenStart = start {
                result.append(Token(
                    value: String(text[tokenStart..<index]).lowercased(),
                    range: tokenStart..<index
                ))
                start = nil
            }
        }
        if let tokenStart = start {
            result.append(Token(
                value: String(text[tokenStart...]).lowercased(),
                range: tokenStart..<text.endIndex
            ))
        }
        return result
    }
}

/// Pure timing guard for a hands-free microphone session. A finish phrase has
/// to remain the recognizer's current hypothesis briefly before it submits;
/// that prevents one volatile partial result from firing a turn. Empty and
/// abandoned sessions time out without ever sending words.
struct HandsFreeListeningGuard {
    enum Action: Equatable {
        case none
        case finish(String)
        /// Silence auto-send is one second away — the controller plays a
        /// soft cue; any speech calls it off.
        case silenceWarning
        /// The opt-in pause elapsed with words on the table. The payload has
        /// already had trailing phrase debris stripped.
        case finishAfterSilence(String)
        case timeout
    }

    static let finishSettle = Duration.milliseconds(350)
    /// A one-slip fuzzy match earns double the settle: a weaker signal gets
    /// more time to either firm up into the exact phrase or dissolve.
    static let fuzzySettle = Duration.milliseconds(700)
    static let noSpeechTimeout = Duration.seconds(15)
    static let maximumDuration = Duration.seconds(180)

    /// How many consecutive polls a near-miss must survive before it is
    /// worth telling the user about — one volatile hypothesis is noise.
    static let nearMissStablePolls = 3

    /// How far ahead of the silence auto-send the warning cue plays.
    static let silenceWarningLead = Duration.seconds(1)

    private let startedAt: ContinuousClock.Instant
    private let model: FinishPhraseModel
    /// Opt-in: how long the *words* must hold still before the session
    /// sends without a finish phrase. Nil (the default) disables it.
    private let silenceAutoFinish: Duration?
    private var finishCandidateKey: String?
    private var finishCandidateSince: ContinuousClock.Instant?
    private var nearMissStreak = 0
    private var nearMissCandidateKey: String?
    private var lastContentKey = ""
    private var lastContentChangeAt: ContinuousClock.Instant?
    private var silenceWarningIssued = false

    /// True while the user seems to be trying the phrase and the recognizer
    /// keeps not quite producing it. Read after `evaluate`; informational
    /// only — a near-miss never submits.
    private(set) var nearMissHint = false
    private(set) var silenceWarningActive = false

    init(
        startedAt: ContinuousClock.Instant,
        model: FinishPhraseModel = .standard,
        silenceAutoFinish: Duration? = nil
    ) {
        self.startedAt = startedAt
        self.model = model
        self.silenceAutoFinish = silenceAutoFinish
    }

    mutating func evaluate(
        transcript: String,
        at instant: ContinuousClock.Instant,
        isFinal: Bool = false
    ) -> Action {
        let current = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentKey = Self.normalizedWords(in: current)
        if contentKey != lastContentKey {
            lastContentKey = contentKey
            lastContentChangeAt = contentKey.isEmpty ? nil : instant
            silenceWarningIssued = false
            silenceWarningActive = false
        } else if !contentKey.isEmpty, lastContentChangeAt == nil {
            lastContentChangeAt = instant
        }

        let evaluation = VoiceFinishPhrase.evaluate(in: current, model: model)
        if evaluation.match != nil {
            nearMissStreak = 0
            nearMissCandidateKey = nil
            nearMissHint = false
        } else if evaluation.nearMiss {
            if nearMissCandidateKey == contentKey {
                nearMissStreak += 1
            } else {
                nearMissCandidateKey = contentKey
                nearMissStreak = 1
            }
            if nearMissStreak >= Self.nearMissStablePolls { nearMissHint = true }
        } else {
            nearMissStreak = 0
            nearMissCandidateKey = nil
            nearMissHint = false
        }
        if let match = evaluation.match {
            // A final recognizer result has already passed a stronger stability
            // boundary than the polling settle delay.
            if isFinal, match.confidence == .exact { return .finish(match.request) }
            // Settle is keyed on the words that would be sent, not the raw
            // transcript: cosmetic churn does not reset the clock, but either
            // a changed request word or changed phrase hypothesis still does.
            let key = Self.settleKey(for: match)
            let required = match.confidence == .exact
                ? Self.finishSettle : Self.fuzzySettle
            if finishCandidateKey == key {
                if let since = finishCandidateSince,
                   instant - since >= required {
                    return .finish(match.request)
                }
            } else {
                finishCandidateKey = key
                finishCandidateSince = instant
            }
        } else {
            finishCandidateKey = nil
            finishCandidateSince = nil
        }

        if current.isEmpty, instant - startedAt >= Self.noSpeechTimeout {
            return .timeout
        }
        if instant - startedAt >= Self.maximumDuration {
            return .timeout
        }
        if let silenceAutoFinish, !contentKey.isEmpty,
           let changedAt = lastContentChangeAt {
            let quietFor = instant - changedAt
            if quietFor >= silenceAutoFinish {
                silenceWarningActive = false
                let request = VoiceFinishPhrase.strippingTrailingPhraseArtifacts(
                    current, model: model
                )
                if !request.isEmpty { return .finishAfterSilence(request) }
            } else if !silenceWarningIssued,
                      quietFor + Self.silenceWarningLead >= silenceAutoFinish {
                silenceWarningIssued = true
                silenceWarningActive = true
                return .silenceWarning
            }
        }
        return .none
    }

    private static func normalizedWords(in text: String) -> String {
        FinishPhraseMatching.words(in: text).joined(separator: " ")
    }

    /// Case, punctuation, and spacing churn collapse; lexical changes on
    /// either side of the phrase boundary restart the safety window.
    private static func settleKey(for match: VoiceFinishPhrase.Match) -> String {
        let confidence = match.confidence == .exact ? "exact" : "fuzzy"
        return "\(normalizedWords(in: match.request))|\(match.signature)|\(confidence)"
    }
}

/// What the assistant may say out loud while the user may be listening to
/// music. Answers to a spoken question always play; everything else is a
/// chime and the HUD unless quiet mode is off.
enum VoiceSpeechPolicy {
    /// Mid-turn tool chatter talks over music and the HUD already shows
    /// Thinking…. Never spoken during a voice turn.
    static func shouldSpeakMilestones(quiet _: Bool) -> Bool { false }

    static func shouldSpeakNudge(quiet: Bool) -> Bool { !quiet }
    static func shouldSpeakPrompts(quiet: Bool) -> Bool { !quiet }
    static func shouldSpeakAcks(quiet: Bool) -> Bool { !quiet }
    static func shouldSpeakAnswers(quiet _: Bool) -> Bool { true }
}

/// The global voice mode: hold ⇧⌥ anywhere, talk to the assistant, hear it
/// answer. App-level and headless — it never steals focus, never opens a
/// window, and works the same whether the user is in ORE, Safari, or a
/// terminal.
///
/// Owns its own `VoiceInputController` rather than borrowing a composer's:
/// the composer's dictation is per-pane state tied to what's on screen, and
/// the whole point of the assistant is that it isn't.
@MainActor
@Observable
final class VoiceAssistantController {
    /// Where the exchange is, for the floating HUD: nothing → mic open →
    /// waiting on the assistant → nothing again once the reply is spoken.
    enum Phase: Equatable {
        case idle
        /// The hold threshold fired; release the modifiers to open the mic.
        case armed
        case listening
        case thinking
        /// A short open mic right after a narrated confirmation, so "yes"
        /// doesn't need another chord.
        case answering
        /// TTS is playing — the HUD stays up so the user can see the assistant
        /// speaking the same way they see it listening.
        case speaking
    }

    private(set) var phase: Phase = .idle {
        didSet {
            AssistantVoiceHUD.shared.phaseChanged(self)
            updateSpeechWatchdog()
        }
    }

    /// Whether the assistant's microphone is open.
    var isListening: Bool { phase == .listening }

    /// Live views into the recognizer, for the HUD's transcript tail and
    /// waveform. Reads register observation — `VoiceInputController` is
    /// `@Observable` — so the HUD animates without any forwarding.
    var liveTranscript: String { voice.transcript }
    var audioLevel: Double { voice.audioLevel }
    private(set) var answerPlaceholder = "Yes or no?"
    /// How much of the utterance being spoken has actually been voiced, for the
    /// HUD to stream.
    var spokenSoFar: String {
        model?.narration.spokenPrefix ?? ""
    }

    /// Whether Escape has something to stop — a turn in flight or a line being
    /// spoken. The HUD shows the key cap exactly when this is true.
    var canInterrupt: Bool {
        phase == .armed || phase == .thinking || phase == .speaking
    }

    /// Hands-free send uses a spoken finish phrase. Hold-to-talk sends on
    /// release, so the HUD and the recognizer must not wait for one.
    var usesFinishPhrase: Bool {
        !UserDefaults.standard.bool(forKey: VoiceHotkeyMonitor.holdToTalkKey)
    }

    /// The phrase the HUD should tell the user to say — tuned or stock.
    var finishPhraseSpoken: String { handsFreePhraseModel.spoken }

    /// HUD and chimes only: speak the answer to a spoken question, not progress.
    static let quietModeKey = "ore.voice.quietMode"
    static let silenceAutoSendKey = "ore.voice.silenceAutoSend"
    private static let silenceAutoSendDelay = Duration.seconds(3)

    private var quietMode: Bool {
        UserDefaults.standard.bool(forKey: Self.quietModeKey)
    }

    private var silenceAutoSendEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.silenceAutoSendKey)
    }

    weak var model: AppModel?

    private let voice = VoiceInputController()
    /// The finish-phrase rules for the session currently listening, loaded
    /// when the mic opens.
    private var handsFreePhraseModel: FinishPhraseModel = .standard
    /// A gentle correction shown in the HUD when the user is close to the
    /// finish phrase but the recognizer keeps not quite producing it.
    private(set) var finishHint: String?
    private var finishLogEnabled = false
    private var finishLogStartedAt: ContinuousClock.Instant?
    private var finishLogEntries: [FinishPhraseDebugLog.Entry] = []
    private var startTask: Task<Void, Never>?
    private var handsFreeTask: Task<Void, Never>?
    private var stillWorkingTask: Task<Void, Never>?
    private var answerWindowTask: Task<Void, Never>?
    private var speechWatchdogTask: Task<Void, Never>?
    /// The needs-you prompt currently being spoken or answered. Its stable ID
    /// lets a click elsewhere dismiss the voice flow immediately rather than
    /// opening the answer microphone after the prompt is cancelled.
    private var activeNeedsYouID: String?
    /// The conversation the user's spoken question went to, held until it is
    /// answered — that turn's completion is spoken no matter what the ambient
    /// narration settings say.
    ///
    /// A chat rather than a flag: the assistant has several conversations now,
    /// and a fleet digest finishing in one must not be taken for the answer to
    /// a question asked in another.
    private var awaitingSpokenReplyFrom: ChatID?
    private var awaitingSpokenReply: Bool { awaitingSpokenReplyFrom != nil }
    private var lastVoiceInteraction: Date?
    /// Milestone throttling: the last phrase spoken and when, so a burst of
    /// tool calls narrates as a beat, not a commentary track.
    private var lastMilestone: String?
    private var lastMilestoneAt: Date = .distantPast
    /// Bumped by `cancel()`. Every `notifyWhenQuiet` continuation captures it
    /// and bails if it changed — stopping the speech *causes* those callbacks
    /// to fire, and without this the one that opens the hands-free answer mic
    /// would open it a beat after the user asked for silence.
    private var cancelToken = 0

    /// How long after a voice exchange a confirmation is still narrated (and
    /// answerable by voice). Matches the action policy's task-grant window —
    /// the same notion of "the user is still in this task".
    private static let voiceSessionWindow: TimeInterval = 15 * 60

    /// A reply slower than this earns one spoken nudge, so a long-running
    /// status query doesn't feel like the assistant went away.
    private static let stillWorkingDelay: Duration = .seconds(12)

    /// Minimum quiet between spoken milestones.
    private static let milestoneGap: TimeInterval = 5

    /// How long the hands-free answer mic stays open before giving up and
    /// leaving the confirmation to the window, the notification, or a chord.
    private static let answerWindow: Duration = .seconds(7)

    /// AVSpeechSynthesizer can occasionally decline an utterance without
    /// delivering either delegate ending. Do not let that missing callback
    /// pin the global pill on "Speaking…" forever.
    private func updateSpeechWatchdog() {
        speechWatchdogTask?.cancel()
        speechWatchdogTask = nil
        guard phase == .speaking else { return }
        speechWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.phase == .speaking,
                  self.model?.narration.hasAudibleOrQueuedSpeech == false
            else { return }
            self.phase = self.awaitingSpokenReply ? .thinking : .idle
        }
    }

    func handle(_ command: VoiceCommand) {
        guard command.target == .assistant else { return }
        switch command.kind {
        case .arm: armTrigger()
        case .disarm: disarmTrigger()
        case .start: begin()
        case .stop: finish()
        case .cancel: cancel()
        case .toggle, .commit: break
        }
    }

    /// Escape: stop whatever the assistant is doing, from wherever the user is.
    ///
    /// What "stop" means depends on where the exchange got to — abandoning a
    /// half-spoken request, killing a turn that is taking too long, or cutting
    /// off an answer the user has already heard enough of. All three end with
    /// the pill gone and nothing running.
    private func cancel() {
        guard phase != .idle else { return }
        cancelToken += 1
        startTask?.cancel()
        startTask = nil
        stillWorkingTask?.cancel()
        stillWorkingTask = nil
        handsFreeTask?.cancel()
        handsFreeTask = nil

        switch phase {
        case .armed:
            phase = .idle
        case .answering:
            // The confirmation itself stays pending: Escape declines to answer
            // by voice, it doesn't answer. The window and the notification
            // still carry it.
            closeAnswerWindow()
        case .listening:
            // The words are dropped rather than sent — the user changed their
            // mind mid-sentence, which is the whole reason they reached for the
            // key instead of releasing the chord.
            flushFinishLog(outcome: "cancel")
            if voice.isActive { voice.stop() }
            model?.narration.setMicActive(false)
            phase = .idle
        case .thinking, .speaking:
            let waitingOn = awaitingSpokenReplyFrom
            awaitingSpokenReplyFrom = nil
            model?.narration.stopAll()
            // Only a turn we're actually waiting on: cutting off "Okay, going
            // ahead." shouldn't kill a turn the user didn't start by voice.
            if let waitingOn { model?.interruptAssistant(chatID: waitingOn) }
            phase = .idle
        case .idle:
            break
        }
    }

    // MARK: - Microphone

    private func armTrigger() {
        // A full assistant request can replace the tiny automatic answer
        // window, but an in-flight request/answer still belongs to Escape.
        if phase == .answering { closeAnswerWindow() }
        guard phase == .idle else { return }
        phase = .armed
        playCue(named: "Tink", volume: 0.24)
    }

    private func disarmTrigger() {
        guard phase == .armed else { return }
        startTask?.cancel()
        startTask = nil
        phase = .idle
    }

    private func begin() {
        guard let model, phase == .armed else { return }
        guard !voice.isActive else { return }
        startTask?.cancel()
        if model.narration.isMicActive {
            // A composer dictation owns the audio. Park its words in its
            // draft — never send something the user didn't finish — give the
            // recognizer a beat to let go, then take the microphone.
            VoiceHotkeyMonitor.shared.requestComposerCommit()
            startTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                self?.openMic()
            }
        } else {
            openMic()
        }
    }

    private func openMic() {
        guard let model, phase == .armed, !voice.isActive else { return }
        // The phrase model is read once per session, so tuning mid-session
        // can't change the rules under an open microphone.
        let phraseModel = FinishPhraseStore.load() ?? .standard
        handsFreePhraseModel = phraseModel
        finishHint = nil
        finishLogEnabled = FinishPhraseDebugLog.isEnabled
        finishLogStartedAt = nil
        finishLogEntries = []
        // Prime the recognizer with the names it will otherwise mangle.
        var names = projectNames()
        if usesFinishPhrase { names += phraseModel.vocabulary }
        voice.vocabulary = names
        phase = .listening
        // Ducking: the assistant must not talk over the user, and its TTS
        // must not leak into the transcription.
        model.narration.setMicActive(true)
        voice.start()
        // Hold-to-talk sends on release; a finish-phrase watcher would steal the
        // utterance or time out while the chord is still down.
        if usesFinishPhrase { watchHandsFreeSession() }
    }

    private func watchHandsFreeSession() {
        handsFreeTask?.cancel()
        handsFreeTask = Task { @MainActor [weak self] in
            var guardState: HandsFreeListeningGuard?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, self.phase == .listening else { return }
                if case .error = self.voice.status {
                    self.flushFinishLog(outcome: "error")
                    self.closeListeningWithoutSending(playCue: false)
                    return
                }
                let now = ContinuousClock.now
                if guardState == nil {
                    // Permission/model preparation can legitimately take longer
                    // than the no-speech window. Start that clock only once
                    // audio is really flowing.
                    guard self.voice.isListening else { continue }
                    guardState = HandsFreeListeningGuard(
                        startedAt: now,
                        model: self.handsFreePhraseModel,
                        silenceAutoFinish: self.silenceAutoSendEnabled
                            ? Self.silenceAutoSendDelay : nil
                    )
                }
                guard var next = guardState else { continue }
                let recognitionEnded = !self.voice.isActive
                let action = next.evaluate(
                    transcript: self.voice.transcript,
                    at: now,
                    isFinal: recognitionEnded
                )
                guardState = next
                self.noteFinishProgress(
                    action: action,
                    nearMiss: next.nearMissHint,
                    silenceWarning: next.silenceWarningActive,
                    at: now
                )
                switch action {
                case .none:
                    if recognitionEnded {
                        self.flushFinishLog(outcome: "ended")
                        self.closeListeningWithoutSending(playCue: true)
                        return
                    }
                    continue
                case .finish(let request):
                    self.flushFinishLog(outcome: "finish")
                    self.finish(spokenOverride: request)
                case .silenceWarning:
                    self.playCue(named: "Tink", volume: 0.12)
                    continue
                case .finishAfterSilence(let request):
                    self.flushFinishLog(outcome: "silence")
                    self.finish(spokenOverride: request)
                case .timeout:
                    self.flushFinishLog(outcome: "timeout")
                    self.closeListeningWithoutSending(playCue: true)
                }
                return
            }
        }
    }

    /// Feeds the HUD's near-miss hint and the opt-in diagnostic log, once
    /// per guard poll. The hint appears while the user seems to be trying
    /// the phrase and disappears the moment they say something else.
    private func noteFinishProgress(
        action: HandsFreeListeningGuard.Action,
        nearMiss: Bool,
        silenceWarning: Bool,
        at now: ContinuousClock.Instant
    ) {
        if silenceWarning {
            finishHint = "Sending in one second — keep talking to cancel"
        } else if nearMiss {
            if finishHint == nil {
                finishHint = "Almost — say “\(handsFreePhraseModel.spoken)” once more"
            }
        } else {
            finishHint = nil
        }

        guard finishLogEnabled else { return }
        if finishLogStartedAt == nil { finishLogStartedAt = now }
        let transcript = voice.transcript
        let saw = switch action {
        case .finish: "finish"
        case .silenceWarning: "silenceWarning"
        case .finishAfterSilence: "silenceFinish"
        case .timeout: "timeout"
        case .none: nearMiss ? "nearMiss" : "none"
        }
        // One entry per change, not one per poll: the transcript is the
        // diagnostic payload, and it holds still most of the time.
        if let last = finishLogEntries.last,
           last.suffix == FinishPhraseDebugLog.suffix(of: transcript), last.saw == saw { return }
        let elapsed = now - (finishLogStartedAt ?? now)
        finishLogEntries.append(FinishPhraseDebugLog.Entry(
            ms: Int(elapsed / .milliseconds(1)),
            suffix: FinishPhraseDebugLog.suffix(of: transcript),
            saw: saw
        ))
    }

    /// Ships the session's log to disk (off the main actor) and drops the
    /// hint. Harmless when logging is off or nothing was heard.
    private func flushFinishLog(outcome: String) {
        finishHint = nil
        guard finishLogEnabled, !finishLogEntries.isEmpty else { return }
        let session = FinishPhraseDebugLog.Session(
            endedAt: Date(),
            outcome: outcome,
            recognizer: voice.recognizerRoute?.rawValue,
            contextApplied: voice.contextualBiasApplied,
            entries: finishLogEntries
        )
        finishLogEntries = []
        Task.detached(priority: .utility) {
            FinishPhraseDebugLog.append(session)
        }
    }

    /// The proper nouns of this user's world: workspace names and repository
    /// names — used both to bias recognition and to repair near-misses.
    private func projectNames() -> [String] {
        guard let model else { return [] }
        var names = model.workspaces.map(\.name)
        names += model.repositories.map { (($0 as NSString).lastPathComponent) }
        return names
    }

    private func finish(spokenOverride: String? = nil) {
        startTask?.cancel()
        startTask = nil
        handsFreeTask?.cancel()
        handsFreeTask = nil
        guard isListening else { return }
        let heard = (spokenOverride ?? voice.transcript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = VoiceVocabulary(names: projectNames()).corrected(heard)
        if voice.isActive { voice.stop() }
        model?.narration.setMicActive(false)

        guard let model, !spoken.isEmpty else {
            phase = .idle
            return
        }
        lastVoiceInteraction = Date()

        // A short yes/no while a confirmation is pending answers *it* rather
        // than becoming a message — this is how "push it" → "say yes" → "yes"
        // stays one fluid exchange.
        if let confirmation = model.assistantConfirmations.first,
           let decision = Self.confirmationDecision(from: spoken) {
            phase = .idle
            model.resolveAssistantConfirmation(confirmation.id, decision: decision)
            if let chatID = model.assistantChatID {
                let ack = if case .allow = decision { "Okay, going ahead." }
                    else { "Okay, I won't." }
                acknowledge(ack, chatID: chatID)
            }
            return
        }

        if let needs = model.tabNeedsYou.first {
            switch needs {
            case .permission:
                if let decision = Self.confirmationDecision(from: spoken) {
                    resolvePermissionNeed(needs, decision: decision)
                    return
                }
            case .question(let payload):
                if let answer = Self.questionAnswer(from: spoken, question: payload.question) {
                    resolveQuestionNeed(needs, answer: answer)
                    return
                }
            case .plan(let payload):
                if let decision = Self.confirmationDecision(from: spoken) {
                    resolvePlanNeed(payload, decision: decision, spoken: spoken)
                    return
                }
            }
        }

        guard let assistant = model.assistantWorkspace else {
            phase = .idle
            return
        }
        phase = .thinking
        // The chat the message actually reached, rather than whichever is
        // active by the time the answer arrives.
        awaitingSpokenReplyFrom = model.send(spoken, to: assistant.id)
        // A spoken "On it." talks over whatever the user is listening to.
        // The HUD already says Thinking…; a quiet close-mic cue is enough.
        playCue(named: "Pop", volume: 0.16)
        scheduleStillWorkingNudge()
    }

    private func closeListeningWithoutSending(playCue shouldPlay: Bool) {
        handsFreeTask?.cancel()
        handsFreeTask = nil
        if voice.isActive { voice.stop() }
        model?.narration.setMicActive(false)
        finishHint = nil
        phase = .idle
        if shouldPlay { playCue(named: "Pop", volume: 0.18) }
    }

    /// One nudge, once, and only if the turn is genuinely still open — silence
    /// after the close-mic cue is what makes a slow answer feel like a dropped one.
    private func scheduleStillWorkingNudge() {
        stillWorkingTask?.cancel()
        stillWorkingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.stillWorkingDelay)
            guard !Task.isCancelled, let self, self.phase == .thinking,
                  let model = self.model, let chatID = model.assistantChatID,
                  VoiceSpeechPolicy.shouldSpeakNudge(quiet: self.quietMode)
            else { return }
            model.narration.speakAssistant("Still on it — a moment.", chatID: chatID)
            phase = .speaking
            let token = cancelToken
            model.narration.notifyWhenQuiet { [weak self] in
                guard let self, self.cancelToken == token,
                      self.phase == .speaking, self.awaitingSpokenReply
                else { return }
                self.phase = .thinking
            }
        }
    }

    // MARK: - Assistant events

    /// Assistant-chat agent events, forwarded from the model's intake.
    ///
    /// Tagged with the conversation they came from: only the one the user's
    /// question went to may answer it out loud.
    func observe(_ event: AgentEvent, chatID: ChatID) {
        guard let model, awaitingSpokenReplyFrom == chatID else { return }
        switch event {
        case .toolCall(let call):
            // Mid-turn milestones, only for turns the user is waiting on by
            // ear. Progress priority: they thin out under load, never delay
            // the reply, and are dropped wholesale the moment a mic opens.
            guard awaitingSpokenReply,
                  let phrase = Self.milestone(for: call.name),
                  phrase != lastMilestone || Date().timeIntervalSince(lastMilestoneAt) > 20,
                  Date().timeIntervalSince(lastMilestoneAt) >= Self.milestoneGap
            else { return }
            lastMilestone = phrase
            lastMilestoneAt = Date()
            // The HUD already shows Thinking…. Spoken milestones talk over
            // music even when quiet mode is off.
            guard VoiceSpeechPolicy.shouldSpeakMilestones(quiet: quietMode) else { return }
            model.narration.speakAssistant(phrase, chatID: chatID, priority: .progress)
            if phase == .thinking {
                phase = .speaking
                let token = cancelToken
                model.narration.notifyWhenQuiet { [weak self] in
                    guard let self, self.cancelToken == token,
                          self.phase == .speaking, self.awaitingSpokenReply
                    else { return }
                    self.phase = .thinking
                }
            }

        case .turnCompleted(let result):
            awaitingSpokenReplyFrom = nil
            stillWorkingTask?.cancel()
            // The assistant's limit, not the ambient one: this line is the
            // answer to a question the user asked out loud, and how long it
            // runs is the question's business.
            let line = NarrationPhraser.spokenNarration(
                result.narration, limit: NarrationPolicy.assistantAnswerLimit
            ) ?? "Done — the details are in the assistant window."
            speakKeepingHUD(line, chatID: chatID, limit: NarrationPolicy.assistantAnswerLimit)

        case .sessionError(let error):
            awaitingSpokenReplyFrom = nil
            stillWorkingTask?.cancel()
            speakKeepingHUD(
                "Something went wrong: \(error.message)", chatID: chatID
            )

        default:
            break
        }
    }

    /// A confirmation arrived. Inside a voice exchange it is narrated — and
    /// then the microphone opens by itself for a beat, so "yes" is just said,
    /// not chorded. Outside one, the notification and the Assistant window
    /// carry it.
    func confirmationArrived(_ confirmation: AssistantConfirmation) {
        guard let model, let chatID = model.assistantChatID else { return }
        let recentVoice = lastVoiceInteraction.map {
            Date().timeIntervalSince($0) < Self.voiceSessionWindow
        } ?? false
        guard awaitingSpokenReply || recentVoice else { return }
        if VoiceSpeechPolicy.shouldSpeakPrompts(quiet: quietMode) {
            model.narration.speakAssistant(
                NarrationPhraser.confirmationAsk(confirmation.summary),
                chatID: chatID
            )
            phase = .speaking
            let token = cancelToken
            model.narration.notifyWhenQuiet { [weak self] in
                guard let self, self.cancelToken == token else { return }
                self.openAnswerWindow(for: confirmation.id)
            }
        } else {
            playCue(named: "Tink", volume: 0.24)
            openAnswerWindow(for: confirmation.id)
        }
    }

    /// The `AskUserQuestion` tool's spoken half: questions always earn the
    /// voice treatment (speak the ask, chime, open the mic) — an agent asking
    /// the user for a fact deserves an answer at the speed of speech, not a
    /// trip to the keyboard. Off-switchable in Settings › Voice input.
    static let voiceAskKey = "ore.voice.answerQuestions"

    private var voiceAsksEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.voiceAskKey) as? Bool ?? true
    }

    /// A soft cue that the microphone just opened for an answer — quiet by
    /// design: it marks a turn to speak, it doesn't demand one.
    private func playMicChime() {
        playCue(named: "Tink", volume: 0.2)
    }

    private func playCue(named name: NSSound.Name, volume: Float) {
        guard let sound = NSSound(named: name) else { return }
        sound.volume = volume
        sound.play()
    }

    @discardableResult
    func needsYouArrived(_ item: TabNeedsYou) -> Bool {
        guard let model, let chatID = model.assistantChatID else { return false }
        let recentVoice = lastVoiceInteraction.map {
            Date().timeIntervalSince($0) < Self.voiceSessionWindow
        } ?? false
        let isQuestion = if case .question = item { true } else { false }
        guard awaitingSpokenReply || recentVoice || !NSApp.isActive
            || (isQuestion && voiceAsksEnabled) else { return false }
        lastVoiceInteraction = Date()
        activeNeedsYouID = item.id
        if VoiceSpeechPolicy.shouldSpeakPrompts(quiet: quietMode) {
            // The assistant's limit, not the ambient one. A question carrying
            // several options runs past 280 characters easily, and at the
            // ambient cap `spokenNarration` replaced the tail of the option
            // list with "there's more in the Assistant window" — cutting off
            // the choices in the middle of reading them out.
            model.narration.speakAssistant(
                item.spokenPrompt(place: model.spokenPlace(for: item)),
                chatID: chatID,
                limit: NarrationPolicy.assistantAnswerLimit,
                kind: item.narrationKind
            )
            phase = .speaking
            let token = cancelToken
            model.narration.notifyWhenQuiet { [weak self] in
                guard let self, self.cancelToken == token else { return }
                self.openNeedsYouWindow(for: item.id)
            }
        } else {
            openNeedsYouWindow(for: item.id)
        }
        return true
    }

    /// The permission was answered by a button, notification, assistant tool,
    /// or voice. Cancel the continuation that would open the answer mic and
    /// make the HUD reflect that there is no longer anything to answer.
    func permissionResolved(_ id: PermissionRequestID) {
        guard activeNeedsYouID == "permission-\(id.rawValue)" else { return }
        activeNeedsYouID = nil
        cancelToken += 1
        answerWindowTask?.cancel()
        answerWindowTask = nil
        if phase == .answering {
            if voice.isActive { voice.stop() }
            model?.narration.setMicActive(false)
        }
        if phase == .speaking || phase == .answering {
            // A permission can interrupt an assistant answer already in
            // flight. Return to waiting for that answer instead of making the
            // whole voice exchange look finished.
            phase = awaitingSpokenReply ? .thinking : .idle
        }
    }

    /// Acks are optional under quiet mode: a Pop is enough, and the HUD
    /// already shows whether a turn is still running.
    private func acknowledge(_ text: String, chatID: ChatID) {
        if VoiceSpeechPolicy.shouldSpeakAcks(quiet: quietMode) {
            speakKeepingHUD(text, chatID: chatID)
        } else {
            playCue(named: "Pop", volume: 0.16)
            phase = awaitingSpokenReply ? .thinking : .idle
        }
    }

    /// Speak while keeping the HUD up as `.speaking`, then return to `resume`
    /// (or idle) once TTS finishes.
    private func speakKeepingHUD(
        _ text: String,
        chatID: ChatID,
        resume: Phase = .idle,
        limit: Int = NarrationPolicy.utteranceLimit
    ) {
        guard let model else { return }
        model.narration.speakAssistant(text, chatID: chatID, limit: limit)
        phase = .speaking
        let token = cancelToken
        model.narration.notifyWhenQuiet { [weak self] in
            guard let self, self.cancelToken == token, self.phase == .speaking else { return }
            self.phase = self.awaitingSpokenReply ? .thinking : resume
        }
    }

    // MARK: - Hands-free answers

    private func openAnswerWindow(for confirmationID: String) {
        guard let model, phase != .listening && phase != .answering, !voice.isActive,
              model.assistantConfirmations.contains(where: { $0.id == confirmationID })
        else { return }
        answerPlaceholder = "Yes or no?"
        voice.vocabulary = ["yes", "no"]
        phase = .answering
        model.narration.setMicActive(true)
        voice.start()

        answerWindowTask?.cancel()
        answerWindowTask = Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now.advanced(by: Self.answerWindow)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.phase == .answering, let model = self.model else { return }
                // Resolved from the window or the notification while we were
                // listening — nothing left to answer.
                guard model.assistantConfirmations.contains(where: { $0.id == confirmationID })
                else {
                    self.closeAnswerWindow()
                    return
                }
                guard Self.confirmationDecision(from: self.voice.transcript) != nil else {
                    continue
                }
                // A polarity appeared — but "no…" may still be becoming
                // "no problem, go ahead". Wait for the phrase to finish, then
                // read the whole utterance.
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, self.phase == .answering else { return }
                let settled = Self.confirmationDecision(from: self.voice.transcript)
                self.closeAnswerWindow()
                guard let settled else { return }
                self.lastVoiceInteraction = Date()
                model.resolveAssistantConfirmation(confirmationID, decision: settled)
                if let chatID = model.assistantChatID {
                    let ack = if case .allow = settled { "Okay, going ahead." }
                        else { "Okay, I won't." }
                    self.acknowledge(ack, chatID: chatID)
                }
                return
            }
            self?.closeAnswerWindow()
        }
    }

    private func openNeedsYouWindow(for itemID: String) {
        guard let model, phase != .listening && phase != .answering, !voice.isActive,
              let item = model.tabNeedsYou.first(where: { $0.id == itemID })
        else { return }
        switch item {
        case .permission:
            openPermissionWindow(for: item)
        case .question(let payload):
            openQuestionWindow(for: item, question: payload.question)
        case .plan(let payload):
            openPlanWindow(for: item, payload: payload)
        }
    }

    private func openPermissionWindow(for item: TabNeedsYou) {
        guard let model else { return }
        answerPlaceholder = "Yes, no, or always?"
        voice.vocabulary = ["yes", "no", "always", "auto-allow"]
        phase = .answering
        playMicChime()
        model.narration.setMicActive(true)
        voice.start()

        answerWindowTask?.cancel()
        answerWindowTask = Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now.advanced(by: Self.answerWindow)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.phase == .answering, let model = self.model else { return }
                guard model.tabNeedsYou.contains(where: { $0.id == item.id }) else {
                    self.closeAnswerWindow()
                    return
                }
                guard Self.confirmationDecision(from: self.voice.transcript) != nil else {
                    continue
                }
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, self.phase == .answering else { return }
                let settled = Self.confirmationDecision(from: self.voice.transcript)
                self.closeAnswerWindow()
                guard let settled else { return }
                self.lastVoiceInteraction = Date()
                self.resolvePermissionNeed(item, decision: settled)
                return
            }
            self?.closeAnswerWindow()
        }
    }

    private func openQuestionWindow(for item: TabNeedsYou, question: AgentQuestion) {
        guard let model else { return }
        answerPlaceholder = "Say your answer…"
        voice.vocabulary = question.options.map(\.label)
        phase = .answering
        playMicChime()
        model.narration.setMicActive(true)
        voice.start()

        answerWindowTask?.cancel()
        answerWindowTask = Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now.advanced(by: Self.answerWindow)
            var lastTranscript = ""
            var unchangedSince = ContinuousClock.now
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.phase == .answering, let model = self.model else { return }
                guard model.tabNeedsYou.contains(where: { $0.id == item.id }) else {
                    self.closeAnswerWindow()
                    return
                }
                let transcript = self.voice.transcript
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if transcript != lastTranscript {
                    lastTranscript = transcript
                    unchangedSince = ContinuousClock.now
                    continue
                }
                // Unlike yes/no, an arbitrary answer has no keyword that says
                // it is complete. A short quiet settle is the speech equivalent
                // of releasing Return in a text field.
                guard !transcript.isEmpty,
                      ContinuousClock.now - unchangedSince >= .milliseconds(800),
                      let answer = Self.questionAnswer(from: transcript, question: question)
                else { continue }
                self.closeAnswerWindow()
                self.lastVoiceInteraction = Date()
                self.resolveQuestionNeed(item, answer: answer)
                return
            }
            self?.closeAnswerWindow()
        }
    }

    private func openPlanWindow(for item: TabNeedsYou, payload: TabNeedsYou.Plan) {
        guard let model else { return }
        answerPlaceholder = "Yes to approve, or no to reject"
        voice.vocabulary = ["yes", "no", "approve", "reject"]
        phase = .answering
        playMicChime()
        model.narration.setMicActive(true)
        voice.start()

        answerWindowTask?.cancel()
        answerWindowTask = Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now.advanced(by: Self.answerWindow)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.phase == .answering, let model = self.model else { return }
                guard model.tabNeedsYou.contains(where: { $0.id == item.id }) else {
                    self.closeAnswerWindow()
                    return
                }
                guard Self.confirmationDecision(from: self.voice.transcript) != nil else {
                    continue
                }
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, self.phase == .answering else { return }
                let settled = Self.confirmationDecision(from: self.voice.transcript)
                self.closeAnswerWindow()
                guard let settled else { return }
                self.lastVoiceInteraction = Date()
                self.resolvePlanNeed(payload, decision: settled, spoken: self.voice.transcript)
                return
            }
            self?.closeAnswerWindow()
        }
    }

    private func resolvePlanNeed(
        _ payload: TabNeedsYou.Plan,
        decision: AssistantConfirmationDecision,
        spoken: String
    ) {
        guard let model else { return }
        activeNeedsYouID = nil
        phase = .idle
        let approve: Bool
        switch decision {
        case .allow: approve = true
        case .deny: approve = false
        }
        let feedback: String
        if case .deny = decision {
            let stripped = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            feedback = Self.confirmationDecision(from: stripped) != nil ? "" : stripped
        } else {
            feedback = ""
        }
        model.respondToPlan(
            chatID: payload.chatID,
            workspaceID: payload.workspaceID,
            approve: approve,
            feedback: feedback
        )
        if let chatID = model.assistantChatID {
            acknowledge(approve ? "Okay, going ahead." : "Okay, I'll send that back.", chatID: chatID)
        }
    }

    private func resolvePermissionNeed(
        _ item: TabNeedsYou,
        decision: AssistantConfirmationDecision
    ) {
        guard let model else { return }
        activeNeedsYouID = nil
        phase = .idle
        switch (item, decision) {
        case (.permission(let payload), .allow(.always)):
            model.autoAllowTab(
                workspaceID: payload.workspaceID,
                chatID: payload.chatID,
                permissionID: payload.request.id
            )
        case (.permission(let payload), .allow):
            model.resolvePermission(
                payload.request.id, decision: .allow,
                for: payload.workspaceID, chatID: payload.chatID
            )
        case (.permission(let payload), .deny):
            model.resolvePermission(
                payload.request.id,
                decision: .deny(reason: "The user denied this by voice."),
                for: payload.workspaceID, chatID: payload.chatID
            )
        case (.question, _), (.plan, _):
            return
        }
        if let chatID = model.assistantChatID {
            let ack: String
            if case .deny = decision { ack = "Okay, I won't." }
            else if case .allow(.always) = decision { ack = "Okay — auto-allowing that tab." }
            else { ack = "Okay, going ahead." }
            acknowledge(ack, chatID: chatID)
        }
    }

    private func resolveQuestionNeed(_ item: TabNeedsYou, answer: String) {
        guard let model, case .question(let payload) = item else { return }
        activeNeedsYouID = nil
        phase = .idle
        model.answerQuestion(
            payload.question.id,
            answer: answer,
            for: payload.workspaceID,
            chatID: payload.chatID
        )
        if let chatID = model.assistantChatID {
            acknowledge("Got it — I passed that answer along.", chatID: chatID)
        }
    }

    private func closeAnswerWindow() {
        answerWindowTask?.cancel()
        answerWindowTask = nil
        guard phase == .answering else { return }
        if voice.isActive { voice.stop() }
        model?.narration.setMicActive(false)
        answerPlaceholder = "Yes or no?"
        phase = .idle
    }

    // MARK: - Parsing

    /// What a tool call sounds like, for mid-turn narration. Only the ORE
    /// tools that represent real progress get a phrase; file reads and greps
    /// are mechanics, not milestones.
    nonisolated static func milestone(for tool: String) -> String? {
        let name = tool.components(separatedBy: "__").last ?? tool
        return switch name {
        case "ListWorkspaces": "Checking your workspaces."
        case "ListChats": "Looking through its chats."
        case "WorkspaceStatus": "Getting its status."
        case "SearchTranscripts": "Searching your history."
        case "GetTranscriptTail": "Reading the conversation."
        case "CreateWorkspace": "Spinning up a workspace."
        case "CreateChat": "Opening a chat."
        case "SendPromptToProject": "Handing it to the project's agent."
        case "Commit": "Committing."
        case "Push": "Pushing."
        case "CreatePullRequest": "Opening the pull request."
        case "ArchiveWorkspace": "Archiving."
        case "GetAppState": "Checking what's on screen."
        case "SetChatModel", "SwitchChatHarness", "SetChatPermissionMode", "SetChatEffort":
            "Updating the tab."
        case "ResolveChatPermission": "Handling the permission."
        case "ListMemory", "ReadMemory", "WriteMemory", "DeleteMemory": "Updating my notes."
        default: nil
        }
    }

    /// A spoken answer to a pending confirmation. The utterance is interpreted
    /// as a whole (see `ConfirmationIntent`); this is not a keyword scan.
    nonisolated static func confirmationDecision(
        from transcript: String
    ) -> AssistantConfirmationDecision? {
        ConfirmationIntent.decision(from: transcript)
    }

    /// Resolves a spoken question answer to the provider's exact option label
    /// when possible. Otherwise the user's words are preserved as freeform
    /// rather than silently selecting the first choice.
    nonisolated static func questionAnswer(
        from transcript: String,
        question: AgentQuestion
    ) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = normalizedAnswer(trimmed)
        if let option = question.options.first(where: {
            normalizedAnswer($0.label) == normalized
                || normalized == "option " + normalizedAnswer($0.label)
        }) {
            return option.label
        }

        let ordinals = ["first": 0, "one": 0, "second": 1, "two": 1,
                        "third": 2, "three": 2, "fourth": 3, "four": 3]
        for (word, index) in ordinals where normalized.split(separator: " ").contains(Substring(word)) {
            if question.options.indices.contains(index) { return question.options[index].label }
        }
        return question.allowsFreeform ? trimmed : nil
    }

    private nonisolated static func normalizedAnswer(_ text: String) -> String {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }
}
