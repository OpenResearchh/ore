import OreProtocol

/// Picks which open chat should receive a shipping prompt (Commit / Create PR).
///
/// Preference order:
/// 1. The selected tab, if its agent is idle and the composer is empty.
/// 2. Otherwise the newest idle, empty-composer tab in the workspace.
/// 3. `nil` — open a new tab rather than interrupting a turn or clobbering a draft.
enum ComposerPlacement {
    static func target(
        active: ChatSummary?,
        open: [ChatSummary],
        isOccupied: (ChatSummary) -> Bool
    ) -> ChatSummary? {
        func reusable(_ chat: ChatSummary) -> Bool {
            !isOccupied(chat)
                && chat.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let active, reusable(active) { return active }
        return open.reversed().first(where: reusable)
    }
}
