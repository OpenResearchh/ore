import Foundation
import Testing
@testable import OreCore
@testable import OrePersistence
import OreProtocol

struct DreamSchedulerTests {
    @Test func disabledStaysDisabledUntilEnabled() {
        let settings = DreamSettings(enabled: false)
        let environment = DreamEnvironmentSnapshot(secondsSinceInput: 3600, isOnACPower: true)
        let (next, actions) = DreamScheduler.step(
            state: DreamScheduler.State(phase: .disabled),
            settings: settings,
            environment: environment
        )
        #expect(next.phase == .disabled)
        #expect(actions.isEmpty)
    }

    @Test func idleInQuietHoursOnACStartsARun() {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 2
        comps.minute = 0
        let now = Calendar.current.date(from: comps) ?? Date()
        let settings = DreamSettings(
            enabled: true,
            quietHoursStartMinutes: 60,
            quietHoursEndMinutes: 7 * 60,
            idleMinutes: 20,
            requireACPower: true
        )
        let environment = DreamEnvironmentSnapshot(
            secondsSinceInput: 30 * 60,
            lastSeenAt: now.addingTimeInterval(-30 * 60),
            now: now,
            isOnACPower: true
        )
        let (watching, _) = DreamScheduler.step(
            state: DreamScheduler.State(phase: .armed),
            settings: settings,
            environment: environment
        )
        #expect(watching.phase == .watching)

        let (dreaming, actions) = DreamScheduler.step(
            state: watching,
            settings: settings,
            environment: environment
        )
        #expect(dreaming.phase == .dreaming)
        #expect(actions == [.startRun(manual: false)])
    }

    @Test func userReturnPausesADream() {
        let now = Date()
        let settings = DreamSettings(enabled: true, idleMinutes: 20)
        let environment = DreamEnvironmentSnapshot(
            secondsSinceInput: 5,
            lastSeenAt: now,
            now: now,
            isOnACPower: true
        )
        let (next, actions) = DreamScheduler.step(
            state: DreamScheduler.State(phase: .dreaming, runID: DreamRunID.generate()),
            settings: settings,
            environment: environment
        )
        #expect(next.phase == .pausing)
        #expect(actions == [.pause])
    }

    @Test func sleepWindsDown() {
        let settings = DreamSettings(enabled: true)
        let environment = DreamEnvironmentSnapshot(
            secondsSinceInput: 3600,
            isOnACPower: true,
            isSleepImminent: true
        )
        let (next, actions) = DreamScheduler.step(
            state: DreamScheduler.State(phase: .dreaming, runID: DreamRunID.generate()),
            settings: settings,
            environment: environment
        )
        #expect(next.phase == .windingDown)
        #expect(actions == [.windDown(reason: "Mac is going to sleep")])
    }

    @Test func keepAwakeOnlyOnAC() {
        let settings = DreamSettings(enabled: true, preventSleep: true)
        let onAC = DreamEnvironmentSnapshot(secondsSinceInput: 0, isOnACPower: true)
        let onBattery = DreamEnvironmentSnapshot(secondsSinceInput: 0, isOnACPower: false)
        #expect(DreamScheduler.shouldHoldSleepAssertion(
            settings: settings, environment: onAC, isDreaming: true
        ))
        #expect(!DreamScheduler.shouldHoldSleepAssertion(
            settings: settings, environment: onBattery, isDreaming: true
        ))
        #expect(DreamScheduler.sleepStatus(
            settings: settings, environment: onBattery, isDreaming: false
        ) == .keepAwakePausedOnBattery)
        #expect(DreamScheduler.sleepStatus(
            settings: DreamSettings(enabled: true, preventSleep: false),
            environment: onAC,
            isDreaming: false
        ) == .macMaySleep)
    }

    @Test func thermalPressurePausesADream() {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 2
        comps.minute = 0
        let now = Calendar.current.date(from: comps) ?? Date()
        let settings = DreamSettings(enabled: true, idleMinutes: 20)
        let environment = DreamEnvironmentSnapshot(
            secondsSinceInput: 30 * 60,
            lastSeenAt: now.addingTimeInterval(-30 * 60),
            now: now,
            isOnACPower: true,
            thermalPressure: true
        )
        let (next, actions) = DreamScheduler.step(
            state: DreamScheduler.State(phase: .dreaming, runID: DreamRunID.generate()),
            settings: settings,
            environment: environment
        )
        #expect(next.phase == .pausing)
        #expect(actions == [.pause])
    }

    @Test func idleAfterPauseResumes() {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 2
        comps.minute = 0
        let now = Calendar.current.date(from: comps) ?? Date()
        let settings = DreamSettings(enabled: true, idleMinutes: 20)
        let environment = DreamEnvironmentSnapshot(
            secondsSinceInput: 30 * 60,
            lastSeenAt: now.addingTimeInterval(-30 * 60),
            now: now,
            isOnACPower: true
        )
        let runID = DreamRunID.generate()
        let (next, actions) = DreamScheduler.step(
            state: DreamScheduler.State(phase: .pausing, runID: runID),
            settings: settings,
            environment: environment
        )
        #expect(next.phase == .dreaming)
        #expect(actions == [.resume])
    }
}

struct DreamPlannerTests {
    @Test func picksTheActiveRepoForReview() {
        let now = Date()
        let candidate = DreamPlanner.plan(
            activity: [
                DreamRepositoryActivity(
                    repositoryPath: "/tmp/quiet",
                    repositoryName: "quiet",
                    turnCount: 0,
                    lastTurnAt: now.addingTimeInterval(-30 * 86_400),
                    isPinned: false
                ),
                DreamRepositoryActivity(
                    repositoryPath: "/tmp/hot",
                    repositoryName: "hot",
                    turnCount: 12,
                    lastTurnAt: now.addingTimeInterval(-3600),
                    isPinned: false
                ),
            ],
            excludedRepoPaths: [],
            now: now
        )
        #expect(candidate?.repositoryName == "hot")
        #expect(candidate?.kind == .bugHunt)
        #expect(candidate?.why.contains("12 turns") == true)
    }

    @Test func stalePinnedRepoGetsAnAudit() {
        let now = Date()
        let candidate = DreamPlanner.plan(
            activity: [
                DreamRepositoryActivity(
                    repositoryPath: "/tmp/pinned",
                    repositoryName: "pinned",
                    turnCount: 1,
                    lastTurnAt: now.addingTimeInterval(-10 * 86_400),
                    isPinned: true
                ),
            ],
            excludedRepoPaths: [],
            now: now
        )
        #expect(candidate?.kind == .dependencyAudit)
        #expect(candidate?.why.contains("pinned") == true)
    }

    @Test func excludedReposAreSkipped() {
        let candidate = DreamPlanner.plan(
            activity: [
                DreamRepositoryActivity(
                    repositoryPath: "/tmp/secret",
                    repositoryName: "secret",
                    turnCount: 40,
                    lastTurnAt: Date(),
                    isPinned: true
                ),
            ],
            excludedRepoPaths: ["/tmp/secret"]
        )
        #expect(candidate == nil)
    }

    @Test func excludedReposAreRefusedForManualStartsToo() {
        #expect(DreamPlanner.isExcludedRepository(
            "/tmp/secret",
            excludedRepoPaths: ["/tmp/secret", "/tmp/other"]
        ))
        #expect(!DreamPlanner.isExcludedRepository(
            "/tmp/ok",
            excludedRepoPaths: ["/tmp/secret"]
        ))
    }

    @Test func rejectedBugHuntsFallThroughToReview() {
        let now = Date()
        let activity = DreamRepositoryActivity(
            repositoryPath: "/tmp/hot",
            repositoryName: "hot",
            turnCount: 12,
            lastTurnAt: now.addingTimeInterval(-3600),
            isPinned: false
        )
        let candidate = DreamPlanner.plan(
            activity: [activity],
            excludedRepoPaths: [],
            now: now,
            acceptance: [
                DreamKindAcceptance(
                    repositoryPath: "/tmp/hot",
                    kind: .bugHunt,
                    accepted: 0,
                    rejected: 2
                ),
            ]
        )
        #expect(candidate?.kind == .review)
    }

    @Test func moderatelyIdleReposGetFeatureIdeas() {
        let now = Date()
        let candidate = DreamPlanner.plan(
            activity: [
                DreamRepositoryActivity(
                    repositoryPath: "/tmp/ideas",
                    repositoryName: "ideas",
                    turnCount: 4,
                    lastTurnAt: now.addingTimeInterval(-4 * 86_400),
                    isPinned: false
                ),
            ],
            excludedRepoPaths: [],
            now: now
        )
        #expect(candidate?.kind == .featureIdeas)
        #expect(DreamKind.featureIdeas.isMVP)
    }

    @Test func nightWindowStartsAtQuietHoursClock() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var comps = DateComponents(calendar: calendar, timeZone: calendar.timeZone)
        comps.year = 2026
        comps.month = 9
        comps.day = 5
        comps.hour = 15
        comps.minute = 0
        let afternoon = calendar.date(from: comps)!
        let start = DreamPlanner.nightWindowStart(
            now: afternoon,
            quietHoursStartMinutes: 60,
            calendar: calendar
        )
        #expect(calendar.component(.hour, from: start) == 1)
        #expect(calendar.component(.day, from: start) == 5)

        comps.hour = 0
        comps.minute = 30
        let beforeStart = calendar.date(from: comps)!
        let previous = DreamPlanner.nightWindowStart(
            now: beforeStart,
            quietHoursStartMinutes: 60,
            calendar: calendar
        )
        #expect(calendar.component(.day, from: previous) == 4)

        #expect(DreamPlanner.remainingTokenBudget(effectiveCap: 37_500, spent: 20_000) == 17_500)
        #expect(DreamPlanner.remainingTokenBudget(effectiveCap: 37_500, spent: 40_000) == 0)
    }
}

struct DreamStoreTests {
    @Test func defaultWorkspaceListExcludesDreamAndAssistant() async throws {
        let store = try OreStore()
        try await store.addRepository(RepositoryRecord(
            path: "/tmp/repo", name: "repo", defaultBranch: "main"
        ))
        try await store.saveWorkspace(WorkspaceRecord(
            id: WorkspaceID.generate(),
            name: "user",
            repositoryPath: "/tmp/repo",
            worktreePath: "/tmp/repo/user",
            branch: "ore/user",
            baseBranch: "main",
            harness: .claudeCode
        ))
        try await store.saveWorkspace(WorkspaceRecord(
            id: WorkspaceID.generate(),
            name: "Dream · review · repo",
            repositoryPath: "/tmp/repo",
            worktreePath: "/tmp/repo/dream",
            branch: "ore/dream/review",
            baseBranch: "main",
            harness: .claudeCode,
            kind: .dream
        ))
        let listed = try await store.workspaces()
        #expect(listed.map(\.name) == ["user"])
        #expect(listed.allSatisfy { $0.workspaceKind == .standard })
    }

    @Test func ledgerSpendIsSummedAcrossTheNight() async throws {
        let store = try OreStore()
        let older = DreamRunID.generate()
        let newer = DreamRunID.generate()
        try await store.saveDreamRun(DreamRunRecord(
            id: older, state: .completed, trigger: .schedule, why: "old", tokenBudget: 10
        ))
        try await store.saveDreamRun(DreamRunRecord(
            id: newer, state: .completed, trigger: .manual, why: "new", tokenBudget: 10
        ))
        try await store.appendDreamLedger(DreamLedgerRecord(
            runID: older, harness: .claudeCode, tokens: 1_000, turns: 1,
            createdAt: Date().addingTimeInterval(-48 * 3600)
        ))
        try await store.appendDreamLedger(DreamLedgerRecord(
            runID: newer, harness: .claudeCode, tokens: 2_000, turns: 1
        ))
        let spent = try await store.dreamLedgerTokens(since: Date().addingTimeInterval(-24 * 3600))
        #expect(spent == 2_000)
        #expect(try await store.dreamLedgerTokens(runID: newer) == 2_000)
    }

    @Test func deferredFindingsResurfaceAndStaleOnesExpire() async throws {
        let store = try OreStore()
        let runID = DreamRunID.generate()
        let taskID = DreamTaskID.generate()
        try await store.saveDreamRun(DreamRunRecord(
            id: runID, state: .completed, trigger: .schedule, why: "test"
        ))
        try await store.saveDreamTask(DreamTaskRecord(
            id: taskID,
            runID: runID,
            repositoryPath: "/tmp/repo",
            kind: .review,
            priorityScore: 1,
            state: .completed,
            why: "test"
        ))
        let deferred = DreamFindingRecord(
            id: DreamFindingID.generate(),
            taskID: taskID,
            runID: runID,
            repositoryPath: "/tmp/repo",
            kind: .issue,
            title: "Deferred bug",
            summary: "later",
            confidence: 0.8,
            severity: .warning,
            status: .deferred,
            deferredUntil: Date().addingTimeInterval(-60),
            dedupeKey: "deferred",
            why: "test"
        )
        try await store.saveDreamFinding(deferred)
        let stale = DreamFindingRecord(
            id: DreamFindingID.generate(),
            taskID: taskID,
            runID: runID,
            repositoryPath: "/tmp/repo",
            kind: .issue,
            title: "Old unused",
            summary: "noise",
            confidence: 0.4,
            severity: .info,
            status: .new,
            dedupeKey: "stale",
            why: "test",
            createdAt: Date().addingTimeInterval(-20 * 24 * 3600)
        )
        try await store.saveDreamFinding(stale)

        try await store.resurfaceDeferredDreamFindings()
        try await store.expireStaleDreamFindings()

        let revived = try await store.dreamFinding(deferred.findingID)
        #expect(revived?.status == DreamFindingStatus.new.rawValue)
        let expired = try await store.dreamFinding(stale.findingID)
        #expect(expired?.status == DreamFindingStatus.expired.rawValue)

        try await store.saveDreamFinding(DreamFindingRecord(
            id: DreamFindingID.generate(),
            taskID: taskID,
            runID: runID,
            repositoryPath: "/tmp/repo",
            kind: .issue,
            title: "Accepted",
            summary: "good",
            confidence: 0.9,
            severity: .warning,
            status: .accepted,
            dedupeKey: "accepted",
            why: "test"
        ))
        let huntTaskID = DreamTaskID.generate()
        try await store.saveDreamTask(DreamTaskRecord(
            id: huntTaskID,
            runID: runID,
            repositoryPath: "/tmp/repo",
            kind: .bugHunt,
            priorityScore: 1,
            state: .completed,
            why: "hunt"
        ))
        try await store.saveDreamFinding(DreamFindingRecord(
            id: DreamFindingID.generate(),
            taskID: huntTaskID,
            runID: runID,
            repositoryPath: "/tmp/repo",
            kind: .bug,
            title: "Rejected hunt",
            summary: "nope",
            confidence: 0.6,
            severity: .info,
            status: .rejected,
            rejectReason: DreamRejectReason.wrong.rawValue,
            dedupeKey: "rejected",
            why: "hunt"
        ))
        let rates = try await store.dreamKindAcceptance()
        #expect(rates.contains { $0.kind == .review && $0.accepted == 1 })
        #expect(rates.contains { $0.kind == .bugHunt && $0.rejected == 1 })
    }
}

struct DreamPolicyTests {
    @Test func researchDreamsDisallowShellAndEdits() {
        #expect(WorkspaceEngine.dreamDisallowedTools.contains("Bash"))
        #expect(WorkspaceEngine.dreamDisallowedTools.contains("Shell"))
        #expect(WorkspaceEngine.dreamDisallowedTools.contains("Edit"))
        #expect(WorkspaceEngine.dreamDisallowedTools.contains("Write"))
    }
}
