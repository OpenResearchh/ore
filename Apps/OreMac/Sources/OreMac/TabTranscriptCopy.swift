import Foundation
import OreProtocol

/// Clipboard-ready context for moving work between chat tabs.
///
/// This intentionally exports the conversation, not the transport log: tool
/// payloads, hidden thinking, fleet-watch digests, and UI-only rows add a great
/// deal of text without helping the receiving agent continue the task. The
/// short form keeps the latest three turns; the full form keeps every visible
/// user/assistant exchange.
enum TabTranscriptCopy {
    enum Length {
        case short
        case full
    }

    static let shortTurnCount = 3

    static func render(
        tabTitle: String,
        agentName: String,
        rows: [TranscriptRow],
        length: Length
    ) -> String {
        var entries = rows.compactMap { entry(for: $0, agentName: agentName) }
        if length == .short {
            var orderedTurns: [TurnID] = []
            var seen: Set<TurnID> = []
            for entry in entries where seen.insert(entry.turnID).inserted {
                orderedTurns.append(entry.turnID)
            }
            let keptTurns = Set(orderedTurns.suffix(shortTurnCount))
            entries.removeAll { !keptTurns.contains($0.turnID) }
        }

        let merged = mergeAdjacent(entries)
        let scope = length == .short
            ? "the latest \(shortTurnCount) conversational turns"
            : "the full conversational transcript"
        let header = "Context copied from ORE tab “\(tabTitle)” (\(agentName)); \(scope)."
        guard !merged.isEmpty else { return header }

        let body = merged.map { "\($0.speaker):\n\($0.text)" }
            .joined(separator: "\n\n")
        return "\(header)\nContinue the work from this context:\n\n\(body)"
    }

    private struct Entry {
        var turnID: TurnID
        var speaker: String
        var text: String
    }

    private static func entry(for row: TranscriptRow, agentName: String) -> Entry? {
        let speaker: String
        switch row.kind {
        case .userMessage:
            guard row.origin != .watch else { return nil }
            speaker = row.origin == .agent ? "ORE" : "User"
        case .assistantText:
            speaker = agentName
        case .plan:
            speaker = "\(agentName) plan"
        case .error:
            speaker = "\(agentName) error"
        case .thinking, .toolCall, .divider, .activityGroup, .turnFooter:
            return nil
        }

        var text = row.kind == .plan
            ? (PlanProposalPolicy.normalizedMarkdown(row.text) ?? row.text)
            : row.text
        let attachmentNames = row.attachments.map { "@\($0.displayName)" }
        if !attachmentNames.isEmpty {
            text += (text.isEmpty ? "" : "\n\n") + attachmentNames.joined(separator: "  ")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Entry(turnID: row.turnID, speaker: speaker, text: text)
    }

    /// Streaming and completed replies may produce several consecutive prose
    /// blocks. One speaker heading per turn is easier to scan after pasting.
    private static func mergeAdjacent(_ entries: [Entry]) -> [Entry] {
        var result: [Entry] = []
        for entry in entries {
            if let last = result.indices.last,
               result[last].turnID == entry.turnID,
               result[last].speaker == entry.speaker {
                result[last].text += "\n\n" + entry.text
            } else {
                result.append(entry)
            }
        }
        return result
    }
}
