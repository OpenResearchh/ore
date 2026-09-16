import Foundation
import Testing

@testable import OreMac

/// A store that will not open used to leave ORE fully usable on a throwaway
/// in-memory database: the sidebar filled, ⌘N made worktrees, and the whole
/// day went away on quit behind a raw error in one pane. The screen is SwiftUI,
/// but the two decisions behind it are not.
struct LaunchFailurePresentationTests {
    private struct Unreadable: LocalizedError {
        var errorDescription: String? { "database disk image is malformed" }
    }

    @Test func launchFailureMessageNamesTheStorePath() {
        let message = LaunchFailure.message(for: Unreadable(), storePath: "/tmp/ore/ore.sqlite")
        #expect(message.contains("/tmp/ore/ore.sqlite"))
        // The raw error is the only place the SQLite message survives, so it
        // has to reach the screen alongside the path.
        #expect(message.contains("database disk image is malformed"))
    }

    /// The default argument is what the app actually passes. Asserted by file
    /// name rather than by importing the persistence layer, which the app
    /// target deliberately does not put in front of the UI.
    @Test func theDefaultPathIsTheRealStoreLocation() {
        let message = LaunchFailure.message(for: Unreadable())
        #expect(message.contains("ore.sqlite"))
        #expect(message.contains("ORE's database lives at /"))
    }

    /// A workspace created now is a worktree on disk with no row anywhere to
    /// remember it by.
    @Test func newWorkspaceCommandsAreDisabledOnLaunchFailure() {
        #expect(!LaunchFailure.commandsEnabled(launchFailure: "boom"))
        #expect(LaunchFailure.commandsEnabled(launchFailure: nil))
    }
}
