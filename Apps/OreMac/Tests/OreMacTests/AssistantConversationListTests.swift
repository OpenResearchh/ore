import Foundation
import OreProtocol
import Testing

@testable import OreMac

/// The Assistant window had two things wrong at once: its switcher listed every
/// conversation ORE had ever opened on the user's behalf, and the line marking
/// each compaction drew into a 4pt row, leaving only the tops of its letters.
@MainActor
struct AssistantConversationListTests {
    private let workspace = WorkspaceID.generate()

    private func conversation(
        _ title: String,
        turns: Int,
        closed: Bool = false,
        minutesAgo: Double
    ) -> ChatSummary {
        ChatSummary(
            id: ChatID.generate(),
            workspaceID: workspace,
            title: title,
            harness: .codex,
            isClosed: closed,
            turnCount: turns,
            createdAt: Date(timeIntervalSinceNow: -minutesAgo * 60 - 1),
            lastActivity: Date(timeIntervalSinceNow: -minutesAgo * 60)
        )
    }

    @Test func housekeepingConversationsAreNotListed() {
        let spoken = conversation("Postgres migration", turns: 4, minutesAgo: 30)
        let digestsOnly = conversation("Chat 47", turns: 0, minutesAgo: 5)
        let empty = conversation("Chat 48", turns: 0, minutesAgo: 1)

        let list = AssistantConversationList([spoken, digestsOnly, empty], current: spoken.id)

        #expect(list.recent.map(\.id) == [spoken.id])
        #expect(list.earlier.isEmpty)
    }

    /// Even an empty conversation is listed while it is the one on screen —
    /// a fresh successor has no turns yet, and the checkmark needs a row.
    @Test func theCurrentConversationIsAlwaysListed() {
        let older = conversation("Postgres migration", turns: 4, minutesAgo: 30)
        let fresh = conversation("Chat 49", turns: 0, minutesAgo: 1)

        let list = AssistantConversationList([older, fresh], current: fresh.id)

        #expect(list.recent.map(\.id) == [fresh.id, older.id])
    }

    /// Retired conversations are history, not a separate "Closed" pile: they
    /// sit in time order with the rest, newest first, and the long tail folds.
    @Test func conversationsAreNewestFirstWithTheTailFolded() {
        let all = (0..<(AssistantConversationList.recentLimit + 3)).map {
            conversation("c\($0)", turns: 2, closed: $0 % 2 == 0, minutesAgo: Double($0))
        }

        let list = AssistantConversationList(all.reversed(), current: nil)

        #expect(list.recent.map(\.title) == all.prefix(AssistantConversationList.recentLimit).map(\.title))
        #expect(list.earlier.map(\.title) == all.dropFirst(AssistantConversationList.recentLimit).map(\.title))
    }

    @Test func aDividerRowIsTallEnoughForItsText() {
        let divider = TranscriptRow(
            id: "transition-1",
            turnID: TurnID(rawValue: "transition"),
            kind: .divider,
            text: "Conversation compacted — continued in a new conversation",
            isComplete: true
        )
        let width: CGFloat = 600
        let text = TranscriptHeightMeasurer.height(
            of: TranscriptCell.attributedText(for: divider), width: width - 20
        )

        // 16pt of label padding sits inside the row before the text starts.
        #expect(text > 0)
        #expect(TranscriptCell.height(for: divider, width: width) >= ceil(text) + 16)

        // And a narrow window wraps it rather than clipping it.
        #expect(
            TranscriptCell.height(for: divider, width: 160)
                > TranscriptCell.height(for: divider, width: width)
        )
    }
}
