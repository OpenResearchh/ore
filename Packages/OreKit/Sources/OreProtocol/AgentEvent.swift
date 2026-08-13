import Foundation

/// The normalized event stream every harness driver emits.
///
/// Everything above this line — orchestration, persistence, the Mac UI — is
/// written against `AgentEvent` alone and never sees a CLI's wire format. When
/// a CLI changes its protocol the blast radius stops at its driver.
public enum AgentEvent: Sendable, Codable, Hashable {
    case sessionStarted(SessionStarted)
    case statusChanged(AgentStatus)
    case turnStarted(TurnStarted)
    case textDelta(BlockDelta)
    case thinkingDelta(BlockDelta)
    case blockCompleted(BlockCompleted)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    case planUpdated(PlanUpdate)
    case permissionRequest(PermissionRequest)
    case permissionResolved(PermissionResolution)
    case question(AgentQuestion)
    case usage(UsageReport)
    case rateLimit(RateLimitReport)
    case turnCompleted(TurnResult)
    case sessionError(SessionError)
    case sessionEnded(SessionEnded)
}

// MARK: - Session lifecycle

public struct SessionStarted: Sendable, Codable, Hashable {
    public var sessionID: SessionID
    /// The id the CLI itself uses. Needed for `--resume`, and it changes on fork.
    public var providerSessionID: String
    public var harness: HarnessKind
    public var model: String?
    public var workingDirectory: String
    public var permissionMode: PermissionMode
    public var availableTools: [String]
    /// Version string of the CLI actually driving this session. Recorded per
    /// session so a bug report pins the exact protocol we were speaking.
    public var harnessVersion: String?

    public init(
        sessionID: SessionID,
        providerSessionID: String,
        harness: HarnessKind,
        model: String? = nil,
        workingDirectory: String,
        permissionMode: PermissionMode = .default,
        availableTools: [String] = [],
        harnessVersion: String? = nil
    ) {
        self.sessionID = sessionID
        self.providerSessionID = providerSessionID
        self.harness = harness
        self.model = model
        self.workingDirectory = workingDirectory
        self.permissionMode = permissionMode
        self.availableTools = availableTools
        self.harnessVersion = harnessVersion
    }
}

/// Coarse activity state, used for the sidebar's "who needs me" indicators.
public enum AgentStatus: String, Sendable, Codable {
    case idle
    case thinking
    /// Waiting on the model.
    case requesting
    case runningTool
    /// Blocked on a human: a permission request or a question.
    case awaitingInput
    case interrupted
    case failed
}

public struct SessionEnded: Sendable, Codable, Hashable {
    public var sessionID: SessionID
    public var exitCode: Int32?
    /// Set when the process died on its own rather than being stopped by ORE.
    public var wasUnexpected: Bool

    public init(sessionID: SessionID, exitCode: Int32?, wasUnexpected: Bool) {
        self.sessionID = sessionID
        self.exitCode = exitCode
        self.wasUnexpected = wasUnexpected
    }
}

// MARK: - Turns and content

public struct TurnStarted: Sendable, Codable, Hashable {
    public var turnID: TurnID
    public var model: String?

    public init(turnID: TurnID, model: String? = nil) {
        self.turnID = turnID
        self.model = model
    }
}

/// An incremental append to one content block. `text` is the delta, never the
/// accumulated value — coalescing happens at the core→UI boundary.
public struct BlockDelta: Sendable, Codable, Hashable {
    public var turnID: TurnID
    public var blockID: BlockID
    public var text: String
    /// Set when the block belongs to a subagent's nested transcript.
    public var parentToolCallID: ToolCallID?

    public init(
        turnID: TurnID,
        blockID: BlockID,
        text: String,
        parentToolCallID: ToolCallID? = nil
    ) {
        self.turnID = turnID
        self.blockID = blockID
        self.text = text
        self.parentToolCallID = parentToolCallID
    }
}

public struct BlockCompleted: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case text
        case thinking
    }

    public var turnID: TurnID
    public var blockID: BlockID
    public var kind: Kind
    /// The block's full final text. Persisted as the source of truth; the
    /// deltas that preceded it were only for live rendering.
    public var text: String
    public var parentToolCallID: ToolCallID?

    public init(
        turnID: TurnID,
        blockID: BlockID,
        kind: Kind,
        text: String,
        parentToolCallID: ToolCallID? = nil
    ) {
        self.turnID = turnID
        self.blockID = blockID
        self.kind = kind
        self.text = text
        self.parentToolCallID = parentToolCallID
    }
}

// MARK: - Tools

public struct ToolCall: Sendable, Codable, Hashable {
    public var turnID: TurnID
    public var id: ToolCallID
    public var name: String
    /// Human-facing label the harness suggests (a file name, a command).
    public var displayName: String?
    public var input: JSONValue
    public var parentToolCallID: ToolCallID?

    public init(
        turnID: TurnID,
        id: ToolCallID,
        name: String,
        displayName: String? = nil,
        input: JSONValue,
        parentToolCallID: ToolCallID? = nil
    ) {
        self.turnID = turnID
        self.id = id
        self.name = name
        self.displayName = displayName
        self.input = input
        self.parentToolCallID = parentToolCallID
    }
}

public struct ToolResult: Sendable, Codable, Hashable {
    public var turnID: TurnID
    public var toolCallID: ToolCallID
    public var isError: Bool
    /// Rendered text of the result, already flattened from whatever block
    /// shape the harness used.
    public var text: String
    /// Structured extras (stdout/stderr split, file diffs) when the harness
    /// provides them.
    public var metadata: JSONValue?

    public init(
        turnID: TurnID,
        toolCallID: ToolCallID,
        isError: Bool,
        text: String,
        metadata: JSONValue? = nil
    ) {
        self.turnID = turnID
        self.toolCallID = toolCallID
        self.isError = isError
        self.text = text
        self.metadata = metadata
    }
}

// MARK: - Plans

public struct PlanUpdate: Sendable, Codable, Hashable {
    public enum Content: Sendable, Codable, Hashable {
        /// A running checklist the agent maintains as it works.
        case todos([TodoItem])
        /// A plan the agent wants approval for before it starts editing.
        /// Approving means allowing the underlying tool call and dropping out
        /// of plan mode.
        case proposal(markdown: String, permissionRequestID: PermissionRequestID?)
    }

    public var turnID: TurnID
    public var content: Content

    public init(turnID: TurnID, content: Content) {
        self.turnID = turnID
        self.content = content
    }
}

public struct TodoItem: Sendable, Codable, Hashable {
    public enum Status: String, Sendable, Codable {
        case pending
        case inProgress
        case completed
    }

    public var text: String
    public var status: Status

    public init(text: String, status: Status) {
        self.text = text
        self.status = status
    }
}

// MARK: - Permissions

public enum PermissionMode: String, Sendable, Codable, CaseIterable {
    case `default`
    /// File edits are auto-approved; everything else still prompts.
    case acceptEdits
    /// Read-only: the agent researches and proposes a plan, no mutations.
    case plan
    case bypassPermissions

    public var displayName: String {
        switch self {
        case .default: return "Ask"
        case .acceptEdits: return "Accept Edits"
        case .plan: return "Plan"
        case .bypassPermissions: return "Bypass"
        }
    }
}

public struct PermissionRequest: Sendable, Codable, Hashable {
    public var turnID: TurnID
    public var id: PermissionRequestID
    public var toolCallID: ToolCallID?
    public var toolName: String
    public var displayName: String?
    /// One-line summary of what will happen ("probe.txt", "git push").
    public var summary: String?
    public var input: JSONValue
    /// Rules the harness suggests offering as one-click "always allow" options.
    public var suggestions: [PermissionSuggestion]

    public init(
        turnID: TurnID,
        id: PermissionRequestID,
        toolCallID: ToolCallID? = nil,
        toolName: String,
        displayName: String? = nil,
        summary: String? = nil,
        input: JSONValue,
        suggestions: [PermissionSuggestion] = []
    ) {
        self.turnID = turnID
        self.id = id
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.displayName = displayName
        self.summary = summary
        self.input = input
        self.suggestions = suggestions
    }
}

/// A harness-proposed shortcut, normalized enough for ORE to render a button
/// while keeping the raw payload to hand back verbatim.
public struct PermissionSuggestion: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable {
        /// "Allow all edits for this session" — switches permission mode.
        case setMode
        /// "Always allow `Bash(git status)`" — adds a scoped rule.
        case addRule
        case other
    }

    public var kind: Kind
    public var title: String
    public var raw: JSONValue

    public init(kind: Kind, title: String, raw: JSONValue) {
        self.kind = kind
        self.title = title
        self.raw = raw
    }
}

public enum PermissionDecision: Sendable, Codable, Hashable {
    /// `updatedInput` lets the user edit a command before approving it.
    case allow(updatedInput: JSONValue?)
    /// Accept the harness-provided persistent permission suggestion verbatim.
    case allowWithSuggestion(JSONValue)
    case deny(reason: String)

    public static var allow: PermissionDecision { .allow(updatedInput: nil) }
}

public struct PermissionResolution: Sendable, Codable, Hashable {
    public var id: PermissionRequestID
    public var decision: PermissionDecision

    public init(id: PermissionRequestID, decision: PermissionDecision) {
        self.id = id
        self.decision = decision
    }
}

// MARK: - Questions

/// The agent asking the user something directly, as opposed to asking for
/// permission. Surfaced the same way in the sidebar: this workspace is blocked.
public struct AgentQuestion: Sendable, Codable, Hashable {
    public struct Option: Sendable, Codable, Hashable {
        public var label: String
        public var detail: String?

        public init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }
    }

    public var turnID: TurnID
    public var id: QuestionID
    public var toolCallID: ToolCallID?
    public var prompt: String
    public var options: [Option]
    public var allowsFreeform: Bool

    public init(
        turnID: TurnID,
        id: QuestionID,
        toolCallID: ToolCallID? = nil,
        prompt: String,
        options: [Option] = [],
        allowsFreeform: Bool = true
    ) {
        self.turnID = turnID
        self.id = id
        self.toolCallID = toolCallID
        self.prompt = prompt
        self.options = options
        self.allowsFreeform = allowsFreeform
    }
}

// MARK: - Usage

public struct UsageReport: Sendable, Codable, Hashable {
    public var turnID: TurnID?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int
    /// Model context window, when the harness reports it — drives the context
    /// meter without ORE hardcoding a per-model table.
    public var contextWindow: Int?
    /// Only populated for API-key sessions; subscription sessions leave it nil
    /// rather than showing a price the user isn't being charged.
    public var costUSD: Double?

    public var totalContextTokens: Int {
        inputTokens + cacheReadTokens + cacheCreationTokens + outputTokens
    }

    public init(
        turnID: TurnID? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        contextWindow: Int? = nil,
        costUSD: Double? = nil
    ) {
        self.turnID = turnID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.contextWindow = contextWindow
        self.costUSD = costUSD
    }
}

public struct RateLimitReport: Sendable, Codable, Hashable {
    public enum Status: String, Sendable, Codable {
        case allowed
        case warning
        case exhausted
        case unknown
    }

    public var status: Status
    public var window: String?
    public var resetsAt: Date?

    public init(status: Status, window: String? = nil, resetsAt: Date? = nil) {
        self.status = status
        self.window = window
        self.resetsAt = resetsAt
    }
}

// MARK: - Turn completion and errors

public struct TurnResult: Sendable, Codable, Hashable {
    public enum Outcome: String, Sendable, Codable {
        case completed
        case interrupted
        case failed
        /// The turn ended because the agent needs the user (plan approval,
        /// a question) before it can continue.
        case awaitingInput
    }

    public var turnID: TurnID
    public var outcome: Outcome
    /// The final assistant text, for auto-titles, notifications and search.
    public var summary: String?
    public var usage: UsageReport?
    public var duration: TimeInterval?
    public var errorMessage: String?

    public init(
        turnID: TurnID,
        outcome: Outcome,
        summary: String? = nil,
        usage: UsageReport? = nil,
        duration: TimeInterval? = nil,
        errorMessage: String? = nil
    ) {
        self.turnID = turnID
        self.outcome = outcome
        self.summary = summary
        self.usage = usage
        self.duration = duration
        self.errorMessage = errorMessage
    }
}

public struct SessionError: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case notInstalled
        case notAuthenticated
        case rateLimited
        case protocolMismatch
        case processFailed
        case transport
        case unknown
    }

    public var kind: Kind
    public var message: String
    /// Raw stderr or payload, kept for bug reports — never shown as the
    /// primary message.
    public var detail: String?
    /// False when the session is dead and the UI should offer a restart.
    public var isRecoverable: Bool

    public init(
        kind: Kind,
        message: String,
        detail: String? = nil,
        isRecoverable: Bool = true
    ) {
        self.kind = kind
        self.message = message
        self.detail = detail
        self.isRecoverable = isRecoverable
    }
}
