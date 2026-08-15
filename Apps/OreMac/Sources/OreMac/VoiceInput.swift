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

    private func remainder(afterIgnoring prefix: String, in full: String) -> String {
        guard !prefix.isEmpty else { return full }
        if full.hasPrefix(prefix) {
            return String(full.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if prefix.hasPrefix(full) { return "" }
        return full
    }
}

enum VoiceDraft {
    static func combined(prefix: String, transcript: String) -> String {
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if spoken.isEmpty { return prefix }
        if prefix.isEmpty { return spoken }
        if prefix.hasSuffix(" ") || prefix.hasSuffix("\n") { return prefix + spoken }
        return prefix + " " + spoken
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
        case downloadingModel
        case listening
        case error(String)
    }

    private(set) var status: Status = .idle
    private(set) var transcript: String = ""

    var isActive: Bool {
        switch status {
        case .requestingPermission, .downloadingModel, .listening: true
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
    /// A reserved on-device dictation locale that still needs releasing. Set once
    /// the reservation is taken so teardown frees it on every exit — throw or
    /// cancel included, not just the clean finish.
    private var reservedDictationLocale: Locale?

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func start() {
        guard !isActive else { return }
        assembler.reset()
        transcript = ""
        status = .requestingPermission
        runTask = Task { await run() }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        Task { await tearDownCapture() }
        if case .error = status { return }
        status = .idle
    }

    /// The composer changed under us (the user deleted or edited while the mic
    /// was live). Drop already-recognized words so the next hypothesis does not
    /// paste them back.
    func discardRecognizedSoFar() {
        assembler.discardCommitted()
        transcript = assembler.text
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

        status = .downloadingModel
        _ = try? await AssetInventory.reserve(locale: locale)
        reservedDictationLocale = locale
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard !Task.isCancelled else { throw CancellationError() }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try await analyzer.prepareToAnalyze(in: bestFormat)

        let capture = MicrophoneCapture()
        let buffers = try capture.start(targetFormat: bestFormat)
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
        await releaseReservedDictationLocale()
    }

    private func releaseReservedDictationLocale() async {
        guard #available(macOS 26.0, *), let locale = reservedDictationLocale else { return }
        reservedDictationLocale = nil
        await AssetInventory.release(reservedLocale: locale)
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
        let buffers = try capture.start(targetFormat: nil)
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
        await releaseReservedDictationLocale()
    }

    private static func userFacingMessage(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "kAFAssistantErrorDomain" {
            return "Speech recognition is busy. Try again in a moment."
        }
        return error.localizedDescription
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

    func start(targetFormat: AVAudioFormat?) throws -> AsyncStream<AVAudioPCMBuffer> {
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
