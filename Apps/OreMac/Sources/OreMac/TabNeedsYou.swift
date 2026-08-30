import Foundation
import OreProtocol

/// A project tab blocked on the user — permission or question — surfaced on
/// the voice HUD and menu bar when the user is in another app.
enum TabNeedsYou: Identifiable, Equatable {
    struct Permission: Equatable {
        var workspaceID: WorkspaceID
        var chatID: ChatID
        var request: PermissionRequest
    }

    struct Question: Equatable {
        var workspaceID: WorkspaceID
        var chatID: ChatID
        var question: AgentQuestion
    }

    case permission(Permission)
    case question(Question)

    var id: String {
        switch self {
        case .permission(let item): return "permission-\(item.request.id.rawValue)"
        case .question(let item): return "question-\(item.question.id.rawValue)"
        }
    }

    var workspaceID: WorkspaceID {
        switch self {
        case .permission(let item): return item.workspaceID
        case .question(let item): return item.workspaceID
        }
    }

    var chatID: ChatID {
        switch self {
        case .permission(let item): return item.chatID
        case .question(let item): return item.chatID
        }
    }

    /// Queue identity for the spoken prompt. Keeping the permission request ID
    /// here is what lets a click invalidate this exact line without cutting
    /// off unrelated assistant speech.
    var narrationKind: SpokenUtterance.Kind {
        switch self {
        case .permission(let item): return .permission(item.request.id)
        case .question: return .question
        }
    }

    /// The written form of the ask, for a row the user reads rather than
    /// hears. Deliberately not `spokenSummary`: "A tab wants to run Bash." is
    /// the right sentence out loud and the wrong one next to a button that
    /// says Allow, where the tool and its argument are the whole point.
    var headline: String {
        switch self {
        case .permission(let item):
            let tool = item.request.displayName ?? item.request.toolName
            guard let summary = item.request.summary, !summary.isEmpty else { return tool }
            return "\(tool) — \(summary)"
        case .question(let item):
            return item.question.prompt
        }
    }

    /// "workspace / tab", or the workspace alone when the tab can't be named.
    /// The assistant's own answers name places this way, so a row the user
    /// clicks reads like the sentence they just heard.
    func placeLabel(workspace: String?, tab: String?) -> String {
        let place = workspace ?? "another workspace"
        guard let tab, !tab.isEmpty else { return place }
        return "\(place) / \(tab)"
    }

    var spokenSummary: String {
        switch self {
        case .permission(let item):
            let tool = item.request.displayName ?? item.request.toolName
            let detail = item.request.summary.map { " (\($0))" } ?? ""
            return "A tab wants to run \(tool)\(detail)."
        case .question(let item):
            return String(item.question.prompt.prefix(160))
        }
    }

    /// One complete spoken prompt. Questions include every choice instead of
    /// being flattened into a yes/no permission prompt, and explicitly leave
    /// room for the user's own answer when the harness supports it.
    var spokenPrompt: String {
        switch self {
        case .permission:
            return "Quick check — \(spokenSummary) Yes to allow, no to deny, "
                + "or always to auto-allow this tab."
        case .question(let item):
            var prompt = "Quick check — \(item.question.prompt)"
            if !item.question.options.isEmpty {
                let labels = item.question.options.map(\.label)
                prompt += " Your options are \(Self.spokenList(labels))."
            }
            if item.question.allowsFreeform {
                prompt += " Say an option, or say your own answer."
            } else if !item.question.options.isEmpty {
                prompt += " Say the option you want."
            }
            return prompt
        }
    }

    private static func spokenList(_ values: [String]) -> String {
        switch values.count {
        case 0: return ""
        case 1: return values[0]
        case 2: return "\(values[0]), or \(values[1])"
        default:
            return values.dropLast().joined(separator: ", ") + ", or " + (values.last ?? "")
        }
    }
}
