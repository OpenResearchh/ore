import Foundation
import Testing

@testable import OreHarness
@testable import OreProtocol

/// Detection, end to end, with the network replaced by a fixture.
///
/// The real payloads are pasted down to their relevant keys: these are the
/// three shapes upstream actually serves, and a change in any of them should
/// fail here rather than silently stop offering upgrades.
struct HarnessUpdateCheckerTests {

    // MARK: - Version parsing

    @Test func versionsAreLiftedOutOfEachCLIsOwnPhrasing() {
        #expect(HarnessVersion.normalize("2.1.154 (Claude Code)") == "2.1.154")
        #expect(HarnessVersion.normalize("codex-cli 0.148.0") == "0.148.0")
        #expect(HarnessVersion.normalize("2026.09.02-c22c1a3") == "2026.09.02-c22c1a3")
        #expect(HarnessVersion.normalize("v1.2.3") == "1.2.3")
    }

    @Test func versionlessOutputNormalizesToNil() {
        #expect(HarnessVersion.normalize(nil) == nil)
        #expect(HarnessVersion.normalize("") == nil)
        #expect(HarnessVersion.normalize("command not found") == nil)
        // A bare integer is a build counter or a stray number, not a version.
        #expect(HarnessVersion.normalize("codex 42") == nil)
    }

    @Test func newerIsStrictAndTolerantOfComponentCounts() {
        #expect(HarnessVersion.isNewer("2.1.263", than: "2.1.154"))
        #expect(HarnessVersion.isNewer("0.153.4", than: "0.148.0"))
        #expect(HarnessVersion.isNewer("1.3", than: "1.2.9"))
        // A missing component is a zero, so `1.2` and `1.2.0` are the same
        // release however the two sides happen to spell it.
        #expect(!HarnessVersion.isNewer("1.2.0", than: "1.2"))
        #expect(!HarnessVersion.isNewer("1.2", than: "1.2.0"))
        #expect(!HarnessVersion.isNewer("2.1.154", than: "2.1.154"))
        #expect(!HarnessVersion.isNewer("2.1.100", than: "2.1.154"))
    }

    @Test func cursorDateBuildsCompareByDateAndIgnoreTheHash() {
        #expect(HarnessVersion.isNewer("2026.09.03-aaa1111", than: "2026.09.02-c22c1a3"))
        // Same day, different build: unorderable, so never advertised as newer.
        // A card the user cannot dismiss for good is worse than a missed patch.
        #expect(!HarnessVersion.isNewer("2026.09.02-ffff999", than: "2026.09.02-c22c1a3"))
    }

    // MARK: - Channel selection

    @Test func theCheckedChannelIsTheOneAnUpgradeWouldUse() {
        // Homebrew install → Homebrew's published version, not npm's. npm often
        // leads the cask, and offering a version `brew upgrade` cannot fetch
        // makes a card that never clears.
        #expect(
            HarnessUpdateChecker.source(for: .codex, executablePath: "/opt/homebrew/bin/codex")
                == .homebrew(token: "codex")
        )
        #expect(
            HarnessUpdateChecker.source(
                for: .claudeCode,
                executablePath: "/Users/me/.nvm/versions/node/v22.0.0/bin/claude"
            ) == .npm(package: "@anthropic-ai/claude-code")
        )
        #expect(
            HarnessUpdateChecker.source(for: .cursorAgent, executablePath: nil)
                == .cursorInstallScript
        )
    }

    @Test func selfUpdatingCLIsStillReadTheirRegistryForTheVersion() {
        // `codex update` knows how to upgrade but not how to be asked what's
        // out there; npm publishes the same release stream.
        #expect(
            HarnessUpdateChecker.source(for: .codex, executablePath: "/usr/local/bin/codex")
                == .npm(package: "@openai/codex")
        )
    }

    @Test func homebrewFallsBackToTheFormulaNamespace() {
        let cask = HarnessUpdateChecker.Source.homebrew(token: "codex")
        #expect(cask.url?.absoluteString.contains("/api/cask/codex.json") == true)
        #expect(cask.fallbackURL?.absoluteString.contains("/api/formula/codex.json") == true)
        #expect(HarnessUpdateChecker.Source.npm(package: "@openai/codex").fallbackURL == nil)
    }

    // MARK: - Channel payloads

    @Test func npmLatestIsParsed() {
        let payload = Data(#"{"name":"@openai/codex","version":"0.153.4"}"#.utf8)
        #expect(HarnessUpdateChecker.parseNPMVersion(payload) == "0.153.4")
        #expect(HarnessUpdateChecker.parseNPMVersion(Data("not json".utf8)) == nil)
    }

    @Test func bothHomebrewNamespacesAreParsed() {
        let cask = Data(#"{"token":"codex","version":"0.153.4"}"#.utf8)
        #expect(HarnessUpdateChecker.parseHomebrewVersion(cask) == "0.153.4")

        let formula = Data(#"{"name":"codex","versions":{"stable":"0.153.4","head":null}}"#.utf8)
        #expect(HarnessUpdateChecker.parseHomebrewVersion(formula) == "0.153.4")

        // Casks pin a build after the version; the CLI only ever prints the
        // part before the comma.
        let withBuild = Data(#"{"token":"thing","version":"1.2.3,4567"}"#.utf8)
        #expect(HarnessUpdateChecker.parseHomebrewVersion(withBuild) == "1.2.3")
    }

    @Test func cursorsInstallScriptNamesTheBuildItWouldInstall() {
        let script = """
        #!/usr/bin/env bash
        TEMP_EXTRACT_DIR="$HOME/.local/share/cursor-agent/versions/.tmp-2026.09.02-c22c1a3-$(date +%s)"
        DOWNLOAD_URL="https://downloads.cursor.com/lab/2026.09.02-c22c1a3/${OS}/${ARCH}/agent-cli-package.tar.gz"
        FINAL_DIR="$HOME/.local/share/cursor-agent/versions/2026.09.02-c22c1a3"
        """
        #expect(HarnessUpdateChecker.parseCursorInstallScript(script) == "2026.09.02-c22c1a3")
        #expect(HarnessUpdateChecker.parseCursorInstallScript("echo hello") == nil)
    }

    // MARK: - Status assembly

    @Test func aNewerPublishedVersionIsAnAvailableUpdate() async {
        let status = await HarnessUpdateChecker.check(
            kind: .codex,
            installedVersion: "codex-cli 0.148.0",
            executablePath: "/opt/homebrew/bin/codex",
            fetch: Self.serving([
                "/api/cask/codex.json": #"{"token":"codex","version":"0.153.4"}"#,
            ])
        )
        #expect(status.installedVersion == "0.148.0")
        #expect(status.latestVersion == "0.153.4")
        #expect(status.isUpdateAvailable)
        #expect(status.failure == nil)
        // The card tells the user how the upgrade will happen, in their terms.
        #expect(status.updateCommand == "brew upgrade 'codex'")
    }

    @Test func matchingVersionsAreNotAnUpdate() async {
        let status = await HarnessUpdateChecker.check(
            kind: .claudeCode,
            installedVersion: "2.1.263 (Claude Code)",
            executablePath: "/Users/me/.nvm/versions/node/v22.0.0/bin/claude",
            fetch: Self.serving([
                "/@anthropic-ai/claude-code/latest": #"{"version":"2.1.263"}"#,
            ])
        )
        #expect(!status.isUpdateAvailable)
        #expect(status.failure == nil)
    }

    @Test func anUnreachableChannelReportsItselfRatherThanClaimingCurrent() async {
        let status = await HarnessUpdateChecker.check(
            kind: .codex,
            installedVersion: "0.148.0",
            executablePath: "/opt/homebrew/bin/codex",
            fetch: { _ in nil }
        )
        #expect(status.latestVersion == nil)
        #expect(!status.isUpdateAvailable)
        #expect(status.failure != nil)
        // The installed version survives a failed check — the harness is fine,
        // only our knowledge of the channel is missing.
        #expect(status.installedVersion == "0.148.0")
    }

    @Test func aCLIThatWontStateItsVersionIsNeverOfferedAnUpgrade() async {
        let status = await HarnessUpdateChecker.check(
            kind: .codex,
            installedVersion: nil,
            executablePath: "/opt/homebrew/bin/codex",
            fetch: Self.serving([
                "/api/cask/codex.json": #"{"token":"codex","version":"0.153.4"}"#,
            ])
        )
        #expect(!status.isUpdateAvailable)
        #expect(status.failure != nil)
    }

    @Test func homebrewFailingOverToFormulaStillResolves() async {
        // Cask 404s, formula answers — the harness is still checkable.
        let status = await HarnessUpdateChecker.check(
            kind: .codex,
            installedVersion: "0.148.0",
            executablePath: "/opt/homebrew/bin/codex",
            fetch: Self.serving([
                "/api/formula/codex.json": #"{"versions":{"stable":"0.153.4"}}"#,
            ])
        )
        #expect(status.latestVersion == "0.153.4")
        #expect(status.isUpdateAvailable)
    }

    /// A fetcher that answers only for URLs whose path it recognises, so a
    /// check aimed at the wrong channel fails the test instead of passing by
    /// accident.
    private static func serving(_ routes: [String: String]) -> HarnessUpdateChecker.Fetcher {
        { url in
            for (suffix, body) in routes where url.path.hasSuffix(suffix) {
                return Data(body.utf8)
            }
            return nil
        }
    }
}
