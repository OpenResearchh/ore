import Foundation
import Testing

@testable import OreHarness
@testable import OreProtocol

struct HarnessCLIUpdaterTests {
    @Test func homebrewCodexUsesBrewUpgrade() {
        let plan = HarnessCLIUpdater.plan(
            for: .codex,
            executablePath: "/opt/homebrew/bin/codex"
        )
        #expect(plan == .brew(formula: "codex"))
        #expect(HarnessCLIUpdater.script(for: plan) == "brew upgrade 'codex'")
    }

    @Test func nvmClaudeUsesNpm() {
        let plan = HarnessCLIUpdater.plan(
            for: .claudeCode,
            executablePath: "/Users/me/.nvm/versions/node/v22.0.0/bin/claude"
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
            executablePath: "/usr/local/bin/codex"
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
            for: .codex, executablePath: "/opt/homebrew/bin/codex"
        ) == .homebrew)
    }

    @Test func aNodeManagedPathIsRecognisedAsNpm() {
        #expect(HarnessCLIUpdater.installMethod(
            for: .claudeCode,
            executablePath: "/Users/me/.nvm/versions/node/v22.0.0/bin/claude"
        ) == .npm)
    }

    @Test func theVendorsOwnBinDirectoryIsANativeInstall() {
        let path = FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/claude"
        #expect(HarnessCLIUpdater.installMethod(for: .claudeCode, executablePath: path)
            == .nativeUserBin)
    }

    /// A bare `/usr/local/bin` entry is almost always `sudo npm install -g`,
    /// which is the install this whole path exists to repair.
    @Test func aSystemPrefixEntryIsTreatedAsAGlobalNpmInstall() {
        #expect(HarnessCLIUpdater.installMethod(
            for: .codex, executablePath: "/usr/local/bin/codex"
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
        let plan = HarnessCLIUpdater.plan(for: .claudeCode, executablePath: path)
        #expect(plan == .selfUpdate(executablePath: path))
    }
}
