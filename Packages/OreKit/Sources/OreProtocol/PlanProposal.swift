import Foundation

/// When a harness's plan is actually something the user can read and approve.
///
/// Harnesses (Cursor especially) announce CreatePlan / ExitPlanMode as soon as
/// the tool *starts*, often with only a title or overview while the agent is
/// still inspecting. Treating that as "the plan is ready" flashes approval
/// controls and spoken prompts before any plan body exists in the transcript.
public enum PlanProposalPolicy {
    /// The plan body fields a harness uses — not the title/overview that
    /// Cursor sends on `started` while it is still writing.
    public static func planBody(from input: JSONValue) -> String? {
        let raw = input["plan"]?.stringValue
            ?? input["markdown"]?.stringValue
            ?? input["content"]?.stringValue
            ?? input["streamContent"]?.stringValue
            ?? input["stream_content"]?.stringValue
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func hasTodos(in input: JSONValue) -> Bool {
        let todos = input["todos"]?.arrayValue ?? input["steps"]?.arrayValue ?? []
        return todos.contains { item in
            let text = item["content"]?.stringValue
                ?? item["text"]?.stringValue
                ?? item["step"]?.stringValue
                ?? item.stringValue
            guard let text else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// True when the tool input carries a plan the user can actually read —
    /// a body, or a checklist — not a name/overview placeholder.
    public static func isReadyInput(_ input: JSONValue) -> Bool {
        if let body = planBody(from: input), isReadyMarkdown(body) { return true }
        return hasTodos(in: input)
    }

    public static func isReadyMarkdown(_ markdown: String) -> Bool {
        !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Tools that mean the agent has moved on from proposing a plan to
    /// implementing it. A leftover proposal after one of these is stale.
    public static func proceedsPastProposal(_ toolName: String) -> Bool {
        switch toolName {
        case "Edit", "Write", "Delete", "Bash":
            return true
        default:
            return false
        }
    }
}

/// One ready proposal per turn may be advertised (spoken, approval card,
/// pending-input). Later updates — a permission id being linked, a duplicate
/// completed record, a slightly longer body — edit the same plan rather than
/// announcing it again.
public struct PlanReadinessGate: Sendable, Equatable {
    private var announcedTurns: Set<String> = []

    public init() {}

    /// Whether this update should trigger "plan ready" UX. False for drafts,
    /// empty markdown, and a turn that has already advertised.
    public mutating func shouldAnnounce(
        scope: String,
        turnID: TurnID,
        markdown: String,
        isReady: Bool
    ) -> Bool {
        guard isReady, PlanProposalPolicy.isReadyMarkdown(markdown) else { return false }
        let key = "\(scope)/\(turnID.rawValue)"
        return announcedTurns.insert(key).inserted
    }

    public mutating func reset(scope: String) {
        let prefix = scope + "/"
        announcedTurns = announcedTurns.filter { !$0.hasPrefix(prefix) }
    }
}
