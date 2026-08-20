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
}
