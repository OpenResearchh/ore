import Foundation
import OreProtocol
import Testing

@testable import OreMac

struct FleetSuggestionTests {
    @Test func blockedBeatsEverything() {
        let suggestion = FleetSuggestionResolver.resolve([
            workspace("committer", status: .idle, uncommitted: true),
            workspace("failed", status: .failed),
            workspace("blocked", status: .awaitingInput),
            workspace("unread", status: .idle, unread: true),
        ])
        #expect(suggestion?.id == "needs-you")
        #expect(suggestion?.title == "blocked is waiting on you")
    }

    @Test func laddersDownToCommit() {
        let suggestion = FleetSuggestionResolver.resolve([
            workspace("quiet", status: .idle),
            workspace("committer", status: .idle, uncommitted: true),
        ])
        #expect(suggestion?.id == "commit")
        #expect(suggestion?.startsCommitAgent == true)
    }

    @Test func quietFleetSuggestsNothing() {
        #expect(FleetSuggestionResolver.resolve([
            workspace("quiet", status: .idle),
            workspace("busy", status: .runningTool),
        ]) == nil)
    }

    /// The menu bar passes live git state through this closure rather than
    /// stamping it onto every summary, so it is asked for only when the rungs
    /// above have not already decided — and never for a fleet with anything
    /// more urgent going on.
    @Test func liveGitStateIsOnlyConsultedOnTheLastRung() {
        var asked: [String] = []
        let suggestion = FleetSuggestionResolver.resolve([
            workspace("quiet", status: .idle),
            workspace("dirty", status: .idle),
            workspace("busy", status: .runningTool),
        ]) { workspace in
            asked.append(workspace.name)
            return workspace.name == "dirty"
        }
        #expect(suggestion?.id == "commit")
        #expect(suggestion?.title == "Commit dirty's changes")
        // Stopped at the first dirty one; "busy" is not idle, so never asked.
        #expect(asked == ["quiet", "dirty"])
    }

    @Test func aBlockedWorkspaceNeverReachesTheGitRung() {
        var asked = 0
        _ = FleetSuggestionResolver.resolve([
            workspace("blocked", status: .awaitingInput),
            workspace("dirty", status: .idle),
        ]) { _ in
            asked += 1
            return true
        }
        #expect(asked == 0)
    }

    @Test func archivedWorkspacesAreIgnored() {
        #expect(FleetSuggestionResolver.resolve([
            workspace("gone", status: .awaitingInput, archived: true)
        ]) == nil)
    }

    private func workspace(
        _ name: String,
        status: AgentStatus,
        unread: Bool = false,
        uncommitted: Bool = false,
        archived: Bool = false
    ) -> WorkspaceSummary {
        WorkspaceSummary(
            id: WorkspaceID(rawValue: name),
            name: name,
            repositoryPath: "/tmp/\(name)",
            worktreePath: "/tmp/\(name)/wt",
            branch: "ore/\(name)",
            baseBranch: "main",
            harness: .claudeCode,
            status: status,
            hasUnread: unread,
            isArchived: archived,
            gitStatus: GitStatusSummary(
                changedFileCount: uncommitted ? 1 : 0,
                insertions: 0,
                deletions: 0,
                hasUncommittedChanges: uncommitted,
                aheadOfBase: 0,
                behindBase: 0
            )
        )
    }
}
