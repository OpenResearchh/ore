import Foundation
import OreProtocol

/// Cheap main-thread fanout counters for Instruments sessions.
///
/// During a text-only stream, `chatUpdated` should stay near 0 rather than
/// tracking `textDelta`. Equal consecutive `ChatSummary`s mean the publish
/// was waste. DEBUG-only so production builds do not pay the increment.
#if DEBUG
@MainActor
enum UIFanoutProbe {
    static var chatUpdated = 0
    static var textDelta = 0
    static var workspaceUpdated = 0
    static var gitStatusChanged = 0
    static var equalChatSummariesSkipped = 0

    static func reset() {
        chatUpdated = 0
        textDelta = 0
        workspaceUpdated = 0
        gitStatusChanged = 0
        equalChatSummariesSkipped = 0
    }

    static func record(_ event: CoreEvent) {
        switch event {
        case .chatUpdated:
            chatUpdated += 1
        case .workspaceUpdated:
            workspaceUpdated += 1
        case .gitStatusChanged:
            gitStatusChanged += 1
        case .agent(_, _, .textDelta):
            textDelta += 1
        default:
            break
        }
    }
}
#endif
