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
            capabilities: capabilities
        )
    }

    private func resolveExecutablePath() -> String? {
        if let executablePathOverride { return executablePathOverride }
        return ShellEnvironment.locate(kind.defaultExecutableName)
    }

    /// Reads login state from the CLI's own stored credentials rather than by
    /// making a request — the doctor must be free to run.
    private func probeAuthState(executablePath: String) async -> HarnessProbeResult.AuthState {
        let output = await CommandProbe.output(
            executablePath: executablePath,
            arguments: ["auth", "status"],
            timeout: .seconds(15)
        )
        guard let output else { return .unknown }
        let text = output.lowercased()
        if text.contains("not logged in") || text.contains("no active") || text.contains("logged out") {
            return .notAuthenticated
        }
        if text.contains("logged in") || text.contains("subscription") || text.contains("account") {
            return .authenticated
        }
        return .unknown
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
                environment: ShellEnvironment.childEnvironment()
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
