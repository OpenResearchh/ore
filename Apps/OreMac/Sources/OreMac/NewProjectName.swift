import Foundation
import OreGit
import OrePersistence

/// A repository name for a project the user never named.
///
/// With nothing to work in, Start makes a project — which means something has
/// to name it, and asking would put back the exact field the composer exists
/// to remove. The instruction already says what the thing is, so the name
/// comes out of that: "build a pricing page for the marketing site" becomes
/// `pricing-page`.
///
/// Deliberately a few plain words rather than anything clever. This is a
/// directory on disk the user will see in Finder and in `cd`, so it has to be
/// short, lowercase, and free of anything a shell would argue with.
enum NewProjectName {
    static let maxWords = 4
    static let fallback = "new-project"

    /// The directory a project of this name will be created in when the
    /// caller does not say otherwise. Mirrors `InProcessCoreClient`.
    static var defaultRoot: URL {
        OreHome.directory.appendingPathComponent("repositories", isDirectory: true)
    }

    /// A name that will not land on a project ORE already has, or on a
    /// directory already sitting in the creation root.
    ///
    /// Comparison is on the *directory* each name becomes, not the name
    /// itself. The core slugs before it creates, so two goals that read
    /// differently — "定价页面" and "价格页面" both slug to the same fallback —
    /// can still want the same folder, and a folder somebody made by hand is
    /// a collision nobody registered with ORE.
    static func from(
        _ goal: String,
        avoiding existing: [String],
        root: URL? = nil
    ) -> String {
        let root = root ?? defaultRoot
        var taken = Set(existing.map { directoryKey(($0 as NSString).lastPathComponent) })
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            taken.insert(directoryKey(entry))
        }

        let base = slug(from: goal)
        guard taken.contains(directoryKey(base)) else { return base }
        // `pricing-page-2`, rather than silently writing into a directory that
        // is already somebody else's project.
        for suffix in 2...99 where !taken.contains(directoryKey("\(base)-\(suffix)")) {
            return "\(base)-\(suffix)"
        }
        // A hundred projects of the same name is not a real situation, but
        // returning `base` here would hand back a name known to be taken.
        // The core refuses a non-empty directory, so the user would get an
        // error instead of a project.
        return "\(base)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// What two names have to share to be the same folder: the core's own
    /// slugging, case-folded because the macOS default volume is.
    private static func directoryKey(_ name: String) -> String {
        RepositoryInitializer.directoryName(for: name).lowercased()
    }

    /// The first few meaningful words, lowercased and hyphenated.
    static func slug(from goal: String) -> String {
        let words = goal
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !leadIns.contains($0) && $0.count > 1 }
            .prefix(maxWords)
        let joined = words.joined(separator: "-")
        // The core's slugger keeps ASCII alphanumerics and nothing else, so a
        // goal written in Chinese, Cyrillic or Arabic survives it as the word
        // "workspace" — the same directory for every such project. Naming it
        // here instead means the numbering below can tell them apart.
        guard joined.contains(where: { $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return fallback }
        return joined
    }

    /// Words that start an instruction without describing it. "Build a pricing
    /// page" is a pricing page, not a build-a.
    private static let leadIns: Set<String> = [
        "a", "an", "the", "my", "our", "this", "that",
        "build", "make", "create", "start", "set", "up", "write", "add", "new",
        "please", "can", "you", "i", "want", "need", "to", "for", "me", "let",
        "and", "with", "using", "use", "on", "in", "of", "it", "is", "app",
        "project", "repo", "repository", "something", "some",
    ]
}
