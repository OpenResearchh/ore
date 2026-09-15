import Foundation
import OreProtocol

/// A finite, in-memory grant. It never changes the harness's permission mode.
struct WorkspaceAutoApproval: Equatable {
    let workspaceID: WorkspaceID
    let expiresAt: Date

    func allows(_ request: PermissionRequest, in workspaceID: WorkspaceID, now: Date = Date()) -> Bool {
        self.workspaceID == workspaceID && now < expiresAt
            && WorkspacePermissionPolicy.isToolRequest(request)
    }
}

enum WorkspacePermissionPolicy {
    static func isToolRequest(_ request: PermissionRequest) -> Bool {
        !["AskUserQuestion", "ExitPlanMode"].contains(request.toolName)
    }

    static func canEdit(_ request: PermissionRequest, harness: HarnessKind) -> Bool {
        // Codex and Cursor approval replies do not accept replacement input.
        harness == .claudeCode && isToolRequest(request) && request.input.objectValue != nil
    }

    static func inputText(_ input: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(input) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func editedInput(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              value.objectValue != nil else { return nil }
        return value
    }
}
