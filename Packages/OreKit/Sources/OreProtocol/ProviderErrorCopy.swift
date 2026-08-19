import Foundation

/// Turns provider error payloads into something a person can act on.
///
/// Codex in particular forwards OpenAI's JSON body as the error *message*, so
/// the composer would otherwise show a blob of `"type": "invalid_request_error"`
/// instead of the one sentence that tells the user to upgrade the CLI.
public enum ProviderErrorCopy {
    /// Innermost human message, peeling JSON wrappers and transport prefixes.
    public static func unwrap(_ raw: String) -> String {
        var current = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in Self.transportPrefixes where current.hasPrefix(prefix) {
            current = String(current.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for _ in 0..<5 {
            guard let nested = nestedMessage(in: current), nested != current else { break }
            current = nested.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return current
    }

    /// The installed agent CLI is too old for the requested model or protocol.
    public static func needsCLIUpgrade(_ text: String) -> Bool {
        let value = unwrap(text).lowercased()
        if value.contains("requires a newer version") { return true }
        if value.contains("newer version of") { return true }
        if value.contains("upgrade to the latest") { return true }
        if value.contains("update your cli") || value.contains("update the cli") { return true }
        if value.contains("cli is out of date") || value.contains("outdated version") { return true }
        // "Please upgrade … CLI" without matching "upgrade to pro".
        if value.contains("upgrade"), value.contains("cli") { return true }
        return false
    }

    public static func looksLikeRateLimit(_ text: String) -> Bool {
        let value = unwrap(text).lowercased()
        return value.contains("usage limit")
            || value.contains("session limit")
            || value.contains("rate limit")
            || value.contains("rate-limit")
            || value.contains("too many requests")
            || value.contains("quota")
    }

    /// SessionError kind that matches the unwrapped copy, so the UI can offer
    /// Upgrade CLI / wait-for-reset rather than a generic Retry.
    public static func sessionKind(for text: String) -> SessionError.Kind {
        if needsCLIUpgrade(text) { return .protocolMismatch }
        if looksLikeRateLimit(text) { return .rateLimited }
        return .transport
    }

    private static let transportPrefixes = [
        "Transport failure: ",
        "Failed to launch the agent CLI: ",
    ]

    private static func nestedMessage(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }
}
