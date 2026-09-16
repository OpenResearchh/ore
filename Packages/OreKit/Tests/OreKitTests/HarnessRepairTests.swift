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

    /// A cask's files live under `Caskroom`, never `Cellar`. The repair used
    /// to `chown` a `Cellar` directory that does not exist for one, so its
    /// first line failed with "No such file or directory" — latent until
    /// `brewToken` started resolving cask tokens like `claude-code@latest`.
    @Test func aCaskIsRepairedInTheCaskroomNotTheCellar() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .claudeCode,
            method: .homebrew,
            executablePath: "/opt/homebrew/Caskroom/claude-code@latest/2.1.154/claude",
            brewPrefix: "/opt/homebrew",
            brewToken: "claude-code@latest"
        ))

        #expect(repair.script.contains("/opt/homebrew/Caskroom/claude-code@latest"))
        #expect(!repair.script.contains("/opt/homebrew/Cellar"))
        // And the token the install actually names, not the stable cask the
        // user does not have.
        #expect(repair.script.contains("brew upgrade 'claude-code@latest'"))
    }

    /// A bare `bin` symlink names neither, and `Cellar` is what this always
    /// assumed — the formula case is the common one.
    @Test func aHomebrewPathThatNamesNeitherKeepsTheCellar() {
        #expect(
            HarnessRepair.brewKegDirectory(
                prefix: "/opt/homebrew", token: "codex",
                executablePath: "/opt/homebrew/bin/codex"
            ) == "/opt/homebrew/Cellar/codex"
        )
        #expect(
            HarnessRepair.brewKegDirectory(
                prefix: "/usr/local", token: "codex", executablePath: nil
            ) == "/usr/local/Cellar/codex"
        )
    }

    /// A path under a Homebrew prefix on a machine where `brew` is gone —
    /// a migrated Mac, or an Intel prefix on Apple Silicon. Telling that user
    /// to run `brew upgrade` is telling them to run a command they do not have.
    ///
    /// Nor is npm an answer: that machine has no more reason to have node than
    /// it has to have Homebrew. The vendor's script needs neither.
    @Test func aHomebrewPathWithoutHomebrewFallsBackToSomethingRunnable() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .codex,
            method: .homebrew,
            executablePath: "/usr/local/bin/codex",
            brewPrefix: nil
        ))

        #expect(!repair.script.contains("brew upgrade"))
        #expect(!repair.script.contains("npm"))
        #expect(repair.script.contains("curl -fsSL https://chatgpt.com/codex/install.sh | bash"))
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
    ///
    /// And it must not need a toolchain either. This used to open with
    /// `npm config set prefix ~/.npm-global`, which is the first line of a
    /// repair that fails immediately for the user who installed the way ORE's
    /// own onboarding tells them to.
    @Test func anUnclassifiedInstallIsRepairedWithoutRoot() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .claudeCode, method: .unknown, executablePath: nil
        ))

        #expect(!repair.needsRoot)
        #expect(!repair.script.contains("sudo"))
        #expect(!repair.script.contains("npm"))
        #expect(repair.script.contains("curl -fsSL https://claude.ai/install.sh | bash"))
    }

    /// Each CLI's own installer, never another's. The harness whose update
    /// plan ended in Cursor's install script was one edit away from doing this
    /// too.
    @Test func eachHarnessIsRepairedThroughItsOwnInstaller() throws {
        let expected: [HarnessKind: String] = [
            .claudeCode: "https://claude.ai/install.sh",
            .codex: "https://chatgpt.com/codex/install.sh",
            .cursorAgent: "https://cursor.com/install",
        ]
        for (kind, url) in expected {
            let repair = try #require(HarnessRepair.forPermissionFailure(
                kind: kind, method: .unknown, executablePath: nil
            ))
            #expect(repair.script.contains(url), "\(kind)")
            #expect(!repair.needsRoot, "\(kind)")
            for other in expected.values where other != url {
                #expect(!repair.script.contains(other), "\(kind) must not install another CLI")
            }
        }
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

        // And the path is on the result, not only in the prose. Withholding it
        // made `isInstalled` false, so the readiness ladder told this user to
        // install an agent that is sitting right there — the one thing that
        // cannot help. `isUnlaunchable` is what keeps them off the "sign in"
        // rung instead.
        #expect(result.executablePath == "/opt/homebrew/bin/claude")
        #expect(result.isUnlaunchable == true)
        #expect(result.isInstalled)
    }

    /// The field is optional so an older serialized probe still decodes, and
    /// nil has to keep meaning what it meant before it existed.
    @Test func aProbeFromBeforeTheFieldExistedStillDecodes() throws {
        let legacy = Data(#"""
        {"kind":"claudeCode","executablePath":"/usr/local/bin/claude","authState":"authenticated"}
        """#.utf8)
        let decoded = try JSONDecoder().decode(HarnessProbeResult.self, from: legacy)
        #expect(decoded.isUnlaunchable == nil)
        #expect(decoded.shadowedPaths == nil)
        #expect(decoded.isReady)
    }

    // MARK: - Two copies on PATH

    /// "I updated it and ORE still shows the old version" is usually two
    /// copies from two channels: the updater upgrades the one the probe found,
    /// and PATH goes on running the other.
    @Test func everyOtherCopyOnPathIsRecorded() {
        let copies = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/Users/me/.local/bin/claude",
        ]
        #expect(
            HarnessPathScan.shadowed(among: copies, winner: "/opt/homebrew/bin/claude")
                == ["/usr/local/bin/claude", "/Users/me/.local/bin/claude"]
        )
        // One install is the ordinary case, and nil rather than [] keeps
        // "nothing to report" spelled exactly one way.
        #expect(HarnessPathScan.shadowed(among: ["/usr/local/bin/claude"],
                                         winner: "/usr/local/bin/claude") == nil)
        #expect(HarnessPathScan.shadowed(among: [], winner: "/usr/local/bin/claude") == nil)
    }

    /// `executablePathOverride` points ORE at a copy that is deliberately not
    /// on PATH. Reporting every PATH copy as "shadowed" states the
    /// relationship backwards — those are the ones a shell reaches.
    @Test func anOffPathWinnerReportsNothingAsShadowed() {
        let copies = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        #expect(
            HarnessPathScan.shadowed(among: copies, winner: "/Users/me/custom/claude") == nil
        )
    }

    /// The walk itself, against a PATH built for the test: real directories,
    /// no agent CLI required.
    @Test func thePathWalkFindsEveryCopyInSearchOrder() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ore-path-scan-\(UUID().uuidString)")
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let empty = root.appendingPathComponent("empty")
        for directory in [first, second, empty] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        for directory in [first, second] {
            #expect(FileManager.default.createFile(
                atPath: directory.appendingPathComponent("codex").path,
                contents: Data("#!/bin/sh\n".utf8),
                attributes: [.posixPermissions: 0o755]
            ))
        }
        // A directory that happens to be named like the executable is not one.
        try FileManager.default.createDirectory(
            at: empty.appendingPathComponent("codex"), withIntermediateDirectories: true
        )

        let environment = ["PATH": "\(first.path):\(empty.path):\(second.path)"]
        let found = HarnessPathScan.copies(of: ["codex"], in: environment)
        #expect(found == [
            first.appendingPathComponent("codex").path,
            second.appendingPathComponent("codex").path,
        ])
        #expect(
            HarnessPathScan.shadowed(
                of: ["codex"], winner: first.appendingPathComponent("codex").path,
                in: environment
            ) == [second.appendingPathComponent("codex").path]
        )
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
