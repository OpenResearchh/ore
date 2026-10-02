import Foundation
import OreProtocol
import OreSupport

/// One Antigravity conversation.
///
/// The CLI keeps stdin open under `--input-format stream-json`, so a single
/// process serves the whole chat: each user message is another NDJSON line.
/// There is no control channel. Permission mode is a launch flag, interrupt
/// tears the process down, and the next send respawns with `--conversation`.
actor AntigravitySession: AgentSession {
    public nonisolated let id: SessionID
    public nonisolated let harness: HarnessKind = .antigravity
    public nonisolated let capabilities: HarnessCapabilities
    public nonisolated let events: AsyncStream<AgentEvent>

    private nonisolated let continuation: AsyncStream<AgentEvent>.Continuation
    private let configuration: SessionConfiguration
    private let executablePath: String
    private let allowUnprompted: Bool

    private var translator: AntigravityTranslator
    private var permissionMode: PermissionMode
    private var process: ChildProcess?
    private var readerTask: Task<Void, Never>?
    private var isStopping = false
    private var isTurnInFlight = false
    private var isInterrupting = false

    public private(set) var providerSessionID: String?

    init(
        id: SessionID,
        executablePath: String,
        configuration: SessionConfiguration,
        capabilities: HarnessCapabilities,
        allowUnprompted: Bool
    ) {
        self.id = id
        self.executablePath = executablePath
        self.configuration = configuration
        self.permissionMode = configuration.permissionMode
        self.capabilities = capabilities
        self.allowUnprompted = allowUnprompted
        self.translator = AntigravityTranslator(sessionID: id)

        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.continuation = continuation

        if case .resume(let providerSessionID) = configuration.resume {
            self.providerSessionID = providerSessionID
        }
    }

    public func start() async throws {
        continuation.yield(.statusChanged(.idle))
    }

    public func send(_ message: UserMessage) async throws {
        guard !isStopping else { throw HarnessError.sessionEnded }
        guard !isTurnInFlight else {
            throw HarnessError.unsupportedCapability("sending while a turn is running")
        }
        let text = message.renderedText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        continuation.yield(.statusChanged(.requesting))
        if process == nil {
            try spawn(effort: message.reasoningEffort)
        }
        guard let process else { throw HarnessError.sessionEnded }
        process.writeLine(try Self.encodeUserEvent(text))
        isTurnInFlight = true
    }

    public func interrupt() async throws {
        guard let process else { return }
        isInterrupting = true
        await process.terminate(gracePeriod: .seconds(2))
        self.process = nil
        isTurnInFlight = false
        continuation.yield(.statusChanged(.interrupted))
    }

    public func setPermissionMode(_ mode: PermissionMode) async throws {
        permissionMode = mode
    }

    public func resolvePermission(
        _ id: PermissionRequestID,
        with decision: PermissionDecision
    ) async throws {
        throw HarnessError.unsupportedCapability("permission prompts")
    }

    public func answerQuestion(_ id: QuestionID, answer: String) async throws {
        try await send(UserMessage(text: answer))
    }

    public func stop() async {
        guard !isStopping else { return }
        isStopping = true
        readerTask?.cancel()
        if let process {
            process.closeStandardInput()
            await process.terminate()
        }
        process = nil
        continuation.finish()
    }

    // MARK: - Process

    private func spawn(effort: ReasoningEffort?) throws {
        let process: ChildProcess
        do {
            process = try ChildProcess(
                executablePath: executablePath,
                arguments: makeArguments(effort: effort),
                workingDirectory: configuration.workingDirectory,
                environment: ShellEnvironment.childEnvironment(
                    overrides: configuration.environmentOverrides,
                    allowProviderCredentials: configuration.allowAPIKeyFallback
                )
            )
        } catch {
            continuation.yield(.statusChanged(.failed))
            throw error
        }
        self.process = process

        readerTask = Task { [weak self] in
            async let diagnostics = Self.collectStderr(from: process)
            for await line in process.stdoutChunks.lines() {
                await self?.handle(line: line)
            }
            let status = await process.waitForExit()
            await self?.handleProcessExit(status: status, stderr: await diagnostics)
        }
    }

    private func handle(line: String) {
        let output = translator.translate(line: line)
        for event in output.events {
            if case .sessionStarted(let started) = event {
                if providerSessionID == started.providerSessionID { continue }
                providerSessionID = started.providerSessionID
            }
            if case .turnCompleted = event {
                isTurnInFlight = false
            }
            continuation.yield(event)
        }
    }

    private func handleProcessExit(status: Int32, stderr: String) {
        process = nil
        let wasInterrupted = isInterrupting
        isInterrupting = false
        isTurnInFlight = false
        for event in translator.closeTurn(
            exitCode: wasInterrupted ? 0 : status,
            stderr: stderr
        ).events {
            continuation.yield(event)
        }
    }

    private func makeArguments(effort: ReasoningEffort?) -> [String] {
        var arguments = AntigravityHarness.printModeArguments
        if let model = configuration.model {
            arguments += ["--model", model]
        }
        if let effort {
            arguments += ["--effort", AntigravityHarness.cliEffort(effort)]
        }
        if let providerSessionID {
            arguments += ["--conversation", providerSessionID]
        } else if case .resume(let id) = configuration.resume {
            arguments += ["--conversation", id]
        }
        arguments += AntigravityHarness.permissionArguments(
            mode: permissionMode,
            allowUnprompted: allowUnprompted
        )
        arguments += configuration.extraArguments
        return arguments
    }

    private static func encodeUserEvent(_ text: String) throws -> String {
        let payload: [String: Any] = [
            "event": "user",
            "message": ["content": text],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw HarnessError.transportFailure("could not encode a message as UTF-8")
        }
        return string
    }

    private static func collectStderr(from process: ChildProcess) async -> String {
        var recent: [String] = []
        for await line in process.stderrChunks.lines() {
            recent.append(line)
            if recent.count > 40 { recent.removeFirst(recent.count - 40) }
        }
        return recent.joined(separator: "\n")
    }
}
