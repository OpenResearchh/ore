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
        /// Says what is wrong and nothing about how to fix it. The fix
        /// depends on how that CLI was installed — which this does not know,
        /// and which is why it used to be wrong: it named the harness's
        /// Homebrew formula regardless, so a root-owned npm install was
        /// answered with `brew install`, adding a second copy of the CLI
        /// behind the broken one. `HarnessRepair` answers it instead, from
        /// the install actually on disk.
        static func permissionDeniedMessage(for kind: HarnessKind, in detail: String) -> String? {
            guard HarnessUpdateFailure.isPermissionProblem(detail) else { return nil }
            return """
            Could not update \(kind.displayName): this install is not writable \
            by your user (often a root-owned `/usr/local` npm package).
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

    /// How the CLI at this path was installed, for advice that has to match
    /// the install rather than the harness's preferred channel.
    public static func installMethod(
        for kind: HarnessKind, executablePath: String?
    ) -> HarnessInstallMethod {
        guard let executablePath else { return .unknown }
        if isHomebrewPath(executablePath) { return .homebrew }
        if isNativeUserBin(executablePath) { return .nativeUserBin }
        if isNodeManagedPath(executablePath) { return .npm }
        // A `/usr/local/bin` or `/opt/bin` entry that resolves to neither is
        // most often a `sudo npm install -g` into the system prefix — the
        // very thing that creates the root-owned tree this is diagnosing.
        if kind.npmPackage != nil { return .npm }
        return .unknown
    }

    /// What to tell the user when an update failed on permissions.
    ///
    /// Asks the environment for npm's and Homebrew's real prefixes, so a
    /// privileged command names a directory that exists on *this* machine
    /// rather than a plausible-looking guess.
    public static func permissionRepair(
        for kind: HarnessKind,
        executablePath: String?
    ) async -> HarnessRepair? {
        let method = installMethod(for: kind, executablePath: executablePath)
        async let npmPrefix = method == .npm ? readPrefix("npm config get prefix") : nil
        async let brewPrefix = method == .homebrew ? readPrefix("brew --prefix") : nil
        return HarnessRepair.forPermissionFailure(
            kind: kind,
            method: method,
            executablePath: executablePath.map(resolvingSymlinks),
            npmPrefix: await npmPrefix,
            brewPrefix: await brewPrefix
        )
    }

    /// Runs one short command on the login shell and returns its first line,
    /// or nil if it isn't there. Nil is a usable answer: the repair falls
    /// back to asking the shell itself at paste time.
    private static func readPrefix(_ command: String) async -> String? {
        guard let process = try? ChildProcess(
            executablePath: ShellEnvironment.loginShellPath,
            arguments: ShellEnvironment.commandArguments(
                for: ShellEnvironment.loginShellPath, script: command
            ),
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: ShellEnvironment.childEnvironment()
        ) else { return nil }
        process.closeStandardInput()
        let timer = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await process.terminate(gracePeriod: .milliseconds(200))
        }
        let output = await process.stdoutChunks.collectText()
        let status = await process.waitForExit()
        timer.cancel()
        guard status == 0 else { return nil }
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        guard let line, line.hasPrefix("/") else { return nil }
        return line
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

