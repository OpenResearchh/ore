import Foundation
import OreProtocol
import Testing

@testable import OreMac

struct SidebarStorageBadgeTests {
    private func workspace(offline: Bool, volume: String = "T7") -> WorkspaceSummary {
        WorkspaceSummary(
            id: WorkspaceID(rawValue: "w1"),
            name: "curie",
            repositoryPath: "/repo",
            worktreePath: "/Volumes/T7/ore/workspaces/repo/curie",
            branch: "ore/curie",
            baseBranch: "main",
            harness: .claudeCode,
            storage: WorkspaceStorageState(
                rootID: StorageRootID(rawValue: "ssd"),
                kind: .external,
                displayName: volume,
                isOffline: offline
            )
        )
    }

    @Test func anOnlineWorkspaceHasNoOfflineBadge() {
        #expect(sidebarStorageBadgeTitle(workspace(offline: false)) == nil)
        #expect(sidebarStorageStatusLine(workspace(offline: false)) == nil)
    }

    @Test func anOfflineWorkspaceNamesTheVolume() {
        #expect(sidebarStorageBadgeTitle(workspace(offline: true)) == "Offline")
        #expect(sidebarStorageStatusLine(workspace(offline: true)) == "T7 isn’t connected")
    }
}
