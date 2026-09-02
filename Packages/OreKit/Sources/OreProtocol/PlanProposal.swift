import Foundation

/// When a harness's plan is actually something the user can read and approve.
///
/// Harnesses (Cursor especially) announce CreatePlan / ExitPlanMode as soon as
/// the tool *starts*, often with only a title or overview while the agent is
/// still inspecting. Treating that as "the plan is ready" flashes approval
/// controls and spoken prompts before any plan body exists in the transcript.
///
/// Cursor also streams the tool payload as `streamContent`. Early chunks are
/// often JSON punctuation (`}}`) or the wrapping CreatePlan object — that is
/// not a plan, and must not become the purple PLAN row.
public enum PlanProposalPolicy {
    /// Completed body fields, then a streaming field only if it already looks
    /// like markdown. Title/overview are not a body.
    ///
    /// `content` is also the Read/Write file body, so it only counts when it
    /// is a JSON envelope (or already a `#` heading). Cursor CreatePlan uses
    /// `plan` / `streamContent`.
    public static func planBody(from input: JSONValue) -> String? {
        for key in ["plan", "markdown"] {
            if let text = normalizedMarkdown(input[key]?.stringValue) { return text }
        }
        if let raw = input["content"]?.stringValue,
           let text = markdownFromGenericContent(raw) {
            return text
        }
        let streaming = input["streamContent"]?.stringValue
            ?? input["stream_content"]?.stringValue
        return normalizedMarkdown(streaming)
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
    /// a body, or a checklist — not a name/overview placeholder or JSON debris.
    public static func isReadyInput(_ input: JSONValue) -> Bool {
        if let body = planBody(from: input), isReadyMarkdown(body) { return true }
        return hasTodos(in: input)
    }

    public static func isReadyMarkdown(_ markdown: String) -> Bool {
        looksLikePlanMarkdown(markdown)
    }

    /// Strip streamed JSON wrappers and leftover object closers. Returns nil
    /// when nothing readable remains — including a payload that is only `}}`
    /// or the CreatePlan args object with no plan field.
    public static func normalizedMarkdown(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }

        while let first = text.first, first == "}" || first == "," {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return nil }

        if text.hasPrefix("{") {
            // Complete JSON unwraps a plan field. Incomplete stream chunks
            // (`{"name":`) are not markdown — wait for a later chunk.
            if jsonObject(from: text) != nil {
                return unwrapJSONPlan(text)
            }
            return nil
        }

        return looksLikePlanMarkdown(text) ? text : nil
    }

    /// A first-line headline for HUD / needs-you rows: a heading if there is
    /// one, otherwise the first non-empty prose line, clipped.
    public static func headline(from markdown: String, limit: Int = 200) -> String {
        let lines = markdown.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let line = lines.first { candidate in
            let stripped = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "#*- "))
            return looksLikePlanMarkdown(stripped)
        } ?? lines.first ?? markdown
        let cleaned = line.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if cleaned.count <= limit { return cleaned }
        return String(cleaned.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Letters or digits must remain after stripping markdown punctuation —
    /// `}}` and `{,}` are wire leftovers, not a plan.
    public static func looksLikePlanMarkdown(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return false }
        return trimmed.contains { $0.isLetter || $0.isNumber }
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

    /// Top-level `content` is a file body unless it is a JSON plan envelope
    /// or already opens as a heading.
    private static func markdownFromGenericContent(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return unwrapJSONPlan(trimmed) }
        if trimmed.hasPrefix("#") { return normalizedMarkdown(trimmed) }
        return nil
    }

    private static func jsonObject(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func unwrapJSONPlan(_ text: String) -> String? {
        guard let object = jsonObject(from: text) else { return nil }
        for key in ["plan", "markdown"] {
            if let value = object[key] as? String,
               let body = normalizedMarkdown(value) {
                return body
            }
        }
        // Inside an envelope, `content` is the plan body more often than a file.
        if let value = object["content"] as? String,
           let body = normalizedMarkdown(value) {
            return body
        }
        for nest in ["result", "success", "args", "arguments", "input", "data"] {
            if let nested = object[nest] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: nested),
               let json = String(data: data, encoding: .utf8),
               let body = unwrapJSONPlan(json) {
                return body
            }
            if let nested = object[nest] as? String,
               let body = normalizedMarkdown(nested) {
                return body
            }
        }
        return nil
    }
}

/// One ready proposal per turn may be advertised (spoken, approval card,
/// pending-input, TabNeedsYou). Later updates — a permission id being linked,
/// a duplicate completed record, a slightly longer body — edit the same plan
/// rather than announcing it again.
public struct PlanReadinessGate: Sendable, Equatable {
    private var announcedTurns: Set<String> = []

    public init() {}

    /// Whether this update should trigger "plan ready" UX. False for drafts,
    /// JSON debris, empty markdown, and a turn that has already advertised.
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
