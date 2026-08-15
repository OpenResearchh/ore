import Foundation
import OreProtocol
import OreSupport

/// Cursor's agent CLI, exposing Grok and Cursor's other models on the user's
/// own Cursor plan.
///
/// **Experimental, and behind a flag.** The plan for this driver assumed an ACP
/// mode with a real `session/request_permission` channel; the shipping CLI has
/// no such subcommand, so the only machine-readable interface is
/// `--print --output-format stream-json`, which streams output but offers no
/// way to answer a permission prompt.
///
/// That is a genuine capability gap, not a detail to paper over. It is also not
/// a reason to ship an agent that silently cannot work: with no approval
/// channel *and* no approval policy, the CLI rejects every shell and write call
/// — the turn returns `result: {rejected: …}` and the agent reports it was
/// "blocked by the environment". So this driver passes `--auto-review`, whose
/// server-side classifier runs the safe calls and refuses the rest. That is a
/// real policy the user can reason about, unlike `--force`, which runs anything
/// at all and therefore still requires an explicit opt-in.
///
/// `permissionModel` stays `.none`: the UI must not offer an approve button
/// there is no channel to answer on.
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
    /// Opt-in, never inferred. Escalates the tool policy from `--auto-review`
    /// (a classifier decides) to `--force` (anything runs), which is a choice
    /// only the user can make.
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
            diagnostic: "Experimental: this CLI has no approval channel. Tool "
                + "calls are decided by Cursor's auto-review classifier"
                + (allowUnprompted ? ", or run unprompted in Bypass mode." : ".")
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

        // The CLI takes several seconds to boot before its first JSON line.
        // Reflect activity immediately so the UI isn't blank meanwhile; the
        // translator's real events take over once the process starts talking.
        continuation.yield(.statusChanged(.requesting))

        let process: ChildProcess
        do {
            process = try ChildProcess(
                executablePath: executablePath,
                arguments: arguments(for: message.renderedText),
                workingDirectory: configuration.workingDirectory,
                environment: ShellEnvironment.childEnvironment(
                    overrides: configuration.environmentOverrides,
                    allowProviderCredentials: configuration.allowAPIKeyFallback
                )
            )
        } catch {
            // Undo the optimistic status or the spinner runs forever.
            continuation.yield(.statusChanged(.failed))
            throw error
        }
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
        // A tool policy is not optional here. There is no approval channel, so
        // without one of these flags every shell and write call comes back
        // `rejected` and the agent can only read — which reads to the user as
        // "the agent is broken", not "the agent asked and nobody answered".
        //
        // `--force` runs anything and so stays behind the explicit opt-in;
        // `--auto-review` is the default because refusing on a classifier's
        // judgement is a policy, whereas refusing everything is a defect.
        if allowUnprompted, configuration.permissionMode == .bypassPermissions {
            arguments.append("--force")
        } else if configuration.permissionMode != .plan {
            arguments.append("--auto-review")
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
