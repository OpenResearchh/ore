import AppKit
import Foundation
import Testing

@testable import OreMac

/// Previewing a binary file a reviewer cannot read as text.
///
/// The bugs these cover are all about *how much* work the preview does: a
/// pane that decodes a 20000-pixel PNG at full size on the main thread is a
/// beachball, and a preview keyed on the file's path alone keeps showing an
/// image the agent has already replaced.
@MainActor
struct BinaryFilePreviewTests {
    // MARK: - Decoding

    @Test func aLargeImageIsDecodedToAThumbnailNotAtFullSize() throws {
        let root = try scratchDirectory()
        try write(png: CGSize(width: 4_000, height: 3_000), to: root, named: "shot.png")

        let loaded = BinaryFilePreview.read(
            root: root.path, relativePath: "shot.png", kind: BinaryFileKind(path: "shot.png")
        )

        let image = try #require(loaded.image)
        let longest = max(image.size.width, image.size.height)
        #expect(longest <= CGFloat(BinaryFilePreview.thumbnailLimit))
        #expect(longest > 0)
    }

    /// The chip reports what is in the file, not what AppKit chose to decode.
    @Test func theReportedDimensionsAreTheFilesOwnPixels() throws {
        let root = try scratchDirectory()
        try write(png: CGSize(width: 4_000, height: 3_000), to: root, named: "shot.png")

        let loaded = BinaryFilePreview.read(
            root: root.path, relativePath: "shot.png", kind: BinaryFileKind(path: "shot.png")
        )

        #expect(loaded.pixelSize == CGSize(width: 4_000, height: 3_000))
        #expect((loaded.byteCount ?? 0) > 0)
    }

    @Test func aFileThatIsNotAnImageStillReportsItsSize() throws {
        let root = try scratchDirectory()
        let data = Data(repeating: 0x7F, count: 2_048)
        try data.write(to: root.appendingPathComponent("archive.zip"))

        let loaded = BinaryFilePreview.read(
            root: root.path, relativePath: "archive.zip", kind: BinaryFileKind(path: "archive.zip")
        )

        #expect(loaded.image == nil)
        #expect(loaded.byteCount == 2_048)
    }

    @Test func anUnreadableImageIsNotAnImage() throws {
        let root = try scratchDirectory()
        // The extension says PNG; the bytes do not. This is what a truncated
        // or LFS-pointer file looks like in a worktree.
        try Data("not an image".utf8).write(to: root.appendingPathComponent("icon.png"))

        let loaded = BinaryFilePreview.read(
            root: root.path, relativePath: "icon.png", kind: BinaryFileKind(path: "icon.png")
        )

        #expect(loaded.image == nil)
        #expect(loaded.pixelSize == nil)
        #expect(loaded.byteCount == 12)
    }

    /// A diff is data from the agent, so its paths are not to be trusted.
    @Test func aPathThatEscapesTheWorktreeReadsNothing() throws {
        let root = try scratchDirectory()

        let loaded = BinaryFilePreview.read(
            root: root.path,
            relativePath: "../../../../etc/passwd",
            kind: BinaryFileKind(path: "passwd")
        )

        #expect(loaded.image == nil)
        #expect(loaded.byteCount == nil)
    }

    // MARK: - Kinds

    @Test func vectorsKeepTheDirectPathBecauseTheyHaveNoPixelsToShrink() {
        #expect(BinaryFileKind(path: "logo.svg").isVector)
        #expect(BinaryFileKind(path: "paper.pdf").isVector)
        #expect(!BinaryFileKind(path: "shot.png").isVector)
        #expect(BinaryFileKind(path: "logo.svg").isPreviewable)
        #expect(BinaryFileKind(path: "paper.pdf").isPreviewable)
    }

    @Test func aFileWeCannotDrawSaysWhatItIs() {
        #expect(BinaryFileKind(path: "clip.mov").label == "Video")
        #expect(!BinaryFileKind(path: "clip.mov").isPreviewable)
        #expect(BinaryFileKind(path: "Inter.woff2").label == "Font")
        #expect(BinaryFileKind(path: "blob.xyz").label == "Binary file")
    }

    // MARK: - Revalidation

    /// The git generation moves for a write *anywhere* in the worktree. Keying
    /// a preview on it reloaded — and blanked — this file whenever an agent
    /// touched an unrelated one. The stamp answers the narrower question.
    @Test func theStampOnlyMovesWhenThisFileMoves() throws {
        let root = try scratchDirectory()
        try write(png: CGSize(width: 8, height: 8), to: root, named: "icon.png")

        let first = try #require(WorktreeFileStamp.read(root: root.path, relativePath: "icon.png"))
        // A write somewhere else in the worktree.
        try Data("unrelated".utf8).write(to: root.appendingPathComponent("notes.txt"))
        #expect(WorktreeFileStamp.read(root: root.path, relativePath: "icon.png") == first)

        try Data(repeating: 0, count: 4_096).write(to: root.appendingPathComponent("icon.png"))
        #expect(WorktreeFileStamp.read(root: root.path, relativePath: "icon.png") != first)
    }

    @Test func aFileThatIsNotThereHasNoStamp() throws {
        let root = try scratchDirectory()
        #expect(WorktreeFileStamp.read(root: root.path, relativePath: "gone.png") == nil)
        // A diff's paths come from the agent, so they are not to be trusted.
        #expect(WorktreeFileStamp.read(root: root.path, relativePath: "../../etc/passwd") == nil)
    }

    // MARK: - Helpers

    private func scratchDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ore-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(png size: CGSize, to directory: URL, named name: String) throws {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        NSColor.systemOrange.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(representation.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name))
    }
}
