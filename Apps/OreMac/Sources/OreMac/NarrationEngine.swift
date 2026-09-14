import Foundation
import Observation
import OreProtocol

/// Speaks what agents are doing, for tabs whose speaker toggle is on.
///
/// One engine app-wide: a single voice naturally serializes every chat's
/// narration, and one priority queue decides what plays next.
/// The rules live in `Narration.swift`; this class owns the audio, the
/// timers, and the per-chat buffers, and consumes the same normalized
/// `AgentEvent` stream the transcript renders — which is what makes narration
/// identical across harnesses.
@MainActor
@Observable
final class NarrationEngine {
    /// One key holding every narrated chat, not a key per chat: the engine
    /// must know the full set at launch to narrate background tabs whose
    /// panes have never been opened this session.
    private static let enabledChatsKey = "ore.narrationChats"
    static let masterSwitchKey = "ore.narration.enabled"
    static let voiceKindKey = "ore.narration.voiceKind"
    static let fleetSwitchKey = "ore.narration.fleet"

    private(set) var enabledChats: Set<ChatID>
    /// Which chat's words are coming out of the speakers, for the UI pulse.
    private(set) var speakingChatID: ChatID?
    /// The utterance currently being spoken, for the assistant HUD.
    private(set) var currentSpokenText: String?
    /// How much of it has actually been voiced, in characters. Reported by the
    /// voice — exactly by the system one's word boundaries, closely by the
    /// neural one's playback clock.
    private(set) var spokenCharacterCount = 0

    /// The part of the current utterance already spoken, cut back to a whole
    /// word. The HUD streams this: the pill shows what the assistant is saying
    /// as it says it, the same way it shows what it is hearing.
    var spokenPrefix: String {
        guard let currentSpokenText else { return "" }
        return Self.wholeWords(of: currentSpokenText, upTo: spokenCharacterCount)
    }

    /// `characters` counts UTF-16 units, since that is what
    /// `AVSpeechSynthesizer` reports its word boundaries in.
    nonisolated static func wholeWords(of text: String, upTo characters: Int) -> String {
        guard characters > 0 else { return "" }
        let utf16 = text.utf16.count
        guard characters < utf16 else { return text }
        guard let cut = String.Index(String.Index(utf16Offset: characters, in: text), within: text)
        else { return text }
        // Mid-word cuts happen with the neural voice's estimate; the system
        // voice lands on boundaries already. Either way, never show half a word
        // — and part-way into the first one, there is no whole word yet.
        guard cut < text.endIndex, !text[cut].isWhitespace else { return String(text[..<cut]) }
        guard let lastBreak = text[..<cut].lastIndex(where: \.isWhitespace) else { return "" }
        return String(text[..<lastBreak])
    }

    /// HUD word-progress only needs to notify when the visible prefix changes.
    /// Intra-word clock ticks from the neural voice otherwise rebuild the pill
    /// on every character.
    nonisolated static func spokenProgressWouldRevealNewWords(
        of text: String,
        from previousCount: Int,
        to nextCount: Int
    ) -> Bool {
        wholeWords(of: text, upTo: previousCount) != wholeWords(of: text, upTo: nextCount)
    }

    /// Both voices are held, not one: the neural voice may still be
    /// downloading, and every utterance until it is ready falls back to the
    /// system voice rather than being dropped.
    private let systemVoice = SystemNarrationVoice()
    let neuralVoice = NeuralNarrationVoice()
    private let summarizer = NarrationSummarizer()

    private var queue = NarrationQueue()
    private var currentUtterance: SpokenUtterance?
    private var lastUtteranceEndedAt = Date.distantPast
    private var coalescers: [ChatID: ToolActivityCoalescer] = [:]
    private var digests: [ChatID: DigestBuffer] = [:]
    private var lastInProgressTodo: [ChatID: String] = [:]
    private var lastToolFailureAt: [ChatID: Date] = [:]
    /// Rotates the phraser's frames for the utterances the coalescer doesn't
    /// own (todos, completions), so those don't repeat one sentence either.
    private var phraseVariant: [ChatID: Int] = [:]
    private var planReadiness = PlanReadinessGate()
    private var activeChatID: ChatID?
    private var micActive = false
    private var summaryTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?

    var isMasterEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.masterSwitchKey) as? Bool ?? true
    }

    /// Fleet awareness: chats with no speaker toggle still announce the
    /// moments that matter. On by default — it is the "assistant sitting
    /// above the fleet" half of narration.
    var isFleetEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.fleetSwitchKey) as? Bool ?? true
    }

    /// Whether the on-device summarizer can run on this machine, as a sentence
    /// for the settings pane. Exposed here so the summarizer stays private.
    var summarizerAvailability: String {
        summarizer.availabilityDescription
    }

    /// Which voice the user picked. The neural one only actually speaks once
    /// its weights are loaded; `voice` is what resolves that.
    var voiceKind: NarrationVoiceKind {
        UserDefaults.standard.string(forKey: Self.voiceKindKey)
            .flatMap(NarrationVoiceKind.init(rawValue:)) ?? .system
    }

    /// The voice that should speak the next utterance.
    ///
    /// The neural voice yields under load: when the CPU is already saturated
    /// or the machine is thermally throttling — agents mid-turn are exactly
    /// when narration speaks most — a 100M-parameter TTS pass would slow the
    /// work the user is waiting on and stutter besides. The system voice
    /// costs nothing and is always ready; the neural voice returns as soon
    /// as the pressure clears, checked per utterance.
    private var voice: NarrationVoice {
        switch voiceKind.resolved(neuralReady: neuralVoice.isReady) {
        case .neural:
            SystemLoadProbe.shared.isUnderPressure ? systemVoice : neuralVoice
        case .system:
            systemVoice
        }
    }

    /// Whether *anything* is currently audible. Not `voice.isSpeaking`: the
    /// setting can change, and the neural voice can finish downloading, while
    /// a line is still playing — after which the voice that is actually
    /// speaking is no longer the one that would be chosen now.
    private var isVoiceSpeaking: Bool {
        systemVoice.isSpeaking || neuralVoice.isSpeaking
    }

    /// The observable truth used by the voice HUD. `currentUtterance` is book-
    /// keeping and can survive a synthesizer that failed before delivering its
    /// end callback; actual playback or a queued line cannot.
    var hasAudibleOrQueuedSpeech: Bool {
        isVoiceSpeaking || queue.peek != nil
    }

    /// Stops whichever voice is mid-utterance, for the same reason.
    private func stopSpeaking(immediate: Bool) {
        systemVoice.stop(immediate: immediate)
        neuralVoice.stop(immediate: immediate)
    }

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.enabledChatsKey) ?? []
        enabledChats = Set(saved.map(ChatID.init(rawValue:)))
        systemVoice.onEnd = { [weak self] in self?.utteranceEnded() }
        neuralVoice.onEnd = { [weak self] in self?.utteranceEnded() }
        systemVoice.onProgress = { [weak self] in self?.noteSpokenProgress($1, of: $0) }
        neuralVoice.onProgress = { [weak self] in self?.noteSpokenProgress($1, of: $0) }
        // Weights already fetched on a previous run load in the background, so
        // the first narrated turn doesn't fall back to the system voice.
        if voiceKind == .neural, neuralVoice.wasInstalledPreviously {
            neuralVoice.install()
        }
        // Tool batches age out on a coarse cadence; the same tick retries a
        // pump that was gap-blocked.
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    // MARK: - Toggle & lifecycle

    func isEnabled(_ chatID: ChatID) -> Bool {
        enabledChats.contains(chatID)
    }

    func toggle(_ chatID: ChatID) {
        if enabledChats.contains(chatID) {
            enabledChats.remove(chatID)
            dropState(for: chatID)
        } else {
            enabledChats.insert(chatID)
            // Load the on-device model before there is anything to say, so
            // the first digest doesn't pay the cold start.
            summarizer.prewarm()
        }
        UserDefaults.standard.set(
            enabledChats.map(\.rawValue).sorted(),
            forKey: Self.enabledChatsKey
        )
    }

    /// The chat no longer exists; neither should anything keyed by it.
    func forget(_ chatID: ChatID) {
        guard enabledChats.contains(chatID) else { return }
        toggle(chatID)
    }

    func activeChatChanged(_ chatID: ChatID?) {
        guard activeChatID != chatID else { return }
        // No back-fill of what was missed: narration describes now, and the
        // chat the user left keeps only its needs-you interjections.
        if let previous = activeChatID {
            queue.dropProgress(for: previous)
            coalescers[previous]?.reset()
        }
        activeChatID = chatID
        pump()
    }

    /// Dictation owns the audio: stop speaking for the mic's whole lifetime —
    /// both so the user isn't talked over and so TTS can't leak into the
    /// transcription. Ambient narration is dropped (stale by the time the mic
    /// closes); needs-you utterances are re-spoken from the start.
    func setMicActive(_ active: Bool) {
        guard micActive != active else { return }
        micActive = active
        if active {
            queue.dropAllProgress()
            if let current = currentUtterance, current.priority > .progress {
                _ = queue.enqueue(current)
            }
            stopSpeaking(immediate: false)
        } else {
            // A beat after the mic closes, so speech doesn't collide with the
            // settle-hold send.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.pump()
            }
        }
    }

    func stopAll() {
        queue.removeAll()
        stopSpeaking(immediate: true)
        flushQuietWaitersIfIdle()
    }

    /// Whether some dictation currently owns the audio. The assistant's
    /// hold-to-talk reads this to know a composer mic is live before taking
    /// the microphone over.
    var isMicActive: Bool { micActive }

    // MARK: - Assistant

    /// Speaks for the assistant, bypassing the per-chat speaker toggles and
    /// the master narration switch: the user just *spoke* to it, and a spoken
    /// question deserves a spoken answer regardless of how the ambient
    /// narration is configured. Answers ride interrupt priority; mid-turn
    /// milestones ride progress, so they thin out under load and the reply
    /// always wins.
    func speakAssistant(
        _ text: String,
        chatID: ChatID,
        priority: NarrationPriority = .interrupt,
        limit: Int = NarrationPolicy.utteranceLimit,
        kind: SpokenUtterance.Kind? = nil
    ) {
        // The limit has to be passed all the way down: this sanitizes a second
        // time, so a line already cleared at the assistant's longer limit would
        // otherwise be re-clipped back to 280 here.
        guard let spoken = NarrationPhraser.spokenNarration(text, limit: limit) else { return }
        enqueue(SpokenUtterance(
            chatID: chatID,
            priority: priority,
            kind: kind ?? (priority == .progress ? .toolActivity : .turnCompleted),
            text: spoken
        ))
    }

    /// A permission was answered while its prompt was queued or speaking.
    /// Invalidate only that request: unrelated assistant speech must continue.
    /// The synthesizer stops at its nearest safe boundary and its normal end
    /// callback pumps whatever remains in the queue.
    func cancelPermissionPrompt(_ id: PermissionRequestID) {
        queue.invalidatePermission(id)
        guard case .permission(id) = currentUtterance?.kind else { return }
        stopSpeaking(immediate: false)
    }

    /// Runs `handler` once nothing is speaking and nothing is waiting to be —
    /// how the assistant knows its spoken question has finished before it
    /// opens the microphone for the answer (opening it earlier would cut the
    /// question off; see `setMicActive`).
    func notifyWhenQuiet(_ handler: @escaping @MainActor () -> Void) {
        if !hasAudibleOrQueuedSpeech {
            handler()
            return
        }
        quietWaiters.append(handler)
    }

    private var quietWaiters: [@MainActor () -> Void] = []

    private func flushQuietWaitersIfIdle() {
        guard !quietWaiters.isEmpty, !hasAudibleOrQueuedSpeech else { return }
        let waiters = quietWaiters
        quietWaiters = []
        for waiter in waiters { waiter() }
    }

    // MARK: - Event intake

    func observe(
        event: AgentEvent,
        chatID: ChatID,
        origin: NarrationOrigin
    ) {
        guard isMasterEnabled else { return }
        guard enabledChats.contains(chatID) else {
            observeFleet(event: event, chatID: chatID, origin: origin)
            return
        }
        // Background tabs only interject for things that need the user;
        // ambient progress would interleave into word salad. When they do
        // interject they name where they are, since the user isn't looking at
        // it — and "where" is the tab, not just the workspace.
        let background = origin.spokenLabel

        switch event {
        case .turnStarted:
            // A new user message: everything queued for this chat — including
            // a now-moot question — describes a turn that no longer exists.
            queue.dropAll(for: chatID)
            coalescers[chatID]?.reset()
            digests[chatID, default: DigestBuffer()].clear()
            planReadiness.reset(scope: chatID.rawValue)
            if speakingChatID == chatID {
                stopSpeaking(immediate: false)
            }

        case .toolCall(let call):
            guard background == nil, call.parentToolCallID == nil,
                  let activity = SpokenToolClass.classify(
                    name: call.name,
                    displayName: call.displayName,
                    input: call.input
                  )
            else { return }
            var coalescer = coalescers[chatID] ?? ToolActivityCoalescer()
            let phrase = coalescer.absorb(activity, at: Date())
            coalescers[chatID] = coalescer
            if let phrase { enqueueProgress(phrase, kind: .toolActivity, chatID: chatID) }

        case .toolResult(let result):
            guard background == nil, result.isError else { return }
            let now = Date()
            if let last = lastToolFailureAt[chatID],
               now.timeIntervalSince(last) < NarrationPolicy.toolFailureCooldown {
                return
            }
            lastToolFailureAt[chatID] = now
            let variant = phraseVariant[chatID] ?? 0
            advanceVariant(for: chatID)
            enqueue(SpokenUtterance(
                chatID: chatID,
                priority: .milestone,
                kind: .toolFailure,
                text: NarrationPhraser.toolFailure(variant: variant)
            ))

        case .thinkingDelta(let delta), .textDelta(let delta):
            guard background == nil, delta.parentToolCallID == nil else { return }
            digests[chatID, default: DigestBuffer()].append(delta.text)
            maybeSummarize(chatID: chatID)

        case .blockCompleted(let block):
            // Template-only fallback: without the on-device model, completed
            // assistant prose is the one text already addressed to the user.
            guard background == nil, !summarizer.isAvailable,
                  block.kind == .text, block.parentToolCallID == nil,
                  let sentence = NarrationPhraser.directSummary(
                    NarrationPhraser.firstSentences(block.text, maxCharacters: 180)
                  )
            else { return }
            enqueueProgress(sentence, kind: .digest, chatID: chatID)

        case .planUpdated(let update):
            switch update.content {
            case .todos(let items):
                guard background == nil else { return }
                let (phrase, current) = NarrationPhraser.todoPhrase(
                    items: items,
                    previousInProgress: lastInProgressTodo[chatID],
                    variant: phraseVariant[chatID] ?? 0
                )
                lastInProgressTodo[chatID] = current
                if let phrase {
                    advanceVariant(for: chatID)
                    enqueueProgress(phrase, kind: .todo, chatID: chatID)
                }
            case .proposal(let markdown, _):
                speakPlanProposal(update, markdown: markdown, chatID: chatID, background: background)
            }

        case .permissionRequest(let request):
            enqueue(SpokenUtterance(
                chatID: chatID,
                priority: .interrupt,
                kind: .permission(request.id),
                text: prefixed(NarrationPhraser.permission(request), background)
            ))

        case .permissionResolved(let resolution):
            // The user clicked before or during the prompt; saying the rest
            // would narrate a decision that has already happened.
            cancelPermissionPrompt(resolution.id)

        case .question(let question):
            enqueue(SpokenUtterance(
                chatID: chatID,
                priority: .interrupt,
                kind: .question,
                text: prefixed(NarrationPhraser.question(question), background)
            ))

        case .turnCompleted(let result):
            coalescers[chatID]?.reset()
            digests[chatID, default: DigestBuffer()].clear()
            queue.dropProgress(for: chatID)
            speakCompletion(result, chatID: chatID, background: background)

        case .sessionError(let error):
            enqueue(SpokenUtterance(
                chatID: chatID,
                priority: .interrupt,
                kind: .sessionError,
                text: prefixed(NarrationPhraser.sessionError(error), background)
            ))

        case .sessionEnded(let ended):
            guard ended.wasUnexpected else { return }
            enqueue(SpokenUtterance(
                chatID: chatID,
                priority: .interrupt,
                kind: .sessionError,
                text: prefixed("The session just ended unexpectedly.", background)
            ))

        case .contextCompacted:
            guard background == nil else { return }
            let variant = phraseVariant[chatID] ?? 0
            advanceVariant(for: chatID)
            enqueue(SpokenUtterance(
                chatID: chatID,
                priority: .milestone,
                kind: .contextCompacted,
                text: NarrationPhraser.contextCompacted(variant: variant)
            ))

        case .rateLimit(let report):
            guard background == nil, let text = NarrationPhraser.rateLimit(report) else { return }
            enqueue(SpokenUtterance(
                chatID: chatID,
                priority: .milestone,
                kind: .rateLimit,
                text: text
            ))

        case .sessionStarted, .statusChanged, .usage, .backgroundTasksChanged:
            break
        }
    }

    /// The fleet half of narration — Jarvis's ambient awareness. Chats whose
    /// speaker toggle is off still announce the moments that matter — turn
    /// finished, turn failed, needs you — always named by place, and only from
    /// the background: what's on screen narrates itself. Ambient progress
    /// stays per-tab; fleet-wide progress is word salad.
    private func observeFleet(event: AgentEvent, chatID: ChatID, origin: NarrationOrigin) {
        guard isFleetEnabled, let background = origin.spokenLabel else { return }
        switch event {
        case .turnStarted:
            // A new message obsoletes anything still queued about this chat.
            queue.dropAll(for: chatID)
            planReadiness.reset(scope: chatID.rawValue)

        case .turnCompleted(let result):
            speakCompletion(result, chatID: chatID, background: background)

        case .permissionRequest(let request):
            enqueue(SpokenUtterance(
                chatID: chatID,
                priority: .interrupt,
                kind: .permission(request.id),
                text: prefixed(NarrationPhraser.permission(request), background)
            ))

        case .question(let question):
            enqueue(SpokenUtterance(
                chatID: chatID,
                priority: .interrupt,
                kind: .question,
                text: prefixed(NarrationPhraser.question(question), background)
            ))

        case .planUpdated(let update):
            if case .proposal(let markdown, _) = update.content {
                speakPlanProposal(update, markdown: markdown, chatID: chatID, background: background)
            }

        case .sessionError(let error):
            enqueue(SpokenUtterance(
                chatID: chatID,
                priority: .interrupt,
                kind: .sessionError,
                text: prefixed(NarrationPhraser.sessionError(error), background)
            ))

        case .permissionResolved(let resolution):
            cancelPermissionPrompt(resolution.id)

        default:
            break
        }
    }

    // MARK: - Completion

    private func speakCompletion(
        _ result: TurnResult,
        chatID: ChatID,
        background: String?
    ) {
        switch result.outcome {
        case .completed:
            if let narration = NarrationPhraser.spokenNarration(result.narration) {
                // The agent wrote this line for the ear itself (see
                // `NarrationTag`) — it beats anything derived locally, and
                // it's the one place a background completion carries real
                // content instead of a bare "It's finished."
                enqueue(SpokenUtterance(
                    chatID: chatID,
                    priority: .milestone,
                    kind: .turnCompleted,
                    text: prefixed(narration, background)
                ))
            } else if let background {
                enqueue(SpokenUtterance(
                    chatID: chatID,
                    priority: .milestone,
                    kind: .turnCompleted,
                    text: NarrationPhraser.prefixed("It's finished.", place: background)
                ))
            } else if let direct = NarrationPhraser.directSummary(result.summary) {
                enqueue(SpokenUtterance(
                    chatID: chatID, priority: .milestone, kind: .turnCompleted, text: direct
                ))
            } else if summarizer.isAvailable, let summary = result.summary, !summary.isEmpty {
                compressCompletion(summary, chatID: chatID, duration: result.duration)
            } else {
                enqueue(SpokenUtterance(
                    chatID: chatID,
                    priority: .milestone,
                    kind: .turnCompleted,
                    text: fallbackCompletion(duration: result.duration, chatID: chatID)
                ))
            }
        case .interrupted:
            // The user pressed stop; in a background tab they know already.
            guard background == nil else { return }
            let variant = phraseVariant[chatID] ?? 0
            advanceVariant(for: chatID)
            enqueue(SpokenUtterance(
                chatID: chatID, priority: .milestone, kind: .stopped,
                text: NarrationPhraser.stopped(variant: variant)
            ))
        case .failed:
            enqueue(SpokenUtterance(
                chatID: chatID,
                priority: .interrupt,
                kind: .turnFailed,
                text: prefixed(NarrationPhraser.turnFailed(result.errorMessage), background)
            ))
        case .awaitingInput:
            // The plan proposal or question that caused this already spoke as
            // its own interrupt.
            break
        }
    }

    /// Speaks a plan proposal with its crux when the model can produce one.
    ///
    /// The canned line only names the moment; what makes the interrupt worth
    /// hearing is what the plan would *do*. When the model is available the
    /// interrupt trades up to ≤2.5s of delay (the summarizer's race deadline)
    /// for that sentence — acceptable for a "come look at this" line, since
    /// the plan card is already on screen either way. Timeout or absence
    /// falls back to the canned phrase.
    ///
    /// Drafts and duplicate ready events for the same turn are silent: Cursor
    /// CreatePlan `started` then `completed`, and Claude's republish with a
    /// permission id, must not re-say "the plan is ready".
    private func speakPlanProposal(
        _ update: PlanUpdate,
        markdown: String,
        chatID: ChatID,
        background: String?
    ) {
        guard planReadiness.shouldAnnounce(
            scope: chatID.rawValue,
            turnID: update.turnID,
            markdown: markdown,
            isReady: update.isReady
        ) else { return }
        let variant = phraseVariant[chatID] ?? 0
        advanceVariant(for: chatID)
        guard summarizer.isAvailable, !markdown.isEmpty else {
            enqueue(SpokenUtterance(
                chatID: chatID,
                priority: .interrupt,
                kind: .planProposal,
                text: prefixed(NarrationPhraser.planProposal(variant: variant), background)
            ))
            return
        }
        let generation = digests[chatID]?.generation ?? 0
        Task { @MainActor [weak self] in
            guard let self else { return }
            let crux = await self.summarizer.planCrux(markdown)
            // A newer turn started while the model ran: its plan is history.
            guard self.digests[chatID]?.generation ?? 0 == generation else { return }
            let line = crux.map { NarrationPhraser.planProposal(crux: $0, variant: variant) }
                ?? NarrationPhraser.planProposal(variant: variant)
            self.enqueue(SpokenUtterance(
                chatID: chatID,
                priority: .interrupt,
                kind: .planProposal,
                text: self.prefixed(line, background)
            ))
        }
    }

    /// A long final report goes through the model to become two spoken
    /// sentences; the template is the timeout's fallback.
    private func compressCompletion(_ summary: String, chatID: ChatID, duration: TimeInterval?) {
        let generation = digests[chatID]?.generation ?? 0
        Task { @MainActor [weak self] in
            guard let self else { return }
            let sentence = await self.summarizer.compress(finalReport: summary)
            // A newer turn started while the model ran: its report is history.
            guard self.digests[chatID]?.generation ?? 0 == generation else { return }
            self.enqueue(SpokenUtterance(
                chatID: chatID,
                priority: .milestone,
                kind: .turnCompleted,
                text: sentence ?? self.fallbackCompletion(duration: duration, chatID: chatID)
            ))
        }
    }

    private func fallbackCompletion(duration: TimeInterval?, chatID: ChatID) -> String {
        defer { advanceVariant(for: chatID) }
        return NarrationPhraser.completionFallback(
            duration: duration,
            variant: phraseVariant[chatID] ?? 0
        )
    }

    private func advanceVariant(for chatID: ChatID) {
        phraseVariant[chatID, default: 0] += 1
    }

    // MARK: - Digest summarization

    private func maybeSummarize(chatID: ChatID) {
        guard summarizer.isAvailable, summaryTask == nil,
              var buffer = digests[chatID], buffer.isTriggerReady
        else { return }
        let (prompt, generation) = buffer.snapshot()
        digests[chatID] = buffer
        summaryTask = Task { @MainActor [weak self] in
            defer { self?.summaryTask = nil }
            guard let self else { return }
            guard let sentence = await self.summarizer.digest(prompt) else { return }
            // Only speak it if nothing made it stale while the model ran.
            guard self.digests[chatID]?.generation == generation,
                  self.activeChatID == chatID
            else { return }
            self.enqueueProgress(sentence, kind: .digest, chatID: chatID)
        }
    }

    // MARK: - Queue & speech

    private func prefixed(_ text: String, _ place: String?) -> String {
        guard let place else { return text }
        return NarrationPhraser.prefixed(text, place: place)
    }

    private func enqueueProgress(_ text: String, kind: SpokenUtterance.Kind, chatID: ChatID) {
        digests[chatID, default: DigestBuffer()].noteActivity(text)
        enqueue(SpokenUtterance(chatID: chatID, priority: .progress, kind: kind, text: text))
    }

    private func enqueue(_ utterance: SpokenUtterance) {
        switch queue.enqueue(utterance) {
        case .interruptCurrent:
            if let current = currentUtterance, current.priority < .interrupt,
               isVoiceSpeaking {
                // The stop reports an ending, which pumps the queue — and the
                // queue now leads with the interrupt.
                stopSpeaking(immediate: false)
            } else {
                pump()
            }
        case .queued:
            pump()
        case .dropped:
            break
        }
    }

    private func tick() {
        if let activeChatID, enabledChats.contains(activeChatID),
           var coalescer = coalescers[activeChatID] {
            if let phrase = coalescer.flushIfDue(at: Date()) {
                coalescers[activeChatID] = coalescer
                enqueueProgress(phrase, kind: .toolActivity, chatID: activeChatID)
            } else {
                coalescers[activeChatID] = coalescer
            }
        }
        pump()
        // The ticker is the engine's second chance at anything a missed event
        // stranded, and a lost ending strands more than a pump. `onEnd` is the
        // only thing that ever finishes a line: without it the book-keeping
        // stays mid-utterance, `notifyWhenQuiet` is never released, and the
        // voice pill sits on "Speaking…" with the agent long since silent.
        if Self.endingWasLost(
            isAudibleOrQueued: hasAudibleOrQueuedSpeech,
            isMidUtterance: currentUtterance != nil
        ) {
            utteranceEnded()
        } else {
            flushQuietWaitersIfIdle()
        }
    }

    /// Whether the engine is still holding a line that cannot be playing.
    ///
    /// Both voices report ending through a callback that can go missing — the
    /// system synthesizer occasionally declines an utterance without
    /// delivering either delegate ending, and the neural voice drops its
    /// ending when a preempted stream loses the generation check. Nothing is
    /// audible and nothing is queued, yet a line is still marked in flight:
    /// that combination only happens when an ending was lost.
    static func endingWasLost(isAudibleOrQueued: Bool, isMidUtterance: Bool) -> Bool {
        isMidUtterance && !isAudibleOrQueued
    }

    private func pump() {
        guard !micActive, !isVoiceSpeaking, let next = queue.peek else { return }
        let gap: TimeInterval = switch next.priority {
        case .interrupt: 0
        case .milestone: NarrationPolicy.milestoneGap
        case .progress: NarrationPolicy.progressGap
        }
        // Not yet: the ticker retries once the quiet time has passed. The
        // wait is synthesis time for free — a voice that renders ahead of
        // playback can have the waveform finished before the gap opens.
        guard Date().timeIntervalSince(lastUtteranceEndedAt) >= gap else {
            voice.prepare(next.text, priority: next.priority)
            return
        }
        guard let utterance = queue.next() else { return }
        speak(utterance)
    }

    private func speak(_ utterance: SpokenUtterance) {
        currentUtterance = utterance
        speakingChatID = utterance.chatID
        currentSpokenText = utterance.text
        spokenCharacterCount = 0
        // What was just said grounds the next digest so it doesn't repeat.
        digests[utterance.chatID]?.noteSpoken(utterance.text)
        voice.speak(utterance.text, priority: utterance.priority)
    }

    /// Both voices report into this, and the stale one can still be draining a
    /// preempted line — so progress only ever moves forward within an
    /// utterance, and a late callback from the previous one is ignored.
    private func noteSpokenProgress(_ characters: Int, of text: String) {
        guard let currentSpokenText, text == currentSpokenText,
              characters > spokenCharacterCount
        else { return }
        let next = min(characters, currentSpokenText.utf16.count)
        guard Self.spokenProgressWouldRevealNewWords(
            of: currentSpokenText, from: spokenCharacterCount, to: next
        ) else { return }
        spokenCharacterCount = next
    }

    private func utteranceEnded() {
        currentUtterance = nil
        speakingChatID = nil
        currentSpokenText = nil
        spokenCharacterCount = 0
        lastUtteranceEndedAt = Date()
        pump()
        flushQuietWaitersIfIdle()
    }

    private func dropState(for chatID: ChatID) {
        queue.dropAll(for: chatID)
        coalescers.removeValue(forKey: chatID)
        digests.removeValue(forKey: chatID)
        lastInProgressTodo.removeValue(forKey: chatID)
        lastToolFailureAt.removeValue(forKey: chatID)
        phraseVariant.removeValue(forKey: chatID)
        if speakingChatID == chatID {
            stopSpeaking(immediate: true)
        }
    }
}
