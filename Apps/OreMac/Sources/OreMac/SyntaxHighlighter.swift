import AppKit
import SwiftTreeSitter
import TreeSitterJSON
import TreeSitterSwift

/// Syntax highlighting for code blocks and diffs.
///
/// tree-sitter parses rather than pattern-matches, which is what makes it
/// correct on the things a regex highlighter gets wrong — a keyword inside a
/// string, a comment containing code, a generic parameter list. It is also
/// incremental, though ORE re-parses whole snippets: they are small, and the
/// diff viewer's unit of work is a hunk, not a file.
///
/// Any language without a bundled grammar falls back to a regex pass rather
/// than to nothing. Unhighlighted code in an app whose whole job is reading
/// code is a worse outcome than approximate highlighting.
final class SyntaxHighlighter: @unchecked Sendable {
    static let shared = SyntaxHighlighter()

    private let lock = NSLock()
    private var languages: [String: LoadedLanguage] = [:]

    private struct LoadedLanguage {
        var language: Language
        var query: Query?
    }

    /// Grammars bundled with the app, and the names people actually write in a
    /// fenced code block.
    ///
    /// Each grammar's C entry point returns an opaque `TSLanguage *`.
    private static func grammar(named name: String) -> OpaquePointer? {
        switch name {
        case "swift": return tree_sitter_swift()
        case "json": return tree_sitter_json()
        default: return nil
        }
    }

    private static let aliases: [String: String] = [
        "py": "python",
        "jsonc": "json",
        "js": "javascript",
        "jsx": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "ts": "javascript",
        "tsx": "javascript",
        "node": "javascript",
    ]

    // Only grammars whose SwiftPM manifest actually builds are bundled.
    //
    // Several official tree-sitter grammars (JavaScript, Python among them)
    // decide whether to compile their external scanner with
    // `FileManager.default.fileExists(atPath: "src/scanner.c")` — a path
    // relative to whoever is *consuming* the package, not to the package
    // itself. Consumed from another directory the test fails, the scanner is
    // skipped, and the link dies on undefined symbols. Vendoring a copy of a
    // generated parser to work around that is a maintenance burden that
    // outweighs the benefit, so those languages take the regex path — the same
    // degradation any unbundled language gets.

    /// Highlights a snippet. Returns plain attributed text when the language is
    /// unknown, so a caller never has to check.
    func highlight(
        _ code: String,
        language rawLanguage: String?,
        font: NSFont,
        baseColor: NSColor = .labelColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: code,
            attributes: [.font: font, .foregroundColor: baseColor]
        )
        guard !code.isEmpty else { return result }

        guard let name = Self.canonicalName(rawLanguage) else {
            RegexHighlighter.apply(to: result, language: nil)
            return result
        }
        guard let loaded = loadLanguage(name), let query = loaded.query else {
            RegexHighlighter.apply(to: result, language: name)
            return result
        }

        let parser = Parser()
        do {
            try parser.setLanguage(loaded.language)
        } catch {
            RegexHighlighter.apply(to: result, language: name)
            return result
        }

        guard let tree = parser.parse(code) else {
            RegexHighlighter.apply(to: result, language: name)
            return result
        }

        let cursor = query.execute(in: tree)
        let utf16Length = code.utf16.count

        while let match = cursor.next() {
            for capture in match.captures {
                guard let captureName = capture.name,
                      let color = SyntaxTheme.color(forCapture: captureName)
                else { continue }
                guard let range = Self.attributedRange(
                    for: capture.node.byteRange, utf16Length: utf16Length
                ) else { continue }
                result.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
        return result
    }

    /// Highlights one line, for the diff viewer.
    func highlightLine(
        _ line: String,
        language: String?,
        font: NSFont,
        baseColor: NSColor = .labelColor
    ) -> NSAttributedString {
        // A single diff line is rarely a complete parse unit, so tree-sitter
        // would produce errors more often than colour. The regex pass is the
        // honest tool at this granularity.
        let result = NSMutableAttributedString(
            string: line,
            attributes: [.font: font, .foregroundColor: baseColor]
        )
        RegexHighlighter.apply(to: result, language: Self.canonicalName(language))
        return result
    }

    /// The grammar name for a fenced block's info string or a file extension.
    static func canonicalName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // A fence can carry more than a language: ```swift title=foo.swift
        let first = raw.split(separator: " ").first.map(String.init) ?? raw
        let lowered = first.lowercased()
        return aliases[lowered] ?? lowered
    }

    static func language(forPath path: String) -> String? {
        canonicalName((path as NSString).pathExtension)
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

/// Colours by capture name.
///
/// Capture names are tree-sitter's shared vocabulary (`@keyword`, `@string`,
/// `@function`), so one theme covers every grammar. System colours are used so
/// the theme follows light and dark mode without a second palette.
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

    private static let table: [String: NSColor] = [
        "keyword": .systemPink,
        "conditional": .systemPink,
        "repeat": .systemPink,
        "include": .systemPink,
        "operator": .labelColor,
        "string": .systemRed,
        "number": .systemPurple,
        "boolean": .systemPurple,
        "constant": .systemPurple,
        "comment": .secondaryLabelColor,
        "function": .systemBlue,
        "method": .systemBlue,
        "type": .systemTeal,
        "constructor": .systemTeal,
        "variable": .labelColor,
        "property": .systemIndigo,
        "parameter": .labelColor,
        "punctuation": .tertiaryLabelColor,
        "attribute": .systemOrange,
        "label": .systemOrange,
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
        // both, rather than silently degrading to the regex pass in one.
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
        case "python": return python
        case "javascript": return javascript
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

    private static let python = """
    (comment) @comment
    (string) @string
    (integer) @number
    (float) @number
    [(true) (false) (none)] @boolean
    (identifier) @variable
    (call function: (identifier) @function)
    (function_definition name: (identifier) @function)
    (class_definition name: (identifier) @type)
    [
      "def" "class" "if" "elif" "else" "for" "while" "return" "import" "from"
      "as" "try" "except" "finally" "raise" "with" "lambda" "yield" "async"
      "await" "pass" "break" "continue" "in" "is" "not" "and" "or" "global"
    ] @keyword
    """

    private static let javascript = """
    (comment) @comment
    (string) @string
    (template_string) @string
    (number) @number
    [(true) (false) (null) (undefined)] @boolean
    (identifier) @variable
    (call_expression function: (identifier) @function)
    (function_declaration name: (identifier) @function)
    (class_declaration name: (identifier) @type)
    (property_identifier) @property
    [
      "function" "const" "let" "var" "if" "else" "for" "while" "return"
      "class" "extends" "new" "import" "from" "export" "default" "try"
      "catch" "finally" "throw" "async" "await" "yield" "typeof" "instanceof"
    ] @keyword
    """

    private static let json = """
    (string) @string
    (number) @number
    [(true) (false) (null)] @boolean
    (pair key: (string) @property)
    """
}

/// Fallback highlighting for languages without a bundled grammar.
///
/// Deliberately crude: strings, comments and a common keyword set. It exists so
/// that an unfamiliar language still reads as code rather than as a wall of
/// uniform text.
enum RegexHighlighter {
    private static let keywords: Set<String> = [
        "func", "function", "def", "class", "struct", "enum", "interface", "trait",
        "let", "var", "const", "val", "if", "else", "elif", "for", "while", "loop",
        "return", "import", "from", "package", "use", "using", "include", "require",
        "public", "private", "protected", "internal", "static", "final", "async",
        "await", "try", "catch", "except", "finally", "throw", "throws", "raise",
        "new", "delete", "null", "nil", "none", "true", "false", "self", "this",
        "match", "case", "switch", "break", "continue", "yield", "type", "impl",
    ]

    static func apply(to string: NSMutableAttributedString, language: String?) {
        let text = string.string
        guard !text.isEmpty else { return }

        applyPattern(#"(?m)(//|#).*$"#, color: .secondaryLabelColor, to: string, in: text)
        applyPattern(#"/\*[\s\S]*?\*/"#, color: .secondaryLabelColor, to: string, in: text)
        applyPattern(#""(?:[^"\\\n]|\\.)*""#, color: .systemRed, to: string, in: text)
        applyPattern(#"'(?:[^'\\\n]|\\.)*'"#, color: .systemRed, to: string, in: text)
        applyPattern(#"\b\d+(\.\d+)?\b"#, color: .systemPurple, to: string, in: text)

        guard let wordExpression = try? NSRegularExpression(pattern: #"\b[A-Za-z_]\w*\b"#)
        else { return }
        let whole = NSRange(text.startIndex..., in: text)

        for match in wordExpression.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text),
                  keywords.contains(String(text[range]))
            else { continue }
            // Comments and strings already claimed their ranges; a keyword
            // inside one must not be recoloured.
            guard !isClaimed(match.range, in: string) else { continue }
            string.addAttribute(.foregroundColor, value: NSColor.systemPink, range: match.range)
        }
    }

    private static func applyPattern(
        _ pattern: String,
        color: NSColor,
        to string: NSMutableAttributedString,
        in text: String
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let whole = NSRange(text.startIndex..., in: text)
        for match in expression.matches(in: text, range: whole) {
            guard !isClaimed(match.range, in: string) else { continue }
            string.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private static func isClaimed(_ range: NSRange, in string: NSMutableAttributedString) -> Bool {
        guard range.location < string.length else { return true }
        var claimed = false
        string.enumerateAttribute(.foregroundColor, in: range) { value, _, stop in
            guard let color = value as? NSColor else { return }
            if color != .labelColor {
                claimed = true
                stop.pointee = true
            }
        }
        return claimed
    }
}
