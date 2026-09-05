import Foundation

/// Client → core. Every interaction the UI can have with the engine, as one
/// `Codable` enum.
///
/// This is the boundary that keeps the cloud version open: today it's dispatched
/// in-process, and swapping in a transport that serializes these over a socket
/// is a change of `CoreClient` implementation only. Nothing here may reference
/// AppKit/SwiftUI types, and nothing may carry a closure.
public enum CoreCommand: Sendable, Codable {
    // Repositories and workspaces
    case addRepository(path: String)
    case createWorkspace(CreateWorkspaceRequest)
    case archiveWorkspace(WorkspaceID)
    case unarchiveWorkspace(WorkspaceID)
    case deleteWorkspace(WorkspaceID, deleteBranch: Bool)
    /// `userInitiated` marks a name the user typed, so the engine won't later
    /// replace it with a prompt-derived or generated title. Automatic
    /// research-identity assignment passes `false`.
    case renameWorkspace(WorkspaceID, name: String, userInitiated: Bool)
    case setWorkspacePinned(WorkspaceID, pinned: Bool)

    // Review and shipping
    case addDiffComment(WorkspaceID, DiffCommentReference)
    case markFileViewed(WorkspaceID, path: String, contentHash: String?)
    case commit(WorkspaceID, message: String)
    /// Create a GitHub repository for a local-only repo and publish it, so a
    /// workspace with committed work but no remote can enter the push/PR flow.
    case createGitHubRepo(WorkspaceID)
    case push(WorkspaceID)
    case createPullRequest(WorkspaceID, title: String, body: String, base: String, draft: Bool)
    case retargetPullRequest(WorkspaceID, number: Int, base: String)
    case mergePullRequest(WorkspaceID, method: String)
    /// After the PR merges: pull the default branch into the local ref and
    /// restart this worktree on a fresh branch cut from that local default.
    case continueAfterMerge(WorkspaceID)
    /// Fast-forward the repository's local default branch (`main`/`master`)
    /// from `origin/<default>` without switching this worktree onto it.
    case pullDefaultBranch(WorkspaceID)
    /// Take `--ours` or `--theirs` for a conflicted path (and stage it).
    case resolveConflict(WorkspaceID, path: String, side: String)
    /// Replace one `<<<<<<<` hunk with ours or theirs.
    case resolveConflictHunk(WorkspaceID, path: String, startLine: Int, side: String)
    /// `gh run rerun --failed` for the branch's latest failing workflow.
    case rerunFailedChecks(WorkspaceID)

    // Chat
    case createChat(CreateChatRequest)
    /// `userInitiated` marks a title the user typed, so the first message's
    /// auto-titling leaves it alone. Automatic research-title assignment passes
    /// `false`.
    case renameChat(WorkspaceID, ChatID, title: String, userInitiated: Bool)
    case closeChat(WorkspaceID, ChatID)
    case reopenChat(WorkspaceID, ChatID)
    case switchChatHarness(WorkspaceID, ChatID, harness: HarnessKind, model: String?)
    case setChatModel(WorkspaceID, ChatID, model: String?)
    case setChatDraft(WorkspaceID, ChatID, text: String)
    case listChats(WorkspaceID)
    case sendMessage(SendMessageRequest)
    /// Cancel the in-flight turn. Distinct from stopping the session.
    case interruptTurn(WorkspaceID)
    case interruptChatTurn(WorkspaceID, ChatID)
    case setPermissionMode(WorkspaceID, PermissionMode)
    case setChatPermissionMode(WorkspaceID, ChatID, PermissionMode)
    /// Persist the effort chip for a chat so later sends (user or assistant)
    /// use the same depth.
    case setChatEffort(WorkspaceID, ChatID, ReasoningEffort?)
    case resolvePermission(WorkspaceID, PermissionRequestID, PermissionDecision)
    case resolveChatPermission(WorkspaceID, ChatID, PermissionRequestID, PermissionDecision)
    case answerQuestion(WorkspaceID, QuestionID, answer: String)
    case answerChatQuestion(WorkspaceID, ChatID, QuestionID, answer: String)
    /// Restore chat *and* working tree to the state before the given turn.
    case revertToCheckpoint(WorkspaceID, TurnID)
    case revertChatToCheckpoint(WorkspaceID, ChatID, TurnID)

    // Session control
    case startSession(WorkspaceID, SessionRequest)
    case startChatSession(WorkspaceID, ChatID, SessionRequest)
    case stopSession(WorkspaceID)
    case stopChatSession(WorkspaceID, ChatID)

    // Assistant
    /// Answer a pending assistant action confirmation. The string is the
    /// confirmation id from `CoreEvent.assistantConfirmationRequested`.
    case resolveAssistantConfirmation(String, AssistantConfirmationDecision)

    // Dream Mode
    case updateDreamSettings(DreamSettings)
    case updateDreamEnvironment(DreamEnvironmentSnapshot)
    /// Manual "Dream now". Bypasses idle/quiet-hours/AC gates; still honors
    /// the night token cap, excluded-repo list, and research-only tool policy.
    case startDreamRun(manual: Bool, repositoryPath: String?)
    case abortDreamRun
    case resolveDreamFinding(DreamFindingID, DreamFindingResolution)
    case listDreamFindings

    // Diagnostics
    case probeHarnesses
    /// Resend the current snapshot — used on reconnect, and by a fresh window.
    case resync(WorkspaceID?)
}

public struct CreateWorkspaceRequest: Sendable, Codable {
    /// Where a new workspace's branch starts from.
    public enum Seed: Sendable, Codable {
        case defaultBranch
        case branch(String)
        /// Stack this workspace on another one: branch from its head and
        /// target its branch when the PR is opened.
        case workspace(WorkspaceID)
        case githubIssue(number: Int)
        case githubPullRequest(number: Int)
    }

    public var repositoryPath: String
    public var name: String
    public var seed: Seed
    public var harness: HarnessKind
    public var model: String?
    public var initialPrompt: String?
    /// Who wrote `initialPrompt`. Carried separately from the text because a
    /// workspace the assistant opens on the user's behalf must not present its
    /// opening prompt as something the user typed.
    public var promptOrigin: MessageOrigin
    public var branchPrefix: String?

    public init(
        repositoryPath: String,
        name: String,
        seed: Seed = .defaultBranch,
        harness: HarnessKind = .claudeCode,
        model: String? = nil,
        initialPrompt: String? = nil,
        promptOrigin: MessageOrigin = .user,
        branchPrefix: String? = nil
    ) {
        self.repositoryPath = repositoryPath
        self.name = name
        self.seed = seed
        self.harness = harness
        self.model = model
        self.initialPrompt = initialPrompt
        self.promptOrigin = promptOrigin
        self.branchPrefix = branchPrefix
    }
}

/// Who asked for a prompt to be sent.
///
/// The transcript draws both the same way — a prompt is a prompt — but it says
/// which is which. A user scrolling back has to be able to tell the work they
/// asked for from the work the assistant started for them.
public enum MessageOrigin: String, Sendable, Codable, Hashable, CaseIterable {
    /// Typed by the person, in a composer.
    case user
    /// Sent by the ORE assistant acting on the user's behalf.
    case agent
    /// A fleet digest ORE hands the assistant to judge — machine to machine,
    /// on a timer, whether or not anyone is at the keyboard.
    ///
    /// Distinguished from `.user` because the assistant's own conversation is
    /// otherwise mostly this: one digest every couple of minutes for as long
    /// as agents are running. Counted as conversation it would trigger a
    /// compaction overnight with nobody there; summarized as conversation it
    /// would bury what the user actually said under a wall of "finished a
    /// turn" and "SKIP".
    case watch
    /// An unattended Dream Mode research turn. Not the user's words, not the
    /// assistant speaking for them — overnight work that must not title chats,
    /// compact conversations, or show up in the fleet digest as activity.
    case dream
}

public struct SendMessageRequest: Sendable, Codable {
    public var workspaceID: WorkspaceID
    /// Nil addresses the workspace's default chat for compatibility with
    /// clients built before chat tabs existed.
    public var chatID: ChatID?
    public var text: String
    public var attachments: [Attachment]
    /// Comments left on a diff, forwarded as structured context so the agent
    /// knows exactly which lines the feedback refers to.
    public var diffComments: [DiffCommentReference]
    /// When a turn is already running: queue this message instead of steering
    /// mid-turn.
    public var queueIfBusy: Bool
    /// Requested reasoning depth. Harnesses that support a per-turn override
    /// apply this without restarting the conversation.
    public var reasoningEffort: ReasoningEffort?
    /// Optional catalog-provided processing tier. Codex calls its accelerated
    /// tier `fast`; unsupported harnesses simply receive nil.
    public var serviceTier: String?
    /// Who asked for this. Prompts the assistant sends arrive here the same way
    /// a typed one does, so without this the transcript cannot tell them apart.
    public var origin: MessageOrigin
    /// Stable identity for this submission, echoed back on `promptSubmitted`.
    ///
    /// A client that drew the prompt optimistically the moment the user pressed
    /// send matches the echo against this id and skips it, so the same message
    /// never lands in the transcript twice.
    public var submissionID: String
    /// Prepended for the model only — omitted from the transcript. How the
    /// assistant receives a live app-state snapshot without cluttering the
    /// Assistant window with it.
    public var hiddenContext: String?

    public init(
        workspaceID: WorkspaceID,
        chatID: ChatID? = nil,
        text: String,
        attachments: [Attachment] = [],
        diffComments: [DiffCommentReference] = [],
        queueIfBusy: Bool = true,
        reasoningEffort: ReasoningEffort? = nil,
        serviceTier: String? = nil,
        origin: MessageOrigin = .user,
        submissionID: String = UUID().uuidString,
        hiddenContext: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.chatID = chatID
        self.text = text
        self.attachments = attachments
        self.diffComments = diffComments
        self.queueIfBusy = queueIfBusy
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.origin = origin
        self.submissionID = submissionID
        self.hiddenContext = hiddenContext
    }
}

public enum ReasoningEffort: String, CaseIterable, Sendable, Codable, Hashable {
    case none, low, medium, high, xhigh, max, adaptive

    public var displayName: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Max"
        case .adaptive: "Adaptive"
        }
    }
}

public struct CreateChatRequest: Sendable, Codable {
    public var workspaceID: WorkspaceID
    public var title: String?
    public var harness: HarnessKind?
    public var model: String?
    public var permissionMode: PermissionMode
    public var forkFrom: ChatID?
    public var reasoningEffort: ReasoningEffort?

    public init(
        workspaceID: WorkspaceID,
        title: String? = nil,
        harness: HarnessKind? = nil,
        model: String? = nil,
        permissionMode: PermissionMode = .default,
        forkFrom: ChatID? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.workspaceID = workspaceID
        self.title = title
        self.harness = harness
        self.model = model
        self.permissionMode = permissionMode
        self.forkFrom = forkFrom
        self.reasoningEffort = reasoningEffort
    }
}

/// Attachments are filesystem objects under the workspace's `.context`
/// directory rather than inline blobs — the agent can read them with its own
/// tools, and they survive a restart.
public struct Attachment: Sendable, Codable, Hashable {
    public var relativePath: String
    public var displayName: String
    public var mimeType: String?

    public init(relativePath: String, displayName: String, mimeType: String? = nil) {
        self.relativePath = relativePath
        self.displayName = displayName
        self.mimeType = mimeType
    }
}

public struct DiffCommentReference: Sendable, Codable, Hashable {
    public var filePath: String
    public var startLine: Int
    public var endLine: Int
    public var body: String
    /// The diff hunk the comment was anchored to, so the agent sees the code
    /// even if the file has since changed.
    public var context: String?

    public init(
        filePath: String,
        startLine: Int,
        endLine: Int,
        body: String,
        context: String? = nil
    ) {
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
        self.body = body
        self.context = context
    }
}

public struct SessionRequest: Sendable, Codable {
    public var harness: HarnessKind
    public var model: String?
    public var permissionMode: PermissionMode
    /// Resume an existing provider session; forking leaves the original intact
    /// so a checkpoint revert can branch the conversation.
    public var resume: ResumeMode

    public enum ResumeMode: Sendable, Codable {
        case fresh
        case resume(providerSessionID: String)
        case fork(providerSessionID: String)
    }

    public init(
        harness: HarnessKind = .claudeCode,
        model: String? = nil,
        permissionMode: PermissionMode = .default,
        resume: ResumeMode = .fresh
    ) {
        self.harness = harness
        self.model = model
        self.permissionMode = permissionMode
        self.resume = resume
    }
}
