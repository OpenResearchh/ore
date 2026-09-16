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
    static let executableNames = ["cursor-agent", "agent"]

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
        guard let resolved = resolveExecutable() else {
            return HarnessProbeResult(
                kind: kind,
                authState: .notAuthenticated,
                diagnostic: "Not found on PATH (\(ShellEnvironment.searchPathDescription))"
            )
        }
        let path = resolved.path

        let version = await CommandProbe.firstLine(
            executablePath: path, arguments: ["--version"], timeout: .seconds(10)
        )

        // `agent` is a name anything can have. Cursor renamed its command to
        // it, so it has to be searched for — but adopting whatever answers to
        // it means ORE reports an agent as installed, offers it in the
        // picker, and then fails the user's first turn with output from a
        // program that has nothing to do with Cursor.
        //
        // The unambiguous name is trusted as found. The generic one has to say
        // who it is.
        if !Self.identifiesAsCursorAgent(isAmbiguousName: resolved.isAmbiguousName, version: version) {
            return HarnessProbeResult(
                kind: kind,
                authState: .notAuthenticated,
                diagnostic: "Not found on PATH (\(ShellEnvironment.searchPathDescription)). "
                    + "A program named `agent` is installed at \(path), but it does not "
                    + "identify itself as cursor-agent."
            )
        }

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

    /// Whether a binary ORE found is one it should drive as cursor-agent.
    ///
    /// Pure, so the rule can be tested without a PATH full of decoys. A binary
    /// found under the unambiguous `cursor-agent` name is accepted whatever it
    /// prints — including nothing, since a CLI that will not answer
    /// `--version` is a different problem and not this check's to diagnose.
    static func identifiesAsCursorAgent(isAmbiguousName: Bool, version: String?) -> Bool {
        guard isAmbiguousName else { return true }
        return version?.localizedCaseInsensitiveContains("cursor") == true
    }

    private func resolveExecutablePath() -> String? { resolveExecutable()?.path }

    /// The resolved binary, and whether it was found under a name that only
    /// Cursor could plausibly own.
    private func resolveExecutable() -> (path: String, isAmbiguousName: Bool)? {
        if let executablePathOverride {
            // An explicit override is the user's own answer to this question.
            return (executablePathOverride, false)
        }
        // Cursor renamed the primary command from `cursor-agent` to `agent`.
        // Current installs commonly provide both symlinks, while older and
        // minimal installs may provide only one. Prefer the unambiguous legacy
        // name, then accept the current documented command.
        for name in Self.executableNames {
            if let path = ShellEnvironment.locate(name) {
                return (path, name == "agent")
            }
        }
        return nil
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
    /// The mode the *next* turn spawns with. A turn is a whole process, so a
    /// change made while one is running lands on the one after it rather than
    /// forcing the user into a new chat.
    private var permissionMode: PermissionMode
    private var currentProcess: ChildProcess?
    private var turnTask: Task<Void, Never>?
    private var isStopping = false
    /// Set while the user's own interrupt is tearing the process down, so its
    /// non-zero exit isn't misread as a failure.
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
            // stderr is drained concurrently and joined before the turn closes:
            // it is the only channel that says *why* a run failed, and reading
            // it after the fact would race the classification against EOF.
            // `async let` keeps it structured, so cancelling the turn cancels it.
            async let diagnostics = Self.collectStderr(from: process)
            for await line in process.stdoutChunks.lines() {
                await self?.handle(line: line)
            }
            let status = await process.waitForExit()
            await self?.finishTurn(status: status, stderr: await diagnostics)
        }
    }

    /// The tail of stderr. Bounded because a failing CLI can print without end,
    /// and only the last lines carry the reason it gave up.
    private static func collectStderr(from process: ChildProcess) async -> String {
        var recent: [String] = []
        for await line in process.stderrChunks.lines() {
            recent.append(line)
            if recent.count > 40 { recent.removeFirst(recent.count - 40) }
        }
        return recent.joined(separator: "\n")
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
        if permissionMode == .plan {
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
        if allowUnprompted, permissionMode == .bypassPermissions {
            arguments.append("--force")
        } else if permissionMode != .plan {
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

    private func finishTurn(status: Int32, stderr: String) {
        currentProcess = nil
        // A process the user killed exits non-zero by definition. Classifying
        // that would raise an error banner for a deliberate stop, so the turn
        // is closed as if it had ended cleanly.
        let wasInterrupted = isInterrupting
        isInterrupting = false
        for event in translator.closeTurn(
            exitCode: wasInterrupted ? 0 : status,
            stderr: stderr
        ).events {
            continuation.yield(event)
        }
    }

    public func interrupt() async throws {
        guard let process = currentProcess else { return }
        isInterrupting = true
        await process.terminate(gracePeriod: .seconds(2))
        currentProcess = nil
        continuation.yield(.statusChanged(.interrupted))
    }

    /// Accepted at any point in the chat. There is no live control channel to
    /// push it down, but every turn is a fresh process, so recording it here is
    /// all it takes for the next turn to run under the new policy — the user
    /// does not have to open a new chat to switch to accept-edits.
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
        turnTask?.cancel()
        if let currentProcess { await currentProcess.terminate() }
        currentProcess = nil
        continuation.finish()
    }
}
