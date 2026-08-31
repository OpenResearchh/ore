import OreProtocol

/// When a streamed token may republish the chat's chrome summary.
///
/// Sidebar, tab bar, and menu bar all observe `ChatSummary`. Token deltas do
/// not change those fields; only status, queue, unread, turn, and (throttled)
/// context-meter ticks do. Gating here is what keeps a streaming agent from
/// rebuilding the whole window on every token.
enum ChatChromePublishPolicy {
    /// Token ticks that do not move the context meter by a visible percent
    /// (or by a thousand tokens when the window is unknown) stay off the
    /// chrome stream. The transcript still sees every `usage` event.
    static func shouldPublishUsage(previous: UsageReport?, next: UsageReport) -> Bool {
        guard let previous else { return true }
        if previous.contextWindow != next.contextWindow { return true }
        if let window = next.contextWindow, window > 0 {
            return previous.totalContextTokens * 100 / window
                != next.totalContextTokens * 100 / window
        }
        return abs(next.totalContextTokens - previous.totalContextTokens) >= 1_000
    }
}
