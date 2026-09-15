import Foundation

/// Lexers for languages that aren't a stream of words and operators: markup,
/// stylesheets, Markdown, YAML and diffs. Each is still one forward pass, and
/// hands embedded code (a `<script>`, a fenced block) back to `lex`.
extension SyntaxLexer {
    private static let commentOpen = Array("<!--".utf16)
    private static let commentClose = Array("-->".utf16)
    private static let cdataOpen = Array("<![CDATA[".utf16)
    private static let cdataClose = Array("]]>".utf16)
    private static let scriptName = Array("script".utf16)
    private static let styleName = Array("style".utf16)
    private static let scriptClose = Array("</script".utf16)
    private static let styleClose = Array("</style".utf16)
    private static let mustacheClose = Array("}}".utf16)

    /// The start of the next `pattern` at or after `from`, or nil.
    func find(_ pattern: [UInt16], from: Int, limit: Int, ignoringCase: Bool = false) -> Int? {
        guard let first = pattern.first else { return nil }
        var cursor = from
        while cursor + pattern.count <= limit {
            let unit = text[cursor]
            if unit == first || (ignoringCase && Unit.isUpper(unit) && unit + 32 == first) {
                if ignoringCase ? matchesIgnoringCase(pattern, at: cursor, limit: limit) : matches(pattern, at: cursor, limit: limit) {
                    return cursor
                }
            }
            cursor += 1
        }
        return nil
    }

    // MARK: - HTML, XML, Vue, Svelte

    mutating func scanMarkup(_ flavor: LanguageDefinition.MarkupFlavor, from: Int, to limit: Int) {
        var index = from
        while index < limit {
            let unit = text[index]
            if unit == 60 /* < */, index + 1 < limit {
                if matches(Self.commentOpen, at: index, limit: limit) {
                    let end = find(Self.commentClose, from: index + 4, limit: limit).map { $0 + 3 } ?? limit
                    emit(.comment, index, end)
                    index = end
                    continue
                }
                if matches(Self.cdataOpen, at: index, limit: limit) {
                    let end = find(Self.cdataClose, from: index + 9, limit: limit).map { $0 + 3 } ?? limit
                    emit(.string, index, end)
                    index = end
                    continue
                }
                let next = text[index + 1]
                if next == 33 /* ! */ {
                    index = scanDeclaration(at: index, limit: limit)
                    continue
                }
                if next == 63 /* ? */ || next == 47 || Unit.isLetter(next) {
                    index = scanTag(flavor, at: index, limit: limit)
                    continue
                }
            } else if unit == 38 /* & */ {
                var cursor = index + 1
                while cursor < limit, cursor - index < 32, Unit.isWord(text[cursor]) || text[cursor] == 35 { cursor += 1 }
                if cursor < limit, cursor > index + 1, text[cursor] == 59 {
                    emit(.stringEscape, index, cursor + 1)
                    index = cursor + 1
                    continue
                }
            } else if unit == 123 /* { */, flavor == .vue || flavor == .svelte {
                if let end = scanTemplateExpression(flavor, at: index, limit: limit) {
                    index = end
                    continue
                }
            }
            index += 1
        }
    }

    /// `<!DOCTYPE html>` and friends.
    private mutating func scanDeclaration(at index: Int, limit: Int) -> Int {
        var cursor = index + 2
        let nameStart = cursor
        while cursor < limit, Unit.isWord(text[cursor]) { cursor += 1 }
        emit(.punctuation, index, nameStart)
        emit(.keyword, nameStart, cursor)
        while cursor < limit, text[cursor] != 62 {
            if text[cursor] == Unit.quote {
                let end = (find([Unit.quote], from: cursor + 1, limit: limit) ?? limit - 1) + 1
                emit(.string, cursor, end)
                cursor = end
            } else {
                cursor += 1
            }
        }
        guard cursor < limit else { return limit }
        emit(.punctuation, cursor, cursor + 1)
        return cursor + 1
    }

    private mutating func scanTag(_ flavor: LanguageDefinition.MarkupFlavor, at index: Int, limit: Int) -> Int {
        var cursor = index + 1
        let closing = text[cursor] == 47
        let instruction = text[cursor] == 63
        if closing || instruction { cursor += 1 }
        guard cursor < limit, Unit.isLetter(text[cursor]) || text[cursor] == 95 else { return index + 1 }
        let nameStart = cursor
        while cursor < limit, Unit.isWord(text[cursor]) || text[cursor] == 45 || text[cursor] == 58 || text[cursor] == 46 {
            cursor += 1
        }
        let nameEnd = cursor
        let component = flavor != .html && flavor != .xml && Unit.isUpper(text[nameStart])
        emit(.punctuation, index, nameStart)
        emit(component ? .type : .tag, nameStart, nameEnd)

        var languageHint: (Int, Int)?
        var selfClosing = false
        while cursor < limit {
            let unit = text[cursor]
            if Unit.isBlank(unit) || unit == Unit.newline {
                cursor += 1
                continue
            }
            if unit == 62 {
                emit(.punctuation, cursor, cursor + 1)
                cursor += 1
                break
            }
            if (unit == 47 || unit == 63), cursor + 1 < limit, text[cursor + 1] == 62 {
                emit(.punctuation, cursor, cursor + 2)
                cursor += 2
                selfClosing = true
                break
            }
            // A new tag before this one closed: the markup is unfinished (or
            // being typed); stop here rather than swallow it.
            if unit == 60 { return cursor }
            if flavor == .svelte || flavor == .vue, unit == 123,
               let end = matchingClose(from: cursor, open: 123, close: 125, limit: limit) {
                lex(LanguageRegistry.definition(for: "javascript"), from: cursor + 1, to: end - 1)
                cursor = end
                continue
            }

            let attributeStart = cursor
            while cursor < limit {
                let character = text[cursor]
                if Unit.isBlank(character) || character == Unit.newline || character == 61 || character == 62
                    || character == 47 || character == Unit.quote || character == Unit.apostrophe || character == 60 {
                    break
                }
                cursor += 1
            }
            if cursor == attributeStart {
                cursor += 1
                continue
            }
            emit(.attribute, attributeStart, cursor)
            let attributeLength = cursor - attributeStart
            let isHint = (attributeLength == 4 && matchesIgnoringCase(Array("lang".utf16), at: attributeStart, limit: cursor))
                || (attributeLength == 4 && matchesIgnoringCase(Array("type".utf16), at: attributeStart, limit: cursor))
            // Vue's `:prop`, `@event` and `v-*` values are expressions.
            let first = text[attributeStart]
            let expression = flavor == .vue && (first == 58 || first == 64 || first == 35
                || (attributeLength > 2 && text[attributeStart] == 118 && text[attributeStart + 1] == 45))

            var valueStart = skipBlanks(from: cursor, limit: limit)
            guard valueStart < limit, text[valueStart] == 61 else { continue }
            valueStart = skipBlanks(from: valueStart + 1, limit: limit)
            guard valueStart < limit else { cursor = limit; break }
            let quote = text[valueStart]
            if quote == Unit.quote || quote == Unit.apostrophe {
                let close = find([quote], from: valueStart + 1, limit: limit) ?? (limit - 1)
                if expression {
                    emit(.punctuation, valueStart, valueStart + 1)
                    lex(LanguageRegistry.definition(for: "javascript"), from: valueStart + 1, to: close)
                    emit(.punctuation, close, close + 1)
                } else {
                    emit(.string, valueStart, close + 1)
                }
                if isHint { languageHint = (valueStart + 1, close) }
                cursor = close + 1
            } else if quote == 123, let end = matchingClose(from: valueStart, open: 123, close: 125, limit: limit) {
                lex(LanguageRegistry.definition(for: "javascript"), from: valueStart + 1, to: end - 1)
                cursor = end
            } else {
                var end = valueStart
                while end < limit, !Unit.isBlank(text[end]), text[end] != Unit.newline, text[end] != 62 { end += 1 }
                emit(.string, valueStart, end)
                if isHint { languageHint = (valueStart, end) }
                cursor = end
            }
        }

        guard !closing, !selfClosing, !instruction, flavor != .xml, cursor < limit else { return cursor }
        let nameLength = nameEnd - nameStart
        let isScript = nameLength == 6 && matchesIgnoringCase(Self.scriptName, at: nameStart, limit: nameEnd)
        let isStyle = nameLength == 5 && matchesIgnoringCase(Self.styleName, at: nameStart, limit: nameEnd)
        guard isScript || isStyle else { return cursor }

        let hint = languageHint.map { String(utf16CodeUnits: Array(text[$0.0..<$0.1]), count: $0.1 - $0.0).lowercased() }
        let bodyEnd = find(isScript ? Self.scriptClose : Self.styleClose, from: cursor, limit: limit, ignoringCase: true) ?? limit
        let language = isScript ? Self.scriptLanguage(hint) : Self.styleLanguage(hint)
        lex(LanguageRegistry.definition(for: language), from: cursor, to: bodyEnd)
        return bodyEnd
    }

    private static func scriptLanguage(_ hint: String?) -> String {
        guard let hint, !hint.isEmpty else { return "javascript" }
        if hint == "ts" || hint.contains("typescript") { return "typescript" }
        if hint == "tsx" { return "tsx" }
        if hint == "jsx" { return "jsx" }
        if hint.contains("json") || hint == "importmap" { return "jsonc" }
        if hint == "module" || hint.contains("javascript") || hint.contains("ecmascript") || hint == "js" {
            return "javascript"
        }
        return "text"
    }

    private static func styleLanguage(_ hint: String?) -> String {
        switch hint {
        case "scss": "scss"
        case "sass": "sass"
        case "less": "less"
        default: "css"
        }
    }

    /// `{{ expr }}` in Vue templates, `{expr}` / `{#if cond}` in Svelte.
    private mutating func scanTemplateExpression(_ flavor: LanguageDefinition.MarkupFlavor, at index: Int, limit: Int) -> Int? {
        let javascript = LanguageRegistry.definition(for: "javascript")
        if flavor == .vue {
            guard index + 1 < limit, text[index + 1] == 123,
                  let close = find(Self.mustacheClose, from: index + 2, limit: limit) else { return nil }
            emit(.punctuationSpecial, index, index + 2)
            lex(javascript, from: index + 2, to: close)
            emit(.punctuationSpecial, close, close + 2)
            return close + 2
        }
        guard let end = matchingClose(from: index, open: 123, close: 125, limit: limit) else { return nil }
        var body = index + 1
        emit(.punctuationSpecial, index, body)
        if body < end - 1, [35, 47, 58, 64].contains(text[body]) {
            var word = body + 1
            while word < end - 1, Unit.isWord(text[word]) { word += 1 }
            emit(.keyword, body, word)
            body = word
        }
        lex(javascript, from: body, to: end - 1)
        emit(.punctuationSpecial, end - 1, end)
        return end
    }

    // MARK: - CSS, SCSS, Sass, Less

    private enum StyleMode { case statement, selector, property, value }

    mutating func scanCSS(_ flavor: LanguageDefinition.CSSFlavor, from: Int, to limit: Int) {
        var mode = StyleMode.statement
        var index = from
        let lineComments = flavor != .css
        let indented = flavor == .sass

        while index < limit {
            let unit = text[index]
            let next: UInt16 = index + 1 < limit ? text[index + 1] : 0
            if unit == Unit.newline {
                if indented { mode = .statement }
                index += 1
                continue
            }
            if Unit.isBlank(unit) { index += 1; continue }
            if unit == 47, next == 42 {
                let end = find([42, 47], from: index + 2, limit: limit).map { $0 + 2 } ?? limit
                emit(.comment, index, end)
                index = end
                continue
            }
            if lineComments, unit == 47, next == 47, index == from || text[index - 1] != 58 {
                let end = lineEnd(from: index, limit: limit)
                emit(.comment, index, end)
                index = end
                continue
            }
            if unit == Unit.quote || unit == Unit.apostrophe {
                var end = index + 1
                while end < limit, text[end] != unit, text[end] != Unit.newline {
                    end += text[end] == Unit.backslash ? 2 : 1
                }
                end = min(limit, end + 1)
                emit(.string, index, end)
                index = end
                continue
            }
            if unit == 35, next == 123, let end = matchingClose(from: index + 1, open: 123, close: 125, limit: limit) {
                emit(.punctuationSpecial, index, end)
                index = end
                continue
            }

            switch mode {
            case .statement:
                if unit == 125 || unit == 59 || unit == 123 {
                    index += 1
                } else if unit == 64 /* @ */, Unit.isLetter(next) {
                    var end = index + 1
                    while end < limit, Unit.isWord(text[end]) || text[end] == 45 { end += 1 }
                    let variableDeclaration = flavor == .less && skipBlanks(from: end, limit: limit) < limit
                        && text[skipBlanks(from: end, limit: limit)] == 58
                    emit(variableDeclaration ? .variableSpecial : .keyword, index, end)
                    mode = .value
                    index = end
                } else {
                    mode = styleStatementMode(at: index, limit: limit, indented: indented)
                }

            case .selector:
                switch unit {
                case 123:
                    mode = .statement
                    index += 1
                case 125, 59:
                    mode = .statement
                    index += 1
                case 46, 35, 37, 58:
                    var end = index + 1
                    if unit == 58, next == 58 { end += 1 }
                    if end < limit, Unit.isLetter(text[end]) || text[end] == 45 || text[end] == 95 {
                        while end < limit, Unit.isWord(text[end]) || text[end] == 45 { end += 1 }
                        let kind: SyntaxTokenKind = switch unit {
                        case 46, 37: .type
                        case 35: .label
                        default: .attribute
                        }
                        emit(kind, index, end)
                        index = end
                    } else {
                        index += 1
                    }
                case 91:
                    var end = index + 1
                    while end < limit, Unit.isWord(text[end]) || text[end] == 45 { end += 1 }
                    emit(.attribute, index + 1, end)
                    index = end
                case 38:
                    emit(.punctuationSpecial, index, index + 1)
                    index += 1
                default:
                    if Unit.isLetter(unit) {
                        var end = index + 1
                        while end < limit, Unit.isWord(text[end]) || text[end] == 45 { end += 1 }
                        emit(.tag, index, end)
                        index = end
                    } else {
                        index += 1
                    }
                }

            case .property:
                if unit == 58 {
                    mode = .value
                    index += 1
                } else if unit == 59 || unit == 125 || unit == 123 {
                    mode = .statement
                    index += 1
                } else if unit == 36 || unit == 64 {
                    var end = index + 1
                    while end < limit, Unit.isWord(text[end]) || text[end] == 45 { end += 1 }
                    emit(.variableSpecial, index, end)
                    index = end
                } else if Unit.isLetter(unit) || unit == 45 || unit == 95 {
                    var end = index + 1
                    while end < limit, Unit.isWord(text[end]) || text[end] == 45 { end += 1 }
                    emit(.property, index, end)
                    index = end
                } else {
                    index += 1
                }

            case .value:
                if unit == 59 || unit == 125 || unit == 123 {
                    mode = .statement
                    index += 1
                } else if unit == 33, Unit.isLetter(next) {
                    var end = index + 1
                    while end < limit, Unit.isLetter(text[end]) { end += 1 }
                    emit(.keyword, index, end)
                    index = end
                } else if Unit.isDigit(unit) || (unit == 46 && Unit.isDigit(next))
                            || ((unit == 45 || unit == 43) && (Unit.isDigit(next) || next == 46)
                                && (index == from || !Unit.isWord(text[index - 1]))) {
                    var end = index + 1
                    while end < limit, Unit.isDigit(text[end]) || text[end] == 46 { end += 1 }
                    while end < limit, Unit.isLetter(text[end]) || text[end] == 37 { end += 1 }
                    emit(.number, index, end)
                    index = end
                } else if unit == 35, Unit.isHexDigit(next) {
                    var end = index + 1
                    while end < limit, Unit.isWord(text[end]) { end += 1 }
                    emit(.number, index, end)
                    index = end
                } else if unit == 36 || unit == 64 {
                    var end = index + 1
                    while end < limit, Unit.isWord(text[end]) || text[end] == 45 { end += 1 }
                    emit(.variableSpecial, index, end)
                    index = end
                } else if Unit.isLetter(unit) || unit == 45 || unit == 95 {
                    var end = index + 1
                    while end < limit, Unit.isWord(text[end]) || text[end] == 45 { end += 1 }
                    if end < limit, text[end] == 40 {
                        emit(.function, index, end)
                        if end - index == 3, matchesIgnoringCase(Array("url".utf16), at: index, limit: end),
                           let close = find([41], from: end + 1, limit: lineEnd(from: end, limit: limit)) {
                            emit(.string, end + 1, close)
                            end = close
                        }
                    } else if end - index > 2, text[index] == 45, text[index + 1] == 45 {
                        emit(.variableSpecial, index, end)
                    } else {
                        emit(.constant, index, end)
                    }
                    index = end
                } else {
                    index += 1
                }
            }
        }
    }

    /// Whether the statement at `index` is a selector (`a:hover {`) or a
    /// declaration (`color: red;`), decided by which terminator comes first.
    /// Each statement is looked ahead over once, so the pass stays linear.
    private func styleStatementMode(at index: Int, limit: Int, indented: Bool) -> StyleMode {
        var cursor = index
        var sawColonSpace = false
        while cursor < limit {
            let unit = text[cursor]
            switch unit {
            case 123:
                if cursor > index, text[cursor - 1] == 35 { break }
                return .selector
            case 59, 125:
                return .property
            case 58:
                if cursor + 1 >= limit || Unit.isBlank(text[cursor + 1]) || text[cursor + 1] == Unit.newline {
                    sawColonSpace = true
                }
            case Unit.newline where indented:
                return sawColonSpace ? .property : .selector
            case Unit.quote, Unit.apostrophe:
                while cursor + 1 < limit, text[cursor + 1] != unit, text[cursor + 1] != Unit.newline { cursor += 1 }
                cursor += 1
            default:
                break
            }
            cursor += 1
        }
        return sawColonSpace ? .property : .selector
    }

    // MARK: - Markdown

    mutating func scanMarkdown(from: Int, to limit: Int) {
        var lineStart = from
        if from == 0, lineEnd(from: 0, limit: limit) == 3, matches(Array("---".utf16), at: 0, limit: limit) {
            // YAML front matter.
            var scan = 4
            while scan < limit {
                let end = lineEnd(from: scan, limit: limit)
                if end - scan == 3, matches(Array("---".utf16), at: scan, limit: end) {
                    emit(.punctuationSpecial, 0, 3)
                    lex(LanguageRegistry.definition(for: "yaml"), from: 4, to: scan)
                    emit(.punctuationSpecial, scan, end)
                    lineStart = end + 1
                    break
                }
                scan = end + 1
            }
        }

        while lineStart < limit {
            let end = lineEnd(from: lineStart, limit: limit)
            var cursor = lineStart
            while cursor < end, cursor - lineStart < 3, text[cursor] == Unit.space { cursor += 1 }
            let unit: UInt16 = cursor < end ? text[cursor] : 0

            if unit == 96 || unit == 126, let next = scanFence(at: cursor, lineEnd: end, limit: limit) {
                lineStart = next
                continue
            }
            if unit == 35 {
                var hashes = cursor
                while hashes < end, text[hashes] == 35 { hashes += 1 }
                if hashes - cursor <= 6, hashes == end || Unit.isBlank(text[hashes]) {
                    emit(.heading, cursor, end)
                    lineStart = end + 1
                    continue
                }
            }
            if unit == 45 || unit == 42 || unit == 95 || unit == 61 {
                var count = 0
                var uniform = true
                for position in cursor..<end {
                    if text[position] == unit { count += 1 } else if !Unit.isBlank(text[position]) { uniform = false; break }
                }
                if uniform, count >= 3 || (unit == 61 && count >= 1) {
                    emit(.punctuationSpecial, cursor, end)
                    lineStart = end + 1
                    continue
                }
            }

            var inline = cursor
            var quoted = false
            while inline < end, text[inline] == 62 {
                emit(.punctuationSpecial, inline, inline + 1)
                quoted = true
                inline = skipBlanks(from: inline + 1, limit: end)
            }
            if quoted { emit(.quote, inline, end) }
            inline = skipBlanks(from: inline, limit: end)
            if inline < end {
                let marker = text[inline]
                if (marker == 45 || marker == 42 || marker == 43), inline + 1 == end || Unit.isBlank(text[inline + 1]) {
                    emit(.punctuationSpecial, inline, inline + 1)
                    inline = skipBlanks(from: inline + 1, limit: end)
                    if inline + 2 < end, text[inline] == 91, text[inline + 2] == 93 {
                        emit(.punctuationSpecial, inline, inline + 3)
                        inline += 3
                    }
                } else if Unit.isDigit(marker) {
                    var digits = inline
                    while digits < end, Unit.isDigit(text[digits]) { digits += 1 }
                    if digits < end, text[digits] == 46 || text[digits] == 41,
                       digits + 1 == end || Unit.isBlank(text[digits + 1]) {
                        emit(.punctuationSpecial, inline, digits + 1)
                        inline = digits + 1
                    }
                }
            }
            let table = inline < end && text[inline] == 124
            lineStart = scanMarkdownInline(from: inline, lineEnd: end, limit: limit, table: table)
        }
    }

    /// A fenced block. The contents are lexed as the fence's language when
    /// the lexer knows it. Returns the start of the line after the fence.
    private mutating func scanFence(at cursor: Int, lineEnd end: Int, limit: Int) -> Int? {
        let fence = text[cursor]
        var run = cursor
        while run < end, text[run] == fence { run += 1 }
        let length = run - cursor
        guard length >= 3 else { return nil }
        let infoStart = skipBlanks(from: run, limit: end)
        var infoEnd = end
        while infoEnd > infoStart, Unit.isBlank(text[infoEnd - 1]) { infoEnd -= 1 }
        // A backtick fence's info string can't contain backticks; otherwise
        // this is inline code spanning a line.
        if fence == 96, find([96], from: infoStart, limit: infoEnd) != nil { return nil }
        emit(.punctuationSpecial, cursor, run)
        emit(.label, infoStart, infoEnd)

        let bodyStart = min(end + 1, limit)
        var scan = bodyStart
        var bodyEnd = limit
        var after = limit
        var closing: (Int, Int)?
        while scan < limit {
            let lineEnd = self.lineEnd(from: scan, limit: limit)
            var closeStart = scan
            while closeStart < lineEnd, closeStart - scan < 3, text[closeStart] == Unit.space { closeStart += 1 }
            var closeRun = closeStart
            while closeRun < lineEnd, text[closeRun] == fence { closeRun += 1 }
            if closeRun - closeStart >= length, skipBlanks(from: closeRun, limit: lineEnd) == lineEnd {
                bodyEnd = scan
                closing = (closeStart, closeRun)
                after = lineEnd + 1
                break
            }
            scan = lineEnd + 1
        }

        if infoEnd > infoStart {
            let info = String(utf16CodeUnits: Array(text[infoStart..<infoEnd]), count: infoEnd - infoStart)
            if let name = LanguageRegistry.canonicalName(info), LanguageRegistry.hasDefinition(name) {
                lex(LanguageRegistry.definition(for: name), from: bodyStart, to: bodyEnd)
            }
        }
        if let closing { emit(.punctuationSpecial, closing.0, closing.1) }
        return after
    }

    /// Inline Markdown on one line. Returns where the next line starts, which
    /// is further on when an HTML comment spans lines.
    private mutating func scanMarkdownInline(from: Int, lineEnd end: Int, limit: Int, table: Bool) -> Int {
        var index = from
        while index < end {
            let unit = text[index]
            let next: UInt16 = index + 1 < end ? text[index + 1] : 0
            switch unit {
            case Unit.backslash where next > 32 && next < 127 && !Unit.isWord(next):
                emit(.stringEscape, index, index + 2)
                index += 2
            case 96:
                var run = index
                while run < end, text[run] == 96 { run += 1 }
                let length = run - index
                var close = run
                var found = false
                while close < end {
                    if text[close] == 96 {
                        var closeRun = close
                        while closeRun < end, text[closeRun] == 96 { closeRun += 1 }
                        if closeRun - close == length { found = true; close = closeRun; break }
                        close = closeRun
                    } else {
                        close += 1
                    }
                }
                if found { emit(.raw, index, close); index = close } else { index = run }
            case 42, 95:
                var run = index
                while run < end, run - index < 3, text[run] == unit { run += 1 }
                let length = run - index
                let intraword = unit == 95 && index > from && Unit.isWord(text[index - 1])
                guard !intraword, run < end, !Unit.isBlank(text[run]) else { index = run; continue }
                let marker = [UInt16](repeating: unit, count: length)
                var search = run
                var closed: Int?
                while let candidate = find(marker, from: search, limit: end) {
                    if !Unit.isBlank(text[candidate - 1]) { closed = candidate; break }
                    search = candidate + length
                }
                if let closed {
                    emit(length == 1 ? .italic : .bold, index, closed + length)
                    index = closed + length
                } else {
                    index = run
                }
            case 126 where next == 126:
                if let close = find([126, 126], from: index + 2, limit: end) {
                    emit(.quote, index, close + 2)
                    index = close + 2
                } else {
                    index += 2
                }
            case 91:
                index = scanMarkdownLink(at: index, lineStart: from, lineEnd: end)
            case 60:
                if matches(Self.commentOpen, at: index, limit: limit) {
                    let close = find(Self.commentClose, from: index + 4, limit: limit).map { $0 + 3 } ?? limit
                    emit(.comment, index, close)
                    if close > end { return close >= limit ? limit : lineEnd(from: close, limit: limit) + 1 }
                    index = close
                } else if let close = find([62], from: index + 1, limit: end),
                          matches(Array("http".utf16), at: index + 1, limit: close) {
                    emit(.linkURL, index, close + 1)
                    index = close + 1
                } else {
                    index += 1
                }
            case 104 where index == from || !Unit.isWord(text[index - 1]):
                if matches(Array("https://".utf16), at: index, limit: end) || matches(Array("http://".utf16), at: index, limit: end) {
                    var close = index
                    while close < end, !Unit.isBlank(text[close]), text[close] != 41, text[close] != 62 { close += 1 }
                    emit(.linkURL, index, close)
                    index = close
                } else {
                    index += 1
                }
            case 124 where table:
                emit(.punctuationSpecial, index, index + 1)
                index += 1
            default:
                index += 1
            }
        }
        return end + 1
    }

    /// `[text](url)`, `[text][ref]`, and `[ref]: url` definitions.
    private mutating func scanMarkdownLink(at index: Int, lineStart: Int, lineEnd end: Int) -> Int {
        var depth = 0
        var close = index
        while close < end {
            if text[close] == 91 { depth += 1 } else if text[close] == 93 {
                depth -= 1
                if depth == 0 { break }
            }
            close += 1
        }
        guard close < end else { return index + 1 }
        let textStart = index > lineStart && text[index - 1] == 33 ? index - 1 : index
        let after = close + 1
        if after < end, text[after] == 40, let paren = find([41], from: after + 1, limit: end) {
            emit(.link, textStart, after)
            emit(.linkURL, after, paren + 1)
            return paren + 1
        }
        if after < end, text[after] == 91, let bracket = find([93], from: after + 1, limit: end) {
            emit(.link, textStart, after)
            emit(.label, after, bracket + 1)
            return bracket + 1
        }
        if after < end, text[after] == 58, index == lineStart {
            emit(.label, index, after + 1)
            emit(.linkURL, skipBlanks(from: after + 1, limit: end), end)
            return end
        }
        return index + 1
    }

    // MARK: - YAML

    mutating func scanYAML(from: Int, to limit: Int) {
        var lineStart = from
        var blockScalarParent: Int?

        while lineStart < limit {
            let end = lineEnd(from: lineStart, limit: limit)
            var cursor = lineStart
            while cursor < end, text[cursor] == Unit.space || text[cursor] == Unit.tab { cursor += 1 }
            let indent = cursor - lineStart

            if let parent = blockScalarParent {
                if skipBlanks(from: cursor, limit: end) == end {
                    lineStart = end + 1
                    continue
                }
                if indent > parent {
                    emit(.string, cursor, end)
                    lineStart = end + 1
                    continue
                }
                blockScalarParent = nil
            }
            guard cursor < end else { lineStart = end + 1; continue }

            if text[cursor] == 35 {
                emit(.comment, cursor, end)
                lineStart = end + 1
                continue
            }
            if indent == 0, text[cursor] == 37 {
                emit(.keyword, cursor, end)
                lineStart = end + 1
                continue
            }
            if indent == 0, end - cursor >= 3,
               matches(Array("---".utf16), at: cursor, limit: end) || matches(Array("...".utf16), at: cursor, limit: end),
               cursor + 3 == end || Unit.isBlank(text[cursor + 3]) {
                emit(.punctuationSpecial, cursor, cursor + 3)
                cursor += 3
            }
            while cursor < end, text[cursor] == 45 || text[cursor] == 63,
                  cursor + 1 == end || Unit.isBlank(text[cursor + 1]) {
                emit(.punctuationSpecial, cursor, cursor + 1)
                cursor = skipBlanks(from: cursor + 1, limit: end)
            }
            let keyColumn = cursor - lineStart
            var hasKey = false
            if let colon = yamlKeyColon(from: cursor, limit: end, flow: false) {
                hasKey = true
                var keyEnd = colon
                while keyEnd > cursor, Unit.isBlank(text[keyEnd - 1]) { keyEnd -= 1 }
                emit(.property, cursor, keyEnd)
                cursor = colon + 1
            }
            if scanYAMLValue(from: cursor, limit: end) {
                // Content belongs to the scalar while it's indented past the
                // key that opened it (or past the line, for `- |`).
                blockScalarParent = hasKey ? keyColumn : indent
            }
            lineStart = end + 1
        }
    }

    /// The `:` ending a mapping key that starts at `from`, if there is one.
    private func yamlKeyColon(from: Int, limit: Int, flow: Bool) -> Int? {
        guard from < limit else { return nil }
        var cursor = from
        let first = text[cursor]
        if first == Unit.quote || first == Unit.apostrophe {
            guard let close = find([first], from: cursor + 1, limit: limit) else { return nil }
            cursor = skipBlanks(from: close + 1, limit: limit)
            guard cursor < limit, text[cursor] == 58 else { return nil }
            return cursor
        }
        if [35, 38, 42, 33, 124, 62, 91, 123, 37, 64, 96].contains(first) { return nil }
        while cursor < limit {
            let unit = text[cursor]
            if unit == 58, cursor + 1 == limit || Unit.isBlank(text[cursor + 1])
                || (flow && (text[cursor + 1] == 44 || text[cursor + 1] == 125)) {
                return cursor
            }
            if unit == 35, cursor > from, Unit.isBlank(text[cursor - 1]) { return nil }
            if flow, unit == 44 || unit == 123 || unit == 125 || unit == 91 || unit == 93 { return nil }
            cursor += 1
        }
        return nil
    }

    /// Lexes a value to the end of the line. Returns true when it opens a
    /// block scalar (`|` or `>`), whose indented lines follow as string.
    private mutating func scanYAMLValue(from: Int, limit: Int) -> Bool {
        var cursor = skipBlanks(from: from, limit: limit)
        var flowDepth = 0
        while cursor < limit {
            let unit = text[cursor]
            if Unit.isBlank(unit) { cursor += 1; continue }
            if unit == 35, cursor == from || Unit.isBlank(text[cursor - 1]) {
                emit(.comment, cursor, limit)
                return false
            }
            switch unit {
            case 38, 42 where cursor + 1 < limit && !Unit.isBlank(text[cursor + 1]):
                var end = cursor + 1
                while end < limit, !Unit.isBlank(text[end]), ![44, 91, 93, 123, 125].contains(text[end]) { end += 1 }
                emit(.label, cursor, end)
                cursor = end
            case 33:
                var end = cursor + 1
                while end < limit, !Unit.isBlank(text[end]) { end += 1 }
                emit(.type, cursor, end)
                cursor = end
            case 124, 62 where flowDepth == 0:
                var end = cursor + 1
                while end < limit, text[end] == 45 || text[end] == 43 || Unit.isDigit(text[end]) { end += 1 }
                let rest = skipBlanks(from: end, limit: limit)
                guard rest == limit || text[rest] == 35 else { fallthrough }
                emit(.punctuationSpecial, cursor, end)
                if rest < limit { emit(.comment, rest, limit) }
                return true
            case Unit.quote, Unit.apostrophe:
                var end = cursor + 1
                while end < limit {
                    if unit == Unit.quote, text[end] == Unit.backslash { end += 2; continue }
                    if text[end] == unit {
                        if unit == Unit.apostrophe, end + 1 < limit, text[end + 1] == unit { end += 2; continue }
                        break
                    }
                    end += 1
                }
                end = min(end + 1, limit)
                if flowDepth > 0, let colon = yamlKeyColon(from: cursor, limit: limit, flow: true), colon >= end - 1 {
                    emit(.property, cursor, end)
                } else {
                    emit(.string, cursor, end)
                }
                cursor = end
            case 91, 123:
                flowDepth += 1
                emit(.punctuation, cursor, cursor + 1)
                cursor += 1
            case 93, 125:
                flowDepth = max(0, flowDepth - 1)
                emit(.punctuation, cursor, cursor + 1)
                cursor += 1
            case 44 where flowDepth > 0:
                emit(.punctuation, cursor, cursor + 1)
                cursor += 1
            default:
                if flowDepth > 0, let colon = yamlKeyColon(from: cursor, limit: limit, flow: true) {
                    emit(.property, cursor, colon)
                    cursor = colon + 1
                    continue
                }
                var end = cursor
                while end < limit {
                    let character = text[end]
                    if character == 35, Unit.isBlank(text[end - 1]) { break }
                    if flowDepth > 0, [44, 91, 93, 123, 125].contains(character) { break }
                    end += 1
                }
                var trimmed = end
                while trimmed > cursor, Unit.isBlank(text[trimmed - 1]) { trimmed -= 1 }
                emit(yamlScalarKind(from: cursor, to: trimmed), cursor, trimmed)
                cursor = end
            }
        }
        return false
    }

    private static let yamlConstants: WordTable = {
        var table = WordTable(caseInsensitive: true)
        table.insert(["true", "false", "yes", "no", "on", "off", "null", "~", ".inf", "-.inf", ".nan"], as: .constantBuiltin)
        return table
    }()

    private func yamlScalarKind(from: Int, to end: Int) -> SyntaxTokenKind {
        if Self.yamlConstants.lookup(text, from, end) != nil { return .constantBuiltin }
        var cursor = from
        if cursor < end, text[cursor] == 45 || text[cursor] == 43 { cursor += 1 }
        guard cursor < end, Unit.isDigit(text[cursor]) || (text[cursor] == 46 && cursor + 1 < end) else { return .string }
        for position in cursor..<end {
            let unit = text[position]
            guard Unit.isHexDigit(unit) || unit == 46 || unit == 95 || unit == 120 || unit == 111
                    || unit == 43 || unit == 45 else { return .string }
        }
        return .number
    }

    // MARK: - Diff

    private static let diffHeaders: [[UInt16]] = [
        "diff ", "index ", "+++ ", "new file mode", "deleted file mode", "similarity index", "rename from",
        "rename to", "old mode", "new mode", "Binary files", "Only in",
    ].map { Array($0.utf16) }
    private static let minusHeader = Array("--- ".utf16)
    private static let plusHeader = Array("+++ ".utf16)

    mutating func scanDiff(from: Int, to limit: Int) {
        var lineStart = from
        while lineStart < limit {
            let end = lineEnd(from: lineStart, limit: limit)
            defer { lineStart = end + 1 }
            guard end > lineStart else { continue }
            let unit = text[lineStart]
            if Self.diffHeaders.contains(where: { matches($0, at: lineStart, limit: end) })
                || (matches(Self.minusHeader, at: lineStart, limit: end) && matches(Self.plusHeader, at: end + 1, limit: limit)) {
                emit(.diffHeader, lineStart, end)
            } else if unit == 64, end - lineStart > 1, text[lineStart + 1] == 64 {
                let close = find([64, 64], from: lineStart + 2, limit: end).map { $0 + 2 } ?? end
                emit(.diffHunk, lineStart, close)
            } else if unit == 43 {
                emit(.diffPlus, lineStart, end)
            } else if unit == 45 {
                emit(.diffMinus, lineStart, end)
            } else if unit == Unit.backslash {
                emit(.comment, lineStart, end)
            }
        }
    }
}
