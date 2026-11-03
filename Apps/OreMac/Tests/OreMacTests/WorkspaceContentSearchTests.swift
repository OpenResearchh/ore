import Foundation
import OreProtocol
import Testing

@testable import OreMac

struct WorkspaceContentSearchTests {
    @Test func parseLineReadsPathLineAndText() {
        let hit = WorkspaceContentSearch.parseLine("src/App.swift:12:    let x = 1")
        #expect(hit?.path == "src/App.swift")
        #expect(hit?.line == 12)
        #expect(hit?.text == "let x = 1")
    }

    @Test func parseLineRejectsAbsolutePathsAndJunk() {
        #expect(WorkspaceContentSearch.parseLine("/tmp/secret.swift:1:nope") == nil)
        #expect(WorkspaceContentSearch.parseLine("") == nil)
        #expect(WorkspaceContentSearch.parseLine("no-colon") == nil)
        #expect(WorkspaceContentSearch.parseLine("file.swift:0:zero") == nil)
    }

    @Test func searchFindsALineCaseInsensitively() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-content-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("Hello UniqueTokenXYZ\n".utf8).write(
            to: root.appendingPathComponent("note.md")
        )
        let hits = WorkspaceContentSearch.search(query: "uniquetokenxyz", in: root.path)
        #expect(hits.contains { $0.path == "note.md" && $0.text.contains("UniqueTokenXYZ") })
    }
}

struct ChatHistoryWindowTests {
    @Test func splitKeepsTheNewestTurns() {
        let turns = Array(1...10)
        let parts = ChatHistoryWindow.split(turns)
        #expect(parts.recent == Array(3...10))
        #expect(parts.older == [1, 2])
        let short = ChatHistoryWindow.split([1, 2, 3])
        #expect(short.recent == [1, 2, 3])
        #expect(short.older.isEmpty)
    }

    @Test func outlineTitlesComeFromUserPrompts() {
        let rows = [
            TranscriptRow(id: "u1", turnID: TurnID(rawValue: "t1"), kind: .userMessage, text: "Fix the crash\nin tests"),
            TranscriptRow(id: "a1", turnID: TurnID(rawValue: "t1"), kind: .assistantText, text: "Sure"),
            TranscriptRow(
                id: "u2",
                turnID: TurnID(rawValue: "t2"),
                kind: .userMessage,
                text: String(repeating: "a", count: 80)
            ),
        ]
        let items = ChatOutlineItem.items(from: rows)
        #expect(items.map(\.row) == [0, 2])
        #expect(items[0].title == "Fix the crash")
        #expect(items[1].title.hasSuffix("…"))
        #expect(items[1].title.count == 42)
    }
}

struct ShellSnippetTests {
    @Test func runnableLanguagesAreShellsOnly() {
        #expect(ShellSnippet.isRunnable("bash"))
        #expect(ShellSnippet.isRunnable("ZSH"))
        #expect(!ShellSnippet.isRunnable("swift"))
        #expect(!ShellSnippet.isRunnable(nil))
    }

    @Test func executeCapturesStdoutFromTheWorktree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-snippet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("marker-xyz\n".utf8).write(to: root.appendingPathComponent("f.txt"))
        let result = ShellSnippet.execute("cat f.txt", worktree: root.path)
        #expect(result.status == .succeeded)
        #expect(result.output.contains("marker-xyz"))
    }

    @Test func runURLRoundTripsThroughTranscriptLink() {
        let url = ShellSnippet.runURL(command: "ls")
        #expect(url.scheme == "ore-run")
        #expect(MarkdownRenderer.TranscriptLink.parse(url) == .runSnippet(ShellSnippet.id(for: "ls")))
    }
}
