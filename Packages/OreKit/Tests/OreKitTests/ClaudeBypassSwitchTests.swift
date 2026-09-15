import Foundation
import Testing

@testable import OreHarness
@testable import OreProtocol

/// Switching a running Claude session into Bypass failed with "the session was
/// not launched with --dangerously-skip-permissions": the CLI only accepts that
/// change from a session started with `--allow-dangerously-skip-permissions`.
struct ClaudeBypassSwitchTests {
    @Test func aCLIThatKnowsTheAllowFlagIsLaunchedWithIt() {
        #expect(
            ClaudeCodeSession.permissionArguments(mode: .acceptEdits, allowsBypassSwitch: true)
                == ["--permission-mode", "acceptEdits", "--allow-dangerously-skip-permissions"]
        )
    }

    /// An older CLI given an unknown flag refuses to start at all, which is far
    /// worse than a mode switch that needs a relaunch.
    @Test func anOlderCLIIsNeverHandedAnUnknownFlag() {
        #expect(
            ClaudeCodeSession.permissionArguments(mode: .default, allowsBypassSwitch: false)
                == ["--permission-mode", "default"]
        )
    }

    @Test func supportIsReadFromTheCLIsOwnHelp() {
        let current = """
          --allow-dangerously-skip-permissions  Enable bypassing all permission checks
          --dangerously-skip-permissions        Bypass all permission checks.
        """
        let older = "  --dangerously-skip-permissions        Bypass all permission checks."
        #expect(ClaudeFlagSupport.helpOffersBypassSwitch(current))
        #expect(!ClaudeFlagSupport.helpOffersBypassSwitch(older))
        #expect(!ClaudeFlagSupport.helpOffersBypassSwitch(nil), "a CLI that hangs reads as no")
    }

    @Test func theCLIsRefusalIsRecognisedAndNothingElseIs() {
        let refusal = HarnessError.transportFailure(
            "Cannot set permission mode to bypassPermissions because the session was not launched with --dangerously-skip-permissions"
        )
        #expect(ClaudeCodeSession.isBypassLaunchRefusal(refusal))
        #expect(!ClaudeCodeSession.isBypassLaunchRefusal(
            HarnessError.transportFailure("timed out waiting for a control response")
        ))
        #expect(!ClaudeCodeSession.isBypassLaunchRefusal(HarnessError.sessionEnded))
    }
}
