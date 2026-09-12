import Foundation
import OreProtocol

/// How much shell work ORE approves without asking.
///
/// A layer on top of the permission modes, not a replacement for them. It only
/// ever sees requests a mode already decided to ask about — Ask and Accept
/// Edits prompt for shell commands, Plan stays read-only, and Bypass never
/// asks at all — and it only ever turns an ask into an approval, never the
/// reverse.
public enum ShellApprovalLevel: String, Sendable, CaseIterable, Codable {
    /// Every command waits for the user: ORE's behaviour before this setting.
    case askEveryTime
    /// Commands that only look or build — listing, reading, searching, git
    /// status and diffs, the project's own tests and linters. The default.
    case routine
    /// Everything except what needs the user: local edits and unrecognised
    /// commands too. Deletes, credentials, pushes, installs, privilege and
    /// anything ORE can't read still ask, whatever this is set to.
    case allButAttention

    public static let `default`: ShellApprovalLevel = .routine

    public func autoApproves(_ kind: ShellCommandVerdict.Kind) -> Bool {
        switch self {
        case .askEveryTime: false
        case .routine: kind <= .build
        case .allButAttention: kind < .attention
        }
    }
}

public enum ShellApprovalPolicy {
    /// The approval ORE gives on the user's behalf, or `nil` to ask them.
    public static func automaticApproval(
        for request: PermissionRequest,
        level: ShellApprovalLevel
    ) -> AutomaticApproval? {
        guard level != .askEveryTime,
              let command = ShellCommandClassifier.command(in: request),
              let verdict = ShellCommandClassifier.verdict(for: request),
              level.autoApproves(verdict.kind)
        else { return nil }
        return AutomaticApproval(toolCallID: request.toolCallID, command: command, reason: verdict.reason)
    }
}

extension ShellCommandClassifier {
    /// The shell command a permission request would run, if it is one.
    ///
    /// Only the shell tool is ever judged. A file write or an MCP call is
    /// never read here, so the policy cannot approve anything it wasn't built
    /// to understand.
    public static func command(in request: PermissionRequest) -> String? {
        guard request.toolName == "Bash" else { return nil }
        // Codex sends argv; read the array rather than its joined form, which
        // lost the quoting that makes `bash -lc 'a && b'` one argument.
        if let argv = request.input["argv"]?.arrayValue?.compactMap(\.stringValue), !argv.isEmpty {
            return argv.map(quoted).joined(separator: " ")
        }
        guard let command = request.input["command"]?.stringValue, !command.isEmpty else { return nil }
        return command
    }

    /// What the request would do, including what the harness says about it
    /// beyond the command text.
    public static func verdict(for request: PermissionRequest) -> ShellCommandVerdict? {
        guard let command = command(in: request) else { return nil }
        // Claude Code's `run_in_background` outlives the turn that asked,
        // which is exactly the kind of thing the user should see happen.
        if request.input["run_in_background"]?.boolValue == true {
            return .attention("keeps running in the background")
        }
        return classify(command)
    }

    /// One argv element, quoted so `ShellCommandLine` reads it back as exactly
    /// one word.
    static func quoted(_ word: String) -> String {
        let plain = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@%+,"
        )
        if !word.isEmpty, word.unicodeScalars.allSatisfy(plain.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
