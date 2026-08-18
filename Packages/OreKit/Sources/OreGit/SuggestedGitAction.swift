import Foundation
import OreProtocol

/// The one thing to do next to get this work merged.
///
/// This is the idea the changelog is clearest about: a developer shipping an
/// agent's work runs the same loop every time — commit, push, open a PR, fix
/// CI, merge — and at any moment exactly one of those is the next step. Making
/// the app compute which one turns a five-tool workflow into a button.
public enum SuggestedGitAction: Sendable, Hashable, Codable {
    /// Nothing changed yet.
    case none
    /// Committed work in a repo with no remote to push it to. This is a real
    /// state — there is a diff to see — not "no changes", which is the lie the
    /// `.none` label told when it stood in for this case.
    case committedNoRemote
    /// Committed work with no remote, but `gh` is ready — so the dead end
    /// becomes a button: create the GitHub repo and publish it, which hands the
    /// rest of the flow (push → PR → merge) back to the usual states.
    case createGitHubRepo
    case commit(fileCount: Int, insertions: Int, deletions: Int)
    case push(commitCount: Int, isFirstPush: Bool)
    case createPullRequest(base: String, isStacked: Bool)
    /// CI is running; nothing to do but wait.
    case waitForChecks(running: Int, total: Int)
    /// CI failed. The action is not "go look at CI" — it's "hand the failure
    /// to the agent that wrote the code".
    case fixFailingChecks(prNumber: Int, failing: [String])
    case resolveConflicts(prNumber: Int, base: String)
    case waitForReview(prNumber: Int)
    case merge(prNumber: Int, isStacked: Bool)
    /// Lower PRs in the stack must land first; merging out of order would
    /// bring their commits along with this one.
    case waitForParentToMerge(parentBranch: String, parentPRNumber: Int?)
    /// A parent merged, so this branch is now stacked on something that's gone.
    case retargetAfterParentMerged(prNumber: Int?, newBase: String)
    case merged(prNumber: Int)
    /// `gh` missing or signed out — say so instead of silently offering nothing.
    case setUpGitHub(reason: String)

    /// Button label.
    public var title: String {
        switch self {
        case .none: return "No changes"
        case .committedNoRemote: return "Committed locally"
        case .createGitHubRepo: return "Create GitHub repo"
        case .commit(let count, _, _): return "Commit \(count) file\(count == 1 ? "" : "s")"
        case .push(let count, let isFirst):
            return isFirst ? "Publish branch" : "Push \(count) commit\(count == 1 ? "" : "s")"
        case .createPullRequest(let base, let isStacked):
            return isStacked ? "Create PR onto \(base)" : "Create pull request"
        case .waitForChecks(let running, let total): return "Checks running (\(running)/\(total))"
        case .fixFailingChecks: return "Send failing checks to agent"
        case .resolveConflicts: return "Resolve conflicts with agent"
        case .waitForReview: return "Waiting for review"
        case .merge(_, let isStacked): return isStacked ? "Merge (bottom of stack)" : "Merge"
        case .waitForParentToMerge(let branch, _): return "Waiting on \(branch)"
        case .retargetAfterParentMerged(_, let base): return "Retarget onto \(base)"
        case .merged: return "Merged"
        case .setUpGitHub: return "Set up GitHub"
        }
    }

    /// Whether the action does something, or is just reporting a state.
    public var isActionable: Bool {
        switch self {
        case .none, .committedNoRemote, .waitForChecks, .waitForReview,
             .waitForParentToMerge, .merged:
            return false
        default:
            return true
        }
    }

    /// True when the action needs the agent rather than the user — those get
    /// routed into the chat instead of run directly.
    public var delegatesToAgent: Bool {
        switch self {
        case .commit, .createPullRequest, .fixFailingChecks, .resolveConflicts:
            return true
        default:
            return false
        }
    }

    /// Prompt dropped into the composer when the user clicks Commit or Create PR.
    /// Nil for actions that still run git/`gh` directly.
    public var agentDraftPrompt: String? {
        switch self {
        case .commit(let count, let insertions, let deletions):
            return GitShipPrompt.commit(
                fileCount: count, insertions: insertions, deletions: deletions
            )
        case .createPullRequest(let base, let isStacked):
            return GitShipPrompt.pullRequest(base: base, isStacked: isStacked)
        default:
            return nil
        }
    }
}

/// Composer text for shipping actions that the agent should carry out with its
/// own tools — inspect the diff, write the message, then run git/`gh`.
public enum GitShipPrompt: Sendable {
    public static func commit(fileCount: Int? = nil, insertions: Int = 0, deletions: Int = 0) -> String {
        var lines = [
            "Inspect the working tree (staged and unstaged) and recent `git log` style, then write a commit message that matches this repo — why the change exists, not a file list.",
        ]
        if let fileCount {
            let files = "\(fileCount) file\(fileCount == 1 ? "" : "s")"
            lines.append(
                "There are currently \(files) changed (+\(insertions)/−\(deletions)). Stage what belongs in this commit; leave unrelated WIP unstaged."
            )
        } else {
            lines.append("Stage what belongs in this commit; leave unrelated WIP unstaged.")
        }
        lines.append("Then commit. Do not push.")
        return lines.joined(separator: "\n\n")
    }

    public static func pullRequest(base: String, isStacked: Bool) -> String {
        var lines = [
            "Inspect the commits and the full diff against `\(base)`. Write a pull-request title and body in this repo's style: a short title, a summary of what changed and why, and a test plan.",
            "Then create the PR onto `\(base)` with `gh pr create`. Do not merge it.",
        ]
        if isStacked {
            lines.append(
                "This branch is stacked; open the PR onto `\(base)` (the parent), not the repository's default branch."
            )
        }
        return lines.joined(separator: "\n\n")
    }

    public static func rebaseOnto(_ base: String) -> String {
        """
        Rebase this branch onto `\(base)` (the repository default). Resolve any \
        conflicts, keep our work, and explain the resolution. Do not force-push \
        unless this branch has no open pull request.
        """
    }
}

/// Everything the state machine needs to decide. Gathering it is I/O; deciding
/// is not, which is why they're separate — the decision is a pure function and
/// is tested as one.
public struct GitActionContext: Sendable {
    public var hasUncommittedChanges: Bool
    public var changedFileCount: Int
    public var insertions: Int
    public var deletions: Int
    /// Commits on this branch that aren't on its upstream.
    public var unpushedCommitCount: Int
    /// Commits this branch has that its base doesn't. Zero means there is
    /// nothing to open a pull request *from* — a workspace that was created
    /// and never worked in looks identical to a fully pushed one otherwise.
    public var commitsAheadOfBase: Int
    public var hasUpstream: Bool
    public var hasRemote: Bool
    public var baseBranch: String
    public var pullRequest: GitHubClient.PullRequest?
    public var gitHubStatus: GitHubClient.Status
    /// Set when this workspace is stacked on another.
    public var parentBranch: String?
    public var parentPullRequest: GitHubClient.PullRequest?
    /// Local merge-tree against origin's default, independent of GitHub's
    /// `mergeable` which can stay UNKNOWN for a long time after master moves.
    public var wouldConflictWithOriginDefault: Bool

    public init(
        hasUncommittedChanges: Bool = false,
        changedFileCount: Int = 0,
        insertions: Int = 0,
        deletions: Int = 0,
        unpushedCommitCount: Int = 0,
        commitsAheadOfBase: Int = 0,
        hasUpstream: Bool = false,
        hasRemote: Bool = true,
        baseBranch: String = "main",
        pullRequest: GitHubClient.PullRequest? = nil,
        gitHubStatus: GitHubClient.Status = GitHubClient.Status(
            isInstalled: true, isAuthenticated: true
        ),
        parentBranch: String? = nil,
        parentPullRequest: GitHubClient.PullRequest? = nil,
        wouldConflictWithOriginDefault: Bool = false
    ) {
        self.hasUncommittedChanges = hasUncommittedChanges
        self.changedFileCount = changedFileCount
        self.insertions = insertions
        self.deletions = deletions
        self.unpushedCommitCount = unpushedCommitCount
        self.commitsAheadOfBase = commitsAheadOfBase
        self.hasUpstream = hasUpstream
        self.hasRemote = hasRemote
        self.baseBranch = baseBranch
        self.pullRequest = pullRequest
        self.gitHubStatus = gitHubStatus
        self.parentBranch = parentBranch
        self.parentPullRequest = parentPullRequest
        self.wouldConflictWithOriginDefault = wouldConflictWithOriginDefault
    }
}

public enum SuggestedGitActionResolver {
    /// Picks the next step.
    ///
    /// Order matters and encodes the workflow: local work before remote work,
    /// blockers before conveniences, and — for a stack — the parent's state
    /// before this branch's own, because merging a child first quietly drags
    /// the parent's commits in with it.
    public static func resolve(_ context: GitActionContext) -> SuggestedGitAction {
        if let pullRequest = context.pullRequest, pullRequest.isMerged {
            return .merged(prNumber: pullRequest.number)
        }

        // A stack whose parent already merged leaves this PR pointing at a
        // deleted branch; retargeting is the only thing that unblocks it.
        if let parent = context.parentPullRequest, parent.isMerged,
           context.parentBranch != nil,
           let pullRequest = context.pullRequest, pullRequest.baseRefName != context.baseBranch {
            return .retargetAfterParentMerged(
                prNumber: pullRequest.number,
                newBase: context.baseBranch
            )
        }

        if context.hasUncommittedChanges {
            return .commit(
                fileCount: context.changedFileCount,
                insertions: context.insertions,
                deletions: context.deletions
            )
        }

        if !context.hasRemote {
            guard context.commitsAheadOfBase > 0 else { return .none }
            // With `gh` ready, "committed but nowhere to push" is no longer a
            // dead end — offer to create the repo. Without it, there's nothing
            // to click, so report the state honestly.
            if context.gitHubStatus.isInstalled, context.gitHubStatus.isAuthenticated {
                return .createGitHubRepo
            }
            return .committedNoRemote
        }

        if !context.gitHubStatus.isInstalled || !context.gitHubStatus.isAuthenticated {
            // Push still works without `gh`; only the PR half needs it. Don't
            // offer to publish a branch that has nothing on it yet — an unpushed
            // branch with zero commits ahead of base is nothing to publish.
            if context.unpushedCommitCount > 0
                || (!context.hasUpstream && context.commitsAheadOfBase > 0) {
                return .push(
                    commitCount: context.unpushedCommitCount,
                    isFirstPush: !context.hasUpstream
                )
            }
            return .setUpGitHub(
                reason: context.gitHubStatus.diagnostic ?? "GitHub is not set up."
            )
        }

        // No PR yet: opening one publishes the branch in the same step (the core
        // pushes `-u` before `gh pr create`), so the flow never stops at a
        // separate "Publish branch" button first — that was the extra click. A
        // branch with no commits ahead of base has nothing to open a PR from.
        guard let pullRequest = context.pullRequest, pullRequest.isOpen else {
            guard context.commitsAheadOfBase > 0 else { return .none }
            return .createPullRequest(
                base: context.parentBranch ?? context.baseBranch,
                isStacked: context.parentBranch != nil
            )
        }

        // A PR is already open: new local commits update it, so push them before
        // reading the PR's checks and review state.
        if context.unpushedCommitCount > 0 {
            return .push(commitCount: context.unpushedCommitCount, isFirstPush: false)
        }

        if pullRequest.hasConflicts || context.wouldConflictWithOriginDefault {
            return .resolveConflicts(
                prNumber: pullRequest.number,
                base: pullRequest.baseRefName
            )
        }

        let failing = pullRequest.failingChecks
        if !failing.isEmpty {
            return .fixFailingChecks(
                prNumber: pullRequest.number,
                failing: failing.map(\.name)
            )
        }

        if pullRequest.hasRunningChecks {
            let running = pullRequest.checks.filter { !$0.isComplete }.count
            return .waitForChecks(running: running, total: pullRequest.checks.count)
        }

        if pullRequest.reviewDecision == "CHANGES_REQUESTED" {
            return .waitForReview(prNumber: pullRequest.number)
        }

        // Green and ready — but only if nothing below it in the stack is
        // still open.
        if let parentBranch = context.parentBranch {
            let parentIsMerged = context.parentPullRequest?.isMerged ?? false
            if !parentIsMerged {
                return .waitForParentToMerge(
                    parentBranch: parentBranch,
                    parentPRNumber: context.parentPullRequest?.number
                )
            }
        }

        return .merge(
            prNumber: pullRequest.number,
            isStacked: context.parentBranch != nil
        )
    }
}
