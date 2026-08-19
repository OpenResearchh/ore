import Foundation
import OreProtocol
import OreSupport

/// Drives one Claude Code conversation.
///
/// The CLI runs as a long-lived child process with stdin held open, so a single
/// process serves the whole conversation: each user message is another line of
/// stream-json, and the control channel carries interrupts, permission-mode
/// changes and the permission callbacks the CLI blocks on.
public actor ClaudeCodeSession: AgentSession {
    public nonisolated let id: SessionID
    public nonisolated let harness: HarnessKind = .claudeCode
    public nonisolated let capabilities: HarnessCapabilities
    public nonisolated let events: AsyncStream<AgentEvent>

    private nonisolated let continuation: AsyncStream<AgentEvent>.Continuation
    private let configuration: SessionConfiguration
    private let executablePath: String

    private var translator: ClaudeCodeTranslator
    /// The current mode, which the control channel keeps in step with the
    /// running CLI and which a later spawn is launched with.
    private var permissionMode: PermissionMode
    private var process: ChildProcess?
    private var readerTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?

    /// Permission requests the CLI is currently blocked on, holding each
    /// request's original tool input. The CLI will wait indefinitely, so every
    /// one of these must be answered — including on interrupt and on shutdown.
    private var pendingPermissions: [PermissionRequestID: JSONValue] = [:]
    private var pendingControlRequests: [String: CheckedContinuation<Void, any Error>] = [:]
    private var controlRequestCounter = 0
    /// Last few stderr lines, attached to errors so a bug report explains
    /// itself without a debug build.
    private var recentStderr: [String] = []
    private var isStopping = false
    private var hasStarted = false

    public private(set) var providerSessionID: String?

    init(
        id: SessionID,
        executablePath: String,
        configuration: SessionConfiguration,
        capabilities: HarnessCapabilities
    ) {
        self.id = id
        self.executablePath = executablePath
        self.configuration = configuration
        self.permissionMode = configuration.permissionMode
        self.capabilities = capabilities
        self.translator = ClaudeCodeTranslator(sessionID: id)

        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.continuation = continuation
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard !hasStarted else { return }
        hasStarted = true

        let environment = ShellEnvironment.childEnvironment(
            overrides: configuration.environmentOverrides,
            allowProviderCredentials: configuration.allowAPIKeyFallback
        )

        let process: ChildProcess
        do {
            process = try ChildProcess(
                executablePath: executablePath,
                arguments: makeArguments(),
                workingDirectory: configuration.workingDirectory,
                environment: environment
            )
        } catch {
            let failure = SessionError(
                kind: .processFailed,
                message: "Could not start Claude Code.",
                detail: String(describing: error),
                isRecoverable: false
            )
            continuation.yield(.sessionError(failure))
            continuation.finish()
            throw error
        }
        self.process = process

        readerTask = Task { [weak self] in
            for await line in process.stdoutChunks.lines() {
                await self?.handle(line: line)
            }
            await self?.handleStdoutClosed()
        }

        stderrTask = Task { [weak self] in
            for await line in process.stderrChunks.lines() {
                await self?.recordStderr(line)
            }
        }

        lifecycleTask = Task { [weak self] in
            let status = await process.waitForExit()
            await self?.handleProcessExit(status: status)
        }

        // The handshake also tells us which slash commands this CLI build
        // exposes; failing it is not fatal, the session still works.
        try? await sendControlRequest(ClaudeControlPayload.initialize(), timeout: .seconds(10))
    }

    public func stop() async {
        guard !isStopping else { return }
        isStopping = true

        // Unblock the CLI before killing it, so it can shut its own children
        // down rather than leaving them orphaned.
        await denyAllPendingPermissions(reason: "ORE: session stopped")

        readerTask?.cancel()
        stderrTask?.cancel()
        lifecycleTask?.cancel()
        failAllPendingControlRequests(reason: "session stopped")

        if let process {
            process.closeStandardInput()
            await process.terminate()
        }
        continuation.finish()
    }

    // MARK: - Sending

    public func send(_ message: UserMessage) async throws {
        guard let process, !isStopping else { throw HarnessError.sessionEnded }
        let text = message.renderedText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let payload = ClaudeWire.UserInputMessage(text: text)
        process.writeLine(try encode(payload))
    }

    public func interrupt() async throws {
        guard capabilities.supportsInterrupt else {
            throw HarnessError.unsupportedCapability("interrupt")
        }
        guard process != nil, !isStopping else { throw HarnessError.sessionEnded }

        // A turn blocked on a permission prompt isn't running anything the CLI
        // can interrupt — deny first, then interrupt whatever remains.
        await denyAllPendingPermissions(reason: "ORE: interrupted by user")
        try await sendControlRequest(ClaudeControlPayload.interrupt(), timeout: .seconds(10))
    }

    /// Live: the CLI applies this to the tool call it is about to make, so a
    /// user who switches to Accept Edits mid-turn stops being asked from the
    /// very next edit.
    public func setPermissionMode(_ mode: PermissionMode) async throws {
        guard capabilities.supportsRuntimePermissionModeChange else {
            throw HarnessError.unsupportedCapability("permission mode changes")
        }
        // Also the flag a relaunch spawns with — a session that has not started
        // yet, or one being resumed after a crash, has no control channel to
        // carry the change and would otherwise come back on the stale mode.
        permissionMode = mode
        guard process != nil, !isStopping else { return }
        try await sendControlRequest(
            ClaudeControlPayload.setPermissionMode(mode),
            timeout: .seconds(10)
        )
    }


    public func setModel(_ model: String?) async throws {
        try await sendControlRequest(
            ClaudeControlPayload.setModel(model),
            timeout: .seconds(10)
        )
    }

    public func resolvePermission(
        _ id: PermissionRequestID,
        with decision: PermissionDecision
    ) async throws {
        guard let process else { throw HarnessError.sessionEnded }
        guard let originalInput = pendingPermissions.removeValue(forKey: id) else {
            // Already answered, or answered by a rule. Not an error: the user
            // can click Allow just as the turn is torn down.
            return
        }

        let response = ClaudeWire.ControlResponse.success(
            requestID: id.rawValue,
            payload: ClaudeControlPayload.permissionReply(
                decision: decision,
                originalInput: originalInput
            )
        )
        process.writeLine(try encode(response))
        continuation.yield(.permissionResolved(PermissionResolution(id: id, decision: decision)))
    }

    public func answerQuestion(_ id: QuestionID, answer: String) async throws {
        // Claude Code has no separate answer channel: a question is a tool call
        // whose reply is the next user message.
        try await send(UserMessage(text: answer))
    }

    // MARK: - Reading

    private func handle(line: String) async {
        let output = translator.translate(line: line)

        for event in output.events {
            if case .permissionRequest(let request) = event {
                pendingPermissions[request.id] = request.input
            }
            if case .sessionStarted(let started) = event {
                // The CLI re-announces itself when late-loading work finishes
                // (MCP servers connecting, for instance). Same conversation, so
                // report the start once — a second one would read as a new
                // session and reset the transcript.
                guard providerSessionID != started.providerSessionID else { continue }
                providerSessionID = started.providerSessionID
            }
            continuation.yield(event)
        }

        for acknowledgement in output.controlAcknowledgements {
            resumeControlRequest(
                id: acknowledgement.requestID,
                error: acknowledgement.isSuccess
                    ? nil
                    : HarnessError.transportFailure(acknowledgement.error ?? "control request failed")
            )
        }

        // Inbound control requests we don't implement still have to be
        // answered — the CLI blocks on every one of them. A line we cannot
        // decode as `can_use_tool` used to be dropped, which left the CLI
        // hung with the composer still saying "running a tool".
        switch ClaudeWire.inboundControl(in: line) {
        case .none, .permissionPrompt:
            break
        case .unsupported(let requestID, let subtype):
            replyUnsupported(requestID: requestID, subtype: subtype)
        }
    }

    private func handleStdoutClosed() async {
        guard !isStopping else { return }
        failAllPendingControlRequests(reason: "the agent closed its output stream")
    }

    private func recordStderr(_ line: String) {
        recentStderr.append(line)
        if recentStderr.count > 40 { recentStderr.removeFirst(recentStderr.count - 40) }
    }

    private func handleProcessExit(status: Int32) async {
        guard !isStopping else { return }
        isStopping = true

        let detail = recentStderr.joined(separator: "\n")
        if status != 0 {
            continuation.yield(.sessionError(classifyExit(status: status, stderr: detail)))
        }
        continuation.yield(.sessionEnded(SessionEnded(
            sessionID: id,
            exitCode: status,
            wasUnexpected: true
        )))
        failAllPendingControlRequests(reason: "the agent exited")
        continuation.finish()
    }

    /// Turns an opaque non-zero exit into something the user can act on. The
    /// two cases that actually matter are "not signed in" and "rate limited";
    /// everything else is a bug report.
    private func classifyExit(status: Int32, stderr: String) -> SessionError {
        let lowercased = stderr.lowercased()
        if lowercased.contains("not logged in")
            || lowercased.contains("authentication")
            || lowercased.contains("invalid api key")
            || lowercased.contains("please run /login") {
            return SessionError(
                kind: .notAuthenticated,
                message: "Claude Code is not signed in. Run `claude /login` in the terminal pane.",
                detail: stderr,
                isRecoverable: false
            )
        }
        if lowercased.contains("rate limit")
            || lowercased.contains("usage limit")
            || lowercased.contains("session limit") {
            return SessionError(
                kind: .rateLimited,
                message: "Claude Code hit a usage limit.",
                detail: stderr,
                isRecoverable: true
            )
        }
        return SessionError(
            kind: .processFailed,
            message: "Claude Code exited unexpectedly (status \(status)).",
            detail: stderr.isEmpty ? nil : stderr,
            isRecoverable: false
        )
    }

    // MARK: - Control channel

    private func sendControlRequest(_ request: JSONValue, timeout: Duration) async throws {
        guard let process, !isStopping else { throw HarnessError.sessionEnded }

        controlRequestCounter += 1
        let requestID = "ore_\(id.rawValue.prefix(8))_\(controlRequestCounter)"
        let envelope = ClaudeWire.ControlRequestOutbound(requestID: requestID, request: request)
        process.writeLine(try encode(envelope))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            pendingControlRequests[requestID] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.resumeControlRequest(
                    id: requestID,
                    error: HarnessError.transportFailure(
                        "timed out waiting for a control response"
                    )
                )
            }
        }
    }

    private func resumeControlRequest(id: String, error: (any Error)?) {
        guard let continuation = pendingControlRequests.removeValue(forKey: id) else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func failAllPendingControlRequests(reason: String) {
        let pending = pendingControlRequests
        pendingControlRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: HarnessError.transportFailure(reason))
        }
    }

    private func denyAllPendingPermissions(reason: String) async {
        for id in pendingPermissions.keys {
            try? await resolvePermission(id, with: .deny(reason: reason))
        }
        pendingPermissions.removeAll()
    }

    private func replyUnsupported(requestID: String, subtype: String? = nil) {
        guard let process else { return }
        let detail = subtype.map { " (\($0))" } ?? ""
        let message = "ore: unanswered claude control_request id=\(requestID) subtype=\(subtype ?? "unknown")\n"
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
        let response = ClaudeWire.ControlResponse(
            response: .init(
                subtype: "error",
                requestID: requestID,
                response: nil,
                error: "ORE does not implement this control request\(detail)"
            )
        )
        if let line = try? encode(response) { process.writeLine(line) }
    }

    // MARK: - Argument construction

    private func makeArguments() -> [String] {
        var arguments = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--include-partial-messages",
            // Required by the CLI whenever stream-json output is used with
            // --print; without it the process exits immediately with an error.
            "--verbose",
            // Routes tool approvals to our control channel instead of a TTY
            // prompt the user will never see.
            "--permission-prompt-tool", "stdio",
        ]

        if let model = configuration.model {
            arguments += ["--model", model]
        }
        arguments += ["--permission-mode", permissionMode.rawValue]

        switch configuration.resume {
        case .fresh:
            break
        case .resume(let providerSessionID):
            arguments += ["--resume", providerSessionID]
        case .fork(let providerSessionID):
            // Forking leaves the original session intact, which is what makes
            // a checkpoint revert non-destructive on the chat side.
            arguments += ["--resume", providerSessionID, "--fork-session"]
        }

        if let appendSystemPrompt = configuration.appendSystemPrompt, !appendSystemPrompt.isEmpty {
            arguments += ["--append-system-prompt", appendSystemPrompt]
        }

        if let mcp = configuration.mcpServer,
           let data = try? JSONSerialization.data(withJSONObject: [
               "mcpServers": ["ore": ["command": mcp.command, "args": mcp.arguments]],
           ]), let json = String(data: data, encoding: .utf8) {
            arguments += ["--mcp-config", json]
        }

        if !configuration.allowedTools.isEmpty {
            arguments += ["--allowedTools", configuration.allowedTools.joined(separator: ",")]
        }

        arguments += configuration.extraArguments
        return arguments
    }

    private func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw HarnessError.transportFailure("could not encode a message as UTF-8")
        }
        return string
    }
}
