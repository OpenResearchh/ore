import Foundation
import Testing

@testable import OreCore
@testable import OreGit
@testable import OreHarness
@testable import OreProtocol

/// The command ORE hands a user whose CLI update failed on permissions.
///
/// It has to repair the install that is actually on the machine. The version
/// this replaced derived one line from the harness's Homebrew formula
/// regardless of how the CLI got there, so a root-owned npm install was
/// answered with `brew install claude-code` — which installs a second copy
/// from a different channel and leaves the broken one still first on `PATH`.
struct HarnessRepairTests {
    // MARK: - Homebrew

    @Test func aHomebrewInstallIsRepairedInItsOwnPrefix() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .codex,
            method: .homebrew,
            executablePath: "/opt/homebrew/bin/codex",
            brewPrefix: "/opt/homebrew"
        ))

        #expect(repair.needsRoot)
        #expect(repair.script.contains("/opt/homebrew/Cellar/codex"))
        #expect(repair.script.contains("brew upgrade 'codex'"))
        // Not the whole prefix: it holds every other package the user has.
        #expect(!repair.script.contains("chown -R \"$(whoami)\" '/opt/homebrew'"))
        #expect(!repair.script.contains("npm"))
    }

    /// A path under a Homebrew prefix on a machine where `brew` is gone —
    /// a migrated Mac, or an Intel prefix on Apple Silicon. Telling that user
    /// to run `brew upgrade` is telling them to run a command they do not have.
    @Test func aHomebrewPathWithoutHomebrewFallsBackToSomethingRunnable() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .codex,
            method: .homebrew,
            executablePath: "/usr/local/bin/codex",
            brewPrefix: nil
        ))

        #expect(!repair.script.contains("brew upgrade"))
        #expect(repair.script.contains("npm install -g '@openai/codex'@latest"))
        #expect(!repair.needsRoot, "the fallback installs under the user's own account")
    }

    // MARK: - npm

    @Test func anNpmInstallIsRepairedNarrowlyAtItsOwnPrefix() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .claudeCode,
            method: .npm,
            executablePath: "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js",
            npmPrefix: "/usr/local"
        ))

        #expect(repair.needsRoot)
        #expect(repair.script.contains(
            "'/usr/local'/lib/node_modules/@anthropic-ai/claude-code"
        ))
        // The launcher too: the package directory alone leaves the symlink
        // root-owned and the next update fails the same way.
        #expect(repair.script.contains("'/usr/local'/bin/claude"))
        // And not every other global tool the user has installed.
        #expect(!repair.script.contains("chown -R \"$(whoami)\" '/usr/local'/lib/node_modules "))
        #expect(repair.script.contains("npm install -g '@anthropic-ai/claude-code'@latest"))
    }

    /// npm's prefix depends on the node manager, so where it was not asked,
    /// the command asks at paste time rather than guessing a literal path
    /// into a `sudo chown`.
    @Test func anUnknownNpmPrefixIsResolvedByTheShellNotGuessed() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .codex, method: .npm, executablePath: "/usr/local/bin/codex"
        ))

        #expect(repair.script.contains("$(npm config get prefix)"))
        #expect(!repair.script.contains("'/usr/local'"))
    }

    // MARK: - Native installs

    @Test func aNativeInstallIsRepairedWhereItLives() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .claudeCode,
            method: .nativeUserBin,
            executablePath: "/Users/me/.local/bin/claude"
        ))

        #expect(repair.needsRoot, "a sudo-installed file in your own bin needs root to take back")
        #expect(repair.script.contains("chown -R \"$(whoami)\" '/Users/me/.local/bin'"))
        #expect(repair.script.contains("'/Users/me/.local/bin/claude' update"))
        #expect(!repair.script.contains("brew"))
        #expect(!repair.script.contains("npm"))
        #expect(repair.reason.contains("/Users/me/.local/bin/claude"))
    }

    @Test func aSelfUpdatingInstallRepairsItsOwnDirectory() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .codex, method: .selfUpdate, executablePath: "/opt/tools/bin/codex"
        ))

        #expect(repair.script.contains("'/opt/tools/bin'"))
        #expect(repair.script.contains("'/opt/tools/bin/codex' update"))
    }

    // MARK: - Unknown installs

    /// With no idea what is on disk, the advice must not run anything as
    /// root: a privileged command aimed at a directory we guessed is the one
    /// mistake here with consequences.
    @Test func anUnclassifiedInstallIsRepairedWithoutRoot() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .claudeCode, method: .unknown, executablePath: nil
        ))

        #expect(!repair.needsRoot)
        #expect(!repair.script.contains("sudo"))
        #expect(repair.script.contains("npm config set prefix ~/.npm-global"))
    }

    /// The old copy is still on `PATH`, usually earlier, so a repair that
    /// installs a working binary somewhere the shell will not look has fixed
    /// nothing the user can see.
    @Test func aUserPrefixRepairAlsoPutsItselfOnThePath() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .codex, method: .unknown, executablePath: nil
        ))

        #expect(repair.script.contains("$HOME/.npm-global/bin:$PATH"))
    }

    @Test func cursorIsRepairedThroughItsOwnInstaller() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .cursorAgent, method: .unknown, executablePath: nil
        ))

        #expect(repair.script.contains("https://cursor.com/install"))
        #expect(!repair.needsRoot)
    }

    // MARK: - Every repair

    /// A shell remembers where it found a command. Without clearing that, the
    /// user runs the fix, runs the CLI, gets the old binary, and concludes the
    /// fix did nothing.
    @Test func everyRepairEndsByProvingItWorked() throws {
        let cases: [(HarnessKind, HarnessInstallMethod, String?)] = [
            (.codex, .homebrew, "/opt/homebrew/bin/codex"),
            (.claudeCode, .npm, "/usr/local/bin/claude"),
            (.claudeCode, .nativeUserBin, "/Users/me/.local/bin/claude"),
            (.codex, .unknown, nil),
            (.cursorAgent, .unknown, nil),
        ]
        for (kind, method, path) in cases {
            let repair = try #require(HarnessRepair.forPermissionFailure(
                kind: kind, method: method, executablePath: path, brewPrefix: "/opt/homebrew"
            ))
            #expect(repair.commands.contains("hash -r"), "\(kind) \(method)")
            #expect(
                repair.commands.last?.contains(kind.defaultExecutableName) == true,
                "\(kind) \(method) should end by running the CLI"
            )
        }
    }

    @Test func aPathWithAQuoteInItIsStillQuotedSafely() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .codex, method: .selfUpdate, executablePath: "/Users/o'brien/bin/codex"
        ))

        #expect(repair.script.contains("'/Users/o'\\''brien/bin'"))
    }

    // MARK: - A CLI that is present but cannot be launched

    /// Quarantined by Gatekeeper, missing its `+x` bit, a symlink into a
    /// version manager that has been uninstalled, a binary on a network volume
    /// that is no longer mounted: every one of these read as *ready*, because
    /// "launched and said nothing" and "never launched" were the same `nil`
    /// and an `.unknown` auth state counts as ready.
    @Test func aBinaryThatCannotLaunchIsNotReady() {
        let reason = "dyld: Library not loaded: @rpath/libnode.dylib"
        let outcome = CommandProbe.classify(
            standardOutput: "", standardError: reason, exitStatus: 133
        )
        #expect(outcome == .couldNotLaunch(reason))

        let result = HarnessDiagnostic.unlaunchable(
            kind: .claudeCode,
            path: "/opt/homebrew/bin/claude",
            reason: outcome.spokenText ?? ""
        )
        #expect(!result.isReady)
        #expect(result.authState == .notAuthenticated)
        // The path, because "reinstall your agent" is unactionable without
        // knowing which copy ORE is talking about, and the CLI's own reason,
        // because it is the only thing that says what to fix.
        #expect(result.diagnostic?.contains("/opt/homebrew/bin/claude") == true)
        #expect(result.diagnostic?.contains("libnode") == true)
    }

    /// The other two outcomes keep their old meanings. A CLI that exits
    /// cleanly with nothing to say is still just unknown — that is what keeps
    /// one without a `--version` flag usable.
    @Test func silenceFromAHealthyBinaryIsNotALaunchFailure() {
        #expect(
            CommandProbe.classify(standardOutput: "", standardError: "", exitStatus: 0) == .empty
        )
        #expect(
            CommandProbe.classify(
                standardOutput: "2.0.14 (Claude Code)\n",
                standardError: "warning: update available",
                exitStatus: 0
            ) == .text("2.0.14 (Claude Code)")
        )
        // An answer outranks a failing exit: a CLI that printed its version
        // and then exited non-zero has still answered the question.
        #expect(
            CommandProbe.classify(standardOutput: "1.0.0", standardError: "", exitStatus: 1)
                == .text("1.0.0")
        )
    }

    /// The flag exists so an `ANTHROPIC_API_KEY` user is not stuck being told
    /// to run a sign-in command that cannot help them. It has to reach the
    /// *probes*, not only sessions, and it has to stay off by default:
    /// stripping those variables is the safeguard that keeps a subscription
    /// session off metered billing.
    @Test func probesHonourTheAPIKeyFallbackFlag() {
        let optedIn = HarnessRegistry.standard(allowAPIKeyFallback: true)
        #expect(
            (optedIn.harness(for: .claudeCode) as? ClaudeCodeHarness)?.allowAPIKeyFallback == true
        )
        #expect((optedIn.harness(for: .codex) as? CodexHarness)?.allowAPIKeyFallback == true)
        #expect(
            (optedIn.harness(for: .cursorAgent) as? CursorAgentHarness)?.allowAPIKeyFallback == true
        )

        let standard = HarnessRegistry.standard()
        #expect(
            (standard.harness(for: .claudeCode) as? ClaudeCodeHarness)?.allowAPIKeyFallback == false
        )
        #expect((standard.harness(for: .codex) as? CodexHarness)?.allowAPIKeyFallback == false)
    }

    // MARK: - A CLI that only exists inside the shell

    /// "Not found on PATH" sends a user to reinstall something they already
    /// have, when what they have is an alias or a shell function — which ORE
    /// genuinely cannot launch, but should at least name.
    @Test func aCommandThatOnlyTheShellKnowsIsNamedAsSuch() throws {
        let output = """
        nvm: version 0.39.7
        __ORE_CV_BEGIN__
        claude: aliased to /Users/me/bin/claude-wrapper --yes
        __ORE_CV_END__
        """
        let answer = try #require(ShellAliasProbe.parse(output))
        let note = try #require(
            ShellAliasProbe.interpret(answer: answer, executableName: "claude")
        )
        #expect(note.contains("alias or function"))

        // A real file the shell can see and ORE cannot is a PATH problem, and
        // saying "alias" there would send the user looking for one.
        let onDisk = try #require(ShellAliasProbe.interpret(
            answer: "/Users/me/.bun/bin/claude", executableName: "claude"
        ))
        #expect(onDisk.contains("/Users/me/.bun/bin/claude"))
        #expect(!onDisk.contains("alias"))
    }

    /// Profile banners print before the answer, and parsing them as the answer
    /// is how a version-manager notice becomes "your CLI is an alias".
    @Test func aShellThatAnswersNothingIsNotGuessedAt() {
        #expect(ShellAliasProbe.parse("some banner with no markers at all") == nil)
        #expect(ShellAliasProbe.parse("__ORE_CV_BEGIN__\n\n__ORE_CV_END__") == nil)
    }

    // MARK: - GitHub

    /// The card's job is to say *which* GitHub is connected. An exit code
    /// cannot: an enterprise host the repository's remote has never heard of
    /// passes `gh auth status` exactly like the right account does.
    @Test func ghStatusNamesTheHostItIsConnectedTo() {
        let report = """
        github.example.com
          ✓ Logged in to github.example.com account ada (keyring)
          - Active account: true
          - Token: gho_************************
          - Token scopes: 'repo', 'workflow'
        """
        // Older `gh` writes the report to stderr, current ones to stdout.
        let summary = GitHubClient.connectionSummary(
            GitOutput(exitCode: 0, standardOutput: "", standardError: report)
        )
        #expect(summary == "Logged in to github.example.com account ada (keyring)")
        // Not the token line, and not the scopes.
        #expect(summary?.contains("gho_") == false)
        #expect(GitHubClient.connectionSummary(nil) == nil)
    }
}
