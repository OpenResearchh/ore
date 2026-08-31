import Foundation
import OreProtocol
import Testing

@testable import OreMac

struct SidebarCompactAgeTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func agesCompressToSingleUnits() {
        #expect(sidebarCompactAge(now.addingTimeInterval(-30), now: now) == "now")
        #expect(sidebarCompactAge(now.addingTimeInterval(-5 * 60), now: now) == "5m")
        #expect(sidebarCompactAge(now.addingTimeInterval(-3 * 3600), now: now) == "3h")
        #expect(sidebarCompactAge(now.addingTimeInterval(-5 * 86400), now: now) == "5d")
        #expect(sidebarCompactAge(now.addingTimeInterval(-14 * 86400), now: now) == "2w")
        #expect(sidebarCompactAge(now.addingTimeInterval(-90 * 86400), now: now) == "3mo")
        #expect(sidebarCompactAge(now.addingTimeInterval(-800 * 86400), now: now) == "2y")
    }

    @Test func futureDatesClampToNow() {
        #expect(sidebarCompactAge(now.addingTimeInterval(3600), now: now) == "now")
    }
}

struct WorkspaceSelectionTests {
    private let first = WorkspaceID(rawValue: "first")
    private let second = WorkspaceID(rawValue: "second")

    @Test func anArchivedSelectionMovesToTheFirstRemainingWorkspace() {
        #expect(workspaceSelectionAfterListChange(
            selected: first, active: [second]
        ) == second)
    }

    @Test func aStillActiveSelectionIsPreservedAcrossListRefreshes() {
        #expect(workspaceSelectionAfterListChange(
            selected: second, active: [first, second]
        ) == second)
    }

    @Test func archivingTheLastWorkspaceClearsSelection() {
        #expect(workspaceSelectionAfterListChange(
            selected: first, active: []
        ) == nil)
    }
}
