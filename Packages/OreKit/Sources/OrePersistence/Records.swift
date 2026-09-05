import Foundation
import GRDB
import OreProtocol

// Row types. Deliberately flat and close to the schema: the richer domain types
// live in OreProtocol, and mapping between the two happens in one place rather
// than being smeared across queries.

public struct RepositoryRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "repository"

    public var path: String
    public var name: String
    public var defaultBranch: String
    public var addedAt: Date

    public init(path: String, name: String, defaultBranch: String, addedAt: Date = Date()) {
        self.path = path
        self.name = name
        self.defaultBranch = defaultBranch
        self.addedAt = addedAt
    }
}

public struct WorkspaceRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "workspace"

    public var id: String
    public var name: String
    public var repositoryPath: String
    public var worktreePath: String
    public var branch: String
    public var baseBranch: String
    public var stackedOnWorkspaceID: String?
    public var harness: String
    public var model: String?
    public var permissionMode: String
    public var isPinned: Bool
    public var isArchived: Bool
    /// Commit holding uncommitted work preserved at archive time.
    public var archivedStateCommit: String?
    public var archivedAt: Date?
    /// Worktree size at archive time — the disk space the archive reclaimed.
    /// Recorded then because the checkout no longer exists to measure later.
    public var archivedDiskBytes: Int64?
    public var hasUnread: Bool
    public var sortIndex: Int
    public var createdAt: Date
    public var lastActivityAt: Date?
    /// The user typed this name. When set, automatic research-identity and
    /// first-prompt renaming leave it alone.
    public var isNameUserSet: Bool
    /// `standard`, `assistant`, or `dream` — see `WorkspaceKind`. A column
    /// rather than a flag so a new kind never means a second migration of the
    /// same shape.
    public var kind: String

    public init(
        id: WorkspaceID,
        name: String,
        repositoryPath: String,
        worktreePath: String,
        branch: String,
        baseBranch: String,
        stackedOnWorkspaceID: WorkspaceID? = nil,
        harness: HarnessKind,
        model: String? = nil,
        permissionMode: PermissionMode = .default,
        isPinned: Bool = false,
        isArchived: Bool = false,
        archivedStateCommit: String? = nil,
        archivedAt: Date? = nil,
        archivedDiskBytes: Int64? = nil,
        hasUnread: Bool = false,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        lastActivityAt: Date? = nil,
        isNameUserSet: Bool = false,
        kind: WorkspaceKind = .standard
    ) {
        self.id = id.rawValue
        self.name = name
        self.repositoryPath = repositoryPath
        self.worktreePath = worktreePath
        self.branch = branch
        self.baseBranch = baseBranch
        self.stackedOnWorkspaceID = stackedOnWorkspaceID?.rawValue
        self.harness = harness.rawValue
        self.model = model
        self.permissionMode = permissionMode.rawValue
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.archivedStateCommit = archivedStateCommit
        self.archivedAt = archivedAt
        self.archivedDiskBytes = archivedDiskBytes
        self.hasUnread = hasUnread
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.isNameUserSet = isNameUserSet
        self.kind = kind.rawValue
    }

    public var workspaceID: WorkspaceID { WorkspaceID(rawValue: id) }

    public var workspaceKind: WorkspaceKind { WorkspaceKind(rawValue: kind) ?? .standard }

    /// The sidebar row for this workspace. Live state — status, git counts —
    /// is layered on by the engine, since it changes far faster than anything
    /// worth writing to disk.
    public func summary(
        status: AgentStatus = .idle,
        gitStatus: GitStatusSummary = GitStatusSummary(),
        contextUsage: UsageReport? = nil,
        baseSync: BaseSyncStatus? = nil
    ) -> WorkspaceSummary {
        WorkspaceSummary(
            id: workspaceID,
            name: name,
            repositoryPath: repositoryPath,
            worktreePath: worktreePath,
            branch: branch,
            baseBranch: baseBranch,
            stackedOn: stackedOnWorkspaceID.map(WorkspaceID.init(rawValue:)),
            harness: HarnessKind(rawValue: harness) ?? .claudeCode,
            model: model,
            status: status,
            permissionMode: PermissionMode(rawValue: permissionMode) ?? .default,
            hasUnread: hasUnread,
            isPinned: isPinned,
            isArchived: isArchived,
            archivedAt: archivedAt,
            archivedDiskBytes: archivedDiskBytes,
            gitStatus: gitStatus,
            contextUsage: contextUsage,
            lastActivity: lastActivityAt,
            baseSync: baseSync,
            kind: workspaceKind
        )
    }
}

public struct SessionRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "session"

    public var id: String
    public var workspaceID: String
    public var chatID: String?
    public var providerSessionID: String?
    public var harness: String
    public var model: String?
    public var harnessVersion: String?
    public var title: String?
    public var startedAt: Date
    public var endedAt: Date?

    public init(
        id: SessionID,
        workspaceID: WorkspaceID,
        chatID: ChatID? = nil,
        providerSessionID: String? = nil,
        harness: HarnessKind,
        model: String? = nil,
        harnessVersion: String? = nil,
        title: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil
    ) {
        self.id = id.rawValue
        self.workspaceID = workspaceID.rawValue
        self.chatID = chatID?.rawValue
        self.providerSessionID = providerSessionID
        self.harness = harness.rawValue
        self.model = model
        self.harnessVersion = harnessVersion
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct ChatRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "chat"

    public var id: String
    public var workspaceID: String
    public var title: String
    public var harness: String
    public var model: String?
    public var permissionMode: String
    public var draftText: String
    public var hasUnread: Bool
    public var isClosed: Bool
    public var sortIndex: Int
    public var createdAt: Date
    public var lastActivityAt: Date?
    /// The user typed this title. When set, the first message's auto-titling
    /// leaves it alone.
    public var isTitleUserSet: Bool
    /// Last requested reasoning depth for this chat. Nil means the composer
    /// (or the harness default) decides per send.
    public var reasoningEffort: String?
    /// A summary of the conversation this chat continues, staged for the model
    /// and cleared once a message has actually carried it. Nil for every chat
    /// that isn't the successor of a compaction.
    public var seedContext: String?

    public init(
        id: ChatID,
        workspaceID: WorkspaceID,
        title: String,
        harness: HarnessKind,
        model: String? = nil,
        permissionMode: PermissionMode = .default,
        draftText: String = "",
        hasUnread: Bool = false,
        isClosed: Bool = false,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        lastActivityAt: Date? = nil,
        isTitleUserSet: Bool = false,
        reasoningEffort: ReasoningEffort? = nil,
        seedContext: String? = nil
    ) {
        self.id = id.rawValue
        self.workspaceID = workspaceID.rawValue
        self.title = title
        self.harness = harness.rawValue
        self.model = model
        self.permissionMode = permissionMode.rawValue
        self.draftText = draftText
        self.hasUnread = hasUnread
        self.isClosed = isClosed
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.isTitleUserSet = isTitleUserSet
        self.reasoningEffort = reasoningEffort?.rawValue
        self.seedContext = seedContext
    }

    public var chatID: ChatID { ChatID(rawValue: id) }
    public var workspaceIdentifier: WorkspaceID { WorkspaceID(rawValue: workspaceID) }

    public func summary(
        status: AgentStatus = .idle,
        capabilities: HarnessCapabilities = HarnessCapabilities(),
        queuedMessageCount: Int = 0,
        isTurnActive: Bool = false,
        contextUsage: UsageReport? = nil,
        turnCount: Int = 0
    ) -> ChatSummary {
        ChatSummary(
            id: chatID,
            workspaceID: workspaceIdentifier,
            title: title,
            harness: HarnessKind(rawValue: harness) ?? .claudeCode,
            model: model,
            permissionMode: PermissionMode(rawValue: permissionMode) ?? .default,
            status: status,
            capabilities: capabilities,
            hasUnread: hasUnread,
            isClosed: isClosed,
            draftText: draftText,
            queuedMessageCount: queuedMessageCount,
            isTurnActive: isTurnActive,
            contextUsage: contextUsage,
            turnCount: turnCount,
            createdAt: createdAt,
            lastActivity: lastActivityAt,
            reasoningEffort: reasoningEffort.flatMap(ReasoningEffort.init(rawValue:))
        )
    }
}

public struct ChatTransitionRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "chatTransition"

    public var id: String
    public var chatID: String
    public var kind: String
    public var fromHarness: String?
    public var toHarness: String?
    public var fromModel: String?
    public var toModel: String?
    public var createdAt: Date

    public init(_ transition: ChatTransition) {
        id = transition.id
        chatID = transition.chatID.rawValue
        kind = transition.kind.rawValue
        fromHarness = transition.fromHarness?.rawValue
        toHarness = transition.toHarness?.rawValue
        fromModel = transition.fromModel
        toModel = transition.toModel
        createdAt = transition.createdAt
    }

    public var transition: ChatTransition {
        ChatTransition(
            id: id,
            chatID: ChatID(rawValue: chatID),
            kind: ChatTransition.Kind(rawValue: kind) ?? .modelChanged,
            fromHarness: fromHarness.flatMap(HarnessKind.init(rawValue:)),
            toHarness: toHarness.flatMap(HarnessKind.init(rawValue:)),
            fromModel: fromModel,
            toModel: toModel,
            createdAt: createdAt
        )
    }
}

public struct TurnRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "turn"

    public var id: String
    public var sessionID: String
    public var ordinal: Int
    public var prompt: String?
    public var outcome: String?
    public var summary: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int
    public var contextWindow: Int?
    public var checkpointCommit: String?
    public var checkpointProviderSessionID: String?
    public var promptAttachments: String = "[]"
    public var promptOrigin: String = MessageOrigin.user.rawValue
    public var startedAt: Date
    public var endedAt: Date?

    public init(
        id: TurnID,
        sessionID: SessionID,
        ordinal: Int,
        prompt: String? = nil,
        outcome: TurnResult.Outcome? = nil,
        summary: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        contextWindow: Int? = nil,
        checkpointCommit: String? = nil,
        checkpointProviderSessionID: String? = nil,
        attachments: [Attachment] = [],
        origin: MessageOrigin = .user,
        startedAt: Date = Date(),
        endedAt: Date? = nil
    ) {
        self.id = id.rawValue
        self.sessionID = sessionID.rawValue
        self.ordinal = ordinal
        self.prompt = prompt
        self.outcome = outcome?.rawValue
        self.summary = summary
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.contextWindow = contextWindow
        self.checkpointCommit = checkpointCommit
        self.checkpointProviderSessionID = checkpointProviderSessionID
        self.promptAttachments = Self.encodeAttachments(attachments)
        self.promptOrigin = origin.rawValue
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public var attachments: [Attachment] {
        Self.decodeAttachments(promptAttachments)
    }

    /// Falls back to the user rather than refusing to render: an unreadable
    /// origin should cost a badge, not the prompt itself.
    public var origin: MessageOrigin {
        MessageOrigin(rawValue: promptOrigin) ?? .user
    }

    private static func encodeAttachments(_ attachments: [Attachment]) -> String {
        (try? JSONEncoder().encode(attachments))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    private static func decodeAttachments(_ raw: String) -> [Attachment] {
        guard let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Attachment].self, from: data)) ?? []
    }

    public var turnID: TurnID { TurnID(rawValue: id) }

    public var usage: UsageReport {
        UsageReport(
            turnID: turnID,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            contextWindow: contextWindow
        )
    }
}

public struct BlockRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "block"

    public enum Kind: String, Codable, Sendable {
        case text
        case thinking
        case toolCall
        case toolResult
        case plan
        case permission
        case question
        /// A transcript marker that isn't chat — e.g. the harness auto-compacted
        /// its context. Replayed as a divider.
        case notice
    }

    public var id: String
    public var turnID: String
    public var ordinal: Int
    public var kind: String
    public var text: String
    public var toolName: String?
    public var toolCallID: String?
    public var displayName: String?
    /// JSON for anything that doesn't fit a column — tool inputs, plan items,
    /// question options. Kept opaque on purpose: these shapes are the harness's,
    /// and pinning them into columns would mean a migration per CLI release.
    public var payload: String?
    public var isError: Bool
    public var parentToolCallID: String?
    public var createdAt: Date

    public init(
        id: String,
        turnID: TurnID,
        ordinal: Int,
        kind: Kind,
        text: String = "",
        toolName: String? = nil,
        toolCallID: ToolCallID? = nil,
        displayName: String? = nil,
        payload: JSONValue? = nil,
        isError: Bool = false,
        parentToolCallID: ToolCallID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.turnID = turnID.rawValue
        self.ordinal = ordinal
        self.kind = kind.rawValue
        self.text = text
        self.toolName = toolName
        self.toolCallID = toolCallID?.rawValue
        self.displayName = displayName
        self.payload = payload.flatMap { value in
            (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) }
        }
        self.isError = isError
        self.parentToolCallID = parentToolCallID?.rawValue
        self.createdAt = createdAt
    }

    public var blockKind: Kind { Kind(rawValue: kind) ?? .text }

    public var decodedPayload: JSONValue? {
        guard let payload, let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

public struct DiffCommentRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "diffComment"

    public var id: Int64?
    public var workspaceID: String
    public var filePath: String
    public var startLine: Int
    public var endLine: Int
    public var body: String
    public var context: String?
    public var isSent: Bool
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        workspaceID: WorkspaceID,
        filePath: String,
        startLine: Int,
        endLine: Int,
        body: String,
        context: String? = nil,
        isSent: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID.rawValue
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
        self.body = body
        self.context = context
        self.isSent = isSent
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var reference: DiffCommentReference {
        DiffCommentReference(
            filePath: filePath,
            startLine: startLine,
            endLine: endLine,
            body: body,
            context: context
        )
    }
}

public struct ViewedFileRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "viewedFile"

    public var workspaceID: String
    public var filePath: String
    /// Hash of the diff the user actually looked at. When the agent changes the
    /// file again the hash stops matching, and the file correctly returns to
    /// unviewed instead of staying ticked off.
    public var contentHash: String
    public var viewedAt: Date

    public init(
        workspaceID: WorkspaceID,
        filePath: String,
        contentHash: String,
        viewedAt: Date = Date()
    ) {
        self.workspaceID = workspaceID.rawValue
        self.filePath = filePath
        self.contentHash = contentHash
        self.viewedAt = viewedAt
    }
}

public struct AssistantActionRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "assistantAction"

    public var id: Int64?
    public var tool: String
    public var summary: String
    public var arguments: String
    public var decision: String
    public var workspaceID: String?
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        tool: String,
        summary: String,
        arguments: String = "{}",
        decision: String,
        workspaceID: WorkspaceID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.tool = tool
        self.summary = summary
        self.arguments = arguments
        self.decision = decision
        self.workspaceID = workspaceID?.rawValue
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct AssistantGrantRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "assistantGrant"

    public var actionClass: String
    public var createdAt: Date

    public init(actionClass: String, createdAt: Date = Date()) {
        self.actionClass = actionClass
        self.createdAt = createdAt
    }
}

public struct AssistantTabGrantRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "assistantTabGrant"

    public var chatID: String
    public var createdAt: Date

    public init(chatID: ChatID, createdAt: Date = Date()) {
        self.chatID = chatID.rawValue
        self.createdAt = createdAt
    }

    public var id: ChatID { ChatID(rawValue: chatID) }
}

public struct QueuedMessageRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "queuedMessage"

    public var id: Int64?
    public var workspaceID: String
    public var chatID: String?
    public var text: String
    public var attachmentPaths: String
    public var serviceTier: String?
    public var origin: String = MessageOrigin.user.rawValue
    /// Carried through the wait so the client that already drew this message as
    /// queued recognises it when the engine finally sends it.
    public var submissionID: String = ""
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        workspaceID: WorkspaceID,
        chatID: ChatID? = nil,
        text: String,
        attachmentPaths: [String] = [],
        serviceTier: String? = nil,
        origin: MessageOrigin = .user,
        submissionID: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID.rawValue
        self.chatID = chatID?.rawValue
        self.text = text
        self.attachmentPaths = (try? JSONEncoder().encode(attachmentPaths))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        self.serviceTier = serviceTier
        self.origin = origin.rawValue
        self.submissionID = submissionID
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var messageOrigin: MessageOrigin {
        MessageOrigin(rawValue: origin) ?? .user
    }

    public var paths: [String] {
        guard let data = attachmentPaths.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}

public struct DreamRunRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "dreamRun"

    public var id: String
    public var scheduledFor: Date
    public var state: String
    public var trigger: String
    public var agendaJSON: String
    public var reportJSON: String?
    public var why: String
    public var abortReason: String?
    public var tokenBudget: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: DreamRunID,
        scheduledFor: Date = Date(),
        state: DreamRunState,
        trigger: DreamRunTrigger,
        agendaJSON: String = "[]",
        reportJSON: String? = nil,
        why: String,
        abortReason: String? = nil,
        tokenBudget: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id.rawValue
        self.scheduledFor = scheduledFor
        self.state = state.rawValue
        self.trigger = trigger.rawValue
        self.agendaJSON = agendaJSON
        self.reportJSON = reportJSON
        self.why = why
        self.abortReason = abortReason
        self.tokenBudget = tokenBudget
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var runID: DreamRunID { DreamRunID(rawValue: id) }
    public var runState: DreamRunState { DreamRunState(rawValue: state) ?? .planned }
    public var runTrigger: DreamRunTrigger { DreamRunTrigger(rawValue: trigger) ?? .schedule }
}

public struct DreamTaskRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "dreamTask"

    public var id: String
    public var runID: String
    public var repositoryPath: String
    public var kind: String
    public var priorityScore: Double
    public var state: String
    public var why: String
    public var workspaceID: String?
    public var chatID: String?
    public var harness: String?
    public var model: String?
    public var tokensUsed: Int
    public var turnCount: Int
    public var failureReason: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: DreamTaskID,
        runID: DreamRunID,
        repositoryPath: String,
        kind: DreamKind,
        priorityScore: Double,
        state: DreamTaskState,
        why: String,
        workspaceID: WorkspaceID? = nil,
        chatID: ChatID? = nil,
        harness: HarnessKind? = nil,
        model: String? = nil,
        tokensUsed: Int = 0,
        turnCount: Int = 0,
        failureReason: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id.rawValue
        self.runID = runID.rawValue
        self.repositoryPath = repositoryPath
        self.kind = kind.rawValue
        self.priorityScore = priorityScore
        self.state = state.rawValue
        self.why = why
        self.workspaceID = workspaceID?.rawValue
        self.chatID = chatID?.rawValue
        self.harness = harness?.rawValue
        self.model = model
        self.tokensUsed = tokensUsed
        self.turnCount = turnCount
        self.failureReason = failureReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var taskID: DreamTaskID { DreamTaskID(rawValue: id) }
    public var dreamRunID: DreamRunID { DreamRunID(rawValue: runID) }
    public var dreamKind: DreamKind { DreamKind(rawValue: kind) ?? .review }
    public var taskState: DreamTaskState { DreamTaskState(rawValue: state) ?? .pending }
}

public struct DreamFindingRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "dreamFinding"

    public var id: String
    public var taskID: String
    public var runID: String
    public var repositoryPath: String
    public var kind: String
    public var title: String
    public var summary: String
    public var evidenceJSON: String
    public var confidence: Double
    public var severity: String
    public var branchName: String?
    public var diffSnapshot: String?
    public var status: String
    public var rejectReason: String?
    public var deferredUntil: Date?
    public var dedupeKey: String
    public var why: String
    public var workspaceID: String?
    public var chatID: String?
    public var createdAt: Date
    public var lastSeenAt: Date

    public init(
        id: DreamFindingID,
        taskID: DreamTaskID,
        runID: DreamRunID,
        repositoryPath: String,
        kind: DreamFindingKind,
        title: String,
        summary: String,
        evidenceJSON: String = "[]",
        confidence: Double,
        severity: DreamFindingSeverity,
        branchName: String? = nil,
        diffSnapshot: String? = nil,
        status: DreamFindingStatus = .new,
        rejectReason: String? = nil,
        deferredUntil: Date? = nil,
        dedupeKey: String,
        why: String,
        workspaceID: WorkspaceID? = nil,
        chatID: ChatID? = nil,
        createdAt: Date = Date(),
        lastSeenAt: Date = Date()
    ) {
        self.id = id.rawValue
        self.taskID = taskID.rawValue
        self.runID = runID.rawValue
        self.repositoryPath = repositoryPath
        self.kind = kind.rawValue
        self.title = title
        self.summary = summary
        self.evidenceJSON = evidenceJSON
        self.confidence = confidence
        self.severity = severity.rawValue
        self.branchName = branchName
        self.diffSnapshot = diffSnapshot
        self.status = status.rawValue
        self.rejectReason = rejectReason
        self.deferredUntil = deferredUntil
        self.dedupeKey = dedupeKey
        self.why = why
        self.workspaceID = workspaceID?.rawValue
        self.chatID = chatID?.rawValue
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }

    public var findingID: DreamFindingID { DreamFindingID(rawValue: id) }

    public var evidence: [DreamEvidence] {
        guard let data = evidenceJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([DreamEvidence].self, from: data)) ?? []
    }
}

public struct DreamLedgerRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "dreamLedger"

    public var id: Int64?
    public var runID: String
    public var taskID: String?
    public var harness: String
    public var tokens: Int
    public var turns: Int
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        runID: DreamRunID,
        taskID: DreamTaskID? = nil,
        harness: HarnessKind,
        tokens: Int,
        turns: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.runID = runID.rawValue
        self.taskID = taskID?.rawValue
        self.harness = harness.rawValue
        self.tokens = tokens
        self.turns = turns
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
