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
    private var isTerminating = false

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
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Self.notificationCategories())

        MainActor.assumeIsolated {
            WindowSnapshot.scheduleIfRequested()
        }
    }

    // MARK: - Notification actions

    /// What a banner can do without the app being opened. Answering from the
    /// notification is the whole point of asking through one — the user is in
    /// another app precisely when these arrive. (A function, not a stored
    /// static: `UNNotificationCategory` isn't Sendable, so a shared constant
    /// trips strict concurrency.)
    static func notificationCategories() -> Set<UNNotificationCategory> { [
        // "Assistant needs approval" — the M2 confirmation tiers, inline.
        UNNotificationCategory(
            identifier: NotificationCategory.assistantConfirmation,
            actions: [
                UNNotificationAction(
                    identifier: NotificationAction.allowTask,
                    title: "Allow for This Task"
                ),
                UNNotificationAction(
                    identifier: NotificationAction.allowOnce,
                    title: "Allow Once"
                ),
                UNNotificationAction(
                    identifier: NotificationAction.deny,
                    title: "Deny",
                    options: [.destructive]
                ),
            ],
            intentIdentifiers: []
        ),
        // "Agent has a question" — an inline text field beats a round trip
        // through the whole app for a one-line answer.
        UNNotificationCategory(
            identifier: NotificationCategory.agentQuestion,
            actions: [
                UNTextInputNotificationAction(
                    identifier: NotificationAction.reply,
                    title: "Reply",
                    textInputButtonTitle: "Send",
                    textInputPlaceholder: "Answer the agent…"
                ),
            ],
            intentIdentifiers: []
        ),
        // "Waiting for permission" — a tool call the user can wave through.
        UNNotificationCategory(
            identifier: NotificationCategory.toolPermission,
            actions: [
                UNNotificationAction(
                    identifier: NotificationAction.allowPermission,
                    title: "Allow"
                ),
                UNNotificationAction(
                    identifier: NotificationAction.denyPermission,
                    title: "Deny",
                    options: [.destructive]
                ),
            ],
            intentIdentifiers: []
        ),
        UNNotificationCategory(
            identifier: NotificationCategory.dreams,
            actions: [
                UNNotificationAction(
                    identifier: NotificationAction.openDreams,
                    title: "Open Dreams"
                ),
            ],
            intentIdentifiers: []
        ),
    ] }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        var info = response.notification.request.content.userInfo
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier, UNNotificationDismissActionIdentifier:
            NotificationCenter.default.post(
                name: .oreOpenFromNotification, object: nil, userInfo: info
            )
        default:
            info["actionIdentifier"] = response.actionIdentifier
            if let text = (response as? UNTextInputNotificationResponse)?.userText {
                info["replyText"] = text
            }
            NotificationCenter.default.post(
                name: .oreNotificationAction, object: nil, userInfo: info
            )
        }
    }

    /// The menu bar presence is what stays: closing the window parks ORE
    /// rather than quitting it, so agents keep running, the assistant keeps
    /// listening, and notifications stay answerable. Quit lives in the menu
    /// bar item and ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Window scenes share one AppModel and one event stream. A scene's
    /// `onDisappear` must not shut that core down while another window (or the
    /// menu-bar app) still needs it, so shutdown belongs to the real process
    /// termination handshake instead.
    ///
    /// The graceful shutdown is raced against a deadline. It stops every
    /// engine and agent session serially, and a single wedged await — a
    /// harness CLI that stopped reading its stdin, say — used to leave the
    /// app in terminate-later limbo forever: alive, mid-quit, unquittable.
    /// That is how the in-app updater "hung at downloading": the update had
    /// fully staged and only the quit never finished. Past the deadline the
    /// remaining children are abandoned to their 3s-grace SIGKILL paths;
    /// a bounded quit beats a perfect one.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        guard let model = MainActor.assumeIsolated({ AppModel.running() }) else {
            return .terminateNow
        }
        isTerminating = true
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await model.shutdown() }
                group.addTask { try? await Task.sleep(for: .seconds(8)) }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Right-click on the dock icon: jump straight to whichever agents need
    /// you. The dock badge says how many; this menu says which. (State is
    /// read inside the main-actor hop as plain strings; `NSMenu` itself isn't
    /// Sendable, so it is assembled out here on the calling main thread.)
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let entries: [(name: String, id: String)] = MainActor.assumeIsolated {
            guard let model = AppModel.running() else { return [] }
            return model.sortedWorkspaces.filter(\.needsAttention).prefix(9)
                .map { ($0.name, $0.id.rawValue) }
        }
        guard !entries.isEmpty else { return nil }

        let menu = NSMenu()
        for entry in entries {
            let item = NSMenuItem(
                title: "\(entry.name) — needs you",
                action: #selector(revealWorkspaceFromDock(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.id
            menu.addItem(item)
        }
        return menu
    }

    @objc private func revealWorkspaceFromDock(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        NotificationCenter.default.post(
            name: .oreOpenFromNotification,
            object: nil,
            userInfo: ["workspaceID": raw]
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Child agent processes are terminated by their sessions on shutdown;
        // this is the last chance to make sure that happened. Terminal shells
        // have no session to close them, so they are killed here rather than
        // left to be reparented when the app goes away.
        MainActor.assumeIsolated { TerminalRegistry.shared.closeAll() }
        NotificationCenter.default.post(name: .oreApplicationWillTerminate, object: nil)
    }
}

/// String constants shared between registration (here), posting (`AppModel`),
/// and handling (`AppModel` again).
enum NotificationCategory {
    static let assistantConfirmation = "ore.category.assistantConfirmation"
    static let agentQuestion = "ore.category.agentQuestion"
    static let toolPermission = "ore.category.toolPermission"
    static let dreams = "ore.category.dreams"
}

enum NotificationAction {
    static let allowTask = "ore.action.allowTask"
    static let allowOnce = "ore.action.allowOnce"
    static let deny = "ore.action.deny"
    static let reply = "ore.action.reply"
    static let allowPermission = "ore.action.allowPermission"
    static let denyPermission = "ore.action.denyPermission"
    static let openDreams = "ore.action.openDreams"
}

extension Notification.Name {
    static let oreApplicationWillTerminate = Notification.Name("ore.applicationWillTerminate")
    static let oreOpenFromNotification = Notification.Name("ore.openFromNotification")
    static let oreNotificationAction = Notification.Name("ore.notificationAction")
}
