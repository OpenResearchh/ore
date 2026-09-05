import Foundation
import OreGit
import OrePersistence
import OreProtocol

extension InProcessCoreClient {
    func applyDreamSettings(_ settings: DreamSettings) async throws {
        dreamSettings = settings
        if let environment = dreamEnvironment {
            try await evaluateDreamScheduler(environment: environment)
        } else if !settings.enabled {
            dreamSchedulerState = DreamScheduler.State(phase: .disabled)
        } else if dreamSchedulerState.phase == .disabled {
            dreamSchedulerState = DreamScheduler.State(phase: .armed)
        }
        try await publishDreamInbox()
    }

    func applyDreamEnvironment(_ snapshot: DreamEnvironmentSnapshot) async throws {
        dreamEnvironment = snapshot
        try await evaluateDreamScheduler(environment: snapshot)
        try await publishDreamInbox()
    }

    func restoreOrphanedDreams() async throws {
        guard let run = try await store.activeDreamRun() else {
            try await maintainDreamInbox()
            return
        }
        for task in try await store.dreamTasks(runID: run.runID)
            where task.taskState == .running || task.taskState == .paused
        {
            try await checkpointDreamTask(task)
            var failed = task
            failed.state = DreamTaskState.failed.rawValue
            failed.failureReason = "Interrupted by a restart"
            failed.updatedAt = Date()
            try await store.saveDreamTask(failed)
        }
        try await finalizeDreamRun(
            run,
            cutoffReason: "ORE restarted before the dream finished",
            taskFailed: true
        )
        dreamSchedulerState = DreamScheduler.State(phase: .armed, runID: nil)
        try await maintainDreamInbox()
    }

    func abortActiveDreamRun() async throws {
        dreamWorkerTask?.cancel()
        dreamWorkerTask = nil
        if let run = try await store.activeDreamRun() {
            try await interruptDreamTasks(runID: run.runID, failureReason: "Stopped by the user")
            var updated = run
            updated.state = DreamRunState.aborted.rawValue
            updated.abortReason = "Stopped by the user"
            updated.updatedAt = Date()
            try await store.saveDreamRun(updated)
            try await writeDreamReport(updated, cutoffReason: "Stopped by the user")
        }
        dreamSchedulerState = DreamScheduler.State(
            phase: dreamSettings.enabled ? .armed : .disabled
        )
        try await publishDreamInbox()
    }

    func resolveDreamFinding(
        _ id: DreamFindingID,
        _ resolution: DreamFindingResolution
    ) async throws {
        guard var record = try await store.dreamFinding(id) else { return }
        switch resolution {
        case .accept:
            try await materializeAcceptedFinding(record)
            record.status = DreamFindingStatus.accepted.rawValue
        case .reject(let reason):
            record.status = DreamFindingStatus.rejected.rawValue
            record.rejectReason = reason.rawValue
        case .snooze(let deferral):
            record.status = DreamFindingStatus.deferred.rawValue
            let interval: TimeInterval = deferral == .tonight ? 12 * 3600 : 7 * 24 * 3600
            record.deferredUntil = Date().addingTimeInterval(interval)
        }
        record.lastSeenAt = Date()
        try await store.saveDreamFinding(record)
        continuation.yield(.dreamFindingUpdated(findingSummary(record)))
        try await publishDreamInbox()
    }

    func publishDreamInbox() async throws {
        try await maintainDreamInbox()
        continuation.yield(.dreamInboxUpdated(try await dreamInboxSnapshot()))
    }

    func beginDreamRun(manual: Bool, repositoryPath: String?) async throws {
        if try await store.activeDreamRun() != nil {
            if manual {
                continuation.yield(.commandFailed(CommandFailure(
                    workspaceID: nil,
                    message: "A dream is already running.",
                    detail: nil
                )))
            }
            return
        }

        let now = Date()
        if let parked = parkedUntil(for: dreamSettings.defaultHarness, now: now) {
            if manual {
                continuation.yield(.commandFailed(CommandFailure(
                    workspaceID: nil,
                    message: "The \(dreamSettings.defaultHarness.displayName) rate limit is exhausted.",
                    detail: parkedDetail(parked)
                )))
            }
            return
        }
        if let probe = harnessProbes.first(where: { $0.kind == dreamSettings.defaultHarness }),
           !probe.isReady {
            if manual {
                continuation.yield(.commandFailed(CommandFailure(
                    workspaceID: nil,
                    message: "\(dreamSettings.defaultHarness.displayName) is not ready to dream.",
                    detail: probe.diagnostic
                )))
            }
            return
        }

        let nightStart = DreamPlanner.nightWindowStart(
            now: now,
            quietHoursStartMinutes: dreamSettings.quietHoursStartMinutes
        )
        let spent = try await store.dreamLedgerTokens(since: nightStart)
        let remaining = DreamPlanner.remainingTokenBudget(
            effectiveCap: dreamSettings.effectiveTokenBudget,
            spent: spent
        )
        if remaining <= 0 {
            if manual {
                continuation.yield(.commandFailed(CommandFailure(
                    workspaceID: nil,
                    message: "Night token cap reached.",
                    detail: "Dreams already spent \(spent) tokens tonight. Morning headroom is reserved."
                )))
            }
            return
        }

        let activity = try await store.dreamRepositoryActivity(
            since: now.addingTimeInterval(-14 * 24 * 3600)
        )
        let acceptance = try await store.dreamKindAcceptance()
        let kinds = DreamKind.allCases.filter(\.isMVP)
        let candidate: DreamPlanner.Candidate?
        if let repositoryPath {
            let row = activity.first { $0.repositoryPath == repositoryPath }
                ?? DreamRepositoryActivity(
                    repositoryPath: repositoryPath,
                    repositoryName: URL(fileURLWithPath: repositoryPath).lastPathComponent,
                    turnCount: 0,
                    lastTurnAt: nil,
                    isPinned: false
                )
            let kind = DreamPlanner.preferredKind(
                for: row,
                now: now,
                kinds: kinds,
                acceptanceRate: { kind in
                    acceptance.first { $0.repositoryPath == row.repositoryPath && $0.kind == kind }?.rate
                        ?? 0.5
                }
            )
            let rate = acceptance.first {
                $0.repositoryPath == row.repositoryPath && $0.kind == kind
            }?.rate ?? 0.5
            let (score, why) = DreamPlanner.score(row, kind: kind, now: now, acceptanceRate: rate)
            candidate = DreamPlanner.Candidate(
                repositoryPath: row.repositoryPath,
                repositoryName: row.repositoryName,
                kind: kind,
                score: score,
                why: why
            )
        } else {
            candidate = DreamPlanner.plan(
                activity: activity,
                excludedRepoPaths: dreamSettings.excludedRepoPaths,
                now: now,
                kinds: kinds,
                acceptance: acceptance
            )
        }

        guard let candidate else {
            continuation.yield(.commandFailed(CommandFailure(
                workspaceID: nil,
                message: "Nothing to dream about yet.",
                detail: "Add a project, then try Dream now."
            )))
            return
        }

        let runID = DreamRunID.generate()
        let why = candidate.why
        let run = DreamRunRecord(
            id: runID,
            scheduledFor: now,
            state: .dreaming,
            trigger: manual ? .manual : .schedule,
            agendaJSON: (try? String(data: JSONEncoder().encode([
                "repository": candidate.repositoryName,
                "kind": candidate.kind.rawValue,
                "why": why,
            ]), encoding: .utf8)) ?? "{}",
            why: why,
            tokenBudget: remaining
        )
        try await store.saveDreamRun(run)

        let task = DreamTaskRecord(
            id: DreamTaskID.generate(),
            runID: runID,
            repositoryPath: candidate.repositoryPath,
            kind: candidate.kind,
            priorityScore: candidate.score,
            state: .pending,
            why: why,
            harness: dreamSettings.defaultHarness,
            model: dreamSettings.defaultModel
        )
        try await store.saveDreamTask(task)

        dreamSchedulerState = DreamScheduler.State(phase: .dreaming, runID: runID)
        continuation.yield(.dreamRunStateChanged(try await runSummary(run)))
        continuation.yield(.dreamTaskUpdated(try await taskSummary(task)))

        let taskID = task.taskID
        dreamWorkerTask?.cancel()
        dreamWorkerTask = Task { [weak self] in
            await self?.performDreamTask(taskID: taskID)
        }
    }

    func noteDreamHarnessRateLimit(harness: HarnessKind, event: AgentEvent) {
        guard AssistantFailoverPolicy.reason(for: event) == .rateLimited else { return }
        var until = Date().addingTimeInterval(60 * 60)
        if case .rateLimit(let report) = event, let resets = report.resetsAt {
            until = resets
        }
        dreamHarnessParkedUntil[harness] = until
    }

    // MARK: - Scheduler

    private func evaluateDreamScheduler(environment: DreamEnvironmentSnapshot) async throws {
        let (next, actions) = DreamScheduler.step(
            state: dreamSchedulerState,
            settings: dreamSettings,
            environment: environment
        )
        for action in actions {
            switch action {
            case .startRun(let manual):
                try await beginDreamRun(manual: manual, repositoryPath: nil)
                return
            case .pause:
                try await pauseDreamRun(reason: pauseReason(environment: environment))
            case .resume:
                try await resumeDreamRun()
            case .windDown(let reason):
                try await windDownDreamRun(reason: reason)
            case .abort(let reason):
                if let run = try await store.activeDreamRun() {
                    var updated = run
                    updated.state = DreamRunState.aborted.rawValue
                    updated.abortReason = reason
                    updated.updatedAt = Date()
                    try await store.saveDreamRun(updated)
                }
            case .disable, .arm:
                break
            }
        }
        if dreamWorkerTask == nil || dreamWorkerTask?.isCancelled == true {
            dreamSchedulerState = next
        }
        if let run = try await store.activeDreamRun() {
            continuation.yield(.dreamRunStateChanged(try await runSummary(run)))
        }
    }

    private func pauseReason(environment: DreamEnvironmentSnapshot) -> String {
        if environment.thermalPressure { return "This Mac got warm" }
        if dreamSettings.requireACPower, !environment.isOnACPower { return "Unplugged" }
        return "You came back"
    }

    private func pauseDreamRun(reason: String) async throws {
        guard let run = try await store.activeDreamRun() else { return }
        for task in try await store.dreamTasks(runID: run.runID) where task.taskState == .running {
            var paused = task
            paused.state = DreamTaskState.paused.rawValue
            paused.updatedAt = Date()
            try await store.saveDreamTask(paused)
            if let workspaceID = task.workspaceID {
                try? await engine(for: WorkspaceID(rawValue: workspaceID)).interrupt()
            }
            try await checkpointDreamTask(paused)
        }
        var updated = run
        updated.state = DreamRunState.paused.rawValue
        updated.abortReason = reason
        updated.updatedAt = Date()
        try await store.saveDreamRun(updated)
        dreamSchedulerState = DreamScheduler.State(phase: .pausing, runID: run.runID)
        continuation.yield(.dreamRunStateChanged(try await runSummary(updated)))
        try await publishDreamInbox()
    }

    private func resumeDreamRun() async throws {
        guard let run = try await store.activeDreamRun() else { return }
        let paused = try await store.dreamTasks(runID: run.runID).filter { $0.taskState == .paused }
        var updated = run
        updated.state = DreamRunState.dreaming.rawValue
        updated.updatedAt = Date()
        try await store.saveDreamRun(updated)
        dreamSchedulerState = DreamScheduler.State(phase: .dreaming, runID: run.runID)
        for task in paused {
            let taskID = task.taskID
            dreamWorkerTask = Task { [weak self] in
                await self?.performDreamTask(taskID: taskID)
            }
        }
        continuation.yield(.dreamRunStateChanged(try await runSummary(updated)))
    }

    private func windDownDreamRun(reason: String) async throws {
        dreamWorkerTask?.cancel()
        dreamWorkerTask = nil
        guard let run = try await store.activeDreamRun() else {
            dreamSchedulerState = DreamScheduler.State(phase: dreamSettings.enabled ? .armed : .disabled)
            return
        }
        try await interruptDreamTasks(runID: run.runID, failureReason: reason)
        try await finalizeDreamRun(run, cutoffReason: reason, taskFailed: true)
        dreamSchedulerState = DreamScheduler.State(phase: .armed)
        try await publishDreamInbox()
        notifyDreamCompletedIfNeeded(run: run)
    }

    private func interruptDreamTasks(runID: DreamRunID, failureReason: String) async throws {
        for task in try await store.dreamTasks(runID: runID)
            where task.taskState == .running || task.taskState == .paused
        {
            if let workspaceID = task.workspaceID {
                try? await engine(for: WorkspaceID(rawValue: workspaceID)).interrupt()
            }
            try await checkpointDreamTask(task)
            var failed = task
            failed.state = DreamTaskState.failed.rawValue
            failed.failureReason = failureReason
            failed.updatedAt = Date()
            try await store.saveDreamTask(failed)
        }
    }

    // MARK: - Worker

    private enum DreamTaskOutcome {
        case completed
        case paused
        case failed(String)
    }

    func performDreamTask(taskID: DreamTaskID) async {
        let outcome: DreamTaskOutcome
        do {
            outcome = try await runDreamTask(taskID: taskID)
        } catch is CancellationError {
            dreamWorkerTask = nil
            return
        } catch {
            outcome = .failed(String(describing: error))
            if var task = try? await store.dreamTask(taskID) {
                task.state = DreamTaskState.failed.rawValue
                task.failureReason = String(describing: error)
                task.updatedAt = Date()
                try? await store.saveDreamTask(task)
                if let summary = try? await taskSummary(task) {
                    continuation.yield(.dreamTaskUpdated(summary))
                }
            }
        }

        switch outcome {
        case .paused:
            break
        case .completed, .failed:
            if let finished = try? await store.dreamTask(taskID),
               let run = try? await store.dreamRun(finished.dreamRunID) {
                let cutoff: String?
                if case .failed(let reason) = outcome { cutoff = reason } else { cutoff = nil }
                try? await finalizeDreamRun(
                    run,
                    cutoffReason: cutoff,
                    taskFailed: cutoff != nil
                )
                notifyDreamCompletedIfNeeded(run: run)
            }
        }
        dreamWorkerTask = nil
        try? await publishDreamInbox()
    }

    private func runDreamTask(taskID: DreamTaskID) async throws -> DreamTaskOutcome {
        guard var task = try await store.dreamTask(taskID) else { return .failed("Missing task") }
        guard let run = try await store.dreamRun(task.dreamRunID) else { return .failed("Missing run") }

        let spent = try await store.dreamLedgerTokens(runID: run.runID)
        if spent >= run.tokenBudget, run.tokenBudget > 0 {
            task.state = DreamTaskState.failed.rawValue
            task.failureReason = "Night token cap reached"
            task.updatedAt = Date()
            try await store.saveDreamTask(task)
            return .failed("Night token cap reached")
        }

        let record: WorkspaceRecord
        let chatID: ChatID?
        let isResume: Bool
        if let existingID = task.workspaceID,
           let existing = try await store.workspace(WorkspaceID(rawValue: existingID)) {
            record = existing
            if let stored = task.chatID {
                chatID = ChatID(rawValue: stored)
            } else {
                chatID = (try await store.chats(workspaceID: record.workspaceID)).first?.chatID
            }
            isResume = true
        } else {
            record = try await createDreamWorkspace(
                repositoryPath: task.repositoryPath,
                kind: task.dreamKind,
                why: task.why
            )
            chatID = (try await store.chats(workspaceID: record.workspaceID)).first?.chatID
            isResume = false
        }

        task.state = DreamTaskState.running.rawValue
        task.workspaceID = record.id
        task.chatID = chatID?.rawValue
        task.updatedAt = Date()
        try await store.saveDreamTask(task)
        continuation.yield(.dreamTaskUpdated(try await taskSummary(task)))

        let engine = try await engine(for: record.workspaceID)
        let prompt = isResume
            ? DreamPrompts.continuation(reason: run.abortReason ?? "paused")
            : DreamPrompts.opening(
                kind: task.dreamKind,
                repositoryName: URL(fileURLWithPath: task.repositoryPath).lastPathComponent,
                why: task.why
            )
        _ = try await engine.send(SendMessageRequest(
            workspaceID: record.workspaceID,
            chatID: chatID,
            text: prompt,
            queueIfBusy: false,
            origin: .dream
        ))

        let wait = try await waitForDreamTurn(
            taskID: taskID,
            workspaceID: record.workspaceID,
            budget: run.tokenBudget,
            alreadySpent: spent
        )

        try await checkpointDreamTask(task)

        switch wait {
        case .paused:
            return .paused
        case .awaitingInput:
            try await pauseDreamRun(reason: "The agent needed a decision")
            return .paused
        case .budgetHit:
            var capped = task
            capped.state = DreamTaskState.failed.rawValue
            capped.failureReason = "Night token cap reached"
            capped.updatedAt = Date()
            try await store.saveDreamTask(capped)
            continuation.yield(.dreamTaskUpdated(try await taskSummary(capped)))
            return .failed("Night token cap reached")
        case .timedOut:
            var timedOut = task
            timedOut.state = DreamTaskState.failed.rawValue
            timedOut.failureReason = "Timed out"
            timedOut.updatedAt = Date()
            try await store.saveDreamTask(timedOut)
            continuation.yield(.dreamTaskUpdated(try await taskSummary(timedOut)))
            return .failed("Timed out")
        case .finished, .failed:
            var completed = task
            completed.state = wait == .failed
                ? DreamTaskState.failed.rawValue
                : DreamTaskState.completed.rawValue
            completed.failureReason = wait == .failed ? "The agent failed" : nil
            completed.updatedAt = Date()
            try await store.saveDreamTask(completed)
            continuation.yield(.dreamTaskUpdated(try await taskSummary(completed)))
            return wait == .failed ? .failed("The agent failed") : .completed
        }
    }

    private enum DreamWaitOutcome: Equatable {
        case finished
        case failed
        case paused
        case awaitingInput
        case budgetHit
        case timedOut
    }

    private func waitForDreamTurn(
        taskID: DreamTaskID,
        workspaceID: WorkspaceID,
        budget: Int,
        alreadySpent: Int
    ) async throws -> DreamWaitOutcome {
        let deadline = Date().addingTimeInterval(30 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            if let task = try await store.dreamTask(taskID), task.taskState == .paused {
                return .paused
            }
            let summary = await (try engine(for: workspaceID)).summary()
            switch summary.status {
            case .idle, .interrupted:
                return .finished
            case .failed:
                return .failed
            case .awaitingInput:
                try? await engine(for: workspaceID).interrupt()
                return .awaitingInput
            default:
                break
            }
            let tokens = (try? await tokenCount(for: workspaceID)) ?? 0
            if budget > 0, alreadySpent + tokens >= budget {
                try? await engine(for: workspaceID).interrupt()
                return .budgetHit
            }
            try await Task.sleep(for: .seconds(2))
        }
        try? await engine(for: workspaceID).interrupt()
        return .timedOut
    }

    private func tokenCount(for workspaceID: WorkspaceID) async throws -> Int {
        let chats = try await store.chats(workspaceID: workspaceID)
        var total = 0
        for chat in chats {
            for turn in try await store.turns(chatID: chat.chatID) {
                total += turn.inputTokens + turn.outputTokens + turn.cacheCreationTokens
            }
        }
        return total
    }

    func createDreamWorkspace(
        repositoryPath: String,
        kind: DreamKind,
        why: String
    ) async throws -> WorkspaceRecord {
        let repositoryURL = try await canonicalRepositoryURL(repositoryPath)
        guard try await store.repositories().contains(where: { $0.path == repositoryURL.path })
        else {
            throw OreCoreError.repositoryNotFound(repositoryURL.path)
        }
        let git = try gitClient(for: repositoryURL.path)
        let configuration = OreConfiguration.load(repositoryPath: repositoryURL)
        let defaultBranch = await git.defaultBranch()
        let day: String = {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: Date())
        }()
        let repoSlug = Slug.make(repositoryURL.lastPathComponent)
        let name = "dream-\(kind.rawValue)-\(repoSlug)-\(day)"

        let manager = WorktreeManager(git: git, root: worktreeRoot)
        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: name,
            branchPrefix: "ore/dream",
            baseRevision: defaultBranch,
            baseBranch: defaultBranch,
            filesToCopy: dreamSettings.copySecrets ? configuration.filesToCopy : []
        ))

        let record = WorkspaceRecord(
            id: WorkspaceID.generate(),
            name: "Dream · \(kind.displayName) · \(repositoryURL.lastPathComponent)",
            repositoryPath: repositoryURL.path,
            worktreePath: worktree.path.path,
            branch: worktree.branch,
            baseBranch: worktree.baseBranch,
            harness: dreamSettings.defaultHarness,
            model: dreamSettings.defaultModel ?? configuration.defaultModel,
            permissionMode: .plan,
            isNameUserSet: true,
            kind: .dream
        )
        try await store.saveWorkspace(record)
        _ = try await store.ensureDefaultChat(for: record)
        let engine = try await makeEngine(for: record)
        markListMutation()
        continuation.yield(.workspaceAdded(await engine.summary()))
        _ = why
        return record
    }

    private func checkpointDreamTask(_ task: DreamTaskRecord) async throws {
        guard let workspaceID = task.workspaceID,
              let workspace = try await store.workspace(WorkspaceID(rawValue: workspaceID))
        else { return }
        try await ingestDreamFindings(task: task, workspace: workspace)
        let tokens = (try? await tokenCount(for: workspace.workspaceID)) ?? 0
        if tokens > task.tokensUsed {
            try await store.appendDreamLedger(DreamLedgerRecord(
                runID: task.dreamRunID,
                taskID: task.taskID,
                harness: HarnessKind(rawValue: workspace.harness) ?? dreamSettings.defaultHarness,
                tokens: tokens - task.tokensUsed,
                turns: 1
            ))
            var billed = task
            billed.tokensUsed = tokens
            billed.turnCount = max(task.turnCount, 1)
            billed.updatedAt = Date()
            try await store.saveDreamTask(billed)
        }
    }

    private func ingestDreamFindings(task: DreamTaskRecord, workspace: WorkspaceRecord) async throws {
        let worktree = URL(fileURLWithPath: workspace.worktreePath)
        let posted = Array(DreamFindingFile.load(in: worktree).prefix(3))
        let diff = await ReviewDiff.unifiedText(in: worktree)
        let repoName = URL(fileURLWithPath: task.repositoryPath).lastPathComponent

        for posted in posted {
            let title = posted.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let files = (posted.evidence ?? []).compactMap(\.path)
            let key = Self.dedupeKey(
                kind: posted.kind ?? task.kind,
                repositoryPath: task.repositoryPath,
                title: title,
                files: files
            )
            let confidence = min(1, max(0, posted.confidence ?? 0.5))
            let findingKind = DreamFindingKind(rawValue: posted.kind ?? "")
                ?? task.dreamKind.findingKind
            let severity = DreamFindingSeverity(rawValue: posted.severity ?? "") ?? .info
            let evidenceJSON = (try? String(
                data: JSONEncoder().encode(posted.evidence ?? []), encoding: .utf8
            )) ?? "[]"

            if var existing = try await store.dreamFinding(dedupeKey: key) {
                existing.lastSeenAt = Date()
                existing.confidence = confidence
                existing.summary = posted.summary
                existing.evidenceJSON = evidenceJSON
                if existing.status == DreamFindingStatus.expired.rawValue {
                    existing.status = DreamFindingStatus.new.rawValue
                }
                try await store.saveDreamFinding(existing)
                continuation.yield(.dreamFindingUpdated(findingSummary(existing, repositoryName: repoName)))
                continue
            }

            let record = DreamFindingRecord(
                id: DreamFindingID.generate(),
                taskID: task.taskID,
                runID: task.dreamRunID,
                repositoryPath: task.repositoryPath,
                kind: findingKind,
                title: title,
                summary: posted.summary,
                evidenceJSON: evidenceJSON,
                confidence: confidence,
                severity: severity,
                branchName: workspace.branch,
                diffSnapshot: diff.isEmpty ? nil : diff,
                dedupeKey: key,
                why: task.why,
                workspaceID: workspace.workspaceID,
                chatID: task.chatID.map(ChatID.init(rawValue:))
            )
            try await store.saveDreamFinding(record)
            continuation.yield(.dreamFindingAdded(findingSummary(record, repositoryName: repoName)))
        }
    }

    static func dedupeKey(
        kind: String,
        repositoryPath: String,
        title: String,
        files: [String]
    ) -> String {
        let normalized = title.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileKey = files.sorted().joined(separator: ",")
        return "\(kind)|\(repositoryPath)|\(normalized)|\(fileKey)"
    }

    private func notifyDreamCompletedIfNeeded(run: DreamRunRecord) {
        _ = run
    }

    // MARK: - Accept / janitor / reports

    private func materializeAcceptedFinding(_ record: DreamFindingRecord) async throws {
        let summary = findingSummary(record)
        let name = String(record.title.prefix(48))
        _ = try await createWorkspace(CreateWorkspaceRequest(
            repositoryPath: record.repositoryPath,
            name: name,
            seed: .defaultBranch,
            harness: dreamSettings.defaultHarness,
            model: dreamSettings.defaultModel,
            initialPrompt: DreamPrompts.acceptedFindingPrompt(summary),
            promptOrigin: .user
        ))
    }

    private func finalizeDreamRun(
        _ run: DreamRunRecord,
        cutoffReason: String?,
        taskFailed: Bool
    ) async throws {
        let findings = try await store.dreamFindings(runID: run.runID)
        let hasFindings = !findings.isEmpty
        var updated = run
        if let cutoffReason {
            updated.abortReason = cutoffReason
            updated.state = hasFindings
                ? DreamRunState.completed.rawValue
                : DreamRunState.interrupted.rawValue
        } else if taskFailed {
            updated.state = hasFindings
                ? DreamRunState.completed.rawValue
                : DreamRunState.interrupted.rawValue
        } else {
            updated.state = DreamRunState.completed.rawValue
        }
        updated.updatedAt = Date()
        try await store.saveDreamRun(updated)
        try await writeDreamReport(updated, cutoffReason: cutoffReason)
        dreamSchedulerState = DreamScheduler.State(
            phase: dreamSettings.enabled ? .armed : .disabled
        )
        continuation.yield(.dreamRunStateChanged(try await runSummary(updated)))
    }

    private func writeDreamReport(_ run: DreamRunRecord, cutoffReason: String?) async throws {
        let tasks = try await store.dreamTasks(runID: run.runID)
        let findings = try await store.dreamFindings(runID: run.runID)
        let tokens = try await store.dreamLedgerTokens(runID: run.runID)
        let report = DreamRunReport(
            tokensUsed: tokens,
            tokenBudget: run.tokenBudget,
            findingCount: findings.count,
            taskStates: tasks.map(\.state),
            cutoffReason: cutoffReason,
            parkedUntil: parkedUntil(for: dreamSettings.defaultHarness, now: Date())
        )
        var updated = run
        updated.reportJSON = (try? String(data: JSONEncoder().encode(report), encoding: .utf8))
        updated.updatedAt = Date()
        try await store.saveDreamRun(updated)
    }

    private func maintainDreamInbox(now: Date = Date()) async throws {
        try await store.resurfaceDeferredDreamFindings(now: now)
        try await store.expireStaleDreamFindings(now: now)
        try await collectExpiredDreamWorktrees(now: now)
    }

    private func collectExpiredDreamWorktrees(now: Date) async throws {
        if let active = try await store.activeDreamRun() {
            let activeIDs = Set(
                (try await store.dreamTasks(runID: active.runID))
                    .compactMap(\.workspaceID)
            )
            try await collectDreamWorktrees(now: now, skipping: activeIDs)
        } else {
            try await collectDreamWorktrees(now: now, skipping: [])
        }
    }

    private func collectDreamWorktrees(now: Date, skipping: Set<String>) async throws {
        let grace = now.addingTimeInterval(-DreamRetention.worktreeGrace)
        let liveStatuses: Set<String> = [
            DreamFindingStatus.new.rawValue,
            DreamFindingStatus.deferred.rawValue,
        ]
        let keep = Set(
            (try await store.dreamFindings(statuses: [.new, .deferred]))
                .compactMap(\.workspaceID)
        )
        let workspaces = try await store.workspaces(includeArchived: false, includeAssistant: true)
        for workspace in workspaces where workspace.workspaceKind == .dream {
            guard !skipping.contains(workspace.id) else { continue }
            guard workspace.createdAt < grace else { continue }
            guard !keep.contains(workspace.id) else { continue }
            let related = try await store.dreamFindings().filter { $0.workspaceID == workspace.id }
            if related.contains(where: { liveStatuses.contains($0.status) }) { continue }
            try? await deleteWorkspace(workspace.workspaceID, deleteBranch: true)
        }
    }

    private func parkedUntil(for harness: HarnessKind, now: Date) -> Date? {
        guard let until = dreamHarnessParkedUntil[harness] else { return nil }
        if now >= until {
            dreamHarnessParkedUntil[harness] = nil
            return nil
        }
        return until
    }

    private func parkedDetail(_ date: Date) -> String {
        "Parked until \(date.formatted(date: .omitted, time: .shortened))."
    }

    // MARK: - Mapping

    func dreamInboxSnapshot() async throws -> DreamInboxSnapshot {
        let run = try await store.latestDreamRun()
        let tasks: [DreamTaskSummary]
        if let run {
            var mapped: [DreamTaskSummary] = []
            for record in try await store.dreamTasks(runID: run.runID) {
                mapped.append(try await taskSummary(record))
            }
            tasks = mapped
        } else {
            tasks = []
        }
        let findings = try await store.dreamFindings(statuses: [
            .new, .accepted, .rejected, .deferred,
        ]).map { findingSummary($0) }
        let recommendation = try await store.quietHoursRecommendation()
        let runSummaryValue: DreamRunSummary?
        if let run {
            runSummaryValue = try await runSummary(run)
        } else {
            runSummaryValue = nil
        }
        return DreamInboxSnapshot(
            run: runSummaryValue,
            tasks: tasks,
            findings: findings,
            quietHoursRecommendation: recommendation
        )
    }

    private func runSummary(_ record: DreamRunRecord) async throws -> DreamRunSummary {
        let tokens = try await store.dreamLedgerTokens(runID: record.runID)
        return runSummary(record, tokensUsed: tokens)
    }

    private func runSummary(_ record: DreamRunRecord, tokensUsed: Int) -> DreamRunSummary {
        DreamRunSummary(
            id: record.runID,
            state: record.runState,
            trigger: record.runTrigger,
            scheduledFor: record.scheduledFor,
            why: record.why,
            tokensUsed: tokensUsed,
            tokenBudget: record.tokenBudget,
            abortReason: record.abortReason
        )
    }

    private func taskSummary(_ record: DreamTaskRecord) async throws -> DreamTaskSummary {
        DreamTaskSummary(
            id: record.taskID,
            runID: record.dreamRunID,
            repositoryPath: record.repositoryPath,
            repositoryName: URL(fileURLWithPath: record.repositoryPath).lastPathComponent,
            kind: record.dreamKind,
            state: record.taskState,
            why: record.why,
            workspaceID: record.workspaceID.map(WorkspaceID.init(rawValue:)),
            chatID: record.chatID.map(ChatID.init(rawValue:)),
            tokensUsed: record.tokensUsed,
            failureReason: record.failureReason
        )
    }

    private func findingSummary(
        _ record: DreamFindingRecord,
        repositoryName: String? = nil
    ) -> DreamFindingSummary {
        DreamFindingSummary(
            id: record.findingID,
            runID: DreamRunID(rawValue: record.runID),
            taskID: DreamTaskID(rawValue: record.taskID),
            repositoryPath: record.repositoryPath,
            repositoryName: repositoryName
                ?? URL(fileURLWithPath: record.repositoryPath).lastPathComponent,
            kind: DreamFindingKind(rawValue: record.kind) ?? .issue,
            title: record.title,
            summary: record.summary,
            evidence: record.evidence,
            confidence: record.confidence,
            severity: DreamFindingSeverity(rawValue: record.severity) ?? .info,
            status: DreamFindingStatus(rawValue: record.status) ?? .new,
            why: record.why,
            diffSnapshot: record.diffSnapshot,
            workspaceID: record.workspaceID.map(WorkspaceID.init(rawValue:)),
            chatID: record.chatID.map(ChatID.init(rawValue:)),
            createdAt: record.createdAt,
            lastSeenAt: record.lastSeenAt
        )
    }
}
