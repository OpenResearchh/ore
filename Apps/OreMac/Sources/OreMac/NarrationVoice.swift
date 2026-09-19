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

/// One reproducible synthesis identity for every neural utterance.
///
/// FluidAudio otherwise uses Pocket TTS's 0.7 temperature and chooses a new
/// random seed for every call. That is expressive in a demo, but in an app it
/// lets the same conditioned voice land with noticeably different prosody —
/// sometimes perceived as a different accent — from one status line to the
/// next. A slightly tighter temperature plus a fixed seed keeps Alba's voice
/// centered while leaving the wording corpus responsible for variety.
enum NeuralNarrationSynthesis {
    static let voice = "alba"
    static let temperature: Float = 0.55
    static let seed: UInt64 = 0x4F_52_45_5F_56_4F_49_43
    static let cacheVersion = "pocket-tts-2-english-alba-t055-stable"

    /// Pocket TTS is autoregressive, so voice characteristics can wander over
    /// a long generation even with stable conditioning. Starting a fresh,
    /// identically seeded session at natural sentence boundaries reasserts
    /// both the speaker prompt and the sampling profile. Punctuation remains
    /// attached so each segment keeps its intended cadence.
    static func segments(_ text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
        }
        if result.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
        }
        return result
    }
}

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
    /// How far a fetch in flight has got.
    ///
    /// `.installing` used to carry nothing, so 940 MB arrived behind a
    /// spinner that looked identical at second one and minute six. FluidAudio
    /// does report byte-weighted progress — just not through
    /// `PocketTtsManager.initialize()`, which drops the handler — so the
    /// download phase can show a real percentage. The two phases either side
    /// of it report nothing, and are labelled rather than given an invented
    /// number.
    enum InstallStage: Equatable, Sendable {
        /// FluidAudio is listing the repository; no byte counts exist yet.
        case preparing
        /// Fetching weights. `fraction` is FluidAudio's own byte-weighted
        /// figure, not a guess.
        case downloading(fraction: Double)
        /// The weights are on disk and CoreML is compiling and loading them.
        /// Measured at 2-11s on an M1, and silent throughout.
        case loading
    }

    enum Readiness: Equatable {
        case notInstalled
        case installing(InstallStage)
        case ready
        case failed(String)
        /// The weights are on disk but this Mac cannot load them — no Metal
        /// device on a VM or a headless session, or a CoreML runtime that
        /// rejects the model. Distinct from `.failed` because the retry that
        /// fixes a download cannot fix this: the same files would be loaded
        /// on the same hardware, forever.
        case unsupported(String)

        /// The button that starts — or restarts — the fetch, and `nil` when
        /// there is nothing to start.
        ///
        /// `.notInstalled` is reachable with the neural voice already chosen:
        /// a download interrupted by a quit, or a relaunch where
        /// `loadNeuralVoiceIfNeeded` rightly declines to spend 940 MB unasked.
        /// That state had no affordance at all, so the only way back to the
        /// download was to switch the picker away and back again.
        ///
        /// `.unsupported` deliberately offers none: a "Try again" that fails
        /// identically every time is worse than saying plainly that this Mac
        /// will be using the system voice.
        var installActionTitle: String? {
            switch self {
            case .notInstalled: "Download"
            case .failed: "Try again"
            case .installing, .ready, .unsupported: nil
            }
        }

        /// The button that stops a fetch in flight. There was none at all
        /// before, which is what made the download feel like something
        /// happening *to* the user rather than something they asked for.
        var cancelActionTitle: String? {
            switch self {
            case .installing: "Cancel"
            case .notInstalled, .ready, .failed, .unsupported: nil
            }
        }
    }

    /// Set once the model has been fetched, so later launches can load it
    /// without asking again or hitting the network.
    private static let installedKey = "ore.narration.neuralInstalled"

    /// FluidAudio's on-disk root for TTS weights on macOS.
    ///
    /// Verified against FluidAudio at the revision `Package.resolved` pins
    /// (0.15.5, 19600a4): `ModelHub.clearAllCaches` names this as the shared
    /// TTS root for every backend on macOS, with the Application Support
    /// variant on the `#else` iOS branch that this app never takes. Pocket
    /// TTS puts its language packs somewhere beneath it.
    ///
    /// Still read in one direction only, because only one direction is sound.
    /// A missing root proves nothing is cached and clears the install flag; a
    /// present root proves only that *some* backend has downloaded something,
    /// not that this language pack is complete, so it changes nothing. Being
    /// wrong that way costs one press of a button that already exists. Being
    /// wrong the other way costs 940 MB nobody asked for.
    private static let vendorCacheRoot = ".cache/fluidaudio"

    /// The one file every compiled CoreML model carries.
    ///
    /// A `.mlmodelc` is a directory, and its contents vary by model type — an
    /// ML Program has `model.mil`, a neural network has `model.espresso.net`
    /// — but all of them have this manifest, and CoreML will not open a
    /// directory without it. So its absence is not a guess about a model
    /// being broken: it is the exact condition the loader refuses on.
    nonisolated static let compiledModelManifest = "coremldata.bin"

    /// A download that stopped partway leaves the directory behind.
    ///
    /// Seen in the wild as `mimi_decoder.mlmodelc` holding only `analytics/`
    /// and `weights/`: the fetch died before the manifest landed. CoreML then
    /// reports it as "Unable to load model … Compile the model with Xcode",
    /// which reads like the app shipped the wrong file and sent the whole
    /// thing to `.unsupported` — "This Mac can't run the neural voice" on a
    /// Mac that runs it fine. Meanwhile FluidAudio sees a directory already
    /// in place and never refetches, so the state was permanent.
    ///
    /// This is the narrowest check that catches it: directory named
    /// `.mlmodelc`, no manifest inside. Nothing else is inspected and nothing
    /// else is ever removed.
    nonisolated static func incompleteCompiledModels(
        under root: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let walk = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var incomplete: [URL] = []
        for case let url as URL in walk {
            guard url.pathExtension == "mlmodelc" else { continue }
            // Whatever is under a model directory, complete or not, is the
            // model's own business — the manifest is the only thing read.
            walk.skipDescendants()
            let manifest = url.appendingPathComponent(compiledModelManifest)
            if !fileManager.fileExists(atPath: manifest.path) { incomplete.append(url) }
        }
        return incomplete
    }

    /// Clears half-written models so the next fetch replaces them, and says
    /// whether anything had to go.
    ///
    /// Deleting inside a vendor cache is a bigger step than reading one, and
    /// it is taken only for directories CoreML has already refused: an
    /// unloadable `.mlmodelc` is worth exactly nothing to keep, and removing
    /// it is what turns "stuck forever" back into "the download resumes".
    private nonisolated static func removeIncompleteModels() {
        for model in incompleteCompiledModels(under: vendorCacheDirectory()) {
            try? FileManager.default.removeItem(at: model)
        }
    }

    private nonisolated static func hasIncompleteModels() -> Bool {
        !incompleteCompiledModels(under: vendorCacheDirectory()).isEmpty
    }

    private nonisolated static func vendorCacheDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(vendorCacheRoot)
    }

    /// The exact language pack this voice fetches and loads.
    ///
    /// Held in one place because two calls now have to agree on it:
    /// `install()` runs FluidAudio's downloader first, for the progress it
    /// reports, and `PocketTtsManager` then loads out of the cache that
    /// filled. Any drift between the two is a second 940 MB download.
    nonisolated static let modelLanguage = PocketTtsLanguage.english
    nonisolated static let modelPrecision = PocketTtsPrecision.fp16
    /// `.gpu` is FluidAudio's default and, measured on an M1, the right one:
    /// GPU ran 1.6-1.9x real time idle and 1.08x with all cores busy, while
    /// `.ane` managed only 1.3-1.4x and 0.83x — below real time, i.e. audible
    /// stutter — and took 13-32s to load rather than 2-11s. `.aneState` fails
    /// outright on this model version ("`functionName` must be nil unless the
    /// model type is ML Program"). The Neural Engine looks like the obvious
    /// home for this and isn't; don't switch without re-measuring.
    nonisolated static let modelPlacement = PocketTtsModelPlacement.gpu

    /// Free space `install()` insists on before it starts.
    ///
    /// There was no check at all, so a volume with no room announced itself
    /// twenty minutes in as whatever the vendor's file writer happened to
    /// throw. Deliberately larger than the 940 MB the pack settles at: each
    /// file streams into a `.partial` beside its destination before being
    /// moved into place, so the peak is everything downloaded so far plus the
    /// largest model a second time.
    nonisolated static let requiredFreeBytes: Int64 = 1_200_000_000

    private(set) var readiness: Readiness

    /// How long the current fetch has been running. The only thing that moves
    /// while FluidAudio lists the repository or CoreML compiles, both of which
    /// report nothing.
    private(set) var installElapsed: TimeInterval = 0

    @ObservationIgnored private let manager = PocketTtsManager(
        defaultVoice: NeuralNarrationSynthesis.voice,
        language: NeuralNarrationVoice.modelLanguage,
        precision: NeuralNarrationVoice.modelPrecision,
        placement: NeuralNarrationVoice.modelPlacement
    )
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
    /// Ticks `installElapsed` while a fetch runs, and only then.
    @ObservationIgnored private var installClockTask: Task<Void, Never>?
    @ObservationIgnored private var installStartedAt: Date?
    /// Bumped by every `install()` and every `cancelInstall()`, so a fetch
    /// that is still unwinding cannot report its outcome over the state the
    /// user has since moved to. Same device as `generation` does for
    /// utterances, for the same reason: cancellation lands late.
    @ObservationIgnored private var installGeneration = 0
    /// Fills the persistent phrase cache only while narration is otherwise
    /// idle. Foreground speech cancels this immediately; a later quiet period
    /// resumes at the first uncached phrase.
    @ObservationIgnored private var corpusWarmupTask: Task<Void, Never>?
    @ObservationIgnored private var corpusWarmupCompleted = false
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
    ///
    /// The stored flag alone is not enough. It was written once on success
    /// and never unwritten, so a Mac whose caches had been emptied — a
    /// cleaner, Migration Assistant, someone reclaiming space — still claimed
    /// the model was installed, and the next narration line silently re-spent
    /// 940 MB with no consent, no progress and no way to stop it. Reading it
    /// is therefore also where a stale flag gets cleared, which puts the
    /// Download button back.
    var wasInstalledPreviously: Bool {
        guard UserDefaults.standard.bool(forKey: Self.installedKey) else { return false }
        guard Self.installFlagIsStale(
            vendorCacheRootExists: Self.hasVendorCacheRoot(),
            hasIncompleteModels: Self.hasIncompleteModels()
        ) else { return true }
        UserDefaults.standard.set(false, forKey: Self.installedKey)
        return false
    }

    /// Whether a stored install flag has been outlived by its weights.
    ///
    /// Still one-directional on the root — see `vendorCacheRoot`. Absence is
    /// proof; presence is not evidence of anything. A model directory with no
    /// manifest is the second kind of proof: not "something may be missing"
    /// but "CoreML will refuse this", which makes the flag a lie however it
    /// got written.
    nonisolated static func installFlagIsStale(
        vendorCacheRootExists: Bool,
        hasIncompleteModels: Bool
    ) -> Bool {
        !vendorCacheRootExists || hasIncompleteModels
    }

    private static func hasVendorCacheRoot() -> Bool {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(vendorCacheRoot)
        return FileManager.default.fileExists(atPath: root.path)
    }

    /// How much of the volume the cache lives on is free, or nil when the
    /// system declines to say. Unknowable is not the same as too small, so a
    /// nil refuses nothing.
    private static func freeBytesForDownload() -> Int64? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// How much more room the fetch needs than the volume has, or nil when
    /// there is enough — or when free space could not be read at all.
    nonisolated static func diskShortfall(
        freeBytes: Int64?,
        required: Int64 = requiredFreeBytes
    ) -> Int64? {
        guard let freeBytes, freeBytes < required else { return nil }
        return required - freeBytes
    }

    /// Names the shortfall rather than the failure. A download that dies at
    /// 900 MB reports whatever the vendor's file writer threw, which tells the
    /// user nothing about what to do next.
    nonisolated static func notEnoughSpaceMessage(shortfall: Int64) -> String {
        let needed = ByteCountFormatter.string(
            fromByteCount: requiredFreeBytes, countStyle: .file
        )
        let missing = ByteCountFormatter.string(fromByteCount: shortfall, countStyle: .file)
        return "Not enough disk space. Installing the neural voice needs about "
            + "\(needed) free — \(missing) more than this Mac has right now."
    }

    /// Downloads the model if needed and loads it. Safe to call repeatedly;
    /// concurrent calls share the one in-flight attempt.
    ///
    /// Two phases, not one. `PocketTtsManager.initialize()` does both but
    /// drops FluidAudio's progress handler on the floor, which is what left
    /// 940 MB behind a spinner. Running the downloader first — with exactly
    /// the pack the manager is built for — buys a real percentage and leaves
    /// `initialize()` as a pure load off the cache that just filled. It also
    /// separates the two failures: a fetch that broke is worth retrying, and a
    /// load that broke is read against the weights on disk — see
    /// `loadFailure(_:modelsAreComplete:)`.
    func install() {
        guard readiness != .ready, installTask == nil else { return }
        if case .unsupported = readiness { return }
        // Only a fetch needs the room. This is also the path a normal session
        // takes to *load* an already-downloaded model, and refusing that on a
        // nearly-full volume would silence the voice of someone who had
        // already paid the 940 MB — with a message about disk space for a
        // download that was never going to happen.
        if !wasInstalledPreviously,
           let shortfall = Self.diskShortfall(freeBytes: Self.freeBytesForDownload()) {
            readiness = .failed(Self.notEnoughSpaceMessage(shortfall: shortfall))
            return
        }
        installGeneration += 1
        let generation = installGeneration
        installStartedAt = Date()
        installElapsed = 0
        readiness = .installing(.preparing)
        startInstallClock()
        // FluidAudio documents this as called from an unspecified queue, so
        // the hop is its contract, not belt and braces.
        let onProgress: ProgressHandler = { [weak self] progress in
            Task { @MainActor in
                self?.noteInstallStage(
                    Self.installStage(for: progress), generation: generation
                )
            }
        }
        installTask = Task { [weak self] in
            guard let self else { return }
            // Before the fetch, not after it: FluidAudio decides what to
            // download from what is already on disk, and a directory left
            // behind by an interrupted download looks finished to it. Clearing
            // the unloadable ones is what puts them back on the fetch list —
            // and only those, so a complete pack costs one directory scan.
            await Task.detached(priority: .utility) {
                NeuralNarrationVoice.removeIncompleteModels()
            }.value
            do {
                try await Self.fetchWeights(progress: onProgress)
            } catch {
                self.finishInstall(
                    with: Self.fetchFailure(error), generation: generation
                )
                return
            }
            self.noteInstallStage(.loading, generation: generation)
            do {
                try await self.manager.initialize()
            } catch {
                self.finishInstall(
                    with: Self.loadFailure(error, modelsAreComplete: !Self.hasIncompleteModels()),
                    generation: generation
                )
                return
            }
            self.finishInstall(with: .ready, generation: generation)
        }
    }

    /// Stops a fetch in flight.
    ///
    /// FluidAudio streams each file into a `.partial` beside its destination
    /// and resumes from there with `Range`/`If-Range`, so this is a pause the
    /// user can undo rather than 940 MB thrown away. The state flips here
    /// instead of waiting for the task to unwind: cancellation only lands at
    /// the next suspension point, and a spinner that keeps spinning after
    /// Cancel is the same non-answer the button was added to remove.
    func cancelInstall() {
        guard installTask != nil else { return }
        installGeneration += 1
        installTask?.cancel()
        installTask = nil
        stopInstallClock()
        readiness = .notInstalled
    }

    /// Fetches the language pack, reporting FluidAudio's byte-weighted
    /// progress. Everything `PocketTtsManager` would download on its own,
    /// with the handler it doesn't forward.
    private static func fetchWeights(
        progress: @escaping ProgressHandler
    ) async throws {
        _ = try await PocketTtsResourceDownloader.ensureModels(
            language: modelLanguage,
            precision: modelPrecision,
            placement: modelPlacement,
            progressHandler: progress
        )
    }

    nonisolated static func installStage(for progress: DownloadProgress) -> InstallStage {
        switch progress.phase {
        case .listing:
            .preparing
        case .downloading:
            .downloading(fraction: progress.fractionCompleted)
        case .compiling:
            .loading
        }
    }

    /// A fetch that broke: the network, the mirror, or the disk. Worth
    /// another press, so `.failed` — which is what carries "Try again".
    nonisolated static func fetchFailure(_ error: Error) -> Readiness {
        wasCancelled(error) ? .notInstalled : .failed(error.localizedDescription)
    }

    /// A load that broke with the weights already on disk.
    ///
    /// Which of the two failures it is turns entirely on whether those
    /// weights are whole. Complete weights that will not load are the machine
    /// saying no — a VM or a headless session with no Metal device fails here
    /// every time — and retrying feeds the same files to the same runtime to
    /// the same end, so `.unsupported` says it once instead of offering a
    /// button that can only disappoint. Weights with a model directory
    /// missing its manifest are the opposite: nothing is wrong with the Mac,
    /// a download stopped partway, and another press is precisely the fix.
    nonisolated static func loadFailure(
        _ error: Error,
        modelsAreComplete: Bool
    ) -> Readiness {
        if wasCancelled(error) { return .notInstalled }
        guard modelsAreComplete else { return .failed(incompleteDownloadMessage) }
        return .unsupported(error.localizedDescription)
    }

    /// CoreML's own wording for this — "Compile the model with Xcode or
    /// `MLModel.compileModel(at:)`" — describes a mistake the app would have
    /// had to make at build time, and there is nothing a user can do with it.
    /// Name the thing that actually happened instead.
    nonisolated static let incompleteDownloadMessage =
        "Part of the voice download is missing or damaged. Trying again "
        + "re-fetches only what is incomplete."

    /// Cancellation arrives as `CancellationError` from our own checks and as
    /// `URLError.cancelled` from the download task URLSession tore down.
    /// Neither is a failure to report.
    nonisolated static func wasCancelled(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func noteInstallStage(_ stage: InstallStage, generation: Int) {
        guard generation == installGeneration,
              case .installing(let current) = readiness,
              Self.stageAdvances(from: current, to: stage)
        else { return }
        readiness = .installing(stage)
    }

    /// Progress callbacks hop to the main actor, so one belonging to a phase
    /// that has already ended can land after the next phase started. Letting
    /// it through would put "Downloading 100%" back under a line that already
    /// said "Loading the voice…", which reads as the fetch restarting. Stages
    /// therefore only ever move forward.
    nonisolated static func stageAdvances(
        from current: InstallStage,
        to next: InstallStage
    ) -> Bool {
        switch (current, next) {
        case (.loading, .preparing), (.loading, .downloading), (.downloading, .preparing):
            false
        case (.downloading(let done), .downloading(let now)):
            now >= done
        default:
            true
        }
    }

    private func finishInstall(with outcome: Readiness, generation: Int) {
        guard generation == installGeneration else { return }
        installTask = nil
        stopInstallClock()
        readiness = outcome
        guard outcome == .ready else { return }
        UserDefaults.standard.set(true, forKey: Self.installedKey)
        scheduleCorpusWarmup()
    }

    private func startInstallClock() {
        installClockTask?.cancel()
        installClockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let started = self.installStartedAt else { return }
                self.installElapsed = Date().timeIntervalSince(started)
            }
        }
    }

    private func stopInstallClock() {
        installClockTask?.cancel()
        installClockTask = nil
        installStartedAt = nil
    }

    /// The determinate fraction for the progress bar, or nil in the phases
    /// FluidAudio reports nothing for. A bar parked at 0% through repository
    /// listing and the CoreML load would read as stalled, which is the
    /// impression this whole change exists to remove.
    var installFraction: Double? {
        guard case .installing(let stage) = readiness,
              case .downloading(let fraction) = stage
        else { return nil }
        return min(max(fraction, 0), 1)
    }

    /// One line of honest status under the picker while a fetch runs.
    var installStatusLine: String? {
        guard case .installing(let stage) = readiness else { return nil }
        return Self.installStatus(stage: stage, elapsed: installElapsed)
    }

    /// Elapsed time appears on every stage, not just the ones with a number:
    /// it is the only thing that moves while FluidAudio lists the repository
    /// or CoreML compiles, and "something is still happening" is exactly what
    /// the bare spinner failed to say.
    nonisolated static func installStatus(
        stage: InstallStage,
        elapsed: TimeInterval
    ) -> String {
        let clock = elapsedDescription(elapsed)
        switch stage {
        case .preparing:
            return "Preparing the download… \(clock)"
        case .downloading(let fraction):
            let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
            return "Downloading \(percent)% of about 940 MB — \(clock)"
        case .loading:
            return "Loading the voice… \(clock)"
        }
    }

    nonisolated static func elapsedDescription(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        guard whole >= 60 else { return "\(whole)s" }
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    func speak(_ text: String, priority: NarrationPriority) {
        guard readiness == .ready else {
            // Nothing to say and nothing will say it — report the ending so
            // the engine's queue doesn't stall waiting on a voice that can't
            // speak.
            reportEnd()
            return
        }
        corpusWarmupTask?.cancel()
        corpusWarmupTask = nil
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
        corpusWarmupTask?.cancel()
        corpusWarmupTask = nil
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
        for segment in NeuralNarrationSynthesis.segments(text) {
            let session = try await stableSession(for: segment)
            for try await frame in session.frames {
                if Task.isCancelled {
                    await session.cancel()
                    throw CancellationError()
                }
                recorded.append(contentsOf: frame.samples)
            }
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
        for segment in NeuralNarrationSynthesis.segments(text) {
            let session = try await stableSession(for: segment)
            for try await frame in session.frames {
                if Task.isCancelled {
                    await session.cancel()
                    throw CancellationError()
                }
                if worthKeeping { recorded.append(contentsOf: frame.samples) }
                accept(frame.samples, generation: generation)
            }
        }
        // Only a line that ran to completion is worth remembering. A preempted
        // one is half a sentence, and replaying half a sentence later would be
        // worse than regenerating the whole one.
        guard worthKeeping, !Task.isCancelled, generation == self.generation else { return }
        phraseCache.store(recorded, for: text)
    }

    /// FluidAudio's streaming convenience API does not expose its seed and
    /// therefore chooses a random one internally. The session API does, so a
    /// short-lived session is the narrowest way to make every line use the
    /// exact same voice conditioning and sampling profile.
    private func stableSession(for text: String) async throws -> PocketTtsSession {
        let session = try await manager.makeSession(
            voice: NeuralNarrationSynthesis.voice,
            temperature: NeuralNarrationSynthesis.temperature,
            seed: NeuralNarrationSynthesis.seed
        )
        session.enqueue(text)
        session.finish()
        return session
    }

    // MARK: Common phrase warmup

    /// Renders the reusable, context-free corpus once and lets the existing
    /// bounded LRU disk tier carry those PCM bytes across launches. Shipping
    /// the bytes in the app would add a large opaque asset and go stale when
    /// the model or voice changes; versioned lazy generation gets the same
    /// repeat-call savings without either problem.
    private func scheduleCorpusWarmup() {
        guard readiness == .ready, !corpusWarmupCompleted,
              corpusWarmupTask == nil
        else { return }
        corpusWarmupTask = Task(priority: .background) { [weak self] in
            // Model loading and the user's first line take precedence over a
            // cache optimization they cannot see.
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }

            for phrase in NarrationPhraser.neuralCacheCorpus {
                guard !Task.isCancelled, !self.isSpeaking,
                      self.prepareTask == nil
                else {
                    self.corpusWarmupTask = nil
                    return
                }
                if await self.rememberedAudio(for: phrase) != nil { continue }
                guard let samples = try? await self.synthesizeAll(phrase),
                      !Task.isCancelled
                else {
                    self.corpusWarmupTask = nil
                    return
                }
                self.phraseCache.store(samples, for: phrase)
                await Task.yield()
            }
            self.corpusWarmupCompleted = true
            self.corpusWarmupTask = nil
        }
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
        scheduleCorpusWarmup()
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
            VStack(alignment: .leading, spacing: 4) {
                // Measured, not quoted: the English pack lands at 939 MB on
                // disk because it ships both FlowLM variants and the MLState
                // pipeline alongside the models actually loaded.
                Text("A one-time download of about 940 MB. Runs entirely on this Mac once installed.")
                    .foregroundStyle(.secondary)
                if let title = voice.readiness.installActionTitle {
                    Button(title) { voice.install() }
                        .buttonStyle(.link)
                }
            }
            .font(.caption)
        case .installing:
            VStack(alignment: .leading, spacing: 4) {
                // Determinate while FluidAudio is counting bytes, a spinner
                // through the two phases that count nothing. A bar parked at
                // 0% for the repository listing and the CoreML load reads as
                // hung, which is the thing being fixed.
                if let fraction = voice.installFraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().controlSize(.small)
                }
                if let line = voice.installStatusLine {
                    Text(line).foregroundStyle(.secondary)
                }
                if let title = voice.readiness.cancelActionTitle {
                    Button(title) { voice.cancelInstall() }
                        .buttonStyle(.link)
                }
            }
            .font(.caption)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Download failed — using the system voice", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message).foregroundStyle(.secondary)
                if let title = voice.readiness.installActionTitle {
                    Button(title) { voice.install() }
                        .buttonStyle(.link)
                }
            }
            .font(.caption)
        case .unsupported(let message):
            // No "Try again": the weights are already on disk and the load
            // failed on this machine's CoreML runtime, so the retry would run
            // the identical thing to the identical end. Say what will happen
            // instead of offering a button that can only disappoint.
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "This Mac can't run the neural voice — narration will use the system voice",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                Text(message).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }
}
