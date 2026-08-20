import AVFoundation
import FluidAudio
import Foundation
import Observation
import SwiftUI

/// Which synthesizer turns narration text into sound.
enum NarrationVoiceKind: String, CaseIterable, Identifiable, Sendable {
    /// `AVSpeechSynthesizer` and whatever Apple voices are installed. Always
    /// available, needs no download, and is the fallback whenever the neural
    /// voice isn't ready.
    case system
    /// Kyutai's Pocket TTS, on-device via CoreML. Downloaded on demand.
    case neural

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System voice"
        case .neural: "Neural voice"
        }
    }

    /// What actually speaks. Choosing the neural voice is a preference, not a
    /// guarantee: until its weights are downloaded and loaded the system voice
    /// stands in, so narration is never silently dropped while a half-gigabyte
    /// download finishes.
    func resolved(neuralReady: Bool) -> NarrationVoiceKind {
        self == .neural && neuralReady ? .neural : .system
    }
}

/// What `NarrationEngine` needs from a synthesizer, and no more.
///
/// The engine owns the queue, the priorities and the quiet gaps; a voice only
/// has to speak one string at a time and say when it stopped. That split is
/// what lets the neural voice slot in without the scheduling rules — which are
/// the part that took the tuning — knowing anything about it.
@MainActor
protocol NarrationVoice: AnyObject {
    var isSpeaking: Bool { get }
    /// Fires when an utterance stops for *any* reason: finished normally, cut
    /// short by a higher-priority interjection, or dropped when the mic opened.
    /// The engine pumps its queue on all three, so it doesn't distinguish them.
    var onEnd: (@MainActor () -> Void)? { get set }
    /// How far into an utterance the voice has actually got, in characters, and
    /// which utterance the position belongs to. The assistant HUD reveals the
    /// line at this pace, so the pill reads like the assistant speaking rather
    /// than a finished sentence sitting there — which is the same live quality
    /// the listening waveform has.
    ///
    /// The text is passed back because these callbacks are deferred: a boundary
    /// from a line that was just preempted can land after the next one started,
    /// and without it that stale position would flash the wrong words.
    var onProgress: (@MainActor (String, Int) -> Void)? { get set }
    /// `priority` shapes delivery, not just what plays first — ambient
    /// progress sits back, interjections lean in. How much of that a given
    /// voice can express depends on the synthesizer.
    func speak(_ text: String, priority: NarrationPriority)
    /// `immediate` cuts instantly; otherwise the voice stops at the nearest
    /// natural boundary it can honour, so preemption doesn't clip a word in
    /// half.
    func stop(immediate: Bool)
    /// A hint that `text` will likely be the next utterance. The engine calls
    /// this while an utterance waits out its quiet gap, so a voice that
    /// renders ahead of playback can spend that idle time synthesizing and
    /// start the line with the waveform already in hand. Purely advisory —
    /// the system voice, which renders in real time anyway, ignores it.
    func prepare(_ text: String, priority: NarrationPriority)
}

extension NarrationVoice {
    func prepare(_ text: String, priority: NarrationPriority) {}
}

// MARK: - System voice

/// Apple's built-in synthesis: intelligible, unmistakably synthetic, free.
@MainActor
final class SystemNarrationVoice: NarrationVoice {
    private let synthesizer = AVSpeechSynthesizer()
    private var delegate: SpeechDelegate?
    private var chosenVoice: AVSpeechSynthesisVoice?

    var onEnd: (@MainActor () -> Void)?
    var onProgress: (@MainActor (String, Int) -> Void)?
    var isSpeaking: Bool { synthesizer.isSpeaking }

    init() {
        let delegate = SpeechDelegate(
            onEnd: { [weak self] in self?.onEnd?() },
            onProgress: { [weak self] text, characters in
                self?.onProgress?(text, characters)
            }
        )
        self.delegate = delegate
        synthesizer.delegate = delegate
    }

    func speak(_ text: String, priority: NarrationPriority) {
        let speech = AVSpeechUtterance(string: text)
        if let voice = bestVoice() { speech.voice = voice }
        applyDelivery(to: speech, priority: priority)
        synthesizer.speak(speech)
    }

    /// Half of sounding robotic is delivery, not wording: without this every
    /// line lands at identical speed and pitch whether it's "it's reading
    /// ChatPane" or "the turn failed". Ambient progress is quicker and quieter
    /// so it sits behind whatever the user is doing; interrupts slow down and
    /// take a beat first, which is what makes them register as different
    /// rather than just louder. Deliberately subtle — these are a few percent
    /// off default, not a character voice.
    private func applyDelivery(
        to speech: AVSpeechUtterance,
        priority: NarrationPriority
    ) {
        switch priority {
        case .progress:
            speech.rate = AVSpeechUtteranceDefaultSpeechRate * 1.06
            speech.pitchMultiplier = 0.98
            speech.volume = 0.85
        case .milestone:
            speech.rate = AVSpeechUtteranceDefaultSpeechRate
            speech.pitchMultiplier = 1.0
            speech.volume = 1.0
            speech.preUtteranceDelay = 0.1
        case .interrupt:
            speech.rate = AVSpeechUtteranceDefaultSpeechRate * 0.96
            speech.pitchMultiplier = 1.02
            speech.volume = 1.0
            speech.preUtteranceDelay = 0.2
        }
    }

    func stop(immediate: Bool) {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: immediate ? .immediate : .word)
    }

    /// The best-sounding voice installed for the user's language, resolved
    /// once: premium beats enhanced beats the compact default.
    private func bestVoice() -> AVSpeechSynthesisVoice? {
        if let chosenVoice { return chosenVoice }
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
        let voice = candidates.first { $0.quality == .premium }
            ?? candidates.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: language)
        chosenVoice = voice
        return voice
    }
}

/// `AVSpeechSynthesizer` reports through a delegate; this adapter turns the
/// two endings — finished and cancelled — into one MainActor callback.
/// Cancelled matters as much as finished: preemption and mic ducking both
/// land there. It also forwards the word boundaries, which is the exact spoken
/// position the HUD reveals its transcript at.
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let onEnd: @Sendable () -> Void
    private let onProgress: @Sendable (String, Int) -> Void

    init(
        onEnd: @escaping @MainActor () -> Void,
        onProgress: @escaping @MainActor (String, Int) -> Void
    ) {
        self.onEnd = { Task { @MainActor in onEnd() } }
        self.onProgress = { text, characters in
            Task { @MainActor in onProgress(text, characters) }
        }
    }

    /// Fires just before each word is voiced, so the reported position is
    /// "what you are hearing now" rather than what has already gone by.
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        // `speechString` is immutable and a `String`, which is what keeps this
        // hop off the main actor free of a non-`Sendable` capture.
        onProgress(utterance.speechString, characterRange.location + characterRange.length)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        onEnd()
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        onEnd()
    }
}

// MARK: - Neural voice

/// Kyutai's Pocket TTS (100M parameters, CC-BY-4.0) running on this Mac
/// through FluidAudio's CoreML port.
///
/// The model is autoregressive and streams: frames of 80ms arrive as they are
/// generated, so playback starts long before the sentence is finished and a
/// preempted utterance dies within a frame rather than at the end of a fully
/// rendered buffer. That is why it's Pocket TTS and not a parallel model like
/// Kokoro — narration is interrupted constantly, and the streaming shape is
/// what preserves `NarrationEngine`'s preemption semantics.
///
/// Weights are not shipped in the app: `install()` fetches them on first use.
@MainActor
@Observable
final class NeuralNarrationVoice: NarrationVoice {
    enum Readiness: Equatable {
        case notInstalled
        case installing
        case ready
        case failed(String)
    }

    /// Set once the model has been fetched, so later launches can load it
    /// without asking again or hitting the network.
    private static let installedKey = "ore.narration.neuralInstalled"

    private(set) var readiness: Readiness

    /// `.gpu` is FluidAudio's default and, measured on an M1, the right one:
    /// GPU ran 1.6-1.9x real time idle and 1.08x with all cores busy, while
    /// `.ane` managed only 1.3-1.4x and 0.83x — below real time, i.e. audible
    /// stutter — and took 13-32s to load rather than 2-11s. `.aneState` fails
    /// outright on this model version ("`functionName` must be nil unless the
    /// model type is ML Program"). The Neural Engine looks like the obvious
    /// home for this and isn't; don't switch without re-measuring.
    @ObservationIgnored private let manager = PocketTtsManager(placement: .gpu)
    /// Lines already spoken, so a repeat costs a buffer copy instead of a
    /// second pass through the model. See `NarrationPhraseCache`.
    @ObservationIgnored private let phraseCache = NarrationPhraseCache()
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(PocketTtsConstants.audioSampleRate),
        channels: 1,
        interleaved: false
    )!

    @ObservationIgnored private var speakTask: Task<Void, Never>?
    @ObservationIgnored private var installTask: Task<Void, Never>?
    /// Ahead-of-need synthesis for the next queued utterance (see `prepare`).
    /// Keyed by exact text, so a prepared waveform survives everything except
    /// the line itself being replaced.
    @ObservationIgnored private var prepareTask: Task<[Float]?, Never>?
    @ObservationIgnored private var preparedText: String?
    @ObservationIgnored private var preparedSamples: [Float]?
    /// Underruns during the current utterance, and the count carried from the
    /// last one — the cushion for the next line grows while the machine is
    /// demonstrably too busy for the default, and resets after a clean run.
    @ObservationIgnored private var underrunsThisUtterance = 0
    @ObservationIgnored private var recentUnderruns = 0
    /// Bumped on every stop and every new utterance, so frames and completion
    /// callbacks belonging to an abandoned utterance can be recognised and
    /// ignored. Without it a buffer finishing after a preemption would report
    /// the *new* utterance as ended.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var scheduledBuffers = 0
    @ObservationIgnored private var streamEnded = false
    /// Frames generated but deliberately not yet handed to the player, while
    /// the pre-roll cushion fills. See `preRollFrames`.
    @ObservationIgnored private var pendingFrames: [[Float]] = []
    @ObservationIgnored private var playbackStarted = false
    @ObservationIgnored private var preRollTarget = 0
    /// Spoken-position tracking for `onProgress`. Pocket TTS reports no word
    /// boundaries, so position is inferred from how much audio has actually
    /// left the speakers against how much there is in total.
    @ObservationIgnored private var progressText = ""
    @ObservationIgnored private var playedSamples = 0
    @ObservationIgnored private var scheduledSamples = 0

    @ObservationIgnored var onEnd: (@MainActor () -> Void)?
    @ObservationIgnored var onProgress: (@MainActor (String, Int) -> Void)?
    private(set) var isSpeaking = false

    var isReady: Bool { readiness == .ready }

    /// How much audio to bank before letting the speakers start.
    ///
    /// Measured on an M1: generation runs at ~1.8x real time idle, but only
    /// ~1.1x with the cores busy — which is the normal state of this app,
    /// since it exists to run coding agents. At 1.1x a frame arrives barely
    /// ahead of the one being played, so any hiccup lands as a gap in the
    /// middle of a sentence. Starting late by this much converts the deficit
    /// into latency, which nobody notices, instead of a stutter, which
    /// everybody does.
    ///
    /// The cushion an utterance needs is `duration * (1 - rate)`, so it scales
    /// with how long the line is and how far behind generation falls. Ambient
    /// progress lines are the longest and the least urgent, so they get the
    /// most; interjections are short and want to land now, so they get least.
    nonisolated static func preRollFrames(for priority: NarrationPriority) -> Int {
        switch priority {
        case .progress: 10  // 800ms
        case .milestone: 8  // 640ms
        case .interrupt: 4  // 320ms
        }
    }

    /// Which priorities render the whole waveform before playback rather than
    /// streaming against the clock.
    ///
    /// Progress lines are the longest, the least urgent, and gap-gated by
    /// seconds of enforced quiet anyway — extra latency there is free, and a
    /// fully rendered line *cannot* stutter, no matter what the agent's build
    /// is doing to the cores. Milestones and interrupts want to land now, so
    /// they keep streaming behind their cushions.
    nonisolated static func prefersFullSynthesis(_ priority: NarrationPriority) -> Bool {
        priority == .progress
    }

    /// The cushion to re-bank after an underrun: enough to absorb another
    /// hiccup, small enough that the pause reads as a breath, not a dropout.
    nonisolated static let underrunReBankFrames = 4  // 320ms

    /// Rough delivery pace, used to guess an utterance's length while the model
    /// is still generating it. It only has to be close: the moment generation
    /// finishes the real sample count is known and the estimate snaps to it.
    nonisolated static let charactersPerSecond = 15.0

    init() {
        // Even a previously-installed model starts here: the weights are on
        // disk but not in memory, and `install()` is what loads them.
        readiness = .notInstalled
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// True when the weights are already on disk from a previous run, so the
    /// UI can load quietly instead of showing a download.
    var wasInstalledPreviously: Bool {
        UserDefaults.standard.bool(forKey: Self.installedKey)
    }

    /// Downloads the model if needed and loads it. Safe to call repeatedly;
    /// concurrent calls share the one in-flight attempt.
    func install() {
        guard readiness != .ready, installTask == nil else { return }
        readiness = .installing
        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.manager.initialize()
                self.readiness = .ready
                UserDefaults.standard.set(true, forKey: Self.installedKey)
            } catch {
                self.readiness = .failed(error.localizedDescription)
            }
            self.installTask = nil
        }
    }

    func speak(_ text: String, priority: NarrationPriority) {
        guard readiness == .ready else {
            // Nothing to say and nothing will say it — report the ending so
            // the engine's queue doesn't stall waiting on a voice that can't
            // speak.
            reportEnd()
            return
        }
        cancelCurrent()
        generation += 1
        let generation = generation
        isSpeaking = true
        streamEnded = false
        scheduledBuffers = 0
        pendingFrames = []
        playbackStarted = false
        underrunsThisUtterance = 0
        progressText = text
        playedSamples = 0
        scheduledSamples = 0
        onProgress?(text, 0)
        // A line that underran is evidence the default cushion is too small
        // for the machine's current load; the next one banks more.
        preRollTarget = Self.preRollFrames(for: priority) + min(6, 2 * recentUnderruns)
        // Pocket TTS exposes no rate or pitch control, so of the system
        // voice's three delivery levers only loudness and the lead-in pause
        // survive. The model's own prosody covers more of the difference than
        // the tuning did.
        player.volume = priority == .progress ? 0.85 : 1
        let lead: Duration = switch priority {
        case .progress: .zero
        case .milestone: .milliseconds(100)
        case .interrupt: .milliseconds(200)
        }

        speakTask = Task { [weak self] in
            guard let self else { return }
            do {
                if lead > .zero { try await Task.sleep(for: lead) }
                try self.startEngineIfNeeded()
                if let remembered = await self.rememberedAudio(for: text) {
                    self.playRemembered(remembered, generation: generation)
                } else if let prepared = await self.consumePrepared(for: text) {
                    // `prepare` already rendered this exact line during the
                    // queue's quiet gap: zero latency and zero stutter.
                    self.playRemembered(prepared, generation: generation)
                } else if Self.prefersFullSynthesis(priority) {
                    try await self.synthesizeWhole(text, generation: generation)
                } else {
                    try await self.synthesize(text, generation: generation)
                }
            } catch {
                // A synthesis failure ends the utterance like any other
                // ending; the engine moves on rather than going silent.
            }
            self.noteStreamEnded(generation: generation)
        }
    }

    // MARK: Ahead-of-need synthesis

    /// Renders the likely-next utterance while the engine's quiet gap runs
    /// down, so a progress line can start fully in hand — the streaming path's
    /// stutter risk disappears along with its latency win.
    func prepare(_ text: String, priority: NarrationPriority) {
        guard readiness == .ready,
              Self.prefersFullSynthesis(priority),
              // The model is single-tenant: rendering ahead while another
              // line's synthesis streams would cause the very stutter this
              // exists to remove.
              !isSpeaking,
              text != preparedText,
              phraseCache.cachedInMemory(text) == nil
        else { return }
        prepareTask?.cancel()
        preparedSamples = nil
        preparedText = text
        prepareTask = Task { [weak self] in
            guard let self else { return nil }
            let samples = try? await self.synthesizeAll(text)
            if let samples, !Task.isCancelled, self.preparedText == text {
                self.preparedSamples = samples
                if NarrationPhraseCache.isCacheable(text) {
                    self.phraseCache.store(samples, for: text)
                }
            }
            return samples
        }
    }

    /// Hands over prepared audio for `text`, waiting out an in-flight render
    /// of the same line — finishing it is faster than starting over. A
    /// prepare for a *different* line is cancelled instead: the utterance it
    /// served was replaced in the queue, and the model is needed now.
    private func consumePrepared(for text: String) async -> [Float]? {
        defer {
            prepareTask = nil
            preparedText = nil
            preparedSamples = nil
        }
        guard preparedText == text else {
            prepareTask?.cancel()
            return nil
        }
        if let preparedSamples { return preparedSamples }
        return await prepareTask?.value
    }

    /// The whole line as one waveform, no playback until it's finished.
    private func synthesizeAll(_ text: String) async throws -> [Float] {
        var recorded: [Float] = []
        let frames = try await manager.synthesizeStreaming(text: text)
        for try await frame in frames {
            try Task.checkCancellation()
            recorded.append(contentsOf: frame.samples)
        }
        return recorded
    }

    /// Full pre-synthesis for the current utterance: render everything, then
    /// play through the remembered-audio path, which cannot underrun.
    private func synthesizeWhole(_ text: String, generation: Int) async throws {
        let samples = try await synthesizeAll(text)
        guard generation == self.generation else { return }
        if NarrationPhraseCache.isCacheable(text) {
            phraseCache.store(samples, for: text)
        }
        playRemembered(samples, generation: generation)
    }

    /// Generates the line, playing each 80ms frame as it arrives and keeping a
    /// copy so the next occurrence can skip all of this.
    private func synthesize(_ text: String, generation: Int) async throws {
        let worthKeeping = NarrationPhraseCache.isCacheable(text)
        var recorded: [Float] = []
        let frames = try await manager.synthesizeStreaming(text: text)
        for try await frame in frames {
            if Task.isCancelled { break }
            if worthKeeping { recorded.append(contentsOf: frame.samples) }
            accept(frame.samples, generation: generation)
        }
        // Only a line that ran to completion is worth remembering. A preempted
        // one is half a sentence, and replaying half a sentence later would be
        // worse than regenerating the whole one.
        guard worthKeeping, !Task.isCancelled, generation == self.generation else { return }
        phraseCache.store(recorded, for: text)
    }

    /// Memory first, then disk — the disk read is a few hundred kilobytes and
    /// belongs off the main actor, which is where this voice otherwise lives.
    private func rememberedAudio(for text: String) async -> [Float]? {
        if let samples = phraseCache.cachedInMemory(text) { return samples }
        let cache = phraseCache
        return await Task.detached(priority: .userInitiated) {
            cache.cachedOnDisk(text)
        }.value
    }

    /// Replays a remembered line. The pre-roll cushion exists to cover
    /// generation falling behind playback; with the whole waveform already in
    /// hand there is nothing to fall behind, so the line starts immediately.
    private func playRemembered(_ samples: [Float], generation: Int) {
        guard generation == self.generation else { return }
        pendingFrames = []
        playbackStarted = true
        schedule(samples, generation: generation)
    }

    func stop(immediate: Bool) {
        guard isSpeaking else { return }
        cancelCurrent()
        generation += 1
        isSpeaking = false
        if immediate {
            player.stop()
            player.volume = 1
            reportEnd()
        } else {
            // Hard-cutting a waveform mid-sample clicks. Duck first, let the
            // mixer ramp, then stop — a boundary the ear accepts, and the
            // closest this model has to `AVSpeechUtterance`'s word boundary.
            let generation = generation
            player.volume = 0
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, self.generation == generation else { return }
                self.player.stop()
                self.player.volume = 1
            }
            reportEnd()
        }
    }

    /// Always a hop later, never inline. The engine pumps its queue from this
    /// callback, so firing it synchronously would re-enter `stop()`'s caller
    /// and start the next utterance before the current one had finished
    /// tearing down. `AVSpeechSynthesizer`'s delegate defers for the same
    /// reason; matching it keeps the two voices interchangeable.
    private func reportEnd() {
        Task { @MainActor [weak self] in self?.onEnd?() }
    }

    private func cancelCurrent() {
        speakTask?.cancel()
        speakTask = nil
        // Banked audio belongs to the utterance being abandoned; releasing it
        // later would speak a line the engine has already moved past.
        pendingFrames = []
        playbackStarted = false
    }

    /// `isRunning` rather than a remembered flag: the engine also stops on its
    /// own when the output device changes — headphones unplugged mid-turn —
    /// and narration has to come back on the new one.
    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        try engine.start()
    }

    /// Takes one 80ms frame off the generator, holding it back until the
    /// pre-roll cushion has filled.
    private func accept(_ samples: [Float], generation: Int) {
        guard generation == self.generation else { return }
        guard !playbackStarted else {
            schedule(samples, generation: generation)
            return
        }
        pendingFrames.append(samples)
        if pendingFrames.count >= preRollTarget { startPlayback(generation: generation) }
    }

    /// Releases the banked frames and lets the speakers open.
    private func startPlayback(generation: Int) {
        guard generation == self.generation, !playbackStarted else { return }
        playbackStarted = true
        let banked = pendingFrames
        pendingFrames = []
        for frame in banked { schedule(frame, generation: generation) }
    }

    /// Hands one 80ms frame to the player, starting playback on the first.
    private func schedule(_ samples: [Float], generation: Int) {
        guard generation == self.generation, !samples.isEmpty else { return }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(
                from: source.baseAddress!,
                count: samples.count
            )
        }
        scheduledBuffers += 1
        scheduledSamples += samples.count
        let played = samples.count
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            Task { @MainActor in
                self?.noteBufferPlayed(samples: played, generation: generation)
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func noteBufferPlayed(samples: Int, generation: Int) {
        guard generation == self.generation else { return }
        scheduledBuffers -= 1
        playedSamples += samples
        reportProgress()
        // Underrun: playback caught up with generation mid-stream. Left
        // alone, the next frame would land after an audible gap torn out of
        // the middle of a word. Pausing to re-bank a small cushion turns
        // that glitch into one breath-length pause at a frame boundary —
        // `accept` banks again because `playbackStarted` is false, and
        // `schedule`'s `player.play()` resumes the paused node when the
        // cushion releases. Mutually exclusive with `finishIfDrained`, whose
        // `streamEnded` guard this check mirrors.
        if scheduledBuffers == 0, !streamEnded, playbackStarted {
            player.pause()
            playbackStarted = false
            preRollTarget = Self.underrunReBankFrames
            underrunsThisUtterance += 1
            return
        }
        finishIfDrained(generation: generation)
    }

    private func noteStreamEnded(generation: Int) {
        guard generation == self.generation else { return }
        // A line shorter than the cushion — "Done." — never reaches the
        // pre-roll target, so releasing here is what stops it being banked
        // forever and never spoken.
        startPlayback(generation: generation)
        streamEnded = true
        // The line's true length is known now, so the estimate stops guessing.
        reportProgress()
        finishIfDrained(generation: generation)
    }

    /// Where in the line the speakers have got to, as a character count.
    ///
    /// Until generation finishes, the total is guessed from the text's length;
    /// after it, the scheduled sample count is exact. Either way the fraction
    /// can only move forward, which is what the HUD needs — a transcript that
    /// un-reveals a word would read as a glitch.
    private func reportProgress() {
        guard onProgress != nil, !progressText.isEmpty else { return }
        let rate = Double(PocketTtsConstants.audioSampleRate)
        let played = Double(playedSamples) / rate
        let total = streamEnded
            ? max(Double(scheduledSamples) / rate, played)
            : max(Double(progressText.count) / Self.charactersPerSecond, played)
        guard total > 0 else { return }
        let fraction = min(1, played / total)
        onProgress?(progressText, Int((fraction * Double(progressText.count)).rounded()))
    }

    /// The utterance is over only when generation has stopped *and* every
    /// frame handed to the player has actually been heard — otherwise the
    /// engine would start the next one over the tail of this one.
    private func finishIfDrained(generation: Int) {
        guard streamEnded, scheduledBuffers == 0, isSpeaking else { return }
        isSpeaking = false
        // A clean utterance is evidence the machine can keep up again; one
        // that starved carries its count into the next line's cushion.
        recentUnderruns = underrunsThisUtterance
        reportEnd()
    }
}

// MARK: - Settings

/// Picks the narration voice, and fetches the neural one the first time it's
/// chosen. The download is deliberately not automatic: it's the best part of a
/// gigabyte, and a narration feature the user hasn't turned on shouldn't spend
/// their bandwidth or their disk.
struct NarrationVoicePicker: View {
    @Bindable var voice: NeuralNarrationVoice
    @AppStorage(NarrationEngine.voiceKindKey) private var kindRaw =
        NarrationVoiceKind.system.rawValue

    private var kind: NarrationVoiceKind {
        NarrationVoiceKind(rawValue: kindRaw) ?? .system
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Voice", selection: $kindRaw) {
                ForEach(NarrationVoiceKind.allCases) { kind in
                    Text(kind.title).tag(kind.rawValue)
                }
            }
            .onChange(of: kindRaw) { _, new in
                guard NarrationVoiceKind(rawValue: new) == .neural else { return }
                voice.install()
            }
            if kind == .neural {
                status
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch voice.readiness {
        case .notInstalled:
            // Measured, not quoted: the English pack lands at 939 MB on disk
            // because it ships both FlowLM variants and the MLState pipeline
            // alongside the models actually loaded.
            Text("A one-time download of about 940 MB. Runs entirely on this Mac once installed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading voice…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Download failed — using the system voice", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message).foregroundStyle(.secondary)
                Button("Try again") { voice.install() }
                    .buttonStyle(.link)
            }
            .font(.caption)
        }
    }
}
