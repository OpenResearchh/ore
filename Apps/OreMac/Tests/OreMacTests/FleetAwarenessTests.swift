import Foundation
import OreProtocol
import Testing

@testable import OreMac

/// The rules of ambient fleet awareness: what a workspace snapshot change is
/// worth saying, how rarely the fleet gets to say it, and the order in which
/// what's waiting is visited.
struct FleetWatcherTests {
    private let start = Date(timeIntervalSince1970: 2_000_000_000)

    // MARK: - Conflicts

    @Test func firstSightRecordsWithoutSpeaking() {
        var watcher = FleetWatcher()
        // A fleet that has been conflicting all night is the launch briefing's
        // story, not an interjection's.
        let seen = watcher.observe(conflicting("Zewail"), now: start)
        #expect(seen.isEmpty)
        #expect(!watcher.hasPendingMilestones)
    }

    @Test func conflictAppearingIsAMilestone() {
        var watcher = FleetWatcher()
        watcher.observe(workspace("Zewail"), now: start)
        let seen = watcher.observe(conflicting("Zewail"), now: start)
        #expect(seen.count == 1)
        #expect(seen[0].kind == .conflicted(base: "main"))
        #expect(seen[0].name == "Zewail")
    }

    @Test func conflictClearingIsAMilestoneToo() {
        var watcher = FleetWatcher()
        watcher.observe(workspace("Zewail"), now: start)
        watcher.observe(conflicting("Zewail"), now: start)
        let seen = watcher.observe(workspace("Zewail"), now: start)
        #expect(seen.map(\.kind) == [.conflictCleared(base: "main")])
    }

    @Test func anUnchangedSnapshotSaysNothing() {
        var watcher = FleetWatcher()
        watcher.observe(conflicting("Zewail"), now: start)
        // The status watcher republishes a summary on every FSEvents batch.
        for _ in 0..<5 {
            #expect(watcher.observe(conflicting("Zewail"), now: start).isEmpty)
        }
    }

    // MARK: - Base drift

    @Test func fallingFarBehindTheBaseIsWorthOneMention() {
        var watcher = FleetWatcher()
        watcher.observe(workspace("Zewail"), now: start)
        let seen = watcher.observe(behind("Zewail", commits: 12), now: start)
        #expect(seen.map(\.kind) == [.fellBehind(commits: 12, base: "main")])
        // Drifting further is the same fact, not a new one.
        #expect(watcher.observe(behind("Zewail", commits: 30), now: start).isEmpty)
    }

    @Test func driftBelowTheThresholdIsNoise() {
        var watcher = FleetWatcher()
        watcher.observe(workspace("Zewail"), now: start)
        #expect(watcher.observe(behind("Zewail", commits: 3), now: start).isEmpty)
    }

    @Test func catchingUpRearmsTheNextMention() {
        var watcher = FleetWatcher()
        watcher.observe(workspace("Zewail"), now: start)
        watcher.observe(behind("Zewail", commits: 12), now: start)
        // A rebase lands: silent, but the next drift may speak again.
        #expect(watcher.observe(behind("Zewail", commits: 0), now: start).isEmpty)
        let seen = watcher.observe(behind("Zewail", commits: 14), now: start)
        #expect(seen.map(\.kind) == [.fellBehind(commits: 14, base: "main")])
    }

    @Test func aWorkspaceAlreadyBehindAtLaunchStaysQuiet() {
        var watcher = FleetWatcher()
        watcher.observe(behind("Zewail", commits: 40), now: start)
        #expect(watcher.observe(behind("Zewail", commits: 41), now: start).isEmpty)
    }

    @Test func archivingForgetsTheWorkspace() {
        var watcher = FleetWatcher()
        watcher.observe(conflicting("Zewail"), now: start)
        var archived = conflicting("Zewail")
        archived.isArchived = true
        #expect(watcher.observe(archived, now: start).isEmpty)
        // Unarchived later, it is new again — and new means silent.
        #expect(watcher.observe(workspace("Zewail"), now: start).isEmpty)
    }

    @Test func theAssistantsOwnWorkspaceIsNotPartOfTheFleet() {
        var watcher = FleetWatcher()
        var assistant = workspace("Assistant")
        assistant.kind = .assistant
        watcher.observe(assistant, now: start)
        var conflicted = conflicting("Assistant")
        conflicted.kind = .assistant
        #expect(watcher.observe(conflicted, now: start).isEmpty)
    }

    // MARK: - Blocked tabs

    @Test func aBlockedTabIsRemindedOnceAfterTheThreshold() {
        var watcher = FleetWatcher()
        let tab = FleetWatcher.BlockedTab(
            id: "permission-1", workspaceID: WorkspaceID(rawValue: "Zewail"), name: "Zewail"
        )
        // The arrival already spoke as an interrupt; nothing is owed yet.
        #expect(watcher.reconcileBlocked([tab], now: start).isEmpty)
        #expect(watcher.reconcileBlocked([tab], now: start.addingTimeInterval(300)).isEmpty)

        let late = start.addingTimeInterval(FleetAwarenessPolicy.blockedReminder + 1)
        let seen = watcher.reconcileBlocked([tab], now: late)
        #expect(seen.map(\.kind) == [.stillBlocked(minutes: 10)])
        // Reminded once, not every tick from here to lunch.
        #expect(watcher.reconcileBlocked([tab], now: late.addingTimeInterval(60)).isEmpty)
    }

    @Test func aTabAnsweredBeforeTheThresholdIsNeverMentioned() {
        var watcher = FleetWatcher()
        let tab = FleetWatcher.BlockedTab(
            id: "question-1", workspaceID: WorkspaceID(rawValue: "Zewail"), name: "Zewail"
        )
        watcher.reconcileBlocked([tab], now: start)
        watcher.reconcileBlocked([], now: start.addingTimeInterval(60))
        let late = start.addingTimeInterval(FleetAwarenessPolicy.blockedReminder + 1)
        #expect(watcher.reconcileBlocked([], now: late).isEmpty)
    }

    @Test func oneWorkspaceBlockedThreeTimesRemindsOnce() {
        var watcher = FleetWatcher()
        let id = WorkspaceID(rawValue: "Zewail")
        let tabs = (1...3).map {
            FleetWatcher.BlockedTab(id: "permission-\($0)", workspaceID: id, name: "Zewail")
        }
        watcher.reconcileBlocked(tabs, now: start)
        let late = start.addingTimeInterval(FleetAwarenessPolicy.blockedReminder + 1)
        #expect(watcher.reconcileBlocked(tabs, now: late).count == 1)
    }

    // MARK: - Rationing

    @Test func aBurstIsAllowedToSettleBeforeItSpeaks() {
        var watcher = FleetWatcher()
        watcher.observe(workspace("Zewail"), now: start)
        watcher.observe(conflicting("Zewail"), now: start)
        #expect(watcher.flush(now: start.addingTimeInterval(5)) == nil)
        let settled = start.addingTimeInterval(FleetAwarenessPolicy.digestWindow + 1)
        #expect(watcher.flush(now: settled) != nil)
    }

    @Test func theFleetSpeaksNoOftenerThanTheGap() {
        var watcher = FleetWatcher()
        watcher.observe(workspace("Zewail"), now: start)
        watcher.observe(conflicting("Zewail"), now: start)
        let settled = start.addingTimeInterval(FleetAwarenessPolicy.digestWindow + 1)
        #expect(watcher.flush(now: settled) != nil)

        watcher.observe(workspace("Curie"), now: settled)
        watcher.observe(conflicting("Curie"), now: settled)
        let soon = settled.addingTimeInterval(FleetAwarenessPolicy.digestWindow + 1)
        #expect(watcher.flush(now: soon) == nil)
        // Nothing is lost — it rides the next line.
        let later = settled.addingTimeInterval(FleetAwarenessPolicy.digestGap + 1)
        #expect(watcher.flush(now: later)?.contains("Curie") == true)
    }

    @Test func nothingPendingSpeaksNothing() {
        var watcher = FleetWatcher()
        #expect(watcher.flush(now: start.addingTimeInterval(10_000)) == nil)
    }

    @Test func aWorkspaceThatFlipsBackWhileWaitingReportsOnlyItsLatestState() {
        var watcher = FleetWatcher()
        watcher.observe(workspace("Zewail"), now: start)
        watcher.observe(conflicting("Zewail"), now: start)
        watcher.observe(workspace("Zewail"), now: start.addingTimeInterval(1))
        let settled = start.addingTimeInterval(FleetAwarenessPolicy.digestWindow + 2)
        let line = watcher.flush(now: settled)
        #expect(line?.contains("no longer conflicts") == true)
        #expect(line?.contains("now conflicts with") == false)
    }

    @Test func discardingDropsWhatWasWaiting() {
        var watcher = FleetWatcher()
        watcher.observe(workspace("Zewail"), now: start)
        watcher.observe(conflicting("Zewail"), now: start)
        watcher.discardPending()
        #expect(!watcher.hasPendingMilestones)
        let settled = start.addingTimeInterval(FleetAwarenessPolicy.digestWindow + 1)
        #expect(watcher.flush(now: settled) == nil)
    }

    @Test func aRemovedWorkspaceTakesItsPendingLineWithIt() {
        var watcher = FleetWatcher()
        watcher.observe(workspace("Zewail"), now: start)
        watcher.observe(conflicting("Zewail"), now: start)
        watcher.forget(WorkspaceID(rawValue: "Zewail"))
        let settled = start.addingTimeInterval(FleetAwarenessPolicy.digestWindow + 1)
        #expect(watcher.flush(now: settled) == nil)
    }

    @Test func theBacklogIsBoundedButItsCountIsNot() {
        var watcher = FleetWatcher()
        let names = (1...20).map { "W\($0)" }
        for name in names { watcher.observe(workspace(name), now: start) }
        for name in names { watcher.observe(conflicting(name), now: start) }
        let settled = start.addingTimeInterval(FleetAwarenessPolicy.digestWindow + 1)
        let line = watcher.flush(now: settled)
        // Three named, and every one of the other seventeen still counted —
        // a cap that quietly shrank the number would report a calm fleet
        // during the one hour it was busiest.
        #expect(line?.hasSuffix("and 17 other workspaces moved.") == true)
    }
}

struct FleetMilestonePhraserTests {
    private let id = WorkspaceID(rawValue: "Zewail")

    @Test func oneMilestoneReadsAsOneSentence() {
        let line = FleetMilestonePhraser.line(for: [
            FleetMilestone(workspaceID: id, name: "Zewail", kind: .conflicted(base: "main"))
        ])
        #expect(line == "Heads up — Zewail now conflicts with main.")
    }

    @Test func twoMilestonesJoinWithAnAnd() {
        let line = FleetMilestonePhraser.line(for: [
            FleetMilestone(workspaceID: id, name: "Zewail", kind: .conflicted(base: "main")),
            FleetMilestone(
                workspaceID: WorkspaceID(rawValue: "Curie"), name: "Curie",
                kind: .fellBehind(commits: 12, base: "main")
            ),
        ])
        #expect(line == "Heads up — Zewail now conflicts with main, and Curie is 12 commits behind main.")
    }

    @Test func pastTheCapTheCountCarriesTheRest() {
        let line = FleetMilestonePhraser.line(for: (1...6).map {
            FleetMilestone(
                workspaceID: WorkspaceID(rawValue: "W\($0)"), name: "W\($0)",
                kind: .conflicted(base: "main")
            )
        })
        #expect(line?.hasSuffix("and three other workspaces moved.") == true)
        #expect(line?.contains("W4") == false)
    }

    @Test func exactlyOneHiddenReadsSingular() {
        let line = FleetMilestonePhraser.line(for: (1...4).map {
            FleetMilestone(
                workspaceID: WorkspaceID(rawValue: "W\($0)"), name: "W\($0)",
                kind: .conflicted(base: "main")
            )
        })
        #expect(line?.hasSuffix("and one other workspace moved.") == true)
    }

    @Test func emptyBatchHasNothingToSay() {
        #expect(FleetMilestonePhraser.line(for: []) == nil)
    }

    @Test func spokenLinesCarryNoMarkdown() {
        // Workspace names come from the user and from `ore.toml`; a name with
        // backticks or an underscore must not be read out as punctuation.
        let line = FleetMilestonePhraser.line(for: [
            FleetMilestone(workspaceID: id, name: "`ahmed_zewail`", kind: .conflicted(base: "main"))
        ])
        #expect(line?.contains("`") == false)
        #expect(line?.contains("_") == false)
    }

    @Test func writtenLinesAreEvidenceNotSpeech() {
        let milestone = FleetMilestone(
            workspaceID: id, name: "Zewail", kind: .stillBlocked(minutes: 12)
        )
        #expect(milestone.writtenLine == "Zewail: still blocked on the user after 12 minutes")
        #expect(milestone.spokenClause == "Zewail has been waiting on you for 12 minutes")
    }
}

struct NeedsYouCycleTests {
    private func workspace(_ name: String, status: AgentStatus) -> WorkspaceSummary {
        WorkspaceSummary(
            id: WorkspaceID(rawValue: name),
            name: name,
            repositoryPath: "/tmp/\(name)",
            worktreePath: "/tmp/\(name)/wt",
            branch: "ore/\(name)",
            baseBranch: "main",
            harness: .claudeCode,
            status: status
        )
    }

    private func permission(_ workspace: String, chat: String, request: String) -> TabNeedsYou {
        .permission(TabNeedsYou.Permission(
            workspaceID: WorkspaceID(rawValue: workspace),
            chatID: ChatID(rawValue: chat),
            request: PermissionRequest(
                turnID: TurnID(rawValue: "t1"),
                id: PermissionRequestID(rawValue: request),
                toolName: "Bash",
                input: nil
            )
        ))
    }

    @Test func blockedTabsLeadInArrivalOrder() {
        let stops = NeedsYouCycle.stops(
            needsYou: [
                permission("Zewail", chat: "c1", request: "p1"),
                permission("Curie", chat: "c2", request: "p2"),
            ],
            workspaces: [workspace("Zewail", status: .awaitingInput)]
        )
        #expect(stops.map(\.chatID?.rawValue) == ["c1", "c2"])
    }

    @Test func failedWorkspacesFollowAndCarryNoTab() {
        let stops = NeedsYouCycle.stops(
            needsYou: [permission("Zewail", chat: "c1", request: "p1")],
            workspaces: [
                workspace("Zewail", status: .awaitingInput),
                workspace("Curie", status: .failed),
            ]
        )
        #expect(stops.count == 2)
        #expect(stops[1] == NeedsYouCycle.Stop(
            workspaceID: WorkspaceID(rawValue: "Curie"), chatID: nil
        ))
    }

    @Test func aWorkspaceIsNotVisitedTwiceForTheSameBlock() {
        // The workspace is `awaitingInput` *because* of the blocked tab; the
        // tab is the stop, and adding the workspace behind it would make ⇧⌘U
        // land on the same place twice in a row.
        let stops = NeedsYouCycle.stops(
            needsYou: [permission("Zewail", chat: "c1", request: "p1")],
            workspaces: [workspace("Zewail", status: .awaitingInput)]
        )
        #expect(stops.count == 1)
    }

    @Test func twoRequestsInOneTabAreOneStop() {
        let stops = NeedsYouCycle.stops(
            needsYou: [
                permission("Zewail", chat: "c1", request: "p1"),
                permission("Zewail", chat: "c1", request: "p2"),
            ],
            workspaces: []
        )
        #expect(stops.count == 1)
    }

    @Test func idleWorkspacesAreNotStops() {
        let stops = NeedsYouCycle.stops(
            needsYou: [],
            workspaces: [workspace("Zewail", status: .idle), workspace("Curie", status: .thinking)]
        )
        #expect(stops.isEmpty)
    }

    @Test func theCycleWrapsAround() {
        let stops = NeedsYouCycle.stops(
            needsYou: [
                permission("Zewail", chat: "c1", request: "p1"),
                permission("Curie", chat: "c2", request: "p2"),
            ],
            workspaces: []
        )
        let first = NeedsYouCycle.next(after: nil, in: stops)
        #expect(first == stops[0])
        #expect(NeedsYouCycle.next(after: first, in: stops) == stops[1])
        #expect(NeedsYouCycle.next(after: stops[1], in: stops) == stops[0])
    }

    @Test func aStopThatIsNoLongerWaitingRestartsTheWalk() {
        let stops = NeedsYouCycle.stops(
            needsYou: [permission("Curie", chat: "c2", request: "p2")],
            workspaces: []
        )
        let answered = NeedsYouCycle.Stop(
            workspaceID: WorkspaceID(rawValue: "Zewail"), chatID: ChatID(rawValue: "c1")
        )
        #expect(NeedsYouCycle.next(after: answered, in: stops) == stops[0])
    }

    @Test func nothingWaitingHasNoNext() {
        #expect(NeedsYouCycle.next(after: nil, in: []) == nil)
    }
}

// MARK: - Shared fixtures

private func workspace(_ name: String) -> WorkspaceSummary {
    WorkspaceSummary(
        id: WorkspaceID(rawValue: name),
        name: name,
        repositoryPath: "/tmp/\(name)",
        worktreePath: "/tmp/\(name)/wt",
        branch: "ore/\(name)",
        baseBranch: "main",
        harness: .claudeCode,
        baseSync: BaseSyncStatus(defaultBranch: "main")
    )
}

private func conflicting(_ name: String) -> WorkspaceSummary {
    var summary = workspace(name)
    summary.baseSync = BaseSyncStatus(defaultBranch: "main", wouldConflict: true)
    return summary
}

private func behind(_ name: String, commits: Int) -> WorkspaceSummary {
    var summary = workspace(name)
    summary.baseSync = BaseSyncStatus(
        defaultBranch: "main", workspaceBehindOrigin: commits
    )
    return summary
}
