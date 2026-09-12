import AppKit
import Testing

@testable import OreMac

@Suite("Non-text files are classified for preview")
struct BinaryFileKindTests {
    @Test("Image formats are previewable and named")
    func imagesArePreviewable() {
        for path in ["icon.png", "shot.JPG", "anim.gif", "photo.heic", "art.webp"] {
            #expect(BinaryFileKind(path: path).isPreviewable, "\(path) should preview")
        }
        #expect(BinaryFileKind(path: "a/b/icon.png").label == "PNG image")
        #expect(BinaryFileKind(path: "logo.svg").label == "SVG image")
    }

    /// Extensions arrive from git in whatever case the file has on disk.
    @Test("Extension matching is case-insensitive")
    func caseInsensitive() {
        #expect(BinaryFileKind(path: "Icon.PNG").label == "PNG image")
        #expect(BinaryFileKind(path: "Logo.SVG").isPreviewable)
    }

    /// Claiming a preview and then failing to draw one is worse than saying
    /// up front that it cannot be shown, so these must stay non-previewable.
    @Test("Formats AppKit cannot draw are honest about it")
    func unpreviewableFormats() {
        for path in ["clip.mp4", "song.mp3", "bundle.zip", "Inter.woff2", "app.sqlite"] {
            #expect(!BinaryFileKind(path: path).isPreviewable, "\(path) must not claim a preview")
        }
        #expect(BinaryFileKind(path: "clip.mp4").label == "Video")
        #expect(BinaryFileKind(path: "Inter.woff2").label == "Font")
    }

    @Test("Unknown extensions fall back rather than guessing")
    func unknownFallsBack() {
        let kind = BinaryFileKind(path: "data.xyzzy")
        #expect(!kind.isPreviewable)
        #expect(kind.label == "Binary file")
        #expect(!BinaryFileKind(path: "Makefile").isPreviewable)
    }

    /// The preview treats SVG as a first-class image, which only holds
    /// because AppKit gained native SVG rendering in macOS 13. If that
    /// assumption were wrong, every SVG would silently show "could not read
    /// this file" — so it is worth asserting against a real file rather than
    /// trusting the release notes.
    @Test("AppKit really can rasterise an SVG")
    func appKitRendersSVG() throws {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32">
              <rect width="32" height="32" fill="#B45309"/>
            </svg>
            """
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ore-test-\(UUID().uuidString).svg")
        try svg.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let image = try #require(NSImage(contentsOf: url), "AppKit could not load an SVG")
        #expect(image.size.width == 32)
        #expect(image.size.height == 32)
    }
}
