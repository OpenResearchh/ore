import Foundation

/// The agent CLIs ORE can drive. Each is spawned as the user's own local
/// process so it carries the user's subscription credentials itself.
public enum HarnessKind: String, Sendable, Codable, CaseIterable {
    case claudeCode
    case codex
    case cursorAgent

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursorAgent: return "Cursor Agent"
        }
    }

    /// Default executable name looked up on the user's login-shell `PATH`.
    public var defaultExecutableName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .cursorAgent: return "agent"
        }
    }

    /// Harnesses that ship behind an experimental flag declare reduced
    /// capabilities rather than pretending to be at parity.
    public var isExperimental: Bool { self == .cursorAgent }

    /// Cursor bakes thinking level into the model id (`cursor-grok-4.6-high`)
    /// and `cursor-agent` has no `--effort` flag. Offering a chip would look
    /// like a setting and then silently do nothing.
    public var supportsReasoningEffort: Bool { self != .cursorAgent }
}

/// How a harness asks for permission before running a tool.
public enum PermissionModel: String, Sendable, Codable {
    /// The harness calls back over its control channel and blocks until we
    /// answer (Claude Code `can_use_tool`, Codex approval requests, ACP
    /// `session/request_permission`).
    case interactiveCallback
    /// The harness only accepts an up-front allow/deny policy; ORE can shape
    /// the rules but cannot answer a live prompt.
    case staticPolicy
    /// No permission surface at all — the agent proposes and ORE applies.
    case none
}

public enum UsageGranularity: String, Sendable, Codable {
    /// Token counts stream during the turn.
    case live
    /// Token counts arrive once, at turn end.
    case perTurn
    case unavailable
}

/// One model advertised by an installed agent CLI.
///
/// Model catalogs move independently of ORE releases. Keeping the provider's
/// identifier separate from its human name lets the UI show a useful picker
/// without turning display copy into a command-line argument.
public struct AgentModel: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var description: String
    public var isDefault: Bool
    public var supportedReasoningEfforts: [String]
    /// Catalog-provided processing tiers such as Codex `fast`. This is
    /// independent of the model and its reasoning effort.
    public var supportedServiceTiers: [String]

    public init(
        id: String,
        displayName: String,
        description: String = "",
        isDefault: Bool = false,
        supportedReasoningEfforts: [String] = [],
        supportedServiceTiers: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.isDefault = isDefault
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.supportedServiceTiers = supportedServiceTiers
    }
}

/// Merges a hand-maintained fallback catalogue with whatever the installed
/// CLI just advertised.
///
/// Discovery wins on id collision. Curated rows used to come first, which meant
/// a stale ORE fallback could advertise `max` (or blank efforts) for a model
/// the live CLI had already corrected — and Codex would reject the turn.
public enum AgentModelCatalog {
    public static func merge(curated: [AgentModel], discovered: [AgentModel]) -> [AgentModel] {
        if discovered.isEmpty { return curated }
        var seen: Set<String> = []
        return (discovered + curated).filter { seen.insert($0.id).inserted }
    }
}

/// What a given harness can actually do.
///
/// The UI reads this to degrade gracefully — a missing capability greys out a
/// control, it never breaks a screen. This is also the record we assert against
/// in golden-transcript CI when a CLI version bumps.
public struct HarnessCapabilities: Sendable, Codable, Hashable {
    public var supportsPlanMode: Bool
    /// Can accept a new user message while a turn is in flight (steering).
    public var supportsSteering: Bool
    public var supportsInterrupt: Bool
    /// Can resume a prior session by id.
    public var supportsResume: Bool
    /// Can resume *into a new session id*, leaving the original intact — the
    /// chat-side half of checkpoints.
    public var supportsSessionFork: Bool
    public var supportsThinkingStream: Bool
    public var supportsPartialMessages: Bool
    /// Can switch permission mode *during a running turn*, so the change binds
    /// the tool call the agent is about to make. Every harness accepts a change
    /// mid-session; false only means it lands on the next turn instead.
    public var supportsRuntimePermissionModeChange: Bool
    /// ORE can expose its own MCP tools (diff comments, ask-user) to the agent.
    public var supportsCustomTools: Bool
    public var permissionModel: PermissionModel
    public var usageGranularity: UsageGranularity

    public init(
        supportsPlanMode: Bool = false,
        supportsSteering: Bool = false,
        supportsInterrupt: Bool = false,
        supportsResume: Bool = false,
        supportsSessionFork: Bool = false,
        supportsThinkingStream: Bool = false,
        supportsPartialMessages: Bool = false,
        supportsRuntimePermissionModeChange: Bool = false,
        supportsCustomTools: Bool = false,
        permissionModel: PermissionModel = .none,
        usageGranularity: UsageGranularity = .unavailable
    ) {
        self.supportsPlanMode = supportsPlanMode
        self.supportsSteering = supportsSteering
        self.supportsInterrupt = supportsInterrupt
        self.supportsResume = supportsResume
        self.supportsSessionFork = supportsSessionFork
        self.supportsThinkingStream = supportsThinkingStream
        self.supportsPartialMessages = supportsPartialMessages
        self.supportsRuntimePermissionModeChange = supportsRuntimePermissionModeChange
        self.supportsCustomTools = supportsCustomTools
        self.permissionModel = permissionModel
        self.usageGranularity = usageGranularity
    }
}

/// Result of the onboarding doctor's check for one harness.
public struct HarnessProbeResult: Sendable, Codable, Hashable {
    public enum AuthState: String, Sendable, Codable {
        case authenticated
        case notAuthenticated
        /// The CLI exists but doesn't let us determine login state without
        /// spending a request — don't block onboarding on it.
        case unknown
    }

    public var kind: HarnessKind
    public var executablePath: String?
    public var version: String?
    public var authState: AuthState
    /// False when the CLI can be detected and diagnosed but the integration is
    /// gated off. Optional keeps older serialized probe snapshots compatible;
    /// nil means enabled, matching the behavior before this field existed.
    public var isEnabled: Bool?
    /// Set when the CLI is present but something is wrong we can explain.
    public var diagnostic: String?
    /// The CLI was found on PATH but could not be executed — quarantined, not
    /// marked executable, a broken symlink, an unmounted network volume.
    ///
    /// Distinct from "not installed", and the distinction is the whole point:
    /// telling somebody to install a CLI that is sitting right there, at a path
    /// ORE can name, sends them to do the one thing that will not help.
    ///
    /// Optional for the same reason as `isEnabled`: synthesized `Codable`
    /// throws on a missing key for a non-optional, so an older serialized
    /// probe snapshot would fail to decode. nil means "not assessed".
    public var isUnlaunchable: Bool?
    /// Other copies of this CLI found on PATH, in search order, excluding the
    /// one at `executablePath` that actually wins.
    ///
    /// Two copies from two install channels is the usual shape of "I updated
    /// it but ORE still reports the old version": the updater upgrades the one
    /// it can see, and PATH keeps running the other.
    public var shadowedPaths: [String]?

    public var isInstalled: Bool { executablePath != nil }
    public var isReady: Bool {
        isEnabled != false && isInstalled && authState != .notAuthenticated
            && isUnlaunchable != true
    }

    public init(
        kind: HarnessKind,
        executablePath: String? = nil,
        version: String? = nil,
        authState: AuthState = .unknown,
        isEnabled: Bool? = nil,
        diagnostic: String? = nil,
        isUnlaunchable: Bool? = nil,
        shadowedPaths: [String]? = nil
    ) {
        self.kind = kind
        self.executablePath = executablePath
        self.version = version
        self.authState = authState
        self.isEnabled = isEnabled
        self.diagnostic = diagnostic
        self.isUnlaunchable = isUnlaunchable
        self.shadowedPaths = shadowedPaths
    }
}

extension HarnessKind {
    /// How this agent's CLI is distributed.
    ///
    /// Vocabulary rather than behaviour, which is why it lives here and not in
    /// the harness layer: the Mac app has to name the install source too — to
    /// tell a user whose update failed on permissions exactly what to run —
    /// and it deliberately does not depend on `OreHarness`.
    public var npmPackage: String? {
        switch self {
        case .claudeCode: return "@anthropic-ai/claude-code"
        case .codex: return "@openai/codex"
        case .cursorAgent: return nil
        }
    }

    public var brewFormula: String? {
        switch self {
        case .claudeCode: return "claude-code"
        case .codex: return "codex"
        case .cursorAgent: return nil
        }
    }

}
