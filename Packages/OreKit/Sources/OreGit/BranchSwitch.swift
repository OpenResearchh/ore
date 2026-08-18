import Foundation

/// Moving a worktree onto a new branch without abandoning the work in it.
///
/// Git already carries uncommitted edits across a `switch` on its own — right
/// up until the two branches disagree about a file the user has touched, where
/// it refuses rather than clobber. That cliff is the problem: it turns a
/// routine action into an error the user has to understand and unpick.
/// Stashing first removes it. The switch always sees a clean tree, and the work
/// is replayed on the far side.
public struct BranchSwitch: Sendable {
    public enum Failure: Error, Sendable, CustomStringConvertible {
        /// The carried work overlapped what the new base changed. Git applied
        /// what it could and left markers; the stash entry survives, so the
        /// original is still recoverable in full.
        case carriedWorkConflicted(base: String)

        public var description: String {
            switch self {
            case .carriedWorkConflicted(let base):
                return """
                Your uncommitted changes clash with the updated \(base). They were \
                carried over with conflict markers and kept in `git stash` — resolve \
                them, then drop the stash entry.
                """
            }
        }
    }

    private let git: GitClient
    private let worktree: URL

    public init(git: GitClient, worktree: URL) {
        self.git = git
        self.worktree = worktree
    }

    /// Creates `branch` from `base` in this worktree, bringing any uncommitted
    /// work along. Reports whether there was in fact work to carry.
    @discardableResult
    public func create(_ branch: String, from base: String) async throws -> Bool {
        let carried = try await stash(labelledFor: branch)
        do {
            try await git.runSerialized(["switch", "-c", branch, base], in: worktree)
        } catch {
            // The switch failed, so the branch this work belongs to is still
            // the one we're on. Put it back before surfacing the error — nobody
            // should have to learn about a stash to recover from a no-op.
            if carried { try? await git.runSerialized(["stash", "pop"], in: worktree) }
            throw error
        }
        guard carried else { return false }

        do {
            try await git.runSerialized(["stash", "pop"], in: worktree)
        } catch {
            throw Failure.carriedWorkConflicted(base: base)
        }
        return true
    }

    /// Stashes the worktree, reporting whether an entry was actually created.
    ///
    /// The return value is the whole point. `git stash push` is silent when it
    /// finds nothing to stash, so an unconditional `pop` afterwards would
    /// restore some unrelated older entry — someone else's work, arriving out
    /// of nowhere. Only the stash ref moving proves the entry is ours.
    ///
    /// `--include-untracked` because a new file is work too, and leaving it
    /// behind would be the same silent loss by a different route.
    private func stash(labelledFor branch: String) async throws -> Bool {
        let before = await stashRef()
        try await git.runSerialized(
            ["stash", "push", "--include-untracked", "--message", "ore: carried onto \(branch)"],
            in: worktree
        )
        let after = await stashRef()
        return after != nil && after != before
    }

    /// The current tip of the stash stack, or nil when nothing is stashed.
    private func stashRef() async -> String? {
        let output = try? await git.run(
            ["rev-parse", "--verify", "--quiet", "refs/stash"], in: worktree
        )
        let sha = output?.trimmedStandardOutput ?? ""
        return sha.isEmpty ? nil : sha
    }
}
