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
///
/// Rendering is safe off the main actor. Nothing here touches a live view, and
/// the two pieces of AppKit that were main-thread-only have been replaced: font
/// traits come from thread-safe CoreText rather than `NSFontManager`, and
/// link-chip symbols come from `LinkSymbolStore` — a locked cache the main
/// actor can fill ahead of time with `prewarmLinkSymbols`. Everything else it
/// builds (fonts by size and weight, paragraph styles, text tables, semantic
/// `NSColor`s, `NSRegularExpression`s) is either a value or immutable and
/// shared read-only; dynamic colours stay unresolved until they are drawn.
///
/// Two things a background caller still owes it. Bind the room first —
/// `appearance.performAsCurrentDrawingAppearance { … }` — because the symbol
/// cache and `SyntaxHighlighter`'s cache both key on the current drawing
/// appearance and `NSAppearance.currentDrawing()` has no window to ask for on
/// a worker thread. And call `prewarmLinkSymbols` on the main actor inside that
/// same appearance.
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
        // Trailing block spacing is padding inside the bubble's own padding.
        trimmingTrailingNewlines(renderBlocks(markdown, highlighting: highlighting))
    }

    /// Parses, draws and links one run of top-level blocks, keeping the
    /// trailing newlines so runs rendered separately concatenate into exactly
    /// what one render of the whole run produces. Trimming before or after the
    /// link passes is equivalent: neither pattern matches across a newline.
    private func renderBlocks(
        _ markdown: String,
        highlighting: HighlightCachePolicy
    ) -> NSMutableAttributedString {
        let document = Document(parsing: markdown, options: [.parseBlockDirectives])
        let fenceCount = codeBlockCount(in: document)
        var visitor = Visitor(
            baseFont: baseFont,
            textColor: textColor,
            highlighter: highlighter,
            fenceCount: fenceCount,
            skipCachingLastFence: highlighting == .stablePrefix
        )
        let result = NSMutableAttributedString(attributedString: visitor.visit(document))
        // Claim bare URLs first so the file-reference pass can't chew into a
        // domain (its single-letter extensions like `.c`/`.m` used to turn
        // `github.com` into a `github.c` file chip mid-URL).
        linkifyBareURLs(in: result)
        linkFileReferences(in: result)
        return result
    }

    // MARK: - Streaming

    /// The settled head of a streaming reply, rendered once.
    ///
    /// A streaming row used to be re-parsed from its first byte on every flush,
    /// so a long answer cost more per delta the longer it got. Everything above
    /// the last blank line that starts an independent block cannot change as
    /// text is appended, so it is rendered once and only the tail is redone.
    struct StreamingPrefix {
        fileprivate let source: String
        fileprivate let rendered: NSAttributedString
        fileprivate let baseFont: NSFont
        fileprivate let textColor: NSColor

        /// UTF-8 length of the source the head covers.
        var sourceLength: Int { source.utf8.count }
        /// UTF-16 length of the rendered head, for callers bounding a cache.
        var renderedLength: Int { rendered.length }

        fileprivate func isExtended(by markdown: String, baseFont: NSFont, textColor: NSColor) -> Bool {
            guard self.baseFont == baseFont, self.textColor == textColor else { return false }
            let contiguous = source.utf8.withContiguousStorageIfAvailable { head in
                markdown.utf8.withContiguousStorageIfAvailable { whole -> Bool in
                    guard whole.count >= head.count else { return false }
                    guard let headBase = head.baseAddress, let wholeBase = whole.baseAddress else {
                        return head.isEmpty
                    }
                    return memcmp(wholeBase, headBase, head.count) == 0
                }
            }
            if let answer = contiguous.flatMap({ $0 }) { return answer }
            return markdown.utf8.starts(with: source.utf8)
        }
    }

    struct StreamingRender {
        var rendered: NSAttributedString
        /// Nil when the document has no settled head, or holds a construct that
        /// reaches across blank lines, so the next flush renders it whole.
        var prefix: StreamingPrefix?
        /// UTF-16 length of `rendered`'s opening run copied unchanged from the
        /// `previous` head this render reused — zero when nothing was reused.
        /// Characters and attributes there are identical to the previous
        /// render's, so a text storage already holding that render only needs
        /// what follows replaced (clamped to both lengths: trimming a trailing
        /// newline can leave either render shorter than the head).
        var reusedLength = 0
    }

    /// Renders a document that is still growing, reusing `previous` when the
    /// text only grew past it. The result is identical to
    /// `render(markdown, highlighting: .stablePrefix)`.
    func renderStreaming(_ markdown: String, reusing previous: StreamingPrefix?) -> StreamingRender {
        let reusable = previous.flatMap {
            $0.isExtended(by: markdown, baseFont: baseFont, textColor: textColor) ? $0 : nil
        }
        let scanStart = reusable?.sourceLength ?? 0
        guard case .split(let found) = Self.streamingBoundary(in: markdown, from: scanStart) else {
            return StreamingRender(rendered: render(markdown, highlighting: .stablePrefix), prefix: nil)
        }
        let boundary = found ?? scanStart

        var head = reusable
        if boundary > scanStart {
            let chunk = renderBlocks(
                Self.slice(markdown, utf8From: scanStart, to: boundary), highlighting: .all
            )
            // Every block the visitor draws ends in a newline, which is what
            // keeps the link passes from matching across the seam. A chunk that
            // does not is something this split does not model; render whole.
            if chunk.length > 0, chunk.mutableString.character(at: chunk.length - 1) != 10 {
                return StreamingRender(rendered: render(markdown, highlighting: .stablePrefix), prefix: nil)
            }
            let combined = NSMutableAttributedString(attributedString: reusable?.rendered ?? NSAttributedString())
            combined.append(chunk)
            head = StreamingPrefix(
                source: Self.slice(markdown, utf8From: 0, to: boundary),
                rendered: combined,
                baseFont: baseFont,
                textColor: textColor
            )
        }

        let tail = renderBlocks(
            Self.slice(markdown, utf8From: boundary, to: markdown.utf8.count),
            highlighting: .stablePrefix
        )
        guard let head else {
            return StreamingRender(rendered: trimmingTrailingNewlines(tail), prefix: nil)
        }
        let result = NSMutableAttributedString(attributedString: head.rendered)
        result.append(tail)
        return StreamingRender(
            rendered: trimmingTrailingNewlines(result),
            prefix: head,
            reusedLength: reusable?.renderedLength ?? 0
        )
    }

    enum StreamingBoundary: Equatable {
        /// Something in the document can reach across a blank line (a link
        /// reference definition, an HTML block, a directive, a fence nested in
        /// a container), so it has to be parsed whole.
        case unsplittable
        /// UTF-8 offset of the latest line after `from` where a parse of the
        /// rest starts in the same state a parse of the whole would be in.
        case split(at: Int?)
    }

    /// Finds where a streaming document can be cut without changing how either
    /// side parses. Deliberately conservative: a cut is only taken after a blank
    /// line, outside any fence, before an unindented line that cannot continue
    /// a list or quote. Anything unsure renders whole, which is only slower.
    static func streamingBoundary(in markdown: String, from start: Int = 0) -> StreamingBoundary {
        markdown.utf8.withContiguousStorageIfAvailable { scanBoundary($0, from: start) } ?? .unsplittable
    }

    private static func scanBoundary(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> StreamingBoundary {
        let count = bytes.count
        guard start >= 0, start <= count else { return .unsplittable }
        var fence: (marker: UInt8, length: Int)?
        var afterBlank = false
        var latest: Int?
        var lineStart = start
        while lineStart < count {
            var lineEnd = lineStart
            while lineEnd < count, bytes[lineEnd] != 10 { lineEnd += 1 }
            var content = lineStart
            var leadingTab = false
            while content < lineEnd, bytes[content] == 32 || bytes[content] == 9 {
                if bytes[content] == 9 { leadingTab = true }
                content += 1
            }
            let indent = content - lineStart

            if let open = fence {
                if !leadingTab, indent <= 3,
                   closesFence(bytes, from: content, to: lineEnd, marker: open.marker, length: open.length) {
                    fence = nil
                }
            } else if content == lineEnd {
                afterBlank = true
            } else {
                if afterBlank, indent == 0, startsIndependentBlock(bytes, at: content, lineEnd: lineEnd) {
                    latest = lineStart
                }
                afterBlank = false
                if let opened = fenceOpening(bytes, from: content, to: lineEnd) {
                    // An indented fence may belong to a list item, and ends
                    // when the item does — a rule this scan does not track.
                    guard indent == 0 else { return .unsplittable }
                    fence = opened
                } else if indent <= 3, !leadingTab, reachesAcrossBlocks(bytes, from: content, to: lineEnd) {
                    return .unsplittable
                }
            }
            lineStart = lineEnd + 1
        }
        return .split(at: latest)
    }

    private static func fenceOpening(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> (marker: UInt8, length: Int)? {
        let marker = bytes[start]
        guard marker == 96 || marker == 126 else { return nil }
        var index = start
        while index < end, bytes[index] == marker { index += 1 }
        let length = index - start
        guard length >= 3 else { return nil }
        // A backtick fence's info string cannot itself contain a backtick.
        if marker == 96, bytes[index..<end].contains(96) { return nil }
        return (marker, length)
    }

    private static func closesFence(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int, marker: UInt8, length: Int
    ) -> Bool {
        var index = start
        while index < end, bytes[index] == marker { index += 1 }
        guard index - start >= length else { return false }
        return bytes[index..<end].allSatisfy { $0 == 32 || $0 == 9 || $0 == 13 }
    }

    /// Link reference definitions resolve across the whole document; HTML
    /// blocks and directives can span blank lines.
    private static func reachesAcrossBlocks(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> Bool {
        switch bytes[start] {
        case 60, 64: // `<`, `@`
            return true
        case 91: // `[`
            var index = start + 1
            while index + 1 < end {
                if bytes[index] == 93, bytes[index + 1] == 58 { return true } // `]:`
                index += 1
            }
            return false
        default:
            return false
        }
    }

    /// Whether an unindented line after a blank line begins a block that
    /// neither continues nor extends what came before it. A line still
    /// arriving that could yet become a list marker is not.
    private static func startsIndependentBlock(
        _ bytes: UnsafeBufferPointer<UInt8>, at start: Int, lineEnd: Int
    ) -> Bool {
        switch bytes[start] {
        case 62: // `>`
            return false
        case 45, 43, 42: // `-`, `+`, `*`
            let next = start + 1
            guard next < lineEnd else { return false }
            return bytes[next] != 32 && bytes[next] != 9
        case 48...57:
            var index = start
            while index < lineEnd, (48...57).contains(bytes[index]) { index += 1 }
            guard index < lineEnd else { return false }
            return bytes[index] != 46 && bytes[index] != 41 // `.`, `)`
        default:
            return true
        }
    }

    /// Cuts at UTF-8 offsets that always sit just after a newline, so both
    /// ends are scalar boundaries.
    private static func slice(_ string: String, utf8From start: Int, to end: Int) -> String {
        let utf8 = string.utf8
        let lower = utf8.index(utf8.startIndex, offsetBy: start)
        let upper = utf8.index(lower, offsetBy: end - start)
        return String(string[lower..<upper])
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

    /// Compiled once: every render of every row used to rebuild this pattern
    /// and its long extension alternation.
    private static let fileReferenceExpression: NSRegularExpression? = {
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
        return try? NSRegularExpression(pattern: pattern)
    }()

    private static let bareURLExpression = try? NSRegularExpression(
        pattern: #"(?:https?://|mailto:)[^\s<>]+"#
    )

    private func linkFileReferences(in result: NSMutableAttributedString) {
        guard let expression = Self.fileReferenceExpression else { return }
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
        guard let expression = Self.bareURLExpression else { return }
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
        if let icon = LinkSymbolStore.shared.image(
            for: LinkSymbolKey(
                name: linkSymbolName(for: url),
                basePointSize: baseFont.pointSize,
                // The palette colour baked into the configuration is dynamic,
                // so the same symbol is a different image on glass than on
                // paper. Callers bind the room with
                // `performAsCurrentDrawingAppearance`; keying on it reproduces
                // exactly what building the image here used to pick up.
                appearance: NSAppearance.currentDrawing().name.rawValue
            )
        ) {
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

    /// Every symbol `linkSymbolName(for:)` can return.
    ///
    /// The set is closed on purpose: `prewarmLinkSymbols` can then build all of
    /// them on the main actor before an off-main render starts, so no render
    /// thread ever has to reach into AppKit's symbol catalogue itself.
    /// `MarkdownRenderOffMainTests` keeps this list and that switch in step.
    static let linkSymbolNames = [
        "envelope.fill",
        "chevron.left.forwardslash.chevron.right",
        "play.rectangle.fill",
        "bubble.left.and.bubble.right.fill",
        "shippingbox.fill",
        "book.fill",
        "pencil.and.outline",
        "note.text",
        "magnifyingglass",
        "globe",
    ]

    /// Builds every link-chip symbol for `baseFont` under the current drawing
    /// appearance, so a subsequent render — on any thread — only reads them.
    ///
    /// Call this on the main actor immediately before handing a render to a
    /// background task, inside the same appearance the render will use.
    @MainActor
    static func prewarmLinkSymbols(baseFont: NSFont) {
        let appearance = NSAppearance.currentDrawing().name.rawValue
        for name in linkSymbolNames {
            _ = LinkSymbolStore.shared.image(
                for: LinkSymbolKey(
                    name: name, basePointSize: baseFont.pointSize, appearance: appearance
                )
            )
        }
    }

    fileprivate struct LinkSymbolKey: Hashable {
        var name: String
        var basePointSize: CGFloat
        var appearance: String
    }

    /// The link-chip symbol images, made once and shared.
    ///
    /// `NSImage(systemSymbolName:)` plus two `withSymbolConfiguration` passes
    /// is a catalogue lookup and a template build — AppKit work that has no
    /// documented thread contract — and a long README can ask for dozens of
    /// them. Building each image once under a lock, keyed by symbol, base size
    /// and appearance, means the off-main preview render normally finds every
    /// icon already made (see `prewarmLinkSymbols`) and the main-actor
    /// transcript stops re-making the same globe for every link it draws.
    ///
    /// A miss still builds in place rather than dropping the icon: a chip
    /// without its symbol would be a visible change, and this is the same call
    /// the renderer has always made. With the prewarm above it should not
    /// happen off the main actor at all.
    ///
    /// Images are never mutated after `make` returns, so sharing one instance
    /// across many attachments is safe; only the attachment's own `bounds`
    /// differs, and that lives on the attachment.
    ///
    /// Unbounded, because the key space is: ten symbols, the handful of prose
    /// sizes ORE renders at, and two appearances. It cannot grow with the
    /// number of documents read.
    fileprivate final class LinkSymbolStore: @unchecked Sendable {
        static let shared = LinkSymbolStore()

        private let lock = NSLock()
        /// Optional values, so a symbol that does not resolve is remembered as
        /// missing instead of being retried on every link.
        private var images: [LinkSymbolKey: NSImage?] = [:]

        /// The lock is held across the build, not just the lookup. Two renders
        /// missing the same symbol at once would otherwise both be inside
        /// AppKit's symbol catalogue at the same time, which is the one thing
        /// this cache exists to prevent — and one of the two images would be
        /// thrown away anyway.
        func image(for key: LinkSymbolKey) -> NSImage? {
            lock.lock()
            defer { lock.unlock() }
            if let hit = images[key] { return hit }
            let made = Self.make(key)
            images[key] = made
            return made
        }

        private static func make(_ key: LinkSymbolKey) -> NSImage? {
            guard let icon = NSImage(systemSymbolName: key.name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: key.basePointSize * 0.92, weight: .medium))?
                .withSymbolConfiguration(.init(paletteColors: [.oreInlineChipText]))
            else { return nil }
            // Not a template: the palette colour above is the whole point, and
            // a template image would be re-tinted by the text view instead.
            icon.isTemplate = false
            return icon
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
                result.addAttribute(.font, value: MarkdownRenderer.applying(trait, to: font), range: range)
            }
            return result
        }
    }

    // MARK: - Fonts

    /// Adds a bold or italic trait to `font`, off the main actor as safely as
    /// on it.
    ///
    /// This used to be `NSFontManager.shared.convert(_:toHaveTrait:)`.
    /// `NSFontManager` is AppKit's shared, app-level object — it backs the font
    /// panel and its state is main-thread-only — so a single call from a
    /// background render is a real data race, and it is the one thing that kept
    /// the document preview's markdown pass on the main actor.
    ///
    /// CoreText is the layer underneath it, it is thread-safe, and
    /// `CTFontCreateCopyWithSymbolicTraits` is the same operation: copy this
    /// exact font with one more trait bit set, keeping everything else —
    /// including the numeric weight, which re-matching a descriptor by symbolic
    /// traits alone silently drops (monospaced Medium plus italic lands on
    /// RegularItalic that way). Verified face-for-face against the font manager
    /// over a thousand combinations — system, monospaced and third-party
    /// families, every weight, both traits, nested and repeated — in
    /// `MarkdownFontTraitTests`.
    ///
    /// Nil means the family has no such face, which is when the font manager
    /// hands the original back too.
    static func applying(_ trait: NSFontTraitMask, to font: NSFont) -> NSFont {
        let bit: CTFontSymbolicTraits = trait == .italicFontMask ? .traitItalic : .traitBold
        guard let copy = CTFontCreateCopyWithSymbolicTraits(font as CTFont, font.pointSize, nil, bit, bit)
        else { return font }
        return copy as NSFont
    }
}
