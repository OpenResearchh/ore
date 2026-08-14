import Foundation
import OreProtocol
import OreSupport

/// Cursor's agent CLI, exposing Grok and Cursor's other models on the user's
/// own Cursor plan.
///
/// **Experimental, and behind a flag.** The plan for this driver assumed an ACP
/// mode with a real `session/request_permission` channel; the shipping CLI
/// (2026.04) has no such subcommand, so the only machine-readable interface is
/// `--print --output-format stream-json`, which streams output but offers no
/// way to answer a permission prompt.
///
/// That is a genuine capability gap, not a detail to paper over. The honest
/// options were to auto-pass `--force` — which would let an agent run any
/// command with no prompt the user ever saw — or to declare the gap and let the
/// UI degrade. This driver does the latter: `permissionModel` is `.none`, and
/// running without prompts requires the user to opt in explicitly.
public struct CursorAgentHarness: AgentHarness {
    public let kind: HarnessKind = .cursorAgent

    public var capabilities: HarnessCapabilities {
        HarnessCapabilities(
            // `--mode plan` is read-only, but there's no plan-approval
            // round trip to hang an approve button on.
            supportsPlanMode: false,
            supportsSteering: false,
            supportsInterrupt: true,
            supportsResume: true,
            supportsSessionFork: false,
            supportsThinkingStream: true,
            supportsPartialMessages: true,
            supportsRuntimePermissionModeChange: false,
            supportsCustomTools: false,
            // No interactive approval channel exists in this CLI version.
            permissionModel: .none,
            usageGranularity: .perTurn
        )
    }

    public var executablePathOverride: String?
    /// Opt-in, never inferred. Without it the agent cannot run tools that need
    /// approval, and the UI says so.
    public var allowUnprompted: Bool

    public init(executablePathOverride: String? = nil, allowUnprompted: Bool = false) {
        self.executablePathOverride = executablePathOverride
        self.allowUnprompted = allowUnprompted
    }

    public func probe() async -> HarnessProbeResult {
        guard let path = resolveExecutablePath() else {
            return HarnessProbeResult(
                kind: kind,
                authState: .notAuthenticated,
                diagnostic: "Not found on PATH (\(ShellEnvironment.searchPathDescription))"
            )
        }

        let version = await CommandProbe.firstLine(
            executablePath: path, arguments: ["--version"], timeout: .seconds(10)
        )
        let status = await CommandProbe.output(
            executablePath: path, arguments: ["status"], timeout: .seconds(15)
        )

        let authState: HarnessProbeResult.AuthState
        switch status?.lowercased() {
        case let text? where text.contains("not logged in"): authState = .notAuthenticated
        case let text? where text.contains("logged in"): authState = .authenticated
        default: authState = .unknown
        }

        return HarnessProbeResult(
            kind: kind,
            executablePath: path,
            version: version,
            authState: authState,
            diagnostic: "Experimental: this CLI has no approval channel, so tool "
                + "permissions cannot be prompted for."
        )
    }

    /// The account's real model catalog, straight from the CLI. Without this the
    /// UI fell back to a stale two-item hardcoded list (just `grok-4`), so newer
    /// models — Composer 2.5, Cursor Grok 4.5/4.6, and everything else the plan
    /// includes — never appeared. `cursor-agent --list-models` prints one
    /// `id - Display Name` per line under an "Available models" banner.
    public func discoverModels() async -> [AgentModel] {
        guard let path = resolveExecutablePath() else { return [] }
        guard let output = await CommandProbe.output(
            executablePath: path, arguments: ["--list-models"], timeout: .seconds(15)
        ) else { return [] }

        var models: [AgentModel] = []
        var seen: Set<String> = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Only lines shaped like `id - Name` are models; the banner isn't.
            guard let separator = line.range(of: " - ") else { continue }
            let id = line[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !id.contains(" "), seen.insert(id).inserted else { continue }
            var name = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            let isDefault = name.localizedCaseInsensitiveContains("(default)")
            if isDefault {
                name = name.replacingOccurrences(
                    of: "(default)", with: "", options: .caseInsensitive
                ).trimmingCharacters(in: .whitespaces)
            }
            models.append(AgentModel(
                id: id, displayName: name.isEmpty ? id : name, isDefault: isDefault
            ))
        }
        return models
    }

    public func makeSession(_ configuration: SessionConfiguration) async throws -> any AgentSession {
        guard let path = configuration.executablePath ?? resolveExecutablePath() else {
            throw HarnessError.executableNotFound(
                kind, searchedPath: ShellEnvironment.searchPathDescription
            )
        }
        return CursorAgentSession(
            id: SessionID.generate(),
            executablePath: path,
            configuration: configuration,
            capabilities: capabilities,
            allowUnprompted: allowUnprompted
        )
    }

    private func resolveExecutablePath() -> String? {
        if let executablePathOverride { return executablePathOverride }
        return ShellEnvironment.locate(kind.defaultExecutableName)
    }
}

/// One cursor-agent turn.
///
/// The CLI is one-shot: `--print` runs a single prompt and exits. There is no
/// persistent stdin protocol, so a "session" here is a chat id that each turn
/// resumes, and a turn is a fresh process.
public actor CursorAgentSession: AgentSession {
    public nonisolated let id: SessionID
    public nonisolated let harness: HarnessKind = .cursorAgent
    public nonisolated let capabilities: HarnessCapabilities
    public nonisolated let events: AsyncStream<AgentEvent>

    private nonisolated let continuation: AsyncStream<AgentEvent>.Continuation
    private let configuration: SessionConfiguration
    private let executablePath: String
    private let allowUnprompted: Bool

    private var translator: CursorAgentTranslator
    private var currentProcess: ChildProcess?
    private var turnTask: Task<Void, Never>?
    private var isStopping = false

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
        self.capabilities = capabilities
        self.allowUnprompted = allowUnprompted
        self.translator = CursorAgentTranslator(sessionID: id)

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
        // Nothing to spawn until there's a prompt: the CLI has no idle mode.
        continuation.yield(.statusChanged(.idle))
    }

    public func send(_ message: UserMessage) async throws {
        guard !isStopping else { throw HarnessError.sessionEnded }
        guard currentProcess == nil else {
            // No steering: a running turn owns the process until it exits.
            throw HarnessError.unsupportedCapability("sending while a turn is running")
        }

        let process = try ChildProcess(
            executablePath: executablePath,
            arguments: arguments(for: message.renderedText),
            workingDirectory: configuration.workingDirectory,
            environment: ShellEnvironment.childEnvironment(
                overrides: configuration.environmentOverrides,
                allowProviderCredentials: configuration.allowAPIKeyFallback
            )
        )
        currentProcess = process
        process.closeStandardInput()

        turnTask = Task { [weak self] in
            for await line in process.stdoutChunks.lines() {
                await self?.handle(line: line)
            }
            await self?.finishTurn(status: await process.waitForExit())
        }
    }

    private func arguments(for prompt: String) -> [String] {
        var arguments = [
            "--print",
            "--output-format", "stream-json",
            "--stream-partial-output",
            "--workspace", configuration.workingDirectory.path,
            // Headless, so there is no dialog to trust the workspace in.
            "--trust",
        ]
        if let model = configuration.model {
            arguments += ["--model", model]
        }
        if configuration.permissionMode == .plan {
            arguments += ["--mode", "plan"]
        }
        if let providerSessionID {
            arguments += ["--resume", providerSessionID]
        }
        // Never inferred from a permission mode: an agent running any command
        // with no prompt has to be something the user chose.
        if allowUnprompted, configuration.permissionMode == .bypassPermissions {
            arguments.append("--force")
        }
        arguments += configuration.extraArguments
        arguments.append(prompt)
        return arguments
    }

    private func handle(line: String) {
        let output = translator.translate(line: line)
        for event in output.events {
            if case .sessionStarted(let started) = event {
                providerSessionID = started.providerSessionID
            }
            continuation.yield(event)
        }
    }

    private func finishTurn(status: Int32) {
        currentProcess = nil
        for event in translator.closeTurn(exitCode: status).events {
            continuation.yield(event)
        }
    }

    public func interrupt() async throws {
        guard let process = currentProcess else { return }
        await process.terminate(gracePeriod: .seconds(2))
        currentProcess = nil
        continuation.yield(.statusChanged(.interrupted))
    }

    public func setPermissionMode(_ mode: PermissionMode) async throws {
        throw HarnessError.unsupportedCapability("permission mode changes")
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
        turnTask?.cancel()
        if let currentProcess { await currentProcess.terminate() }
        currentProcess = nil
        continuation.finish()
    }
}
