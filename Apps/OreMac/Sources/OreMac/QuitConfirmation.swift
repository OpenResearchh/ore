import AppKit

/// Asks before ⌘Q quits.
///
/// ⌘Q sits one key from ⌘W and ⌘1, and quitting stops every agent mid-turn.
/// Only the keystroke asks: the menu bar's Quit is a deliberate click, and the
/// updater's relaunch and a logout are not the user's hand at all — a dialog
/// in their way would stall a restart nobody is watching.
enum QuitConfirmation {
    static let suppressedKey = "ore.quit.dontAsk"

    /// Whether the quit in flight came from the ⌘Q keystroke.
    static func isCommandQ(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers.contains(.command)
            && event.charactersIgnoringModifiers?.lowercased() == "q"
    }

    static func message(busyAgents: Int) -> String {
        switch busyAgents {
        case 0:
            "Agents stop and the assistant stops listening until you open ORE again."
        case 1:
            "1 agent is working and will stop."
        default:
            "\(busyAgents) agents are working and will stop."
        }
    }

    /// Shows the alert and returns whether to go ahead with the quit.
    @MainActor
    static func confirm(busyAgents: Int, defaults: UserDefaults = .standard) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit ORE?"
        alert.informativeText = message(busyAgents: busyAgents)
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don\u{2019}t ask again"
        NSApp.activate(ignoringOtherApps: true)
        let quit = alert.runModal() == .alertFirstButtonReturn
        if quit, alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: suppressedKey)
        }
        return quit
    }
}
