@preconcurrency import AVFoundation
import Foundation
import Observation
@preconcurrency import Speech

/// Turns live speech into the text that lands in the composer.
///
/// Confirmed segments stay put; the current volatile hypothesis is replaced as
/// the recognizer updates, which is how iPhone dictation feels.
struct VoiceTranscriptAssembler: Equatable, Sendable {
    private(set) var confirmed = ""
    private(set) var volatile = ""
    /// Engine text already reflected in the composer — or discarded by the user.
    /// Later hypotheses that still include this prefix only contribute the rest.
    private var ignoredPrefix = ""

    var text: String {
        remainder(afterIgnoring: ignoredPrefix, in: confirmed + volatile)
    }

    mutating func applySegment(_ segment: String, isFinal: Bool) {
        if isFinal {
            confirmed += segment
            volatile = ""
        } else {
            volatile = segment
        }
    }

    /// `SFSpeechRecognizer` reports the whole utterance so far, not a delta.
    mutating func applyUtterance(_ utterance: String, isFinal: Bool) {
        if isFinal {
            confirmed = utterance
            volatile = ""
        } else {
            confirmed = ""
            volatile = utterance
        }
    }

    /// The user edited or cleared the composer while we were still listening.
    /// Keep the recognizer running, but do not write its old words back.
    mutating func discardCommitted() {
        ignoredPrefix = confirmed + volatile
    }

    mutating func reset() {
        confirmed = ""
        volatile = ""
        ignoredPrefix = ""
    }

    /// Words already discarded stay discarded. A later hypothesis is compared
    /// word-by-word (case and punctuation ignored) so "Hello world extra."
    /// cannot paste back "hello world extra" the user just deleted, and a
    /// revision like "add a test now" only contributes the new "now".
    private func remainder(afterIgnoring prefix: String, in full: String) -> String {
        guard !prefix.isEmpty else { return full }
        let prefixWords = words(in: prefix)
        let fullWords = words(in: full)
        guard !prefixWords.isEmpty else { return full }

        var shared = 0
        while shared < prefixWords.count, shared < fullWords.count,
              prefixWords[shared] == fullWords[shared] {
            shared += 1
        }

        if shared == fullWords.count { return "" }
        if shared == 0 { return full }
        return substring(of: full, afterWordCount: shared)
    }

    private func words(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private func substring(of full: String, afterWordCount count: Int) -> String {
        var seen = 0
        var index = full.startIndex
        while index < full.endIndex, seen < count {
            if full[index].isLetter || full[index].isNumber {
                while index < full.endIndex, full[index].isLetter || full[index].isNumber {
                    index = full.index(after: index)
                }
                seen += 1
            } else {
                index = full.index(after: index)
            }
        }
        return String(full[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum VoiceDraft {
    static func combined(prefix: String, transcript: String) -> String {
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if spoken.isEmpty { return prefix }
        if prefix.isEmpty { return spoken }
        if prefix.hasSuffix(" ") || prefix.hasSuffix("\n") { return prefix + spoken }
        if spoken.hasPrefix("\n") { return prefix + spoken }
        if spoken.hasPrefix("- ") { return prefix + "\n" + spoken }
        return prefix + " " + spoken
    }
}

/// Decides what happens to the dictated text when a voice session ends.
/// Ending the chord sends the turn; Esc cancels; passive teardown (switching
/// tabs, the pane disappearing) parks the words in the draft instead of firing
/// a turn the user never asked for.
enum VoiceTurnCommit {
    enum Disposition {
        case send
        case commitToDraft
        case cancel
    }

    enum Outcome: Equatable {
        case send(String)
        case updateDraft(String)
        case none
    }

    static func resolve(_ disposition: Disposition, prefix: String, spokenFormatted: String) -> Outcome {
        if case .cancel = disposition { return .none }
        // Nothing was actually said: leave the draft alone and never send.
        guard !spokenFormatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .none
        }
        let combined = VoiceDraft.combined(prefix: prefix, transcript: spokenFormatted)
        switch disposition {
        case .send: return .send(combined)
        case .commitToDraft: return .updateDraft(combined)
        case .cancel: return .none
        }
    }
}

/// Turns a dictated paragraph into something closer to a typed prompt: spoken
/// "new line" / "new paragraph" become real breaks, and a run of "first… second…"
/// becomes a markdown list. Intent extraction still sees the raw transcript;
/// this runs on the rewritten draft so model-switch clauses are already gone.
enum VoiceDictationFormatter {
    static func format(_ text: String) -> String {
        let withBreaks = applySpokenBreaks(text)
        return applySpokenLists(withBreaks)
    }

    private static let breakPhrases: [(phrase: String, replacement: String)] = [
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
        ("newline", "\n"),
        ("bullet point", "\n- "),
        ("next bullet", "\n- "),
    ]

    private static func applySpokenBreaks(_ text: String) -> String {
        var result = text
        for (phrase, replacement) in breakPhrases {
            let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: phrase) + #"\b"#
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        result = result.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let ordinalPattern = try! NSRegularExpression(
        pattern: #"\b(firstly|first|secondly|second|thirdly|third|fourth|fifth|finally|lastly)\b"#,
        options: .caseInsensitive
    )

    private static func applySpokenLists(_ text: String) -> String {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = ordinalPattern.matches(in: text, range: full).filter { match in
            isClauseStart(in: text, before: match.range.location)
        }
        guard matches.count >= 2 else { return text }

        let intro = String(text[text.startIndex..<range(matches[0].range, in: text).lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [String] = []
        for (index, match) in matches.enumerated() {
            let start = range(match.range, in: text).upperBound
            let end = index + 1 < matches.count
                ? range(matches[index + 1].range, in: text).lowerBound
                : text.endIndex
            var item = String(text[start..<end])
            item = item.replacingOccurrences(
                of: #"^[\s,;:\-–—]+"#, with: "", options: .regularExpression
            )
            item = item.trimmingCharacters(in: CharacterSet(charactersIn: " \t,;."))
            if !item.isEmpty { items.append(item) }
        }
        guard items.count >= 2 else { return text }

        let list = items.map { "- \($0)" }.joined(separator: "\n")
        if intro.isEmpty { return list }
        return intro + "\n" + list
    }

    private static func isClauseStart(in text: String, before location: Int) -> Bool {
        guard location > 0 else { return true }
        let prefix = (text as NSString).substring(to: location)
        guard let last = prefix.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return true
        }
        return ".!?;:\n".contains(last)
    }

    private static func range(_ nsRange: NSRange, in text: String) -> Range<String.Index> {
        Range(nsRange, in: text) ?? text.startIndex..<text.startIndex
    }
}

/// Live microphone dictation for the composer. Stays in OreMac: the core still
/// only ever receives the resulting string.
@MainActor
@Observable
final class VoiceInputController {
    enum Status: Equatable {
        case idle
        case requestingPermission
        /// Loading an already-installed on-device model into the analyzer.
        case preparing
        /// The English dictation asset is not on disk yet and is being fetched.
        case downloadingModel
        case listening
        case error(String)
    }

    private(set) var status: Status = .idle
    private(set) var transcript: String = ""
    /// Smoothed microphone loudness, 0…1 — fast attack, slow release, so the
    /// composer's smoke breathes with the voice instead of flickering with it.
    private(set) var audioLevel: Double = 0

    var isActive: Bool {
        switch status {
        case .requestingPermission, .preparing, .downloadingModel, .listening: true
        case .idle, .error: false
        }
    }

    var isListening: Bool {
        if case .listening = status { return true }
        return false
    }

    private var runTask: Task<Void, Never>?
    private var assembler = VoiceTranscriptAssembler()
    private var capture: MicrophoneCapture?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var analyzerStop: (@Sendable () async -> Void)?

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func start() {
        guard !isActive else { return }
        assembler.reset()
        transcript = ""
        audioLevel = 0
        status = .requestingPermission
        runTask = Task { await run() }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        Task { await tearDownCapture() }
        audioLevel = 0
        if case .error = status { return }
        status = .idle
    }

    /// Called from the audio tap (via the main actor) roughly 12×/second.
    private func absorb(level: Float) {
        audioLevel = max(Double(level), audioLevel * 0.82)
    }

    /// The tap's level callback: hops to the main actor and feeds `absorb`.
    private nonisolated func levelHandler() -> @Sendable (Float) -> Void {
        { [weak self] level in
            Task { @MainActor in self?.absorb(level: level) }
        }
    }

    private func run() async {
        do {
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard allowed else {
                status = .error("Microphone access is required for dictation.")
                return
            }
            guard !Task.isCancelled else { return }

            if #available(macOS 26.0, *) {
                do {
                    try await runOnDeviceDictation()
                    if case .error = status { return }
                    status = .idle
                    return
                } catch is CancellationError {
                    status = .idle
                    return
                } catch {
                    guard !Task.isCancelled else {
                        status = .idle
                        return
                    }
                    // Fall through to the older recognizer so a missing on-device
                    // model doesn't leave the mic button dead.
                }
            }

            try await runSpeechRecognizer()
            if case .error = status { return }
            status = .idle
        } catch is CancellationError {
            status = .idle
        } catch {
            status = .error(Self.userFacingMessage(for: error))
        }
        await tearDownCapture()
    }

    @available(macOS 26.0, *)
    private func runOnDeviceDictation() async throws {
        let preferred = Locale(identifier: "en_US")
        let locale = await DictationTranscriber.supportedLocale(equivalentTo: preferred)
            ?? preferred
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)

        status = .preparing
        try await SpeechAssetKeeper.ensureInstalled(transcriber: transcriber, locale: locale) {
            status = .downloadingModel
        }
        guard !Task.isCancelled else { throw CancellationError() }
        if status == .downloadingModel { status = .preparing }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try await analyzer.prepareToAnalyze(in: bestFormat)

        let capture = MicrophoneCapture()
        let buffers = try capture.start(targetFormat: bestFormat, onLevel: levelHandler())
        self.capture = capture

        let input = AsyncStream<AnalyzerInput> { continuation in
            let bufferTask = Task {
                for await buffer in buffers {
                    continuation.yield(AnalyzerInput(buffer: buffer))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in bufferTask.cancel() }
        }

        analyzerStop = {
            await analyzer.cancelAndFinishNow()
        }

        let resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let segment = String(result.text.characters)
                    await MainActor.run {
                        guard let self else { return }
                        self.assembler.applySegment(segment, isFinal: result.isFinal)
                        self.transcript = self.assembler.text
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    self?.status = .error(Self.userFacingMessage(for: error))
                }
            }
        }

        status = .listening
        try await analyzer.start(inputSequence: input)
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        resultsTask.cancel()
    }

    private func runSpeechRecognizer() async throws {
        let authorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard authorized else {
            status = .error("Speech recognition access is required for dictation.")
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US")),
              recognizer.isAvailable
        else {
            status = .error("English speech recognition isn’t available on this Mac.")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let capture = MicrophoneCapture()
        let buffers = try capture.start(targetFormat: nil, onLevel: levelHandler())
        self.capture = capture

        let pump = Task { [weak self] in
            for await buffer in buffers {
                self?.recognitionRequest?.append(buffer)
            }
            self?.recognitionRequest?.endAudio()
        }

        status = .listening
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var finished = false
                recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    guard let self else { return }
                    if let result {
                        Task { @MainActor in
                            self.assembler.applyUtterance(
                                result.bestTranscription.formattedString,
                                isFinal: result.isFinal
                            )
                            self.transcript = self.assembler.text
                        }
                    }
                    if let error {
                        if !finished {
                            finished = true
                            continuation.resume(throwing: error)
                        }
                        return
                    }
                    if result?.isFinal == true, !finished {
                        finished = true
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            pump.cancel()
        }
        pump.cancel()
    }

    private func tearDownCapture() async {
        capture?.stop()
        capture = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        if let analyzerStop {
            await analyzerStop()
            self.analyzerStop = nil
        }
    }

    private static func userFacingMessage(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "kAFAssistantErrorDomain" {
            return "Speech recognition is busy. Try again in a moment."
        }
        return error.localizedDescription
    }
}

/// Holds the on-device English dictation locale for the process lifetime.
///
/// Releasing it at the end of every mic session made the next tab look like a
/// fresh download: `AssetInventory` had to reserve (and sometimes reinstall)
/// the same asset again, and the UI labeled that wait as "Downloading…".
@available(macOS 26.0, *)
@MainActor
enum SpeechAssetKeeper {
    private static var reservedLocale: Locale?
    private static var assetsReady = false

    static func ensureInstalled(
        transcriber: DictationTranscriber,
        locale: Locale,
        downloading: () -> Void
    ) async throws {
        if reservedLocale == nil {
            do {
                try await AssetInventory.reserve(locale: locale)
            } catch {
                // Already reserved in this process, or the system is holding it.
            }
            reservedLocale = locale
        }
        guard !assetsReady else { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            downloading()
            try await request.downloadAndInstall()
        }
        assetsReady = true
    }
}

private enum VoiceInputError: LocalizedError {
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone is available."
        }
    }
}

private final class BufferConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let lock = NSLock()

    init?(from: AVAudioFormat, to: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: from, to: to) else { return nil }
        self.converter = converter
        self.format = to
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(capacity, 1)) else {
            return nil
        }
        var error: NSError?
        let consumed = Flag()
        converter.convert(to: output, error: &error) { _, status in
            if consumed.value {
                status.pointee = .noDataNow
                return nil
            }
            consumed.value = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil || output.frameLength == 0 { return nil }
        return output
    }
}

private final class Flag: @unchecked Sendable {
    var value = false
}

/// Lives outside `VoiceInputController` so the audio tap is not MainActor-isolated.
/// The previous version crashed with `dispatch_assert_queue` on the realtime thread.
private final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    func start(
        targetFormat: AVAudioFormat?,
        onLevel: (@Sendable (Float) -> Void)? = nil
    ) throws -> AsyncStream<AVAudioPCMBuffer> {
        let input = engine.inputNode
        engine.prepare()
        try engine.start()

        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.channelCount > 0, hardwareFormat.sampleRate > 0 else {
            engine.stop()
            throw VoiceInputError.noInputDevice
        }

        let converter: BufferConverter?
        if let targetFormat,
           targetFormat.sampleRate != hardwareFormat.sampleRate
            || targetFormat.channelCount != hardwareFormat.channelCount
            || targetFormat.commonFormat != hardwareFormat.commonFormat {
            converter = BufferConverter(from: hardwareFormat, to: targetFormat)
        } else {
            converter = nil
        }

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.continuation = continuation
        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { buffer, _ in
            if let onLevel, let loudness = bufferLoudness(buffer) {
                onLevel(loudness)
            }
            if let converter, let converted = converter.convert(buffer) {
                continuation.yield(converted)
            } else if let copy = copyPCMBuffer(buffer) {
                continuation.yield(copy)
            }
        }
        tapInstalled = true
        return stream
    }

    func stop() {
        continuation?.finish()
        continuation = nil
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
    }
}

/// Perceptual loudness of a buffer in 0…1, mapping roughly -50 dB (room tone)
/// to -8 dB (speaking directly into the mic).
private func bufferLoudness(_ buffer: AVAudioPCMBuffer) -> Float? {
    guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
    let frames = Int(buffer.frameLength)
    let samples = data[0]
    var sum: Float = 0
    for i in 0..<frames {
        sum += samples[i] * samples[i]
    }
    let rms = sqrt(sum / Float(frames))
    let db = 20 * log10(max(rms, 1e-6))
    return min(max((db + 50) / 42, 0), 1)
}

private func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
        return nil
    }
    copy.frameLength = buffer.frameLength
    let channels = Int(buffer.format.channelCount)
    let frames = Int(buffer.frameLength)
    if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
        for channel in 0..<channels {
            dst[channel].update(from: src[channel], count: frames)
        }
    } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
        for channel in 0..<channels {
            dst[channel].update(from: src[channel], count: frames)
        }
    } else {
        return nil
    }
    return copy
}
