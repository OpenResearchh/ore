import Foundation

// The assistant's action lane. Read tools answer straight from a read-only
// database view; anything that *changes* the user's world crosses this bridge
// into the app process, where policy is enforced. The model is never trusted
// with the policy — it only sees results.

/// One action request from the assistant's MCP server process to the app,
/// as a line of NDJSON over the bridge socket.
public struct AssistantBridgeRequest: Sendable, Codable {
    public var id: String
    public var tool: String
    public var arguments: JSONValue

    public init(id: String, tool: String, arguments: JSONValue) {
        self.id = id
        self.tool = tool
        self.arguments = arguments
    }
}

public struct AssistantBridgeResponse: Sendable, Codable {
    public var id: String
    public var ok: Bool
    public var result: String?
    public var error: String?

    public init(id: String, ok: Bool, result: String? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }
}

/// The classes of consequential action the user can grant. Deliberately
/// coarse: a grant means "the assistant may do this kind of thing", not a
/// replay of one exact command.
public enum AssistantActionClass: String, Sendable, Codable, CaseIterable, Hashable {
    case commit
    case push
    case createPullRequest
    case archiveWorkspace
    /// Resolve a project tab's permission, or switch that tab to Bypass.
    case autoAllowTab
    /// Create a workspace that would sit beside a dirty sibling worktree.
    case createWorkspace
    /// Permanently remove an archived workspace, optionally including its branch.
    case deleteWorkspace
    /// Move or merge published git history (retarget, merge, continue, or pull).
    case changeGitHistory
    /// Replace conflicted file contents or rewind a workspace checkpoint.
    case rewriteWorkspace
    /// Create or update state on a remote hosting provider.
    case remoteRepository
    /// Bring a remote repository — and the agent instructions and settings it
    /// carries — onto this Mac. Its own class so that granting "always" for
    /// publishing the user's own work does not also grant cloning anything the
    /// assistant happens to read a name for.
    case cloneRepository
    /// Install a new version of one of the user's agent CLIs. Consequential
    /// because it replaces software outside ORE's own tree, on the user's
    /// machine, with whatever the vendor is publishing right now.
    case updateHarnessCLI

    /// Whether "for this task" or "always" may cover this class.
    ///
    /// Not for a permanent delete. One "Always" pressed on 2026-09-19 let the
    /// assistant delete workspaces for the rest of the session without a word,
    /// which is the one outcome a confirmation exists to prevent: nothing can
    /// bring those back. Every delete asks, whatever was pressed before.
    public var allowsStandingGrant: Bool {
        self != .deleteWorkspace
    }

    public var displayName: String {
        switch self {
        case .commit: "Commit"
        case .push: "Push"
        case .createPullRequest: "Create pull requests"
        case .archiveWorkspace: "Archive workspaces"
        case .autoAllowTab: "Auto-allow a tab"
        case .createWorkspace: "Create a workspace beside uncommitted work"
        case .deleteWorkspace: "Permanently delete workspaces"
        case .changeGitHistory: "Change git history"
        case .rewriteWorkspace: "Rewrite workspace files"
        case .remoteRepository: "Change remote repository state"
        case .cloneRepository: "Clone a repository onto this Mac"
        case .updateHarnessCLI: "Update an agent CLI"
        }
    }
}

/// How far a user's "allow" reaches.
///
/// `task` is the anti-nagging tier: a user who asked for something that
/// involves three pushes should be asked once, not three times. It covers the
/// action class for a sliding window rather than trying to detect task
/// boundaries the user never declared.
public enum AssistantGrantScope: String, Sendable, Codable {
    case once
    case task
    case always
}

public enum AssistantConfirmationDecision: Sendable, Codable, Hashable {
    case allow(AssistantGrantScope)
    case deny
}

/// A pending "may the assistant do this?" question, shown in the Assistant
/// window (and narrated, once voice mode exists).
public struct AssistantConfirmation: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var actionClass: AssistantActionClass
    public var workspaceID: WorkspaceID?
    public var chatID: ChatID?
    /// Human-readable, e.g. "Push branch ore/foo in kailash".
    public var summary: String

    public init(
        id: String,
        actionClass: AssistantActionClass,
        workspaceID: WorkspaceID? = nil,
        chatID: ChatID? = nil,
        summary: String
    ) {
        self.id = id
        self.actionClass = actionClass
        self.workspaceID = workspaceID
        self.chatID = chatID
        self.summary = summary
    }
}

/// UI-level effects the assistant can cause — things that live in the Mac app
/// rather than the core, like which workspace is frontmost or what sits in a
/// tab's composer.
///
/// The composer cases exist because a tab's draft text and its tagged files are
/// view state, not core state: the draft only reaches a *visible* composer
/// through the injection channel, and the tagged files live on the UI's
/// `ChatState` (and `UserDefaults`), never in the store. So the core validates
/// what it can — the file is really in the worktree — and then hands the actual
/// mutation to the app, exactly as `revealWorkspace` does.
public enum AssistantUIAction: Sendable, Codable, Hashable {
    case revealWorkspace(WorkspaceID)
    case revealChat(WorkspaceID, ChatID)
    /// Replace (or, when `append`, extend) a tab's composer draft, then focus it.
    case setComposerDraft(WorkspaceID, ChatID, text: String, append: Bool)
    /// Tag a workspace file onto a tab's composer as a shelf attachment.
    case tagComposerFile(WorkspaceID, ChatID, relativePath: String, displayName: String)
    /// Drop one tagged file from a tab's composer, matched by path or name.
    case untagComposerFile(WorkspaceID, ChatID, reference: String)
    /// Clear every tagged file from a tab's composer; optionally the draft too.
    case clearComposerTags(WorkspaceID, ChatID, clearDraft: Bool)
    /// Open (or re-focus) a workspace file as a centre-column tab.
    case openFile(WorkspaceID, relativePath: String, mode: String?, line: Int?)
    /// Close a centre-column file tab.
    case closeFile(WorkspaceID, relativePath: String)
    /// Approve or reject a project tab's pending plan, with optional feedback.
    case respondToPlan(WorkspaceID, ChatID, approve: Bool, feedback: String)
    /// Copy a pending plan into a new tab's composer, unsent.
    case handoffPlan(WorkspaceID, ChatID)
}

/// Where the bridge socket lives, derived from the database's location so the
/// app (server) and the MCP process (client) agree without configuration.
///
/// Normally beside the assistant home (`~/ore/assistant/.bridge.sock`), but
/// `sockaddr_un` paths max out at ~104 bytes — a deep scratch `ORE_HOME` (or a
/// test fixture under `/var/folders/…`) blows that limit, so long homes get a
/// short socket under the user-owned temporary directory (a subdirectory, never
/// a bare name in world-writable `/tmp`).
public enum AssistantBridgeLocator {
    public static func socketURL(forDatabase databaseURL: URL) -> URL {
        let preferred = databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("assistant/.bridge.sock")
        guard preferred.path.utf8.count >= 100 else { return preferred }

        var hash: UInt64 = 5381
        for byte in preferred.path.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        let name = "ore-bridge-\(String(hash, radix: 36))"

        // `$TMPDIR` is user-owned on macOS (`/var/folders/…/T`), not the
        // world-writable `/tmp`. Keep the socket inside a directory so the
        // name is never a bare file anyone can pre-create.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("bridge.sock")
        if tmp.path.utf8.count < 104 { return tmp }

        return URL(fileURLWithPath: "/tmp/\(name)/bridge.sock")
    }
}
