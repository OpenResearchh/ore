import AppKit
import Foundation

/// The System Settings panes ORE has to send people to.
///
/// macOS grants these permissions exactly once. After that the API is silent:
/// `AVAudioApplication.requestRecordPermission()` returns false immediately
/// and `AXIsProcessTrustedWithOptions` will not show its prompt a second time.
/// So an app that only ever *asks* has nothing to offer somebody who said no —
/// and a user who clicked "Don't Allow" once, months ago, has no way to
/// connect a feature that silently does nothing to a decision they have
/// forgotten making.
///
/// Before this the repository contained no `x-apple.systempreferences` URL at
/// all: every denied permission was a dead end.
///
/// The `Privacy_*` anchors are a documented, long-stable URL scheme, but they
/// are still a scheme rather than API — `open` simply fails on an unknown
/// anchor, so `open(_:)` reports whether it worked and callers fall back to
/// telling the user where to go by name.
enum SystemSettingsLink: String, CaseIterable {
    case microphone = "Privacy_Microphone"
    case speechRecognition = "Privacy_SpeechRecognition"
    case accessibility = "Privacy_Accessibility"
    case filesAndFolders = "Privacy_FilesAndFolders"
    case notifications = "Privacy_Notifications"

    /// Where to tell the user to go when the deep link does not open, and what
    /// to label a button with.
    var paneName: String {
        switch self {
        case .microphone: "Privacy & Security ▸ Microphone"
        case .speechRecognition: "Privacy & Security ▸ Speech Recognition"
        case .accessibility: "Privacy & Security ▸ Accessibility"
        case .filesAndFolders: "Privacy & Security ▸ Files and Folders"
        case .notifications: "Notifications"
        }
    }

    var url: URL? {
        // Notifications lives under its own pane, not the privacy one.
        let base = self == .notifications
            ? "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
            : "x-apple.systempreferences:com.apple.preference.security?\(rawValue)"
        return URL(string: base)
    }

    /// Opens the pane. Returns false when macOS would not take the URL, so the
    /// caller can leave the pane name on screen instead of appearing to do
    /// nothing.
    @discardableResult
    static func open(_ link: SystemSettingsLink) -> Bool {
        guard let url = link.url else { return false }
        return NSWorkspace.shared.open(url)
    }
}
