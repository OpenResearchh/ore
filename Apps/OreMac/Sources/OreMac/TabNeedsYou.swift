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
