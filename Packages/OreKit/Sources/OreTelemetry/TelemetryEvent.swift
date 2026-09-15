import Foundation

// This file is the complete list of everything ORE ever reports about how it
// is used. If it is not in `TelemetryEvent`, it does not leave the machine.
//
// The design goal is that the privacy promise is checkable by reading one
// file, and unbreakable by anyone who has not read it. Three things enforce
// that, all at compile time:
//
//   1. `TelemetryEvent` is a closed enum. There is no `case custom(String,
//      [String: Any])`, so a call site cannot invent an event.
//   2. No property value can hold a free-form String. `TelemetryValue` admits
//      Bool, Int, and `TelemetryTag` — and `TelemetryTag`'s only public
//      initializer takes a `TelemetryVocabulary`, which is always a closed
//      enum defined below. A file path or a branch name has no route in.
//   3. `auditCatalogue` + `TelemetryPayloadTests` prove it, by serializing one
//      of every case built from deliberately hostile values and asserting
//      nothing sensitive survives.
//
// What is deliberately never collected, at any granularity: prompt text,
// agent output, diffs, file paths, repository names, branch names, commit
// messages.

// MARK: - Vocabulary

/// A closed set of strings that is safe to report.
///
/// The point is the absence of a `String` initializer on `TelemetryTag`.
/// Conforming an enum here is a deliberate act that shows up in review;
/// passing a string that happens to contain a customer's repo name is not
/// something the type system will let anyone do by accident.
public protocol TelemetryVocabulary: Sendable {
    var telemetryToken: String { get }
}

/// A string that provably came from a closed vocabulary.
public struct TelemetryTag: Sendable, Hashable {
    public let rawValue: String

    private init(unchecked value: String) { self.rawValue = value }

    public init<V: TelemetryVocabulary>(_ vocabulary: V) {
        self.init(unchecked: vocabulary.telemetryToken)
    }
}

/// A property value. Numbers, flags, and vocabulary tags — nothing else.
public enum TelemetryValue: Sendable, Hashable {
    case flag(Bool)
    case count(Int)
    case tag(TelemetryTag)

    public init<V: TelemetryVocabulary>(_ vocabulary: V) { self = .tag(TelemetryTag(vocabulary)) }
}

// MARK: - Closed vocabularies

public enum HarnessTag: String, TelemetryVocabulary, CaseIterable {
    case claudeCode, codex, cursorAgent, other
    public var telemetryToken: String { rawValue }

    /// Harness identifiers are ours, not user data, but they still arrive as
    /// strings from the protocol layer. Mapping through a closed set means a
    /// future harness id cannot widen what gets reported without a code change.
    public init(rawHarness: String) {
        switch rawHarness.lowercased() {
        case "claude", "claudecode", "claude-code": self = .claudeCode
        case "codex": self = .codex
        case "cursor", "cursoragent", "cursor-agent": self = .cursorAgent
        default: self = .other
        }
    }
}

/// The one place an unbounded external string is reduced to a safe token.
///
/// Model identifiers come from the harness CLIs, so their shape is not ours to
/// control — `claude-sonnet-4-5-20250929` today, anything at all tomorrow.
/// Reporting them raw would mean shipping an unbounded string, which is
/// exactly the hole the rest of this file exists to close. Unknown values
/// collapse to `.other` and the original is discarded.
public enum ModelTag: String, TelemetryVocabulary, CaseIterable {
    case opus, sonnet, haiku, gpt, gemini, other
    case oSeries = "o-series"
    public var telemetryToken: String { rawValue }

    public init(rawModel: String?) {
        guard let raw = rawModel?.lowercased(), !raw.isEmpty else { self = .other; return }
        if raw.contains("opus") { self = .opus }
        else if raw.contains("sonnet") { self = .sonnet }
        else if raw.contains("haiku") { self = .haiku }
        else if raw.contains("gemini") { self = .gemini }
        else if raw.hasPrefix("o1") || raw.hasPrefix("o3") || raw.hasPrefix("o4") { self = .oSeries }
        else if raw.contains("gpt") { self = .gpt }
        else { self = .other }
    }
}

public enum TurnOutcomeTag: String, TelemetryVocabulary, CaseIterable {
    case completed, interrupted, failed, awaitingInput
    public var telemetryToken: String { rawValue }
}

public enum LaunchReason: String, TelemetryVocabulary, CaseIterable {
    case cold, afterUpdate
    public var telemetryToken: String { rawValue }
}

public enum InstallChannel: String, TelemetryVocabulary, CaseIterable {
    case installScript = "install.sh"
    case homebrew, dmg, unknown
    public var telemetryToken: String { rawValue }

    /// Written by install.sh / the Homebrew cask into `~/ore/install-channel`.
    /// Deliberately outside the app bundle: writing there would break the code
    /// signature seal, and the updater replaces the bundle on every update.
    public init(marker: String?) {
        switch marker?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "install.sh": self = .installScript
        case "homebrew": self = .homebrew
        case "dmg": self = .dmg
        default: self = .unknown
        }
    }
}

// MARK: - Buckets

// Buckets are a privacy control, not tidiness. An exact duration in
// milliseconds or an exact file count is a fingerprinting surface: enough of
// them together identify a person even with no name attached. Coarse buckets
// answer every product question we actually have ("are turns getting slower?")
// while carrying far less identifying signal.

public enum DurationBucket: String, TelemetryVocabulary, CaseIterable {
    case under5s = "lt5s"
    case to15s = "5-15s"
    case to60s = "15-60s"
    case to5m = "1-5m"
    case to15m = "5-15m"
    case over15m = "15m+"
    public var telemetryToken: String { rawValue }

    public init(seconds: Double) {
        switch seconds {
        case ..<5: self = .under5s
        case ..<15: self = .to15s
        case ..<60: self = .to60s
        case ..<300: self = .to5m
        case ..<900: self = .to15m
        default: self = .over15m
        }
    }
}

public enum DayBucket: String, TelemetryVocabulary, CaseIterable {
    case sameDay = "d0"
    case nextDay = "d1"
    case firstWeek = "d2-6"
    case firstMonth = "d7-29"
    case beyond = "d30+"
    public var telemetryToken: String { rawValue }

    public init(days: Int) {
        switch days {
        case ..<1: self = .sameDay
        case 1: self = .nextDay
        case 2...6: self = .firstWeek
        case 7...29: self = .firstMonth
        default: self = .beyond
        }
    }
}

// MARK: - Events

/// Everything ORE reports. Adding a case here is the only way to report
/// anything new, and `TelemetryPayloadTests` will fail until the new case is
/// added to `auditCatalogue` too.
public enum TelemetryEvent: Sendable, Hashable {
    /// Fired once ever, the first time an install ID is minted.
    case appInstalled(channel: InstallChannel)

    /// The workhorse: DAU/WAU/MAU, retention cohorts, version adoption.
    case appLaunched(reason: LaunchReason, daysSinceInstall: DayBucket)

    /// Activation step one — did they actually try it?
    case workspaceCreated(harness: HarnessTag, isFirst: Bool)

    /// Core usage volume, harness mix, and the turn failure rate.
    case turnCompleted(
        harness: HarnessTag,
        model: ModelTag,
        outcome: TurnOutcomeTag,
        duration: DurationBucket,
        isFirst: Bool
    )

    /// The value moment. The number that says ORE actually works.
    case pullRequestCreated(isFirst: Bool)

    /// Sent alone, after the queue has been deleted, so the denominator for
    /// every other metric stays honest rather than quietly shrinking. See
    /// `TelemetryClient.optOut`.
    case telemetryOptOut

    public var name: String {
        switch self {
        case .appInstalled: "app_installed"
        case .appLaunched: "app_launched"
        case .workspaceCreated: "workspace_created"
        case .turnCompleted: "turn_completed"
        case .pullRequestCreated: "pull_request_created"
        case .telemetryOptOut: "telemetry_opt_out"
        }
    }

    public var properties: [String: TelemetryValue] {
        switch self {
        case .appInstalled(let channel):
            ["install_channel": TelemetryValue(channel)]
        case .appLaunched(let reason, let days):
            ["launch_reason": TelemetryValue(reason), "days_since_install": TelemetryValue(days)]
        case .workspaceCreated(let harness, let isFirst):
            ["harness": TelemetryValue(harness), "is_first": .flag(isFirst)]
        case .turnCompleted(let harness, let model, let outcome, let duration, let isFirst):
            [
                "harness": TelemetryValue(harness),
                "model": TelemetryValue(model),
                "outcome": TelemetryValue(outcome),
                "duration": TelemetryValue(duration),
                "is_first": .flag(isFirst),
            ]
        case .pullRequestCreated(let isFirst):
            ["is_first": .flag(isFirst)]
        case .telemetryOptOut:
            [:]
        }
    }

    /// Milestone events fire at most once per install, tracked locally, so the
    /// activation funnel survives retries, clock skew and reinstalls of the
    /// app (the install ID lives in `~/ore`, not in the bundle).
    public var milestoneKey: String? {
        switch self {
        case .appInstalled: "installed"
        case .workspaceCreated(_, let isFirst): isFirst ? "first_workspace" : nil
        case .turnCompleted(_, _, _, _, let isFirst): isFirst ? "first_turn" : nil
        case .pullRequestCreated(let isFirst): isFirst ? "first_pr" : nil
        default: nil
        }
    }

    /// True when this event happens once per install and nothing else — losing
    /// it after the milestone is claimed is correct, because a second
    /// `app_installed` would be a miscount.
    public var isInstallOnly: Bool {
        if case .appInstalled = self { return true }
        return false
    }

    /// The same event with its first-time flag cleared.
    ///
    /// The translator's "have I seen one yet" flags reset on every launch, so
    /// the first turn, workspace or PR of each later session claims a milestone
    /// that is already taken. Those events still happened; only the claim of
    /// being first is wrong, and dropping them made a user who opens one pull
    /// request per session report `pull_request_created` exactly once ever.
    public var notFirst: TelemetryEvent? {
        switch self {
        case .workspaceCreated(let harness, _):
            .workspaceCreated(harness: harness, isFirst: false)
        case .turnCompleted(let harness, let model, let outcome, let duration, _):
            .turnCompleted(
                harness: harness, model: model, outcome: outcome,
                duration: duration, isFirst: false
            )
        case .pullRequestCreated:
            .pullRequestCreated(isFirst: false)
        case .appInstalled:
            nil
        default:
            self
        }
    }
}

// MARK: - Audit

extension TelemetryEvent {
    /// One instance of every case, built from values chosen to be as hostile
    /// as the type system allows. `ModelTag` is the only door an outside
    /// string can walk through, so it gets a path and a secret in it; if
    /// mapping ever regresses to passing the raw value along, the audit test
    /// fails rather than a customer's directory name shipping to PostHog.
    ///
    /// The exhaustive `switch` in `TelemetryPayloadTests` means a new event
    /// cannot be added without being added here and consciously audited.
    public static var auditCatalogue: [TelemetryEvent] {
        let hostileModel = ModelTag(rawModel: "/Users/ada/code/secret-startup feature/fix-the-thing")
        return [
            .appInstalled(channel: .installScript),
            .appLaunched(reason: .cold, daysSinceInstall: .firstWeek),
            .workspaceCreated(harness: .claudeCode, isFirst: true),
            .turnCompleted(
                harness: .codex,
                model: hostileModel,
                outcome: .failed,
                duration: .to5m,
                isFirst: false
            ),
            .pullRequestCreated(isFirst: true),
            .telemetryOptOut,
        ]
    }

    /// Every property key any event can emit. The audit test asserts nothing
    /// outside this set ever appears in a payload.
    public static var allowedPropertyKeys: Set<String> {
        [
            "install_channel", "launch_reason", "days_since_install",
            "harness", "model", "outcome", "duration", "is_first",
        ]
    }

    /// Every key a serialized payload may contain: the per-event properties
    /// above, the context attached to all of them, and the two PostHog
    /// directives that suppress IP and geo capture. Asserted against the
    /// encoded JSON, not against `properties`, so a context or envelope key
    /// cannot slip past the audit.
    public static var allowedPayloadKeys: Set<String> {
        allowedPropertyKeys.union([
            "distinct_id", "app_version", "build", "os_version", "arch",
            "install_channel", "session_id", "$ip", "$geoip_disable",
        ])
    }
}
