import Foundation

/// Core → client. The other half of the boundary described in `CoreCommand`.
///
/// Two shapes travel here: `snapshot` carries whole state for a cold start or a
/// reconnect, and everything else is an incremental patch. A client that
/// applies snapshots and patches in order is always correct, whether the core
/// is in-process or across a socket.
public enum CoreEvent: Sendable, Codable {
    case snapshot(CoreSnapshot)
    case workspaceAdded(WorkspaceSummary)
    case workspaceUpdated(WorkspaceSummary)
    case workspaceRemoved(WorkspaceID)
    case chatAdded(ChatSummary)
    case chatUpdated(ChatSummary)
    case chatRemoved(WorkspaceID, ChatID)
    case chatsListed(WorkspaceID, [ChatSummary])
    /// A harness event, tagged with both owners so concurrent tabs can never
    /// cross-attribute streamed output.
    case agent(WorkspaceID, ChatID, AgentEvent)
    case gitStatusChanged(WorkspaceID, GitStatusSummary)
    case harnessProbeCompleted([HarnessProbeResult])
    case modelCatalogUpdated(HarnessKind, [AgentModel])
    case commandFailed(CommandFailure)

    // The assistant's action lane surfacing into the client: a pending
    // confirmation, its resolution (however it resolved — user, timeout, or
    // another window), and UI-level effects like revealing a workspace.
    case assistantConfirmationRequested(AssistantConfirmation)
    case assistantConfirmationResolved(String)
    case assistantUIAction(AssistantUIAction)
}

public struct CoreSnapshot: Sendable, Codable {
    public var workspaces: [WorkspaceSummary]
    public var chats: [ChatSummary]
    public var harnesses: [HarnessProbeResult]

    public init(
        workspaces: [WorkspaceSummary],
        chats: [ChatSummary] = [],
        harnesses: [HarnessProbeResult]
    ) {
        self.workspaces = workspaces
        self.chats = chats
        self.harnesses = harnesses
    }
}

/// Durable state for one chat tab. Provider sessions are incarnations beneath
/// this identity, so changing harnesses never replaces the visible transcript.
public struct ChatSummary: Sendable, Codable, Hashable, Identifiable {
    public var id: ChatID
    public var workspaceID: WorkspaceID
    public var title: String
    public var harness: HarnessKind
    public var model: String?
    public var permissionMode: PermissionMode
    public var status: AgentStatus
    public var capabilities: HarnessCapabilities
    public var hasUnread: Bool
    public var isClosed: Bool
    public var draftText: String
    public var queuedMessageCount: Int
    /// Whether a turn is open — and so whether the next message sent will be
    /// queued rather than delivered.
    ///
    /// Published rather than inferred from `status`, because the two genuinely
    /// differ: an agent blocked on a permission request reads as `awaitingInput`
    /// while its turn is still very much open. Deriving "will this queue?" from
    /// the status is how the composer came to promise an immediate send for a
    /// message the engine then quietly queued.
    public var isTurnActive: Bool
    public var contextUsage: UsageReport?
    public var createdAt: Date
    public var lastActivity: Date?

    public init(
        id: ChatID,
        workspaceID: WorkspaceID,
        title: String,
        harness: HarnessKind,
        model: String? = nil,
        permissionMode: PermissionMode = .default,
        status: AgentStatus = .idle,
        capabilities: HarnessCapabilities = HarnessCapabilities(),
        hasUnread: Bool = false,
        isClosed: Bool = false,
        draftText: String = "",
        queuedMessageCount: Int = 0,
        isTurnActive: Bool = false,
        contextUsage: UsageReport? = nil,
        createdAt: Date = Date(),
        lastActivity: Date? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
        self.harness = harness
        self.model = model
        self.permissionMode = permissionMode
        self.status = status
        self.capabilities = capabilities
        self.hasUnread = hasUnread
        self.isClosed = isClosed
        self.draftText = draftText
        self.queuedMessageCount = queuedMessageCount
        self.isTurnActive = isTurnActive
        self.contextUsage = contextUsage
        self.createdAt = createdAt
        self.lastActivity = lastActivity
    }
}

/// What a workspace is for.
///
/// `.assistant` marks the product-owned assistant workspace: one per user,
/// hidden from the sidebar and every picker, surfaced only through the
/// Assistant activity window and voice mode. It runs the same engine as any
/// other workspace — being hidden is a client concern, not an engine one.
public enum WorkspaceKind: String, Sendable, Codable, Hashable {
    case standard
    case assistant
}

/// Everything the sidebar needs to render one row, in one struct — the sidebar
/// is the app's "which agent needs me right now" dashboard, so it must never
/// have to fan out to other queries to draw itself.
public struct WorkspaceSummary: Sendable, Codable, Hashable, Identifiable {
    public var id: WorkspaceID
    public var name: String
    public var repositoryPath: String
    public var worktreePath: String
    public var branch: String
    public var baseBranch: String
    /// Set when this workspace is stacked on another one's branch.
    public var stackedOn: WorkspaceID?
    public var harness: HarnessKind
    public var model: String?
    public var status: AgentStatus
    public var permissionMode: PermissionMode
    /// Capped at one per workspace by design: a workspace either needs
    /// attention or it doesn't, and a badge of 37 tells you nothing.
    public var hasUnread: Bool
    public var isPinned: Bool
    public var isArchived: Bool
    public var archivedAt: Date?
    /// Disk space the archive reclaimed, measured before the worktree was
    /// removed. Nil for never-archived workspaces.
    public var archivedDiskBytes: Int64?
    public var gitStatus: GitStatusSummary
    public var contextUsage: UsageReport?
    public var lastActivity: Date?
    /// Origin default vs local default vs this branch. Nil until the first
    /// fetch lands; missing from older snapshots.
    public var baseSync: BaseSyncStatus?
    /// Nil in snapshots from cores predating the assistant; treat as `.standard`.
    public var kind: WorkspaceKind?

    public var isAssistant: Bool { kind == .assistant }

    public init(
        id: WorkspaceID,
        name: String,
        repositoryPath: String,
        worktreePath: String,
        branch: String,
        baseBranch: String,
        stackedOn: WorkspaceID? = nil,
        harness: HarnessKind,
        model: String? = nil,
        status: AgentStatus = .idle,
        permissionMode: PermissionMode = .default,
        hasUnread: Bool = false,
        isPinned: Bool = false,
        isArchived: Bool = false,
        archivedAt: Date? = nil,
        archivedDiskBytes: Int64? = nil,
        gitStatus: GitStatusSummary = GitStatusSummary(),
        contextUsage: UsageReport? = nil,
        lastActivity: Date? = nil,
        baseSync: BaseSyncStatus? = nil,
        kind: WorkspaceKind? = nil
    ) {
        self.id = id
        self.name = name
        self.repositoryPath = repositoryPath
        self.worktreePath = worktreePath
        self.branch = branch
        self.baseBranch = baseBranch
        self.stackedOn = stackedOn
        self.harness = harness
        self.model = model
        self.status = status
        self.permissionMode = permissionMode
        self.hasUnread = hasUnread
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.archivedAt = archivedAt
        self.archivedDiskBytes = archivedDiskBytes
        self.gitStatus = gitStatus
        self.contextUsage = contextUsage
        self.lastActivity = lastActivity
        self.baseSync = baseSync
        self.kind = kind
    }
}

public struct GitStatusSummary: Sendable, Codable, Hashable {
    public var changedFileCount: Int
    public var insertions: Int
    public var deletions: Int
    public var hasUncommittedChanges: Bool
    public var aheadOfBase: Int
    public var behindBase: Int
    /// Generation counter from the status watcher. A client must ignore any
    /// summary older than the one it has, since FSEvents batches can land out
    /// of order under load.
    public var generation: UInt64

    public init(
        changedFileCount: Int = 0,
        insertions: Int = 0,
        deletions: Int = 0,
        hasUncommittedChanges: Bool = false,
        aheadOfBase: Int = 0,
        behindBase: Int = 0,
        generation: UInt64 = 0
    ) {
        self.changedFileCount = changedFileCount
        self.insertions = insertions
        self.deletions = deletions
        self.hasUncommittedChanges = hasUncommittedChanges
        self.aheadOfBase = aheadOfBase
        self.behindBase = behindBase
        self.generation = generation
    }
}

/// Origin's default branch compared to the local default ref and to this
/// worktree's HEAD. The UI uses it to prompt for a pull or a rebase without
/// sending the user to GitHub.
public struct BaseSyncStatus: Sendable, Codable, Hashable {
    public var defaultBranch: String
    /// Commits on `origin/<default>` that local `<default>` does not have.
    public var localDefaultBehindOrigin: Int
    /// Commits on `origin/<default>` that this workspace's HEAD does not have.
    public var workspaceBehindOrigin: Int
    /// Merging `origin/<default>` into this branch would conflict.
    public var wouldConflict: Bool

    public init(
        defaultBranch: String,
        localDefaultBehindOrigin: Int = 0,
        workspaceBehindOrigin: Int = 0,
        wouldConflict: Bool = false
    ) {
        self.defaultBranch = defaultBranch
        self.localDefaultBehindOrigin = localDefaultBehindOrigin
        self.workspaceBehindOrigin = workspaceBehindOrigin
        self.wouldConflict = wouldConflict
    }

    public var needsAttention: Bool {
        localDefaultBehindOrigin > 0 || workspaceBehindOrigin > 0 || wouldConflict
    }
}

public struct CommandFailure: Sendable, Codable, Hashable {
    public var workspaceID: WorkspaceID?
    public var message: String
    public var detail: String?

    public init(workspaceID: WorkspaceID? = nil, message: String, detail: String? = nil) {
        self.workspaceID = workspaceID
        self.message = message
        self.detail = detail
    }
}

/// The single surface the Mac app talks to. `InProcessCoreClient` implements it
/// today; a `RemoteCoreClient` speaking the same two enums over a socket is the
/// cloud version.
public protocol CoreClient: Sendable {
    var events: AsyncStream<CoreEvent> { get }
    func send(_ command: CoreCommand) async
}
