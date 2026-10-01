import Foundation
import Testing

@testable import OreProtocol

struct ProviderErrorCopyTests {
    @Test func organizationPolicyDenialIsSpecificToClaudeAccess() {
        let refusal = "Your organization has disabled Claude subscription access for Claude Code · Use an Anthropic API key instead, or ask your admin to enable access"
        #expect(ProviderErrorCopy.isClaudeSubscriptionBlocked(refusal))
        #expect(!ProviderErrorCopy.isClaudeSubscriptionBlocked("Claude subscription access for Claude Code is explained in this document"))
    }

    @Test func unwrapsCodexModelUpgradeJSON() {
        let raw = """
        {"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The 'gpt-5.6-sol' model requires a newer version of Codex. Please upgrade to the latest app or CLI and try again."}}
        """
        #expect(ProviderErrorCopy.unwrap(raw) == "The 'gpt-5.6-sol' model requires a newer version of Codex. Please upgrade to the latest app or CLI and try again.")
        #expect(ProviderErrorCopy.needsCLIUpgrade(raw))
        #expect(ProviderErrorCopy.sessionKind(for: raw) == .protocolMismatch)
    }

    @Test func unwrapsATransportPrefixThenNestedJSON() {
        let inner = #"{"error":{"message":"The 'gpt-5.6-sol' model requires a newer version of Codex."}}"#
        let raw = "Transport failure: \(inner)"
        #expect(ProviderErrorCopy.unwrap(raw).contains("requires a newer version of Codex"))
        #expect(ProviderErrorCopy.needsCLIUpgrade(raw))
    }

    @Test func upgradeToProIsNotACLIUpgrade() {
        let message = "You've hit your usage limit. Upgrade to Pro for more."
        #expect(!ProviderErrorCopy.needsCLIUpgrade(message))
        #expect(ProviderErrorCopy.looksLikeRateLimit(message))
        #expect(ProviderErrorCopy.sessionKind(for: message) == .rateLimited)
    }

    @Test func plainTextIsLeftAlone() {
        #expect(ProviderErrorCopy.unwrap("connection reset") == "connection reset")
        #expect(!ProviderErrorCopy.needsCLIUpgrade("connection reset"))
    }
}
