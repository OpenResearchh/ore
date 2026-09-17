import Foundation
import OreProtocol
import OreSupport

/// Codex, driven through `codex app-server` on the user's ChatGPT plan.
public struct CodexHarness: AgentHarness {
    public let kind: HarnessKind = .codex

    public var capabilities: HarnessCapabilities {
        HarnessCapabilities(
            // Plan mode is the read-only sandbox rather than a dedicated mode,
            // so there's no plan to approve — the agent proposes in prose.
            supportsPlanMode: false,
            supportsSteering: true,
            supportsInterrupt: true,
            supportsResume: true,
            supportsSessionFork: true,
            supportsThinkingStream: true,
            supportsPartialMessages: true,
            // The sandbox posture is set per turn, not by a live control
            // message, so a change takes effect on the next turn.
            supportsRuntimePermissionModeChange: false,
            supportsCustomTools: true,
            permissionModel: .interactiveCallback,
            usageGranularity: .live
        )
    }

    public var executablePathOverride: String?
    /// See `ClaudeCodeHarness.allowAPIKeyFallback`: probes strip provider
    /// credentials unless the user opted in, which is why an `OPENAI_API_KEY`
    /// user was told to sign in to a CLI they are already authenticated to.
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

        // See `ClaudeCodeHarness.probe`: every other copy on PATH, because the
        // one ORE updates and the one the shell runs need not be the same file.
        let shadowed = HarnessPathScan.shadowed(
            of: [kind.defaultExecutableName], winner: path
        )

        let versionProbe = await CommandProbe.run(
            executablePath: path,
            arguments: ["--version"],
            timeout: .seconds(10),
            allowAPIKeyFallback: allowAPIKeyFallback
        )
        if case .couldNotLaunch(let reason) = versionProbe {
            return HarnessDiagnostic.unlaunchable(
                kind: kind, path: path, reason: reason, shadowedPaths: shadowed
            )
        }

        return HarnessProbeResult(
            kind: kind,
            executablePath: path,
            version: versionProbe.firstLine,
            authState: await probeAuthState(executablePath: path),
            shadowedPaths: shadowed
        )
    }

    public func discoverModels() async -> [AgentModel] {
        guard let path = resolveExecutablePath() else { return [] }
        do {
            let process = try ChildProcess(
                executablePath: path,
                arguments: ["app-server"],
                workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                environment: ShellEnvironment.childEnvironment(
                    allowProviderCredentials: allowAPIKeyFallback
                ),
                discardStandardError: true
            )
            let connection = JSONRPCConnection(process: process)
            await connection.start()
            // Notifications aren't wanted here, but left unread they buffer
            // until the connection goes away. Ends when `stop()` finishes it.
            Task {
                for await _ in connection.incoming {}
            }
            defer {
                Task {
                    await connection.stop()
                    await process.terminate(gracePeriod: .milliseconds(200))
                }
            }

            _ = try await connection.send(
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("ore-model-catalog"),
                        "title": .string("ORE"),
                        "version": .string(OreVersion.current),
                    ]),
                ]),
                timeout: .seconds(15)
            )
            try await connection.notify(method: "initialized", params: .object([:]))
            let response = try await connection.send(
                method: "model/list",
                params: .object(["includeHidden": .bool(false), "limit": .integer(100)]),
                timeout: .seconds(20)
            )
            return (response["data"]?.arrayValue ?? []).compactMap { value in
                guard value["hidden"]?.boolValue != true,
                      let id = value["model"]?.stringValue ?? value["id"]?.stringValue
                else { return nil }
                let efforts = value["supportedReasoningEfforts"]?.arrayValue?.compactMap {
                    $0["reasoningEffort"]?.stringValue
                } ?? []
                let serviceTiers = value["serviceTiers"]?.arrayValue?.compactMap {
                    $0["id"]?.stringValue
                } ?? []
                return AgentModel(
                    id: id,
                    displayName: value["displayName"]?.stringValue ?? id,
                    description: value["description"]?.stringValue ?? "",
                    isDefault: value["isDefault"]?.boolValue ?? false,
                    supportedReasoningEfforts: efforts,
                    supportedServiceTiers: serviceTiers
                )
            }
        } catch {
            return []
        }
    }

    public func makeSession(_ configuration: SessionConfiguration) async throws -> any AgentSession {
        guard let path = configuration.executablePath ?? resolveExecutablePath() else {
            throw HarnessError.executableNotFound(
                kind, searchedPath: ShellEnvironment.searchPathDescription
            )
        }
        return CodexSession(
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

    private func probeAuthState(executablePath: String) async -> HarnessProbeResult.AuthState {
        let outcome = await CommandProbe.run(
            executablePath: executablePath,
            arguments: ["login", "status"],
            timeout: .seconds(15),
            allowAPIKeyFallback: allowAPIKeyFallback
        )
        // Stderr counts as an answer here: the CLI reports "Not logged in" on
        // it and exits non-zero, which the stdout-only read threw away and
        // then guessed at from the credentials file.
        let text = (outcome.spokenText ?? "").lowercased()
        if text.contains("not logged in") || text.contains("logged out") { return .notAuthenticated }
        if text.contains("logged in") { return .authenticated }

        // Fall back to the credentials file the CLI writes on login. Anything
        // that isn't one of the two answers above lands here, including a
        // non-zero exit with nothing to say: reading `spokenText` must not
        // cost us this check, which is the only evidence left when the CLI
        // declines to state its login state.
        //
        // Its *absence* is real evidence: the CLI has never logged in on
        // this machine. Its presence is not — the file survives an expired
        // or revoked token, and reading it as `.authenticated` told the
        // user "CLI subscription connected" right up until their first
        // turn failed on auth. `.unknown` is what we actually know, and
        // the UI already has wording for it ("Managed by CLI").
        let authFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        return FileManager.default.fileExists(atPath: authFile.path)
            ? .unknown
            : .notAuthenticated
    }
}
