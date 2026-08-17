import Foundation
import OreProtocol

/// Turns a failed cursor-agent run into something the user can act on.
///
/// This CLI reports *why* it failed exclusively on stderr, and exits non-zero
/// with a completely empty stdout. An unavailable model, an expired login and
/// an exhausted quota are therefore indistinguishable from the exit status
/// alone — which is why they all used to surface as the same
/// "cursor-agent exited with status 1", a message that tells the user nothing
/// they can fix.
///
/// Every branch below keys off stderr text, and the unrecognized case reports
/// stderr verbatim rather than dropping it: an ugly real message beats a tidy
/// useless one, and it is also how the next unhandled shape gets discovered.
enum CursorAgentFailure {
    /// Classifies a non-zero exit. `stderr` is the tail of the process's
    /// diagnostics, already newline-joined.
    static func classify(exitCode: Int32, stderr: String) -> SessionError {
        let text = stripANSI(stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = text.lowercased()

        // Ordered most-specific first: a quota message often also mentions the
        // model, and an auth failure often also mentions the API key.
        if let limit = usageLimit(text: text, lowercased: lowercased) { return limit }
        if let model = modelUnavailable(text: text, lowercased: lowercased) { return model }
        if let auth = notAuthenticated(text: text, lowercased: lowercased) { return auth }
        if let network = networkFailure(text: text, lowercased: lowercased) { return network }

        // Unrecognized. Show what the CLI actually said — the exit code on its
        // own is exactly the dead end this type exists to remove.
        guard !text.isEmpty else {
            return SessionError(
                kind: .processFailed,
                message: "cursor-agent exited with status \(exitCode) without reporting a reason. "
                    + "Try the same prompt in a terminal to see the full output.",
                detail: nil,
                isRecoverable: true
            )
        }
        return SessionError(
            kind: .processFailed,
            message: "cursor-agent failed (status \(exitCode)): \(summarize(text))",
            detail: text,
            isRecoverable: true
        )
    }

    // MARK: - Cases

    /// The case the user most needs named, because the fix is "wait" or "pay"
    /// rather than anything in the app. Cursor's wording varies by plan, so
    /// this matches on the whole family of quota phrasings.
    private static func usageLimit(text: String, lowercased: String) -> SessionError? {
        let markers = [
            "rate limit", "rate-limit", "too many requests", "429",
            "usage limit", "usage-based", "quota", "out of credits",
            "insufficient credits", "no credits", "spend limit", "monthly limit",
            "hit your limit", "reached your limit", "upgrade to pro",
            "free trial has expired", "purchase more credits",
        ]
        guard markers.contains(where: lowercased.contains) else { return nil }
        // Keep Cursor's own sentence: it is the part that names the plan and
        // often carries the reset time the banner parses out of this message.
        return SessionError(
            kind: .rateLimited,
            message: "Cursor usage limit reached — \(summarize(text)) "
                + "Wait for the quota to reset, switch to a cheaper model, "
                + "or add credits in Cursor's dashboard.",
            detail: text,
            // The plan recovers on its own; the session itself is still fine.
            isRecoverable: true
        )
    }

    /// `Cannot use this model: <id>. Available models: <150 of them>`.
    ///
    /// The available-model list is deliberately dropped: it is ~2KB of ids that
    /// would bury the one sentence that matters, and the model picker already
    /// shows the same catalog in a form the user can click.
    private static func modelUnavailable(text: String, lowercased: String) -> SessionError? {
        guard lowercased.contains("cannot use this model")
            || lowercased.contains("unknown model")
            || lowercased.contains("model not found")
            || lowercased.contains("invalid model")
        else { return nil }

        let named = modelName(in: text)
        let subject = named.map { "The model `\($0)` isn't" } ?? "That model isn't"
        return SessionError(
            kind: .processFailed,
            message: "\(subject) available to your Cursor account. "
                + "Pick a different model from the model picker — "
                + "your plan's catalog may have changed.",
            detail: text,
            isRecoverable: true
        )
    }

    /// Everything between `model:` and the sentence end, which is where the
    /// CLI puts the id it rejected.
    private static func modelName(in text: String) -> String? {
        guard let range = text.range(of: "model:", options: .caseInsensitive) else { return nil }
        let rest = text[range.upperBound...]
        let name = rest.prefix { $0 != "." && !$0.isNewline }
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func notAuthenticated(text: String, lowercased: String) -> SessionError? {
        let markers = [
            "api key is invalid", "invalid api key", "not logged in", "not authenticated",
            "unauthorized", "401", "please log in", "please login", "authentication failed",
            "session expired", "token expired",
        ]
        guard markers.contains(where: lowercased.contains) else { return nil }
        let usesAPIKey = lowercased.contains("api key")
        return SessionError(
            kind: .notAuthenticated,
            message: usesAPIKey
                ? "Cursor rejected the API key. Clear or replace `CURSOR_API_KEY`, "
                    + "or run `cursor-agent login` to authenticate without one."
                : "Cursor isn't signed in. Run `cursor-agent login` in a terminal, "
                    + "then send the message again.",
            detail: text,
            // Nothing the app can retry until the user signs in.
            isRecoverable: false
        )
    }

    private static func networkFailure(text: String, lowercased: String) -> SessionError? {
        let markers = [
            "econnrefused", "enotfound", "econnreset", "getaddrinfo",
            "network error", "fetch failed", "socket hang up", "timed out",
            "etimedout", "offline", "dns",
        ]
        guard markers.contains(where: lowercased.contains) else { return nil }
        return SessionError(
            kind: .transport,
            message: "Couldn't reach Cursor's servers — \(summarize(text)) "
                + "Check your network connection and try again.",
            detail: text,
            isRecoverable: true
        )
    }

    // MARK: - Text handling

    /// The leading sentence or two, capped. cursor-agent can print a wall of
    /// text (a model catalog, a stack trace); a banner needs the headline, and
    /// the untruncated original stays on `detail` for bug reports.
    private static func summarize(_ text: String, limit: Int = 240) -> String {
        let firstMeaningful = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(2)
            .joined(separator: " ")
        let collapsed = firstMeaningful.isEmpty ? text : firstMeaningful
        guard collapsed.count > limit else { return collapsed }
        return collapsed.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// cursor-agent colours its warnings even when stdout isn't a TTY, so raw
    /// stderr arrives as `\u{1B}[33m⚠ Warning: …\u{1B}[0m`. Rendered in a
    /// SwiftUI `Text` those escapes show up as literal `[33m` garbage.
    static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var iterator = text.makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            guard character == "\u{1B}" else {
                result.append(character)
                continue
            }
            // CSI (`ESC [`) runs until a byte in @–~; anything else is a short
            // two-character sequence we drop along with its introducer.
            guard let next = iterator.next() else { break }
            guard next == "[" else { continue }
            while let terminator = iterator.next() {
                if let ascii = terminator.asciiValue, (0x40...0x7E).contains(ascii) { break }
                // A malformed sequence shouldn't eat the rest of the string.
                if terminator == "\u{1B}" { pending = terminator; break }
            }
        }
        return result
    }
}
