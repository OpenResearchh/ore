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
            command: "npm install -g '@openai/codex'@latest",
            exitCode: 1,
            output: raw
        )
        let message = error.errorDescription ?? ""
        #expect(message.contains("not writable by your user"))
        #expect(message.contains("brew install codex"))
        #expect(!message.contains("npm error"))
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
