import AppKit
import SwiftTreeSitter
import TreeSitterJSON
import TreeSitterSwift

/// Syntax highlighting for code blocks, the source editor and diffs.
///
/// Two engines, one theme. tree-sitter parses rather than pattern-matches,
/// which makes it the most accurate option, but only Swift and JSON have
/// grammars ORE can bundle (see below). Everything else — and every diff
/// line, and any snippet tree-sitter fails on — goes through `SyntaxLexer`, a
/// single-pass scanner driven by declarative `LanguageDefinition`s.
///
/// The lexer is deliberately a lexer, not a parser: it knows where comments,
/// strings, numbers and words start and end in each language, and colours by
/// what a token is rather than where it sits. That is enough to never colour a
/// `//` inside a string as a comment or a keyword inside a comment, and it runs
/// in one linear pass with no regular expressions, so a 2 MB file in the
/// editor costs about as much as copying it.
///
/// Unhighlighted code in an app whose whole job is reading code is a worse
/// outcome than approximate highlighting, so unknown languages get a generic
/// C-like definition rather than nothing. Plain text (`text`, `log`) opts out.
final class SyntaxHighlighter: @unchecked Sendable {
    static let shared = SyntaxHighlighter()

    private let lock = NSLock()
    private var languages: [String: LoadedLanguage] = [:]

    private struct LoadedLanguage {
        var language: Language
        var query: Query?
    }

    /// Grammars bundled with the app.
    ///
    /// Each grammar's C entry point returns an opaque `TSLanguage *`.
    private static func grammar(named name: String) -> OpaquePointer? {
        switch name {
        case "swift": return tree_sitter_swift()
        case "json": return tree_sitter_json()
        default: return nil
        }
    }

    // Only grammars whose SwiftPM manifest actually builds are bundled.
    //
    // Several official tree-sitter grammars (JavaScript, Python among them)
    // decide whether to compile their external scanner with
    // `FileManager.default.fileExists(atPath: "src/scanner.c")` — a path
    // relative to whoever is *consuming* the package, not to the package
    // itself. Consumed from another directory the test fails, the scanner is
    // skipped, and the link dies on undefined symbols. Vendoring a copy of a
    // generated parser to work around that is a maintenance burden that
    // outweighs the benefit, so those languages take the lexer path.

    /// Highlights a snippet or a whole file. Returns plain attributed text when
    /// the language opts out of colour, so a caller never has to check.
    func highlight(
        _ code: String,
        language rawLanguage: String?,
        font: NSFont,
        baseColor: NSColor = .labelColor,
        cache: Bool = true
    ) -> NSAttributedString {
        guard cache else {
            return renderHighlight(code, language: rawLanguage, font: font, baseColor: baseColor)
        }
        let cacheKey = HighlightCacheKey(
            language: Self.canonicalName(rawLanguage) ?? "",
            codeHash: code.hashValue,
            codeLength: code.utf8.count,
            fontSize: font.pointSize,
            appearance: NSAppearance.currentDrawing().name.rawValue
        )
        if let cached = cachedHighlight(for: cacheKey, code: code) { return cached }

        let rendered = renderHighlight(
            code, language: rawLanguage, font: font, baseColor: baseColor
        )
        storeHighlight(rendered, code: code, for: cacheKey)
        return rendered
    }

    init(highlightCacheBudget: Int = 8 << 20, highlightCacheCapacity: Int = 48) {
        self.highlightCacheBudget = highlightCacheBudget
        self.highlightCacheCapacity = highlightCacheCapacity
    }

    /// Keyed by a hash of the code rather than the code itself, with the
    /// code kept on the entry for a full comparison on a hit — a collision
    /// must never hand back another snippet's colours.
    private struct HighlightCacheKey: Hashable {
        var language: String
        var codeHash: Int
        var codeLength: Int
        var fontSize: CGFloat
        var appearance: String
    }

    private struct HighlightCacheEntry {
        var code: String
        var value: NSAttributedString
        var cost: Int
        var lastUsed: UInt64
    }

    private var highlightCache: [HighlightCacheKey: HighlightCacheEntry] = [:]
    private var highlightTick: UInt64 = 0
    private var highlightCacheCost = 0
    /// Bounded by size as well as count. Forty-eight whole files was the old
    /// bound, and the editor added one per keystroke.
    private let highlightCacheBudget: Int
    private let highlightCacheCapacity: Int

    /// Approximate bytes: the attributed copy (UTF-16 plus attribute runs)
    /// and the code string kept for the equality check.
    static func highlightCost(of value: NSAttributedString, code: String) -> Int {
        value.length * 4 + code.utf8.count + 64
    }

    /// Entry count and approximate bytes held, for tests.
    var highlightCacheUsage: (count: Int, cost: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (highlightCache.count, highlightCacheCost)
    }

    private func cachedHighlight(for key: HighlightCacheKey, code: String) -> NSAttributedString? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = highlightCache[key], entry.code == code else { return nil }
        highlightTick += 1
        highlightCache[key]?.lastUsed = highlightTick
        return entry.value
    }

    private func storeHighlight(_ value: NSAttributedString, code: String, for key: HighlightCacheKey) {
        let cost = Self.highlightCost(of: value, code: code)
        lock.lock()
        defer { lock.unlock() }
        if let replaced = highlightCache.removeValue(forKey: key) {
            highlightCacheCost -= replaced.cost
        }
        // One snippet worth a large share of the budget would evict everything
        // else to make room, then be the next thing evicted.
        guard cost <= highlightCacheBudget / 4 else { return }
        highlightTick += 1
        highlightCache[key] = HighlightCacheEntry(code: code, value: value, cost: cost, lastUsed: highlightTick)
        highlightCacheCost += cost
        guard highlightCache.count > highlightCacheCapacity || highlightCacheCost > highlightCacheBudget
        else { return }
        // Least recently used first, down to three quarters so the next few
        // stores don't each pay for a sort.
        let targetCount = highlightCacheCapacity * 3 / 4
        let targetCost = highlightCacheBudget * 3 / 4
        for (staleKey, entry) in highlightCache.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            guard highlightCache.count > targetCount || highlightCacheCost > targetCost else { break }
            highlightCache.removeValue(forKey: staleKey)
            highlightCacheCost -= entry.cost
        }
    }

    private func renderHighlight(
        _ code: String,
        language rawLanguage: String?,
        font: NSFont,
        baseColor: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: code,
            attributes: [.font: font, .foregroundColor: baseColor]
        )
        guard !code.isEmpty else { return result }

        let name = Self.canonicalName(rawLanguage)
        if let name, applyTreeSitter(to: result, code: code, language: name) {
            return result
        }
        SyntaxPainter.paint(SyntaxLexer.tokens(for: code, language: name), into: result, font: font)
        return result
    }

    /// Colours `result` with a bundled grammar. False when there is no grammar
    /// for the language or it couldn't parse, so the caller can fall back.
    private func applyTreeSitter(to result: NSMutableAttributedString, code: String, language name: String) -> Bool {
        guard let loaded = loadLanguage(name), let query = loaded.query else { return false }
        let parser = Parser()
        guard (try? parser.setLanguage(loaded.language)) != nil, let tree = parser.parse(code) else { return false }

        let cursor = query.execute(in: tree)
        let utf16Length = code.utf16.count
        result.beginEditing()
        defer { result.endEditing() }
        while let match = cursor.next() {
            for capture in match.captures {
                guard let captureName = capture.name,
                      let color = SyntaxTheme.color(forCapture: captureName),
                      let range = Self.attributedRange(for: capture.node.byteRange, utf16Length: utf16Length)
                else { continue }
                result.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
        return true
    }

    /// Highlights one line, for the diff viewer.
    func highlightLine(
        _ line: String,
        language: String?,
        font: NSFont,
        baseColor: NSColor = .labelColor
    ) -> NSAttributedString {
        // A single diff line is rarely a complete parse unit, so tree-sitter
        // would produce errors more often than colour. The lexer needs no
        // context beyond the line, which is the honest tool at this granularity.
        let result = NSMutableAttributedString(
            string: line,
            attributes: [.font: font, .foregroundColor: baseColor]
        )
        guard !line.isEmpty else { return result }
        SyntaxPainter.paint(
            SyntaxLexer.tokens(for: line, language: Self.canonicalName(language)), into: result, font: font
        )
        return result
    }

    /// The language name for a fenced block's info string or a file extension.
    static func canonicalName(_ raw: String?) -> String? {
        LanguageRegistry.canonicalName(raw)
    }

    /// The language for a file, by well-known name (`Dockerfile`, `.zshrc`)
    /// and then by extension.
    static func language(forPath path: String) -> String? {
        LanguageRegistry.language(forPath: path)
    }

    static func language(forPath path: String, contents: String) -> String? {
        LanguageRegistry.language(forPath: path, contents: contents)
    }

    // MARK: - Loading

    private func loadLanguage(_ name: String) -> LoadedLanguage? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = languages[name] { return cached }
        guard let pointer = Self.grammar(named: name) else { return nil }

        let language = Language(language: pointer)
        // Each grammar ships its own `highlights.scm`, written against exactly
        // the node names that grammar produces. Preferring it means a grammar
        // update brings its query along; the inline fallback only covers the
        // case where the resource bundle didn't make it into the app.
        let query = HighlightQueries.bundled(for: name, language: language)
            ?? HighlightQueries.compiled(for: name, language: language)

        let loaded = LoadedLanguage(language: language, query: query)
        languages[name] = loaded
        return loaded
    }

    /// Converts a tree-sitter byte range into an `NSAttributedString` range.
    ///
    /// SwiftTreeSitter feeds the parser UTF-16 (`TSInputEncodingUTF16LE`), so
    /// tree-sitter's "byte" offsets are two per UTF-16 code unit — exactly what
    /// `NSAttributedString` indexes in, once halved. Reading them as UTF-8
    /// bytes instead makes every highlight twice as long as the token it
    /// belongs to, which looks like an off-by-one until you count.
    private static func attributedRange(
        for byteRange: Range<UInt32>,
        utf16Length: Int
    ) -> NSRange? {
        let start = Int(byteRange.lowerBound) / 2
        let end = Int(byteRange.upperBound) / 2
        guard start >= 0, start < end, end <= utf16Length else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

/// Applies lexer tokens to attributed text.
enum SyntaxPainter {
    static func paint(_ tokens: [SyntaxToken], into result: NSMutableAttributedString, font: NSFont) {
        guard !tokens.isEmpty else { return }
        let colors = SyntaxTheme.tokenColors
        let length = result.length
        var bold: NSFont?
        var italic: NSFont?

        // One editing session: without it every attribute change notifies
        // layout, which on a large file costs more than the lexing.
        result.beginEditing()
        defer { result.endEditing() }
        for token in tokens {
            let end = min(token.end, length)
            guard token.start < end else { continue }
            let range = NSRange(location: token.start, length: end - token.start)
            if let color = colors[Int(token.kind.rawValue)] {
                result.addAttribute(.foregroundColor, value: color, range: range)
            }
            switch token.kind {
            case .heading, .bold:
                if bold == nil { bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                result.addAttribute(.font, value: bold ?? font, range: range)
            case .italic:
                if italic == nil { italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                result.addAttribute(.font, value: italic ?? font, range: range)
            default:
                break
            }
        }
    }
}

/// Colours by capture name.
///
/// Capture names are tree-sitter's shared vocabulary (`@keyword`, `@string`,
/// `@function`), so one theme covers every grammar and the lexer. System
/// colours are used so the theme follows light and dark mode without a second
/// palette.
enum SyntaxTheme {
    static func color(forCapture capture: String) -> NSColor? {
        // Captures are dotted and specific-to-general: `keyword.function`
        // should fall back to `keyword`.
        var name = capture
        while true {
            if let color = table[name] { return color }
            guard let dot = name.lastIndex(of: ".") else { return nil }
            name = String(name[name.startIndex..<dot])
        }
    }

    /// The lexer's colours, resolved once per token kind rather than per token.
    static let tokenColors: [NSColor?] = SyntaxTokenKind.allCases.map { color(forCapture: $0.capture) }

    private static let table: [String: NSColor] = [
        "keyword": .systemPink,
        "conditional": .systemPink,
        "repeat": .systemPink,
        "include": .systemPink,
        "operator": .labelColor,
        "string": .systemRed,
        "string.escape": .systemOrange,
        // Regular expressions, heredoc markers, LaTeX math.
        "string.special": .systemBrown,
        "number": .systemPurple,
        "boolean": .systemPurple,
        "constant": .systemPurple,
        "comment": .secondaryLabelColor,
        "function": .systemBlue,
        "method": .systemBlue,
        "type": .systemTeal,
        "constructor": .systemTeal,
        "variable": .labelColor,
        // `self`/`this` read as keywords, as in Xcode.
        "variable.builtin": .systemPink,
        // Sigil variables: `$HOME`, `@name`, `--custom-property`.
        "variable.special": .systemIndigo,
        "property": .systemIndigo,
        "parameter": .labelColor,
        "punctuation": .tertiaryLabelColor,
        // Interpolation delimiters, list markers, fences.
        "punctuation.special": .systemOrange,
        "attribute": .systemOrange,
        "label": .systemOrange,
        "tag": .systemBlue,
        "markup.heading": .systemBlue,
        "markup.link": .systemIndigo,
        "markup.link.url": .systemTeal,
        "markup.raw": .systemRed,
        "markup.quote": .secondaryLabelColor,
        "diff.plus": .systemGreen,
        "diff.minus": .systemRed,
        "diff.hunk": .systemTeal,
        "diff.header": .systemPurple,
    ]
}

/// Highlight queries, bundled as source.
///
/// The grammar packages don't consistently ship `highlights.scm`, and pinning a
/// query to a grammar version is how a highlighter silently stops colouring
/// anything. These are small, cover the constructs that carry meaning when
/// skimming, and are compiled once per language.
enum HighlightQueries {
    /// The grammar package's own `highlights.scm`.
    ///
    /// SwiftPM puts a target's resources in a bundle named
    /// `<package>_<target>.bundle` beside the executable, so the app bundle has
    /// to carry those along — see `Scripts/bundle.sh`.
    static func bundled(for language: String, language object: Language) -> Query? {
        let moduleNames = [
            "swift": "TreeSitterSwift",
            "json": "TreeSitterJSON",
        ]
        guard let module = moduleNames[language] else { return nil }

        // Where the grammar bundles live depends on how the code was launched:
        // inside `Contents/Resources` for the app, beside the test binary when
        // running tests. Searching both means highlighting behaves the same in
        // both, rather than silently degrading to the lexer in one.
        let ownBundle = Bundle(for: SyntaxHighlighter.self)
        let searchRoots = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL.deletingLastPathComponent(),
            ownBundle.resourceURL,
            ownBundle.bundleURL.deletingLastPathComponent(),
        ].compactMap { $0 }

        for root in searchRoots {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil
            ) else { continue }

            for candidate in contents
            where candidate.pathExtension == "bundle" && candidate.lastPathComponent.contains(module) {
                let query = candidate
                    .appendingPathComponent("queries")
                    .appendingPathComponent("highlights.scm")
                guard let data = try? Data(contentsOf: query),
                      let compiled = try? Query(language: object, data: data)
                else { continue }
                return compiled
            }
        }
        return nil
    }

    static func compiled(for language: String, language object: Language) -> Query? {
        guard let source = source(for: language) else { return nil }
        return try? Query(language: object, data: Data(source.utf8))
    }

    static func source(for language: String) -> String? {
        switch language {
        case "swift": return swift
        case "json": return json
        default: return nil
        }
    }

    private static let swift = """
    (line_comment) @comment
    (multiline_comment) @comment
    (line_str_text) @string
    (str_escape) @string
    (integer_literal) @number
    (real_literal) @number
    (boolean_literal) @boolean
    (simple_identifier) @variable
    (type_identifier) @type
    (attribute) @attribute
    [
      "func" "let" "var" "if" "else" "guard" "return" "struct" "class" "enum"
      "protocol" "extension" "import" "for" "in" "while" "switch" "case"
      "throw" "throws" "try" "async" "await" "actor" "init" "self" "nil"
      "public" "private" "internal" "fileprivate" "static" "some" "any"
    ] @keyword
    (call_expression (simple_identifier) @function)
    (function_declaration (simple_identifier) @function)
    """

    private static let json = """
    (string) @string
    (number) @number
    [(true) (false) (null)] @boolean
    (pair key: (string) @property)
    """
}
