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
