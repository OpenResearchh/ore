import Foundation
import Observation
import OreProtocol
import Testing

@testable import OreMac

/// The per-workspace chat index, the diff refresh gate and the telemetry
/// translator's pruning: the pieces that keep AppModel's reads cheap and its
/// per-chat memory bounded.
@MainActor
@Suite("App state stays indexed and bounded")
struct AppStateMemoryTests {
    private final class Flag: @unchecked Sendable {
        var fired = false
    }

    private func chat(
        _ id: String,
        workspace: String = "ws-1",
        at seconds: TimeInterval,
        title: String = "tab",
        isClosed: Bool = false
    ) -> ChatSummary {
        ChatSummary(
            id: ChatID(rawValue: id),
            workspaceID: WorkspaceID(rawValue: workspace),
            title: title,
            harness: .claudeCode,
            isClosed: isClosed,
            createdAt: Date(timeIntervalSince1970: seconds)
        )
    }

    /// Whether reading `read` would have been invalidated by `mutate`.
    private func notifies(_ read: () -> Void, when mutate: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking(read, onChange: { flag.fired = true })
        mutate()
        return flag.fired
    }

    // MARK: - ChatIndex

    @Test("Chats come back oldest first, with equal timestamps in arrival order")
    func ordering() {
        let index = ChatIndex()
        index.upsert(chat("b", at: 20))
        index.upsert(chat("a", at: 10))
        index.upsert(chat("c", at: 20))
        #expect(index.chats(for: WorkspaceID("ws-1"), includeClosed: false).map(\.id.rawValue)
            == ["a", "b", "c"])
    }

    @Test("A closed chat leaves the open list but stays in the full one")
    func closing() {
        let index = ChatIndex()
        let workspace = WorkspaceID("ws-1")
        index.upsert(chat("a", at: 10))
        index.upsert(chat("b", at: 20))
        index.upsert(chat("a", at: 10, isClosed: true))
        #expect(index.chats(for: workspace, includeClosed: false).map(\.id.rawValue) == ["b"])
        #expect(index.chats(for: workspace, includeClosed: true).map(\.id.rawValue) == ["a", "b"])
        #expect(index.summary(for: ChatID("a"))?.isClosed == true)
    }

    @Test("Workspaces are observed independently, and equal writes notify no one")
    func observationScope() {
        let index = ChatIndex()
        index.upsert(chat("a", workspace: "ws-1", at: 10))
        index.upsert(chat("b", workspace: "ws-2", at: 10))
        let first = index.list(for: WorkspaceID("ws-1"))

        #expect(!notifies({ _ = first.all }, when: {
            index.upsert(chat("b", workspace: "ws-2", at: 10, title: "renamed"))
        }), "another workspace's chat changing must not redraw this tab strip")
        #expect(!notifies({ _ = first.all }, when: {
            index.upsert(chat("a", workspace: "ws-1", at: 10))
        }), "an identical summary is not a change")
        #expect(notifies({ _ = first.all }, when: {
            index.upsert(chat("a", workspace: "ws-1", at: 10, title: "renamed"))
        }))
    }

    @Test("A snapshot rebuilds every list and empties workspaces that lost their chats")
    func snapshot() {
        let index = ChatIndex()
        index.upsert(chat("stale", workspace: "ws-gone", at: 5))
        index.replaceAll([
            chat("b", at: 20),
            chat("a", at: 10),
            chat("x", workspace: "ws-2", at: 1),
        ])
        #expect(index.chats(for: WorkspaceID("ws-1"), includeClosed: true).map(\.id.rawValue)
            == ["a", "b"])
        #expect(index.chats(for: WorkspaceID("ws-gone"), includeClosed: true).isEmpty)
        #expect(index.summary(for: ChatID("stale")) == nil)
    }

    @Test("Removing a workspace hands back its chats and forgets them")
    func removeWorkspace() {
        let index = ChatIndex()
        index.upsert(chat("a", at: 10))
        index.upsert(chat("b", at: 20, isClosed: true))
        let removed = index.removeWorkspace(WorkspaceID("ws-1"))
        #expect(Set(removed.map(\.rawValue)) == ["a", "b"])
        #expect(index.summary(for: ChatID("a")) == nil)
        #expect(index.chats(for: WorkspaceID("ws-1"), includeClosed: true).isEmpty)
    }

    @Test("A chat that moves workspace is listed only in its new one")
    func move() {
        let index = ChatIndex()
        index.upsert(chat("a", workspace: "ws-1", at: 10))
        index.upsert(chat("a", workspace: "ws-2", at: 10))
        #expect(index.chats(for: WorkspaceID("ws-1"), includeClosed: true).isEmpty)
        #expect(index.chats(for: WorkspaceID("ws-2"), includeClosed: true).map(\.id.rawValue) == ["a"])
    }

    // MARK: - Diff cache

    @Test("Storing an identical diff snapshot does not redraw its readers")
    func diffStateEquality() {
        let state = WorkspaceDiffState()
        let snapshot = AppModel.DiffSnapshot(generation: 1, diffs: [], gitAction: .none, pullRequest: nil)
        state.store(snapshot)
        #expect(!notifies({ _ = state.snapshot }, when: { state.store(snapshot) }))
        var next = snapshot
        next.generation = 2
        #expect(notifies({ _ = state.snapshot }, when: { state.store(next) }))
    }

    @Test("Each workspace's cached diff is its own observable")
    func diffRegistryScope() {
        let registry = WorkspaceDiffRegistry()
        let first = registry.state(for: WorkspaceID("ws-1"))
        let snapshot = AppModel.DiffSnapshot(generation: 3, diffs: [], gitAction: .none, pullRequest: nil)
        #expect(!notifies({ _ = first.snapshot }, when: {
            registry.state(for: WorkspaceID("ws-2")).store(snapshot)
        }))
        first.store(snapshot)
        registry.remove(WorkspaceID("ws-1"))
        #expect(first.snapshot == nil, "a pane still holding the removed state is cleared")
        #expect(registry.state(for: WorkspaceID("ws-1")).snapshot == nil)
    }

    // MARK: - RefreshGate

    @Test("An older diff finishing last cannot replace the newer generation")
    func outOfOrderDiffs() {
        let state = WorkspaceDiffState()
        let newer = AppModel.DiffSnapshot(generation: 2, diffs: [], gitAction: .none, pullRequest: nil)
        state.store(newer)
        state.store(AppModel.DiffSnapshot(generation: 1, diffs: [], gitAction: .none, pullRequest: nil))
        #expect(state.snapshot == newer)
    }

    @Test("Reopening an archived workspace does not adopt an old refresh")
    func releasedDiffIdentity() {
        let registry = WorkspaceDiffRegistry()
        let id = WorkspaceID("ws-1")
        let old = registry.state(for: id)
        #expect(registry.contains(old, for: id))
        registry.remove(id)
        let reopened = registry.state(for: id)
        #expect(!registry.contains(old, for: id))
        #expect(registry.contains(reopened, for: id))
    }

    @Test("Requests during a refresh collapse into one trailing run")
    func gateCollapses() {
        var gate = RefreshGate<String>()
        let request1 = gate.request("ws")
        #expect(request1)
        let request2 = gate.request("ws")
        #expect(!request2)
        let request3 = gate.request("ws")
        #expect(!request3)
        let finish4 = gate.finish("ws")
        #expect(finish4, "one trailing run for the requests that arrived")
        #expect(gate.isInFlight("ws"))
        let finish5 = gate.finish("ws")
        #expect(!finish5, "nothing arrived during the trailing run")
        #expect(!gate.isInFlight("ws"))
        let request6 = gate.request("ws")
        #expect(request6)
    }

    @Test("Keys are independent, and cancelling clears both flags")
    func gateKeys() {
        var gate = RefreshGate<String>()
        let request7 = gate.request("a")
        #expect(request7)
        let request8 = gate.request("b")
        #expect(request8)
        let request9 = gate.request("a")
        #expect(!request9)
        gate.cancel("a")
        #expect(!gate.isInFlight("a"))
        let request10 = gate.request("a")
        #expect(request10)
        #expect(gate.isInFlight("b"))
    }

    // MARK: - Telemetry pruning

    @Test("A turn that never completes is dropped when its chat starts another or goes away")
    func translatorPrunes() {
        var translator = TelemetryTranslator(now: { Date(timeIntervalSince1970: 0) })
        let workspace = WorkspaceID("ws-1")
        let chatID = ChatID("chat-1")

        _ = translator.observe(.agent(workspace, chatID, .turnStarted(TurnStarted(turnID: TurnID("t1")))))
        _ = translator.observe(.agent(workspace, chatID, .turnStarted(TurnStarted(turnID: TurnID("t2")))))
        #expect(translator.pendingTurnCount == 1, "a chat runs one turn at a time")

        _ = translator.observe(.agent(
            workspace, ChatID("chat-2"), .turnStarted(TurnStarted(turnID: TurnID("t3")))
        ))
        #expect(translator.pendingTurnCount == 2)

        translator.forget(chatID)
        #expect(translator.pendingTurnCount == 1)

        _ = translator.observe(.agent(
            workspace, ChatID("chat-2"),
            .turnCompleted(TurnResult(turnID: TurnID("t3"), outcome: .failed))
        ))
        #expect(translator.pendingTurnCount == 0, "a failed turn is finished too")
    }
}
