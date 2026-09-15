import AppKit
import Testing

@testable import OreMac

/// A value built on one thread and read on another. The tests below hand fonts,
/// appearances and finished renders across `Task.detached`; all of them are
/// immutable once made, which is the same bargain the app's own render path
/// makes.
private struct Sent<Value>: @unchecked Sendable {
    let value: Value
}

/// A stable, printable description of everything about a render that a reader
/// can see.
///
/// `NSAttributedString.isEqual` is no use here: attachments and text blocks
/// compare by identity, so two renders of the same markdown are never equal
/// even when they draw the same pixels. This walks the attribute runs instead
/// and writes out the parts that decide what appears on screen — font face and
/// size, colours, link, underline and strikethrough, the paragraph geometry,
/// and each attachment's box and image.
enum RenderFingerprint {
    static func of(_ string: NSAttributedString) -> String {
        var lines = [string.string]
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attributes, range, _ in
            var parts = ["[\(range.location),\(range.length)]"]
            for key in attributes.keys.map(\.rawValue).sorted() {
                let value = attributes[NSAttributedString.Key(key)]
                parts.append("\(key)=\(describe(value))")
            }
            lines.append(parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ value: Any?) -> String {
        switch value {
        case let font as NSFont:
            // Face and size are what the text system draws with; the same face
            // can carry two different descriptor spellings.
            return "\(font.fontName)@\(font.pointSize)"
        case let color as NSColor:
            // Dynamic catalog colours are shared instances, so identity is the
            // honest comparison — resolving them would test the appearance,
            // not the render.
            return ObjectIdentifier(color).debugDescription
        case let style as NSParagraphStyle:
            let blocks = style.textBlocks.map { block in
                "block(\(describe(block.backgroundColor))"
                    + ",\(block.width(for: .padding, edge: .minX))"
                    + ",\(block.width(for: .padding, edge: .maxY)))"
            }
            return "para(ls=\(style.lineSpacing),before=\(style.paragraphSpacingBefore)"
                + ",after=\(style.paragraphSpacing),first=\(style.firstLineHeadIndent)"
                + ",head=\(style.headIndent),break=\(style.lineBreakMode.rawValue)"
                + ",blocks=[\(blocks.joined(separator: ","))])"
        case let attachment as NSTextAttachment:
            let image = attachment.image
            return "attach(bounds=\(NSStringFromRect(attachment.bounds))"
                + ",image=\(image.map { NSStringFromSize($0.size) } ?? "nil")"
                + ",instance=\(image.map { ObjectIdentifier($0).debugDescription } ?? "nil"))"
        case let url as URL:
            return url.absoluteString
        case let number as NSNumber:
            return number.stringValue
        case .none:
            return "nil"
        case .some(let other):
            return String(describing: other)
        }
    }
}

/// The document preview renders markdown off the main actor. These tests are
/// the contract that makes that safe: the font conversion has to land on the
/// same faces `NSFontManager` used to hand back, the link-chip symbols have to
/// be the ones the main actor already built, and a whole document rendered on a
/// worker thread has to be indistinguishable from the same document rendered on
/// main.
@MainActor
struct MarkdownRenderOffMainTests {
    /// Exercises every construct the visitor and the link passes can produce:
    /// emphasis (including nested), headings, both list flavours, a checklist,
    /// a table, a fenced block that tree-sitter can parse, inline code, a bare
    /// URL, a descriptive link, a file reference, a quote and a rule.
    static let sample = """
        # Heading one

        Ordinary prose with **bold**, *italic*, ***both at once***, \
        ~~struck~~ and `inline code` in it.

        ## Heading two

        - A bullet with **bold inside**
        - [ ] An unchecked box
        - [x] A checked box
            - A nested bullet in *italics*

        1. First
        2. Second with `code`

        > A quote that runs on a little, with **emphasis**.

        | Column | Other |
        |--------|-------|
        | value  | `code` |

        ```swift
        struct Thing {
            let name: String  // a comment
        }
        ```

        Visit https://github.com/OpenResearchh/ore/pull/1 or read
        [the docs](https://developer.apple.com/documentation) or open
        Sources/OreMac/MarkdownRenderer.swift:42 for the details.

        ---

        Trailing paragraph.
        """

    private func render(baseFont: NSFont, appearance: NSAppearance) -> NSAttributedString {
        var result = NSAttributedString()
        appearance.performAsCurrentDrawingAppearance {
            result = MarkdownRenderer(
                baseFont: baseFont,
                textColor: .labelColor,
                highlighter: SyntaxHighlighter.shared
            ).render(Self.sample, highlighting: .all)
        }
        return result
    }

    @Test func aDetachedRenderIsIdenticalToTheMainActorRender() async {
        let appearance = NSAppearance(named: .darkAqua) ?? NSAppearance()
        let baseFont = NSFont.systemFont(ofSize: OreTheme.Font.prose)
        appearance.performAsCurrentDrawingAppearance {
            MarkdownRenderer.prewarmLinkSymbols(baseFont: baseFont)
        }
        let onMain = render(baseFont: baseFont, appearance: appearance)

        let request = Sent(value: (baseFont, appearance))
        let offMain = await Task.detached(priority: .userInitiated) { () -> Sent<NSAttributedString> in
            let (font, room) = request.value
            var result = NSAttributedString()
            room.performAsCurrentDrawingAppearance {
                result = MarkdownRenderer(
                    baseFont: font,
                    textColor: .labelColor,
                    highlighter: SyntaxHighlighter.shared
                ).render(Self.sample, highlighting: .all)
            }
            return Sent(value: result)
        }.value.value

        #expect(offMain.string == onMain.string)
        #expect(RenderFingerprint.of(offMain) == RenderFingerprint.of(onMain))
    }

    /// Rendering in both rooms at once is what the app actually does — the
    /// transcript on main while the preview runs off it — and both the symbol
    /// cache and the highlighter's cache are shared between them.
    @Test func concurrentRendersInTwoAppearancesBothSucceed() async {
        let baseFont = NSFont.systemFont(ofSize: OreTheme.Font.prose)
        let rooms = [NSAppearance(named: .darkAqua), NSAppearance(named: .aqua)].compactMap { $0 }
        var expected: [String] = []
        for room in rooms {
            room.performAsCurrentDrawingAppearance {
                MarkdownRenderer.prewarmLinkSymbols(baseFont: baseFont)
            }
            expected.append(RenderFingerprint.of(render(baseFont: baseFont, appearance: room)))
        }

        let request = Sent(value: (baseFont, rooms))
        let produced = await withTaskGroup(of: Sent<(Int, String)>.self) { group in
            for index in rooms.indices {
                group.addTask(priority: .userInitiated) {
                    let (font, allRooms) = request.value
                    var result = NSAttributedString()
                    allRooms[index].performAsCurrentDrawingAppearance {
                        result = MarkdownRenderer(
                            baseFont: font,
                            textColor: .labelColor,
                            highlighter: SyntaxHighlighter.shared
                        ).render(Self.sample, highlighting: .all)
                    }
                    return Sent(value: (index, RenderFingerprint.of(result)))
                }
            }
            var byIndex: [Int: String] = [:]
            for await item in group { byIndex[item.value.0] = item.value.1 }
            return byIndex
        }

        for index in rooms.indices {
            #expect(produced[index] == expected[index])
        }
    }

    /// The whole reason the symbols are cached: a second render must reuse the
    /// image the first one built rather than ask AppKit's catalogue again.
    @Test func linkChipsShareOneSymbolImage() {
        let font = NSFont.systemFont(ofSize: 13)
        let first = MarkdownRenderer.urlChip(
            url: URL(string: "https://github.com/a/b")!, label: "github.com/a/b", baseFont: font
        )
        let second = MarkdownRenderer.urlChip(
            url: URL(string: "https://github.com/c/d")!, label: "github.com/c/d", baseFont: font
        )
        let images = [first, second].map { chip -> NSImage? in
            (chip.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.image
        }
        #expect(images[0] != nil)
        #expect(images[0] === images[1])
    }

    /// `prewarmLinkSymbols` is only worth anything if it covers every symbol a
    /// chip can ask for; a name the list misses would be built on the render
    /// thread instead.
    @Test func everyChipSymbolIsInThePrewarmList() {
        let urls = [
            "https://github.com/a/b", "https://gitlab.com/a", "https://bitbucket.org/a",
            "https://youtube.com/watch", "https://youtu.be/x", "https://vimeo.com/1",
            "https://stackoverflow.com/q/1", "https://stackexchange.com/q/1",
            "https://npmjs.com/p", "https://pypi.org/p", "https://crates.io/p",
            "https://developer.apple.com/x", "https://docs.swift.org/x",
            "https://readthedocs.io/x", "https://www.apple.com/x",
            "https://figma.com/f", "https://notion.so/n", "https://google.com/search",
            "https://example.com/anything", "mailto:someone@example.com",
        ].compactMap(URL.init(string:))
        #expect(urls.count == 20)
        for url in urls {
            #expect(MarkdownRenderer.linkSymbolNames.contains(MarkdownRenderer.linkSymbolName(for: url)))
        }
        #expect(Set(MarkdownRenderer.linkSymbolNames).count == MarkdownRenderer.linkSymbolNames.count)
    }
}

/// The bold/italic conversion used to go through `NSFontManager`, which is
/// AppKit's shared main-thread object. These pin the descriptor-based
/// replacement to exactly what the font manager returns, so "safe off main"
/// did not quietly become "a different face".
@MainActor
struct MarkdownFontTraitTests {
    /// Every font the renderer hands to `applying(trait:)`: the base prose
    /// font, the heading scales, list markers, table cells, inline code, and
    /// the two chip faces — plus the results of converting each, since emphasis
    /// nests.
    private static var rendererFonts: [NSFont] {
        let base = OreTheme.Font.prose
        var fonts: [NSFont] = [
            .systemFont(ofSize: base),
            .systemFont(ofSize: base, weight: .semibold),
            .systemFont(ofSize: base * 0.95, weight: .medium),
            .monospacedSystemFont(ofSize: base - 0.5, weight: .regular),
            .monospacedSystemFont(ofSize: base - 1, weight: .regular),
            .monospacedSystemFont(ofSize: base * 0.92, weight: .medium),
            .systemFont(ofSize: base - 0.5, weight: .semibold),
            .systemFont(ofSize: base - 0.5, weight: .regular),
        ]
        for scale in [1.45, 1.28, 1.14, 1.06, 1.0] as [CGFloat] {
            fonts.append(.systemFont(ofSize: base * scale, weight: .semibold))
        }
        return fonts
    }

    /// `.AppleSystemUIFontDemi` and `.SFNS-Semibold` are two spellings of one
    /// face, and `NSFont` knows it even though the names differ.
    private func isSameFace(_ lhs: NSFont, _ rhs: NSFont) -> Bool {
        lhs == rhs || (lhs.fontName == rhs.fontName && lhs.pointSize == rhs.pointSize)
    }

    @Test func traitsMatchTheFontManagerForEveryFontTheRendererMakes() {
        for font in Self.rendererFonts {
            for trait in [NSFontTraitMask.boldFontMask, .italicFontMask] {
                let expected = NSFontManager.shared.convert(font, toHaveTrait: trait)
                let actual = MarkdownRenderer.applying(trait, to: font)
                #expect(
                    isSameFace(expected, actual),
                    "\(font.fontName)+\(trait.rawValue): expected \(expected.fontName), got \(actual.fontName)"
                )

                // Nested emphasis: ***text*** converts twice, and repeated
                // emphasis has to be idempotent rather than drift a weight.
                let other: NSFontTraitMask = trait == .boldFontMask ? .italicFontMask : .boldFontMask
                for second in [other, trait] {
                    let expectedTwice = NSFontManager.shared.convert(expected, toHaveTrait: second)
                    let actualTwice = MarkdownRenderer.applying(second, to: actual)
                    let note = "\(font.fontName)+\(trait.rawValue)+\(second.rawValue):"
                        + " expected \(expectedTwice.fontName), got \(actualTwice.fontName)"
                    #expect(isSameFace(expectedTwice, actualTwice), "\(note)")
                }
            }
        }
    }

    /// The faces the reader actually sees, end to end: what the renderer puts
    /// on an emphasised run has to be what the font manager would have.
    /// Wider than the renderer needs, because `applying` is now the app's only
    /// trait conversion and the next caller may hand it anything: every system
    /// and monospaced weight, and a few real families with their own italics.
    @Test func traitsMatchTheFontManagerAcrossFamiliesAndWeights() {
        let weights: [NSFont.Weight] = [
            .ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black,
        ]
        var fonts: [NSFont] = []
        for size in [10, 12, 12.88, 13, 18.85] as [CGFloat] {
            for weight in weights {
                fonts.append(.systemFont(ofSize: size, weight: weight))
                fonts.append(.monospacedSystemFont(ofSize: size, weight: weight))
            }
            for family in ["Menlo", "Helvetica", "Times New Roman"] {
                if let font = NSFont(name: family, size: size) { fonts.append(font) }
            }
        }

        for font in fonts {
            for trait in [NSFontTraitMask.boldFontMask, .italicFontMask] {
                let expected = NSFontManager.shared.convert(font, toHaveTrait: trait)
                let actual = MarkdownRenderer.applying(trait, to: font)
                let note = "\(font.fontName)+\(trait.rawValue):"
                    + " expected \(expected.fontName), got \(actual.fontName)"
                #expect(isSameFace(expected, actual), "\(note)")
            }
        }
    }

    @Test func renderedEmphasisUsesTheFontManagerFaces() {
        let base = NSFont.systemFont(ofSize: OreTheme.Font.prose)
        let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        let boldItalic = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
        let code = NSFont.monospacedSystemFont(ofSize: OreTheme.Font.prose - 0.5, weight: .regular)
        let boldCode = NSFontManager.shared.convert(code, toHaveTrait: .boldFontMask)

        let rendered = MarkdownRenderer(baseFont: base, textColor: .labelColor)
            .render("plain **bold** *italic* ***both*** **`code`**")

        func font(under word: String) -> NSFont? {
            let location = (rendered.string as NSString).range(of: word).location
            guard location != NSNotFound else { return nil }
            return rendered.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        }

        #expect(font(under: "plain") == base)
        #expect(font(under: "bold") == bold)
        #expect(font(under: "italic") == italic)
        #expect(font(under: "both") == boldItalic)
        #expect(font(under: "code") == boldCode)
    }
}
