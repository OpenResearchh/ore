import Foundation
import OreProtocol
import Testing

@testable import OreMac

struct MenuBarWorkspaceVisibilityTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func onlyCurrentAndRecentlyCompletedWorkAppears() {
        let working = workspace("working", status: .runningTool)
        let recent = workspace(
            "recent", status: .idle, lastActivity: now.addingTimeInterval(-9 * 60)
        )
        let old = workspace(
            "old", status: .idle, lastActivity: now.addingTimeInterval(-11 * 60)
        )
        let neverRun = workspace("never", status: .idle)

        let visible = MenuBarWorkspaceVisibility.visible(
            [working, recent, old, neverRun], needsYouWorkspaceIDs: [], now: now
        )
        #expect(visible.map(\.name) == ["working", "recent"])
    }

    @Test func explicitAttentionStaysVisibleRegardlessOfAge() {
        let waiting = workspace("waiting", status: .awaitingInput)
        let failed = workspace("failed", status: .failed)
        let routedPermission = workspace("permission", status: .idle)

        let visible = MenuBarWorkspaceVisibility.visible(
            [waiting, failed, routedPermission],
            needsYouWorkspaceIDs: [routedPermission.id],
            now: now
        )
        #expect(visible.map(\.name) == ["waiting", "failed", "permission"])
    }

    private func workspace(
        _ name: String,
        status: AgentStatus,
        lastActivity: Date? = nil
    ) -> WorkspaceSummary {
        WorkspaceSummary(
            id: WorkspaceID(rawValue: name),
            name: name,
            repositoryPath: "/tmp/repo",
            worktreePath: "/tmp/tree",
            branch: "ore/\(name)",
            baseBranch: "main",
            harness: .codex,
            status: status,
            lastActivity: lastActivity
        )
    }
}
