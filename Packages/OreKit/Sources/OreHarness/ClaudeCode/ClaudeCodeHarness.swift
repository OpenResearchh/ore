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
    /// Whether the doctor's probes may see `ANTHROPIC_API_KEY` and friends.
    ///
    /// Sessions already honour this (`SessionConfiguration.allowAPIKeyFallback`),
    /// but probes stripped the credentials unconditionally, so a user who
    /// authenticates by API key was told to run `claude auth login` forever —
    /// advice that cannot help them. Off by default: the stripping is a
    /// billing safeguard, and only the app knows the user opted in.
    public var allowAPIKeyFallback: Bool

    public init(executablePathOverride: String? = nil, allowAPIKeyFallback: Bool = false) {
        self.executablePathOverride = executablePathOverride
        self.allowAPIKeyFallback = allowAPIKeyFallback
    }

    public func probe() async -> HarnessProbeResult {
        guard let path = resolveExecutablePath() else {
            return HarnessProbeResult(
                kind: kind,
                authState: .notAuthenticated,
                diagnostic: await HarnessDiagnostic.notFound(
                    executableName: kind.defaultExecutableName
                )
            )
        }

        let versionProbe = await CommandProbe.run(
            executablePath: path,
            arguments: ["--version"],
            timeout: .seconds(10),
            allowAPIKeyFallback: allowAPIKeyFallback
        )
        // The first thing ORE asks the binary is also the proof that it can be
        // asked anything at all.
        if case .couldNotLaunch(let reason) = versionProbe {
            return HarnessDiagnostic.unlaunchable(kind: kind, path: path, reason: reason)
        }
        let version = versionProbe.firstLine
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
        let outcome = await CommandProbe.run(
            executablePath: executablePath,
            arguments: ["auth", "status"],
            timeout: .seconds(15),
            allowAPIKeyFallback: allowAPIKeyFallback
        )
        // `spokenText` rather than stdout alone: a CLI that prints "Not logged
        // in" on stderr and exits non-zero is answering the question, not
        // failing to start — the launch was already proven by `--version`.
        return ClaudeAuthStatus.interpret(outcome.spokenText)
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
    /// What the command actually did.
    ///
    /// "Ran and printed nothing" and "could not be started at all" were both
    /// reported as `nil`, and that is why a CLI that is present but
    /// unlaunchable — quarantined by Gatekeeper, missing its `+x` bit, a
    /// symlink into a version manager that was uninstalled, a binary on a
    /// network volume that is no longer mounted — read as *ready*: a missing
    /// version string is not evidence of anything, and `.unknown` auth counts
    /// as ready. Stderr, which is where the reason lives, was discarded.
    enum Outcome: Sendable, Equatable {
        /// The command ran and printed something on stdout.
        case text(String)
        /// The command ran, exited cleanly, and said nothing.
        case empty
        /// The command never ran, or died without producing an answer. The
        /// payload is the CLI's own explanation where it gave one.
        case couldNotLaunch(String)

        /// Stdout only. For callers that want an answer and have no use for a
        /// failure they cannot distinguish.
        var text: String? {
            if case .text(let text) = self { return text }
            return nil
        }

        var firstLine: String? {
            text?.split(separator: "\n").first.map(String.init)
        }

        /// Whatever the command said, from wherever it said it. A CLI that
        /// reports "not logged in" on stderr and exits non-zero is answering
        /// the question rather than failing to run, so an interpreter of its
        /// prose should see that text too.
        var spokenText: String? {
            switch self {
            case .text(let text): return text
            case .empty: return nil
            case .couldNotLaunch(let reason): return reason
            }
        }
    }

    static func run(
        executablePath: String,
        arguments: [String],
        timeout: Duration,
        allowAPIKeyFallback: Bool = false
    ) async -> Outcome {
        let process: ChildProcess
        do {
            process = try ChildProcess(
                executablePath: executablePath,
                arguments: arguments,
                workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                environment: ShellEnvironment.childEnvironment(
                    allowProviderCredentials: allowAPIKeyFallback
                )
            )
        } catch ChildProcessError.launchFailed(_, let reason) {
            // The reason alone: the caller names the path, and saying it twice
            // reads as two separate failures.
            return .couldNotLaunch(reason)
        } catch {
            return .couldNotLaunch(error.localizedDescription)
        }
        process.closeStandardInput()

        // Both pipes are drained concurrently. Reading one and leaving the
        // other to fill is how a CLI that writes a long diagnostic to stderr
        // stops writing to stdout and hangs until the timer kills it.
        async let standardOutput = process.stdoutChunks.collectText()
        async let standardError = process.stderrChunks.collectText()

        let timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await process.terminate(gracePeriod: .milliseconds(200))
        }

        let output = await standardOutput
        let errorOutput = await standardError
        let status = await process.waitForExit()
        timer.cancel()
        await process.terminate(gracePeriod: .milliseconds(200))

        return classify(standardOutput: output, standardError: errorOutput, exitStatus: status)
    }

    /// Pure, so the three outcomes can be checked without a binary that fails
    /// to launch in a way every machine reproduces.
    static func classify(
        standardOutput: String,
        standardError: String,
        exitStatus: Int32
    ) -> Outcome {
        let output = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty { return .text(output) }

        // Silence with a clean exit says nothing bad about the binary. Silence
        // with a failing exit is the shape of a CLI that could not start: a
        // missing interpreter (`env: node: No such file or directory`, 127), a
        // dynamic link that no longer resolves, a Gatekeeper kill. Reporting
        // that as a launch failure is what stops it reading as ready.
        guard exitStatus != 0 else { return .empty }
        let errorOutput = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return .couldNotLaunch(
            errorOutput.isEmpty ? "exited with status \(exitStatus)" : errorOutput
        )
    }

    static func output(
        executablePath: String,
        arguments: [String],
        timeout: Duration,
        allowAPIKeyFallback: Bool = false
    ) async -> String? {
        await run(
            executablePath: executablePath,
            arguments: arguments,
            timeout: timeout,
            allowAPIKeyFallback: allowAPIKeyFallback
        ).text
    }

    static func firstLine(
        executablePath: String,
        arguments: [String],
        timeout: Duration,
        allowAPIKeyFallback: Bool = false
    ) async -> String? {
        await run(
            executablePath: executablePath,
            arguments: arguments,
            timeout: timeout,
            allowAPIKeyFallback: allowAPIKeyFallback
        ).firstLine
    }
}

/// The diagnostics all three probes share, so they cannot drift into three
/// different explanations of the same failure.
enum HarnessDiagnostic {
    /// Why ORE cannot find a CLI the user believes they have.
    static func notFound(executableName: String) async -> String {
        let base = "Not found on PATH (\(ShellEnvironment.searchPathDescription))"
        guard let shellNote = await ShellAliasProbe.note(for: executableName) else { return base }
        return base + ". " + shellNote
    }

    /// A binary ORE found on disk and could not start.
    ///
    /// No `executablePath` on the result, though the text names the path:
    /// `isInstalled` is what puts the readiness ladder on its "installed but
    /// not signed in" rung, and sending this user to `claude auth login` —
    /// a command that has to launch the very binary that will not launch —
    /// is the dead end this exists to remove. Reinstalling is the real fix,
    /// which is the rung they get instead. `.notAuthenticated` keeps
    /// `isReady` false for anything reading the state rather than the rung;
    /// the landed `agent`-impostor guard makes the same call.
    static func unlaunchable(
        kind: HarnessKind,
        path: String,
        reason: String
    ) -> HarnessProbeResult {
        // One bounded line: this is rendered as a caption in Settings, and a
        // CLI that dies on launch can print a whole stack trace at us.
        let firstLine = reason
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        let condensed = firstLine.count > 200
            ? String(firstLine.prefix(200)) + "…"
            : firstLine
        return HarnessProbeResult(
            kind: kind,
            authState: .notAuthenticated,
            diagnostic: condensed.isEmpty
                ? "Found at \(path) but could not be launched."
                : "Found at \(path) but could not be launched: \(condensed)"
        )
    }
}

/// Asks the login shell about a command ORE could not find on `PATH`.
///
/// A CLI installed as a shell alias or function is invisible to `locate()`,
/// which only looks for files, so the user was told their agent was "not found
/// on PATH" while `claude` worked perfectly in their terminal. ORE still
/// cannot launch an alias — there is no file to spawn — but naming what is
/// actually there beats sending someone to reinstall what they already have.
enum ShellAliasProbe {
    private static let begin = "__ORE_CV_BEGIN__"
    private static let end = "__ORE_CV_END__"

    /// One bounded shell round trip, diagnostic only: nothing about the probe
    /// result changes on the strength of it.
    static func note(for executableName: String) async -> String? {
        let shell = ShellEnvironment.loginShellPath
        let script = "printf '%s\\n' \(begin); command -v -- '\(executableName)' 2>/dev/null; "
            + "printf '%s\\n' \(end)"
        // Interactive as well as login, for the reason the PATH probe is:
        // aliases and functions are defined in `.zshrc` / `.bashrc`, which a
        // non-interactive shell never reads — and an alias is the whole point
        // of asking. An exotic shell keeps its plain `-c`.
        var arguments = ShellEnvironment.commandArguments(for: shell, script: script)
        if arguments.first == "-lc" { arguments[0] = "-ilc" }

        let outcome = await CommandProbe.run(
            executablePath: shell,
            arguments: arguments,
            timeout: .seconds(5)
        )
        guard let answer = parse(outcome.spokenText ?? "") else { return nil }
        return interpret(answer: answer, executableName: executableName)
    }

    /// The markers keep profile banners, version-manager notices and update
    /// nags from being read as the answer — the same problem, and the same
    /// fix, as the environment probe.
    static func parse(_ output: String) -> String? {
        guard let beginRange = output.range(of: begin + "\n"),
              let endRange = output.range(of: end, range: beginRange.upperBound..<output.endIndex)
        else { return nil }
        return output[beginRange.upperBound..<endRange.lowerBound]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// Pure: what `command -v` answering with `answer` means for a user who
    /// was just told the command does not exist.
    static func interpret(answer: String, executableName: String) -> String? {
        guard !answer.isEmpty else { return nil }
        if answer.hasPrefix("/") {
            // A real file, on a PATH only an interactive shell assembles.
            return "Your login shell finds it at \(answer), which is not on the PATH ORE sees."
        }
        return "`\(executableName)` exists in your shell as an alias or function, "
            + "which ORE cannot launch."
    }
}
