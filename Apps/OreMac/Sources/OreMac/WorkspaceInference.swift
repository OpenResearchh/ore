import Foundation

/// Which repository the user meant, and how sure ORE is about it.
///
/// The old sheet asked, every time, from a flat unsorted list with the first
/// entry pre-selected — a question whose answer was usually obvious and
/// occasionally wrong in a way nobody noticed until the worktree appeared in
/// the wrong project. This works it out instead, and only falls back to asking
/// when it genuinely cannot tell.
///
/// Infer → verify → ask, in that order. The confidence is not decoration: it
/// decides whether the composer starts on a Start button or on a repository
/// picker.
enum WorkspaceInference {
    struct Choice: Equatable {
        /// Absolute path of the repository.
        var path: String
        var confidence: Confidence
        /// Why, in the user's terms — shown under the composer so the guess is
        /// always visible and always correctable.
        var reason: String
        /// A project the user named that ORE has no match for. Set means
        /// `path` is a fallback nobody asked for: the caller must not start
        /// work in it without the user choosing.
        var unmatchedName: String?

        /// Whether work may begin without the user settling the project
        /// first. The one question this whole type exists to answer.
        var isSettled: Bool { confidence != .ambiguous && unmatchedName == nil }
    }

    enum Confidence: Equatable {
        /// The user named it, or there is only one thing it could be.
        case certain
        /// A good guess from context or recency. Shown, and trivially
        /// changed, but not worth stopping for.
        case likely
        /// Two or more equally plausible answers. Ask.
        case ambiguous
    }

    /// Everything known at the moment the user presses Start.
    struct Context {
        /// Every repository ORE knows about.
        var repositories: [String]
        /// Repository paths in most-recently-worked order.
        var recents: [String]
        /// The repository of the workspace on screen, if the user is already
        /// inside one. The strongest signal there is: people ask for work in
        /// the project they are looking at.
        var current: String?

        init(repositories: [String], recents: [String] = [], current: String? = nil) {
            self.repositories = repositories
            self.recents = recents
            self.current = current
        }
    }

    /// The repository to use, or `nil` when ORE knows of none at all and the
    /// user has to add one first.
    static func repository(for intent: WorkspaceIntent, in context: Context) -> Choice? {
        guard !context.repositories.isEmpty else { return nil }

        // 1. The user said which one. Nothing beats being told.
        if let hint = intent.repositoryHint {
            let named = context.repositories.filter { matches(hint, path: $0) }
            if named.count == 1 {
                return Choice(
                    path: named[0],
                    confidence: .certain,
                    reason: "You said \(name(of: named[0]))"
                )
            }
            if named.count > 1 {
                // Two folders with the same name in different parents. ORE
                // picks the likeliest to show, but the user has to confirm:
                // starting in the wrong one branches the wrong repository.
                return Choice(
                    path: preferred(among: named, in: context),
                    confidence: .ambiguous,
                    reason: "More than one project matches “\(hint)”",
                    unmatchedName: nil
                )
            }
            // Named something ORE has never heard of. Everything below is a
            // fallback the user did not ask for, so it is shown as a
            // suggestion and never started without them choosing it — which
            // is the difference between "I'll use this instead" and creating
            // a worktree in a repository nobody mentioned.
            var fallback = bestGuess(for: intent, in: context)
            fallback.confidence = .ambiguous
            fallback.unmatchedName = hint
            fallback.reason = "No project called “\(hint)” — pick one"
            return fallback
        }

        return bestGuess(for: intent, in: context)
    }

    /// The signals other than being told, in order of strength.
    private static func bestGuess(
        for intent: WorkspaceIntent,
        in context: Context
    ) -> Choice {
        // 2. Only one repository exists. There is nothing to be unsure about.
        if context.repositories.count == 1 {
            return Choice(
                path: context.repositories[0],
                confidence: .certain,
                reason: name(of: context.repositories[0])
            )
        }

        // 3. The project the user is already looking at.
        if let current = context.current, context.repositories.contains(current) {
            return Choice(
                path: current,
                confidence: intent.repositoryHint == nil ? .certain : .likely,
                reason: "The project you're in"
            )
        }

        // 4. Whatever they worked in last.
        if let recent = context.recents.first(where: { context.repositories.contains($0) }) {
            return Choice(
                path: recent,
                confidence: intent.repositoryHint == nil ? .likely : .ambiguous,
                reason: "Your most recent project"
            )
        }

        // 5. Nothing to go on.
        return Choice(
            path: context.repositories[0],
            confidence: .ambiguous,
            reason: "Pick a project"
        )
    }

    /// Whether a spoken name refers to this repository.
    ///
    /// Matched on the folder name and on the `owner/name` tail, so both "ore"
    /// and "openresearchh/ore" find `~/code/ore`. Deliberately not a fuzzy
    /// match: quietly resolving "web" to `website-legacy` is worse than asking.
    static func matches(_ hint: String, path: String) -> Bool {
        let needle = hint.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return false }
        let folder = name(of: path).lowercased()
        if folder == needle { return true }
        // "openresearchh/ore" against `.../openresearchh/ore`.
        if needle.contains("/") {
            return path.lowercased().hasSuffix(needle)
        }
        return false
    }

    /// The best of several equally-named candidates: what the user is in,
    /// then what they touched last.
    private static func preferred(among matches: [String], in context: Context) -> String {
        if let current = context.current, matches.contains(current) { return current }
        if let recent = context.recents.first(where: matches.contains) { return recent }
        return matches[0]
    }

    static func name(of path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
