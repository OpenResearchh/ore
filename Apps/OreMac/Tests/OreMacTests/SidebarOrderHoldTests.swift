import Foundation
import OreProtocol
import Testing

@testable import OreMac

/// The sidebar stops re-sorting under the pointer. These pin the three pure
/// pieces that make that safe: when the hold releases, how the frozen order is
/// reconciled with live data, and what ⌘1–9 lands on while it is frozen.
struct SidebarOrderHoldTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    // MARK: Release

    @Test func aPointerInTheSidebarHolds() {
        #expect(SidebarOrderHold.release(
            pointerInside: true, isScrolling: false, lastScrollEnd: nil, now: now
        ) == .hold)
    }

    @Test func momentumHoldsEvenWithThePointerGone() {
        #expect(SidebarOrderHold.release(
            pointerInside: false, isScrolling: true, lastScrollEnd: nil, now: now
        ) == .hold)
    }

    @Test func aPointerThatNeverScrolledReleasesAtOnce() {
        #expect(SidebarOrderHold.release(
            pointerInside: false, isScrolling: false, lastScrollEnd: nil, now: now
        ) == .now)
    }

    /// A flick that carries the pointer out of the sidebar must not reorder the
    /// rows it just showed; the grace runs from the end of the gesture.
    @Test func aRecentFlickKeepsHoldingForTheRemainingGrace() {
        let release = SidebarOrderHold.release(
            pointerInside: false,
            isScrolling: false,
            lastScrollEnd: now.addingTimeInterval(-0.5),
            now: now
        )
        #expect(release == .after(SidebarOrderHold.scrollGrace - 0.5))
    }

    @Test func anOldFlickReleasesAtOnce() {
        #expect(SidebarOrderHold.release(
            pointerInside: false,
            isScrolling: false,
            lastScrollEnd: now.addingTimeInterval(-SidebarOrderHold.scrollGrace - 1),
            now: now
        ) == .now)
    }

    // MARK: Merge

    @Test func theHeldOrderSurvivesAReSort() {
        #expect(SidebarOrderHold.merge(held: [1, 2, 3], live: [3, 1, 2]) == [1, 2, 3])
    }

    @Test func aRemovedWorkspaceDropsOutImmediately() {
        #expect(SidebarOrderHold.merge(held: [1, 2, 3], live: [3, 1]) == [1, 3])
    }

    /// A workspace the person just made takes its live position rather than
    /// waiting for the hold to end — it is the row they are looking for.
    @Test func aNewWorkspaceAppearsAtItsLivePosition() {
        #expect(SidebarOrderHold.merge(held: [1, 2], live: [9, 1, 2]) == [9, 1, 2])
    }

    @Test func aNewWorkspacePastTheEndIsAppended() {
        #expect(SidebarOrderHold.merge(held: [1, 2], live: [1, 2, 9]) == [1, 2, 9])
    }

    @Test func anEmptyHoldIsJustTheLiveOrder() {
        #expect(SidebarOrderHold.merge(held: [], live: [1, 2, 3]) == [1, 2, 3])
    }

    // MARK: ⌘1–9

    @Test func shortcutsFollowTheLiveOrderWhenNothingIsHeld() {
        #expect(SidebarOrderHold.shortcutTarget(at: 1, held: nil, live: [a, b, c]) == b)
    }

    /// The badge on screen says ⌘2, so ⌘2 has to select that row even though
    /// the live sort has since promoted something else.
    @Test func shortcutsFollowTheDisplayedOrderWhileHeld() {
        #expect(SidebarOrderHold.shortcutTarget(at: 1, held: [a, b, c], live: [c, a, b]) == b)
    }

    /// A held slot whose workspace is gone selects nothing rather than the
    /// wrong workspace; the row is already out of the list.
    @Test func aVanishedHeldWorkspaceIsNotSelected() {
        #expect(SidebarOrderHold.shortcutTarget(at: 1, held: [a, b, c], live: [a, c]) == nil)
    }

    @Test func slotsPastTheEndSelectNothing() {
        #expect(SidebarOrderHold.shortcutTarget(at: 5, held: nil, live: [a, b]) == nil)
    }

    private let a = WorkspaceID(rawValue: "a")
    private let b = WorkspaceID(rawValue: "b")
    private let c = WorkspaceID(rawValue: "c")
}

/// The sidebar's layout is pure, so the hold, the filter and the grouping can
/// be checked without a window.
struct SidebarLayoutTests {
    @Test func theAllTabListsEveryUnpinnedWorkspace() {
        let layout = SidebarLayout(
            workspaces: [workspace("a"), workspace("b", pinned: true)],
            activeIDs: nil,
            held: nil
        )
        #expect(layout.ordered.map(\.name) == ["a", "b"])
        #expect(layout.pinned.map(\.name) == ["b"])
        #expect(layout.listed.map(\.name) == ["a"])
    }

    /// Pinned rows live in the strip, so the Active filter never hides them —
    /// only the main list narrows.
    @Test func theActiveTabNarrowsTheListButNotTheStrip() {
        let layout = SidebarLayout(
            workspaces: [workspace("a"), workspace("b"), workspace("pinned", pinned: true)],
            activeIDs: [WorkspaceID(rawValue: "b")],
            held: nil
        )
        #expect(layout.listed.map(\.name) == ["b"])
        #expect(layout.pinned.map(\.name) == ["pinned"])
    }

    @Test func heldOrderCapturesWhatIsOnScreen() {
        let layout = SidebarLayout(
            workspaces: [workspace("a", repository: "one"), workspace("b", repository: "two")],
            activeIDs: nil,
            held: nil
        )
        #expect(layout.heldOrder.workspaceIDs == [
            WorkspaceID(rawValue: "a"), WorkspaceID(rawValue: "b"),
        ])
        #expect(layout.heldOrder.repositoryPaths == ["/repos/one", "/repos/two"])
    }

    /// A row re-sorting to the top mid-scroll is the bug; while held, only the
    /// row's contents change, never its position.
    @Test func aHeldLayoutKeepsPositionsThroughAReSort() {
        let first = workspace("a")
        let second = workspace("b")
        let held = SidebarLayout(workspaces: [first, second], activeIDs: nil, held: nil).heldOrder

        var promoted = second
        promoted.status = .awaitingInput
        let layout = SidebarLayout(workspaces: [promoted, first], activeIDs: nil, held: held)

        #expect(layout.ordered.map(\.name) == ["a", "b"])
        #expect(layout.ordered[1].status == .awaitingInput)
    }

    /// Whole project sections jumping is worse than a single row moving, so
    /// the group order freezes with everything else.
    @Test func aHeldLayoutKeepsRepositorySectionsInPlace() {
        let epoch = Date(timeIntervalSince1970: 1_000)
        let one = workspace("a", repository: "one", activity: epoch.addingTimeInterval(20))
        var two = workspace("b", repository: "two", activity: epoch)
        let held = SidebarLayout(workspaces: [one, two], activeIDs: nil, held: nil).heldOrder
        #expect(held.repositoryPaths == ["/repos/one", "/repos/two"])

        // "two" is now the most recent, so the live sort would float it above.
        two.lastActivity = epoch.addingTimeInterval(40)
        let live = SidebarLayout(workspaces: [two, one], activeIDs: nil, held: nil)
        #expect(live.groups.map(\.name) == ["two", "one"])

        let heldLayout = SidebarLayout(workspaces: [two, one], activeIDs: nil, held: held)
        #expect(heldLayout.groups.map(\.name) == ["one", "two"])
    }

    @Test func shortcutOrderStopsAtNine() {
        let many = (0..<12).map { workspace("w\($0)") }
        let layout = SidebarLayout(workspaces: many, activeIDs: nil, held: nil)
        #expect(layout.shortcutOrder.count == 9)
        #expect(layout.shortcutOrder.last == WorkspaceID(rawValue: "w8"))
    }

    private func workspace(
        _ name: String,
        pinned: Bool = false,
        repository: String = "repo",
        activity: Date? = nil
    ) -> WorkspaceSummary {
        WorkspaceSummary(
            id: WorkspaceID(rawValue: name),
            name: name,
            repositoryPath: "/repos/\(repository)",
            worktreePath: "/repos/\(repository)/\(name)",
            branch: "ore/\(name)",
            baseBranch: "main",
            harness: .claudeCode,
            isPinned: pinned,
            lastActivity: activity
        )
    }
}

/// The Active tab's set and the footer's working count are maintained on
/// AppModel now, so they are computed once per change rather than per render.
struct SidebarFleetActivityTests {
    @Test func workingBlockedAndUnreadWorkspacesAreActive() {
        let summary = SidebarFleetActivity.resolve(
            [
                workspace("busy"),
                workspace("blocked"),
                workspace("unread", unread: true),
                workspace("quiet"),
                workspace("stopped"),
            ],
            chats: { id in
                switch id.rawValue {
                case "busy": return [chat("busy", status: .runningTool)]
                case "blocked": return [chat("blocked", status: .awaitingInput)]
                case "stopped": return [chat("stopped", status: .interrupted)]
                default: return []
                }
            }
        )
        #expect(summary.activeIDs == [
            WorkspaceID(rawValue: "busy"),
            WorkspaceID(rawValue: "blocked"),
            WorkspaceID(rawValue: "unread"),
        ])
        #expect(summary.workingCount == 1)
    }

    /// The count is workspaces, not tabs: two agents in one worktree is still
    /// one row with a spinning ring.
    @Test func severalBusyTabsCountAsOneWorkingWorkspace() {
        let summary = SidebarFleetActivity.resolve([workspace("w")]) { _ in
            [chat("one", status: .thinking), chat("two", status: .runningTool)]
        }
        #expect(summary.workingCount == 1)
    }

    /// A tab that failed long ago must not keep the row lit once a newer tab
    /// has moved on — that is what `sidebarEffectiveStatus` is for.
    @Test func aStaleFailureLosesToANewerIdleTab() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let summary = SidebarFleetActivity.resolve([workspace("w")]) { _ in
            [
                chat("old", status: .failed, lastActivity: old),
                chat("new", status: .idle, lastActivity: new),
            ]
        }
        #expect(summary.activeIDs.isEmpty)
        #expect(summary.workingCount == 0)
    }

    private func workspace(_ name: String, unread: Bool = false) -> WorkspaceSummary {
        WorkspaceSummary(
            id: WorkspaceID(rawValue: name),
            name: name,
            repositoryPath: "/repos/repo",
            worktreePath: "/repos/repo/\(name)",
            branch: "ore/\(name)",
            baseBranch: "main",
            harness: .claudeCode,
            hasUnread: unread
        )
    }

    private func chat(
        _ id: String, status: AgentStatus, lastActivity: Date? = nil
    ) -> ChatSummary {
        ChatSummary(
            id: ChatID(rawValue: id),
            workspaceID: WorkspaceID(rawValue: "w"),
            title: id,
            harness: .claudeCode,
            status: status,
            lastActivity: lastActivity
        )
    }
}
