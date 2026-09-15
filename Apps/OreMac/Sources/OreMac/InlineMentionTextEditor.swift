import AppKit
import OreProtocol
import SwiftUI

/// The prompt editor needs one capability SwiftUI's `TextEditor` does not
/// expose on macOS: intercepting Tab while a completion menu is open. It also
/// lets workspace references read as inline tokens without moving them to a
/// separate attachment shelf above the prompt.
/// What the composer wants done with a paste it inspected.
enum PasteOutcome {
    /// Not ours — let the text view paste normally.
    case ignored
    /// Handled entirely (e.g. attached a file); insert nothing.
    case consumed
    /// Handled, and this token should be typed in at the caret (e.g. an inline
    /// chip pointing at a pasted image).
    case insert(String)
}

/// Attachments that belong with composer text, so ⌘C / ⌘V across tabs keeps
/// `@` chips and the shelf instead of leaving bare filenames.
enum ComposerPasteboard {
    static let type = NSPasteboard.PasteboardType("app.ore.composer-draft")

    struct Payload: Codable, Equatable {
        var attachments: [Attachment]
        var inlinePaths: [String]
    }

    static func write(_ payload: Payload, to pasteboard: NSPasteboard) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        pasteboard.setData(data, forType: type)
    }

    static func read(from pasteboard: NSPasteboard) -> Payload? {
        guard let data = pasteboard.data(forType: type) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    /// Which pasted attachments a draft still mentions by token.
    ///
    /// Reconstructs the inline set from the text alone, for when the view state
    /// that tracked it is gone: switching chat tabs tears the composer down
    /// while the attachments live on for the chat, and without rebuilding this
    /// every inline pill came back as a shelf chip. Pasted display names are
    /// draft-unique, so a token maps to exactly one attachment; shelf items
    /// carry no token and correctly stay out.
    static func inlinePaths(inDraft text: String, attachments: [Attachment]) -> Set<String> {
        Set(
            attachments.lazy
                .filter { $0.relativePath.hasPrefix(".context/attachments/") }
                .filter { text.contains("@\($0.displayName)") }
                .map(\.relativePath)
        )
    }

    static func payload(
        forCopiedText text: String,
        fullDraft: String,
        attachments: [Attachment],
        inlinePaths: Set<String>
    ) -> Payload {
        let mentioned = attachments.filter { text.contains("@\($0.displayName)") }
        let shelf = attachments.filter {
            $0.relativePath.hasPrefix(".context/attachments/")
                && !inlinePaths.contains($0.relativePath)
        }
        let copyingWholeDraft = text.trimmingCharacters(in: .whitespacesAndNewlines)
            == fullDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var items = mentioned
        if copyingWholeDraft {
            for item in shelf where !items.contains(item) { items.append(item) }
        }
        let inlines = items
            .map(\.relativePath)
            .filter { inlinePaths.contains($0) }
        return Payload(attachments: items, inlinePaths: inlines)
    }
}

extension NSAttributedString.Key {
    /// File URL of an attachment that should pop up when the pointer rests on
    /// this range — pasted images and long text, in both the composer and the
    /// transcript.
    static let oreAttachmentPreview = NSAttributedString.Key("ore.attachmentPreview")
}

/// Shared hover popover for image and text attachments. The composer and the
/// transcript both show this instead of inlining a tiny thumbnail or a wall of
/// pasted prose next to the chip.
@MainActor
final class AttachmentPreviewController {
    private var popover: NSPopover?
    private var shownURL: URL?

    func show(url: URL, from view: NSView, anchor: NSRect) {
        if shownURL == url, popover?.isShown == true { return }
        dismiss()
        let content: NSView
        if Self.isImageURL(url), let image = NSImage(contentsOf: url) {
            content = imagePreview(image)
        } else if let text = try? String(contentsOf: url, encoding: .utf8) {
            content = textPreview(text)
        } else if let image = NSImage(contentsOf: url) {
            content = imagePreview(image)
        } else {
            return
        }

        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = false
        popover.contentSize = content.frame.size
        popover.contentViewController = controller
        popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
        self.popover = popover
        shownURL = url
    }

    func dismiss() {
        popover?.performClose(nil)
        popover = nil
        shownURL = nil
    }

    private func imagePreview(_ image: NSImage) -> NSView {
        let cap = NSSize(width: 320, height: 320)
        let aspect = image.size.width / max(1, image.size.height)
        var width = min(cap.width, max(1, image.size.width))
        var height = width / max(0.01, aspect)
        if height > cap.height { height = cap.height; width = height * aspect }

        let padding: CGFloat = 6
        let container = NSView(frame: NSRect(
            x: 0, y: 0, width: width + padding * 2, height: height + padding * 2
        ))
        let imageView = NSImageView(frame: NSRect(x: padding, y: padding, width: width, height: height))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(imageView)
        return container
    }

    private func textPreview(_ text: String) -> NSView {
        let display = text.count > 8_000 ? String(text.prefix(8_000)) + "\n…" : text
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        let cap = NSSize(width: 420, height: 260)
        let padding: CGFloat = 8
        let innerWidth = cap.width - padding * 2
        let measured = (display as NSString).boundingRect(
            with: NSSize(width: innerWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let width = min(cap.width, max(240, ceil(measured.width) + padding * 2 + 12))
        let height = min(cap.height, max(72, ceil(measured.height) + padding * 2))

        let textView = NSTextView(frame: NSRect(
            x: 0, y: 0,
            width: width,
            height: max(height, ceil(measured.height) + padding * 2)
        ))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = .labelColor
        textView.string = display
        textView.textContainerInset = NSSize(width: padding, height: padding)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        // Overlay, light knob and autohide come with the class.
        let scroll = OreOverlayScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = ceil(measured.height) + padding * 2 > cap.height
        scroll.documentView = textView
        return scroll
    }

    private static func isImageURL(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]
            .contains(url.pathExtension.lowercased())
    }
}

/// Hit-testing for attachment hover previews.
///
/// `NSLayoutManager.glyphIndex(for:in:)` returns the *nearest* glyph, so a
/// pointer resting in the composer's padding, on another word of the same
/// line, or in the empty trailing width of a process row still mapped onto
/// a chip. Previews must only appear when the pointer is actually over the
/// chip's used glyphs.
enum AttachmentHoverHitTesting {
    static func characterIndex(at point: NSPoint, in textView: NSTextView) -> Int? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let textStorage = textView.textStorage,
              textStorage.length > 0 else { return nil }
        let containerPoint = containerPoint(at: point, in: textView)
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        let used = layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyphIndex, effectiveRange: nil
        )
        guard used.contains(containerPoint) else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard character < textStorage.length else { return nil }
        return character
    }

    static func anchor(
        for range: NSRange,
        at point: NSPoint,
        in textView: NSTextView
    ) -> NSRect? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }
        let origin = textView.textContainerOrigin
        let containerPoint = containerPoint(at: point, in: textView)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: range, actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        // A couple of points of slop so the chip's visual padding still counts.
        guard rect.insetBy(dx: -3, dy: -3).contains(containerPoint) else { return nil }
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        return rect
    }

    private static func containerPoint(at point: NSPoint, in textView: NSTextView) -> NSPoint {
        let origin = textView.textContainerOrigin
        return NSPoint(x: point.x - origin.x, y: point.y - origin.y)
    }
}

struct InlineMentionTextEditor: NSViewRepresentable {
    @Binding var text: String
    var mentionNames: [String]
    var onTab: () -> Bool
    /// Called when the user pastes. Return `.consumed` when the paste is fully
    /// handled, `.insert` to drop a token at the caret, or `.ignored` to let the
    /// editor paste as usual.
    var onPaste: (NSPasteboard) -> PasteOutcome = { _ in .ignored }
    /// Called after the system writes the selected text so the composer can
    /// attach chip metadata to the same pasteboard.
    var onCopy: (NSPasteboard, String) -> Void = { _, _ in }
    /// Given an inline token's name (without the `@`), a file URL to preview when
    /// the pointer rests on it. Return nil for tokens with nothing to show.
    var previewURL: (String) -> URL? = { _ in nil }
    /// The height the text actually occupies, so the composer can grow with its
    /// content. Measured from the layout manager rather than by rendering a
    /// hidden copy of the string in SwiftUI: that copy re-laid out the whole
    /// draft on every keystroke, and — because `onChange` reads the geometry
    /// from *before* the layout it triggered — reported the height one
    /// keystroke late.
    var onHeightChange: (CGFloat) -> Void = { _ in }
    /// The tallest the composer grows before the draft scrolls inside it. Must
    /// match the frame cap the caller applies — below it, the editor never
    /// scrolls internally (see `PinnedClipView`).
    var heightCap: CGFloat = .greatestFiniteMagnitude

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onTab: onTab, onHeightChange: onHeightChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Overlay scrollers float above the text instead of insetting it. With
        // a legacy scroller, its appearance/disappearance as the draft crosses
        // the height cap shrank the text container width and re-wrapped every
        // line — the "shutter" the user saw when a space pushed to a new line.
        // `OreOverlayScrollView` holds that answer even after the system
        // scroller preference changes, with the window-wide light knob.
        let scrollView = OreOverlayScrollView()
        scrollView.contentView = PinnedClipView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        // TextKit 1 from the start. The height measurement and hover hit-testing
        // read `layoutManager`, and the first such read on a TextKit 2 view
        // tears its layout stack down and rebuilds it as TextKit 1.
        let editor = PromptTextView(usingTextLayoutManager: false)
        editor.onPaste = onPaste
        editor.onCopy = onCopy
        editor.previewURL = previewURL
        editor.mentionNames = mentionNames
        editor.delegate = context.coordinator
        editor.drawsBackground = false
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainerInset = NSSize(width: 5, height: 6)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        // The base style from the first keystroke. Without this the editor
        // typed in NSTextView's default font until the first mention pass
        // (typically a pasted image's chip) restyled the whole draft to the
        // real style — a visible size jump mid-composition.
        editor.font = NSFont.systemFont(ofSize: OreTheme.Font.prose)
        editor.typingAttributes = Coordinator.baseAttributes
        editor.setAccessibilityLabel("Agent prompt")
        scrollView.documentView = editor
        context.coordinator.editor = editor
        // A narrower editor re-wraps and so grows taller; the height has to be
        // re-reported on width changes, not only on edits.
        editor.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.editorFrameChanged),
            name: NSView.frameDidChangeNotification,
            object: editor
        )
        context.coordinator.apply(text: text, mentionNames: mentionNames)
        context.coordinator.reportHeight(deferred: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parentText = $text
        context.coordinator.onTab = onTab
        context.coordinator.onHeightChange = onHeightChange
        context.coordinator.heightCap = heightCap
        if let editor = scrollView.documentView as? PromptTextView {
            editor.onPaste = onPaste
            editor.onCopy = onCopy
            editor.previewURL = previewURL
            editor.mentionNames = mentionNames
        }
        context.coordinator.apply(text: text, mentionNames: mentionNames)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parentText: Binding<String>
        var onTab: () -> Bool
        weak var editor: NSTextView?
        private var isApplying = false
        private var currentMentionNames: [String] = []
        /// Whether any mention attributes are currently painted into the
        /// storage — the flag that lets a mention-free draft (the common case)
        /// skip the restyle pass on every keystroke, and lets deleting the
        /// last token still trigger the one pass that clears its color.
        private var hasStyledMentions = false
        var onHeightChange: (CGFloat) -> Void
        /// The last height handed up, so an unchanged measurement doesn't write
        /// state. This is what keeps the measurement from looping: the height
        /// feeds the editor's frame, which re-measures, and only a genuine
        /// change propagates — so it converges in one step.
        private var lastReportedHeight: CGFloat = -1
        var heightCap: CGFloat = .greatestFiniteMagnitude

        init(
            text: Binding<String>,
            onTab: @escaping () -> Bool,
            onHeightChange: @escaping (CGFloat) -> Void
        ) {
            parentText = text
            self.onTab = onTab
            self.onHeightChange = onHeightChange
        }

        /// The composer's one text style, shared by editor creation and the
        /// mention pass so the draft renders identically with and without
        /// chips.
        static var baseAttributes: [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            paragraph.lineBreakMode = .byWordWrapping
            return [
                .font: NSFont.systemFont(ofSize: OreTheme.Font.prose),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let editor else { return }
            parentText.wrappedValue = editor.string
            // Restyle only when there is anything to style: with no mention
            // tokens in play (the common case), a keystroke needs no
            // attribute pass and no re-layout at all. `typingAttributes` — set
            // whenever styling does run, and at `apply` — keeps new text in
            // the base style on its own.
            if !currentMentionNames.isEmpty || hasStyledMentions {
                styleMentions(currentMentionNames, preservingSelection: true)
            }
            // Typing is an AppKit event, outside SwiftUI's update cycle, so the
            // height can be written synchronously and lands in the same frame
            // as the character.
            reportHeight(deferred: false)
        }

        @objc func editorFrameChanged() {
            reportHeight(deferred: true)
        }

        /// Reports the height the laid-out text occupies, including the
        /// container inset.
        ///
        /// `deferred` moves the callback off the current turn of the run loop.
        /// It is required whenever this runs inside `updateNSView`, where
        /// writing SwiftUI state synchronously would mutate state during a view
        /// update; a one-frame delay on programmatic text changes is invisible.
        func reportHeight(deferred: Bool) {
            guard let editor,
                  let layout = editor.layoutManager,
                  let container = editor.textContainer else { return }
            layout.ensureLayout(for: container)
            let height = ceil(layout.usedRect(for: container).height)
                + editor.textContainerInset.height * 2
            // Decided before the caret scroll that follows an edit: a wrap
            // grows the text a line before SwiftUI grows the frame, and without
            // the pin NSTextView scrolled that line into view for one frame and
            // then snapped back once the taller frame landed.
            (editor.enclosingScrollView?.contentView as? PinnedClipView)?
                .pinsToTop = height <= heightCap + 0.5
            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            if deferred {
                DispatchQueue.main.async { [self] in onHeightChange(height) }
            } else {
                onHeightChange(height)
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertTab(_:)) else { return false }
            return onTab()
        }

        func apply(text: String, mentionNames: [String]) {
            guard let editor else { return }
            let mentionsChanged = mentionNames != currentMentionNames
            currentMentionNames = mentionNames
            var changed = false
            if editor.string != text {
                isApplying = true
                let selection = Self.adjustedSelection(
                    editor.selectedRange(),
                    replacing: editor.string,
                    with: text
                )
                editor.string = text
                editor.setSelectedRange(selection)
                isApplying = false
                changed = true
            }
            // The hot path is a keystroke bouncing the binding through SwiftUI
            // and back into `updateNSView`: the text already matches (it came
            // from the editor) and the mentions haven't moved, so there is
            // nothing to restyle. Restyling anyway was the second full
            // attribute pass + re-layout every keystroke paid for — and, on a
            // rewrite of composing text, what broke IME input.
            if changed || mentionsChanged {
                styleMentions(mentionNames, preservingSelection: true)
            }
            // Only for text set from outside (slash command, voice commit, a
            // tab switch restoring a draft). Typing already reported itself
            // synchronously in `textDidChange`, and this runs inside
            // `updateNSView`, so it has to defer.
            if changed { reportHeight(deferred: true) }
        }

        /// SwiftUI updates the binding after a completion replaces `@ind` with
        /// `@index.ts `. AppKit still has the old insertion point at that moment;
        /// map it across the changed range so continued typing starts after the
        /// complete token instead of in the middle of its filename.
        private static func adjustedSelection(
            _ selection: NSRange,
            replacing oldValue: String,
            with newValue: String
        ) -> NSRange {
            let old = oldValue as NSString
            let new = newValue as NSString
            var prefix = 0
            while prefix < min(old.length, new.length),
                  old.character(at: prefix) == new.character(at: prefix) {
                prefix += 1
            }

            var suffix = 0
            while suffix < old.length - prefix,
                  suffix < new.length - prefix,
                  old.character(at: old.length - suffix - 1)
                    == new.character(at: new.length - suffix - 1) {
                suffix += 1
            }

            let oldChangeEnd = old.length - suffix
            let newChangeEnd = new.length - suffix
            let location: Int
            if selection.location >= prefix, selection.location <= oldChangeEnd {
                location = newChangeEnd
            } else if selection.location > oldChangeEnd {
                location = selection.location + new.length - old.length
            } else {
                location = selection.location
            }
            return NSRange(location: min(max(0, location), new.length), length: 0)
        }

        private func styleMentions(_ mentionNames: [String], preservingSelection: Bool) {
            guard let editor, let storage = editor.textStorage else { return }
            // Callers gate on actual change now (see `apply` / `textDidChange`)
            // — the old defence here was a signature string that *copied the
            // whole draft* to decide whether to skip, an O(n) allocation per
            // keystroke that cost nearly as much as the work it avoided.
            hasStyledMentions = mentionNames.contains { !$0.isEmpty }
            let selection = editor.selectedRange()
            let whole = NSRange(location: 0, length: storage.length)
            let base = Self.baseAttributes

            isApplying = true
            storage.beginEditing()
            storage.setAttributes(base, range: whole)
            let source = storage.string as NSString
            for name in mentionNames where !name.isEmpty {
                var search = NSRange(location: 0, length: source.length)
                let token = "@\(name)"
                while search.length > 0 {
                    let found = source.range(of: token, options: [], range: search)
                    guard found.location != NSNotFound else { break }
                    storage.addAttributes([
                        .font: NSFont.systemFont(ofSize: OreTheme.Font.prose, weight: .semibold),
                        .foregroundColor: NSColor.oreInlineChipText,
                        .backgroundColor: NSColor.oreInlineChipFill,
                    ], range: found)
                    let next = NSMaxRange(found)
                    search = NSRange(location: next, length: source.length - next)
                }
            }
            storage.endEditing()
            editor.typingAttributes = base
            if preservingSelection { editor.setSelectedRange(selection) }
            isApplying = false
        }
    }
}

/// The composer's clip view. While the draft fits under the height cap the
/// composer's frame is what grows, so there is never anything to scroll to —
/// holding the origin at the top keeps a line wrap from scrolling the text for
/// the single frame before the taller frame arrives.
final class PinnedClipView: NSClipView {
    var pinsToTop = true

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        if pinsToTop { bounds.origin.y = 0 }
        return bounds
    }
}

/// An `NSTextView` that lets the composer intercept paste, so a copied file,
/// image, or long text dump lands as an attachment (an inline `@name` chip at
/// the caret) instead of its path or a wall of prose being typed in. Hovering
/// a chip previews the file.
final class PromptTextView: NSTextView {
    var onPaste: ((NSPasteboard) -> PasteOutcome)?
    var onCopy: ((NSPasteboard, String) -> Void)?
    var previewURL: ((String) -> URL?)?
    var mentionNames: [String] = []

    private var hoverTracking: NSTrackingArea?
    private let attachmentPreview = AttachmentPreviewController()

    /// Runs the composer's paste handler and applies its verdict. Returns true
    /// when the paste was ours (so the caller skips the default paste).
    private func consumePaste(_ pboard: NSPasteboard) -> Bool {
        switch onPaste?(pboard) ?? .ignored {
        case .ignored:
            return false
        case .consumed:
            return true
        case .insert(let token):
            insertText(token, replacementRange: selectedRange())
            return true
        }
    }

    override func copy(_ sender: Any?) {
        let text = copiedText
        super.copy(sender)
        onCopy?(NSPasteboard.general, text)
    }

    override func cut(_ sender: Any?) {
        let text = copiedText
        super.cut(sender)
        onCopy?(NSPasteboard.general, text)
    }

    private var copiedText: String {
        let range = selectedRange()
        if range.length > 0 {
            return (string as NSString).substring(with: range)
        }
        return string
    }

    override func paste(_ sender: Any?) {
        if consumePaste(.general) { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if consumePaste(.general) { return }
        super.pasteAsPlainText(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        if consumePaste(.general) { return }
        super.pasteAsRichText(sender)
    }

    // `paste(_:)` funnels through `readSelection(from:)` to actually pull content
    // off the board; overriding it here catches every paste path (including the
    // image/file cases a plain-text view would otherwise silently drop).
    override func readSelection(from pboard: NSPasteboard) -> Bool {
        if consumePaste(pboard) { return true }
        return super.readSelection(from: pboard)
    }

    // A plain-text view advertises only text types, so AppKit never offers it
    // images or file URLs. Advertise them too, so paste reaches `readSelection`.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [ComposerPasteboard.type, .png, .tiff, .fileURL] + super.readablePasteboardTypes
    }

    // MARK: - Hover preview

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Keep only our own tracking area in sync; NSTextView owns others (cursor
        // rects, selection) that must not be torn down here.
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let options: NSTrackingArea.Options = [
            .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect,
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updatePreview(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        dismissPreview()
    }

    private func updatePreview(at point: NSPoint) {
        guard let previewURL,
              let charIndex = AttachmentHoverHitTesting.characterIndex(at: point, in: self)
        else { dismissPreview(); return }
        let named = mentionNames.filter { previewURL($0) != nil }
        guard !named.isEmpty else { dismissPreview(); return }

        let source = string as NSString
        for name in named {
            let token = "@\(name)"
            var search = NSRange(location: 0, length: source.length)
            while search.length > 0 {
                let found = source.range(of: token, options: [], range: search)
                guard found.location != NSNotFound else { break }
                if charIndex >= found.location, charIndex < NSMaxRange(found),
                   let url = previewURL(name),
                   let anchor = AttachmentHoverHitTesting.anchor(
                    for: found, at: point, in: self
                   ) {
                    attachmentPreview.show(url: url, from: self, anchor: anchor)
                    return
                }
                let next = NSMaxRange(found)
                search = NSRange(location: next, length: source.length - next)
            }
        }
        dismissPreview()
    }

    private func dismissPreview() {
        attachmentPreview.dismiss()
    }
}
