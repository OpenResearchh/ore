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

    @Test func oauthRefreshFailureIsRecognisedAsAuth() {
        #expect(ClaudeCodeSession.looksLikeAuthFailure(
            "failed to authenticate: oauth session expired and could not be refreshed"
        ))
        #expect(!ClaudeCodeSession.looksLikeAuthFailure(
            "permission denied writing to the worktree"
        ))
    }
}
