import Foundation
import OreProtocol

/// Composer text for a new tab that should execute an existing plan.
///
/// Empty after trimming means there is nothing to hand off. A trailing newline
/// leaves the caret ready for extra instructions without wrapping the plan in
/// a canned "implement this" prompt — the user owns that.
enum PlanHandoff {
    static func composerDraft(from markdown: String) -> String? {
        let body = PlanProposalPolicy.normalizedMarkdown(markdown)
        guard let body, PlanProposalPolicy.isReadyMarkdown(body) else { return nil }
        return body + "\n"
    }
}
