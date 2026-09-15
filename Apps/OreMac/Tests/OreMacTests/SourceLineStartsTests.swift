import AppKit
import Foundation
import Testing

@testable import OreMac

/// The editor splices line starts on every edit instead of rescanning the file,
/// so every splice has to land exactly where a full rescan would.
struct SourceLineStartsTests {
    /// Applies one edit to both a spliced index and a fresh rescan.
    private func check(
        _ original: String, replacing range: NSRange, with replacement: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let before = NSMutableString(string: original)
        var spliced = SourceLineStarts(text: before)
        before.replaceCharacters(in: range, with: replacement)
        spliced.replace(range, withLength: (replacement as NSString).length, in: before)
        #expect(spliced == SourceLineStarts(text: before), sourceLocation: sourceLocation)
    }

    @Test func emptyTextHasOneLine() {
        #expect(SourceLineStarts(text: "").starts == [0])
        #expect(SourceLineStarts(text: "a\n").starts == [0])
        #expect(SourceLineStarts(text: "a\nb").starts == [0, 2])
        #expect(SourceLineStarts(text: "a\r\nb").starts == [0, 3])
    }

    @Test func typingAndDeletingNewlines() {
        check("abc", replacing: NSRange(location: 1, length: 0), with: "\n")
        check("a\nbc", replacing: NSRange(location: 1, length: 1), with: "")
        check("one\ntwo\nthree", replacing: NSRange(location: 4, length: 3), with: "2\n2b\n2c")
        check("one\ntwo\nthree\n", replacing: NSRange(location: 0, length: 14), with: "")
        check("", replacing: NSRange(location: 0, length: 0), with: "x\ny\n")
        check("tail\n", replacing: NSRange(location: 5, length: 0), with: "z")
    }

    @Test func carriageReturnsJoinAndSplit() {
        // An LF typed after a CR merges two breaks into one.
        check("a\rb", replacing: NSRange(location: 2, length: 0), with: "\n")
        // Deleting between them merges too.
        check("a\rX\nb", replacing: NSRange(location: 2, length: 1), with: "")
        // Splitting a CRLF makes two breaks.
        check("a\r\nb", replacing: NSRange(location: 2, length: 0), with: "X")
        check("a\r\nb", replacing: NSRange(location: 1, length: 1), with: "")
    }

    @Test func randomEditsMatchARescan() {
        var generator = SystemRandomNumberGenerator()
        let pieces = ["a", "bc", "\n", "\r", "\r\n", "\u{2028}", "x\ny", "", "long line here"]
        var text = ""
        for _ in 0..<40 { text += pieces.randomElement(using: &generator)! }
        let current = NSMutableString(string: text)
        var spliced = SourceLineStarts(text: current)
        for _ in 0..<500 {
            let location = Int.random(in: 0...current.length, using: &generator)
            let length = Int.random(in: 0...min(6, current.length - location), using: &generator)
            var replacement = ""
            for _ in 0..<Int.random(in: 0...3, using: &generator) {
                replacement += pieces.randomElement(using: &generator)!
            }
            let range = NSRange(location: location, length: length)
            current.replaceCharacters(in: range, with: replacement)
            spliced.replace(range, withLength: (replacement as NSString).length, in: current)
            #expect(spliced == SourceLineStarts(text: current))
            if spliced != SourceLineStarts(text: current) { return }
        }
    }

    @Test func lineLookupsClamp() {
        let starts = SourceLineStarts(text: "a\nbb\nccc")
        #expect(starts.line(containing: 0) == 0)
        #expect(starts.line(containing: 2) == 1)
        #expect(starts.line(containing: 4) == 1)
        #expect(starts.line(containing: 99) == 2)
        #expect(starts.start(ofLine: 1) == 2)
        #expect(starts.start(ofLine: 50) == 5)
    }
}

/// The editor colours a keystroke's own lines synchronously and leaves
/// everything a lexer can't see from those lines alone to a whole-file pass
/// that lands about 150 ms later. These pin the seams between the two.
struct SourceHighlightPassTests {
    @MainActor
    private func fonts() -> SourceHighlightFonts {
        SourceHighlightFonts(base: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular))
    }

    /// The storage as a whole-file pass would leave it.
    @MainActor
    private func rendered(_ text: String, path: String) -> NSTextStorage {
        NSTextStorage(attributedString: SourceHighlightPass.render(text, path: path, fonts: fonts()).attributed)
    }

    /// The per-line pass decides whether a construct is still open above an
    /// edit by asking whether the previous line's terminator carries a colour.
    /// A line comment must stop short of its terminator for that to work, or
    /// every line under a `//` would wait for the idle pass to be coloured.
    @MainActor @Test func lineCommentsStopBeforeTheirTerminator() {
        let text = "// note\nlet a = 1\n"
        let storage = rendered(text, path: "a.js")
        let terminator = (text as NSString).range(of: "\nlet").location
        #expect(SourceHighlightPass.isColoured(storage, at: terminator) == false)
    }

    /// The other half of the same probe: a block comment does cover the breaks
    /// inside it, and stops covering them at its close.
    @MainActor @Test func blockCommentsCoverTheLineBreaksInsideThem() {
        let text = "let a = 1\n/* opened\nstill inside\n*/\nlet b = 2\n"
        let storage = rendered(text, path: "a.js")
        let ns = text as NSString
        let inside = ns.range(of: "\nstill").location
        #expect(SourceHighlightPass.isColoured(storage, at: inside))
        // The break after the close belongs to no token again.
        let afterClose = ns.range(of: "*/").location + 2
        #expect(SourceHighlightPass.isColoured(storage, at: afterClose) == false)
    }

    /// For tree-sitter languages the per-line pass repaints only the characters
    /// the edit touched, because the lexer's opinion of the rest of the line
    /// would disagree with the parser's. Neighbouring tokens must survive.
    @MainActor @Test func paintOnlyTouchingLeavesNeighbouringTokensAlone() {
        let fonts = self.fonts()
        let text = "let a = 1"
        // A colour no theme uses: `systemPurple` is what numbers are painted,
        // so a repainted "1" would have compared equal to the sentinel and the
        // check would have passed for the wrong reason.
        let sentinel = NSColor(srgbRed: 0.42, green: 0.17, blue: 0.83, alpha: 1)
        let target = NSMutableAttributedString(
            string: text,
            attributes: [.font: fonts.base, .foregroundColor: sentinel]
        )
        let full = NSRange(location: 0, length: (text as NSString).length)
        SourceHighlightPass.paint(
            SyntaxLexer.tokens(for: text, language: "javascript"),
            offset: 0, into: target, over: full, fonts: fonts,
            onlyTouching: NSRange(location: 8, length: 1)
        )
        #expect(target.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == sentinel)
        #expect(target.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor != sentinel)
    }

    /// Without a focus range the whole range is reset first, so a token that
    /// an edit removed loses its colour instead of keeping a stale one.
    @MainActor @Test func paintResetsTheRangeItRepaints() {
        let fonts = self.fonts()
        let text = "plain words"
        let target = NSMutableAttributedString(
            string: text,
            attributes: [.font: fonts.bold, .foregroundColor: NSColor.systemPurple]
        )
        let full = NSRange(location: 0, length: (text as NSString).length)
        SourceHighlightPass.paint([], offset: 0, into: target, over: full, fonts: fonts)
        #expect(target.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .labelColor)
        #expect(target.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == fonts.base)
    }

    /// The idle pass hands back colours for the snapshot it was given. If the
    /// file moved under it the offsets no longer mean anything, so the result
    /// has to be dropped rather than applied at the wrong places.
    @MainActor @Test func aStaleIdleResultIsDropped() {
        let storage = NSTextStorage(
            string: "let a = 1\nlet b = 2\n",
            attributes: [.foregroundColor: NSColor.labelColor]
        )
        let stale = NSAttributedString(
            string: "let a = 1\n",
            attributes: [.foregroundColor: NSColor.systemPink]
        )
        SourceHighlightPass.applyChanges(from: stale, to: storage)
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .labelColor)
    }

    /// A fresh result is copied on, and only colour and font are copied: the
    /// editor's line spacing lives in the storage and a background pass never
    /// computes it.
    @MainActor @Test func aFreshIdleResultKeepsTheEditorsParagraphStyle() {
        let fonts = self.fonts()
        let text = "/* opened\nstill inside\n*/\n"
        let storage = NSTextStorage(string: text, attributes: [
            .font: fonts.base,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: SourceHighlightPass.paragraphStyle,
        ])
        let target = SourceHighlightPass.render(text, path: "a.js", fonts: fonts).attributed
        SourceHighlightPass.applyChanges(from: target, to: storage)
        let inside = (text as NSString).range(of: "still").location
        #expect(
            storage.attribute(.foregroundColor, at: inside, effectiveRange: nil) as? NSColor
                == target.attribute(.foregroundColor, at: inside, effectiveRange: nil) as? NSColor
        )
        #expect(SourceHighlightPass.isColoured(storage, at: inside))
        #expect(
            storage.attribute(.paragraphStyle, at: inside, effectiveRange: nil) as? NSParagraphStyle
                == SourceHighlightPass.paragraphStyle
        )
    }

    /// `usesParser` gates which languages only get their edited characters
    /// repainted. It is a hand-kept copy of `SyntaxHighlighter.grammar(named:)`
    /// and silently colours a file twice over if the two drift apart.
    @Test func usesParserMatchesTheBundledGrammars() {
        #expect(SourceHighlightPass.usesParser("swift"))
        #expect(SourceHighlightPass.usesParser("json"))
        #expect(SourceHighlightPass.usesParser("javascript") == false)
        #expect(SourceHighlightPass.usesParser(nil) == false)
    }
}
