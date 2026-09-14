import Foundation
import OreProtocol
import Testing

@testable import OreMac

/// A turn that hands work off — a build, a test run — used to end looking like
/// a chat with nothing left to do. The composer now says what it is waiting on.
@MainActor
struct BackgroundWaitTests {
    private let build = AgentBackgroundTask(
        id: "b1", kind: "local_bash", description: "Build OreMac and run tests"
    )
    private let lint = AgentBackgroundTask(id: "b2", kind: "local_bash", description: "Lint")

    @Test func theLiveSetIsReplacedNotAccumulated() {
        let state = ChatState()
        state.apply(.backgroundTasksChanged([build, lint]))
        #expect(state.backgroundTasks.map(\.id) == ["b1", "b2"])

        state.apply(.backgroundTasksChanged([lint]))
        #expect(state.backgroundTasks.map(\.id) == ["b2"])

        state.apply(.backgroundTasksChanged([]))
        #expect(state.backgroundTasks.isEmpty)
        #expect(state.backgroundWaitStartedAt == nil)
    }

    /// Waiting is not working: the composer must stay free for the user.
    @Test func waitingOnBackgroundWorkIsNotBusy() {
        let state = ChatState()
        state.apply(.backgroundTasksChanged([build]))
        #expect(!state.isBusy)
        #expect(state.backgroundWaitStartedAt != nil)
    }

    /// A second task joining is the same wait, so the clock keeps running.
    @Test func theWaitClockSurvivesATaskJoining() throws {
        let state = ChatState()
        state.apply(.backgroundTasksChanged([build]))
        let started = try #require(state.backgroundWaitStartedAt)
        state.apply(.backgroundTasksChanged([build, lint]))
        #expect(state.backgroundWaitStartedAt == started)
    }

    @Test func theLabelNamesOneTaskAndCountsSeveral() {
        #expect(ComposerBusyCopy.waitingLabel([build]) == "Waiting on background work · Build OreMac and run tests")
        #expect(ComposerBusyCopy.waitingLabel([build, lint]) == "Waiting on 2 background tasks")
        #expect(ComposerBusyCopy.waitingLabel([
            AgentBackgroundTask(id: "b3", description: "  ")
        ]) == "Waiting on a background task")
        #expect(ComposerBusyCopy.waitingLabel([]).isEmpty)
    }
}
