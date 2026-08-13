import Foundation

/// A durable divider in a chat transcript. The transcript remains one visible
/// conversation while its provider incarnation or model changes beneath it.
public struct ChatTransition: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case harnessChanged
        case modelChanged
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
        }
    }
}
