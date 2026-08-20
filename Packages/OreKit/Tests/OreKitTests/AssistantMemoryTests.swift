import Foundation
import Testing

@testable import OreCore

struct AssistantMemoryTests {
    @Test func writesStayInsideMemoryAndRefreshTheIndex() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try "# Memory index\n\n".write(
            to: home.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8
        )
        try AssistantMemory.write(
            home: home,
            path: "memory/preferences.md",
            contents: "# Preferences\n\nLikes short answers.\n",
            append: false
        )
        let listing = AssistantMemory.listingText(home: home)
        #expect(listing.contains("memory/preferences.md"))
        let read = try AssistantMemory.read(home: home, path: "memory/preferences.md")
        #expect(read.contains("short answers"))
        let index = AssistantMemory.readIndex(home: home)
        #expect(index.contains("memory/preferences.md"))
    }

    @Test func rejectsPathsOutsideTheSandbox() {
        let home = URL(fileURLWithPath: "/tmp")
        #expect(throws: AssistantMemoryError.self) {
            try AssistantMemory.read(home: home, path: "../etc/passwd")
        }
        #expect(throws: AssistantMemoryError.self) {
            try AssistantMemory.write(
                home: home, path: "memory/nested/nope.md", contents: "x", append: false
            )
        }
    }
}
