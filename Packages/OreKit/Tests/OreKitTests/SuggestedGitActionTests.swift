import Foundation
import Testing

@testable import OreGit
@testable import OreProtocol

/// The action resolver decides what the app's most prominent button does, so
/// its ordering is behaviour, not an implementation detail.
struct SuggestedGitActionTests {
    private func check(_ name: String, _ state: String) -> GitHubClient.CheckRun {
        GitHubClient.CheckRun(name: name, state: state)
    }

    private func openPR(
        number: Int = 7,
        base: String = "main",
        mergeable: String? = "MERGEABLE",
        reviewDecision: String? = nil,
        checks: [GitHubClient.CheckRun] = []
    ) -> GitHubClient.PullRequest {
        GitHubClient.PullRequest(
            number: number,
            state: "OPEN",
            baseRefName: base,
            mergeable: mergeable,
            reviewDecision: reviewDecision,
            checks: checks
        )
    }

    @Test func aWorkspaceWithNoWorkInItOffersNothing() {
        // A workspace created but never worked in has an upstream and no
        // commits. Offering "Create pull request" here would fail on click.
        let action = SuggestedGitActionResolver.resolve(GitActionContext(
            commitsAheadOfBase: 0, hasUpstream: true
        ))
        #expect(action == .none)
        #expect(!action.isActionable)
    }

    @Test func uncommittedChangesComeBeforeEverythingElse() {
        // Even with a green PR open, unsaved work is the next step.
        let action = SuggestedGitActionResolver.resolve(GitActionContext(
            hasUncommittedChanges: true,
            changedFileCount: 3,
            insertions: 42,
            deletions: 8,
            hasUpstream: true,
            pullRequest: openPR(checks: [check("build", "SUCCESS")])
        ))
        #expect(action == .commit(fileCount: 3, insertions: 42, deletions: 8))
        #expect(action.title == "Commit 3 files")
    }

    @Test func anUnpublishedBranchGoesStraightToCreatePR() {
        // Publishing is folded into "Create pull request" (the core pushes `-u`
        // before `gh pr create`), so an unpushed branch with work no longer stops
        // at a separate "Publish branch" button first.
        let action = SuggestedGitActionResolver.resolve(GitActionContext(
            commitsAheadOfBase: 2, hasUpstream: false, baseBranch: "main"
        ))
        #expect(action == .createPullRequest(base: "main", isStacked: false))
    }

    @Test func pushedWorkWithNoPullRequestOffersToOpenOne() {
        let action = SuggestedGitActionResolver.resolve(GitActionContext(
            commitsAheadOfBase: 2, hasUpstream: true, baseBranch: "main"
        ))
        #expect(action == .createPullRequest(base: "main", isStacked: false))
    }

    @Test func newCommitsOnAnOpenPullRequestArePushedToUpdateIt() {
        // Once a PR exists, local commits that aren't on the remote yet update it
        // — that's the one place a bare push still surfaces in the ready flow.
        let action = SuggestedGitActionResolver.resolve(GitActionContext(
            unpushedCommitCount: 3,
            commitsAheadOfBase: 5,
            hasUpstream: true,
            pullRequest: openPR(checks: [check("build", "SUCCESS")])
        ))
        #expect(action == .push(commitCount: 3, isFirstPush: false))
        #expect(action.title == "Push 3 commits")
    }

    @Test func failingChecksGoToTheAgentRatherThanToTheBrowser() {
        // The point of the feature: the developer shouldn't have to find the
        // failing job and paste the error back themselves.
        let action = SuggestedGitActionResolver.resolve(GitActionContext(
            hasUpstream: true,
            pullRequest: openPR(checks: [
                check("build", "SUCCESS"),
                check("test", "FAILURE"),
                check("lint", "SUCCESS"),
            ])
        ))
        #expect(action == .fixFailingChecks(prNumber: 7, failing: ["test"]))
        #expect(action.delegatesToAgent)
    }

    @Test func conflictsOutrankFailingChecks() {
        // A conflicted PR can't merge no matter what CI says, and asking the
        // agent to chase a test failure first wastes a turn.
        let action = SuggestedGitActionResolver.resolve(GitActionContext(
            hasUpstream: true,
            pullRequest: openPR(
                mergeable: "CONFLICTING",
                checks: [check("test", "FAILURE")]
            )
        ))
        #expect(action == .resolveConflicts(prNumber: 7, base: "main"))
        #expect(action.delegatesToAgent)
    }

    @Test func runningChecksAreReportedButNotActionable() {
        let action = SuggestedGitActionResolver.resolve(GitActionContext(
            hasUpstream: true,
            pullRequest: openPR(checks: [
                check("build", "SUCCESS"),
                check("test", "IN_PROGRESS"),
            ])
        ))
        #expect(action == .waitForChecks(running: 1, total: 2))
        #expect(!action.isActionable)
    }

    @Test func unknownMergeabilityIsNotTreatedAsAConflict() {
        // GitHub reports UNKNOWN while it's still computing; showing "resolve
        // conflicts" then would be a false alarm on every fresh PR.
        let action = SuggestedGitActionResolver.resolve(GitActionContext(
            hasUpstream: true,
            pullRequest: openPR(mergeable: "UNKNOWN", checks: [check("build", "SUCCESS")])
        ))
        #expect(action == .merge(prNumber: 7, isStacked: false))
    }

    @Test func changesRequestedBlocksTheMergeButton() {
        let action = SuggestedGitActionResolver.resolve(GitActionContext(
            hasUpstream: true,
            pullRequest: openPR(
                reviewDecision: "CHANGES_REQUESTED",
                checks: [check("build", "SUCCESS")]
            )
        ))
        #expect(action == .waitForReview(prNumber: 7))
    }

    @Test func aGreenPullRequestOffersMerge() {
        let action = SuggestedGitActionResolver.resolve(GitActionContext(
            hasUpstream: true,
            pullRequest: openPR(reviewDecision: "APPROVED", checks: [check("build", "SUCCESS")])
        ))
        #expect(action == .merge(prNumber: 7, isStacked: false))
        #expect(action.isActionable)
    }

    // MARK: - Stacks

    @Test func aStackedPullRequestTargetsItsParentBranch() {
        let action = SuggestedGitActionResolver.resolve(GitActionContext(
            commitsAheadOfBase: 1,
            hasUpstream: true,
            baseBranch: "main",
            parentBranch: "ore/lower-half"
        ))
        #expect(action == .createPullRequest(base: "ore/lower-half", isStacked: true))
    }

    @Test func mergingIsWithheldUntilTheRestOfTheStackHasLanded() {
        // Merging a child first drags the parent's commits in with it, which
        // is exactly the mess stacks exist to avoid.
        let action = SuggestedGitActionResolver.resolve(GitActionContext(
            hasUpstream: true,
            pullRequest: openPR(number: 8, base: "ore/lower", checks: [check("build", "SUCCESS")]),
            parentBranch: "ore/lower",
            parentPullRequest: openPR(number: 7)
        ))
        #expect(action == .waitForParentToMerge(parentBranch: "ore/lower", parentPRNumber: 7))
        #expect(!action.isActionable)
    }

    @Test func aMergedParentTriggersARetargetBeforeAnythingElse() {
        // The child now points at a branch that no longer exists; nothing else
        // can proceed until it's retargeted.
        var parent = openPR(number: 7)
        parent.state = "MERGED"

        let action = SuggestedGitActionResolver.resolve(GitActionContext(
            hasUncommittedChanges: true,
            hasUpstream: true,
            baseBranch: "main",
            pullRequest: openPR(number: 8, base: "ore/lower"),
            parentBranch: "ore/lower",
            parentPullRequest: parent
        ))
        #expect(action == .retargetAfterParentMerged(prNumber: 8, newBase: "main"))
    }

    @Test func aRetargetedChildBecomesMergeableOnceItsParentLands() {
        var parent = openPR(number: 7)
        parent.state = "MERGED"

        let action = SuggestedGitActionResolver.resolve(GitActionContext(
            hasUpstream: true,
            baseBranch: "main",
            // Already retargeted onto main.
            pullRequest: openPR(number: 8, base: "main", checks: [check("build", "SUCCESS")]),
            parentBranch: "ore/lower",
            parentPullRequest: parent
        ))
        #expect(action == .merge(prNumber: 8, isStacked: true))
    }

    // MARK: - Degraded environments

    @Test func aMissingGitHubCLIStillAllowsPushing() {
        // `gh` is only needed for the PR half. Losing it shouldn't strand work
        // that git alone can move.
        let context = GitActionContext(
            unpushedCommitCount: 1,
            hasUpstream: true,
            gitHubStatus: GitHubClient.Status(
                isInstalled: false, isAuthenticated: false,
                diagnostic: "The GitHub CLI (`gh`) is not installed."
            )
        )
        #expect(SuggestedGitActionResolver.resolve(context)
            == .push(commitCount: 1, isFirstPush: false))

        var pushed = context
        pushed.unpushedCommitCount = 0
        guard case .setUpGitHub(let reason) = SuggestedGitActionResolver.resolve(pushed) else {
            Issue.record("expected a GitHub setup prompt")
            return
        }
        #expect(reason.contains("gh"))
    }

    @Test func aRepositoryWithNoRemoteAndNoCommitsOffersNothing() {
        let action = SuggestedGitActionResolver.resolve(GitActionContext(hasRemote: false))
        #expect(action == .none)
    }

    @Test func committedWorkWithNoRemoteOffersToCreateTheRepoWhenGitHubIsReady() {
        // The dead-end "Committed locally" becomes a button once `gh` can make
        // the repo it was missing.
        let action = SuggestedGitActionResolver.resolve(GitActionContext(
            commitsAheadOfBase: 1, hasRemote: false
        ))
        #expect(action == .createGitHubRepo)
    }

    @Test func committedWorkWithNoRemoteAndNoGitHubReportsTheStateHonestly() {
        // Without `gh` there is nothing to click, so don't pretend otherwise.
        let action = SuggestedGitActionResolver.resolve(GitActionContext(
            commitsAheadOfBase: 1,
            hasRemote: false,
            gitHubStatus: GitHubClient.Status(isInstalled: false, isAuthenticated: false)
        ))
        #expect(action == .committedNoRemote)
    }

    @Test func aMergedPullRequestIsTerminal() {
        var merged = openPR()
        merged.state = "MERGED"
        let action = SuggestedGitActionResolver.resolve(GitActionContext(
            hasUncommittedChanges: true, hasUpstream: true, pullRequest: merged
        ))
        #expect(action == .merged(prNumber: 7))
    }
}
