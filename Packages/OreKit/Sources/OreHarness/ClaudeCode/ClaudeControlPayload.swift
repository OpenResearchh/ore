import Foundation
import OreProtocol

/// Builders for the payloads ORE sends *to* the Claude Code CLI.
///
/// Kept separate from the session so they can be asserted directly. Golden
/// transcripts only prove we read the CLI correctly; nothing in a recording
/// says whether what we write back is well formed, and the CLI validates
/// strictly — a missing field comes back as an opaque schema error attached to
/// the tool call, not as a protocol error.
enum ClaudeControlPayload {
    /// The body of a `can_use_tool` reply.
    ///
    /// `updatedInput` is mandatory on an allow. It exists so the user can edit
    /// a command before approving it; when they haven't, the original input is
    /// echoed back unchanged.
    static func permissionReply(
        decision: PermissionDecision,
        originalInput: JSONValue
    ) -> JSONValue {
        switch decision {
        case .allow(let updatedInput):
            return .object([
                "behavior": .string("allow"),
                "updatedInput": updatedInput ?? originalInput,
            ])
        case .allowWithSuggestion(let suggestion):
            return .object([
                "behavior": .string("allow"),
                "updatedInput": originalInput,
                "updatedPermissions": .array([suggestion]),
            ])
        case .deny(let reason):
            return .object([
                "behavior": .string("deny"),
                "message": .string(reason),
            ])
        }
    }

    static func interrupt() -> JSONValue {
        .object(["subtype": .string("interrupt")])
    }

    static func setPermissionMode(_ mode: PermissionMode) -> JSONValue {
        .object([
            "subtype": .string("set_permission_mode"),
            "mode": .string(mode.rawValue),
        ])
    }

    static func setModel(_ model: String?) -> JSONValue {
        .object([
            "subtype": .string("set_model"),
            "model": model.map(JSONValue.string) ?? .null,
        ])
    }

    static func initialize() -> JSONValue {
        .object(["subtype": .string("initialize")])
    }
}
