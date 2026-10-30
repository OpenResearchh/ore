import Foundation

/// Where ORE keeps its own state.
///
/// `ORE_HOME` overrides it, which is what makes it possible to run a second
/// instance against a scratch directory — for development, and so a test run
/// can never touch the state a real session depends on.
///
/// Lives in OreSupport rather than OrePersistence so git worktree layout and
/// the database agree on one home without a persistence dependency.
public enum OreHome {
    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["ORE_HOME"], !override.isEmpty {
            return FilePath.expandingTildeURL(override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ore", isDirectory: true)
    }

    public static var worktreeRoot: URL {
        directory.appendingPathComponent("workspaces", isDirectory: true)
    }

    public static var repositories: URL {
        directory.appendingPathComponent("repositories", isDirectory: true)
    }

    /// Shown in Settings: `~/ore` rather than an expanded home, so a screenshot
    /// of the pane does not leak an account name. `$ORE_HOME` is shown as given.
    public static var displayPath: String {
        if let override = ProcessInfo.processInfo.environment["ORE_HOME"], !override.isEmpty {
            return override
        }
        return "~/ore"
    }
}
