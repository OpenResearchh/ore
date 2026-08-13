import Foundation

/// Path helpers that work on every platform ORE targets.
///
/// The obvious spellings — `(path as NSString).expandingTildeInPath`,
/// `.lastPathComponent` — rely on Objective-C bridging, which does not exist
/// outside Apple platforms. Using them is how a headless core that is supposed
/// to compile on Linux quietly stops doing so, and the failure shows up as a
/// wall of bridging errors rather than as anything that names the cause.
public enum FilePath {
    /// Expands a leading `~` against the current user's home directory.
    public static func expandingTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" { return home }
        return home + String(path.dropFirst(1))
    }

    public static func expandingTildeURL(_ path: String) -> URL {
        URL(fileURLWithPath: expandingTilde(path))
    }

    /// The last path component, without bridging.
    public static func lastComponent(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// The path minus its last component.
    public static func parent(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    public static func pathExtension(_ path: String) -> String {
        URL(fileURLWithPath: path).pathExtension
    }
}
