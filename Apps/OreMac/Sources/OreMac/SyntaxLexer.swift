import AppKit

/// What a span of source is, in tree-sitter's capture vocabulary.
///
/// The lexer and the tree-sitter path share `SyntaxTheme`, so a keyword looks
/// the same whether a grammar or the scanner found it. An enum rather than
/// strings keeps the hot loop free of allocation; `capture` is only read when
/// the theme table is built and by tests.
enum SyntaxTokenKind: UInt8, CaseIterable, Sendable {
    case keyword, type, typeBuiltin, function, functionBuiltin
    case constant, constantBuiltin, number
    case string, stringEscape, stringSpecial
    case comment, attribute, label, property
    case variableBuiltin, variableSpecial
    case tag, punctuation, punctuationSpecial
    case heading, bold, italic, link, linkURL, raw, quote
    case diffPlus, diffMinus, diffHunk, diffHeader

    var capture: String {
        switch self {
        case .keyword: "keyword"
        case .type: "type"
        case .typeBuiltin: "type.builtin"
        case .function: "function"
        case .functionBuiltin: "function.builtin"
        case .constant: "constant"
        case .constantBuiltin: "constant.builtin"
        case .number: "number"
        case .string: "string"
        case .stringEscape: "string.escape"
        case .stringSpecial: "string.special"
        case .comment: "comment"
        case .attribute: "attribute"
        case .label: "label"
        case .property: "property"
        case .variableBuiltin: "variable.builtin"
        case .variableSpecial: "variable.special"
        case .tag: "tag"
        case .punctuation: "punctuation"
        case .punctuationSpecial: "punctuation.special"
        case .heading: "markup.heading"
        case .bold: "markup.bold"
        case .italic: "markup.italic"
        case .link: "markup.link"
        case .linkURL: "markup.link.url"
        case .raw: "markup.raw"
        case .quote: "markup.quote"
        case .diffPlus: "diff.plus"
        case .diffMinus: "diff.minus"
        case .diffHunk: "diff.hunk"
        case .diffHeader: "diff.header"
        }
    }
}

struct SyntaxToken: Equatable, Sendable {
    var start: Int
    var end: Int
    var kind: SyntaxTokenKind
}

/// Keyword, type and constant lookup without building a `String` per word.
///
/// Every identifier in a file is looked up, so hashing the UTF-16 units in
/// place and comparing against stored units is what keeps a 2 MB file from
/// allocating half a million throwaway strings.
struct WordTable: Sendable {
    private struct Entry: Sendable {
        var units: [UInt16]
        var kind: SyntaxTokenKind
    }

    private var buckets: [UInt64: [Entry]] = [:]
    private(set) var maxLength = 0
    let caseInsensitive: Bool

    init(caseInsensitive: Bool) {
        self.caseInsensitive = caseInsensitive
    }

    var isEmpty: Bool { buckets.isEmpty }

    /// Later insertions don't override earlier ones, so callers add the most
    /// specific category (keywords) first.
    mutating func insert(_ words: [String], as kind: SyntaxTokenKind) {
        for word in words {
            var units = Array(word.utf16)
            if caseInsensitive { units = units.map(Self.fold) }
            let hash = units.withUnsafeBufferPointer { Self.hash($0, 0, $0.count, fold: false) }
            if buckets[hash, default: []].contains(where: { $0.units == units }) { continue }
            buckets[hash, default: []].append(Entry(units: units, kind: kind))
            maxLength = max(maxLength, units.count)
        }
    }

    func lookup(_ text: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int) -> SyntaxTokenKind? {
        let length = end - start
        guard length > 0, length <= maxLength else { return nil }
        let hash = Self.hash(text, start, end, fold: caseInsensitive)
        guard let entries = buckets[hash] else { return nil }
        for entry in entries where entry.units.count == length {
            var equal = true
            for offset in 0..<length {
                let unit = caseInsensitive ? Self.fold(text[start + offset]) : text[start + offset]
                if unit != entry.units[offset] { equal = false; break }
            }
            if equal { return entry.kind }
        }
        return nil
    }

    private static func fold(_ unit: UInt16) -> UInt16 {
        unit >= 65 && unit <= 90 ? unit + 32 : unit
    }

    private static func hash(_ text: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int, fold: Bool) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for index in start..<end {
            let unit = fold ? Self.fold(text[index]) : text[index]
            hash = (hash ^ UInt64(unit)) &* 0x100_0000_01b3
        }
        return hash
    }
}

/// A set of ASCII code units, for "can this character start/continue X".
struct UnitSet: Sendable {
    private var low: UInt64 = 0
    private var high: UInt64 = 0

    init(_ characters: String = "") {
        for unit in characters.utf16 { insert(unit) }
    }

    mutating func insert(_ unit: UInt16) {
        if unit < 64 { low |= 1 << UInt64(unit) } else if unit < 128 { high |= 1 << UInt64(unit - 64) }
    }

    func contains(_ unit: UInt16) -> Bool {
        if unit < 64 { return low & (1 << UInt64(unit)) != 0 }
        if unit < 128 { return high & (1 << UInt64(unit - 64)) != 0 }
        return false
    }
}

enum Unit {
    static let newline: UInt16 = 10
    static let carriageReturn: UInt16 = 13
    static let space: UInt16 = 32
    static let tab: UInt16 = 9
    static let backslash: UInt16 = 92
    static let quote: UInt16 = 34
    static let apostrophe: UInt16 = 39
    static let backtick: UInt16 = 96

    @inline(__always) static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }
    @inline(__always) static func isHexDigit(_ unit: UInt16) -> Bool {
        isDigit(unit) || (unit >= 65 && unit <= 70) || (unit >= 97 && unit <= 102)
    }
    @inline(__always) static func isLetter(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122)
    }
    @inline(__always) static func isUpper(_ unit: UInt16) -> Bool { unit >= 65 && unit <= 90 }
    @inline(__always) static func isLower(_ unit: UInt16) -> Bool { unit >= 97 && unit <= 122 }
    @inline(__always) static func isBlank(_ unit: UInt16) -> Bool {
        unit == space || unit == tab || unit == carriageReturn
    }
    /// ASCII word characters, plus anything non-ASCII: identifiers in most
    /// languages accept Unicode letters, and treating the rest (emoji, NBSP)
    /// as word characters costs nothing worse than an uncoloured run.
    @inline(__always) static func isWord(_ unit: UInt16) -> Bool {
        isLetter(unit) || isDigit(unit) || unit == 95 || unit >= 128
    }
}

/// The scanner. One forward pass per language region; delegation (a
/// `<script>` in HTML, a fence in Markdown, an interpolation in a string)
/// recurses over a sub-range of the same buffer, so token offsets are always
/// absolute UTF-16 indices that map straight onto `NSAttributedString`.
struct SyntaxLexer {
    let text: UnsafeBufferPointer<UInt16>
    var tokens: [SyntaxToken] = []
    /// Delegation depth, so a pathological input can't recurse without bound.
    var depth = 0

    init(text: UnsafeBufferPointer<UInt16>) {
        self.text = text
    }

    /// Tokens for `code` in `language` (a canonical name or nil), in order.
    /// Later tokens may overlap earlier ones and win, which Markdown uses to
    /// layer inline styles over a block quote.
    static func tokens(for code: String, language: String?) -> [SyntaxToken] {
        let units = Array(code.utf16)
        guard !units.isEmpty else { return [] }
        let definition = LanguageRegistry.definition(for: language)
        return units.withUnsafeBufferPointer { buffer in
            var lexer = SyntaxLexer(text: buffer)
            lexer.lex(definition, from: 0, to: buffer.count)
            return lexer.tokens
        }
    }

    @inline(__always)
    mutating func emit(_ kind: SyntaxTokenKind, _ start: Int, _ end: Int) {
        guard end > start else { return }
        if let last = tokens.last, last.kind == kind, last.end == start {
            tokens[tokens.count - 1].end = end
        } else {
            tokens.append(SyntaxToken(start: start, end: end, kind: kind))
        }
    }

    mutating func lex(_ language: CompiledLanguage, from: Int, to: Int) {
        guard from < to, depth < 16 else { return }
        depth += 1
        defer { depth -= 1 }
        switch language.lexer {
        case .plain: break
        case .code: scanCode(language, from: from, to: to)
        case .markup(let flavor): scanMarkup(flavor, from: from, to: to)
        case .css(let flavor): scanCSS(flavor, from: from, to: to)
        case .markdown: scanMarkdown(from: from, to: to)
        case .yaml: scanYAML(from: from, to: to)
        case .diff: scanDiff(from: from, to: to)
        }
    }

    // MARK: - Small helpers shared by every lexer

    @inline(__always)
    func matches(_ pattern: [UInt16], at index: Int, limit: Int) -> Bool {
        let count = pattern.count
        guard count > 0, index + count <= limit else { return false }
        for offset in 0..<count where text[index + offset] != pattern[offset] { return false }
        return true
    }

    func matchesIgnoringCase(_ pattern: [UInt16], at index: Int, limit: Int) -> Bool {
        let count = pattern.count
        guard count > 0, index + count <= limit else { return false }
        for offset in 0..<count {
            var unit = text[index + offset]
            if Unit.isUpper(unit) { unit += 32 }
            if unit != pattern[offset] { return false }
        }
        return true
    }

    func lineEnd(from index: Int, limit: Int) -> Int {
        var cursor = index
        while cursor < limit, text[cursor] != Unit.newline { cursor += 1 }
        return cursor
    }

    func skipBlanks(from index: Int, limit: Int) -> Int {
        var cursor = index
        while cursor < limit, Unit.isBlank(text[cursor]) { cursor += 1 }
        return cursor
    }

    /// Whether only blanks separate `index` from the start of its line.
    func isAtLineStart(_ index: Int, floor: Int) -> Bool {
        var cursor = index - 1
        while cursor >= floor {
            let unit = text[cursor]
            if unit == Unit.newline { return true }
            if !Unit.isBlank(unit) { return false }
            cursor -= 1
        }
        return true
    }

    /// The index just past the bracket matching the opener at `index`, or nil
    /// when it isn't closed before `limit`. Quoted text is skipped so a `}` in
    /// a string doesn't end an interpolation early.
    func matchingClose(from index: Int, open: UInt16, close: UInt16, limit: Int) -> Int? {
        var depth = 0
        var cursor = index
        var quote: UInt16 = 0
        while cursor < limit {
            let unit = text[cursor]
            if quote != 0 {
                if unit == Unit.backslash { cursor += 2; continue }
                // Quotes are tracked within a line: a stray apostrophe (a Rust
                // lifetime, prose) must not swallow the rest of the input.
                if unit == quote || unit == Unit.newline { quote = 0 }
            } else if unit == Unit.quote || unit == Unit.apostrophe {
                quote = unit
            } else if unit == open {
                depth += 1
            } else if unit == close {
                depth -= 1
                if depth == 0 { return cursor + 1 }
            }
            cursor += 1
        }
        return nil
    }
}
