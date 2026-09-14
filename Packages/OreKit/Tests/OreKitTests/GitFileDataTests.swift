import Foundation
import Testing

@testable import OreGit

/// Reading a file out of git as bytes.
///
/// The review pane uses this to show a deleted or replaced image. `run`
/// decodes output as UTF-8, so the property that matters is that a blob full
/// of NULs and invalid UTF-8 comes back byte-for-byte.
struct GitFileDataTests {
    @Test func aBinaryBlobComesBackByteForByte() async throws {
        let fixture = try await GitFixture.initialized()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0xFE, 0x0A, 0x00, 0xC3])
        let url = fixture.repository.appendingPathComponent("icon.png")
        try bytes.write(to: url)
        try await fixture.run(["add", "-A"])
        try await fixture.commit("add icon")
        try FileManager.default.removeItem(at: url)

        let data = await fixture.git.fileData(atRevision: "HEAD", path: "icon.png")
        #expect(data == bytes)
    }

    @Test func aPathMissingAtTheRevisionIsNil() async throws {
        let fixture = try await GitFixture.initialized()
        #expect(await fixture.git.fileData(atRevision: "HEAD", path: "missing.png") == nil)
    }

    @Test func aBlobOverTheLimitIsNotRead() async throws {
        let fixture = try await GitFixture.initialized()
        let data = await fixture.git.fileData(
            atRevision: "HEAD", path: "README.md", maximumBytes: 3
        )
        #expect(data == nil)
    }
}
