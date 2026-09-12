import Foundation
import OreProtocol
import OreSupport

/// Drives one Codex conversation through `codex app-server`.
///
/// The app-server is the official rich interface — JSON-RPC over stdio, with
/// thread and turn lifecycles, streamed deltas and approval callbacks — so ORE
/// speaks it rather than scraping the interactive TUI. Auth comes from the
/// user's `codex login` (a ChatGPT plan), exactly as with Claude Code.
public actor CodexSession: AgentSession {
    public nonisolated let id: SessionID
    public nonisolated let harness: HarnessKind = .codex
    public nonisolated let capabilities: HarnessCapabilities
    public nonisolated let events: AsyncStream<AgentEvent>

    private nonisolated let continuation: AsyncStream<AgentEvent>.Continuation
    private let configuration: SessionConfiguration
    private let executablePath: String

    private var translator: CodexTranslator
    private var process: ChildProcess?
    private var connection: JSONRPCConnection?
    private var incomingTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    /// Approval requests the agent is blocked on, keyed by our permission id and
    /// holding the JSON-RPC id we must reply to.
    private var pendingApprovals: [PermissionRequestID: (id: JSONValue, method: String)] = [:]
    private var pendingQuestions: [QuestionID: JSONValue] = [:]
    private var recentStderr: [String] = []
    private var isStopping = false
    private var hasStarted = false
    private var currentModel: String?
    private var hasModelOverride: Bool
    /// The posture the next turn starts under. Codex binds sandbox and approval
    /// policy per turn, so a change made mid-chat is carried here and applied
    /// on the next `turn/start` rather than needing a new thread.
    private var permissionMode: PermissionMode
    /// Whether the user changed the mode after the thread was started. Only
    /// then does `turn/start` carry the override params — an untouched chat
    /// keeps running on exactly the policy `thread/start` established.
    private var hasPermissionOverride = false

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
        self.currentModel = configuration.model
        self.hasModelOverride = configuration.model != nil
        self.permissionMode = configuration.permissionMode
        self.capabilities = capabilities
        self.translator = CodexTranslator(sessionID: id)

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

        let process = try ChildProcess(
            executablePath: executablePath,
            arguments: ["app-server"],
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
                "clientInfo": .object([
                    "name": .string("ore"),
                    "title": .string("ORE"),
                    "version": .string(OreVersion.current),
                ]),
            ]),
            timeout: .seconds(30)
        )
        try await connection.notify(method: "initialized", params: .object([:]))

        try await openThread(connection: connection)
    }

    private func openThread(connection: JSONRPCConnection) async throws {
        var params: [String: JSONValue] = [
            "cwd": .string(configuration.workingDirectory.path),
            // Source writes stay rooted at the worktree. The config below adds
            // only its linked Git administrative root so ordinary Git commands
            // can update the index, object store, and this worktree's ref.
            "sandbox": .string(sandboxMode()),
            "approvalPolicy": .string(approvalPolicy()),
        ]
        var config: [String: JSONValue] = [:]
        if let model = configuration.model { config["model"] = .string(model) }
        if !configuration.additionalWritableRoots.isEmpty {
            config["sandbox_workspace_write"] = Self.workspaceWriteConfiguration(
                writableRoots: configuration.additionalWritableRoots
            )
        }
        if let mcp = configuration.mcpServer {
            config["mcp_servers"] = .object([
                "ore": Self.mcpServerConfiguration(
                    mcp,
                    allowedTools: configuration.allowedTools
                ),
            ])
        }
        if !config.isEmpty { params["config"] = .object(config) }
        if let appendSystemPrompt = configuration.appendSystemPrompt {
            params["developerInstructions"] = .string(appendSystemPrompt)
        }

        let method: String
        switch configuration.resume {
        case .fresh:
            method = "thread/start"
        case .resume(let providerSessionID):
            method = "thread/resume"
            params["threadId"] = .string(providerSessionID)
        case .fork(let providerSessionID):
            // Forking leaves the original thread intact — the chat half of a
            // checkpoint revert.
            method = "thread/fork"
            params["threadId"] = .string(providerSessionID)
        }

        let result = try await connection.send(
            method: method, params: .object(params), timeout: .seconds(60)
        )
        let output = translator.translate(method: "thread/started", params: result)
        emit(output)
        providerSessionID = translator.threadID
    }

    /// Plan mode is read-only, so it maps onto the sandbox rather than onto the
    /// approval policy: the agent can research and propose, and cannot write.
    private func sandboxMode() -> String {
        switch permissionMode {
        case .plan: return "read-only"
        case .bypassPermissions: return "danger-full-access"
        case .default, .acceptEdits: return "workspace-write"
        }
    }

    /// The same posture as `sandboxMode`, in the tagged shape `turn/start`
    /// takes. `thread/start` names the sandbox by mode; a per-turn override
    /// names it by policy object.
    private func sandboxPolicy() -> JSONValue {
        Self.sandboxPolicy(
            permissionMode: permissionMode,
            writableRoots: configuration.additionalWritableRoots
        )
    }

    static func sandboxPolicy(
        permissionMode: PermissionMode,
        writableRoots: [URL]
    ) -> JSONValue {
        switch permissionMode {
        case .plan: return .object(["type": .string("readOnly")])
        case .bypassPermissions: return .object(["type": .string("dangerFullAccess")])
        case .default, .acceptEdits:
            var policy: [String: JSONValue] = ["type": .string("workspaceWrite")]
            if !writableRoots.isEmpty {
                policy["writableRoots"] = .array(normalizedPaths(writableRoots).map(JSONValue.string))
            }
            return .object(policy)
        }
    }

    /// App-server's thread config uses snake_case while per-turn sandbox
    /// policies use camelCase. Keep both encodings beside each other so adding
    /// a root at thread creation cannot be lost after a permission-mode change.
    static func workspaceWriteConfiguration(writableRoots: [URL]) -> JSONValue {
        .object([
            "writable_roots": .array(normalizedPaths(writableRoots).map(JSONValue.string)),
        ])
    }

    private static func normalizedPaths(_ roots: [URL]) -> [String] {
        var seen: Set<String> = []
        return roots.compactMap {
            let path = $0.standardizedFileURL.resolvingSymlinksInPath().path
            return seen.insert(path).inserted ? path : nil
        }
    }

    private func approvalPolicy() -> String {
        Self.approvalPolicy(permissionMode: permissionMode)
    }

    /// Only Bypass silences Codex.
    ///
    /// Accept Edits means "don't stop me for file edits", which the
    /// `workspace-write` sandbox already delivers — it must not also mean "run
    /// anything without asking". Mapping it to `never` did exactly that: Codex
    /// stopped sending approval requests, so ORE's shell classifier, the
    /// routine-approval setting and the `ore` MCP boundary were never consulted
    /// and every command ran unasked, on the one harness where the Assistant's
    /// own prompt promises the opposite.
    static func approvalPolicy(permissionMode: PermissionMode) -> String {
        switch permissionMode {
        case .bypassPermissions: return "never"
        case .plan, .default, .acceptEdits: return "on-request"
        }
    }

    /// The Assistant may invoke its product-owned ORE server without a second
    /// Codex approval. ORE still evaluates every requested action through its
    /// own action policy, while shell/editor tools retain the chat's normal
    /// approval posture.
    static func mcpServerConfiguration(
        _ mcp: SessionConfiguration.MCPServer,
        allowedTools: [String]
    ) -> JSONValue {
        var server: [String: JSONValue] = [
            "command": .string(mcp.command),
            "args": .array(mcp.arguments.map(JSONValue.string)),
        ]
        if allowedTools.contains(where: {
            $0 == "mcp__ore" || $0.hasPrefix("mcp__ore__")
        }) {
            server["default_tools_approval_mode"] = .string("approve")
        }
        return .object(server)
    }

    public func stop() async {
        guard !isStopping else { return }
        isStopping = true

        await denyAllPendingApprovals()
        incomingTask?.cancel()
        stderrTask?.cancel()
        await connection?.stop()

        if let process {
            process.closeStandardInput()
            await process.terminate()
        }
        continuation.finish()
    }

    // MARK: - Sending

    public func send(_ message: UserMessage) async throws {
        guard let connection, let threadID = translator.threadID, !isStopping else {
            throw HarnessError.sessionEnded
        }
        let text = message.renderedText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let input: JSONValue = .array([.object([
            "type": .string("text"),
            "text": .string(text),
        ])])

        // Steering an in-flight turn is a different call, and it needs the id
        // of the turn it expects to be steering.
        if let providerTurnID = translator.providerTurnID {
            _ = try await connection.send(
                method: "turn/steer",
                params: .object([
                    "threadId": .string(threadID),
                    "expectedTurnId": .string(providerTurnID),
                    "input": input,
                ])
            )
            return
        }

        var parameters: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": input,
        ]
        if hasModelOverride {
            parameters["model"] = currentModel.map(JSONValue.string) ?? .null
        }
        // The only place a mid-chat permission change can land: both fields
        // override "this turn and subsequent turns". Sandbox alone would not be
        // enough — Accept Edits and Ask share a sandbox and differ only in
        // whether Codex stops to ask.
        if hasPermissionOverride {
            parameters["sandboxPolicy"] = sandboxPolicy()
            parameters["approvalPolicy"] = .string(approvalPolicy())
        }
        if let effort = message.reasoningEffort {
            // Current ChatGPT Codex models reject `max` (supported: none…xhigh).
            // Map a leftover Max from an older catalog/UI default onto xhigh so a
            // turn is not rejected after a model remap.
            let value = effort == .max ? ReasoningEffort.xhigh.rawValue : effort.rawValue
            parameters["effort"] = .string(value)
        }
        // App-server v2 keeps the tier on the thread for this and subsequent
        // turns. Sending an explicit null when Fast is off clears a previous
        // override rather than accidentally leaving the conversation fast.
        parameters["serviceTier"] = message.serviceTier.map(JSONValue.string) ?? .null

        _ = try await connection.send(
            method: "turn/start",
            params: .object(parameters),
            // Starting a turn can remain outstanding while Codex is working.
            // A UI transport timeout must never cancel a legitimate long turn.
            timeout: .seconds(86_400)
        )
    }

    public func interrupt() async throws {
        guard let connection, let threadID = translator.threadID else {
            throw HarnessError.sessionEnded
        }
        await denyAllPendingApprovals()
        guard let providerTurnID = translator.providerTurnID else { return }

        _ = try await connection.send(
            method: "turn/interrupt",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(providerTurnID),
            ]),
            timeout: .seconds(15)
        )
    }

    /// Accepted at any point in the chat, and applied on the next `turn/start`.
    ///
    /// There is no live channel for this: `thread/metadata/update` only patches
    /// git metadata, so the version of this that called it was writing to a
    /// field the app-server ignores and the mode never actually changed. The
    /// per-turn override is the real mechanism, and it is enough — a change
    /// made while a turn runs binds the next one, without a new chat.
    public func setPermissionMode(_ mode: PermissionMode) async throws {
        guard mode != permissionMode else { return }
        permissionMode = mode
        hasPermissionOverride = true
    }

    public func setModel(_ model: String?) async throws {
        currentModel = model
        hasModelOverride = true
    }

    public func resolvePermission(
        _ id: PermissionRequestID,
        with decision: PermissionDecision
    ) async throws {
        guard let connection,
              let pending = pendingApprovals.removeValue(forKey: id)
        else { return }

        let value = CodexApprovalDecision.value(for: decision, method: pending.method)
        try await connection.respond(
            to: pending.id,
            result: .object(["decision": .string(value)])
        )
        continuation.yield(.permissionResolved(PermissionResolution(id: id, decision: decision)))
    }

    public func answerQuestion(_ id: QuestionID, answer: String) async throws {
        guard let connection, let requestID = pendingQuestions.removeValue(forKey: id) else {
            // No outstanding request: fall back to an ordinary message so the
            // user's answer isn't silently dropped.
            try await send(UserMessage(text: answer))
            return
        }
        try await connection.respond(
            to: requestID,
            result: .object([
                "answers": .object([
                    id.rawValue: .object(["answers": .array([.string(answer)])]),
                ]),
            ])
        )
    }

    // MARK: - Incoming

    private func handle(_ incoming: JSONRPCConnection.Incoming) async {
        switch incoming {
        case .notification(let notification):
            let output = translator.translate(
                method: notification.method, params: notification.params
            )
            emit(output)
            if translator.threadID != nil { providerSessionID = translator.threadID }

        case .request(let request):
            await handleServerRequest(request)

        case .closed:
            guard !isStopping else { return }
            isStopping = true
            continuation.yield(.sessionError(SessionError(
                kind: .processFailed,
                message: "Codex exited unexpectedly.",
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
        let requestID = request.id.stringValue ?? request.id.description

        if let permission = translator.permissionRequest(
            method: request.method, params: request.params, requestID: requestID
        ) {
            pendingApprovals[permission.id] = (request.id, request.method)
            continuation.yield(.permissionRequest(permission))
            continuation.yield(.statusChanged(.awaitingInput))
            return
        }

        if request.method == "item/tool/requestUserInput" {
            let questions = translator.question(params: request.params, requestID: requestID)
            guard !questions.isEmpty else {
                respondUnsupported(request)
                return
            }
            for question in questions {
                pendingQuestions[question.id] = request.id
                continuation.yield(.question(question))
            }
            continuation.yield(.statusChanged(.awaitingInput))
            return
        }

        respondUnsupported(request)
    }

    /// Every server request blocks the agent until it's answered, including the
    /// ones we don't implement.
    private func respondUnsupported(_ request: JSONRPCConnection.Request) {
        Task { [connection] in
            try? await connection?.respond(
                to: request.id,
                error: "ORE does not implement \(request.method)"
            )
        }
    }

    private func emit(_ output: CodexTranslator.Output) {
        for event in output.events {
            continuation.yield(event)
        }
    }

    private func recordStderr(_ line: String) {
        recentStderr.append(line)
        if recentStderr.count > 40 { recentStderr.removeFirst(recentStderr.count - 40) }
    }

    private func denyAllPendingApprovals() async {
        for id in pendingApprovals.keys {
            try? await resolvePermission(id, with: .deny(reason: "ORE: cancelled by the user"))
        }
        pendingApprovals.removeAll()
    }
}

/// Codex uses a different decision vocabulary per approval method.
enum CodexApprovalDecision {
    static func value(for decision: PermissionDecision, method: String) -> String {
        // The older `execCommandApproval` / `applyPatchApproval` methods use
        // `approved`/`denied`; the item-scoped ones use `accept`/`decline`.
        let isLegacy = method == "execCommandApproval" || method == "applyPatchApproval"
        switch decision {
        case .allow, .allowWithSuggestion: return isLegacy ? "approved" : "accept"
        case .deny: return isLegacy ? "denied" : "decline"
        }
    }
}

public enum OreVersion {
    public static let current = "0.1.0"
}
