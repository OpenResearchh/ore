import Sparkle
import SwiftUI

/// In-app updates.
///
/// ORE drives CLIs whose protocols change weekly, so the gap between "we fixed
/// the harness" and "the user has the fix" is the difference between a working
/// app and a broken one. Shipping without an updater would mean every protocol
/// break waits for someone to notice a new release exists.
///
/// Sparkle checks a signed appcast and verifies an EdDSA signature over the
/// archive, so an update is only applied if it came from whoever holds the
/// private key — a compromised download host isn't enough to ship code.
@MainActor
@Observable
final class Updater {
    private let controller: SPUStandardUpdaterController

    /// Bound to the Check for Updates menu item so it disables while a check
    /// is already running.
    private(set) var canCheckForUpdates = false

    private var observation: NSKeyValueObservation?

    init() {
        // `startingUpdater: true` begins the scheduled background check. The
        // user is asked before the first automatic check, which is Sparkle's
        // default and the right one — silently phoning home on first launch is
        // not something to opt a user into.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        observation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Whether the build is actually configured to update.
    ///
    /// A development build has no appcast URL and no public key; saying so is
    /// better than a menu item that fails with a network error.
    var isConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }
}

/// The Check for Updates menu item.
struct CheckForUpdatesCommand: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates || !updater.isConfigured)
        .help(updater.isConfigured
            ? "Check whether a newer version of ORE is available"
            : "This build isn't configured for updates")
    }
}
