import Foundation
import OreProtocol

/// Replays a recorded Claude Code transcript through the driver's translator.
///
/// This is the seam the stability discipline hangs off: record one real session
/// per CLI version, then assert in CI that the same bytes still produce the same
/// normalized events. Protocol churn shows up as a failing diff instead of as a
/// user-visible regression weeks later.
public enum ClaudeCodeTranscriptReplay {
    /// Feeds newline-delimited JSON through the translator and returns the
    /// events it produced.
    public static func events(
        transcript: String,
        sessionID: SessionID = SessionID(rawValue: "replay")
    ) -> [AgentEvent] {
        var translator = ClaudeCodeTranslator(sessionID: sessionID)
        var events: [AgentEvent] = []
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            events.append(contentsOf: translator.translate(line: String(line)).events)
        }
        return events
    }

    public static func events(
        transcriptAt url: URL,
        sessionID: SessionID = SessionID(rawValue: "replay")
    ) throws -> [AgentEvent] {
        events(transcript: try String(contentsOf: url, encoding: .utf8), sessionID: sessionID)
    }
}
