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

    @Test func parseLineStripsDotSlashPrefixes() {
        let hit = WorkspaceContentSearch.parseLine("./note.md:1:Hello UniqueTokenXYZ")
        #expect(hit?.path == "note.md")
        #expect(hit?.line == 1)
        #expect(hit?.text == "Hello UniqueTokenXYZ")
        let nested = WorkspaceContentSearch.parseLine("././src/App.swift:3:x")
        #expect(nested?.path == "src/App.swift")
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

    @Test func transitionsStayWithTheWindowTheyOccurredIn() {
        let chat = ChatID(rawValue: "c1")
        let olderMark = ChatTransition(
            id: "old",
            chatID: chat,
            kind: .modelChanged,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let recentMark = ChatTransition(
            id: "new",
            chatID: chat,
            kind: .harnessChanged,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        let parts = ChatHistoryWindow.splitTransitions(
            [olderMark, recentMark],
            recentStart: Date(timeIntervalSince1970: 200)
        )
        #expect(parts.older.map(\.id) == ["old"])
        #expect(parts.recent.map(\.id) == ["new"])
        let allRecent = ChatHistoryWindow.splitTransitions(
            [olderMark, recentMark],
            recentStart: nil
        )
        #expect(allRecent.older.isEmpty)
        #expect(allRecent.recent.map(\.id) == ["old", "new"])
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
        let url = ShellSnippet.runURL(command: "ls", worktree: "/tmp/tree")
        #expect(url.scheme == "ore-run")
        #expect(
            MarkdownRenderer.TranscriptLink.parse(url)
                == .runSnippet(ShellSnippet.id(for: "ls", worktree: "/tmp/tree"))
        )
    }

    @Test func snippetIDsAreScopedToTheWorktree() {
        #expect(
            ShellSnippet.id(for: "ls", worktree: "/tmp/a")
                != ShellSnippet.id(for: "ls", worktree: "/tmp/b")
        )
    }

    @Test func executeDrainsLargeStdoutWithoutStalling() {
        let result = ShellSnippet.execute(
            "for i in {1..8000}; do echo 0123456789abcdefghij; done",
            worktree: "/tmp"
        )
        #expect(result.status == .succeeded)
        #expect(result.output.contains("truncated") || result.output.count > 1_000)
    }
}

struct RemoteHTTPLimitsTests {
    @Test func contentLengthRejectsNegativeAndOversizedValues() {
        #expect(RemoteHTTPLimits.contentLength(from: "GET / HTTP/1.1") == .missing)
        #expect(RemoteHTTPLimits.contentLength(from: "Content-Length: 12") == .valid(12))
        #expect(RemoteHTTPLimits.contentLength(from: "Content-Length: -1") == .invalid)
        #expect(RemoteHTTPLimits.contentLength(from: "content-length: 999999999") == .invalid)
        #expect(RemoteHTTPLimits.contentLength(from: "Content-Length: abc") == .invalid)
    }

    @Test func aLargeBodyInTheFirstPacketIsNotAnOversizedHeader() {
        var packet = Data("POST /api/send HTTP/1.1\r\nContent-Length: 40000\r\n\r\n".utf8)
        packet.append(Data(repeating: 0x61, count: 40_000))
        #expect(!RemoteHTTPLimits.headersTooLarge(packet))
        #expect(RemoteHTTPLimits.contentLength(from: "Content-Length: 40000") == .valid(40_000))
        var headers = Data(repeating: 0x41, count: RemoteHTTPLimits.maxHeaderBytes + 1)
        headers.append(Data("\r\n\r\n".utf8))
        #expect(RemoteHTTPLimits.headersTooLarge(headers))
        #expect(RemoteHTTPLimits.headersTooLarge(Data(repeating: 0x41, count: RemoteHTTPLimits.maxHeaderBytes + 1)))
    }
}

struct WorkspaceFileCreationTests {
    @Test func validatedRelativePathRejectsTraversal() {
        #expect(AppModel.validatedRelativePath("foo.swift") == "foo.swift")
        #expect(AppModel.validatedRelativePath("src/foo.swift") == "src/foo.swift")
        #expect(AppModel.validatedRelativePath("  notes.md  ") == "notes.md")
        #expect(AppModel.validatedRelativePath("../secret") == nil)
        #expect(AppModel.validatedRelativePath("/etc/passwd") == nil)
        #expect(AppModel.validatedRelativePath("foo/../bar") == nil)
        #expect(AppModel.validatedRelativePath("") == nil)
        #expect(AppModel.validatedRelativePath(".") == nil)
        #expect(AppModel.validatedRelativePath("foo\\bar") == nil)
    }

    @Test func writeEmptyFileCreatesNestedPathAndRefusesOverwrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-new-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try AppModel.writeEmptyFile("src/hello.swift", root: root.path)
        let created = root.appendingPathComponent("src/hello.swift")
        #expect(FileManager.default.fileExists(atPath: created.path))
        #expect(throws: AppModel.FileCreationError.alreadyExists) {
            try AppModel.writeEmptyFile("src/hello.swift", root: root.path)
        }
        #expect(throws: AppModel.FileCreationError.invalidName) {
            try AppModel.writeEmptyFile("../outside.swift", root: root.path)
        }
    }
}
