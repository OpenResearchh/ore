import Foundation
import OreProtocol
import OreTelemetry
import Testing

@testable import OreMac

/// Feeds the translator a scripted core-event stream and asserts exactly what
/// comes out. This is the reason the mapping is a standalone struct rather
/// than methods on `AppModel`: no window, no core, no database, and a clock
/// we control, so duration bucketing is deterministic.
@Suite("Core events translate to the right telemetry")
struct TelemetryTranslationTests {
    /// A clock the test advances by hand.
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000)
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private func chat(
        _ id: ChatID,
        workspace: WorkspaceID,
        harness: HarnessKind = .claudeCode,
        model: String? = "claude-sonnet-4-5-20250929"
    ) -> ChatSummary {
        ChatSummary(
            id: id,
            workspaceID: workspace,
            title: "fix the login bug",
            harness: harness,
            model: model
        )
    }

    @Test("A turn start and finish becomes one turn_completed with a duration")
    func turnRoundTrip() {
        let clock = Clock()
        var translator = TelemetryTranslator(now: { clock.now })
        let workspace = WorkspaceID("ws-1")
        let chatID = ChatID("chat-1")
        let turn = TurnID("turn-1")

        #expect(translator.observe(.chatAdded(chat(chatID, workspace: workspace))).isEmpty)
        #expect(
            translator.observe(
                .agent(workspace, chatID, .turnStarted(TurnStarted(turnID: turn)))
            ).isEmpty,
            "a turn starting is not itself reportable"
        )

        clock.advance(90)

        let events = translator.observe(
            .agent(
                workspace, chatID,
                .turnCompleted(TurnResult(turnID: turn, outcome: .completed))
            )
        )

        #expect(events.count == 1)
        guard case .turnCompleted(let harness, let model, let outcome, let duration, let isFirst) =
            events.first
        else {
            Issue.record("expected turn_completed, got \(String(describing: events.first))")
            return
        }
        #expect(harness == .claudeCode)
        #expect(model == .sonnet, "the model string should collapse to a family token")
        #expect(outcome == .completed)
        #expect(duration == .to5m, "90s falls in the 1–5m bucket")
        #expect(isFirst)
    }

    @Test("Only the first turn is flagged as first")
    func firstTurnIsOnlyOnce() {
        let clock = Clock()
        var translator = TelemetryTranslator(now: { clock.now })
        let workspace = WorkspaceID("ws-1")
        let chatID = ChatID("chat-1")
        _ = translator.observe(.chatAdded(chat(chatID, workspace: workspace)))

        var flags: [Bool] = []
        for index in 0..<3 {
            let turn = TurnID(rawValue: "turn-\(index)")
            _ = translator.observe(
                .agent(workspace, chatID, .turnStarted(TurnStarted(turnID: turn)))
            )
            let events = translator.observe(
                .agent(
                    workspace, chatID,
                    .turnCompleted(TurnResult(turnID: turn, outcome: .completed))
                )
            )
            if case .turnCompleted(_, _, _, _, let isFirst) = events.first { flags.append(isFirst) }
        }
        #expect(flags == [true, false, false])
    }

    @Test("A failed turn reports its outcome, and nothing else about it")
    func failureOutcome() {
        let clock = Clock()
        var translator = TelemetryTranslator(now: { clock.now })
        let workspace = WorkspaceID("ws-1")
        let chatID = ChatID("chat-1")
        let turn = TurnID("turn-1")
        _ = translator.observe(.chatAdded(chat(chatID, workspace: workspace)))
        _ = translator.observe(
            .agent(workspace, chatID, .turnStarted(TurnStarted(turnID: turn)))
        )

        let events = translator.observe(
            .agent(
                workspace, chatID,
                .turnCompleted(
                    TurnResult(
                        turnID: turn,
                        outcome: .failed,
                        summary: "error: cannot open /Users/tushar/secret/app.swift"
                    )
                )
            )
        )

        guard case .turnCompleted(_, _, let outcome, _, _) = events.first else {
            Issue.record("expected turn_completed")
            return
        }
        #expect(outcome == .failed)

        // The summary carried a real path. Nothing in the emitted properties
        // may contain it — this is the case that would leak if anyone ever
        // "helpfully" added a failure-reason string.
        let rendered = events.first!.properties.description
        #expect(!rendered.contains("/Users/"))
        #expect(!rendered.contains("secret"))
    }

    @Test("A turn that finishes with no recorded start does not crash or invent a duration")
    func unmatchedTurnCompletion() {
        let clock = Clock()
        var translator = TelemetryTranslator(now: { clock.now })
        let workspace = WorkspaceID("ws-1")
        let chatID = ChatID("chat-1")
        _ = translator.observe(.chatAdded(chat(chatID, workspace: workspace)))

        // Happens for real: a turn already running when the app launched.
        let events = translator.observe(
            .agent(
                workspace, chatID,
                .turnCompleted(TurnResult(turnID: TurnID("orphan"), outcome: .completed))
            )
        )
        guard case .turnCompleted(_, _, _, let duration, _) = events.first else {
            Issue.record("expected turn_completed")
            return
        }
        #expect(duration == .under5s)
    }

    @Test("Ordinary chatter reports nothing at all")
    func mostEventsAreSilent() {
        let clock = Clock()
        var translator = TelemetryTranslator(now: { clock.now })
        let workspace = WorkspaceID("ws-1")

        #expect(translator.observe(.workspaceRemoved(workspace)).isEmpty)
        #expect(
            translator.observe(
                .commandFailed(CommandFailure(message: "boom", detail: "/Users/tushar/x.swift"))
            ).isEmpty,
            "commandFailed carries real paths in `detail` and must never be reported"
        )
    }

    @Test("Workspace creation reports the harness and flags only the first")
    func workspaceCreation() {
        var translator = TelemetryTranslator()
        guard case .workspaceCreated(let harness, let isFirst) =
            translator.workspaceCreated(harness: .codex)
        else {
            Issue.record("expected workspace_created")
            return
        }
        #expect(harness == .codex)
        #expect(isFirst)

        guard case .workspaceCreated(_, let secondIsFirst) =
            translator.workspaceCreated(harness: .claudeCode)
        else { return }
        #expect(!secondIsFirst)
    }

    @Test("Pull request creation flags only the first")
    func pullRequestCreation() {
        var translator = TelemetryTranslator()
        guard case .pullRequestCreated(let first) = translator.pullRequestCreated() else {
            Issue.record("expected pull_request_created")
            return
        }
        #expect(first)
        guard case .pullRequestCreated(let second) = translator.pullRequestCreated() else { return }
        #expect(!second)
    }
}
