import AppKit
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
