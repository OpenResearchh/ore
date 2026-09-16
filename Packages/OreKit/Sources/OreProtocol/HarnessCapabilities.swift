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
    /// Present *and* able to start — what a caller asking "is it there?"
    /// almost always means.
    ///
    /// `isInstalled` stopped carrying that meaning when an unlaunchable binary
    /// began keeping its `executablePath`: a probe can now be installed, at a
    /// path worth naming, and unable to run a single command. Anything that
    /// treated `isInstalled` as "usable" wants this instead. `isReady` is this
    /// plus signed in and not gated off.
    public var isLaunchable: Bool { isInstalled && isUnlaunchable != true }
    public var isReady: Bool {
        isEnabled != false && isLaunchable && authState != .notAuthenticated
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

    /// The Homebrew token to assume when the install cannot name its own.
    ///
    /// An assumption, not a fact: Anthropic publishes two casks — `claude-code`
    /// and `claude-code@latest` — and this is the stable one. Where there is a
    /// path to read, `HarnessCLIUpdater.brewToken` asks the Caskroom which one
    /// is actually installed; upgrading the wrong cask is a no-op the user
    /// cannot tell apart from a broken update button.
    public var brewFormula: String? {
        switch self {
        case .claudeCode: return "claude-code"
        case .codex: return "codex"
        case .cursorAgent: return nil
        }
    }

    /// Whether `token` is one of this CLI's Homebrew tokens.
    ///
    /// Taking the token out of a path is only safe if it is checked: an npm
    /// install under a Homebrew-managed node lives at
    /// `…/Cellar/node/24.1.0/lib/node_modules/@anthropic-ai/claude-code/…`,
    /// and reading that path's token gives `node` — a real cask, and a
    /// catastrophic thing to `brew upgrade` on the user's behalf.
    public func ownsBrewToken(_ token: String) -> Bool {
        guard let brewFormula else { return false }
        // `@`-suffixed variants (`claude-code@latest`) are the same package on
        // a different release channel, which is exactly the case this exists
        // to keep.
        return token == brewFormula || token.hasPrefix(brewFormula + "@")
    }

    /// The vendor's own install script — the one channel that needs nothing
    /// installed first.
    ///
    /// Each CLI has its own. They used to share Cursor's, which was a
    /// landmine rather than a bug: nothing reached the fallthrough, so a
    /// Claude Code install one edit away from installing cursor-agent looked
    /// fine. These are the URLs Anthropic, OpenAI and Cursor document, and
    /// they match `HarnessSetup.installCommand` in the Mac app.
    public var nativeInstallerURL: String {
        switch self {
        case .claudeCode: return "https://claude.ai/install.sh"
        case .codex: return "https://chatgpt.com/codex/install.sh"
        case .cursorAgent: return "https://cursor.com/install"
        }
    }
}
