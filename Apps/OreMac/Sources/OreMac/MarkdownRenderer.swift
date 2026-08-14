import AppKit
import Markdown

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

    func render(_ markdown: String) -> NSAttributedString {
        let document = Document(parsing: markdown, options: [.parseBlockDirectives])
        var visitor = Visitor(
            baseFont: baseFont,
            textColor: textColor,
            highlighter: highlighter
        )
        let result = NSMutableAttributedString(
            attributedString: trimmingTrailingNewlines(visitor.visit(document))
        )
        linkFileReferences(in: result)
        // Trailing block spacing is padding inside the bubble's own padding.
        return result
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
        // click can jump straight to it.
        let pattern = #"(?<![A-Za-z0-9_])(?:/?(?:[A-Za-z0-9_.@+\-]+/)+)?[A-Za-z0-9_.@+\-]+\.(?:"#
            + extensions + #")(?::\d+(?:[:,]\d+)?)?"#
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
                .foregroundColor: NSColor.controlAccentColor,
                .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.92, weight: .medium),
                .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.08),
                .underlineStyle: 0,
            ], range: match.range)
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
        /// Nesting depth for list items, so a nested bullet indents.
        var listDepth = 0

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
                    .paragraphStyle: readableParagraph(spacingBefore: 14, spacingAfter: 8),
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
            paragraph.lineSpacing = 4.5
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
            let highlighted = highlighter?.highlight(
                code, language: codeBlock.language, font: font
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
                    .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.075),
                ]
            )
        }

        mutating func visitLink(_ link: Markdown.Link) -> NSAttributedString {
            let result = NSMutableAttributedString(attributedString: children(of: link))
            guard let destination = link.destination else { return result }
            let url: URL?
            if destination.hasPrefix("http://") || destination.hasPrefix("https://")
                || destination.hasPrefix("mailto:") || destination.hasPrefix("#") {
                url = URL(string: destination)
            } else {
                url = MarkdownRenderer.fileReferenceURL(destination)
            }
            guard let url else { return result }

            result.addAttributes(
                [
                    .link: url,
                    .foregroundColor: NSColor.linkColor,
                ],
                range: NSRange(location: 0, length: result.length)
            )
            return result
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
