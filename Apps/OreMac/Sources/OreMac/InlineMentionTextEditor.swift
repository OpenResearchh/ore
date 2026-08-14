import AppKit
import SwiftUI

/// The prompt editor needs one capability SwiftUI's `TextEditor` does not
/// expose on macOS: intercepting Tab while a completion menu is open. It also
/// lets workspace references read as inline tokens without moving them to a
/// separate attachment shelf above the prompt.
struct InlineMentionTextEditor: NSViewRepresentable {
    @Binding var text: String
    var mentionNames: [String]
    var onTab: () -> Bool
    /// Called when the user pastes; return true to consume the paste (e.g. a
    /// file or image was attached) so the editor doesn't also insert text.
    var onPaste: (NSPasteboard) -> Bool = { _ in false }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onTab: onTab)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let editor = PromptTextView()
        editor.onPaste = onPaste
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
        (scrollView.documentView as? PromptTextView)?.onPaste = onPaste
        context.coordinator.apply(text: text, mentionNames: mentionNames)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parentText: Binding<String>
        var onTab: () -> Bool
        weak var editor: NSTextView?
        private var isApplying = false
        private var currentMentionNames: [String] = []

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
            let selection = editor.selectedRange()
            let whole = NSRange(location: 0, length: storage.length)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            paragraph.lineBreakMode = .byWordWrapping
            let base: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15),
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
                        .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
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

/// An `NSTextView` that lets the composer intercept paste, so a copied file or
/// image lands as an attachment instead of its path/nothing being typed in.
final class PromptTextView: NSTextView {
    var onPaste: ((NSPasteboard) -> Bool)?

    override func paste(_ sender: Any?) {
        if onPaste?(NSPasteboard.general) == true { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if onPaste?(NSPasteboard.general) == true { return }
        super.pasteAsPlainText(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        if onPaste?(NSPasteboard.general) == true { return }
        super.pasteAsRichText(sender)
    }

    // `paste(_:)` funnels through `readSelection(from:)` to actually pull content
    // off the board; overriding it here catches every paste path (including the
    // image/file cases a plain-text view would otherwise silently drop).
    override func readSelection(from pboard: NSPasteboard) -> Bool {
        if onPaste?(pboard) == true { return true }
        return super.readSelection(from: pboard)
    }

    // A plain-text view advertises only text types, so AppKit never offers it
    // images or file URLs. Advertise them too, so paste reaches `readSelection`.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.png, .tiff, .fileURL] + super.readablePasteboardTypes
    }
}
