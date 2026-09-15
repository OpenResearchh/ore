import Foundation
import OreProtocol
import OreSupport

/// Claude Code, driven through its stream-json interface on the user's own
/// Claude subscription.
public struct ClaudeCodeHarness: AgentHarness {
    public let kind: HarnessKind = .claudeCode

    public var capabilities: HarnessCapabilities {
        HarnessCapabilities(
            supportsPlanMode: true,
            supportsSteering: true,
            supportsInterrupt: true,
            supportsResume: true,
            supportsSessionFork: true,
            supportsThinkingStream: true,
            supportsPartialMessages: true,
            supportsRuntimePermissionModeChange: true,
            supportsCustomTools: true,
            permissionModel: .interactiveCallback,
            usageGranularity: .live
        )
    }

    /// Overrides `PATH` lookup, for users whose version manager hides the
    /// binary from a GUI app's environment.
    public var executablePathOverride: String?

    public init(executablePathOverride: String? = nil) {
        self.executablePathOverride = executablePathOverride
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
            executablePath: path,
            arguments: ["--version"],
            timeout: .seconds(10)
        )
        // Answered now, while the doctor is already asking the CLI things, so
        // the first session doesn't pay for it.
        _ = await ClaudeFlagSupport.shared.allowsBypassSwitch(executablePath: path)

        return HarnessProbeResult(
            kind: kind,
            executablePath: path,
            version: version,
            authState: await probeAuthState(executablePath: path),
            diagnostic: nil
        )
    }

    public func discoverModels() async -> [AgentModel] {
        // Claude Code does not expose the account's model catalog as a
        // metadata-only command. These are the provider's documented model ids
        // accepted by `claude --model`; the service remains authoritative about
        // which entries the signed-in plan may use.
        [
            AgentModel(
                id: "claude-fable-5", displayName: "Fable 5",
                description: "Highest capability for long-running agent work",
                supportedReasoningEfforts: ["adaptive"]
            ),
            AgentModel(
                id: "claude-opus-5", displayName: "Opus 5",
                description: "Complex agentic coding and enterprise work",
                supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max"]
            ),
            AgentModel(
                id: "claude-opus-4-8[1m]", displayName: "Opus 4.8 · 1M",
                description: "Deep reasoning with a one-million-token context",
                supportedReasoningEfforts: ["low", "medium", "high", "xhigh"]
            ),
            AgentModel(
                id: "claude-opus-4-7[1m]", displayName: "Opus 4.7 · 1M",
                description: "Previous Opus generation for compatible sessions"
            ),
            AgentModel(
                id: "claude-opus-4-6[1m]", displayName: "Opus 4.6 · 1M",
                description: "Long-context Opus model"
            ),
            AgentModel(
                id: "claude-sonnet-5[1m]", displayName: "Sonnet 5 · 1M",
                description: "Fast frontier model for coding and agents",
                isDefault: true,
                supportedReasoningEfforts: ["low", "medium", "high", "xhigh"]
            ),
            AgentModel(
                id: "claude-sonnet-4-6[1m]", displayName: "Sonnet 4.6 · 1M",
                description: "Balanced long-context model"
            ),
            AgentModel(
                id: "claude-sonnet-4-6", displayName: "Sonnet 4.6",
                description: "Balanced speed and capability"
            ),
            AgentModel(
                id: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5",
                description: "Fastest Claude model for lightweight work"
            ),
        ]
    }

    public func makeSession(_ configuration: SessionConfiguration) async throws -> any AgentSession {
        guard let path = configuration.executablePath ?? resolveExecutablePath() else {
            throw HarnessError.executableNotFound(
                kind,
                searchedPath: ShellEnvironment.searchPathDescription
            )
        }
        return ClaudeCodeSession(
            id: SessionID.generate(),
            executablePath: path,
            configuration: configuration,
            capabilities: capabilities,
            allowsBypassSwitch: await ClaudeFlagSupport.shared.allowsBypassSwitch(executablePath: path)
        )
    }

    private func resolveExecutablePath() -> String? {
        if let executablePathOverride { return executablePathOverride }
        return ShellEnvironment.locate(kind.defaultExecutableName)
    }

    /// Reads login state from the CLI's own stored credentials rather than by
    /// making a request — the doctor must be free to run.
    ///
    /// Current Claudes answer `auth status` as JSON by default
    /// (`{"loggedIn":false,…}`). Older builds printed prose. An expired
    /// subscription still looks "installed" and used to fall through to
    /// `.unknown`, which hid Settings' sign-in button and left the chat with
    /// only a red "OAuth session expired" bubble and no way to recover.
    private func probeAuthState(executablePath: String) async -> HarnessProbeResult.AuthState {
        let output = await CommandProbe.output(
            executablePath: executablePath,
            arguments: ["auth", "status"],
            timeout: .seconds(15)
        )
        return ClaudeAuthStatus.interpret(output)
    }
}

/// Interprets `claude auth status` output across CLI shapes.
enum ClaudeAuthStatus {
    static func interpret(_ output: String?) -> HarnessProbeResult.AuthState {
        guard let output, !output.isEmpty else { return .unknown }
        if let loggedIn = jsonLoggedIn(output) {
            return loggedIn ? .authenticated : .notAuthenticated
        }
        let text = output.lowercased()
        if text.contains("not logged in")
            || text.contains("no active")
            || text.contains("logged out")
            || text.contains("login: expired")
            || text.contains("log in again") {
            return .notAuthenticated
        }
        if text.contains("logged in") || text.contains("subscription") || text.contains("account") {
            return .authenticated
        }
        return .unknown
    }

    /// `{"loggedIn": false, …}` — the default shape since the CLI made JSON
    /// the default for `auth status`.
    private static func jsonLoggedIn(_ output: String) -> Bool? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" ,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = object["loggedIn"] as? Bool
        else { return nil }
        return loggedIn
    }
}

/// Which launch flags a Claude CLI binary understands, asked once per binary.
///
/// `--help` rather than a version table: when the flag first shipped isn't
/// something ORE should hard-code, and an older CLI given an unknown flag
/// refuses to start at all. A CLI that hangs or can't run reads as "no".
actor ClaudeFlagSupport {
    static let shared = ClaudeFlagSupport()

    private var answers: [String: Task<Bool, Never>] = [:]

    func allowsBypassSwitch(executablePath: String) async -> Bool {
        if let answer = answers[executablePath] { return await answer.value }
        let probe = Task {
            Self.helpOffersBypassSwitch(await CommandProbe.output(
                executablePath: executablePath,
                arguments: ["--help"],
                timeout: .seconds(10)
            ))
        }
        answers[executablePath] = probe
        return await probe.value
    }

    nonisolated static func helpOffersBypassSwitch(_ help: String?) -> Bool {
        help?.contains("--allow-dangerously-skip-permissions") ?? false
    }
}

/// Runs a short-lived command and collects its output. Used by the onboarding
/// doctor, where a hung CLI must degrade to "unknown" rather than block
/// first run.
enum CommandProbe {
    static func output(
        executablePath: String,
        arguments: [String],
        timeout: Duration
    ) async -> String? {
        let process: ChildProcess
        do {
            process = try ChildProcess(
                executablePath: executablePath,
                arguments: arguments,
                workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                environment: ShellEnvironment.childEnvironment(),
                // Only stdout is the answer; nobody reads stderr here.
                discardStandardError: true
            )
        } catch {
            return nil
        }
        process.closeStandardInput()

        let collector = Task { await process.stdoutChunks.collectText() }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await process.terminate(gracePeriod: .milliseconds(200))
        }

        let result = await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        timer.cancel()
        await process.terminate(gracePeriod: .milliseconds(200))
        return result.isEmpty ? nil : result
    }

    static func firstLine(
        executablePath: String,
        arguments: [String],
        timeout: Duration
    ) async -> String? {
        await output(executablePath: executablePath, arguments: arguments, timeout: timeout)?
            .split(separator: "\n").first.map(String.init)
    }
}
