import Foundation
import OreProtocol

/// Long chats open on the newest turns first. Older turns are prepended once
/// their blocks arrive, so switching to a year-old conversation does not wait
/// on every tool result before the latest reply is on screen.
enum ChatHistoryWindow {
    static let recentTurnLimit = 8

    static func split<T>(_ turns: [T]) -> (recent: [T], older: [T]) {
        guard turns.count > recentTurnLimit else { return (turns, []) }
        return (
            Array(turns.suffix(recentTurnLimit)),
            Array(turns.dropLast(recentTurnLimit))
        )
    }

    /// Markers belong with the window whose turns they fall in. Putting every
    /// transition on the older batch (then prepending it) parked recent
    /// switches above the older turns.
    static func splitTransitions(
        _ transitions: [ChatTransition],
        recentStart: Date?
    ) -> (recent: [ChatTransition], older: [ChatTransition]) {
        guard let recentStart else { return (transitions, []) }
        var recent: [ChatTransition] = []
        var older: [ChatTransition] = []
        recent.reserveCapacity(transitions.count)
        older.reserveCapacity(transitions.count)
        for transition in transitions {
            if transition.createdAt >= recentStart {
                recent.append(transition)
            } else {
                older.append(transition)
            }
        }
        return (recent, older)
    }
}

/// One clickable entry in the transcript outline: a user prompt and the row
/// it occupies in the displayed table.
struct ChatOutlineItem: Equatable, Sendable {
    var row: Int
    var title: String

    static func items(from rows: [TranscriptRow]) -> [ChatOutlineItem] {
        rows.enumerated().compactMap { index, row in
            guard row.kind == .userMessage else { return nil }
            return ChatOutlineItem(row: index, title: title(from: row.text))
        }
    }

    static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? text
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 42 { return trimmed.isEmpty ? "Message" : trimmed }
        return String(trimmed.prefix(41)) + "…"
    }
}
