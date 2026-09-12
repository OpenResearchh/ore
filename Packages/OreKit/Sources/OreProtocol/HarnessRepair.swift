import Foundation

/// How the agent CLI on this machine was installed.
///
/// Vocabulary, like `HarnessKind.npmPackage`: the harness layer classifies a
/// path into one of these, and the Mac app — which does not depend on
/// `OreHarness` — reads the result.
public enum HarnessInstallMethod: String, Sendable, Codable, Hashable {
    case homebrew
    /// A global npm install, wherever npm's prefix happens to be.
    case npm
    /// The vendor's own installer, under the user's home (`~/.local/bin`).
    case nativeUserBin
    /// The CLI updates itself (`codex update`, `claude update`).
    case selfUpdate
    case unknown
}

/// Reading an update failure well enough to know whether advice will help.
public enum HarnessUpdateFailure {
    /// Whether this output or message is the "something isn't writable" kind.
    ///
    /// One place, because two surfaces ask: the harness layer, turning a raw
    /// EACCES dump into a sentence, and the app, deciding whether to work out
    /// a repair at all.
    public static func isPermissionProblem(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("eacces")
            || lower.contains("permission denied")
            || lower.contains("operation not permitted")
            || lower.contains("not writable")
            || lower.contains("read-only file system")
    }
}

/// What to run when updating an agent CLI failed because something on disk
/// is not writable.
///
/// ORE deliberately does not run these itself. They need root, and a GUI app
/// willing to run an arbitrary privileged command on request is a far worse
/// thing to have on the machine than one extra paste: the user should read
/// exactly what will run as root and type their own password into their own
/// terminal. ORE's job is to remove every *other* obstacle — name the
/// commands, put them on the clipboard, and open a terminal.
///
/// The advice has to match the install it is repairing. It used to be one
/// line derived from the harness's Homebrew formula, which told a user whose
/// npm install was root-owned to `brew install claude-code` — installing a
/// second copy of the CLI, from a different channel, leaving the broken one
/// still first on `PATH`. That is not a repair; it is a second problem.
public struct HarnessRepair: Sendable, Equatable, Codable, Hashable {
    /// One sentence naming what is actually wrong.
    public var reason: String
    /// The shell lines to run, in order.
    public var commands: [String]
    /// True when any line runs as root, so the card can say so plainly
    /// instead of the user discovering it at the password prompt.
    public var needsRoot: Bool

    public init(reason: String, commands: [String], needsRoot: Bool) {
        self.reason = reason
        self.commands = commands
        self.needsRoot = needsRoot
    }

    /// The whole thing as one pasteable script.
    public var script: String {
        commands.joined(separator: "\n")
    }

    /// Confirms the repair took effect, and is not decoration.
    ///
    /// A shell caches the location of every command it has run, and a broken
    /// install is usually broken *and* first on `PATH`. Without this the user
    /// runs the fix, types the old command, gets the old binary, and
    /// reasonably concludes the fix did nothing.
    static func verification(for kind: HarnessKind) -> [String] {
        let name = kind.defaultExecutableName
        return ["hash -r", "command -v \(name) && \(name) --version"]
    }

    /// The repair for a "not writable" failure, given what was discovered
    /// about the install.
    ///
    /// - Parameters:
    ///   - kind: which agent CLI.
    ///   - method: how it was installed.
    ///   - executablePath: the binary that is actually being run, symlinks
    ///     resolved. Used to scope privileged commands to one directory
    ///     rather than a whole prefix.
    ///   - npmPrefix: `npm config get prefix`, when npm is installed.
    ///   - brewPrefix: `brew --prefix`, when Homebrew is installed.
    public static func forPermissionFailure(
        kind: HarnessKind,
        method: HarnessInstallMethod,
        executablePath: String?,
        npmPrefix: String? = nil,
        brewPrefix: String? = nil
    ) -> HarnessRepair? {
        switch method {
        case .homebrew:
            // Homebrew declines to run as root, so a Cellar owned by someone
            // else is fixed by taking it back — narrowly, for this formula
            // and the bin directory holding its symlink, rather than the
            // `chown -R` on the whole prefix that Homebrew's own error text
            // suggests. A prefix can hold hundreds of unrelated packages.
            guard let formula = kind.brewFormula else {
                return fallback(kind: kind, npmPrefix: npmPrefix)
            }
            guard let brewPrefix else {
                // The path says Homebrew but `brew` is not on PATH: a
                // migrated machine, or an Intel prefix on an Apple Silicon
                // Mac. Reinstalling through Homebrew cannot be the advice.
                return fallback(kind: kind, npmPrefix: npmPrefix)
            }
            return HarnessRepair(
                reason: "Homebrew's files for \(formula) are owned by another user.",
                commands: [
                    "sudo chown -R \"$(whoami)\" "
                        + quote("\(brewPrefix)/Cellar/\(formula)") + " "
                        + quote("\(brewPrefix)/bin"),
                    "brew upgrade \(quote(formula))",
                ] + verification(for: kind),
                needsRoot: true
            )

        case .npm:
            guard let package = kind.npmPackage else {
                return fallback(kind: kind, npmPrefix: npmPrefix)
            }
            // `$(npm config get prefix)` rather than a guess when npm has not
            // been asked: the answer differs per node manager, and a wrong
            // literal path in a `sudo chown` is the one mistake here with
            // consequences.
            let prefix = npmPrefix.map(quote) ?? "\"$(npm config get prefix)\""
            return HarnessRepair(
                reason: "npm's global directory is owned by root — which is what "
                    + "`sudo npm install -g` leaves behind.",
                commands: [
                    // Scoped to this package and its launcher. Not the whole
                    // of `lib/node_modules`, which is every global tool the
                    // user has.
                    "sudo chown -R \"$(whoami)\" "
                        + "\(prefix)/lib/node_modules/\(package) "
                        + "\(prefix)/bin/\(kind.defaultExecutableName)",
                    "npm install -g \(quote(package))@latest",
                ] + verification(for: kind),
                needsRoot: true
            )

        case .nativeUserBin, .selfUpdate:
            guard let executablePath else {
                return fallback(kind: kind, npmPrefix: npmPrefix)
            }
            // A vendor installer run under `sudo` once leaves a root-owned
            // file in the user's own bin directory, and every self-update
            // afterwards fails. Only that file needs to change hands.
            let directory = (executablePath as NSString).deletingLastPathComponent
            return HarnessRepair(
                reason: "\(kind.displayName) is installed at \(executablePath), "
                    + "which this account cannot write to.",
                commands: [
                    "sudo chown -R \"$(whoami)\" \(quote(directory))",
                    "\(quote(executablePath)) update",
                ] + verification(for: kind),
                needsRoot: true
            )

        case .unknown:
            return fallback(kind: kind, npmPrefix: npmPrefix)
        }
    }

    /// When the install cannot be classified, reinstall through the channel
    /// the vendor documents — and do it without root, so a failure here
    /// cannot make the ownership situation any worse than it already is.
    private static func fallback(kind: HarnessKind, npmPrefix: String?) -> HarnessRepair? {
        if let package = kind.npmPackage {
            return HarnessRepair(
                reason: "ORE can't tell where \(kind.displayName) was installed from, "
                    + "so this installs it under your own account instead.",
                commands: [
                    // A user-owned prefix sidesteps the permission problem
                    // entirely rather than arguing with it as root.
                    "npm config set prefix ~/.npm-global",
                    "npm install -g \(quote(package))@latest",
                    // And the new copy has to actually win: the old one is
                    // still on PATH, usually earlier.
                    "echo 'export PATH=\"$HOME/.npm-global/bin:$PATH\"' >> ~/.zshrc",
                    "export PATH=\"$HOME/.npm-global/bin:$PATH\"",
                ] + verification(for: kind),
                needsRoot: false
            )
        }
        guard kind == .cursorAgent else { return nil }
        return HarnessRepair(
            reason: "\(kind.displayName) installs through its own script, which "
                + "replaces whatever is there now.",
            commands: ["curl -fsSL https://cursor.com/install | bash"]
                + verification(for: kind),
            needsRoot: false
        )
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
