import AppKit
import Testing
@testable import OreMac

struct QuitConfirmationTests {
    private func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: 12
        )
    }

    @Test func onlyTheKeystrokeAsks() {
        #expect(QuitConfirmation.isCommandQ(key("q", .command)))
        // Caps Lock or Shift must not slip an accidental quit past the prompt.
        #expect(QuitConfirmation.isCommandQ(key("Q", [.command, .shift])))
        #expect(!QuitConfirmation.isCommandQ(key("q", [])))
        #expect(!QuitConfirmation.isCommandQ(key("w", .command)))
        // The menu bar's Quit, the updater and a logout carry no key event.
        #expect(!QuitConfirmation.isCommandQ(nil))
    }

    @Test func theMessageSaysWhatStops() {
        #expect(QuitConfirmation.message(busyAgents: 1) == "1 agent is working and will stop.")
        #expect(QuitConfirmation.message(busyAgents: 3) == "3 agents are working and will stop.")
        #expect(QuitConfirmation.message(busyAgents: 0).contains("Agents stop"))
    }
}

@MainActor
struct ProjectDeleteMessageTests {
    @Test func theDialogCountsWhatGoes() {
        let one = AppModel.PendingProjectDelete(repositoryPath: "/r/LACE", workspaceCount: 1)
        #expect(one.name == "LACE")
        #expect(one.confirmationMessage.hasPrefix("This stops its workspace"))
        let many = AppModel.PendingProjectDelete(repositoryPath: "/r/LACE", workspaceCount: 4)
        #expect(many.confirmationMessage.contains("all 4 of its workspaces"))
        // The reassurance that makes the destructive button safe to press.
        #expect(many.confirmationMessage.contains("Trash"))
    }
}
