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
