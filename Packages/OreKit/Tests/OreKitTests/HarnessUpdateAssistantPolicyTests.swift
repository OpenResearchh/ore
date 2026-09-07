import Testing

@testable import OreCore
@testable import OreProtocol

/// The assistant may look at harness versions freely; installing one is the
/// user's call. These two tools exist to make that distinction explicit, so
/// they are worth pinning.
struct HarnessUpdateAssistantPolicyTests {
    @Test func checkingForUpdatesIsAPlainRead() {
        guard case .auto = AssistantActionPolicy.tier(forTool: "CheckHarnessUpdates") else {
            Issue.record("checking versions should not need a confirmation")
            return
        }
    }

    @Test func installingACLIAlwaysAsksTheUser() {
        guard case .confirm(let actionClass) =
            AssistantActionPolicy.tier(forTool: "UpdateHarnessCLI")
        else {
            Issue.record("installing software must be confirmed")
            return
        }
        #expect(actionClass == .updateHarnessCLI)
    }

    @Test func bothToolsAreRoutedOverTheBridge() {
        // A tool the policy knows but the bridge doesn't list is unreachable;
        // one the bridge lists but the policy doesn't know is denied by default.
        #expect(AssistantActionPolicy.actionToolNames.contains("CheckHarnessUpdates"))
        #expect(AssistantActionPolicy.actionToolNames.contains("UpdateHarnessCLI"))
    }

    @Test func theUpgradeGrantIsItsOwnClass() {
        // Sharing a class with, say, `remoteRepository` would mean an "always"
        // grant for one silently authorised the other.
        #expect(AssistantActionClass.updateHarnessCLI.displayName == "Update an agent CLI")
        #expect(AssistantActionClass.allCases.contains(.updateHarnessCLI))
    }
}
