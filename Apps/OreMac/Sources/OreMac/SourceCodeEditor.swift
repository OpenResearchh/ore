import AppKit
import SwiftUI

/// A real source editor surface for centre tabs. It keeps editing native to
/// NSTextView (selection, undo, find, keyboard navigation) while applying the
/// same language-aware highlighting used by diffs and Markdown code blocks.
struct SourceCodeEditor: NSViewRepresentable {
    @Binding var text: String
    let path: String
    /// A line to reveal and flash when the file is opened from a `file.py:711`
    /// reference. The token distinguishes repeat requests for the same line.
    var focus: AppModel.FileFocus?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        // Lay out only what is on screen after an edit or a recolour, rather
        // than everything from the change to the end of the file. The usual
        // price of non-contiguous layout is estimated heights that correct
        // themselves as real layout lands, moving content under the ruler. It
        // barely applies here: every line is one monospaced fragment of the
        // same height, `apply` still lays the whole file out when it arrives,
        // and the ruler redraws whenever the document's frame changes.
        layout.allowsNonContiguousLayout = true
        let container = NSTextContainer(containerSize: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        storage.delegate = context.coordinator

        let textView = SourceTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 0),
            textContainer: container
        )
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindBar = true
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 14, height: 12)
        // Let the enclosing scroll view own the semantic background. Resolving
        // textBackgroundColor with an alpha before this view joins a window can
        // freeze its Aqua (white) value, leaving white syntax text on white
        // after the app adopts Dark Aqua.
        textView.drawsBackground = false
        textView.insertionPointColor = NSColor.controlAccentColor

        // Overlay scrollers, the light knob and autohide come from
        // OreOverlayScrollView, which also keeps overlay style when the system
        // scroller preference changes underneath a running app.
        let scrollView = OreOverlayScrollView()
        // NSRulerView uses a drawing coordinate space tied to the document's
        // scroll position. Give the representable a hard clipping boundary so
        // its gutter cannot paint through the file header and tab strip.
        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = true
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder

        let ruler = SourceLineNumberRuler(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        let coordinator = context.coordinator
        coordinator.textView = textView
        coordinator.scrollView = scrollView
        coordinator.ruler = ruler
        coordinator.observe(scrollView: scrollView, textView: textView)
        coordinator.apply(text, path: path, preservingSelection: false)
        DispatchQueue.main.async { [weak coordinator] in
            coordinator?.resizeDocument()
            coordinator?.resetScrollOrigin()
        }
        // Closing ⌘P returns first responder after the sheet animation, and
        // AppKit may then reveal the insertion point by nudging the horizontal
        // origin by one text inset. Reassert the true document origin once that
        // handoff is complete; without it the first few source characters hide
        // under the gutter on every newly opened file.
        coordinator.scheduleOriginReassertion()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // Compare against what the coordinator last applied or read back, not
        // `textView.string`: that bridged a copy of the whole file on every
        // SwiftUI pass. On the typing path `text` is the very string
        // `textDidChange` recorded, and identical String storage compares
        // without walking it.
        if coordinator.path != path || text != coordinator.lastAppliedText {
            coordinator.apply(text, path: path, preservingSelection: true)
        } else {
            coordinator.resizeDocumentIfViewportChanged()
        }
        coordinator.revealFocus(focus)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        var parent: SourceCodeEditor
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        fileprivate weak var ruler: SourceLineNumberRuler?
        var path = ""
        /// The text last pushed into the view or read back out of it, so an
        /// update can tell a real change from its own echo without touching
        /// the text storage.
        private(set) var lastAppliedText = ""
        private var isApplying = false
        private var lastFocusToken: Int?
        private var didRevealFocus = false
        private var lastViewportSize: NSSize?
        private var originReassertion: Task<Void, Never>?

        /// The lexer's canonical name for the open file, refreshed by each
        /// whole-file pass in case an edit changed a shebang.
        private var language: String?
        private let fonts: SourceHighlightFonts
        /// Bumped by every character edit and every full apply. A background
        /// whole-file pass only lands if nothing moved while it ran.
        private var highlightGeneration = 0
        private var idleHighlight: Task<Void, Never>?

        init(parent: SourceCodeEditor) {
            self.parent = parent
            fonts = SourceHighlightFonts(base: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular))
        }

        func observe(scrollView: NSScrollView, textView: NSTextView) {
            // A reader who starts scrolling has taken over the origin; the
            // delayed reassertion must not snap them back to the top.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(liveScrollWillStart),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
            // Window and pane resizes change the viewport without a SwiftUI
            // update, and the document must keep filling it.
            scrollView.contentView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(viewportFrameDidChange),
                name: NSView.frameDidChangeNotification,
                object: scrollView.contentView
            )
            // Non-contiguous layout can correct the document height as it lays
            // out lines it had only estimated. Redraw the gutter when that
            // happens so its labels never sit beside the wrong line.
            textView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(documentFrameDidChange),
                name: NSView.frameDidChangeNotification,
                object: textView
            )
        }

        @objc private func liveScrollWillStart() {
            originReassertion?.cancel()
            originReassertion = nil
        }

        @objc private func viewportFrameDidChange() {
            resizeDocumentIfViewportChanged()
        }

        @objc private func documentFrameDidChange() {
            ruler?.needsDisplay = true
        }

        /// Scrolls to and flashes a 1-based line, once per distinct focus token.
        func revealFocus(_ focus: AppModel.FileFocus?) {
            guard let focus, focus.token != lastFocusToken, let textView,
                  let storage = textView.textStorage, let ruler else { return }
            lastFocusToken = focus.token
            guard storage.length > 0, focus.line > 0 else { return }
            didRevealFocus = true
            originReassertion?.cancel()
            // Past the last line lands on the last line.
            let start = ruler.lineStarts.start(ofLine: focus.line - 1)
            let lineRange = storage.mutableString.lineRange(for: NSRange(location: start, length: 0))
            // Defer so the freshly-applied text has laid out before we scroll.
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
                textView.scrollRangeToVisible(lineRange)
                textView.showFindIndicator(for: lineRange)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let textView else { return }
            // The storage delegate has already recoloured the edited lines and
            // spliced the line starts; all that is left is the binding and the
            // idle whole-file pass.
            let value = textView.string
            lastAppliedText = value
            parent.text = value
            scheduleIdleHighlight()
        }

        // MARK: - Incremental highlighting

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            // Attribute-only edits are this coordinator's own recolouring, and
            // a full apply rebuilds everything itself.
            guard !isApplying, editedMask.contains(.editedCharacters) else { return }
            highlightGeneration &+= 1
            let text = textStorage.mutableString
            // Within one editing session the storage reports the union of its
            // edits, which is still one old range replaced by one new one.
            ruler?.updateLineStarts(
                replacing: NSRange(location: editedRange.location, length: editedRange.length - delta),
                withLength: editedRange.length,
                in: text
            )
            ruler?.needsDisplay = true
            rehighlightLines(around: editedRange, in: textStorage)
        }

        /// Re-lexes just the lines an edit touched, as attribute changes inside
        /// the storage's own editing pass, so a keystroke never recolours or
        /// re-lays out the rest of the file.
        ///
        /// The lexer only sees those lines, so it can't know about a comment or
        /// string opened further up. When the line above ends inside a token,
        /// the edit is left in the colour it was typed with (NSTextView takes
        /// typing attributes from the surrounding text) and the idle whole-file
        /// pass settles it.
        private func rehighlightLines(around editedRange: NSRange, in storage: NSTextStorage) {
            let text = storage.mutableString
            guard text.length > 0 else { return }
            let lines = text.lineRange(for: NSRange(
                location: min(editedRange.location, text.length),
                length: min(editedRange.length, text.length - min(editedRange.location, text.length))
            ))
            guard lines.length > 0, lines.length <= SourceHighlightPass.lineEditLimit else { return }
            if lines.location > 0,
               SourceHighlightPass.isColoured(storage, at: lines.location - 1) { return }
            let tokens = SyntaxLexer.tokens(for: text.substring(with: lines), language: language)
            // tree-sitter colours the whole file for these languages and the
            // lexer's opinion of the rest of the line would differ from it, so
            // only the tokens the edit touched change until the idle pass.
            let touching = SourceHighlightPass.usesParser(language) ? editedRange : nil
            SourceHighlightPass.paint(
                tokens, offset: lines.location, into: storage, over: lines,
                fonts: fonts, onlyTouching: touching
            )
        }

        /// Recolours the whole file off the main thread once typing pauses.
        /// This is what corrects constructs that span lines, which the per-line
        /// pass above can't see: a `/*` typed above existing code, a closed
        /// string, a pasted block.
        private func scheduleIdleHighlight() {
            idleHighlight?.cancel()
            idleHighlight = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                await self?.runIdleHighlight()
            }
        }

        private func runIdleHighlight() async {
            guard let storage = textView?.textStorage else { return }
            let generation = highlightGeneration
            let text = storage.string
            let path = self.path
            let fonts = self.fonts
            let result = await Task.detached(priority: .userInitiated) {
                SourceHighlightPass.render(text, path: path, fonts: fonts)
            }.value
            // Anything typed, pasted or reloaded meanwhile makes this stale;
            // that edit has already scheduled its own pass.
            guard !Task.isCancelled else { return }
            guard generation == highlightGeneration else { return }
            guard path == self.path else { return }
            guard let storage = textView?.textStorage else { return }
            guard storage.length == result.attributed.length else { return }
            language = result.language
            SourceHighlightPass.applyChanges(from: result.attributed, to: storage)
        }

        // MARK: - Full apply

        func apply(_ value: String, path: String, preservingSelection: Bool) {
            guard let textView, let storage = textView.textStorage else { return }
            isApplying = true
            defer { isApplying = false }
            idleHighlight?.cancel()
            highlightGeneration &+= 1

            let openedDifferentFile = self.path != path
            let selection = textView.selectedRange()
            let font = fonts.base
            let rawLanguage = SyntaxHighlighter.language(forPath: path, contents: value)
            language = SyntaxHighlighter.canonicalName(rawLanguage)
            // Uncached: every reload is a new whole-file string, so caching
            // only filled the shared cache with copies nobody would ask for again.
            let highlighted = NSMutableAttributedString(attributedString:
                SyntaxHighlighter.shared.highlight(
                    value,
                    language: rawLanguage,
                    font: font,
                    cache: false
                )
            )
            let paragraph = SourceHighlightPass.paragraphStyle
            highlighted.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: NSRange(location: 0, length: highlighted.length)
            )

            storage.setAttributedString(highlighted)
            lastAppliedText = value
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            if openedDifferentFile || !preservingSelection {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            } else {
                textView.setSelectedRange(NSRange(
                    location: min(selection.location, highlighted.length),
                    length: min(selection.length, max(0, highlighted.length - min(selection.location, highlighted.length)))
                ))
            }
            self.path = path
            ruler?.rebuildLineStarts(storage.mutableString)
            ruler?.needsDisplay = true
            // A replaced file is laid out in full once, so its size (and the
            // reader's scroll position within it) is right immediately. Edits
            // after that rely on NSTextView resizing itself between minSize
            // and maxSize as the edited lines lay out.
            resizeDocument(ensuringLayout: true)
            if openedDifferentFile { resetScrollOrigin() }
        }

        /// NSTextView only scrolls when its document view is larger than the
        /// clip view. Explicit sizing is important here because this editor
        /// supports both axes and therefore cannot use widthTracksTextView.
        /// `minSize` tracks the viewport so the view's own resizing after an
        /// edit never shrinks it below the visible area.
        func resizeDocument(ensuringLayout: Bool = false) {
            guard let textView, let scrollView,
                  let layout = textView.layoutManager,
                  let container = textView.textContainer else { return }
            if ensuringLayout { layout.ensureLayout(for: container) }
            let used = layout.usedRect(for: container)
            let viewport = scrollView.contentSize
            lastViewportSize = viewport
            textView.minSize = viewport
            textView.frame.size = NSSize(
                width: max(viewport.width, ceil(used.width + textView.textContainerInset.width * 2 + 2)),
                height: max(viewport.height, ceil(used.height + textView.textContainerInset.height * 2 + 2))
            )
        }

        /// The document only needs re-sizing from outside when the viewport
        /// moved; SwiftUI passes that change nothing else are no-ops.
        func resizeDocumentIfViewportChanged() {
            guard let scrollView, scrollView.contentSize != lastViewportSize else { return }
            resizeDocument()
        }

        func resetScrollOrigin() {
            guard let scrollView else { return }
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            // Set the scroller's semantic value too. Updating the clip view
            // alone can still leave AppKit's ruler-adjusted horizontal value
            // slightly advanced after a sheet returns first responder.
            if let scroller = scrollView.horizontalScroller {
                scroller.setAccessibilityValue(0.0)
            }
        }

        func scheduleOriginReassertion() {
            originReassertion?.cancel()
            originReassertion = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.reassertOriginIfUntouched()
            }
        }

        /// Undoes only the one-inset nudge the sheet handoff causes. A line
        /// jump from `revealFocus`, or a reader who has already scrolled, is
        /// left where it is.
        private func reassertOriginIfUntouched() {
            originReassertion = nil
            guard !didRevealFocus, let scrollView, let textView else { return }
            let origin = scrollView.contentView.bounds.origin
            guard abs(origin.y) < 0.5,
                  abs(origin.x) <= textView.textContainerInset.width + 0.5 else { return }
            resetScrollOrigin()
        }
    }
}

/// The bold and italic variants a Markdown heading or emphasis token needs,
/// resolved on the main actor so a background pass never touches
/// NSFontManager. Fonts are immutable, so sharing them across threads is safe.
struct SourceHighlightFonts: @unchecked Sendable {
    let base: NSFont
    let bold: NSFont
    let italic: NSFont

    @MainActor
    init(base: NSFont) {
        self.base = base
        bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }
}

/// A finished whole-file colouring. The attributed string is built and then
/// only read, so handing it back to the main actor is safe.
struct SourceHighlightResult: @unchecked Sendable {
    let language: String?
    let attributed: NSAttributedString
}

/// The editor's incremental colouring, on top of `SyntaxHighlighter`'s
/// whole-snippet API.
enum SourceHighlightPass {
    /// Lines longer than this in one edit (a huge paste, a Replace All) skip
    /// the synchronous per-line pass and wait for the idle pass instead.
    static let lineEditLimit = 64_000

    nonisolated(unsafe) static let paragraphStyle: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2.5
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 32
        return paragraph
    }()

    /// Languages `SyntaxHighlighter` colours with a bundled tree-sitter
    /// grammar rather than the lexer. Keep in step with its `grammar(named:)`.
    static func usesParser(_ language: String?) -> Bool {
        language == "swift" || language == "json"
    }

    /// Whether the character at `index` carries a token colour. For the
    /// terminator of the line above an edit, that means a comment or string
    /// is still open across it.
    @MainActor
    static func isColoured(_ storage: NSTextStorage, at index: Int) -> Bool {
        guard let color = storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
        else { return false }
        return color != NSColor.labelColor
    }

    /// Resets `range` to the base style, then paints lexer tokens whose offsets
    /// are relative to `offset`. With `onlyTouching`, only that range is reset
    /// and only tokens meeting it are painted. The same rules as
    /// `SyntaxPainter`: later tokens win, headings and emphasis change font.
    static func paint(
        _ tokens: [SyntaxToken],
        offset: Int,
        into target: NSMutableAttributedString,
        over range: NSRange,
        fonts: SourceHighlightFonts,
        onlyTouching focus: NSRange? = nil
    ) {
        let limit = NSMaxRange(range)
        let reset = focus.map { NSIntersectionRange($0, range) } ?? range
        if reset.length > 0 {
            target.addAttributes([.font: fonts.base, .foregroundColor: NSColor.labelColor], range: reset)
        }
        let colors = SyntaxTheme.tokenColors
        for token in tokens {
            let start = max(range.location, token.start + offset)
            let end = min(limit, token.end + offset)
            guard start < end else { continue }
            if let focus, start > NSMaxRange(focus) || end < focus.location { continue }
            let tokenRange = NSRange(location: start, length: end - start)
            if let color = colors[Int(token.kind.rawValue)] {
                target.addAttribute(.foregroundColor, value: color, range: tokenRange)
            }
            switch token.kind {
            case .heading, .bold:
                target.addAttribute(.font, value: fonts.bold, range: tokenRange)
            case .italic:
                target.addAttribute(.font, value: fonts.italic, range: tokenRange)
            default:
                break
            }
        }
    }

    /// The whole file's colours, computed off the main thread. tree-sitter
    /// languages go through `SyntaxHighlighter` so they match what `apply`
    /// shows; everything else is lexed and painted here with fonts resolved
    /// in advance.
    static func render(_ text: String, path: String, fonts: SourceHighlightFonts) -> SourceHighlightResult {
        let rawLanguage = SyntaxHighlighter.language(forPath: path, contents: text)
        let language = SyntaxHighlighter.canonicalName(rawLanguage)
        if usesParser(language) {
            let highlighted = SyntaxHighlighter.shared.highlight(
                text, language: rawLanguage, font: fonts.base, cache: false
            )
            return SourceHighlightResult(language: language, attributed: highlighted)
        }
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: fonts.base, .foregroundColor: NSColor.labelColor]
        )
        paint(
            SyntaxLexer.tokens(for: text, language: language),
            offset: 0,
            into: result,
            over: NSRange(location: 0, length: result.length),
            fonts: fonts
        )
        return SourceHighlightResult(language: language, attributed: result)
    }

    /// Copies `target`'s colours and font weights onto `storage`, touching only
    /// runs that differ. An idle pass usually changes nothing, and when a block
    /// comment opens it changes only the lines it swallowed, so layout is
    /// invalidated there and nowhere else.
    @MainActor
    static func applyChanges(from target: NSAttributedString, to storage: NSTextStorage) {
        guard target.length == storage.length, target.length > 0 else { return }
        let full = NSRange(location: 0, length: target.length)
        var edits: [(key: NSAttributedString.Key, value: Any, range: NSRange)] = []
        for key in [NSAttributedString.Key.foregroundColor, .font] {
            target.enumerateAttribute(key, in: full) { value, run, _ in
                guard let value = value as? NSObject else { return }
                var location = run.location
                while location < NSMaxRange(run) {
                    var effective = NSRange()
                    let current = storage.attribute(key, at: location, effectiveRange: &effective)
                    let end = max(location + 1, min(NSMaxRange(effective), NSMaxRange(run)))
                    if !matches(current, value, for: key) {
                        edits.append((key, value, NSRange(location: location, length: end - location)))
                    }
                    location = end
                }
            }
        }
        guard !edits.isEmpty else { return }
        // Separate edits keep layout invalidation tight; past a handful, one
        // editing session beats paying for a processing pass per run.
        let batched = edits.count > 32
        if batched { storage.beginEditing() }
        for edit in edits {
            storage.addAttribute(edit.key, value: edit.value, range: edit.range)
        }
        if batched { storage.endEditing() }
    }

    /// Fonts compare by weight and slant only. The storage substitutes fallback
    /// fonts for emoji and other glyphs the monospaced face lacks, and treating
    /// those as different would rewrite them on every pass.
    private static func matches(_ current: Any?, _ value: NSObject, for key: NSAttributedString.Key) -> Bool {
        guard key == .font else { return (current as? NSObject)?.isEqual(value) == true }
        guard let current = current as? NSFont, let value = value as? NSFont else { return false }
        let styles: NSFontDescriptor.SymbolicTraits = [.bold, .italic]
        return current.fontDescriptor.symbolicTraits.intersection(styles)
            == value.fontDescriptor.symbolicTraits.intersection(styles)
    }
}

/// Where each line of the editor's text starts, as UTF-16 offsets. The ruler
/// binary-searches it every frame and `revealFocus` jumps through it, so an
/// edit splices in the lines it touched instead of rescanning the file.
///
/// Line breaks are whatever `NSString.lineRange(for:)` says they are, so
/// CRLF counts once. A trailing terminator does not start an extra line.
struct SourceLineStarts: Equatable {
    private(set) var starts: [Int] = [0]

    init(text: NSString) {
        var index = 0
        while index < text.length {
            index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
            if index < text.length { starts.append(index) }
        }
    }

    var count: Int { starts.count }

    /// The 0-based line containing a UTF-16 offset.
    func line(containing location: Int) -> Int {
        max(0, starts.partitioningIndex { $0 <= location } - 1)
    }

    /// The start of a 0-based line, clamped to the last line.
    func start(ofLine line: Int) -> Int {
        starts[min(max(0, line), starts.count - 1)]
    }

    /// Updates the index after `oldRange` of the previous text was replaced by
    /// `newLength` characters; `text` is the text after the edit.
    mutating func replace(_ oldRange: NSRange, withLength newLength: Int, in text: NSString) {
        let delta = newLength - oldRange.length
        let oldEnd = NSMaxRange(oldRange)
        let newEnd = oldRange.location + newLength
        // Rescan from the line before the edit: a CR ending that line and an
        // LF inserted right after it become one terminator, which removes the
        // start between them.
        let first = max(0, line(containing: oldRange.location) - 1)
        // Starts past the edit keep their terminator, since it lies outside
        // the replaced characters; they only shift.
        let tail = starts.partitioningIndex { $0 <= oldEnd }
        var rebuilt = Array(starts[...first])
        var index = starts[first]
        while index < text.length {
            let next = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
            guard next < text.length else { break }
            rebuilt.append(next)
            index = next
            if next > newEnd { break }
        }
        let last = rebuilt[rebuilt.count - 1]
        for start in starts[tail...] where start + delta > last {
            rebuilt.append(start + delta)
        }
        starts = rebuilt
    }
}

/// AppKit asks a newly focused text view to reveal its zero-length selection
/// after a file-palette sheet closes. With a vertical ruler attached, the
/// default implementation can mistake the ruler width for hidden document
/// content and move the horizontal origin by one text inset. Keep the true
/// origin when the insertion point is at the start while preserving ordinary
/// horizontal scrolling everywhere else.
@MainActor
private final class SourceTextView: NSTextView {
    override func scrollRangeToVisible(_ range: NSRange) {
        super.scrollRangeToVisible(range)
        guard range.location == 0, range.length == 0,
              let scrollView = enclosingScrollView else { return }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// A quiet line-number gutter. The ruler only draws visible lines and caches
/// their starts, so large generated files remain as responsive as plain text.
@MainActor
fileprivate final class SourceLineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    private(set) var lineStarts = SourceLineStarts(text: "")

    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: labelFont,
        .foregroundColor: NSColor.tertiaryLabelColor,
    ]
    /// Every digit in a monospaced-digit face is this wide, so right-aligning
    /// a label needs its digit count, not a text measurement per line per frame.
    private static let digitWidth = ("0" as NSString).size(withAttributes: labelAttributes).width

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        wantsLayer = true
        layer?.masksToBounds = true
        clientView = textView
        ruleThickness = 48
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not supported") }

    func rebuildLineStarts(_ text: NSString) {
        lineStarts = SourceLineStarts(text: text)
        updateThickness()
    }

    func updateLineStarts(replacing oldRange: NSRange, withLength newLength: Int, in text: NSString) {
        lineStarts.replace(oldRange, withLength: newLength, in: text)
        updateThickness()
    }

    /// Setting the thickness re-tiles the scroll view, so only when the widest
    /// label gains or loses a digit.
    private func updateThickness() {
        let thickness = max(42, CGFloat(Self.digitCount(max(1, lineStarts.count))) * 8 + 18)
        if thickness != ruleThickness { ruleThickness = thickness }
    }

    private static func digitCount(_ value: Int) -> Int {
        var count = 1
        var rest = value
        while rest >= 10 { rest /= 10; count += 1 }
        return count
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layout = textView.layoutManager,
              let container = textView.textContainer
        else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor.separatorColor.withAlphaComponent(0.22).setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let attributes = Self.labelAttributes
        // The storage's length, not `textView.string`: reading the string
        // bridges a copy of the whole file, and this ran once per visible line
        // on every scroll frame.
        let length = textView.textStorage?.length ?? 0
        if length == 0 {
            ("1" as NSString).draw(at: NSPoint(x: bounds.width - 17, y: 13), withAttributes: attributes)
            return
        }

        let visible = scrollView?.contentView.bounds ?? textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // The container is unbounded in width, so nothing soft-wraps and every
        // line is exactly one fragment: the fragment after the first visible
        // one is the next line, and no per-line character lookup is needed.
        // That matters with non-contiguous layout on, because
        // `glyphIndexForCharacter` is documented to generate glyphs for
        // everything up to the index it is asked about — asking once per
        // visible line would put the whole file back on the scroll path this
        // ruler exists to stay off.
        var line = lineStarts.line(containing: characters.location)
        let lineCount = lineStarts.count
        // Fragment rects are in container space; the ruler draws in the clip
        // view's, so the two differ by the text inset and the scroll origin.
        let originY = textView.textContainerOrigin.y - visible.minY
        let rightEdge = bounds.width - 9
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, stop in
            // The trailing extra line fragment has no line start behind it.
            guard line < lineCount else {
                stop.pointee = true
                return
            }
            let number = line + 1
            let width = CGFloat(Self.digitCount(number)) * Self.digitWidth
            ("\(number)" as NSString).draw(
                at: NSPoint(x: rightEdge - width, y: rect.minY + originY + 1),
                withAttributes: attributes
            )
            line += 1
        }
    }
}

private extension Array where Element == Int {
    func partitioningIndex(where predicate: (Int) -> Bool) -> Int {
        var lower = startIndex
        var upper = endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if predicate(self[middle]) { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
}
