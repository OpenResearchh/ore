import AppKit
import Foundation
import Observation
import OreProtocol

/// A deliberately unusual spoken terminator for hands-free requests.
///
/// Detection is suffix-only and token-based: punctuation and hyphens do not
/// matter, but ordinary prose containing the words earlier in the request does.
/// "Yep" is the one narrow ASR accommodation for "yip"; accepting broader
/// near-matches would turn a safety mechanism into a false-submit hazard.
enum VoiceFinishPhrase {
    static let spoken = "yip yap yip yip"
    static let vocabulary = ["yip", "yap", "yep", spoken]

    struct Match: Equatable {
        let request: String
    }

    private struct Token {
        let value: String
        let range: Range<String.Index>
    }

    static func match(in text: String) -> Match? {
        let tokens = tokens(in: text)
        guard tokens.count >= 4 else { return nil }
        let suffix = Array(tokens.suffix(4))
        let yip = Set(["yip", "yep"])
        guard yip.contains(suffix[0].value),
              suffix[1].value == "yap",
              yip.contains(suffix[2].value),
              yip.contains(suffix[3].value)
        else { return nil }

        let request = String(text[..<suffix[0].range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Match(request: request)
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
        case timeout
    }

    static let finishSettle = Duration.milliseconds(350)
    static let noSpeechTimeout = Duration.seconds(15)
    static let maximumDuration = Duration.seconds(180)

    private let startedAt: ContinuousClock.Instant
    private var finishCandidate: String?
    private var finishCandidateSince: ContinuousClock.Instant?

    init(startedAt: ContinuousClock.Instant) {
        self.startedAt = startedAt
    }

    mutating func evaluate(
        transcript: String,
        at instant: ContinuousClock.Instant,
        isFinal: Bool = false
    ) -> Action {
        let current = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = VoiceFinishPhrase.match(in: current) {
            // A final recognizer result has already passed a stronger stability
            // boundary than the polling settle delay.
            if isFinal { return .finish(match.request) }
            if finishCandidate == current {
                if let since = finishCandidateSince,
                   instant - since >= Self.finishSettle {
                    return .finish(match.request)
                }
            } else {
                finishCandidate = current
                finishCandidateSince = instant
            }
        } else {
            finishCandidate = nil
            finishCandidateSince = nil
        }

        if current.isEmpty, instant - startedAt >= Self.noSpeechTimeout {
            return .timeout
        }
        if instant - startedAt >= Self.maximumDuration {
            return .timeout
        }
        return .none
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

    /// HUD and chimes only: speak the answer to a spoken question, not progress.
    static let quietModeKey = "ore.voice.quietMode"

    private var quietMode: Bool {
        UserDefaults.standard.bool(forKey: Self.quietModeKey)
    }

    weak var model: AppModel?

    private let voice = VoiceInputController()
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
        // Prime the recognizer with the names it will otherwise mangle.
        var names = projectNames()
        if usesFinishPhrase { names += VoiceFinishPhrase.vocabulary }
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
                    self.closeListeningWithoutSending(playCue: false)
                    return
                }
                let now = ContinuousClock.now
                if guardState == nil {
                    // Permission/model preparation can legitimately take longer
                    // than the no-speech window. Start that clock only once
                    // audio is really flowing.
                    guard self.voice.isListening else { continue }
                    guardState = HandsFreeListeningGuard(startedAt: now)
                }
                guard var next = guardState else { continue }
                let recognitionEnded = !self.voice.isActive
                let action = next.evaluate(
                    transcript: self.voice.transcript,
                    at: now,
                    isFinal: recognitionEnded
                )
                guardState = next
                switch action {
                case .none:
                    if recognitionEnded {
                        self.closeListeningWithoutSending(playCue: true)
                        return
                    }
                    continue
                case .finish(let request):
                    self.finish(spokenOverride: request)
                case .timeout:
                    self.closeListeningWithoutSending(playCue: true)
                }
                return
            }
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
                "Quick check — \(confirmation.summary). Yes to allow it for this "
                    + "task, or no.",
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
            model.narration.speakAssistant(
                item.spokenPrompt,
                chatID: chatID,
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
        case (.question, _):
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
