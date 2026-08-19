import Foundation
import OreProtocol
import OreSupport

/// Updates the user's locally installed agent CLI.
///
/// ORE never vendors these binaries — it drives whatever the user already has
/// on PATH — so a model that "requires a newer version of Codex" is a prompt
/// to upgrade *their* install, not ours. Detection follows the path: Homebrew
/// prefixes go through `brew upgrade`, node version-manager trees through
/// `npm install -g`, and native `~/.local/bin` installs through the CLI's own
/// updater or the vendor's install script.
public enum HarnessCLIUpdater {
    public enum Plan: Equatable, Sendable {
        case brew(formula: String)
        case npm(package: String)
        case selfUpdate(executablePath: String)
        case nativeInstaller(url: String)
    }

    public enum UpdateError: Error, Sendable, LocalizedError {
        case commandFailed(command: String, exitCode: Int32, output: String)
        case timedOut(command: String)

        public var errorDescription: String? {
            switch self {
            case .commandFailed(_, let code, let output):
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.isEmpty { return "CLI update failed (exit \(code))." }
                return detail
            case .timedOut:
                return "CLI update timed out. Try again, or update it in a terminal."
            }
        }
    }

    public static func plan(for kind: HarnessKind, executablePath: String?) -> Plan {
        if let path = executablePath, isHomebrewPath(path), let formula = kind.brewFormula {
            return .brew(formula: formula)
        }
        if let path = executablePath, isNodeManagedPath(path), let package = kind.npmPackage {
            return .npm(package: package)
        }
        if let path = executablePath, isNativeUserBin(path) {
            switch kind {
            case .claudeCode:
                return .selfUpdate(executablePath: path)
            case .codex:
                return .npm(package: kind.npmPackage ?? "@openai/codex")
            case .cursorAgent:
                return .nativeInstaller(url: Self.cursorInstallURL)
            }
        }
        if let package = kind.npmPackage {
            return .npm(package: package)
        }
        return .nativeInstaller(url: Self.cursorInstallURL)
    }

    /// Runs the update on the user's login-shell PATH so nvm/brew/fnm resolve.
    public static func update(kind: HarnessKind, executablePath: String?) async throws {
        let plan = plan(for: kind, executablePath: executablePath)
        let command = script(for: plan)
        try await runLoginShell(command)
    }

    static func script(for plan: Plan) -> String {
        switch plan {
        case .brew(let formula):
            return "brew upgrade \(shellEscape(formula))"
        case .npm(let package):
            return "npm install -g \(shellEscape(package))@latest"
        case .selfUpdate(let path):
            return "\(shellEscape(path)) update"
        case .nativeInstaller(let url):
            return "curl -fsSL \(shellEscape(url)) | bash"
        }
    }

    private static let cursorInstallURL = "https://cursor.com/install"

    private static func runLoginShell(_ script: String) async throws {
        let shell = ShellEnvironment.loginShellPath
        let process = try ChildProcess(
            executablePath: shell,
            arguments: ShellEnvironment.commandArguments(for: shell, script: script),
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: ShellEnvironment.childEnvironment()
        )
        process.closeStandardInput()

        let timedOut = Lockbox(false)
        async let standardOutput = process.stdoutChunks.collectText()
        async let standardError = process.stderrChunks.collectText()
        let timer = Task {
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            timedOut.set(true)
            await process.terminate(gracePeriod: .milliseconds(200))
        }

        let output = await standardOutput
        let errorOutput = await standardError
        let status = await process.waitForExit()
        timer.cancel()
        let combined = output + errorOutput

        if timedOut.get() {
            throw UpdateError.timedOut(command: script)
        }
        if status != 0 {
            throw UpdateError.commandFailed(command: script, exitCode: status, output: combined)
        }
    }

    static func isHomebrewPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.contains("/homebrew/") || lower.contains("/linuxbrew/") || lower.contains("/cellar/") {
            return true
        }
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            let resolved = destination.lowercased()
            return resolved.contains("/cellar/") || resolved.contains("/homebrew/")
        }
        return false
    }

    static func isNodeManagedPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let markers = [
            "/.nvm/", "/nvm/versions/", "/.fnm/", "/fnm/node-versions/",
            "/.volta/", "/volta/", "/.nodenv/", "/nodenv/",
            "/node_modules/", "/.npm/", "/npm-global/", "/.asdf/",
        ]
        return markers.contains { lower.contains($0) }
    }

    static func isNativeUserBin(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/.local/bin/")
    }

    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension HarnessKind {
    var npmPackage: String? {
        switch self {
        case .claudeCode: return "@anthropic-ai/claude-code"
        case .codex: return "@openai/codex"
        case .cursorAgent: return nil
        }
    }

    var brewFormula: String? {
        switch self {
        case .claudeCode: return "claude-code"
        case .codex: return "codex"
        case .cursorAgent: return nil
        }
    }
}
