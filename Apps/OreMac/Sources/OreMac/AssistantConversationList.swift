import Foundation
import OreProtocol

/// Which of the assistant's conversations its switcher lists, and where.
///
/// ORE creates these itself — a compaction opens a successor, and fleet
/// digests keep arriving whether or not anyone is talking — so the raw list is
/// mostly housekeeping: empty "Chat 47"s and conversations that only ever
/// carried digests. Listing all of it made the menu a wall the user had to
/// manage. What is left is what they actually said something in, newest first,
/// a handful up front and the rest one level down.
struct AssistantConversationList {
    static let recentLimit = 6
    /// A menu is not an archive browser; past this the conversations are
    /// still stored and searchable, just not listed.
    static let earlierLimit = 30

    private(set) var recent: [ChatSummary] = []
    private(set) var earlier: [ChatSummary] = []

    init(_ conversations: [ChatSummary], current: ChatID?) {
        // `turnCount` is the person's turns — digests are already excluded —
        // so zero means they never spoke here. The current conversation is
        // listed regardless, or the checkmark would have nowhere to go.
        let spoken = conversations
            .filter { $0.id == current || $0.turnCount > 0 }
            .sorted { ($0.lastActivity ?? $0.createdAt) > ($1.lastActivity ?? $1.createdAt) }
        recent = Array(spoken.prefix(Self.recentLimit))
        earlier = Array(spoken.dropFirst(Self.recentLimit).prefix(Self.earlierLimit))
    }
}
