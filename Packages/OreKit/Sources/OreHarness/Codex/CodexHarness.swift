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
            executablePath: path, arguments: ["--version"], timeout: .seconds(10)
        )

        return HarnessProbeResult(
            kind: kind,
            executablePath: path,
            version: version,
            authState: await probeAuthState(executablePath: path)
        )
    }

    public func discoverModels() async -> [AgentModel] {
        guard let path = resolveExecutablePath() else { return [] }
        do {
            let process = try ChildProcess(
                executablePath: path,
                arguments: ["app-server"],
                workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                environment: ShellEnvironment.childEnvironment()
            )
            let connection = JSONRPCConnection(process: process)
            await connection.start()
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
        guard let output = await CommandProbe.output(
            executablePath: executablePath, arguments: ["login", "status"], timeout: .seconds(15)
        ) else {
            // Fall back to the credentials file the CLI writes on login.
            let authFile = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/auth.json")
            return FileManager.default.fileExists(atPath: authFile.path)
                ? .authenticated
                : .notAuthenticated
        }

        let text = output.lowercased()
        if text.contains("not logged in") || text.contains("logged out") { return .notAuthenticated }
        if text.contains("logged in") { return .authenticated }
        return .unknown
    }
}
