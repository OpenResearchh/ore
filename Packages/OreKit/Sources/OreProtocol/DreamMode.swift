import Foundation

// MARK: - Kinds

/// What a dream is allowed to do. Research kinds are read-only; anything that
/// edits or executes is opt-in and later-phase.
public enum DreamKind: String, Sendable, Codable, CaseIterable, Hashable {
    case review
    case bugHunt
    case dependencyAudit
    case featureIdeas
    case testRun
    case fix
    case appExplore

    /// Research kinds the planner may schedule. Action kinds stay in the enum
    /// so findings do not need a migration when they turn on.
    public var isMVP: Bool {
        switch self {
        case .review, .bugHunt, .dependencyAudit, .featureIdeas: true
        default: false
        }
    }

    public var displayName: String {
        switch self {
        case .review: "Code review"
        case .bugHunt: "Bug hunt"
        case .dependencyAudit: "Dependency audit"
        case .featureIdeas: "Feature ideas"
        case .testRun: "Test run"
        case .fix: "Prepare a fix"
        case .appExplore: "Explore the app"
        }
    }

    public var findingKind: DreamFindingKind {
        switch self {
        case .review: .issue
        case .bugHunt: .bug
        case .dependencyAudit: .dependencyIssue
        case .featureIdeas: .featureProposal
        case .testRun: .testFailure
        case .fix: .fixPrepared
        case .appExplore: .insight
        }
    }
}

public enum DreamFindingKind: String, Sendable, Codable, Hashable {
    case issue
    case bug
    case dependencyIssue
    case featureProposal
    case testFailure
    case fixPrepared
    case insight
}

public enum DreamFindingSeverity: String, Sendable, Codable, Hashable {
    case info
    case warning
    case error
}

public enum DreamRunState: String, Sendable, Codable, Hashable {
    case planned
    case dreaming
    case paused
    case windingDown
    case completed
    case aborted
    case interrupted
}

public enum DreamTaskState: String, Sendable, Codable, Hashable {
    case pending
    case running
    case paused
    case completed
    case failed
}

public enum DreamFindingStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case new
    case accepted
    case rejected
    case deferred
    case expired
}

public enum DreamRunTrigger: String, Sendable, Codable, Hashable {
    case schedule
    case manual
}

public enum DreamRejectReason: String, Sendable, Codable, Hashable, CaseIterable {
    case wrong
    case alreadyKnown
    case dontCare

    public var displayName: String {
        switch self {
        case .wrong: "Wrong"
        case .alreadyKnown: "Already known"
        case .dontCare: "Don't care"
        }
    }
}

public enum DreamDeferral: String, Sendable, Codable, Hashable {
    case tonight
    case nextWeek
}

public enum DreamFindingResolution: Sendable, Codable, Hashable {
    case accept
    case reject(DreamRejectReason)
    case snooze(DreamDeferral)
}

// MARK: - Settings & environment

/// What the Mac app persists in UserDefaults and pushes into the core. The
/// core never reads AppKit or UserDefaults.
public struct DreamSettings: Sendable, Codable, Equatable {
    public var enabled: Bool
    /// Minutes from midnight. Default 01:00.
    public var quietHoursStartMinutes: Int
    /// Minutes from midnight. Default 07:00.
    public var quietHoursEndMinutes: Int
    public var idleMinutes: Int
    public var requireACPower: Bool
    /// Hold an idle-sleep assertion during quiet hours / an active dream,
    /// but only while plugged in. Never on battery.
    public var preventSleep: Bool
    public var nightTokenCap: Int
    /// Fraction of the night cap reserved for morning work. 0.25 means dreams
    /// may spend 75% of `nightTokenCap`.
    public var headroomFraction: Double
    public var copySecrets: Bool
    public var excludedRepoPaths: [String]
    public var defaultHarness: HarnessKind
    public var defaultModel: String?

    public static let `default` = DreamSettings()

    public init(
        enabled: Bool = false,
        quietHoursStartMinutes: Int = 60,
        quietHoursEndMinutes: Int = 7 * 60,
        idleMinutes: Int = 20,
        requireACPower: Bool = true,
        preventSleep: Bool = false,
        nightTokenCap: Int = 50_000,
        headroomFraction: Double = 0.25,
        copySecrets: Bool = false,
        excludedRepoPaths: [String] = [],
        defaultHarness: HarnessKind = .claudeCode,
        defaultModel: String? = nil
    ) {
        self.enabled = enabled
        self.quietHoursStartMinutes = quietHoursStartMinutes
        self.quietHoursEndMinutes = quietHoursEndMinutes
        self.idleMinutes = idleMinutes
        self.requireACPower = requireACPower
        self.preventSleep = preventSleep
        self.nightTokenCap = nightTokenCap
        self.headroomFraction = headroomFraction
        self.copySecrets = copySecrets
        self.excludedRepoPaths = excludedRepoPaths
        self.defaultHarness = defaultHarness
        self.defaultModel = defaultModel
    }

    /// Tokens dreams may actually spend tonight.
    public var effectiveTokenBudget: Int {
        let reserved = max(0, min(1, headroomFraction))
        return Int(Double(max(0, nightTokenCap)) * (1 - reserved))
    }
}

/// App-side sensors, pushed every ~30s. OreCore stays AppKit-free.
public struct DreamEnvironmentSnapshot: Sendable, Codable, Equatable {
    public var secondsSinceInput: TimeInterval
    public var lastSeenAt: Date?
    public var now: Date
    public var isOnACPower: Bool
    public var thermalPressure: Bool
    /// The Mac is about to sleep. Sandman should checkpoint and wind down.
    public var isSleepImminent: Bool

    public init(
        secondsSinceInput: TimeInterval,
        lastSeenAt: Date? = nil,
        now: Date = Date(),
        isOnACPower: Bool = true,
        thermalPressure: Bool = false,
        isSleepImminent: Bool = false
    ) {
        self.secondsSinceInput = secondsSinceInput
        self.lastSeenAt = lastSeenAt
        self.now = now
        self.isOnACPower = isOnACPower
        self.thermalPressure = thermalPressure
        self.isSleepImminent = isSleepImminent
    }
}

// MARK: - Sleep UX (computed in the app from settings + environment)

public enum DreamSleepStatus: String, Sendable, Codable, Hashable {
    /// Overnight dreams will likely never start because the Mac sleeps.
    case macMaySleep
    /// Keep-awake is on, but we're on battery so it is not held.
    case keepAwakePausedOnBattery
    /// Assertion is (or will be) held on AC.
    case keepAwakeActive
    /// Plugged in, keep-awake off — user chose opportunistic dreaming.
    case opportunistic
    /// Dreaming is off entirely.
    case disabled
}

// MARK: - Summaries

public struct DreamEvidence: Sendable, Codable, Hashable {
    public var path: String?
    public var line: Int?
    public var note: String?

    public init(path: String? = nil, line: Int? = nil, note: String? = nil) {
        self.path = path
        self.line = line
        self.note = note
    }
}

public struct DreamRunSummary: Sendable, Codable, Hashable, Identifiable {
    public var id: DreamRunID
    public var state: DreamRunState
    public var trigger: DreamRunTrigger
    public var scheduledFor: Date
    public var why: String
    public var tokensUsed: Int
    public var tokenBudget: Int
    public var abortReason: String?

    public init(
        id: DreamRunID,
        state: DreamRunState,
        trigger: DreamRunTrigger,
        scheduledFor: Date,
        why: String,
        tokensUsed: Int = 0,
        tokenBudget: Int = 0,
        abortReason: String? = nil
    ) {
        self.id = id
        self.state = state
        self.trigger = trigger
        self.scheduledFor = scheduledFor
        self.why = why
        self.tokensUsed = tokensUsed
        self.tokenBudget = tokenBudget
        self.abortReason = abortReason
    }
}

public struct DreamTaskSummary: Sendable, Codable, Hashable, Identifiable {
    public var id: DreamTaskID
    public var runID: DreamRunID
    public var repositoryPath: String
    public var repositoryName: String
    public var kind: DreamKind
    public var state: DreamTaskState
    public var why: String
    public var workspaceID: WorkspaceID?
    public var chatID: ChatID?
    public var tokensUsed: Int
    public var failureReason: String?

    public init(
        id: DreamTaskID,
        runID: DreamRunID,
        repositoryPath: String,
        repositoryName: String,
        kind: DreamKind,
        state: DreamTaskState,
        why: String,
        workspaceID: WorkspaceID? = nil,
        chatID: ChatID? = nil,
        tokensUsed: Int = 0,
        failureReason: String? = nil
    ) {
        self.id = id
        self.runID = runID
        self.repositoryPath = repositoryPath
        self.repositoryName = repositoryName
        self.kind = kind
        self.state = state
        self.why = why
        self.workspaceID = workspaceID
        self.chatID = chatID
        self.tokensUsed = tokensUsed
        self.failureReason = failureReason
    }
}

public struct DreamFindingSummary: Sendable, Codable, Hashable, Identifiable {
    public var id: DreamFindingID
    public var runID: DreamRunID
    public var taskID: DreamTaskID
    public var repositoryPath: String
    public var repositoryName: String
    public var kind: DreamFindingKind
    public var title: String
    public var summary: String
    public var evidence: [DreamEvidence]
    public var confidence: Double
    public var severity: DreamFindingSeverity
    public var status: DreamFindingStatus
    public var why: String
    public var diffSnapshot: String?
    public var workspaceID: WorkspaceID?
    public var chatID: ChatID?
    public var createdAt: Date
    public var lastSeenAt: Date

    public init(
        id: DreamFindingID,
        runID: DreamRunID,
        taskID: DreamTaskID,
        repositoryPath: String,
        repositoryName: String,
        kind: DreamFindingKind,
        title: String,
        summary: String,
        evidence: [DreamEvidence] = [],
        confidence: Double,
        severity: DreamFindingSeverity,
        status: DreamFindingStatus,
        why: String,
        diffSnapshot: String? = nil,
        workspaceID: WorkspaceID? = nil,
        chatID: ChatID? = nil,
        createdAt: Date = Date(),
        lastSeenAt: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.taskID = taskID
        self.repositoryPath = repositoryPath
        self.repositoryName = repositoryName
        self.kind = kind
        self.title = title
        self.summary = summary
        self.evidence = evidence
        self.confidence = confidence
        self.severity = severity
        self.status = status
        self.why = why
        self.diffSnapshot = diffSnapshot
        self.workspaceID = workspaceID
        self.chatID = chatID
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }
}

public struct QuietHoursRecommendation: Sendable, Codable, Equatable {
    public var startMinutes: Int
    public var endMinutes: Int
    public var reason: String

    public init(startMinutes: Int, endMinutes: Int, reason: String) {
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.reason = reason
    }
}

public struct DreamInboxSnapshot: Sendable, Codable, Equatable {
    public var run: DreamRunSummary?
    public var tasks: [DreamTaskSummary]
    public var findings: [DreamFindingSummary]
    public var quietHoursRecommendation: QuietHoursRecommendation?

    public init(
        run: DreamRunSummary? = nil,
        tasks: [DreamTaskSummary] = [],
        findings: [DreamFindingSummary] = [],
        quietHoursRecommendation: QuietHoursRecommendation? = nil
    ) {
        self.run = run
        self.tasks = tasks
        self.findings = findings
        self.quietHoursRecommendation = quietHoursRecommendation
    }

    public var newFindingCount: Int {
        findings.filter { $0.status == .new }.count
    }
}

/// Posted by the agent via MCP into `.context/ore-dream-findings.json`.
public struct PostedDreamFinding: Sendable, Codable, Hashable {
    public var kind: String?
    public var title: String
    public var summary: String
    public var confidence: Double?
    public var severity: String?
    public var evidence: [DreamEvidence]?

    public init(
        kind: String? = nil,
        title: String,
        summary: String,
        confidence: Double? = nil,
        severity: String? = nil,
        evidence: [DreamEvidence]? = nil
    ) {
        self.kind = kind
        self.title = title
        self.summary = summary
        self.confidence = confidence
        self.severity = severity
        self.evidence = evidence
    }
}

// MARK: - Planner inputs

public struct DreamRepositoryActivity: Sendable, Hashable {
    public var repositoryPath: String
    public var repositoryName: String
    public var turnCount: Int
    public var lastTurnAt: Date?
    public var isPinned: Bool

    public init(
        repositoryPath: String,
        repositoryName: String,
        turnCount: Int,
        lastTurnAt: Date?,
        isPinned: Bool
    ) {
        self.repositoryPath = repositoryPath
        self.repositoryName = repositoryName
        self.turnCount = turnCount
        self.lastTurnAt = lastTurnAt
        self.isPinned = isPinned
    }
}

/// Laplace-smoothed accept/reject counts for one (repo × kind) pair.
public struct DreamKindAcceptance: Sendable, Hashable {
    public var repositoryPath: String
    public var kind: DreamKind
    public var accepted: Int
    public var rejected: Int

    public init(
        repositoryPath: String,
        kind: DreamKind,
        accepted: Int,
        rejected: Int
    ) {
        self.repositoryPath = repositoryPath
        self.kind = kind
        self.accepted = accepted
        self.rejected = rejected
    }

    /// `(accepted + 1) / (resolved + 2)`. Unseen pairs are 0.5.
    public var rate: Double {
        Double(accepted + 1) / Double(accepted + rejected + 2)
    }
}

/// Written onto `dreamRun.reportJSON` when a run finishes or is cut off.
public struct DreamRunReport: Sendable, Codable, Hashable {
    public var tokensUsed: Int
    public var tokenBudget: Int
    public var findingCount: Int
    public var taskStates: [String]
    public var cutoffReason: String?
    public var parkedUntil: Date?

    public init(
        tokensUsed: Int,
        tokenBudget: Int,
        findingCount: Int,
        taskStates: [String],
        cutoffReason: String? = nil,
        parkedUntil: Date? = nil
    ) {
        self.tokensUsed = tokensUsed
        self.tokenBudget = tokenBudget
        self.findingCount = findingCount
        self.taskStates = taskStates
        self.cutoffReason = cutoffReason
        self.parkedUntil = parkedUntil
    }
}

public enum DreamRetention {
    public static let findingDays: TimeInterval = 14 * 24 * 3600
    public static let worktreeGrace: TimeInterval = 24 * 3600
    /// Skip a kind when Laplace-smoothed acceptance falls below this.
    public static let noisyKindRate: Double = 0.3
}
