import Foundation
import OreProtocol
import OreSupport

/// Persistent Cursor ACP session: `agent acp` over newline-delimited JSON-RPC.
///
/// Print stream-json is one-shot and cannot answer a permission prompt. ACP is
/// the documented client protocol on current CLIs (`agent acp --help`), so this
/// driver is what gives Cursor the same live approvals, plans, questions, and
/// thinking stream the other harnesses already have.
public actor CursorACPSession: AgentSession {
    public nonisolated let id: SessionID
    public nonisolated let harness: HarnessKind = .cursorAgent
    public nonisolated let capabilities: HarnessCapabilities
    public nonisolated let events: AsyncStream<AgentEvent>

    private nonisolated let continuation: AsyncStream<AgentEvent>.Continuation
    private let configuration: SessionConfiguration
    private let executablePath: String
    private let allowUnprompted: Bool

    private var translator: CursorACPTranslator
    private var process: ChildProcess?
    private var connection: JSONRPCConnection?
    private var incomingTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var recentStderr: [String] = []
    private var isStopping = false
    private var hasStarted = false
    private var permissionMode: PermissionMode
    private var pendingApprovals: [PermissionRequestID: (id: JSONValue, method: String, params: JSONValue?)] = [:]
    private var pendingQuestions: [QuestionID: (id: JSONValue, params: JSONValue?)] = [:]
    private var pendingPlanApprovals: [PermissionRequestID: JSONValue] = [:]

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
        self.translator = CursorACPTranslator(sessionID: id)

        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.continuation = continuation
    }

    public func start() async throws {
        guard !hasStarted else { return }
        hasStarted = true

        let launch = CursorAgentPrivacyBoundary.launchCommand(
            executablePath: executablePath,
            arguments: ["acp"],
            workingDirectory: configuration.workingDirectory,
            additionalAllowedRoots: configuration.additionalWritableRoots
        )
        let process = try ChildProcess(
            executablePath: launch.executablePath,
            arguments: launch.arguments,
            workingDirectory: configuration.workingDirectory,
            environment: ShellEnvironment.childEnvironment(
                overrides: configuration.environmentOverrides,
                allowProviderCredentials: configuration.allowAPIKeyFallback
            )
        )
        self.process = process

        let connection = JSONRPCConnection(process: process)
        self.connection = connection
        await connection.start()

        incomingTask = Task { [weak self] in
            for await incoming in connection.incoming {
                await self?.handle(incoming)
            }
        }
        stderrTask = Task { [weak self, process] in
            for await line in process.stderrChunks.lines() {
                await self?.recordStderr(line)
            }
        }

        _ = try await connection.send(
            method: "initialize",
            params: .object([
                "protocolVersion": .integer(1),
                "clientInfo": .object([
                    "name": .string("ore"),
                    "title": .string("ORE"),
                    "version": .string(OreVersion.current),
                ]),
                "clientCapabilities": .object([
                    "fs": .object([
                        "readTextFile": .bool(false),
                        "writeTextFile": .bool(false),
                    ]),
                    "terminal": .bool(false),
                    "session": .object([
                        "compaction": .object([:]),
                        "notices": .object([:]),
                    ]),
                ]),
            ]),
            timeout: .seconds(30)
        )

        // Pre-authenticated CLIs treat this as a no-op; a missing login is a
        // real error and should fail the session rather than hang on tools.
        do {
            _ = try await connection.send(
                method: "authenticate",
                params: .object(["methodId": .string("cursor_login")]),
                timeout: .seconds(30)
            )
        } catch {
            if !isAlreadyAuthenticated(error) { throw error }
        }

        try await openSession(connection: connection)
    }

    private func openSession(connection: JSONRPCConnection) async throws {
        var params: [String: JSONValue] = [
            "cwd": .string(configuration.workingDirectory.path),
            "mcpServers": .array(mcpServers()),
        ]
        if let model = configuration.model {
            params["model"] = .string(model)
        }
        params["mode"] = .string(CursorACPTranslator.acpMode(for: permissionMode))

        let method: String
        switch configuration.resume {
        case .fresh:
            method = "session/new"
        case .resume(let providerSessionID), .fork(let providerSessionID):
            // ACP has no fork; resume is the honest remaining option.
            method = "session/load"
            params["sessionId"] = .string(providerSessionID)
        }

        let result = try await connection.send(
            method: method, params: .object(params), timeout: .seconds(60)
        )
        let sessionID = result["sessionId"]?.stringValue
            ?? result["session_id"]?.stringValue
            ?? configuration.resume.existingID
            ?? ""
        providerSessionID = sessionID
        emit(translator.noteSession(
            id: sessionID,
            workingDirectory: configuration.workingDirectory.path,
            model: configuration.model,
            permissionMode: permissionMode
        ))
    }

    public func send(_ message: UserMessage) async throws {
        guard let connection, let sessionID = providerSessionID, !isStopping else {
            throw HarnessError.sessionEnded
        }
        let text = message.renderedText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        emit(translator.beginTurn())
        let result = try await connection.send(
            method: "session/prompt",
            params: .object([
                "sessionId": .string(sessionID),
                "prompt": .array([.object([
                    "type": .string("text"),
                    "text": .string(text),
                ])]),
            ]),
            timeout: .seconds(86_400)
        )
        emit(translator.finishTurn(stopReason: result["stopReason"]?.stringValue))
    }

    public func interrupt() async throws {
        guard let connection, let sessionID = providerSessionID else { return }
        await cancelPending(reason: "interrupted")
        try await connection.notify(
            method: "session/cancel",
            params: .object(["sessionId": .string(sessionID)])
        )
        continuation.yield(.statusChanged(.interrupted))
    }

    public func setPermissionMode(_ mode: PermissionMode) async throws {
        permissionMode = mode
        guard let connection, let sessionID = providerSessionID else { return }
        _ = try? await connection.send(
            method: "session/set_mode",
            params: .object([
                "sessionId": .string(sessionID),
                "modeId": .string(CursorACPTranslator.acpMode(for: mode)),
            ]),
            timeout: .seconds(10)
        )
    }

    public func resolvePermission(
        _ id: PermissionRequestID,
        with decision: PermissionDecision
    ) async throws {
        if let jsonID = pendingPlanApprovals.removeValue(forKey: id) {
            let accepted = if case .deny = decision { false } else { true }
            let reason = if case .deny(let reason) = decision { reason } else { nil as String? }
            try await connection?.respond(
                to: jsonID,
                result: CursorACPTranslator.planOutcome(accepted: accepted, reason: reason)
            )
            continuation.yield(.permissionResolved(PermissionResolution(id: id, decision: decision)))
            return
        }
        guard let pending = pendingApprovals.removeValue(forKey: id) else { return }
        try await connection?.respond(
            to: pending.id,
            result: CursorACPTranslator.permissionOutcome(for: decision, params: pending.params)
        )
        continuation.yield(.permissionResolved(PermissionResolution(id: id, decision: decision)))
    }

    public func answerQuestion(_ id: QuestionID, answer: String) async throws {
        guard let pending = pendingQuestions.removeValue(forKey: id) else {
            try await send(UserMessage(text: answer))
            return
        }
        try await connection?.respond(
            to: pending.id,
            result: CursorACPTranslator.questionOutcome(params: pending.params, answer: answer)
        )
    }

    public func stop() async {
        guard !isStopping else { return }
        isStopping = true
        await cancelPending(reason: "session ended")
        incomingTask?.cancel()
        stderrTask?.cancel()
        await connection?.stop()
        if let process { await process.terminate() }
        process = nil
        connection = nil
        continuation.finish()
    }

    // MARK: - Incoming

    private func handle(_ incoming: JSONRPCConnection.Incoming) async {
        switch incoming {
        case .notification(let notification):
            emit(translator.translate(method: notification.method, params: notification.params))

        case .request(let request):
            await handleServerRequest(request)

        case .closed:
            guard !isStopping else { return }
            isStopping = true
            continuation.yield(.sessionError(SessionError(
                kind: .processFailed,
                message: "Cursor Agent exited unexpectedly.",
                detail: recentStderr.joined(separator: "\n"),
                isRecoverable: false
            )))
            continuation.yield(.sessionEnded(SessionEnded(
                sessionID: id, exitCode: process?.terminationStatus, wasUnexpected: true
            )))
            continuation.finish()
        }
    }

    private func handleServerRequest(_ request: JSONRPCConnection.Request) async {
        switch request.method {
        case "session/request_permission":
            if allowUnprompted, permissionMode == .bypassPermissions {
                try? await connection?.respond(
                    to: request.id,
                    result: CursorACPTranslator.permissionOutcome(
                        for: .allowWithSuggestion(.object(["optionId": .string("allow-always")])),
                        params: request.params
                    )
                )
                return
            }
            guard let permission = translator.permissionRequest(
                params: request.params, requestID: requestIDString(request.id)
            ) else {
                respondUnsupported(request)
                return
            }
            pendingApprovals[permission.id] = (request.id, request.method, request.params)
            continuation.yield(.permissionRequest(permission))
            continuation.yield(.statusChanged(.awaitingInput))

        case "cursor/ask_question":
            guard let question = translator.question(
                params: request.params, requestID: requestIDString(request.id)
            ) else {
                respondUnsupported(request)
                return
            }
            pendingQuestions[question.id] = (request.id, request.params)
            continuation.yield(.question(question))
            continuation.yield(.statusChanged(.awaitingInput))

        case "cursor/create_plan":
            guard let (update, permission) = translator.planProposal(
                params: request.params, requestID: requestIDString(request.id)
            ) else {
                try? await connection?.respond(
                    to: request.id,
                    result: CursorACPTranslator.planOutcome(accepted: false, reason: "empty plan")
                )
                return
            }
            pendingPlanApprovals[permission.id] = request.id
            continuation.yield(.planUpdated(update))
            continuation.yield(.permissionRequest(permission))
            continuation.yield(.statusChanged(.awaitingInput))

        default:
            respondUnsupported(request)
        }
    }

    private func respondUnsupported(_ request: JSONRPCConnection.Request) {
        Task { [connection] in
            try? await connection?.respond(
                to: request.id,
                error: "ORE does not implement \(request.method)"
            )
        }
    }

    private func cancelPending(reason: String) async {
        for (_, pending) in pendingApprovals {
            try? await connection?.respond(
                to: pending.id,
                result: CursorACPTranslator.cancelledPermissionOutcome()
            )
        }
        pendingApprovals.removeAll()
        for (_, jsonID) in pendingPlanApprovals {
            try? await connection?.respond(
                to: jsonID,
                result: CursorACPTranslator.planOutcome(accepted: false, reason: reason)
            )
        }
        pendingPlanApprovals.removeAll()
        for (_, pending) in pendingQuestions {
            try? await connection?.respond(
                to: pending.id,
                result: .object(["outcome": .object(["outcome": .string("cancelled")])])
            )
        }
        pendingQuestions.removeAll()
    }

    private func emit(_ output: CursorACPTranslator.Output) {
        for event in output.events { continuation.yield(event) }
        if let providerSessionID = translator.providerSessionID {
            self.providerSessionID = providerSessionID
        }
    }

    private func recordStderr(_ line: String) {
        recentStderr.append(line)
        if recentStderr.count > 40 { recentStderr.removeFirst(recentStderr.count - 40) }
    }

    private func mcpServers() -> [JSONValue] {
        guard let mcp = configuration.mcpServer else { return [] }
        return [.object([
            "name": .string("ore"),
            "command": .string(mcp.command),
            "args": .array(mcp.arguments.map(JSONValue.string)),
            "env": .array([]),
        ])]
    }

    private func requestIDString(_ id: JSONValue) -> String {
        id.stringValue ?? id.intValue.map(String.init) ?? id.description
    }

    private func isAlreadyAuthenticated(_ error: any Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("already") || text.contains("authenticated")
    }
}

extension SessionRequest.ResumeMode {
    fileprivate var existingID: String? {
        switch self {
        case .fresh: return nil
        case .resume(let id), .fork(let id): return id
        }
    }
}
