import Foundation

/// Composer text for a new tab that should execute an existing plan.
///
/// Empty after trimming means there is nothing to hand off. A trailing newline
/// leaves the caret ready for extra instructions without wrapping the plan in
/// a canned "implement this" prompt — the user owns that.
enum PlanHandoff {
    static func composerDraft(from markdown: String) -> String? {
        let body = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return body + "\n"
    }
}
