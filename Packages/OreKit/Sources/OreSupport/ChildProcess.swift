import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
// `signal`, `kill` and the SIG* constants come from the platform's C library,
// which Foundation re-exports on Apple platforms and does not elsewhere.
import Glibc
#endif

/// A child CLI process with streaming stdio.
///
/// Both the agent harnesses and the git engine run their work as child
/// processes, so this is the shared substrate under both. Output is exposed as
/// raw byte chunks rather than lines: git's output is not line-oriented (a diff
/// is full of blank lines that matter, and `-z` output has no newlines at all),
/// so line splitting is left to the callers that actually want it.
///
/// Reading happens on dedicated threads with blocking reads rather than on the
/// cooperative pool: an agent CLI can go silent for minutes and then emit
/// megabytes, and neither should starve Swift's thread pool.
public enum ChildProcessError: Error, Sendable, CustomStringConvertible {
    case launchFailed(executablePath: String, reason: String)

    public var description: String {
        switch self {
        case .launchFailed(let path, let reason):
            return "Could not launch \(path): \(reason)"
        }
    }
}

public final class ChildProcess: @unchecked Sendable {
    /// Raw stdout, in whatever chunks arrive. Finishes at EOF.
    public let stdoutChunks: AsyncStream<Data>
    /// Raw stderr. Kept separate: for a harness, stderr is diagnostics and
    /// never protocol.
    public let stderrChunks: AsyncStream<Data>

    public let executablePath: String
    public let arguments: [String]

    private let process: Process
    private let stdinHandle: FileHandle
    private let writeQueue: DispatchQueue
    private let state = Lockbox(State())
    private let exitState: Lockbox<ExitState>

    private struct State {
        var stdinClosed = false
        var terminated = false
        var writeFailure: String?
    }

    private struct ExitState {
        var status: Int32?
        var waiters: [CheckedContinuation<Int32, Never>] = []
    }

    /// Stderr is diagnostics, so under backpressure it keeps the newest output
    /// (where the reason for a failure lives) instead of growing without end.
    /// Consumers that read it concurrently never come near this; it only bites
    /// a stream nobody reads, which used to buffer every chunk for as long as
    /// the process object lived.
    static let stderrBufferLimit = 256

    /// Foundation's `FileHandle.write` raises `SIGPIPE` when the child has
    /// exited, which would kill the *host app* rather than surface an error.
    /// Ignoring it once turns those writes into ordinary `EPIPE` failures.
    private static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    private static func launch(_ process: Process) throws {
        try ProcessLaunch.run(process)
    }

    public init(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        discardStandardError: Bool = false
    ) throws {
        _ = ChildProcess.ignoreSIGPIPE

        self.executablePath = executablePath
        self.arguments = arguments

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.writeQueue = DispatchQueue(
            label: "ore.harness.stdin.\(URL(fileURLWithPath: executablePath).lastPathComponent)"
        )

        self.stdoutChunks = ChildProcess.chunkStream(
            from: stdoutPipe.fileHandleForReading,
            label: "stdout",
            bufferingPolicy: .unbounded  // protocol: dropping any of it corrupts
        )
        if discardStandardError {
            // No pipe, no reader thread, nothing to buffer.
            process.standardError = FileHandle.nullDevice
            self.stderrChunks = AsyncStream { $0.finish() }
        } else {
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            self.stderrChunks = ChildProcess.chunkStream(
                from: stderrPipe.fileHandleForReading,
                label: "stderr",
                bufferingPolicy: .bufferingNewest(ChildProcess.stderrBufferLimit)
            )
        }

        // Installed before launch, exactly once. Installing it after launch
        // raced the exit, and when the process had already gone Foundation
        // invoked the handler but never released it — one leaked block (and
        // everything it captured) per short-lived git call.
        let exitState = Lockbox(ExitState())
        self.exitState = exitState
        process.terminationHandler = { process in
            let status = process.terminationStatus
            process.terminationHandler = nil
            let waiters = exitState.withLock { current -> [CheckedContinuation<Int32, Never>] in
                current.status = status
                defer { current.waiters.removeAll() }
                return current.waiters
            }
            for waiter in waiters { waiter.resume(returning: status) }
        }

        do {
            try ChildProcess.launch(process)
        } catch {
            process.terminationHandler = nil
            throw ChildProcessError.launchFailed(
                executablePath: executablePath,
                reason: error.localizedDescription
            )
        }
    }

    public var isRunning: Bool { process.isRunning }

    public var processIdentifier: Int32 { process.processIdentifier }

    /// Non-nil once the process has exited.
    public var terminationStatus: Int32? {
        process.isRunning ? nil : process.terminationStatus
    }

    /// The last stdin write error, if any. Read when a session goes quiet to
    /// distinguish "agent is thinking" from "we lost the pipe".
    public var writeFailure: String? {
        state.withLock { $0.writeFailure }
    }

    /// Queues a line for stdin. Returns immediately; writes are performed in
    /// order on a dedicated queue so a full pipe buffer never blocks a caller.
    public func writeLine(_ line: String) {
        var data = Data(line.utf8)
        data.append(0x0A)
        write(data)
    }

    public func write(_ data: Data) {
        let shouldSkip = state.withLock { $0.stdinClosed || $0.terminated }
        guard !shouldSkip else { return }

        writeQueue.async { [stdinHandle, state] in
            guard state.withLock({ !$0.stdinClosed }) else { return }
            do {
                try stdinHandle.write(contentsOf: data)
            } catch {
                state.withLock { current in
                    if current.writeFailure == nil {
                        current.writeFailure = error.localizedDescription
                    }
                }
            }
        }
    }

    /// Closes stdin, which is how a `-p` style CLI learns no more input is
    /// coming and can exit cleanly.
    public func closeStandardInput() {
        let alreadyClosed = state.withLock { current -> Bool in
            defer { current.stdinClosed = true }
            return current.stdinClosed
        }
        guard !alreadyClosed else { return }

        // Ordered behind any queued writes so a final message isn't lost.
        writeQueue.async { [stdinHandle] in
            try? stdinHandle.close()
        }
    }

    /// Waits for exit without blocking a thread.
    @discardableResult
    public func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            // Checked and registered under one lock, so the handler either
            // already recorded the status or will find this waiter.
            let status = exitState.withLock { current -> Int32? in
                if current.status == nil { current.waiters.append(continuation) }
                return current.status
            }
            if let status { continuation.resume(returning: status) }
        }
    }

    deinit {
        // The read ends belong to their reader threads, which close them at
        // EOF; closing one under a blocked read would fault. Stdin is ours,
        // and a caller that never closed it would otherwise hold it open
        // until the Pipe happened to be released.
        closeStandardInput()
    }

    /// Asks the process to exit, escalating to `SIGKILL` if it doesn't.
    ///
    /// Agent CLIs run their own child processes (a build, a test run); giving
    /// them a moment to shut down lets them clean those up instead of leaving
    /// orphans behind.
    public func terminate(gracePeriod: Duration = .seconds(3)) async {
        state.withLock { $0.terminated = true }
        closeStandardInput()

        guard process.isRunning else { return }
        process.terminate()

        let deadline = ContinuousClock.now.advanced(by: gracePeriod)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    // MARK: - Reading

    /// Captures only the handle and the continuation — never `self` — so an
    /// exited process isn't kept alive by its own reader.
    private static func chunkStream(
        from handle: FileHandle,
        label: String,
        bufferingPolicy: AsyncStream<Data>.Continuation.BufferingPolicy
    ) -> AsyncStream<Data> {
        AsyncStream(Data.self, bufferingPolicy: bufferingPolicy) { continuation in
            let thread = Thread {
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }  // EOF
                    continuation.yield(chunk)
                }
                // Release the descriptor now rather than whenever Foundation
                // lets go of the Pipe; that was the pile of pipe fds with no
                // live peer.
                try? handle.close()
                continuation.finish()
            }
            thread.name = "ore.process.\(label)"
            thread.start()
        }
    }
}

extension AsyncStream where Element == Data {
    /// Splits a byte stream into lines, without the newline.
    ///
    /// Empty lines are preserved — dropping them would quietly corrupt any
    /// payload where a blank line is content rather than padding.
    public func lines() -> AsyncStream<String> {
        // Unbounded on purpose: this stream only exists because a consumer
        // asked for it, and for stdout a dropped line is a corrupted protocol.
        // Unread output is bounded upstream, at the chunk stream.
        AsyncStream<String>(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                var buffer = Data()
                for await chunk in self {
                    buffer.append(chunk)
                    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[buffer.startIndex..<newlineIndex]
                        buffer = buffer[buffer.index(after: newlineIndex)...]
                        continuation.yield(Self.decode(lineData))
                    }
                }
                // A final line without a trailing newline still counts.
                if !buffer.isEmpty { continuation.yield(Self.decode(buffer)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func decode(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }
}

extension AsyncStream where Element == Data {
    /// Collects the whole stream into one string. For short-lived commands
    /// whose entire output is the result.
    public func collectText() async -> String {
        var data = Data()
        for await chunk in self { data.append(chunk) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Collects the whole stream as bytes, for output that isn't text.
    public func collectData() async -> Data {
        var data = Data()
        for await chunk in self { data.append(chunk) }
        return data
    }
}
