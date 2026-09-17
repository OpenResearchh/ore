import Foundation
import Testing

@testable import OreMac

/// The deep links are a URL *scheme*, not API: a typo in an anchor produces a
/// button that silently does nothing, which is the exact dead end this type
/// exists to remove. Nothing here opens System Settings — it asserts that every
/// pane ORE can send someone to is spelled well enough to become a URL, and
/// that each one also has a name to fall back on when `open` refuses it.
struct SystemSettingsLinkTests {
    @Test func everyPaneProducesAValidURL() {
        for link in SystemSettingsLink.allCases {
            #expect(link.url != nil, "\(link) has no URL")
            #expect(link.url?.scheme == "x-apple.systempreferences")
            #expect(!link.paneName.isEmpty)
        }
    }

    /// Notifications is not a privacy pane, and pointing it at the privacy one
    /// lands the user on a screen with no notification settings on it.
    @Test func notificationsGoesToItsOwnPaneNotPrivacy() {
        let notifications = SystemSettingsLink.notifications.url?.absoluteString ?? ""
        #expect(notifications.contains("Notifications-Settings"))

        for link in SystemSettingsLink.allCases where link != .notifications {
            let url = link.url?.absoluteString ?? ""
            #expect(url.contains("com.apple.preference.security"))
            #expect(url.hasSuffix(link.rawValue))
        }
    }
}
