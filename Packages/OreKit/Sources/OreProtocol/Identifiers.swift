import Foundation

/// String-backed identifier with free `Codable`/`Hashable` conformance.
public protocol OreIdentifier: RawRepresentable, Sendable, Hashable, Codable,
    CustomStringConvertible, ExpressibleByStringLiteral
where RawValue == String {
    init(rawValue: String)
}

extension OreIdentifier {
    public init(stringLiteral value: String) { self.init(rawValue: value) }
    public var description: String { rawValue }

    /// A fresh random identifier. Used wherever ORE owns the id namespace
    /// (workspaces, sessions, turns) rather than mirroring a provider's.
    public static func generate() -> Self { Self(rawValue: UUID().uuidString.lowercased()) }
}

public struct WorkspaceID: OreIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// ORE's identity for one durable chat tab. A workspace can own many chats,
/// each with an independent harness session, model, queue and unread state.
public struct ChatID: OreIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// ORE's own session identity. Distinct from the harness's `providerSessionID`,
/// which is owned by the CLI and changes when a session is forked.
public struct SessionID: OreIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct TurnID: OreIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Identifies one content block (a text run, a thinking run) inside a turn.
public struct BlockID: OreIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ToolCallID: OreIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct PermissionRequestID: OreIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct QuestionID: OreIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct DreamRunID: OreIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct DreamTaskID: OreIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct DreamFindingID: OreIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}
