import Foundation

/// A durable divider in a chat transcript. The transcript remains one visible
/// conversation while its provider incarnation or model changes beneath it.
public struct ChatTransition: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case harnessChanged
        case modelChanged
        /// ORE retired this conversation into a summary and opened a fresh one
        /// from it.
        case compacted
        /// The other side of a `compacted` seam. Two kinds rather than one
        /// with a direction, because the two transcripts need opposite
        /// sentences: the retired one has to say where the conversation went,
        /// and the successor — which otherwise opens blank — has to say what
        /// it continues.
        case continuedFromCompaction
    }

    public var id: String
    public var chatID: ChatID
    public var kind: Kind
    public var fromHarness: HarnessKind?
    public var toHarness: HarnessKind?
    public var fromModel: String?
    public var toModel: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        chatID: ChatID,
        kind: Kind,
        fromHarness: HarnessKind? = nil,
        toHarness: HarnessKind? = nil,
        fromModel: String? = nil,
        toModel: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.chatID = chatID
        self.kind = kind
        self.fromHarness = fromHarness
        self.toHarness = toHarness
        self.fromModel = fromModel
        self.toModel = toModel
        self.createdAt = createdAt
    }
}

public extension ChatTransition {
    var displayText: String {
        switch kind {
        case .harnessChanged:
            let from = fromHarness?.displayName ?? "Previous agent"
            let to = toHarness?.displayName ?? "new agent"
            return "Switched from \(from) to \(to)"
        case .modelChanged:
            return "Model changed from \(fromModel ?? "default") to \(toModel ?? "default")"
        case .compacted:
            return "Conversation compacted — continued in a new conversation"
        case .continuedFromCompaction:
            return "Continued from an earlier conversation, summarized above"
        }
    }
}
