import AppKit
import OreProtocol
import Testing

@testable import OreMac

struct EffortScrollAccumulatorTests {
    @Test func trackpadNeedsMeaningfulTravelBeforeChangingEffort() {
        var gesture = EffortScrollAccumulator()
        #expect(gesture.consume(delta: 10, precise: true).step == nil)
        #expect(gesture.consume(delta: 10, precise: true).step == nil)
        #expect(gesture.consume(delta: 13, precise: true).step == nil)
        #expect(gesture.consume(delta: 1, precise: true).step == 1)
    }

    @Test func mouseWheelNeedsThreeDetents() {
        var gesture = EffortScrollAccumulator()
        #expect(gesture.consume(delta: -4, precise: false).step == nil)
        #expect(gesture.consume(delta: -4, precise: false).step == nil)
        #expect(gesture.consume(delta: -4, precise: false).step == -1)
    }

    @Test func changingDirectionRestartsTheGesture() {
        var gesture = EffortScrollAccumulator()
        #expect(gesture.consume(delta: 24, precise: true).step == nil)
        let reversed = gesture.consume(delta: -20, precise: true)
        #expect(reversed.step == nil)
        #expect(reversed.progress < 0)
        #expect(abs(reversed.progress) < 0.6)
    }
}

/// Rendering is where the app's correctness is visible rather than provable:
/// a wrong highlight range or a lost list marker doesn't crash, it just makes
/// the transcript slightly wrong in a way a reader absorbs without noticing.
@MainActor
struct MarkdownRendererTests {
    private func render(_ markdown: String) -> NSAttributedString {
        MarkdownRenderer(highlighter: SyntaxHighlighter.shared).render(markdown)
    }

    @Test func headingsAreLargerAndBolderThanBodyText() {
        let result = render("# Title\n\nBody text.")
        let base = NSFont.systemFont(ofSize: 13)

        let headingFont = result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(headingFont != nil)
        #expect((headingFont?.pointSize ?? 0) > base.pointSize)

        // The heading's own text survives; only its formatting changed.
        #expect(result.string.contains("Title"))
        #expect(result.string.contains("Body text."))
    }

    @Test func listsRenderWithMarkersAndKeepTheirItemsOnSeparateLines() {
        let result = render("- first\n- second\n")
        let lines = result.string.split(separator: "\n").map(String.init)

        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.hasPrefix("•") })
        #expect(lines[0].contains("first"))
        #expect(lines[1].contains("second"))
    }

    @Test func taskListsShowTheirCheckedState() {
        // An agent's checklist is how it reports progress; the boxes carry the
        // meaning, not the text.
        let result = render("- [x] done\n- [ ] pending\n")
        #expect(result.string.contains("☑ done"))
        #expect(result.string.contains("☐ pending"))
    }

    @Test func nestedListsIndent() {
        let result = render("- outer\n    - inner\n")
        let lines = result.string.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(!lines[0].hasPrefix(" "))
        #expect(lines[1].hasPrefix("    "))
    }

    @Test func inlineCodeIsMonospacedButNotABlock() {
        let result = render("Call `render()` now.")
        guard let range = result.string.range(of: "render()") else {
            Issue.record("inline code text was lost")
            return
        }
        let location = result.string.distance(from: result.string.startIndex, to: range.lowerBound)
        let font = result.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true)

        // The surrounding prose stays proportional.
        let proseFont = result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(proseFont?.isFixedPitch == false)
    }

    @Test func fencedCodeBlocksAreMonospacedAndHighlighted() {
        let result = render("""
        Here:

        ```swift
        struct Square { let side: Double }
        ```
        """)

        guard let range = result.string.range(of: "struct") else {
            Issue.record("code block text was lost")
            return
        }
        let location = result.string.distance(from: result.string.startIndex, to: range.lowerBound)
        let font = result.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true)

        // Highlighted: the keyword is not the body colour.
        let color = result.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
        #expect(color != nil)
        #expect(color != NSColor.labelColor)
    }

    @Test func multilineCodeUsesOneTextBlockInsteadOfLineBackgrounds() {
        let result = render("""
        ```swift
        let first = 1
        let second = 2
        ```
        """)
        guard let firstRange = result.string.range(of: "let first"),
              let secondRange = result.string.range(of: "let second") else {
            Issue.record("code lines were lost")
            return
        }
        let first = result.string.distance(from: result.string.startIndex, to: firstRange.lowerBound)
        let second = result.string.distance(from: result.string.startIndex, to: secondRange.lowerBound)
        let firstStyle = result.attribute(.paragraphStyle, at: first, effectiveRange: nil) as? NSParagraphStyle
        let secondStyle = result.attribute(.paragraphStyle, at: second, effectiveRange: nil) as? NSParagraphStyle
        #expect(firstStyle?.textBlocks.count == 1)
        #expect(secondStyle?.textBlocks.count == 1)
        #expect(result.attribute(.backgroundColor, at: first, effectiveRange: nil) == nil)
    }

    @Test func linksCarryTheirDestination() {
        let result = render("See [the docs](https://example.com/docs).")
        guard let range = result.string.range(of: "the docs") else {
            Issue.record("link text was lost")
            return
        }
        let location = result.string.distance(from: result.string.startIndex, to: range.lowerBound)
        let url = result.attribute(.link, at: location, effectiveRange: nil) as? URL
        #expect(url?.absoluteString == "https://example.com/docs")
    }

    private func firstWebLink(in result: NSAttributedString) -> URL? {
        var found: URL?
        result.enumerateAttribute(
            .link, in: NSRange(location: 0, length: result.length)
        ) { value, _, stop in
            if let url = value as? URL, url.scheme == "http" || url.scheme == "https" {
                found = url
                stop.pointee = true
            }
        }
        return found
    }

    @Test func bareURLsBecomeClickableChips() {
        // A bare link the agent drops in prose should be clickable, not raw text.
        let result = render("Opened https://github.com/OpenResearchh/ore/pull/1 for review.")
        #expect(firstWebLink(in: result)?.absoluteString
            == "https://github.com/OpenResearchh/ore/pull/1")
        // The long path is shortened into a chip label rather than shown whole.
        #expect(!result.string.contains("OpenResearchh/ore/pull/1"))
        #expect(result.string.contains("github.com"))
    }

    @Test func urlsAreNotFracturedByTheFileReferencePass() {
        // The bug this guards: `.c` in `github.com` matched the C-file extension
        // and turned a slice of the URL into an `ore-file` chip.
        let result = render("See https://github.com/a/b for details.")
        #expect(firstWebLink(in: result)?.scheme == "https")
        // No slice of the URL was mis-tagged as an internal file reference.
        var sawFileLink = false
        result.enumerateAttribute(
            .link, in: NSRange(location: 0, length: result.length)
        ) { value, _, _ in
            if (value as? URL)?.scheme == "ore-file" { sawFileLink = true }
        }
        #expect(!sawFileLink)
    }

    @Test func descriptiveMarkdownLinksKeepTheirWords() {
        // `linksCarryTheirDestination` covers the URL; this covers that a chip
        // doesn't replace human text with a bare host.
        let result = render("Read [the changelog](https://example.com/log).")
        #expect(result.string.contains("the changelog"))
        #expect(firstWebLink(in: result)?.absoluteString == "https://example.com/log")
    }

    @Test func bareWorkspaceFileReferencesBecomeInternalLinks() {
        let result = render("Open server/index.ts:42 and continue.")
        guard let range = result.string.range(of: "server/index.ts:42") else {
            Issue.record("file reference was lost")
            return
        }
        let location = result.string.distance(from: result.string.startIndex, to: range.lowerBound)
        let url = result.attribute(.link, at: location, effectiveRange: nil) as? URL
        let path = url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value
        }
        #expect(url?.scheme == "ore-file")
        #expect(path == "server/index.ts:42")
    }

    @Test func emphasisAndStrongChangeTheFontRatherThanTheText() {
        let result = render("*italic* and **bold**")
        #expect(result.string.contains("italic"))
        #expect(result.string.contains("bold"))
        // The markers themselves are consumed.
        #expect(!result.string.contains("*"))

        guard let boldRange = result.string.range(of: "bold") else { return }
        let location = result.string.distance(
            from: result.string.startIndex, to: boldRange.lowerBound
        )
        let font = result.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
        #expect(traits.contains(.boldFontMask))
    }

    @Test func plainTextPassesThroughUnchanged() {
        // Most agent replies are prose; markdown must not mangle them.
        let text = "I looked at the parser and it handles the case already."
        #expect(render(text).string == text)
    }

    @Test func trailingBlankLinesAreTrimmed() {
        // Block elements each append spacing; left in, the bubble grows a gap
        // under the last line.
        let result = render("One paragraph.\n\n")
        #expect(!result.string.hasSuffix("\n"))
    }

    @Test func malformedMarkdownStillRenders() {
        // Agents produce unterminated fences and stray brackets constantly,
        // especially mid-stream.
        for input in ["```swift\nlet x = 1", "**unclosed", "[link](", "# "] {
            #expect(!render(input).string.isEmpty || input == "# ")
        }
    }

    @Test func tablesKeepCellsSeparatedAndHeadersDistinct() {
        let result = render("""
        | File | Added | Removed |
        | --- | ---: | ---: |
        | App.swift | 12 | 3 |
        """)
        #expect(!result.string.contains("│"))
        #expect(result.string.contains("File"))
        #expect(result.string.contains("App.swift"))
        #expect(!result.string.contains("FileAddedRemoved"))

        guard let range = result.string.range(of: "File") else { return }
        let location = result.string.distance(from: result.string.startIndex, to: range.lowerBound)
        let font = result.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == false)
        #expect(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
    }
}

@MainActor
struct SyntaxHighlighterTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private func colors(
        _ code: String,
        language: String?
    ) -> [(text: String, color: NSColor?)] {
        let result = SyntaxHighlighter.shared.highlight(code, language: language, font: font)
        var runs: [(String, NSColor?)] = []
        result.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: result.length)
        ) { value, range, _ in
            runs.append((result.attributedSubstring(from: range).string, value as? NSColor))
        }
        return runs
    }

    private func color(of token: String, in code: String, language: String?) -> NSColor? {
        let result = SyntaxHighlighter.shared.highlight(code, language: language, font: font)
        guard let range = code.range(of: token) else { return nil }
        let location = code.distance(from: code.startIndex, to: range.lowerBound)
        return result.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    @Test func highlightRangesLineUpWithTheirTokens() {
        // tree-sitter is fed UTF-16, so its "byte" offsets are two per code
        // unit. Reading them as UTF-8 makes every highlight twice as long as
        // the token — which reads as a rendering glitch, not a units bug.
        let code = "struct Square { let side: Double }"
        let result = SyntaxHighlighter.shared.highlight(code, language: "swift", font: font)

        var keywordRange = NSRange(location: 0, length: 0)
        _ = result.attribute(.foregroundColor, at: 0, effectiveRange: &keywordRange)

        // `struct` is six characters; the run that starts at 0 must not spill
        // into the identifier after it.
        #expect(keywordRange.length <= 7)
        #expect(result.string == code)
    }

    @Test func swiftKeywordsAndTypesGetDistinctColors() {
        let code = "struct Square { let side: Double }"
        let keyword = color(of: "struct", in: code, language: "swift")
        let type = color(of: "Double", in: code, language: "swift")

        #expect(keyword != nil)
        #expect(type != nil)
        #expect(keyword != type)
    }

    @Test func swiftUsesTheParserRatherThanTheRegexFallback() {
        // A user-defined type name is the cheap way to tell the two apart: the
        // regex pass only knows a fixed keyword list, so `Square` would come
        // back unstyled. Colouring it means a grammar actually parsed this.
        let code = "struct Square { let side: Double }"
        let typeName = color(of: "Square", in: code, language: "swift")

        #expect(typeName != nil)
        #expect(typeName != NSColor.labelColor, "the tree-sitter grammar did not load")
    }

    @Test func stringsAndCommentsAreColouredInJSON() {
        let code = #"{"name": "ore", "count": 3}"#
        let result = SyntaxHighlighter.shared.highlight(code, language: "json", font: font)
        let distinct = Set(colors(code, language: "json").compactMap { $0.color })
        #expect(distinct.count > 1)
        #expect(result.string == code)
    }

    @Test func anUnknownLanguageStillGetsTheRegexPass() {
        // Unhighlighted code in an app for reading code is worse than
        // approximate highlighting.
        let code = "def greet(name):\n    return \"hi\"  # a comment"
        let result = SyntaxHighlighter.shared.highlight(code, language: "python", font: font)
        #expect(result.string == code)

        let distinct = Set(colors(code, language: "python").compactMap { $0.color })
        #expect(distinct.count > 1, "expected the fallback highlighter to colour something")
    }

    @Test func aKeywordInsideAStringIsNotColouredAsAKeyword() {
        // The thing regex highlighters classically get wrong.
        let code = "let message = \"return this\""
        let keyword = color(of: "let", in: code, language: "unknownlang")
        let inString = color(of: "return this", in: code, language: "unknownlang")
        #expect(keyword != inString)
    }

    @Test func languageNamesAreNormalised() {
        #expect(SyntaxHighlighter.canonicalName("Swift") == "swift")
        #expect(SyntaxHighlighter.canonicalName("py") == "python")
        #expect(SyntaxHighlighter.canonicalName("swift title=a.swift") == "swift")
        #expect(SyntaxHighlighter.canonicalName(nil) == nil)
        #expect(SyntaxHighlighter.language(forPath: "Sources/App.swift") == "swift")
        #expect(SyntaxHighlighter.language(forPath: "data.json") == "json")
    }

    @Test func emptyAndHugeInputAreHandled() {
        #expect(SyntaxHighlighter.shared.highlight("", language: "swift", font: font).length == 0)

        let big = String(repeating: "let x = 1\n", count: 2000)
        let result = SyntaxHighlighter.shared.highlight(big, language: "swift", font: font)
        #expect(result.string == big)
    }

    @Test func textWithEmojiKeepsItsRangesAligned() {
        // Multi-code-unit characters are exactly what a units bug corrupts.
        let code = "let flag = \"🎉 done\"\nstruct A {}"
        let result = SyntaxHighlighter.shared.highlight(code, language: "swift", font: font)
        #expect(result.string == code)
        #expect(color(of: "struct", in: code, language: "swift") != nil)
    }
}

@MainActor
struct SourceFileIconTests {
    @Test func programmingLanguagesHaveDistinctRecognizableIdentities() {
        let swift = FileVisualIdentity(path: "Sources/App.swift")
        let typeScript = FileVisualIdentity(path: "client/viewer.tsx")
        let javaScript = FileVisualIdentity(path: "client/index.js")
        let python = FileVisualIdentity(path: "tools/build.py")

        #expect(swift.symbol == "swift")
        #expect(typeScript.glyph == "TS")
        #expect(javaScript.glyph == "JS")
        #expect(python.glyph == "Py")
        #expect(Set([swift.label, typeScript.label, javaScript.label, python.label]).count == 4)
    }

    @Test func configurationAndFoldersDoNotFallBackToGenericDocuments() {
        #expect(FileVisualIdentity(path: "Dockerfile").label == "Docker")
        #expect(FileVisualIdentity(path: ".env.local").label == "Environment file")
        #expect(FileVisualIdentity(path: "src", isDirectory: true).symbol == "folder.fill")
    }
}

@MainActor
struct UserMessageAttachmentTests {
    @Test func sentUserBubblesKeepAttachmentChipsInsteadOfPlainTokens() {
        let row = TranscriptRow(
            id: "u1",
            turnID: TurnID(rawValue: "t1"),
            kind: .userMessage,
            text: "Look at this",
            attachments: [
                Attachment(
                    relativePath: ".context/attachments/abcd-pasted-image.png",
                    displayName: "pasted-image.png",
                    mimeType: "image/png"
                ),
                Attachment(relativePath: "Sources/App.swift", displayName: "App.swift"),
            ]
        )
        let rendered = TranscriptCell.attributedText(for: row)
        // The typed prose stays; attachments render as chips, not a dumped
        // `@pasted-image.png` suffix.
        #expect(rendered.string.contains("Look at this"))
        #expect(!rendered.string.contains("@pasted-image.png"))
        var attachmentCount = 0
        rendered.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            if value != nil { attachmentCount += 1 }
        }
        #expect(attachmentCount >= 2)
    }

    @Test func appendingAUserMessageStoresAttachmentsOnTheRow() {
        let state = ChatState()
        state.appendUserMessage(
            "see this",
            attachments: [
                Attachment(
                    relativePath: ".context/attachments/shot.png",
                    displayName: "pasted-image.png",
                    mimeType: "image/png"
                )
            ],
            comments: []
        )
        #expect(state.rows.count == 1)
        #expect(state.rows[0].text == "see this")
        #expect(state.rows[0].attachments.map(\.displayName) == ["pasted-image.png"])
    }
}

/// The transcript rasterises file chips and resolves semantic colours into
/// bitmaps, then caches the result. Both halves have to notice a light/dark
/// switch, or a row keeps drawing its dark-mode pills on a light background —
/// white on white, which reads as the chips having disappeared.
@MainActor
struct TranscriptAppearanceTests {
    private func editRow() -> TranscriptRow {
        TranscriptRow(
            id: "tool-appearance",
            turnID: TurnID(rawValue: "t1"),
            kind: .toolCall,
            text: "Edit",
            toolName: "Edit",
            toolCallID: ToolCallID(rawValue: "c1"),
            toolInput: .object([
                "file_path": .string("Sources/App.swift"),
                "old_string": .string("a"),
                "new_string": .string("b"),
            ]),
            isComplete: true
        )
    }

    @Test func switchingAppearanceRerendersRatherThanServingTheCachedBitmap() {
        let application = NSApplication.shared
        let original = application.appearance
        defer { application.appearance = original }

        application.appearance = NSAppearance(named: .darkAqua)
        let dark = TranscriptCell.attributedText(for: editRow())
        let darkPixels = chipPixels(in: dark)

        application.appearance = NSAppearance(named: .aqua)
        let light = TranscriptCell.attributedText(for: editRow())
        let lightPixels = chipPixels(in: light)

        // Same row, same text — but the chip must have been drawn again for the
        // new appearance instead of being served from the cache.
        #expect(dark.string == light.string)
        #expect(darkPixels != nil)
        #expect(lightPixels != nil)
        #expect(darkPixels != lightPixels)
    }

    /// The PNG bytes of the row's first inline image — the file chip.
    private func chipPixels(in text: NSAttributedString) -> Data? {
        var found: NSImage?
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if let image = (value as? NSTextAttachment)?.image, image.size.width > 20 {
                found = image
                stop.pointee = true
            }
        }
        guard let found, let tiff = found.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}

/// The agent's checklist tools name their task by id, so a row that only shows
/// the tool name is the one thing that cannot say which task it touched.
@MainActor
struct ChecklistRowTests {
    private func row(tool: String, input: JSONValue, subject: String?) -> TranscriptRow {
        var row = TranscriptRow(
            id: "task-1",
            turnID: TurnID(rawValue: "t1"),
            kind: .toolCall,
            text: tool,
            toolName: tool,
            toolCallID: ToolCallID(rawValue: "c1"),
            toolInput: input,
            isComplete: true
        )
        row.resolvedSubject = subject
        return row
    }

    @Test func completingATaskNamesTheTaskRatherThanTheTool() {
        let rendered = TranscriptCell.attributedText(for: row(
            tool: "TaskUpdate",
            input: .object(["taskId": .string("8"), "status": .string("completed")]),
            subject: "Fix stuck plan-approval card"
        ))
        #expect(rendered.string.contains("Task completed"))
        #expect(!rendered.string.contains("TaskUpdate"))
    }

    @Test func theStatusPicksTheWording() {
        let started = TranscriptCell.attributedText(for: row(
            tool: "TaskUpdate",
            input: .object(["taskId": .string("8"), "status": .string("in_progress")]),
            subject: "Something"
        ))
        #expect(started.string.contains("Task started"))

        let created = TranscriptCell.attributedText(for: row(
            tool: "TaskCreate",
            input: .object(["subject": .string("Write the thing")]),
            subject: nil
        ))
        #expect(created.string.contains("Task added"))
    }

    @Test func anMCPNamespacedChecklistToolIsStillRecognised() {
        let rendered = TranscriptCell.attributedText(for: row(
            tool: "mcp__ore__TaskUpdate",
            input: .object(["taskId": .string("3"), "status": .string("completed")]),
            subject: "Namespaced"
        ))
        #expect(rendered.string.contains("Task completed"))
    }
}

struct UsageLimitResetTests {
    @Test func parsesProviderResetCopyIntoTheNextWallClock() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 10, hour: 10, minute: 0))!
        let parsed = UsageLimitReset.parse(
            "You've hit your session limit · resets 5:30am (UTC)",
            now: now
        )
        #expect(parsed != nil)
        let hour = calendar.component(.hour, from: parsed!)
        let minute = calendar.component(.minute, from: parsed!)
        #expect(hour == 5)
        #expect(minute == 30)
        #expect(parsed! > now)
    }

    @Test func formatsResetTimesWithTheZone() {
        let date = Date(timeIntervalSince1970: 0)
        let zone = TimeZone(identifier: "UTC")!
        let formatted = UsageLimitReset.format(date, timeZone: zone)
        #expect(formatted.contains(zone.identifier) || formatted.contains("GMT") || formatted.contains("UTC"))
    }
}

// `GitHubUpdater` is main-actor isolated, and this suite lost its annotation in
// the merge — the `@MainActor` it relied on sat above the conflicted region and
// ended up attached to the suite that came first.
@MainActor
struct GitHubUpdaterVersionTests {
    @Test func newerVersionsAreDetectedAcrossComponentsAndPrefixes() {
        #expect(GitHubUpdater.isNewer("0.2.0", than: "0.1.0"))
        #expect(GitHubUpdater.isNewer("v0.1.1", than: "0.1.0"))
        #expect(GitHubUpdater.isNewer("1.0.0", than: "0.9.9"))
        // A leading `v` and missing components must not fake a difference.
        #expect(!GitHubUpdater.isNewer("v0.1.0", than: "0.1.0"))
        #expect(!GitHubUpdater.isNewer("0.1", than: "0.1.0"))
        #expect(!GitHubUpdater.isNewer("0.1.0", than: "0.2.0"))
        // A malformed tag sorts as zeros rather than pretending to be newer.
        #expect(!GitHubUpdater.isNewer("garbage", than: "0.1.0"))
    }

    @Test func displayVersionAddsALeadingVOnce() {
        #expect(GitHubUpdater.displayVersion("0.2.0") == "v0.2.0")
        #expect(GitHubUpdater.displayVersion("v0.2.0") == "v0.2.0")
        #expect(GitHubUpdater.displayVersion("V1.0") == "V1.0")
    }

    @Test func prefersDmgOverZip() {
        let assets: [[String: Any]] = [
            [
                "name": "ORE-0.2.0.zip",
                "browser_download_url": "https://example.com/ORE-0.2.0.zip",
                "id": 1,
            ],
            [
                "name": "ORE-0.2.0.dmg",
                "browser_download_url": "https://example.com/ORE-0.2.0.dmg",
                "id": 2,
            ],
        ]
        let chosen = GitHubUpdater.preferredAsset(from: assets)
        #expect(chosen?.name == "ORE-0.2.0.dmg")
        #expect(chosen?.id == 2)
    }

    @Test func prefersOREAppInADiskImageLayout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-upd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("ORE.app"), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Applications"),
            withDestinationURL: URL(fileURLWithPath: "/Applications")
        )
        #expect(GitHubUpdater.appBundle(in: root)?.lastPathComponent == "ORE.app")
        try FileManager.default.removeItem(at: root)
    }

    @Test func findsNestedAppInAZipLayout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-upd-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("ORE").appendingPathComponent("ORE.app")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(GitHubUpdater.appBundle(in: root)?.lastPathComponent == "ORE.app")
        try FileManager.default.removeItem(at: root)
    }

    @Test func installDestinationMovesOffADiskImage() {
        let fromVolume = URL(fileURLWithPath: "/Volumes/ORE/ORE.app")
        #expect(GitHubUpdater.installDestination(currentBundle: fromVolume).path == "/Applications/ORE.app")
        let fromApps = URL(fileURLWithPath: "/Applications/ORE.app")
        #expect(GitHubUpdater.installDestination(currentBundle: fromApps).path == "/Applications/ORE.app")
        let fromDownloads = URL(fileURLWithPath: "/Users/me/Downloads/ORE.app")
        #expect(
            GitHubUpdater.installDestination(currentBundle: fromDownloads).path
                == "/Users/me/Downloads/ORE.app"
        )
    }

    @Test func shellQuoteEscapesEmbeddedQuotes() {
        #expect(GitHubUpdater.shellQuote("/tmp/ORE.app") == "'/tmp/ORE.app'")
        #expect(GitHubUpdater.shellQuote("/tmp/O'Reilly.app") == "'/tmp/O'\\''Reilly.app'")
    }

    @Test func mountPointReadsHdiutilPlist() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>system-entities</key>
            <array>
                <dict>
                    <key>dev-entry</key>
                    <string>/dev/disk4</string>
                </dict>
                <dict>
                    <key>mount-point</key>
                    <string>/Volumes/ORE</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let mount = GitHubUpdater.mountPoint(fromPlist: Data(xml.utf8))
        #expect(mount?.path == "/Volumes/ORE")
    }

    @Test func parsePicksTheDmgAsset() {
        let object: [String: Any] = [
            "tag_name": "v0.2.0",
            "name": "ORE v0.2.0",
            "html_url": "https://github.com/OpenResearchh/ore/releases/tag/v0.2.0",
            "assets": [
                [
                    "name": "ORE-0.2.0.zip",
                    "browser_download_url": "https://example.com/ORE-0.2.0.zip",
                    "id": 11,
                ],
                [
                    "name": "ORE-0.2.0.dmg",
                    "browser_download_url": "https://example.com/ORE-0.2.0.dmg",
                    "id": 12,
                ],
            ],
        ]
        let release = GitHubUpdater.parse(object)
        #expect(release?.version == "v0.2.0")
        #expect(release?.assetName == "ORE-0.2.0.dmg")
        #expect(release?.assetID == 12)
        #expect(release?.downloadURL?.lastPathComponent == "ORE-0.2.0.dmg")
    }
}

struct ToolChangeStatsTests {
    @Test func editUsesOldAndNewStringLineCounts() {
        let old = "func a() {\n    return 1\n}\n"
        let new = "func a() {\n    return 2\n}\nfunc b() {}\n"
        let counts = ToolChangeStats.lineCounts(
            diff: "",
            old: old,
            new: new,
            content: nil,
            changeKind: nil,
            isWrite: false
        )
        #expect(counts.insertions == 4)
        #expect(counts.deletions == 3)
    }

    @Test func writeCountsContentLines() {
        let counts = ToolChangeStats.lineCounts(
            diff: "",
            old: nil,
            new: nil,
            content: "one\ntwo\nthree\n",
            changeKind: nil,
            isWrite: true
        )
        #expect(counts.insertions == 3)
        #expect(counts.deletions == 0)
    }

    @Test func unifiedDiffCountsAddedAndRemovedLines() {
        let diff = """
        --- a/App.swift
        +++ b/App.swift
        @@ -1,3 +1,4 @@
         keep
        -old
        +new
        +extra
        """
        let counts = ToolChangeStats.lineCounts(
            diff: diff,
            old: nil,
            new: nil,
            content: nil,
            changeKind: nil,
            isWrite: false
        )
        #expect(counts.insertions == 2)
        #expect(counts.deletions == 1)
    }

    @Test func addedFileWithoutDiffMarkersCountsSnippetLines() {
        let counts = ToolChangeStats.lineCounts(
            diff: "ore\n",
            old: nil,
            new: nil,
            content: nil,
            changeKind: "add",
            isWrite: false
        )
        #expect(counts.insertions == 1)
        #expect(counts.deletions == 0)
    }
}
