import Foundation
import OreProtocol
import Testing

@testable import OreMac

/// Settings' "Sign in…" spawns a CLI that opens a browser and then waits. Both
/// halves of that used to be invisible: the link the CLI printed went to a pipe
/// nobody read, and a handshake that never completed left a spinner running for
/// the life of the app. These cover the two pure pieces — the extraction and
/// the terminal copy — which is as far as a test can go without spawning a real
/// vendor CLI.
struct HarnessSignInTests {
    @Test func signInTimeoutProducesATerminalFallbackNotice() {
        for kind in [HarnessKind.codex, .cursorAgent] {
            let command = HarnessSetup.signInCommand(for: kind)
            let message = HarnessAuthenticationError.timedOut(command).errorDescription ?? ""
            // The only advice left once the browser handshake plainly did not
            // happen is the command to run by hand, so it has to be in the text.
            #expect(message.contains(command))
            #expect(message.contains("Terminal"))
        }
    }

    /// Claude Code is the one that cannot be driven headlessly at all, so its
    /// error says so rather than offering a cancel on a process that would
    /// never have worked.
    @Test func claudeCodeSignInSaysItIsInteractive() {
        let message = HarnessAuthenticationError.interactiveOnly.errorDescription ?? ""
        #expect(message.contains("interactive"))
    }

    @Test func aPrintedURLIsExtractedFromLoginOutput() {
        #expect(
            AppModel.firstURL(in: "Visit https://auth.openai.com/device?code=ABCD to continue")
                == "https://auth.openai.com/device?code=ABCD"
        )
        // These links arrive wrapped as often as not.
        #expect(
            AppModel.firstURL(in: "Open <https://cursor.com/login>.")
                == "https://cursor.com/login"
        )
        #expect(
            AppModel.firstURL(in: "first https://one.example second https://two.example")
                == "https://one.example"
        )
    }

    @Test func outputWithNoLinkYieldsNothingToOffer() {
        #expect(AppModel.firstURL(in: "Waiting for authentication…") == nil)
        #expect(AppModel.firstURL(in: "see http://insecure.example") == nil)
        // A bare scheme is not a link; offering it would be a dead button.
        #expect(AppModel.firstURL(in: "https://") == nil)
    }
}
