import Foundation
import Testing

@testable import OreHarness
@testable import OreProtocol

/// Every harness can leave work running after a call returns. Each reports it
/// its own way — Claude Code as a pushed level, Cursor as tool results and
/// completion lines, Codex only on request — and each has to reach the composer
/// as the same `backgroundTasksChanged` set.
struct BackgroundWorkTranslationTests {
    // MARK: - Codex

    @Test func codexTerminalsBecomeTheLiveSetWithReadableCommands() {
        let list: JSONValue = .object([
            "data": .array([
                .object([
                    "itemId": .string("item-1"),
                    "processId": .string("1234"),
                    "osPid": .integer(95461),
                ]),
                .object([
                    "itemId": .string("item-2"),
                    "processId": .integer(77),
                    "command": .string("/bin/zsh -lc 'npm run dev'"),
                ]),
            ]),
            "nextCursor": .null,
        ])
        let tasks = CodexTranslator.backgroundTasks(
            fromTerminalList: list,
            commands: ["item-1": "/bin/zsh -lc 'swift test --filter Engine'"]
        )
        #expect(tasks.map(\.id) == ["1234", "77"])
        // Recovered from the item that started it when the entry has no command.
        #expect(tasks.first?.description == "swift test --filter Engine")
        #expect(tasks.last?.description == "npm run dev")
    }

    @Test func anEmptyCodexListIsAnEmptySet() {
        let list: JSONValue = .object(["data": .array([]), "nextCursor": .null])
        #expect(CodexTranslator.backgroundTasks(fromTerminalList: list, commands: [:]).isEmpty)
    }

    @Test func codexAsksAgainOnlyWhenTheSetCanHaveMoved() {
        #expect(CodexSession.backgroundTerminalsMayHaveChanged(method: "turn/completed"))
        #expect(CodexSession.backgroundTerminalsMayHaveChanged(method: "process/exited"))
        #expect(!CodexSession.backgroundTerminalsMayHaveChanged(method: "item/agentMessage/delta"))
    }

    @Test func aCommandWithoutAShellWrapperIsLeftAlone() {
        #expect(CodexTranslator.readableCommand("git status") == "git status")
        #expect(CodexTranslator.readableCommand("/bin/bash -lc \"make build\"") == "make build")
    }

    // MARK: - Cursor

    private func cursorSets(
        _ lines: [String],
        exitCode: Int32? = nil
    ) -> [[AgentBackgroundTask]] {
        var translator = CursorAgentTranslator(sessionID: SessionID.generate())
        var events = lines.flatMap { translator.translate(line: $0).events }
        if let exitCode { events += translator.closeTurn(exitCode: exitCode).events }
        return events.compactMap {
            if case .backgroundTasksChanged(let tasks) = $0 { return tasks }
            return nil
        }
    }

    private let backgroundShell = #"{"type":"tool_call","subtype":"completed","call_id":"c1","tool_call":{"shellToolCall":{"args":{"command":"swift build","description":"Build the app","isBackground":true},"result":{"success":{"shellId":898306,"pid":95461},"isBackground":true}}}}"#

    @Test func aCursorBackgroundShellIsTrackedUntilItsNotification() {
        let sets = cursorSets([
            backgroundShell,
            #"{"type":"system","subtype":"task_notification","task_id":"898306","status":"completed","title":"Build the app","session_id":"s"}"#,
        ])
        #expect(sets.count == 2)
        #expect(sets.first?.map(\.id) == ["898306"])
        #expect(sets.first?.first?.description == "Build the app")
        #expect(sets.last?.isEmpty == true)
    }

    /// A foreground shell carries no background flag and must not appear.
    @Test func aCursorForegroundShellIsNotBackgroundWork() {
        let sets = cursorSets([
            #"{"type":"tool_call","subtype":"completed","call_id":"c2","tool_call":{"shellToolCall":{"args":{"command":"git status","isBackground":false},"result":{"success":{"stdout":"clean","exitCode":0}}}}}"#,
        ])
        #expect(sets.isEmpty)
    }

    /// Nothing a one-shot process started outlives it, and no notification will
    /// come for it — the exit itself has to clear the set.
    @Test func cursorBackgroundWorkEndsWithTheProcess() {
        let sets = cursorSets([backgroundShell], exitCode: 0)
        #expect(sets.map(\.count) == [1, 0])
    }

    @Test func aNotificationForUnknownWorkChangesNothing() {
        let sets = cursorSets([
            #"{"type":"system","subtype":"task_notification","task_id":"42","status":"completed"}"#,
        ])
        #expect(sets.isEmpty)
    }
}
