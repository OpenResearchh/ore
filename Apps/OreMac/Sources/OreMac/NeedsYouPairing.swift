import Foundation
import OreProtocol

/// An AskUserQuestion is one ask wearing two hats.
///
/// The harness publishes it as one or more questions *and* as a permission
/// gate on the same tool call, and they have to be treated as one thing in
/// both directions: every answer travels back through the one gate, and
/// settling the gate retires all of them. Getting one direction wrong is what
/// let the floating HUD re-ask a question the user had already answered in
/// the window — the transcript answered through the gate, the question record
/// stayed pending, and the HUD shows the newest pending ask the moment ORE
/// loses focus.
enum NeedsYouPairing {
    /// The open permission the answers to `toolCallID`'s questions travel
    /// back through, or `nil` when they are an ordinary user message.
    ///
    /// Matched on the tool call. When both sides name one, they must name
    /// the *same* one: a stale notification for a question that has been and
    /// gone must never resolve the gate a newer question is waiting on, and
    /// the agent must never receive an answer to a question it did not ask.
    static func gate(
        forToolCall toolCallID: ToolCallID?,
        pendingPermissions: [PermissionRequest]
    ) -> PermissionRequestID? {
        // Searched, not the head of the queue: a Bash request from a parallel
        // tool call can be open ahead of the question's gate.
        let gates = pendingPermissions.filter { $0.toolName == "AskUserQuestion" }
        if let toolCallID, let exact = gates.first(where: { $0.toolCallID == toolCallID }) {
            return exact.id
        }
        // One side did not report a tool call id, so there is nothing to
        // contradict the pairing. A chat only ever has one AskUserQuestion
        // gate open at a time, so the tool name is the best evidence left.
        return gates.first { toolCallID == nil || $0.toolCallID == nil }?.id
    }

    /// The reply to send back through the gate once a tool call's questions
    /// have all been answered.
    ///
    /// Phrased as a denial with a reason because that is the only channel a
    /// permission gate has for carrying text back to the agent.
    static func reply(for answered: [(question: AgentQuestion, answer: String)]) -> String {
        let given = answered.filter { !$0.answer.trimmed.isEmpty }
        guard !given.isEmpty else {
            return "The user dismissed the question without choosing; continue."
        }
        if given.count == 1, answered.count == 1 {
            return "The user answered your question: \"\(given[0].answer.trimmed)\". "
                + "Continue with this answer in mind."
        }
        let lines = given.map { "- \($0.question.prompt) → \"\($0.answer.trimmed)\"" }
        let unanswered = answered.filter { $0.answer.trimmed.isEmpty }
        var reply = "The user answered:\n" + lines.joined(separator: "\n")
        if !unanswered.isEmpty {
            reply += "\n\nThey skipped: "
                + unanswered.map(\.question.prompt).joined(separator: "; ")
                + ". Do not re-ask; proceed with what they did say."
        }
        return reply + "\n\nContinue with these answers in mind."
    }

    /// What is still pending once `requestID` has been answered.
    ///
    /// The permission itself, any plan it gated, and — the part that was
    /// missing — the questions raised by the same tool call.
    static func remaining(
        _ items: [TabNeedsYou],
        resolving requestID: PermissionRequestID
    ) -> [TabNeedsYou] {
        let gatedToolCall = items.compactMap { item -> ToolCallID? in
            guard case .permission(let permission) = item,
                  permission.request.id == requestID else { return nil }
            return permission.request.toolCallID
        }.first
        return items.filter { item in
            switch item {
            case .permission(let item): return item.request.id != requestID
            case .plan(let item): return item.permissionRequestID != requestID
            case .question(let item):
                guard let gatedToolCall, let asked = item.question.toolCallID else { return true }
                return asked != gatedToolCall
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
