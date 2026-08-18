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
    /// `priority` shapes delivery, not just what plays first — ambient
    /// progress sits back, interjections lean in. How much of that a given
    /// voice can express depends on the synthesizer.
    func speak(_ text: String, priority: NarrationPriority)
    /// `immediate` cuts instantly; otherwise the voice stops at the nearest
    /// natural boundary it can honour, so preemption doesn't clip a word in
    /// half.
    func stop(immediate: Bool)
}

// MARK: - System voice

/// Apple's built-in synthesis: intelligible, unmistakably synthetic, free.
@MainActor
final class SystemNarrationVoice: NarrationVoice {
    private let synthesizer = AVSpeechSynthesizer()
    private var delegate: SpeechDelegate?
    private var chosenVoice: AVSpeechSynthesisVoice?

    var onEnd: (@MainActor () -> Void)?
    var isSpeaking: Bool { synthesizer.isSpeaking }

    init() {
        let delegate = SpeechDelegate { [weak self] in self?.onEnd?() }
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
/// land there.
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let onEnd: @Sendable () -> Void

    init(onEnd: @escaping @MainActor () -> Void) {
        self.onEnd = { Task { @MainActor in onEnd() } }
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

    @ObservationIgnored var onEnd: (@MainActor () -> Void)?
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
        preRollTarget = Self.preRollFrames(for: priority)
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
                let frames = try await self.manager.synthesizeStreaming(text: text)
                for try await frame in frames {
                    if Task.isCancelled { break }
                    self.accept(frame.samples, generation: generation)
                }
            } catch {
                // A synthesis failure ends the utterance like any other
                // ending; the engine moves on rather than going silent.
            }
            self.noteStreamEnded(generation: generation)
        }
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
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            Task { @MainActor in
                self?.noteBufferPlayed(generation: generation)
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func noteBufferPlayed(generation: Int) {
        guard generation == self.generation else { return }
        scheduledBuffers -= 1
        finishIfDrained(generation: generation)
    }

    private func noteStreamEnded(generation: Int) {
        guard generation == self.generation else { return }
        // A line shorter than the cushion — "Done." — never reaches the
        // pre-roll target, so releasing here is what stops it being banked
        // forever and never spoken.
        startPlayback(generation: generation)
        streamEnded = true
        finishIfDrained(generation: generation)
    }

    /// The utterance is over only when generation has stopped *and* every
    /// frame handed to the player has actually been heard — otherwise the
    /// engine would start the next one over the tail of this one.
    private func finishIfDrained(generation: Int) {
        guard streamEnded, scheduledBuffers == 0, isSpeaking else { return }
        isSpeaking = false
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
