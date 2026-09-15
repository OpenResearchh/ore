import AppKit
import Foundation
import Testing

@testable import OreMac

/// Which files open as a preview, and which have source at all.
///
/// The bug behind these: a deleted `icon.png` opened in the Source segment
/// and showed "ORE can only edit UTF-8 text files", because every file was
/// assumed to have text and only markdown was assumed to have a preview.
struct FilePreviewModeTests {
    @Test func documentsPagesAndImagesHaveAPreview() {
        #expect(FilePresentationMode.previewKind(path: "docs/PLAN.md") == .markdown)
        #expect(FilePresentationMode.previewKind(path: "site/index.html") == .html)
        #expect(FilePresentationMode.previewKind(path: "site/INDEX.HTM") == .html)
        #expect(FilePresentationMode.previewKind(path: "web/ore/icon.png") == .image)
        #expect(FilePresentationMode.previewKind(path: "Resources/AppIcon.icns") == .image)
        #expect(FilePresentationMode.previewKind(path: "logo.svg") == .image)
        #expect(FilePresentationMode.previewKind(path: "main.swift") == nil)
    }

    @Test func previewableFilesOpenAsPreviews() {
        #expect(FilePresentationMode.preferred(forPath: "icon.png") == .preview)
        #expect(FilePresentationMode.preferred(forPath: "index.html") == .preview)
        #expect(FilePresentationMode.preferred(forPath: "main.swift") == .source)
    }

    @Test func onlyFilesWithTextHaveSource() {
        #expect(!FilePresentationMode.hasSource(path: "icon.png"))
        #expect(!FilePresentationMode.hasSource(path: "AppIcon.icns"))
        #expect(!FilePresentationMode.hasSource(path: "archive.zip"))
        // SVG is XML, and an unrecognised name is more likely text than not.
        #expect(FilePresentationMode.hasSource(path: "logo.svg"))
        #expect(FilePresentationMode.hasSource(path: "index.html"))
        #expect(FilePresentationMode.hasSource(path: "Makefile"))
    }

    @Test func imageBytesFromGitDecodeLikeAFileOnDisk() throws {
        let data = try pngData(width: 64, height: 32)
        let loaded = BinaryFilePreview.decode(data: data, kind: BinaryFileKind(path: "icon.png"))

        #expect(loaded.image != nil)
        #expect(loaded.pixelSize == CGSize(width: 64, height: 32))
        #expect(loaded.byteCount == Int64(data.count))
    }

    @Test func unreadableBytesDecodeToNoImage() {
        let loaded = BinaryFilePreview.decode(
            data: Data([0x00, 0x01, 0x02]), kind: BinaryFileKind(path: "icon.png")
        )
        #expect(loaded.image == nil)
        #expect(loaded.byteCount == 3)
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}
