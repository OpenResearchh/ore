import OreProtocol

/// Decides which harness upgrades are worth showing the user right now.
///
/// Separate from the card so the nagging rules can be reasoned about (and
/// tested) without a window: an update prompt that reappears after the user
/// said "Later" is the fastest way to teach someone to ignore the banner.
enum HarnessUpdatePrompting {
    /// Upgrades that should be on screen: really newer, and not the exact
    /// version this user already dismissed.
    ///
    /// Dismissal is keyed by version, not by harness. "Later" answers *this*
    /// release; the next one is a new question, and a user who never wants to
    /// hear about a CLI again can stop asking ORE to drive it.
    static func pending(
        statuses: [HarnessUpdateStatus],
        dismissed: [HarnessKind: String]
    ) -> [HarnessUpdateStatus] {
        statuses.filter { status in
            guard status.isUpdateAvailable, let latest = status.latestVersion else { return false }
            return dismissed[status.kind] != latest
        }
    }
}
