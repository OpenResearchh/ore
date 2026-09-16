import Testing

import OreProtocol
@testable import OreMac

/// When the update card is allowed to appear — the part of the feature the
/// user experiences as either helpful or as nagging.
struct HarnessUpdatePromptingTests {
    private func status(
        _ kind: HarnessKind,
        installed: String?,
        latest: String?,
        failure: String? = nil
    ) -> HarnessUpdateStatus {
        HarnessUpdateStatus(
            kind: kind,
            installedVersion: installed,
            latestVersion: latest,
            failure: failure
        )
    }

    @Test func onlyGenuinelyNewerVersionsPrompt() {
        let statuses = [
            status(.claudeCode, installed: "2.1.154", latest: "2.1.263"),
            status(.codex, installed: "0.153.4", latest: "0.153.4"),
        ]
        let pending = HarnessUpdatePrompting.pending(statuses: statuses, dismissed: [:])
        #expect(pending.map(\.kind) == [.claudeCode])
    }

    @Test func aDismissedVersionStopsPromptingForThatVersionOnly() {
        let claude = status(.claudeCode, installed: "2.1.154", latest: "2.1.263")
        #expect(
            HarnessUpdatePrompting.pending(
                statuses: [claude],
                dismissed: [.claudeCode: "2.1.263"]
            ).isEmpty
        )
        // The next release is a new question, asked once.
        let next = status(.claudeCode, installed: "2.1.154", latest: "2.1.300")
        #expect(
            HarnessUpdatePrompting.pending(
                statuses: [next],
                dismissed: [.claudeCode: "2.1.263"]
            ).count == 1
        )
    }

    @Test func dismissingOneHarnessLeavesTheOthersAlone() {
        let statuses = [
            status(.claudeCode, installed: "2.1.154", latest: "2.1.263"),
            status(.codex, installed: "0.148.0", latest: "0.153.4"),
        ]
        let pending = HarnessUpdatePrompting.pending(
            statuses: statuses,
            dismissed: [.claudeCode: "2.1.263"]
        )
        #expect(pending.map(\.kind) == [.codex])
    }

    @Test func aFailedCheckNeverPrompts() {
        let statuses = [
            status(.codex, installed: "0.148.0", latest: nil, failure: "Couldn't reach the registry."),
            // No version from the CLI: nothing to compare, so nothing to offer.
            status(.cursorAgent, installed: nil, latest: "2026.09.02-c22c1a3"),
        ]
        #expect(HarnessUpdatePrompting.pending(statuses: statuses, dismissed: [:]).isEmpty)
    }
}

/// What happens after the button is pressed.
///
/// For a self-updating CLI, ORE asks one oracle what is published (npm, a
/// vendor endpoint) and a different one to install it (the CLI's own `update`
/// subcommand). When those two disagree the update exits zero, the version does
/// not move, and the card used to be cleared on the strength of the exit code —
/// then came back unchanged on the next check, with nothing to do about it but
/// press the same button again.
struct HarnessNoOpUpdateTests {
    private func status(installed: String?, latest: String?) -> HarnessUpdateStatus {
        HarnessUpdateStatus(kind: .codex, installedVersion: installed, latestVersion: latest)
    }

    @Test func aNoOpUpdateKeepsTheCardWithAnExplanation() throws {
        let explanation = try #require(AppModel.noOpUpdateExplanation(
            kind: .codex,
            before: "0.148.0",
            after: status(installed: "0.148.0", latest: "0.153.4")
        ))
        // Naming the version is the whole point: it is what tells the user the
        // upgrade did not happen, rather than that they misread the card.
        #expect(explanation.contains("0.148.0"))
        #expect(explanation.contains("Codex"))
    }

    @Test func anUpgradeThatMovedClearsTheCard() {
        #expect(AppModel.noOpUpdateExplanation(
            kind: .codex,
            before: "0.148.0",
            after: status(installed: "0.153.4", latest: "0.153.4")
        ) == nil)
    }

    /// Unchanged, but the channel is no longer advertising anything newer —
    /// the check that was wrong, not the CLI. Nothing to explain.
    @Test func aChannelThatStoppedOfferingIsNotAFailure() {
        #expect(AppModel.noOpUpdateExplanation(
            kind: .codex,
            before: "0.153.4",
            after: status(installed: "0.153.4", latest: "0.153.4")
        ) == nil)
    }

    /// No version to compare — a CLI that will not report one. Accusing its
    /// updater of lagging would be a guess.
    @Test func anUnknownInstalledVersionSaysNothing() {
        #expect(AppModel.noOpUpdateExplanation(
            kind: .codex,
            before: nil,
            after: status(installed: nil, latest: "0.153.4")
        ) == nil)
        #expect(AppModel.noOpUpdateExplanation(kind: .codex, before: "0.148.0", after: nil) == nil)
    }
}
