/// Picks which tab should become active after the current one is closed.
///
/// Closing always used to jump to the first remaining tab, which is jarring
/// when you close anything that isn't the oldest. Prefer the right-hand
/// neighbor (browser-style); if that was the last tab, fall back to the left.
enum TabCloseSelection {
    /// `nil` when the closed tab was not active, or when nothing remains.
    static func replacement<ID: Equatable>(
        closing closedID: ID,
        active activeID: ID?,
        open: [ID]
    ) -> ID? {
        guard activeID == closedID else { return nil }
        guard let index = open.firstIndex(of: closedID) else { return nil }
        if index + 1 < open.count { return open[index + 1] }
        if index > 0 { return open[index - 1] }
        return nil
    }
}
