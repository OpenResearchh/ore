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
        self.contextUsage = contextUsage
        self.createdAt = createdAt
        self.lastActivity = lastActivity
    }
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
    public var gitStatus: GitStatusSummary
    public var contextUsage: UsageReport?
    public var lastActivity: Date?

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
        gitStatus: GitStatusSummary = GitStatusSummary(),
        contextUsage: UsageReport? = nil,
        lastActivity: Date? = nil
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
        self.gitStatus = gitStatus
        self.contextUsage = contextUsage
        self.lastActivity = lastActivity
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
