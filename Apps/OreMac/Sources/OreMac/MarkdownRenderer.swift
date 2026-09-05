import AppKit
import Markdown

/// Inline token (file chip, url chip, @-mention, inline code) colors, resolved
/// at draw time per appearance. These strings render in two very different
/// rooms: the main window's smoked glass (always dark) and the assistant
/// window (system appearance). The old constants — accent text on an
/// accent-at-8% wash — were designed for white paper; over dark glass they
/// collapsed into an unreadable navy-on-navy blob.
extension NSColor {
    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Token text: the system accent on paper, lifted toward white on glass
    /// where the raw accent sinks into the dark.
    static let oreInlineChipText = NSColor(name: nil) { appearance in
        guard isDark(appearance) else { return .controlAccentColor }
        return NSColor.controlAccentColor.blended(withFraction: 0.45, of: .white)
            ?? .controlAccentColor
    }

    /// Token fill: an accent wash on paper, a neutral white lift on glass —
    /// neutral because a dark-accent wash adds no contrast over dark glass.
    static let oreInlineChipFill = NSColor(name: nil) { appearance in
        guard isDark(appearance) else {
            return NSColor.controlAccentColor.withAlphaComponent(0.08)
        }
        return NSColor.white.withAlphaComponent(0.12)
    }
}

/// Renders an agent's markdown into an `NSAttributedString`.
///
/// Agents write markdown constantly — headings, bullet lists, inline code, and
/// fenced code blocks — and showing it raw means the reader parses the
/// formatting themselves, in the one place where they are trying to read
/// quickly. Rendering it is the difference between a transcript and a log.
///
/// The output is a plain attributed string rather than a view hierarchy, which
/// is what lets the AppKit transcript keep one text view per row and measure a
/// row's height by laying out its text once.
struct MarkdownRenderer {
    var baseFont: NSFont
    var textColor: NSColor
    var highlighter: SyntaxHighlighter?

    init(
        baseFont: NSFont = .systemFont(ofSize: 13),
        textColor: NSColor = .labelColor,
        highlighter: SyntaxHighlighter? = nil
    ) {
        self.baseFont = baseFont
        self.textColor = textColor
        self.highlighter = highlighter
    }

    func render(
        _ markdown: String,
        highlighting: HighlightCachePolicy = .all
    ) -> NSAttributedString {
        let document = Document(parsing: markdown, options: [.parseBlockDirectives])
        let fenceCount = codeBlockCount(in: document)
        var visitor = Visitor(
            baseFont: baseFont,
            textColor: textColor,
            highlighter: highlighter,
            fenceCount: fenceCount,
            skipCachingLastFence: highlighting == .stablePrefix
        )
        let result = NSMutableAttributedString(
            attributedString: trimmingTrailingNewlines(visitor.visit(document))
        )
        // Claim bare URLs first so the file-reference pass can't chew into a
        // domain (its single-letter extensions like `.c`/`.m` used to turn
        // `github.com` into a `github.c` file chip mid-URL).
        linkifyBareURLs(in: result)
        linkFileReferences(in: result)
        // Trailing block spacing is padding inside the bubble's own padding.
        return result
    }

    /// How aggressively fenced-block highlighting is cached.
    ///
    /// A streaming row re-renders on every delta. Completed fences above the
    /// caret are stable and should hit the highlighter cache; the last open
    /// fence is still growing and would only pollute it.
    enum HighlightCachePolicy {
        case all
        case stablePrefix
    }

    private func codeBlockCount(in markup: any Markup) -> Int {
        var count = 0
        if markup is CodeBlock { count += 1 }
        for child in markup.children {
            count += codeBlockCount(in: child)
        }
        return count
    }

    private func trimmingTrailingNewlines(_ string: NSAttributedString) -> NSAttributedString {
        var length = string.length
        let utf16 = string.string as NSString
        while length > 0, utf16.character(at: length - 1) == 10 {
            length -= 1
        }
        guard length < string.length else { return string }
        return string.attributedSubstring(from: NSRange(location: 0, length: length))
    }

    /// A deterministic local URL keeps workspace references inside ORE. A
    /// regular relative URL is otherwise handed to NSWorkspace, which treats
    /// `server/index.ts` as a Finder target and produces an opaque -50 error.
    static func fileReferenceURL(_ reference: String) -> URL? {
        var components = URLComponents()
        components.scheme = "ore-file"
        components.host = "workspace"
        components.queryItems = [URLQueryItem(name: "path", value: reference)]
        return components.url
    }

    private func linkFileReferences(in result: NSMutableAttributedString) {
        let extensions = [
            "swift", "m", "mm", "h", "c", "cc", "cpp", "cs", "go", "rs", "java", "kt",
            "js", "jsx", "ts", "tsx", "py", "rb", "php", "sh", "zsh", "fish", "sql",
            "html", "css", "scss", "vue", "svelte", "json", "jsonl", "yaml", "yml", "toml",
            "xml", "md", "mdx", "txt", "plist", "gradle", "properties", "env",
        ].joined(separator: "|")
        // A trailing `:line`, `:line:col`, or `:line,col` locator is captured so a
        // click can jump straight to it. The trailing `(?![A-Za-z0-9])` boundary
        // stops a one-letter extension from matching the head of a longer run —
        // e.g. the `.c` in `github.com` — which used to fracture URLs.
        let pattern = #"(?<![A-Za-z0-9_])(?:/?(?:[A-Za-z0-9_.@+\-]+/)+)?[A-Za-z0-9_.@+\-]+\.(?:"#
            + extensions + #")(?::\d+(?:[:,]\d+)?)?(?![A-Za-z0-9])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let whole = NSRange(location: 0, length: result.length)
        for match in expression.matches(in: result.string, range: whole).reversed() {
            guard result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
            let reference = (result.string as NSString).substring(with: match.range)
            guard let url = Self.fileReferenceURL(reference) else { continue }
            // Render as a quiet inline "chip": monospaced, accent-tinted, with a
            // subtle fill — reads as a file token rather than a raw blue link.
            result.addAttributes([
                .link: url,
                .foregroundColor: NSColor.oreInlineChipText,
                .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.92, weight: .medium),
                .backgroundColor: NSColor.oreInlineChipFill,
                .underlineStyle: 0,
            ], range: match.range)
        }
    }

    /// Turns bare `http(s)://` and `mailto:` URLs into clickable chips: a site
    /// icon plus a shortened label, so a long link reads as one tappable token
    /// instead of a wall of path segments the reader has to scan.
    private func linkifyBareURLs(in result: NSMutableAttributedString) {
        let pattern = #"(?:https?://|mailto:)[^\s<>]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let whole = NSRange(location: 0, length: result.length)
        let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "\"", "'", "]", ">"]
        for match in expression.matches(in: result.string, range: whole).reversed() {
            // Leave anything already linked (a markdown link's own text) alone.
            guard result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil
            else { continue }
            var text = (result.string as NSString).substring(with: match.range)
            var range = match.range
            // Sentence punctuation that trails a URL isn't part of it.
            while let last = text.last, trailing.contains(last) {
                text.removeLast()
                range.length -= 1
            }
            guard range.length > 0, let url = URL(string: text) else { continue }
            result.replaceCharacters(
                in: range,
                with: Self.urlChip(url: url, label: Self.linkLabel(for: url), baseFont: baseFont)
            )
        }
    }

    /// A compact, clickable chip for a web link: a site-aware icon and a short
    /// label, tinted and filled like ORE's other inline tokens.
    static func urlChip(url: URL, label: String, baseFont: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if let icon = NSImage(systemSymbolName: linkSymbolName(for: url), accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: baseFont.pointSize * 0.92, weight: .medium))?
            .withSymbolConfiguration(.init(paletteColors: [.oreInlineChipText])) {
            icon.isTemplate = false
            let attachment = NSTextAttachment()
            attachment.image = icon
            let side = baseFont.pointSize
            attachment.bounds = NSRect(x: 0, y: -2, width: side, height: side)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "\u{2009}"))
        }
        result.append(NSAttributedString(
            string: label,
            attributes: [.font: NSFont.systemFont(ofSize: baseFont.pointSize * 0.95, weight: .medium)]
        ))
        result.addAttributes([
            .link: url,
            .foregroundColor: NSColor.oreInlineChipText,
            .backgroundColor: NSColor.oreInlineChipFill,
            .underlineStyle: 0,
        ], range: NSRange(location: 0, length: result.length))
        return result
    }

    /// A short, human label for a link chip: the host, plus the tail of the path
    /// when there is one, so `…/OpenResearchh/ore/pull/1` reads as `…/pull/1`.
    static func linkLabel(for url: URL) -> String {
        if url.scheme == "mailto" {
            return url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        }
        let host = (url.host ?? url.absoluteString)
            .replacingOccurrences(of: "www.", with: "")
        let segments = url.path.split(separator: "/").map(String.init)
        if segments.isEmpty { return host }
        if segments.count <= 2 { return host + "/" + segments.joined(separator: "/") }
        return host + "/…/" + segments.suffix(2).joined(separator: "/")
    }

    /// A site-appropriate SF Symbol for a link chip, so common destinations are
    /// recognisable at a glance; everything else gets a neutral globe.
    static func linkSymbolName(for url: URL) -> String {
        if url.scheme == "mailto" { return "envelope.fill" }
        let host = (url.host ?? "").lowercased()
        switch true {
        case host.contains("github"), host.contains("gitlab"), host.contains("bitbucket"):
            return "chevron.left.forwardslash.chevron.right"
        case host.contains("youtube"), host.contains("youtu.be"), host.contains("vimeo"):
            return "play.rectangle.fill"
        case host.contains("stackoverflow"), host.contains("stackexchange"):
            return "bubble.left.and.bubble.right.fill"
        case host.contains("npmjs"), host.contains("pypi"), host.contains("crates.io"):
            return "shippingbox.fill"
        case host.contains("developer."), host.contains("docs."),
             host.contains("readthedocs"), host.hasSuffix("apple.com"):
            return "book.fill"
        case host.contains("figma"):
            return "pencil.and.outline"
        case host.contains("notion"):
            return "note.text"
        case host.contains("google"):
            return "magnifyingglass"
        default:
            return "globe"
        }
    }

    /// Walks the parsed tree and builds the attributed string.
    ///
    /// swift-markdown gives a CommonMark tree; the mapping here is deliberately
    /// small — the transcript is prose and code, not a document renderer, and
    /// anything unsupported falls through to its plain text rather than
    /// disappearing.
    private struct Visitor: MarkupVisitor {
        typealias Result = NSAttributedString

        let baseFont: NSFont
        let textColor: NSColor
        let highlighter: SyntaxHighlighter?
        let fenceCount: Int
        let skipCachingLastFence: Bool
        /// Nesting depth for list items, so a nested bullet indents.
        var listDepth = 0
        var visitedFences = 0

        mutating func defaultVisit(_ markup: any Markup) -> NSAttributedString {
            children(of: markup)
        }

        mutating func children(of markup: any Markup) -> NSAttributedString {
            let result = NSMutableAttributedString()
            for child in markup.children {
                result.append(visit(child))
            }
            return result
        }

        // MARK: - Blocks

        mutating func visitParagraph(_ paragraph: Paragraph) -> NSAttributedString {
            let result = NSMutableAttributedString(attributedString: children(of: paragraph))
            let style = readableParagraph(spacingAfter: 12)
            result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
            result.append(NSAttributedString(string: "\n", attributes: [.font: baseFont, .paragraphStyle: style]))
            return result
        }

        mutating func visitHeading(_ heading: Heading) -> NSAttributedString {
            let sizes: [CGFloat] = [1.45, 1.28, 1.14, 1.06, 1.0, 1.0]
            let scale = sizes[min(max(heading.level - 1, 0), sizes.count - 1)]
            let font = NSFont.systemFont(
                ofSize: baseFont.pointSize * scale, weight: .semibold
            )

            let result = NSMutableAttributedString(attributedString: children(of: heading))
            result.addAttributes(
                [
                    .font: font,
                    .foregroundColor: textColor,
                    .paragraphStyle: readableParagraph(spacingBefore: 10, spacingAfter: 7),
                ],
                range: NSRange(location: 0, length: result.length)
            )
            result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            return result
        }

        mutating func visitUnorderedList(_ list: UnorderedList) -> NSAttributedString {
            listDepth += 1
            defer { listDepth -= 1 }
            return children(of: list)
        }

        mutating func visitOrderedList(_ list: OrderedList) -> NSAttributedString {
            listDepth += 1
            defer { listDepth -= 1 }

            let result = NSMutableAttributedString()
            for (index, item) in list.listItems.enumerated() {
                result.append(renderListItem(item, marker: "\(index + 1)."))
            }
            return result
        }

        mutating func visitListItem(_ item: ListItem) -> NSAttributedString {
            // A checklist is how an agent shows progress, so it renders as one.
            let marker: String
            switch item.checkbox {
            case .checked: marker = "☑"
            case .unchecked: marker = "☐"
            case nil: marker = "•"
            }
            return renderListItem(item, marker: marker)
        }

        private mutating func renderListItem(
            _ item: ListItem,
            marker: String
        ) -> NSAttributedString {
            let indent = String(repeating: "    ", count: max(listDepth - 1, 0))
            let result = NSMutableAttributedString(
                string: "\(indent)\(marker) ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold),
                    .foregroundColor: marker == "•" ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
                ]
            )

            let body = NSMutableAttributedString(attributedString: children(of: item))
            // Paragraphs inside a list item add their own blank line; a list
            // reads as a list only without it.
            while body.string.hasSuffix("\n\n") {
                body.deleteCharacters(
                    in: NSRange(location: body.length - 1, length: 1)
                )
            }
            result.append(body)
            if !result.string.hasSuffix("\n") {
                result.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
            }
            let paragraph = readableParagraph(spacingAfter: 7)
            paragraph.lineSpacing = 4
            paragraph.firstLineHeadIndent = CGFloat(max(listDepth - 1, 0) * 22)
            paragraph.headIndent = CGFloat(listDepth * 22)
            result.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: NSRange(location: 0, length: result.length)
            )
            return result
        }

        /// Tables use TextKit's native table blocks. Each cell therefore owns
        /// its wrapping width; a long value cannot push the following column
        /// onto a visually unrelated line as it can with tabs or ASCII grids.
        mutating func visitTable(_ table: Table) -> NSAttributedString {
            var header: [NSAttributedString] = []
            for cell in table.head.cells { header.append(visit(cell)) }
            var body: [[NSAttributedString]] = []
            for row in table.body.rows {
                var cells: [NSAttributedString] = []
                for cell in row.cells { cells.append(visit(cell)) }
                body.append(cells)
            }
            let rows = [header] + body
            let columns = rows.map(\.count).max() ?? 0
            guard columns > 0 else { return NSAttributedString() }

            let textTable = NSTextTable()
            textTable.numberOfColumns = columns
            textTable.collapsesBorders = true
            textTable.hidesEmptyCells = false

            let result = NSMutableAttributedString()
            for (rowIndex, row) in rows.enumerated() {
                for column in 0..<columns {
                    let cell = column < row.count ? row[column] : NSAttributedString()
                    let value = NSMutableAttributedString(attributedString: cell)
                    while value.string.hasSuffix("\n") {
                        value.deleteCharacters(in: NSRange(location: value.length - 1, length: 1))
                    }
                    if value.length == 0 { value.append(NSAttributedString(string: " ")) }

                    let block = NSTextTableBlock(
                        table: textTable,
                        startingRow: rowIndex,
                        rowSpan: 1,
                        startingColumn: column,
                        columnSpan: 1
                    )
                    for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
                        block.setWidth(7, type: .absoluteValueType, for: .padding, edge: edge)
                    }
                    block.backgroundColor = rowIndex == 0
                        ? NSColor.secondaryLabelColor.withAlphaComponent(0.065)
                        : rowIndex.isMultiple(of: 2)
                            ? NSColor.secondaryLabelColor.withAlphaComponent(0.025)
                            : .clear

                    let paragraph = readableParagraph(spacingBefore: 0, spacingAfter: 0)
                    paragraph.lineSpacing = 3
                    paragraph.textBlocks = [block]
                    value.addAttributes([
                        .font: NSFont.systemFont(
                            ofSize: baseFont.pointSize - 0.5,
                            weight: rowIndex == 0 ? .semibold : .regular
                        ),
                        .foregroundColor: rowIndex == 0 ? textColor : NSColor.secondaryLabelColor,
                        .paragraphStyle: paragraph,
                    ], range: NSRange(location: 0, length: value.length))
                    result.append(value)
                    result.append(NSAttributedString(
                        string: "\n",
                        attributes: [.font: baseFont, .paragraphStyle: paragraph]
                    ))
                }
            }
            result.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
            return result
        }

        mutating func visitTableHead(_ tableHead: Table.Head) -> NSAttributedString { children(of: tableHead) }
        mutating func visitTableBody(_ tableBody: Table.Body) -> NSAttributedString { children(of: tableBody) }
        mutating func visitTableRow(_ tableRow: Table.Row) -> NSAttributedString { children(of: tableRow) }
        mutating func visitTableCell(_ tableCell: Table.Cell) -> NSAttributedString { children(of: tableCell) }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> NSAttributedString {
            let code = codeBlock.code.hasSuffix("\n")
                ? String(codeBlock.code.dropLast())
                : codeBlock.code

            let font = NSFont.monospacedSystemFont(
                ofSize: baseFont.pointSize - 1, weight: .regular
            )
            visitedFences += 1
            let cache = !(skipCachingLastFence && visitedFences == fenceCount)
            let highlighted = highlighter?.highlight(
                code, language: codeBlock.language, font: font, cache: cache
            ) ?? NSAttributedString(
                string: code,
                attributes: [.font: font, .foregroundColor: textColor]
            )

            let result = NSMutableAttributedString(attributedString: highlighted)
            let table = NSTextTable()
            table.numberOfColumns = 1
            table.collapsesBorders = true
            let block = NSTextTableBlock(
                table: table,
                startingRow: 0,
                rowSpan: 1,
                startingColumn: 0,
                columnSpan: 1
            )
            for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
                block.setWidth(10, type: .absoluteValueType, for: .padding, edge: edge)
            }
            block.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.075)

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacingBefore = 8
            paragraph.paragraphSpacing = 8
            paragraph.textBlocks = [block]
            result.addAttributes(
                [
                    .paragraphStyle: paragraph,
                ],
                range: NSRange(location: 0, length: result.length)
            )
            result.append(NSAttributedString(string: "\n\n", attributes: [.font: font]))
            return result
        }

        mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> NSAttributedString {
            let result = NSMutableAttributedString(attributedString: children(of: blockQuote))
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = 16
            paragraph.headIndent = 16
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacingBefore = 6
            paragraph.paragraphSpacing = 8
            result.addAttributes(
                [
                    .paragraphStyle: paragraph,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.045),
                ],
                range: NSRange(location: 0, length: result.length)
            )
            return result
        }

        mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> NSAttributedString {
            NSAttributedString(
                string: "────────\n\n",
                attributes: [.font: baseFont, .foregroundColor: NSColor.tertiaryLabelColor]
            )
        }

        // MARK: - Inline

        mutating func visitText(_ text: Markdown.Text) -> NSAttributedString {
            NSAttributedString(
                string: text.string,
                attributes: [.font: baseFont, .foregroundColor: textColor]
            )
        }

        mutating func visitEmphasis(_ emphasis: Emphasis) -> NSAttributedString {
            applying(trait: .italicFontMask, to: children(of: emphasis))
        }

        mutating func visitStrong(_ strong: Strong) -> NSAttributedString {
            applying(trait: .boldFontMask, to: children(of: strong))
        }

        mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> NSAttributedString {
            let result = NSMutableAttributedString(attributedString: children(of: strikethrough))
            result.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: 0, length: result.length)
            )
            return result
        }

        mutating func visitInlineCode(_ inlineCode: InlineCode) -> NSAttributedString {
            NSAttributedString(
                string: inlineCode.code,
                attributes: [
                    .font: NSFont.monospacedSystemFont(
                        ofSize: baseFont.pointSize - 0.5, weight: .regular
                    ),
                    // Quiet and semantic: inline code should read as code, not
                    // as a neon warning label inside an otherwise calm answer.
                    .foregroundColor: textColor,
                    .backgroundColor: NSColor.oreInlineChipFill,
                ]
            )
        }

        mutating func visitLink(_ link: Markdown.Link) -> NSAttributedString {
            let inner = NSMutableAttributedString(attributedString: children(of: link))
            guard let destination = link.destination else { return inner }
            let isWeb = destination.hasPrefix("http://")
                || destination.hasPrefix("https://")
                || destination.hasPrefix("mailto:")
            let url = isWeb || destination.hasPrefix("#")
                ? URL(string: destination)
                : MarkdownRenderer.fileReferenceURL(destination)
            guard let url else { return inner }

            if isWeb {
                // A descriptive link keeps its words; a bare-URL link is shortened.
                // Either way it reads as a clickable chip with a site icon.
                let visible = inner.string.trimmingCharacters(in: .whitespaces)
                let label = visible.isEmpty || visible.hasPrefix("http") || visible == destination
                    ? MarkdownRenderer.linkLabel(for: url)
                    : visible
                return MarkdownRenderer.urlChip(url: url, label: label, baseFont: baseFont)
            }

            inner.addAttributes(
                [.link: url, .foregroundColor: NSColor.linkColor],
                range: NSRange(location: 0, length: inner.length)
            )
            return inner
        }

        mutating func visitSoftBreak(_ softBreak: SoftBreak) -> NSAttributedString {
            NSAttributedString(string: " ", attributes: [.font: baseFont])
        }

        mutating func visitLineBreak(_ lineBreak: LineBreak) -> NSAttributedString {
            NSAttributedString(string: "\n", attributes: [.font: baseFont])
        }

        // MARK: - Helpers

        private func readableParagraph(
            spacingBefore: CGFloat = 0,
            spacingAfter: CGFloat = 0
        ) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4
            style.paragraphSpacingBefore = spacingBefore
            style.paragraphSpacing = spacingAfter
            style.lineBreakMode = .byWordWrapping
            return style
        }

        private func applying(
            trait: NSFontTraitMask,
            to string: NSAttributedString
        ) -> NSAttributedString {
            let result = NSMutableAttributedString(attributedString: string)
            let whole = NSRange(location: 0, length: result.length)

            result.enumerateAttribute(.font, in: whole) { value, range, _ in
                let font = (value as? NSFont) ?? baseFont
                let converted = NSFontManager.shared.convert(font, toHaveTrait: trait)
                result.addAttribute(.font, value: converted, range: range)
            }
            return result
        }
    }
}
