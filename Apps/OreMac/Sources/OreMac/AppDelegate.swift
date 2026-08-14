import AppKit
import SwiftUI
import UserNotifications

/// Application-level behaviour SwiftUI doesn't expose.
///
/// The activation policy is the important one. A SwiftUI app launched through
/// LaunchServices gets `.regular` for free, but one launched by running its
/// executable directly — which is how a script, or CI, runs it — does not, and
/// then never shows a window at all. Setting it explicitly makes both paths
/// behave the same.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // A visual-test override; normal launches keep the system appearance.
        // This lets CI exercise both semantic colour paths without changing
        // the developer's global macOS setting.
        if ProcessInfo.processInfo.environment["ORE_APPEARANCE"] == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if ProcessInfo.processInfo.environment["ORE_APPEARANCE"] == "light" {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        NSApp.activate(ignoringOtherApps: true)
        UNUserNotificationCenter.current().delegate = self

        MainActor.assumeIsolated {
            WindowSnapshot.scheduleIfRequested()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    /// Closing the last window quits. ORE is a single-window app; leaving a
    /// dockless process behind would mean agents running with nothing to show
    /// for them.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Child agent processes are terminated by their sessions on shutdown;
        // this is the last chance to make sure that happened.
        NotificationCenter.default.post(name: .oreApplicationWillTerminate, object: nil)
    }
}

extension Notification.Name {
    static let oreApplicationWillTerminate = Notification.Name("ore.applicationWillTerminate")
}
