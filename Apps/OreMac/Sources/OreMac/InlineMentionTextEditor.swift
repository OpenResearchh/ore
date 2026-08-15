import AppKit
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

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = ceil(measured.height) + padding * 2 > cap.height
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = textView
        return scroll
    }

    private static func isImageURL(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]
            .contains(url.pathExtension.lowercased())
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
    /// Given an inline token's name (without the `@`), a file URL to preview when
    /// the pointer rests on it. Return nil for tokens with nothing to show.
    var previewURL: (String) -> URL? = { _ in nil }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onTab: onTab)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // Overlay scrollers float above the text instead of insetting it. With
        // a legacy scroller, its appearance/disappearance as the draft crosses
        // the height cap shrank the text container width and re-wrapped every
        // line — the "shutter" the user saw when a space pushed to a new line.
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        let editor = PromptTextView()
        editor.onPaste = onPaste
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
        editor.setAccessibilityLabel("Agent prompt")
        scrollView.documentView = editor
        context.coordinator.editor = editor
        context.coordinator.apply(text: text, mentionNames: mentionNames)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parentText = $text
        context.coordinator.onTab = onTab
        if let editor = scrollView.documentView as? PromptTextView {
            editor.onPaste = onPaste
            editor.previewURL = previewURL
            editor.mentionNames = mentionNames
        }
        context.coordinator.apply(text: text, mentionNames: mentionNames)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parentText: Binding<String>
        var onTab: () -> Bool
        weak var editor: NSTextView?
        private var isApplying = false
        private var currentMentionNames: [String] = []
        /// The (text, mention-names) the storage was last styled for. Every
        /// keystroke bounces the binding through SwiftUI, so `updateNSView`
        /// re-runs `apply` and would restyle the whole storage a second time for
        /// the exact same content — a redundant full re-layout that showed up as
        /// a flicker. Skipping when nothing changed makes it one pass, not two.
        private var lastStyledSignature: String?

        init(text: Binding<String>, onTab: @escaping () -> Bool) {
            parentText = text
            self.onTab = onTab
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let editor else { return }
            parentText.wrappedValue = editor.string
            styleMentions(currentMentionNames, preservingSelection: true)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertTab(_:)) else { return false }
            return onTab()
        }

        func apply(text: String, mentionNames: [String]) {
            guard let editor else { return }
            currentMentionNames = mentionNames
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
            }
            styleMentions(mentionNames, preservingSelection: true)
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
            // A full-storage restyle is only worth its re-layout when the text
            // or the set of mentions actually changed since the last one.
            let signature = "\(storage.length):\(storage.string)\u{0}\(mentionNames.joined(separator: "\u{0}"))"
            guard signature != lastStyledSignature else { return }
            lastStyledSignature = signature
            let selection = editor.selectedRange()
            let whole = NSRange(location: 0, length: storage.length)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            paragraph.lineBreakMode = .byWordWrapping
            let base: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: OreTheme.Font.prose),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]

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
                        .foregroundColor: NSColor.controlAccentColor,
                        .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.10),
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

/// An `NSTextView` that lets the composer intercept paste, so a copied file,
/// image, or long text dump lands as an attachment (an inline `@name` chip at
/// the caret) instead of its path or a wall of prose being typed in. Hovering
/// a chip previews the file.
final class PromptTextView: NSTextView {
    var onPaste: ((NSPasteboard) -> PasteOutcome)?
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
        [.png, .tiff, .fileURL] + super.readablePasteboardTypes
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
              let layoutManager,
              let textContainer else { dismissPreview(); return }
        let named = mentionNames.filter { previewURL($0) != nil }
        guard !named.isEmpty else { dismissPreview(); return }

        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyph)
        let source = string as NSString
        guard charIndex < source.length else { dismissPreview(); return }

        for name in named {
            let token = "@\(name)"
            var search = NSRange(location: 0, length: source.length)
            while search.length > 0 {
                let found = source.range(of: token, options: [], range: search)
                guard found.location != NSNotFound else { break }
                if charIndex >= found.location, charIndex < NSMaxRange(found),
                   let url = previewURL(name) {
                    let glyphRange = layoutManager.glyphRange(
                        forCharacterRange: found, actualCharacterRange: nil
                    )
                    var anchor = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                    anchor.origin.x += origin.x
                    anchor.origin.y += origin.y
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
