import Foundation
import OreProtocol
import OreSupport

/// Google Antigravity, driven through the `agy` CLI on the user's own Google
/// account (or Gemini API key).
///
/// **Experimental.** The CLI has a documented bidirectional stream-json
/// protocol — closer to Claude Code than to cursor-agent — but no live
/// permission callback. `control_request` on stdin aborts the session. Tool
/// policy is therefore static: `--mode accept-edits` so workspace writes
/// aren't silently rejected, and shell stays on Antigravity's Ask policy
/// unless the user opts into Bypass (`--dangerously-skip-permissions`).
///
/// `permissionModel` is `.staticPolicy` so the UI can explain the allow-list
/// rather than offering an Approve button there is no channel to answer on.
public struct AntigravityHarness: AgentHarness {
    public let kind: HarnessKind = .antigravity

    public var capabilities: HarnessCapabilities {
        HarnessCapabilities(
            supportsPlanMode: false,
            supportsSteering: false,
            supportsInterrupt: true,
            supportsResume: true,
            supportsSessionFork: false,
            supportsThinkingStream: false,
            supportsPartialMessages: true,
            supportsRuntimePermissionModeChange: false,
            supportsCustomTools: false,
            permissionModel: .staticPolicy,
            usageGranularity: .live
        )
    }

    public var executablePathOverride: String?
    /// Opt-in, never inferred. Escalates from the CLI's default Ask policy to
    /// `--dangerously-skip-permissions` when the chat is in Bypass.
    public var allowUnprompted: Bool
    public var allowAPIKeyFallback: Bool

    public init(
        executablePathOverride: String? = nil,
        allowUnprompted: Bool = false,
        allowAPIKeyFallback: Bool = false
    ) {
        self.executablePathOverride = executablePathOverride
        self.allowUnprompted = allowUnprompted
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
            diagnostic: "Experimental: this CLI has no live approval channel. "
                + "File edits use --mode accept-edits; shell commands follow "
                + "Antigravity's Ask policy"
                + (allowUnprompted ? ", or run unprompted in Bypass mode." : "."),
            shadowedPaths: shadowed
        )
    }

    /// `agy models` is metadata-only and does not spend a turn.
    ///
    /// `--output-format` is a *global* flag (`agy --output-format json models`).
    /// Passing it after `models` is a CLI error, which is why the picker used
    /// to show only the four-item fallback. JSON when it works; the
    /// tab-separated text listing otherwise.
    public func discoverModels() async -> [AgentModel] {
        guard let path = resolveExecutablePath() else { return [] }
        let json = await CommandProbe.output(
            executablePath: path,
            arguments: ["--output-format", "json", "models"],
            timeout: .seconds(15),
            allowAPIKeyFallback: allowAPIKeyFallback
        )
        if let json, let models = Self.parseModels(json), !models.isEmpty {
            return models
        }
        guard let text = await CommandProbe.output(
            executablePath: path,
            arguments: ["models"],
            timeout: .seconds(15),
            allowAPIKeyFallback: allowAPIKeyFallback
        ) else { return [] }
        return Self.parseModels(text) ?? []
    }

    public func makeSession(_ configuration: SessionConfiguration) async throws -> any AgentSession {
        guard let path = configuration.executablePath ?? resolveExecutablePath() else {
            throw HarnessError.executableNotFound(
                kind, searchedPath: ShellEnvironment.searchPathDescription
            )
        }
        return AntigravitySession(
            id: SessionID.generate(),
            executablePath: path,
            configuration: configuration,
            capabilities: capabilities,
            allowUnprompted: allowUnprompted
        )
    }

    /// Headless stream-json launch flags.
    ///
    /// `agy -p` always consumes the next argv as the prompt. A bare `-p`
    /// therefore swallows `--input-format` (or whatever follows) and the CLI
    /// exits before reading stdin. `-p=` is the empty-prompt form the CLI
    /// documents, so messages come from NDJSON on stdin.
    static let printModeArguments = [
        "-p=",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
    ]

    /// Maps ORE's effort ladder onto the values `agy --effort` accepts.
    static func cliEffort(_ effort: ReasoningEffort) -> String {
        switch effort {
        case .none, .low: return "low"
        case .medium: return "medium"
        case .high, .xhigh, .max, .adaptive: return "high"
        }
    }

    /// Headless `agy` has no TTY and no permission callback. Without a mode
    /// flag every write and shell call is rejected, which reads as a broken
    /// agent rather than an unanswered prompt. `--mode accept-edits` is the
    /// default; Bypass still requires the explicit opt-in.
    static func permissionArguments(
        mode: PermissionMode,
        allowUnprompted: Bool
    ) -> [String] {
        if allowUnprompted, mode == .bypassPermissions {
            return ["--dangerously-skip-permissions"]
        }
        if mode == .plan {
            return ["--mode", "plan"]
        }
        return ["--mode", "accept-edits"]
    }

    private func resolveExecutablePath() -> String? {
        if let executablePathOverride { return executablePathOverride }
        return ShellEnvironment.locate(kind.defaultExecutableName)
    }

    private func probeAuthState(executablePath: String) async -> HarnessProbeResult.AuthState {
        let outcome = await CommandProbe.run(
            executablePath: executablePath,
            arguments: ["-p=/usage", "--output-format", "json", "--print-timeout", "15s"],
            timeout: .seconds(20),
            allowAPIKeyFallback: allowAPIKeyFallback
        )
        return AntigravityAuthStatus.interpret(outcome.spokenText)
    }

    /// Pure so the catalogue parser can be tested without a live `agy`.
    static func parseModels(_ output: String) -> [AgentModel]? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let models = parseJSONModels(trimmed) { return models }
        return parseTextModels(trimmed)
    }

    private static func parseJSONModels(_ output: String) -> [AgentModel]? {
        guard let data = output.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        if let rows = modelRows(in: value) {
            let models = decodeModelRows(rows)
            if !models.isEmpty { return models }
        }
        // `agy --output-format json models` also repeats the listing as a
        // tab-separated `response` string. Use it when `command.data` is absent.
        if let response = value["response"]?.stringValue {
            let models = parseTextModels(response)
            if !models.isEmpty { return models }
        }
        return nil
    }

    /// Live `agy --output-format json models` wraps the catalogue as
    /// `command.data.models`. Bare arrays and `{models:[…]}` stay accepted.
    private static func modelRows(in value: JSONValue) -> [JSONValue]? {
        if let array = value.arrayValue { return array }
        if let array = value["models"]?.arrayValue ?? value["items"]?.arrayValue {
            return array
        }
        if let array = value["command"]?["data"]?["models"]?.arrayValue
            ?? value["command"]?["models"]?.arrayValue
            ?? value["data"]?["models"]?.arrayValue {
            return array
        }
        return nil
    }

    private static func decodeModelRows(_ rows: [JSONValue]) -> [AgentModel] {
        var models: [AgentModel] = []
        var seen: Set<String> = []
        for row in rows {
            if let id = row.stringValue {
                guard seen.insert(id).inserted else { continue }
                models.append(AgentModel(id: id, displayName: id))
                continue
            }
            guard let id = row["id"]?.stringValue
                ?? row["slug"]?.stringValue
                ?? row["model"]?.stringValue,
                  seen.insert(id).inserted
            else { continue }
            let name = row["label"]?.stringValue
                ?? row["display_name"]?.stringValue
                ?? row["displayName"]?.stringValue
                ?? row["name"]?.stringValue
                ?? row["title"]?.stringValue
                ?? id
            let isDefault = row["is_default"]?.boolValue
                ?? row["isDefault"]?.boolValue
                ?? row["default"]?.boolValue
                ?? false
            models.append(AgentModel(
                id: id,
                displayName: name,
                description: row["description"]?.stringValue ?? "",
                isDefault: isDefault,
                supportedReasoningEfforts: ["low", "medium", "high"]
            ))
        }
        return models
    }

    private static func parseTextModels(_ output: String) -> [AgentModel] {
        var models: [AgentModel] = []
        var seen: Set<String> = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lowered = line.lowercased()
            if lowered.hasPrefix("available") || lowered.hasPrefix("fetching") { continue }
            guard let (id, name) = splitListingLine(line),
                  !id.isEmpty, !id.contains(" "), seen.insert(id).inserted
            else { continue }
            models.append(AgentModel(
                id: id,
                displayName: name.isEmpty ? id : name,
                supportedReasoningEfforts: ["low", "medium", "high"]
            ))
        }
        return models
    }

    /// Live `agy models` is `id<TAB>label`. Older docs used two-or-more spaces.
    private static func splitListingLine(_ line: String) -> (String, String)? {
        if let tab = line.firstIndex(of: "\t") {
            let id = String(line[..<tab]).trimmingCharacters(in: .whitespaces)
            let name = String(line[line.index(after: tab)...])
                .trimmingCharacters(in: .whitespaces)
            return (id, name)
        }
        guard let range = line.range(of: #"\s{2,}"#, options: .regularExpression) else {
            return nil
        }
        let id = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let name = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (id, name)
    }
}

/// Interprets `agy -p /usage` (and similar metadata) across CLI shapes.
enum AntigravityAuthStatus {
    static func interpret(_ output: String?) -> HarnessProbeResult.AuthState {
        guard let output, !output.isEmpty else { return .unknown }
        if looksLikeAuthFailure(output) { return .notAuthenticated }
        if looksAuthenticated(output) { return .authenticated }
        return .unknown
    }

    static func looksLikeAuthFailure(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("authentication required")
            || text.contains("not signed in")
            || text.contains("not logged in")
            || text.contains("please sign in")
            || text.contains("run /login")
            || text.contains("no active session")
            || (text.contains("unauthenticated") && !text.contains("permission"))
    }

    private static func looksAuthenticated(_ output: String) -> Bool {
        let text = output.lowercased()
        if text.contains("\"status\":\"success\"") { return true }
        if text.contains("input_tokens") || text.contains("\"usage\"") { return true }
        if text.contains("signed in") || text.contains("logged in") { return true }
        return output.first == "{"
    }
}
