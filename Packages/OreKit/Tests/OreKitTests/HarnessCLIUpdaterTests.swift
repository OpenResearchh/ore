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
