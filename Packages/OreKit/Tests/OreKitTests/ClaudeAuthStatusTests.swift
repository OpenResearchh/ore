import Foundation
import Testing

@testable import OreHarness
@testable import OreProtocol

struct ClaudeAuthStatusTests {
    @Test func jsonLoggedOutIsNotAuthenticated() {
        let output = """
        {
          "loggedIn": false,
          "authMethod": "none",
          "apiProvider": "firstParty"
        }
        """
        #expect(ClaudeAuthStatus.interpret(output) == .notAuthenticated)
    }

    @Test func jsonLoggedInIsAuthenticated() {
        let output = #"{"loggedIn":true,"authMethod":"oauth"}"#
        #expect(ClaudeAuthStatus.interpret(output) == .authenticated)
    }

    @Test func expiredTextIsNotAuthenticated() {
        let output = """
        Login: Expired — log in again
        Organization: Ada Lovelace's Organization
        Email: ada@example.com
        Not logged in. Run claude auth login to authenticate.
        """
        #expect(ClaudeAuthStatus.interpret(output) == .notAuthenticated)
    }

    @Test func emptyOutputIsUnknown() {
        #expect(ClaudeAuthStatus.interpret(nil) == .unknown)
        #expect(ClaudeAuthStatus.interpret("") == .unknown)
    }

    /// `claude auth status` says "not logged in" on *stderr* and exits
    /// non-zero. Reading stdout alone threw that away and left the probe at
    /// `.unknown`, which counts as ready — so a signed-out CLI was offered as
    /// an agent and failed on the user's first turn instead of in the doctor.
    @Test func proseOnStderrStillAnswersTheAuthQuestion() {
        let outcome = CommandProbe.classify(
            standardOutput: "",
            standardError: "Not logged in. Run `claude auth login` to authenticate.",
            exitStatus: 1
        )
        #expect(ClaudeAuthStatus.interpret(outcome.spokenText) == .notAuthenticated)
    }

    /// The same channel now carries launch failures, and a loader error is not
    /// a login state. Nothing in it may read as signed in.
    @Test func aLaunchFailureReasonIsNotReadAsALogin() {
        #expect(ClaudeAuthStatus.interpret("exited with status 127") == .unknown)
        #expect(
            ClaudeAuthStatus.interpret("env: node: No such file or directory") == .unknown
        )
    }

    @Test func oauthRefreshFailureIsRecognisedAsAuth() {
        #expect(ClaudeCodeSession.looksLikeAuthFailure(
            "failed to authenticate: oauth session expired and could not be refreshed"
        ))
        #expect(!ClaudeCodeSession.looksLikeAuthFailure(
            "permission denied writing to the worktree"
        ))
    }
}
