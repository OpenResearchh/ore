import Foundation
import OreProtocol
import Testing

@testable import OreMac

struct LaunchBriefingTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// The spoken half of the briefing asked "how long were you away?" and
    /// answered "forever" when it had never been told — so the one launch that
    /// must stay quiet, a first run with a restored `~/ore`, was the one that
    /// spoke.
    @Test func missingLastSeenIsNotALongAbsence() {
        #expect(!AppModel.isLongAbsence(lastSeenAt: nil, now: now))
        #expect(!AppModel.isLongAbsence(
            lastSeenAt: now.addingTimeInterval(-60), now: now
        ))
        #expect(AppModel.isLongAbsence(
            lastSeenAt: now.addingTimeInterval(-LaunchBriefing.spokenAwayThreshold - 1),
            now: now
        ))
    }

    /// `compose` is happy to brief on nothing — it has a line for it — which is
    /// why `AppModel.prepareLaunchBriefing` guards on an empty fleet before
    /// calling it rather than after. That guard is one line inside a
    /// `@MainActor` model with a live core behind it and is not reachable from
    /// here; this pins the behaviour it exists to suppress, so the guard cannot
    /// be deleted as redundant.
    @Test func firstLaunchWithEmptyFleetProducesNoBriefing() {
        let briefing = LaunchBriefing.compose(
            workspaces: [], lastSeenAt: nil, now: now, userName: "Ada"
        )
        #expect(briefing.lines.map(\.id) == ["quiet"])
        #expect(!briefing.spoken.isEmpty)
    }

    @Test func greetingUsesFirstNameAndDaypart() {
        let morning = date(hour: 9)
        let briefing = LaunchBriefing.compose(
            workspaces: [], lastSeenAt: nil, now: morning, userName: "Ada"
        )
        #expect(briefing.greeting == "Good morning, Ada.")
        #expect(briefing.lines.map(\.id) == ["quiet"])
        #expect(briefing.lines[0].text == "Ready when you are")
    }

    @Test func lateNightGetsItsOwnGreeting() {
        let night = date(hour: 2)
        let briefing = LaunchBriefing.compose(
            workspaces: [], lastSeenAt: nil, now: night, userName: nil
        )
        #expect(briefing.greeting == "Working late.")
    }

    @Test func bucketsNeedsYouFinishedWorkingAndUncommitted() {
        let lastSeen = now.addingTimeInterval(-3600)
        let briefing = LaunchBriefing.compose(
            workspaces: [
                workspace("Kailash", status: .awaitingInput, activity: now),
                workspace("Zewail", status: .idle, unread: true, activity: now),
                workspace("Leloir", status: .runningTool, activity: now),
                workspace("Seed", status: .idle, uncommitted: true, activity: now),
            ],
            lastSeenAt: lastSeen,
            now: now,
            userName: nil
        )
        #expect(briefing.lines.map(\.id) == ["needs-you", "finished", "working", "uncommitted"])
        #expect(briefing.lines[0].text == "Kailash needs your attention")
        #expect(briefing.lines[0].isAttention)
        #expect(briefing.lines[1].text == "Zewail finished while you were away")
        #expect(briefing.lines[2].text == "Leloir is still working")
        #expect(briefing.lines[3].text == "Seed has changes ready to commit")
        #expect(briefing.spoken.hasSuffix(
            "Kailash needs your attention. Zewail finished while you were away. "
                + "Leloir is still working. Seed has changes ready to commit."
        ))
    }

    @Test func finishedBeforeTheAbsenceIsOldNews() {
        let lastSeen = now.addingTimeInterval(-600)
        let briefing = LaunchBriefing.compose(
            workspaces: [
                workspace(
                    "Old", status: .idle, unread: true,
                    activity: lastSeen.addingTimeInterval(-3600)
                )
            ],
            lastSeenAt: lastSeen,
            now: now,
            userName: nil
        )
        #expect(briefing.lines.map(\.id) == ["quiet"])
        #expect(briefing.lines[0].text == "All quiet — 1 workspace ready")
    }

    @Test func dreamFindingsLeadTheMorningCard() {
        let briefing = LaunchBriefing.compose(
            workspaces: [workspace("Quiet", status: .idle, activity: now)],
            lastSeenAt: now.addingTimeInterval(-3600),
            now: now,
            userName: nil,
            dreamFindingCount: 3
        )
        #expect(briefing.lines.map(\.id) == ["dreams"])
        #expect(briefing.lines[0].text == "ORE dreamed last night — 3 findings to review")
    }

    @Test func manyNamesCollapseToACount() {
        let briefing = LaunchBriefing.compose(
            workspaces: (1...5).map {
                workspace("W\($0)", status: .awaitingInput, activity: now)
            },
            lastSeenAt: nil,
            now: now,
            userName: nil
        )
        #expect(briefing.lines[0].text == "W1, W2, and 3 others need your attention")
    }

    @Test func archivedWorkspacesAreInvisible() {
        let briefing = LaunchBriefing.compose(
            workspaces: [workspace("Gone", status: .awaitingInput, archived: true, activity: now)],
            lastSeenAt: nil,
            now: now,
            userName: nil
        )
        #expect(briefing.lines.map(\.id) == ["quiet"])
        #expect(briefing.lines[0].text == "Ready when you are")
    }

    @Test func standingConflictsGetTheirOwnAttentionLine() {
        // `FleetWatcher` only announces a conflict that appears while the user
        // is watching, so one that was already there at launch is the
        // briefing's to report or nobody's.
        let briefing = LaunchBriefing.compose(
            workspaces: [
                workspace("Kailash", status: .idle, conflicted: true, activity: now),
                workspace("Zewail", status: .idle, conflicted: true, activity: now),
            ],
            lastSeenAt: nil,
            now: now,
            userName: nil
        )
        #expect(briefing.lines.map(\.id) == ["conflicted"])
        #expect(briefing.lines[0].text == "2 workspaces conflict with their base branch")
        #expect(briefing.lines[0].isAttention)
    }

    @Test func aSingleConflictIsNamed() {
        let briefing = LaunchBriefing.compose(
            workspaces: [workspace("Kailash", status: .idle, conflicted: true, activity: now)],
            lastSeenAt: nil,
            now: now,
            userName: nil
        )
        #expect(briefing.lines[0].text == "Kailash conflicts with its base branch")
    }

    @Test func firstNameExtraction() {
        #expect(LaunchBriefing.firstName(from: "Ada Lovelace") == "Ada")
        #expect(LaunchBriefing.firstName(from: "") == nil)
    }

    // MARK: - Fixtures

    private func date(hour: Int) -> Date {
        Calendar.current.date(
            bySettingHour: hour, minute: 0, second: 0, of: now
        ) ?? now
    }

    private func workspace(
        _ name: String,
        status: AgentStatus,
        unread: Bool = false,
        uncommitted: Bool = false,
        archived: Bool = false,
        conflicted: Bool = false,
        activity: Date? = nil
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
                changedFileCount: uncommitted ? 2 : 0,
                insertions: 0,
                deletions: 0,
                hasUncommittedChanges: uncommitted,
                aheadOfBase: 0,
                behindBase: 0
            ),
            lastActivity: activity,
            baseSync: BaseSyncStatus(defaultBranch: "main", wouldConflict: conflicted)
        )
    }
}
