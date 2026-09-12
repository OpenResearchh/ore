import AppKit
import Foundation

/// Handing the current worktree to something outside ORE.
///
/// A worktree is a real directory on disk, and the fastest way to answer
/// "what actually changed here" is sometimes Finder or a full editor. ORE
/// should make that a single click rather than something the user
/// reconstructs by copying a path out of the UI.
enum ExternalTools {
    // MARK: - Finder

    static func revealInFinder(_ path: String) {
        // `open` rather than `selectFile`: the target is the worktree root
        // itself, and selecting a directory highlights it in its *parent*
        // window, which is not what "open my project folder" means.
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - Terminal

    /// Opens a standalone Terminal window already in the worktree.
    ///
    /// ORE has its own terminal pane, and this is deliberately not that: the
    /// pane dies with the tab and lives inside ORE's layout, while some work —
    /// a long build, an interactive rebase, anything the user wants beside
    /// another app — wants a real window that outlives the workspace being
    /// closed.
    static func openInTerminal(_ path: String) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: terminal,
            configuration: configuration
        )
    }

    // MARK: - The path itself

    /// Copies a path to the clipboard.
    ///
    /// The plainest possible escape hatch: whatever ORE has not thought to
    /// offer a button for, the user can still do by pasting the path into
    /// their own tool.
    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    // MARK: - Cursor

    /// Where Cursor is installed, or nil if it isn't.
    ///
    /// Deliberately not a bare bundle-identifier lookup. Cursor ships through
    /// ToDesktop, so its identifier is a generated string
    /// (`com.todesktop.230313mzl4w4u92`) rather than anything stable or
    /// guessable — it has changed across releases, and hard-coding it alone
    /// means the button silently disappears after a Cursor update. The
    /// identifier is tried first because it survives the app being renamed or
    /// installed somewhere unusual, then we fall back to looking for the app
    /// by name in the standard locations.
    /// Answered from a cache that remembers "not installed" too.
    ///
    /// This is read from a view body that redraws on every streamed token,
    /// and the lookup is not cheap: a LaunchServices query plus two `stat`s.
    /// Caching only successes was worse than useless, because the expensive
    /// answer is the negative one — on a Mac without Cursor, which is most of
    /// them, the whole thing ran again for every delta. `refresh()` on app
    /// activation is what keeps installing or removing Cursor visible without
    /// paying for the question continuously.
    static var cursorApplicationURL: URL? {
        if let cached = cachedCursorURL { return cached.url }
        let found = locateCursor()
        cachedCursorURL = Discovery(url: found)
        return found
    }

    static var isCursorInstalled: Bool { cursorApplicationURL != nil }

    /// Forgets what was discovered, so the next read looks again. Called when
    /// ORE becomes active: installing or removing an app happens elsewhere,
    /// and coming back to ORE is the moment to notice.
    static func refreshDiscoveredApps() {
        cachedCursorURL = nil
    }

    /// A recorded answer, including "there is none" — which `URL?` alone
    /// could not express.
    private struct Discovery {
        let url: URL?
    }

    private nonisolated(unsafe) static var cachedCursorURL: Discovery?

    private static func locateCursor() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.todesktop.230313mzl4w4u92"
        ) {
            return url
        }
        let candidates = [
            "/Applications/Cursor.app",
            NSHomeDirectory() + "/Applications/Cursor.app",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Opens a directory as a project in Cursor.
    static func openInCursor(_ path: String) {
        guard let application = cursorApplicationURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: application,
            configuration: configuration
        )
    }
}
