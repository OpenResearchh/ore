import Foundation
import Testing

@testable import OreHarness
@testable import OreProtocol

struct HarnessCLIUpdaterTests {
    /// `resolve: { $0 }` on purpose. The classifiers follow symlinks against
    /// the real filesystem, so without it this asserts something about the
    /// machine running the suite — it would flip to `.npm` on any Mac that
    /// genuinely has `/opt/homebrew/bin/codex` symlinked into a Homebrew-node
    /// `node_modules` tree, which is a setup this very code exists to handle.
    @Test func homebrewCodexUsesBrewUpgrade() {
        let plan = HarnessCLIUpdater.plan(
            for: .codex,
            executablePath: "/opt/homebrew/bin/codex",
            isBrewAvailable: true,
            resolve: { $0 }
        )
        #expect(plan == .brew(formula: "codex"))
        #expect(HarnessCLIUpdater.script(for: plan) == "brew upgrade 'codex'")
    }

    @Test func nvmClaudeUsesNpm() {
        let plan = HarnessCLIUpdater.plan(
            for: .claudeCode,
            executablePath: "/Users/me/.nvm/versions/node/v22.0.0/bin/claude",
            resolve: { $0 }
        )
        #expect(plan == .npm(package: "@anthropic-ai/claude-code"))
        #expect(HarnessCLIUpdater.script(for: plan).contains("npm install -g '@anthropic-ai/claude-code'@latest"))
    }

    @Test func unknownCodexPathFallsBackToNpm() {
        let plan = HarnessCLIUpdater.plan(for: .codex, executablePath: nil)
        #expect(plan == .npm(package: "@openai/codex"))
    }

    @Test func installedCodexPrefersSelfUpdate() {
        let plan = HarnessCLIUpdater.plan(
            for: .codex,
            executablePath: "/usr/local/bin/codex",
            resolve: { $0 }
        )
        #expect(plan == .selfUpdate(executablePath: "/usr/local/bin/codex"))
        #expect(HarnessCLIUpdater.script(for: plan) == "'/usr/local/bin/codex' update")
    }

    @Test func permissionDeniedNpmOutputBecomesActionable() {
        let raw = """
        npm error code EACCES
        npm error Error: EACCES: permission denied, rename '/usr/local/lib/node_modules/@openai/codex'
        """
        let error = HarnessCLIUpdater.UpdateError.commandFailed(
            kind: .codex,
            command: "npm install -g '@openai/codex'@latest",
            exitCode: 1,
            output: raw
        )
        let message = error.errorDescription ?? ""
        #expect(message.contains("not writable by your user"))
        #expect(!message.contains("npm error"))
    }

    /// Shipped in v0.7.1: the Claude Code update card rendered
    /// "Reinstall with Homebrew (`brew install codex`)", pointing the user at a
    /// different agent's CLI. The message names the harness that failed — and
    /// no longer prescribes a channel at all, because the message does not
    /// know which one this install came from. See `HarnessRepairTests`.
    @Test func permissionDeniedNamesTheHarnessBeingUpdated() {
        let raw = "Error: EACCES: permission denied, open '/usr/local/lib/node_modules'"
        let error = HarnessCLIUpdater.UpdateError.commandFailed(
            kind: .claudeCode,
            command: "'/Users/someone/.local/bin/claude' update",
            exitCode: 1,
            output: raw
        )
        let message = error.errorDescription ?? ""
        #expect(message.contains("Claude Code"))
        #expect(!message.contains("codex"))
        #expect(!message.contains("brew install"), "the channel is the repair's business")
    }

    @Test func aPermissionFailureIsRecognisedHoweverItIsWorded() {
        for output in [
            "npm error code EACCES",
            "Error: permission denied",
            "mkdir: Operation not permitted",
            "/usr/local/bin is not writable",
            "cp: Read-only file system",
        ] {
            #expect(HarnessUpdateFailure.isPermissionProblem(output), "\(output)")
        }
        #expect(!HarnessUpdateFailure.isPermissionProblem("network timeout"))
    }

    // MARK: - Which install is being repaired

    @Test func aHomebrewPathIsRecognisedAsHomebrew() {
        #expect(HarnessCLIUpdater.installMethod(
            for: .codex, executablePath: "/opt/homebrew/bin/codex", resolve: { $0 }
        ) == .homebrew)
    }

    @Test func aNodeManagedPathIsRecognisedAsNpm() {
        #expect(HarnessCLIUpdater.installMethod(
            for: .claudeCode,
            executablePath: "/Users/me/.nvm/versions/node/v22.0.0/bin/claude",
            resolve: { $0 }
        ) == .npm)
    }

    @Test func theVendorsOwnBinDirectoryIsANativeInstall() {
        let path = FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/claude"
        #expect(
            HarnessCLIUpdater.installMethod(
                for: .claudeCode, executablePath: path, resolve: { $0 }
            ) == .nativeUserBin
        )
    }

    /// A bare `/usr/local/bin` entry is almost always `sudo npm install -g`,
    /// which is the install this whole path exists to repair.
    @Test func aSystemPrefixEntryIsTreatedAsAGlobalNpmInstall() {
        #expect(HarnessCLIUpdater.installMethod(
            for: .codex, executablePath: "/usr/local/bin/codex", resolve: { $0 }
        ) == .npm)
    }

    @Test func noPathMeansNoClassification() {
        #expect(HarnessCLIUpdater.installMethod(for: .codex, executablePath: nil) == .unknown)
    }

    @Test func cursorWithoutAKnownPathUsesTheVendorInstaller() {
        let plan = HarnessCLIUpdater.plan(for: .cursorAgent, executablePath: nil)
        guard case .nativeInstaller(let url) = plan else {
            Issue.record("expected the Cursor installer, got \(plan)")
            return
        }
        #expect(url.contains("cursor.com"))
    }

    @Test func nativeClaudeBinUsesSelfUpdate() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = home + "/.local/bin/claude"
        let plan = HarnessCLIUpdater.plan(for: .claudeCode, executablePath: path, resolve: { $0 })
        #expect(plan == .selfUpdate(executablePath: path))
    }

    // MARK: - Which Homebrew package

    /// Anthropic publishes two casks. A user on `claude-code@latest` was sent
    /// `brew upgrade claude-code` — a cask they do not have — so the button
    /// reported success and changed nothing, while the version oracle read the
    /// stable cask and under-reported what they could be running.
    @Test func theInstalledCaskIsReadFromThePathNotAssumed() {
        let latest = "/opt/homebrew/Caskroom/claude-code@latest/2.1.263/claude"
        let plan = HarnessCLIUpdater.plan(
            for: .claudeCode, executablePath: latest, isBrewAvailable: true
        )
        #expect(plan == .brew(formula: "claude-code@latest"))
        #expect(HarnessCLIUpdater.script(for: plan) == "brew upgrade 'claude-code@latest'")

        // And the version oracle has to follow the same cask, or the card
        // offers an upgrade that cannot land.
        #expect(
            HarnessUpdateChecker.source(
                for: .claudeCode, executablePath: latest, isBrewAvailable: true
            ) == .homebrew(token: "claude-code@latest")
        )
    }

    @Test func aStableCaskKeepsItsOwnToken() {
        let stable = "/opt/homebrew/Caskroom/claude-code/2.1.154/claude"
        #expect(
            HarnessCLIUpdater.plan(
                for: .claudeCode, executablePath: stable, isBrewAvailable: true
            ) == .brew(formula: "claude-code")
        )
    }

    /// A bare prefix symlink names no token, so the stable one is the only
    /// answer available — a guess, but the documented default.
    @Test func aPathThatNamesNoTokenFallsBackToTheStableOne() {
        #expect(
            HarnessCLIUpdater.plan(
                for: .claudeCode, executablePath: "/opt/homebrew/bin/claude",
                isBrewAvailable: true, resolve: { $0 }
            ) == .brew(formula: "claude-code")
        )
        #expect(HarnessCLIUpdater.homebrewPathToken(in: "/usr/local/bin/claude") == nil)
        #expect(
            HarnessCLIUpdater.homebrewPathToken(in: "/opt/homebrew/Cellar/codex/0.153.4/bin/codex")
                == "codex"
        )
    }

    /// `brew install node` + `npm install -g` is a Homebrew *prefix* holding an
    /// npm install. Answering it with `brew upgrade claude-code` installs a
    /// second copy from a cask the user never asked for, and leaves the npm
    /// one still first on PATH.
    @Test func anNpmInstallUnderHomebrewsNodeIsNotACask() {
        let path = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        #expect(
            HarnessCLIUpdater.installMethod(
                for: .claudeCode, executablePath: path, resolve: { $0 }
            ) == .npm
        )
        #expect(
            HarnessCLIUpdater.plan(
                for: .claudeCode, executablePath: path,
                isBrewAvailable: true, resolve: { $0 }
            )
                == .npm(package: "@anthropic-ai/claude-code")
        )
        // The token in that path is `node`, which must never be upgraded on
        // the user's behalf.
        #expect(!HarnessKind.claudeCode.ownsBrewToken("node"))
        #expect(HarnessKind.claudeCode.ownsBrewToken("claude-code"))
        #expect(HarnessKind.claudeCode.ownsBrewToken("claude-code@latest"))
    }

    // MARK: - Homebrew that is no longer there

    /// A migrated Mac keeps the binaries and loses Homebrew. `plan` inferred
    /// `brew upgrade` from the path shape alone, so the update button ran a
    /// command the machine does not have.
    @Test func aHomebrewPathWithoutBrewNeverPlansBrew() {
        let codex = HarnessCLIUpdater.plan(
            for: .codex, executablePath: "/opt/homebrew/bin/codex",
            isBrewAvailable: false, resolve: { $0 }
        )
        #expect(codex == .selfUpdate(executablePath: "/opt/homebrew/bin/codex"))

        let claude = HarnessCLIUpdater.plan(
            for: .claudeCode, executablePath: "/opt/homebrew/bin/claude",
            isBrewAvailable: false, resolve: { $0 }
        )
        #expect(claude == .nativeInstaller(url: "https://claude.ai/install.sh"))
        #expect(!HarnessCLIUpdater.script(for: claude).contains("brew"))
    }

    // MARK: - A channel the user actually has

    /// Claude Code's arm of `plan` ended in Cursor's install script. Nothing
    /// reached it — `npmPackage` is never nil — which is exactly why it had to
    /// go: one edit away from installing the wrong agent entirely.
    @Test func eachHarnessInstallsItselfAndNotAnother() {
        #expect(HarnessKind.claudeCode.nativeInstallerURL == "https://claude.ai/install.sh")
        #expect(HarnessKind.codex.nativeInstallerURL == "https://chatgpt.com/codex/install.sh")
        #expect(HarnessKind.cursorAgent.nativeInstallerURL == "https://cursor.com/install")

        let paths: [String?] = [nil, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        for path in paths {
            let script = HarnessCLIUpdater.script(
                for: HarnessCLIUpdater.plan(
                    for: .claudeCode, executablePath: path,
                    isBrewAvailable: false, resolve: { $0 }
                )
            )
            #expect(!script.contains("cursor.com"), "\(String(describing: path))")
        }
    }

    /// The update path used to answer every unclassifiable install with
    /// `npm install -g`, including the install ORE's own onboarding now
    /// recommends — the vendor's script, which leaves a machine with a working
    /// `claude` and no npm at all.
    @Test func anUnclassifiedInstallIsUpdatedWithoutNeedingNpm() {
        let plan = HarnessCLIUpdater.plan(for: .claudeCode, executablePath: nil)
        #expect(plan == .nativeInstaller(url: "https://claude.ai/install.sh"))
        #expect(!HarnessCLIUpdater.script(for: plan).contains("npm"))

        // An install that really is npm's still goes through npm.
        #expect(
            HarnessCLIUpdater.plan(
                for: .claudeCode,
                executablePath: "/Users/me/.nvm/versions/node/v22.0.0/bin/claude",
                resolve: { $0 }
            ) == .npm(package: "@anthropic-ai/claude-code")
        )
    }

    // MARK: - A self-update subcommand that may not exist

    /// `codex update` is not confirmed to exist. If it does not, every Codex
    /// update in ORE fails — so the failure is read, not assumed away.
    @Test func anUnknownSubcommandIsRecognisedHoweverItIsWorded() {
        for output in [
            "error: unrecognized subcommand 'update'",
            "Unknown command: update",
            "codex: 'update' is not a valid subcommand",
            "error: invalid command `update`",
        ] {
            #expect(HarnessCLIUpdater.isUnknownSubcommand(output: output, exitCode: 1), "\(output)")
        }
        // Usage text with the parser's own exit code, which is what clap
        // prints when nothing matched.
        #expect(HarnessCLIUpdater.isUnknownSubcommand(
            output: "Usage: codex [OPTIONS] <COMMAND>", exitCode: 2
        ))
        // And a real update failure is left alone, including one that exits 2.
        #expect(!HarnessCLIUpdater.isUnknownSubcommand(
            output: "error: failed to download release: connection reset", exitCode: 2
        ))
        #expect(!HarnessCLIUpdater.isUnknownSubcommand(
            output: "npm error code EACCES", exitCode: 1
        ))
    }

    /// And the recovery goes through the channel this install came from, not
    /// through npm by default.
    @Test func aMissingSelfUpdateFallsBackToTheInstallsOwnChannel() {
        #expect(
            HarnessCLIUpdater.fallbackPlan(
                for: .codex,
                executablePath: "/Users/me/.nvm/versions/node/v22.0.0/bin/codex"
            ) == .npm(package: "@openai/codex")
        )
        let native = FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/codex"
        #expect(
            HarnessCLIUpdater.fallbackPlan(for: .codex, executablePath: native)
                == .nativeInstaller(url: "https://chatgpt.com/codex/install.sh")
        )
        // `claude update` is documented and confirmed; nothing about its
        // failures should be reinterpreted.
        #expect(HarnessCLIUpdater.selfUpdateIsConfirmed(for: .claudeCode))
        #expect(!HarnessCLIUpdater.selfUpdateIsConfirmed(for: .codex))
    }

    // MARK: - Disk space

    /// An update that fills the disk half-way through leaves a partly
    /// unpacked package where a working CLI used to be.
    @Test func aRefusalForDiskSpaceNamesTheShortfall() {
        let message = HarnessCLIUpdater.UpdateError.insufficientDiskSpace(
            kind: .codex, availableBytes: 200_000_000, requiredBytes: 1_000_000_000
        ).errorDescription ?? ""

        #expect(message.contains("Codex"))
        #expect(message.contains("200 MB"), "\(message)")
        #expect(message.contains("800 MB"), "\(message)")
        #expect(message.contains("1.0 GB"), "\(message)")
    }

    @Test func spaceIsMeasuredInWholeUnitsTheUserRecognises() {
        #expect(HarnessCLIUpdater.UpdateError.describeBytes(2_500_000_000) == "2.5 GB")
        #expect(HarnessCLIUpdater.UpdateError.describeBytes(512_000_000) == "512 MB")
        #expect(HarnessCLIUpdater.UpdateError.describeBytes(0) == "0 MB")
    }
}
