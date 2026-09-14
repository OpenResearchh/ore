import Foundation
import OreProtocol
import OreTelemetry

/// Turns the core's event stream into the handful of anonymous events ORE
/// reports.
///
/// Deliberately a standalone value with its own state rather than methods on
/// `AppModel`. Turn duration needs the start time of each turn, and harness
/// identity lives on the chat rather than on the turn event, so something has
/// to remember a little. Keeping that here means the whole mapping can be
/// tested by feeding it a scripted `[CoreEvent]` and asserting what comes
/// out — no window, no core, no database.
///
/// Note what this deliberately ignores: `.commandFailed` carries a `detail`
/// string built from real paths and git output, and there is no safe way to
/// report it. Failure signal comes from `turn_completed`'s outcome instead.
struct TelemetryTranslator {
    /// Everything the translator needs to know about a chat to describe a
    /// turn. Populated from chat and workspace summaries as they flow past.
    private struct ChatFacts {
        var harness: HarnessTag
        var model: ModelTag
    }

    private var facts: [ChatID: ChatFacts] = [:]
    private var turnStarts: [TurnID: Date] = [:]

    /// Injected so duration bucketing is deterministic under test.
    private let now: () -> Date

    /// Whether this install has already recorded each first-time event.
    /// A local guess only — `TelemetryStore.claimMilestone` is the
    /// authority and will drop a duplicate even if this is wrong.
    private var sawFirstTurn = false
    private var sawFirstWorkspace = false
    private var sawFirstPullRequest = false

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// The single funnel. Returns the events to record, if any.
    mutating func observe(_ event: CoreEvent) -> [TelemetryEvent] {
        switch event {
        case .chatAdded(let chat), .chatUpdated(let chat):
            remember(chat)
            return []

        case .snapshot(let snapshot):
            snapshot.chats.forEach { remember($0) }
            return []

        case .agent(_, let chatID, .turnStarted(let started)):
            turnStarts[started.turnID] = now()
            // The turn's model is more accurate than the chat's, which can be
            // "whatever the default was when the chat was made".
            if started.model != nil, var known = facts[chatID] {
                known.model = ModelTag(rawModel: started.model)
                facts[chatID] = known
            }
            return []

        case .agent(_, let chatID, .turnCompleted(let result)):
            return [turnCompleted(result, chatID: chatID)]

        default:
            return []
        }
    }

    /// `workspace_created` is recorded from the command rather than the event
    /// stream: the request carries the harness and model that were actually
    /// chosen, and `.workspaceAdded` alone cannot distinguish creating a
    /// workspace from one arriving in a snapshot at launch.
    mutating func workspaceCreated(harness: HarnessKind) -> TelemetryEvent {
        let isFirst = !sawFirstWorkspace
        sawFirstWorkspace = true
        return .workspaceCreated(harness: HarnessTag(rawHarness: harness.rawValue), isFirst: isFirst)
    }

    /// Recorded when a PR is *observed on the diff*, not when one is
    /// requested. A request that fails is not a pull request, and counting it
    /// would quietly inflate the one number that says ORE works.
    mutating func pullRequestCreated() -> TelemetryEvent {
        let isFirst = !sawFirstPullRequest
        sawFirstPullRequest = true
        return .pullRequestCreated(isFirst: isFirst)
    }

    // MARK: - Private

    private mutating func remember(_ chat: ChatSummary) {
        facts[chat.id] = ChatFacts(
            harness: HarnessTag(rawHarness: chat.harness.rawValue),
            model: ModelTag(rawModel: chat.model)
        )
    }

    private mutating func turnCompleted(_ result: TurnResult, chatID: ChatID) -> TelemetryEvent {
        let started = turnStarts.removeValue(forKey: result.turnID)
        // Prefer the harness's own measurement when it reports one: it knows
        // when the model actually started work, where we only know when the
        // event reached the UI. Fall back to our own timing, and to zero for
        // a turn that was already running when the app launched (there is no
        // start to subtract, and inventing one would skew the bucket).
        let seconds = result.duration ?? started.map { now().timeIntervalSince($0) } ?? 0
        let known = facts[chatID]

        let isFirst = !sawFirstTurn
        sawFirstTurn = true

        return .turnCompleted(
            harness: known?.harness ?? .other,
            model: known?.model ?? .other,
            outcome: Self.outcome(result.outcome),
            duration: DurationBucket(seconds: seconds),
            isFirst: isFirst
        )
    }

    private static func outcome(_ outcome: TurnResult.Outcome) -> TurnOutcomeTag {
        switch outcome {
        case .completed: .completed
        case .interrupted: .interrupted
        case .failed: .failed
        case .awaitingInput: .awaitingInput
        }
    }
}
