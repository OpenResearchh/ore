import Foundation
import OreProtocol
import OreSupport

/// Updates the user's locally installed agent CLI.
///
/// ORE never vendors these binaries — it drives whatever the user already has
/// on PATH — so a model that "requires a newer version of Codex" is a prompt
/// to upgrade *their* install, not ours. Detection follows the path: Homebrew
/// prefixes go through `brew upgrade`, Codex always prefers its own
/// `codex update`, node version-manager trees through `npm install -g`, and
/// native `~/.local/bin` installs through the CLI's own updater or the vendor's
/// install script.
public enum HarnessCLIUpdater {
    public enum Plan: Equatable, Sendable {
        case brew(formula: String)
        case npm(package: String)
        case selfUpdate(executablePath: String)
        case nativeInstaller(url: String)
    }

    public enum UpdateError: Error, Sendable, LocalizedError {
        case commandFailed(kind: HarnessKind, command: String, exitCode: Int32, output: String)
        case timedOut(command: String)

        public var errorDescription: String? {
            switch self {
            case .commandFailed(let kind, _, let code, let output):
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if let friendly = Self.permissionDeniedMessage(for: kind, in: detail) {
                    return friendly
                }
                if detail.isEmpty { return "CLI update failed (exit \(code))." }
                return detail
            case .timedOut:
                return "CLI update timed out. Try again, or update it in a terminal."
            }
        }

        /// npm's EACCES dump is useless in the composer; translate it into the
        /// action the user actually needs.
        ///
        /// The remedy has to name the harness being updated. A hardcoded
        /// formula told someone updating Claude Code to `brew install codex`,
        /// which installs a different agent and leaves the broken CLI in place.
        static func permissionDeniedMessage(for kind: HarnessKind, in detail: String) -> String? {
            let lower = detail.lowercased()
            guard lower.contains("eacces")
                || lower.contains("permission denied")
                || lower.contains("operation not permitted")
            else { return nil }
            // Cursor has no formula, so offering Homebrew there would be a
            // dead end; fall back to the ownership fix on its own.
            let remedy = kind.brewFormula.map {
                "Reinstall with Homebrew (`brew install \($0)`) or fix"
            } ?? "Fix"
            return """
            Could not update \(kind.displayName): this install is not writable \
            by your user (often a root-owned `/usr/local` npm package). \
            \(remedy) ownership of the install directory, then try again.
            """
        }
    }

    public static func plan(for kind: HarnessKind, executablePath: String?) -> Plan {
        // Keep the PATH entry the user actually runs in the update script.
        // Classification helpers resolve symlinks themselves when needed.
        let original = executablePath

        if let original, isHomebrewPath(original), let formula = kind.brewFormula {
            return .brew(formula: formula)
        }

        switch kind {
        case .codex:
            // Codex ships `codex update` for every install flavor. Prefer it
            // over a blind `npm install -g`, which fails with a raw EACCES
            // stack on root-owned `/usr/local` installs.
            if let original {
                return .selfUpdate(executablePath: original)
            }
            return .npm(package: kind.npmPackage ?? "@openai/codex")

        case .claudeCode:
            // A `~/.local/bin/claude` shim that happens to symlink into
            // node_modules is still a native user install — prefer self-update.
            if let original, isNativeUserBin(original) {
                return .selfUpdate(executablePath: original)
            }
            if let original, isNodeManagedPath(original), let package = kind.npmPackage {
                return .npm(package: package)
            }
            if let package = kind.npmPackage {
                return .npm(package: package)
            }
            return .nativeInstaller(url: Self.cursorInstallURL)

        case .cursorAgent:
            return .nativeInstaller(url: Self.cursorInstallURL)
        }
    }

    /// Runs the update on the user's login-shell PATH so nvm/brew/fnm resolve.
    public static func update(kind: HarnessKind, executablePath: String?) async throws {
        let plan = plan(for: kind, executablePath: executablePath)
        let command = script(for: plan)
        try await runLoginShell(command, kind: kind)
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

    private static func runLoginShell(_ script: String, kind: HarnessKind) async throws {
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
            throw UpdateError.commandFailed(
                kind: kind, command: script, exitCode: status, output: combined
            )
        }
    }

    /// Follows one level of symlink so `/usr/local/bin/codex` →
    /// `…/node_modules/@openai/codex/…` is classified correctly.
    static func resolvingSymlinks(_ path: String) -> String {
        var current = path
        for _ in 0..<6 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current)
            else { return current }
            if destination.hasPrefix("/") {
                current = destination
            } else {
                let parent = (current as NSString).deletingLastPathComponent
                current = (parent as NSString).appendingPathComponent(destination)
            }
        }
        return current
    }

    static func isHomebrewPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.contains("/homebrew/") || lower.contains("/linuxbrew/") || lower.contains("/cellar/") {
            return true
        }
        let resolved = resolvingSymlinks(path).lowercased()
        return resolved.contains("/homebrew/")
            || resolved.contains("/linuxbrew/")
            || resolved.contains("/cellar/")
    }

    static func isNodeManagedPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let markers = [
            "/.nvm/", "/nvm/versions/", "/.fnm/", "/fnm/node-versions/",
            "/.volta/", "/volta/", "/.nodenv/", "/nodenv/",
            "/node_modules/", "/.npm/", "/npm-global/", "/.asdf/",
        ]
        if markers.contains(where: { lower.contains($0) }) { return true }
        let resolved = resolvingSymlinks(path).lowercased()
        return markers.contains { resolved.contains($0) }
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
