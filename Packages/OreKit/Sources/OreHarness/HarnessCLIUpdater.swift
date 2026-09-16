import Foundation
import OreProtocol
import OreSupport

/// Updates the user's locally installed agent CLI.
///
/// ORE never vendors these binaries — it drives whatever the user already has
/// on PATH — so a model that "requires a newer version of Codex" is a prompt
/// to upgrade *their* install, not ours. Detection follows the path: Homebrew
/// prefixes go through `brew upgrade` (when brew is still there, and for the
/// token the install actually names), Codex prefers its own `codex update`,
/// node version-manager trees go through `npm install -g`, and everything else
/// through the vendor's install script.
///
/// The ordering is deliberate and one-directional: a channel is only used when
/// this machine demonstrably has it. Every arm of this that guessed — brew from
/// a path shape, npm for anything unclassified — sent somebody to run a command
/// they did not have.
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
        /// Refused before running anything, because the volume cannot hold the
        /// download and the unpacked copy.
        case insufficientDiskSpace(kind: HarnessKind, availableBytes: Int64, requiredBytes: Int64)

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
            case .insufficientDiskSpace(let kind, let available, let required):
                return Self.diskSpaceMessage(
                    kind: kind, available: available, required: required
                )
            }
        }

        /// Names the shortfall, not just the refusal.
        ///
        /// "Not enough disk space" sends the user to look at a Finder number
        /// that will not obviously be too small — the floor an update needs is
        /// bigger than what it finally occupies, because npm and Homebrew both
        /// unpack a second copy before swapping it in.
        static func diskSpaceMessage(
            kind: HarnessKind, available: Int64, required: Int64
        ) -> String {
            let short = max(required - available, 0)
            return "Not enough disk space to update \(kind.displayName): "
                + "\(describeBytes(required)) free is needed and "
                + "\(describeBytes(available)) is left — about "
                + "\(describeBytes(short)) short. Free up space and try again."
        }

        /// Deliberately not `ByteCountFormatter`: this string is asserted in
        /// tests, and the formatter's output changes with the user's locale.
        static func describeBytes(_ bytes: Int64) -> String {
            let gigabytes = Double(bytes) / 1_000_000_000
            if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
            return "\(max(bytes, 0) / 1_000_000) MB"
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

    /// - Parameter isBrewAvailable: whether `brew` is really on this machine.
    ///   Resolved from `PATH` by default; injected by tests so a plan does not
    ///   depend on what the machine running them happens to have installed.
    public static func plan(
        for kind: HarnessKind,
        executablePath: String?,
        isBrewAvailable: Bool = Self.brewIsAvailable(),
        resolve: PathResolver = Self.resolvingSymlinks
    ) -> Plan {
        // Keep the PATH entry the user actually runs in the update script.
        // Classification helpers resolve symlinks themselves when needed.
        let original = executablePath
        let method = installMethod(for: kind, executablePath: original, resolve: resolve)

        // A Homebrew *path* is not Homebrew. A Mac migrated from another one
        // keeps `/opt/homebrew/bin/codex` long after brew itself is gone, and
        // the plan inferred from that path shape ran `brew upgrade` →
        // `command not found`. `HarnessRepair` already refuses to prescribe a
        // brew it cannot find; this is the same rule for the update button.
        if method == .homebrew, isBrewAvailable,
           let token = brewToken(for: kind, executablePath: original) {
            return .brew(formula: token)
        }

        switch kind {
        case .codex:
            // Codex's own updater, where there is a binary to ask. If the
            // subcommand turns out not to exist, `update` retries through
            // `fallbackPlan` rather than failing — see `isUnknownSubcommand`.
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
            // npm only where the install really is npm's. This used to be the
            // unconditional answer, including for the install ORE itself now
            // recommends — the vendor's script, which leaves a machine with a
            // working `claude` and no `npm` at all.
            if method == .npm, let package = kind.npmPackage {
                return .npm(package: package)
            }
            return .nativeInstaller(url: kind.nativeInstallerURL)

        case .cursorAgent:
            return .nativeInstaller(url: kind.nativeInstallerURL)
        }
    }

    /// The channel to try when a CLI's own updater turns out not to exist.
    ///
    /// Same rule as `plan`: npm only for an npm-managed install, the vendor's
    /// script otherwise, because a fallback that needs a toolchain the user
    /// does not have has only changed which error they see.
    static func fallbackPlan(for kind: HarnessKind, executablePath: String?) -> Plan {
        if installMethod(for: kind, executablePath: executablePath) == .npm,
           let package = kind.npmPackage {
            return .npm(package: package)
        }
        return .nativeInstaller(url: kind.nativeInstallerURL)
    }

    /// Whether Homebrew itself is installed, as opposed to having once been.
    public static func brewIsAvailable() -> Bool {
        ShellEnvironment.locate("brew") != nil
    }

    /// The Homebrew token this install actually came from.
    ///
    /// Homebrew ships some CLIs under more than one token — Anthropic
    /// publishes `claude-code` and `claude-code@latest` — and assuming the
    /// stable one broke both halves of the feature for anyone on the other:
    /// `brew upgrade claude-code` upgrades a cask they do not have, while the
    /// version oracle reads the stable cask's release and under-reports what
    /// they could be running. A Cellar or Caskroom path names its own token,
    /// so read it rather than assume, and keep the stable token for the
    /// installs (a bare `/opt/homebrew/bin` symlink into nothing readable)
    /// that cannot say.
    static func brewToken(for kind: HarnessKind, executablePath: String?) -> String? {
        guard let brewFormula = kind.brewFormula else { return nil }
        guard let executablePath else { return brewFormula }
        for candidate in [executablePath, resolvingSymlinks(executablePath)] {
            guard let token = homebrewPathToken(in: candidate), kind.ownsBrewToken(token)
            else { continue }
            return token
        }
        return brewFormula
    }

    /// The token component of `…/Cellar/<token>/<version>/…` or
    /// `…/Caskroom/<token>/<version>/…`. Pure, and unvalidated: the caller
    /// decides whether the token is one this harness may act on.
    static func homebrewPathToken(in path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        for (index, component) in components.enumerated() {
            let lower = component.lowercased()
            guard lower == "cellar" || lower == "caskroom" else { continue }
            let next = components.index(after: index)
            guard next < components.endIndex else { return nil }
            return String(components[next])
        }
        return nil
    }

    /// How the CLI at this path was installed, for advice that has to match
    /// the install rather than the harness's preferred channel.
    public static func installMethod(
        for kind: HarnessKind,
        executablePath: String?,
        resolve: PathResolver = Self.resolvingSymlinks
    ) -> HarnessInstallMethod {
        guard let executablePath else { return .unknown }
        // A Homebrew *prefix* is not a Homebrew *package*. `brew install node`
        // followed by `npm install -g` leaves the CLI in
        // `/opt/homebrew/lib/node_modules/…` with its launcher in
        // `/opt/homebrew/bin` — a very common setup that was being answered
        // with `brew upgrade claude-code`, which installs a whole second copy
        // from the cask alongside the npm one. The node tree is the tell, and
        // it wins: no cask ORE knows ships one.
        if isHomebrewPath(executablePath, resolve: resolve),
           !isNodeManagedPath(executablePath, resolve: resolve) {
            return .homebrew
        }
        if isNativeUserBin(executablePath) { return .nativeUserBin }
        if isNodeManagedPath(executablePath, resolve: resolve) { return .npm }
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
        // Read off the path, not assumed: the repair ends in `brew upgrade`,
        // and upgrading the cask the user does not have is a repair that
        // reports success and changes nothing.
        let resolvedBrewToken = method == .homebrew
            ? brewToken(for: kind, executablePath: executablePath) : nil
        async let npmPrefix = method == .npm ? readPrefix("npm config get prefix") : nil
        async let brewPrefix = method == .homebrew ? readPrefix("brew --prefix") : nil
        return HarnessRepair.forPermissionFailure(
            kind: kind,
            method: method,
            executablePath: executablePath.map(resolvingSymlinks),
            npmPrefix: await npmPrefix,
            brewPrefix: await brewPrefix,
            brewToken: resolvedBrewToken
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
        // Before anything runs: an update that fills the disk half-way through
        // leaves a partially unpacked package where a working CLI used to be,
        // which is a worse outcome than refusing with a number.
        if let available = availableBytesForUpdate(),
           available < requiredFreeBytes {
            throw UpdateError.insufficientDiskSpace(
                kind: kind, availableBytes: available, requiredBytes: requiredFreeBytes
            )
        }

        let plan = plan(for: kind, executablePath: executablePath)
        do {
            try await runLoginShell(script(for: plan), kind: kind)
        } catch let error as UpdateError {
            guard case .selfUpdate = plan,
                  !selfUpdateIsConfirmed(for: kind),
                  case .commandFailed(_, _, let exitCode, let output) = error,
                  isUnknownSubcommand(output: output, exitCode: exitCode)
            else { throw error }
            // The CLI has no `update` subcommand. Nobody has confirmed that it
            // does, and a guess that is wrong takes every update in ORE down
            // with it — so treat it as a fact learned at runtime and finish
            // the job through the channel the install itself implies.
            try await runLoginShell(
                script(for: fallbackPlan(for: kind, executablePath: executablePath)), kind: kind
            )
        }
    }

    /// Whether this CLI's `update` subcommand is known to exist.
    ///
    /// `claude update` is documented and confirmed, so nothing about its
    /// failures should be reinterpreted. `codex update` is not: it may well
    /// be there, but ORE would rather recover from its absence than take
    /// every Codex update down on the strength of an assumption.
    static func selfUpdateIsConfirmed(for kind: HarnessKind) -> Bool {
        switch kind {
        case .claudeCode: return true
        case .codex, .cursorAgent: return false
        }
    }

    /// Whether a failed command is the CLI saying it has no such subcommand.
    ///
    /// Pure, because the alternative is confirming `codex update` exists on
    /// every machine ORE runs on. The wordings are the ones the common
    /// argument parsers print (clap, cobra, commander, argparse); the exit
    /// code is clap's and argparse's convention for "your arguments did not
    /// parse", which is why it only counts alongside usage text — plenty of
    /// genuine update failures exit 2.
    static func isUnknownSubcommand(output: String, exitCode: Int32) -> Bool {
        let lower = output.lowercased()
        let phrases = [
            "unknown subcommand", "unrecognized subcommand", "unrecognised subcommand",
            "unknown command", "unrecognized command", "unrecognised command",
            "invalid command", "no such subcommand", "unexpected argument",
            "unknown argument", "is not a valid", "is not a recognized",
        ]
        if phrases.contains(where: { lower.contains($0) }) { return true }
        return exitCode == 2 && lower.contains("usage:")
    }

    /// Room to require before starting. Both npm and Homebrew download an
    /// archive and unpack a full second copy of the tree before swapping it
    /// in, so the floor is several times what the CLI finally occupies.
    static let requiredFreeBytes: Int64 = 1_000_000_000

    /// Free space on the volume the update will land on, or nil when the
    /// volume will not say — in which case the update proceeds, because
    /// refusing on an unanswered question is worse than the risk.
    static func availableBytesForUpdate(
        at url: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Int64? {
        #if canImport(Darwin)
        // "Important usage" is the one that accounts for purgeable space, so
        // it answers the question the user would ask: how much could this
        // machine actually give me?
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int64(capacity)
        #else
        // A different API entirely on Linux, not just a different accessor:
        // the CI build here is what keeps the headless core honest, and
        // `volumeAvailableCapacityForImportantUsage` is a purgeable-space
        // notion that swift-corelibs-foundation has no reason to carry. Naming
        // the resource key at all — even only to read `allValues` — would have
        // been enough to break that build. `systemFreeSize` is plain statfs,
        // which is the closest thing Linux has to the question.
        guard let attributes = try? FileManager.default
            .attributesOfFileSystem(forPath: url.path),
            let free = attributes[.systemFreeSize] as? NSNumber
        else { return nil }
        return free.int64Value
        #endif
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

    /// How a path is followed to its real location.
    ///
    /// Injectable because the classifiers below are otherwise not testable:
    /// they resolve against the *real* filesystem, so asserting that
    /// `/opt/homebrew/bin/codex` is a Homebrew install quietly depends on the
    /// machine running the suite not happening to have a Homebrew-node install
    /// at that exact path. That is a test that passes on CI and fails on the
    /// laptop of the one contributor it describes.
    typealias PathResolver = (String) -> String

    static func isHomebrewPath(
        _ path: String, resolve: PathResolver = Self.resolvingSymlinks
    ) -> Bool {
        let lower = path.lowercased()
        if lower.contains("/homebrew/") || lower.contains("/linuxbrew/") || lower.contains("/cellar/") {
            return true
        }
        let resolved = resolve(path).lowercased()
        return resolved.contains("/homebrew/")
            || resolved.contains("/linuxbrew/")
            || resolved.contains("/cellar/")
    }

    static func isNodeManagedPath(
        _ path: String, resolve: PathResolver = Self.resolvingSymlinks
    ) -> Bool {
        let lower = path.lowercased()
        let markers = [
            "/.nvm/", "/nvm/versions/", "/.fnm/", "/fnm/node-versions/",
            "/.volta/", "/volta/", "/.nodenv/", "/nodenv/",
            "/node_modules/", "/.npm/", "/npm-global/", "/.asdf/",
        ]
        if markers.contains(where: { lower.contains($0) }) { return true }
        let resolved = resolve(path).lowercased()
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

