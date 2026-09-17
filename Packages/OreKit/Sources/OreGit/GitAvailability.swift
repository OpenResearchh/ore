import Foundation
import OreSupport

/// Whether this machine can run git at all.
///
/// Deliberately a different question from the one the readiness ladder used to
/// ask. That rung checked `user.name` and `user.email` — which only makes
/// sense once git runs — so a Mac with no working git was told to configure
/// its identity, and the real problem surfaced later as a raw git error from
/// whatever the user tried first.
///
/// It matters more on macOS than the ladder's other rungs suggest, because
/// `/usr/bin/git` always exists. It is a stub that asks `xcrun` to find the
/// real binary, and until the Command Line Tools are installed there is
/// nothing behind it. Every "is git installed" check written as
/// `which git != nil` therefore answers yes on a machine where git cannot run.
public enum GitAvailability: Sendable, Equatable {
    /// git runs. The version is whatever `git --version` printed, for display.
    case ready(version: String?)

    /// `/usr/bin/git` is the developer-tools stub and nothing is behind it.
    ///
    /// Detected *without* launching it: running the stub is precisely what
    /// pops the system "install the command line developer tools" dialog, and
    /// a modal the user did not ask for, attributed to no app in particular,
    /// seconds after ORE's first launch is a worse first impression than the
    /// thing it is trying to warn about.
    case commandLineToolsMissing

    /// Nothing named `git` on the resolved PATH.
    case notFound

    /// The probe could not answer — git was found but would not run, or the
    /// launch failed. Distinct from `notFound` so the ladder can stay silent
    /// rather than accuse the user of something that may not be true.
    case unknown

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

extension GitAvailability {
    /// The macOS stub. Not a heuristic on the binary's contents: this is the
    /// fixed path the OS ships, and a real git installed by Homebrew, Xcode or
    /// a version manager resolves somewhere else and is never mistaken for it.
    static let developerToolsStubPath = "/usr/bin/git"

    /// Probes once. Cheap enough to call on each welcome-screen appearance:
    /// one `stat` walk of PATH, and at most one short-lived child process.
    ///
    /// `environment` is injectable so the ladder stays testable without
    /// depending on what happens to be installed on the machine running the
    /// suite.
    public static func probe(
        environment: [String: String]? = nil
    ) async -> GitAvailability {
        let environment = environment ?? GitProcess.gitEnvironment()

        guard let path = ShellEnvironment.locate("git", in: environment) else {
            return .notFound
        }

        #if canImport(Darwin)
        if path == developerToolsStubPath {
            let hasTools = await hasCommandLineTools(environment: environment)
            if !hasTools { return .commandLineToolsMissing }
        }
        #endif

        guard let output = await GitProbe.firstLine(
            executablePath: path,
            arguments: ["--version"],
            environment: environment
        ) else {
            return .unknown
        }
        // The stub can also answer on stderr with an xcrun complaint and a
        // non-zero status, which `firstLine` already turns into nil. A zero
        // exit that printed nothing recognisable is still not proof that git
        // works, so it is `unknown` rather than `ready`.
        guard output.lowercased().contains("git version") else { return .unknown }
        return .ready(version: output)
    }

    /// Whether git has a name and an email to commit with, or nil when git
    /// could not be run at all.
    ///
    /// Lives here rather than in the app so that the one thing it has to get
    /// right — resolving git through the *login-shell* PATH, the same way
    /// every other git call in ORE does — cannot drift. The app's copy used
    /// `/usr/bin/env git` and was the single launch in the whole product that
    /// ignored the probed environment, so on a Mac whose git comes from
    /// Homebrew or a version manager it answered about a different git than
    /// the one ORE commits with.
    ///
    /// Checked without `--global` on purpose: a repository-local identity, or
    /// one supplied by an `includeIf` in the user's gitconfig, is just as
    /// valid, and telling somebody to set a global identity they have
    /// deliberately avoided setting would be wrong.
    ///
    /// nil rather than false when git is unavailable: the ladder must not
    /// accuse somebody of an unset identity when the real problem is that
    /// there is no git.
    public static func probeIdentity(
        environment: [String: String]? = nil
    ) async -> Bool? {
        let environment = environment ?? GitProcess.gitEnvironment()
        guard let path = ShellEnvironment.locate("git", in: environment) else {
            return nil
        }
        #if canImport(Darwin)
        // Same reason as `probe`: never launch the stub.
        if path == developerToolsStubPath {
            let hasTools = await hasCommandLineTools(environment: environment)
            if !hasTools { return nil }
        }
        #endif

        async let name = GitProbe.firstLine(
            executablePath: path,
            arguments: ["config", "--get", "user.name"],
            environment: environment
        )
        async let email = GitProbe.firstLine(
            executablePath: path,
            arguments: ["config", "--get", "user.email"],
            environment: environment
        )
        // Read into locals before combining: `&&` takes an autoclosure, so an
        // `async let` cannot be awaited across it.
        //
        // `git config --get` exits 1 for an unset key, which `firstLine`
        // reports as nil — indistinguishable from a launch failure. That is
        // fine here only because the launch was already proven possible above.
        let resolvedName = (await name) ?? ""
        let resolvedEmail = (await email) ?? ""
        return !resolvedName.isEmpty && !resolvedEmail.isEmpty
    }

    #if canImport(Darwin)
    /// Asks `xcode-select` rather than running git.
    ///
    /// `xcode-select -p` prints the active developer directory and exits
    /// non-zero when there isn't one. Unlike `git` or `xcrun`, it does not
    /// present the install dialog, which is the entire reason this is a
    /// separate question instead of just trying git and reading the error.
    private static func hasCommandLineTools(environment: [String: String]) async -> Bool {
        guard let selectPath = ShellEnvironment.locate("xcode-select", in: environment)
        else {
            // No xcode-select at all is not a machine we can reason about;
            // let the git launch be the judge.
            return true
        }
        guard let directory = await GitProbe.firstLine(
            executablePath: selectPath,
            arguments: ["-p"],
            environment: environment
        ) else { return false }
        return !directory.isEmpty
    }
    #endif
}

/// One short-lived child process, for questions asked before a repository
/// exists. `GitProcess` cannot serve these: it requires a working directory
/// that is a repository, and it throws `GitError` where these want a plain
/// "no answer".
enum GitProbe {
    /// The first line of a command's stdout, or nil if it could not be
    /// launched or exited non-zero.
    static func firstLine(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) async -> String? {
        guard let process = try? ChildProcess(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            environment: environment,
            discardStandardError: true
        ) else { return nil }

        async let text = process.stdoutChunks.collectText()
        process.closeStandardInput()
        let output = await text
        guard await process.waitForExit() == 0 else { return nil }
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
