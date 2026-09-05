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
        let container = NSTextContainer(containerSize: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

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

        let scrollView = NSScrollView()
        // NSRulerView uses a drawing coordinate space tied to the document's
        // scroll position. Give the representable a hard clipping boundary so
        // its gutter cannot paint through the file header and tab strip.
        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = true
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        // Overlay even when the system pref says legacy — an opaque scroller
        // track is the one rectangle the glass window can't absorb.
        scrollView.scrollerStyle = .overlay
        // One knob family window-wide — see TranscriptView.
        scrollView.scrollerKnobStyle = .light
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder

        let ruler = SourceLineNumberRuler(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.ruler = ruler
        context.coordinator.apply(text, path: path, preservingSelection: false)
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            coordinator?.resizeDocument()
            coordinator?.resetScrollOrigin()
        }
        // Closing ⌘P returns first responder after the sheet animation, and
        // AppKit may then reveal the insertion point by nudging the horizontal
        // origin by one text inset. Reassert the true document origin once that
        // handoff is complete; without it the first few source characters hide
        // under the gutter on every newly opened file.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            [weak coordinator = context.coordinator] in
            coordinator?.resetScrollOrigin()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text || context.coordinator.path != path {
            context.coordinator.apply(text, path: path, preservingSelection: true)
        }
        context.coordinator.resizeDocument()
        context.coordinator.revealFocus(focus)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourceCodeEditor
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        fileprivate weak var ruler: SourceLineNumberRuler?
        var path = ""
        private var isApplying = false
        private var lastFocusToken: Int?

        init(parent: SourceCodeEditor) { self.parent = parent }

        /// Scrolls to and flashes a 1-based line, once per distinct focus token.
        func revealFocus(_ focus: AppModel.FileFocus?) {
            guard let focus, focus.token != lastFocusToken, let textView else { return }
            lastFocusToken = focus.token
            let ns = textView.string as NSString
            guard ns.length > 0, focus.line > 0 else { return }
            var index = 0
            var current = 1
            while current < focus.line {
                let next = NSMaxRange(ns.lineRange(for: NSRange(location: index, length: 0)))
                if next <= index || next >= ns.length { index = min(next, ns.length); break }
                index = next
                current += 1
            }
            let lineRange = ns.lineRange(for: NSRange(location: min(index, ns.length), length: 0))
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
            parent.text = textView.string
            apply(textView.string, path: parent.path, preservingSelection: true)
        }

        func apply(_ value: String, path: String, preservingSelection: Bool) {
            guard let textView else { return }
            isApplying = true
            defer { isApplying = false }

            let openedDifferentFile = self.path != path
            let selection = textView.selectedRange()
            let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            let highlighted = NSMutableAttributedString(attributedString:
                SyntaxHighlighter.shared.highlight(
                    value,
                    language: SyntaxHighlighter.language(forPath: path),
                    font: font
                )
            )
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2.5
            paragraph.tabStops = []
            paragraph.defaultTabInterval = 32
            highlighted.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: NSRange(location: 0, length: highlighted.length)
            )

            textView.textStorage?.setAttributedString(highlighted)
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
            ruler?.rebuildLineStarts(value)
            ruler?.needsDisplay = true
            resizeDocument()
            if openedDifferentFile { resetScrollOrigin() }
        }

        /// NSTextView only scrolls when its document view is larger than the
        /// clip view. Explicit sizing is important here because this editor
        /// supports both axes and therefore cannot use widthTracksTextView.
        func resizeDocument() {
            guard let textView, let scrollView,
                  let layout = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            let viewport = scrollView.contentSize
            textView.frame.size = NSSize(
                width: max(viewport.width, ceil(used.width + textView.textContainerInset.width * 2 + 2)),
                height: max(viewport.height, ceil(used.height + textView.textContainerInset.height * 2 + 2))
            )
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
    private var lineStarts: [Int] = [0]

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

    func rebuildLineStarts(_ text: String) {
        lineStarts = [0]
        let nsText = text as NSString
        var index = 0
        while index < nsText.length {
            let range = nsText.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(range)
            if index < nsText.length { lineStarts.append(index) }
        }
        ruleThickness = max(42, CGFloat(String(max(1, lineStarts.count)).count) * 8 + 18)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layout = textView.layoutManager,
              let container = textView.textContainer,
              !lineStarts.isEmpty
        else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor.separatorColor.withAlphaComponent(0.22).setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let visible = scrollView?.contentView.bounds ?? textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let firstLine = max(0, lineStarts.partitioningIndex { $0 <= characters.location } - 1)
        let lastCharacter = NSMaxRange(characters)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        if textView.string.isEmpty {
            ("1" as NSString).draw(at: NSPoint(x: bounds.width - 17, y: 13), withAttributes: attributes)
            return
        }

        for index in firstLine..<lineStarts.count {
            let character = lineStarts[index]
            if character > lastCharacter { break }
            let glyph = layout.glyphIndexForCharacter(at: min(character, textView.string.utf16.count - 1))
            let lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = lineRect.minY + textView.textContainerOrigin.y - visible.minY
            let label = "\(index + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: bounds.width - size.width - 9, y: y + 1),
                withAttributes: attributes
            )
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
