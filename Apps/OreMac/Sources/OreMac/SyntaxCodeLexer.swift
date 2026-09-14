import Foundation

/// The token-oriented lexer every C-like (and not-so-C-like) language shares.
///
/// Precedence is positional, not by pass: at each index the scanner asks
/// "does a comment start here? a string? a number? a word?" in that order and
/// consumes whatever matches whole. That is what makes `"https://x"` a string
/// and `// it's` a comment — the first construct to start wins, and nothing
/// inside it is looked at again.
extension SyntaxLexer {
    private struct Heredoc {
        var markerStart: Int
        var markerEnd: Int
    }

    mutating func scanCode(_ language: CompiledLanguage, from: Int, to limit: Int) {
        let definition = language.definition
        let jsx = definition.jsx
        let regexLiterals = definition.regexLiterals
        let heredocs = definition.heredocs
        let charLiterals = definition.charLiterals
        let quoteLabels = definition.quoteLabels
        let preprocessor = definition.preprocessor
        let decorateAt = definition.decorators.contains { if case .at = $0 { true } else { false } }
        let decorateHash = definition.decorators.contains { if case .hashBracket = $0 { true } else { false } }
        let decorateDash = definition.decorators.contains { if case .lineStartDash = $0 { true } else { false } }
        let rawStrings = definition.rawStrings
        let sectionHeaders = definition.sectionHeaders
        let hasSigils = !language.sigils.isEmpty
        let percentNumbers = definition.percentNumbers
        let keys = definition.keys
        let firstWordKind = definition.firstWordKind

        var index = from
        var lineStart = isAtLineStart(from, floor: 0)
        var firstWord = lineStart
        // Only keywords so far in this statement: `export FOO=1` still has a key.
        var statementStart = lineStart
        // Whether the previous significant token was a value, which decides
        // whether `/` is division or a regex and `<` a comparison or a tag.
        var previousIsValue = false
        var lastPunctuation: UInt16 = 0
        var pendingDefinition: SyntaxTokenKind?
        var heredoc: Heredoc?
        // Where a string opener last failed to close, per rule. An unclosed
        // quote on a long line would otherwise be rescanned from every quote
        // after it — quadratic on minified or prose-heavy input.
        var failedUntil = [Int](repeating: -1, count: language.strings.count)

        if from == 0, limit >= 2, text[0] == 35, text[1] == 33 {
            index = lineEnd(from: 0, limit: limit)
            emit(.comment, 0, index)
        }

        scanning: while index < limit {
            let unit = text[index]
            if unit == Unit.newline {
                index += 1
                lineStart = true
                firstWord = true
                statementStart = true
                if let pending = heredoc {
                    heredoc = nil
                    index = scanHeredocBody(pending, from: index, limit: limit)
                }
                continue
            }
            if Unit.isBlank(unit) {
                index += 1
                continue
            }
            let atLineStart = lineStart
            lineStart = false

            // `#[attr]` before comments: PHP has both.
            if decorateHash, unit == 35, index + 1 < limit,
               text[index + 1] == 91 || (text[index + 1] == 33 && index + 2 < limit && text[index + 2] == 91) {
                let bracket = text[index + 1] == 91 ? index + 1 : index + 2
                if let end = matchingClose(from: bracket, open: 91, close: 93, limit: limit) {
                    emit(.attribute, index, end)
                    index = end
                    continue
                }
            }

            // 1. Comments, then strings.
            if language.openers.contains(unit) {
                if let end = scanComment(language, at: index, atLineStart: atLineStart, from: from, limit: limit) {
                    index = end
                    continue
                }
                for (ruleIndex, rule) in language.strings.enumerated()
                where index >= failedUntil[ruleIndex] && matches(rule.open, at: index, limit: limit) {
                    let before = tokens.count
                    if let end = scanString(
                        language, rule, tokenStart: index, bodyStart: index + rule.open.count, limit: limit,
                        escapes: rule.rule.escapes, interpolation: rule.rule.interpolation
                    ) {
                        if statementStart || keys?.statementStart == false, let keys, keys.quoted,
                           isKeySeparator(language, at: end, limit: limit) {
                            retag(from: before, to: keys.kind)
                        }
                        index = end
                        previousIsValue = true
                        firstWord = false
                        statementStart = false
                        continue scanning
                    }
                    failedUntil[ruleIndex] = lineEnd(from: index, limit: limit)
                }
            }

            // 2. Constructs that need a specific character.
            if unit == 35 /* # */ {
                if rawStrings.contains(.swift), let end = scanSwiftRawString(at: index, limit: limit) {
                    index = end; previousIsValue = true; continue
                }
                if preprocessor, atLineStart {
                    index = scanPreprocessor(at: index, limit: limit)
                    continue
                }
            }
            if sectionHeaders, atLineStart, unit == 91 /* [ */, let end = sectionHeaderEnd(at: index, limit: limit) {
                emit(.type, index, end)
                index = end
                continue
            }
            if heredocs, unit == 60 /* < */, let (end, marker) = heredocOpener(at: index, limit: limit) {
                emit(.stringSpecial, index, end)
                heredoc = marker
                index = end
                previousIsValue = true
                continue
            }
            if regexLiterals, unit == 47 /* / */, !previousIsValue, let end = regexEnd(at: index, limit: limit) {
                emit(.stringSpecial, index, end)
                index = end
                previousIsValue = true
                continue
            }
            if jsx, unit == 60, index + 1 < limit {
                let next = text[index + 1]
                let opening = !previousIsValue && (Unit.isLetter(next) || next == 62)
                let closing = next == 47 && index + 2 < limit && (Unit.isLetter(text[index + 2]) || text[index + 2] == 62)
                if opening || closing {
                    index = scanJSXTag(language, at: index, limit: limit)
                    previousIsValue = false
                    continue
                }
            }
            if decorateAt, unit == 64 /* @ */, index + 1 < limit,
               Unit.isLetter(text[index + 1]) || text[index + 1] == 95 {
                var end = index + 1
                while end < limit, Unit.isWord(text[end]) || text[end] == 46 { end += 1 }
                let isKeyword = language.words.lookup(text, index + 1, end) == .keyword
                emit(isKeyword ? .keyword : .attribute, index, end)
                index = end
                continue
            }
            if decorateDash, atLineStart, unit == 45 /* - */, index + 1 < limit, Unit.isLetter(text[index + 1]) {
                var end = index + 1
                while end < limit, Unit.isWord(text[end]) { end += 1 }
                emit(.attribute, index, end)
                index = end
                continue
            }
            if hasSigils, let sigil = language.sigils[unit], let end = scanSigil(sigil, language, at: index, from: from, limit: limit) {
                index = end
                previousIsValue = true
                firstWord = false
                continue
            }

            // 3. Numbers.
            if Unit.isDigit(unit)
                || (unit == 46 && index + 1 < limit && Unit.isDigit(text[index + 1])
                    && (index == from || !(Unit.isWord(text[index - 1]) || text[index - 1] == 46))) {
                let end = numberEnd(language, at: index, limit: limit, percent: percentNumbers)
                emit(.number, index, end)
                index = end
                previousIsValue = true
                firstWord = false
                statementStart = false
                pendingDefinition = nil
                continue
            }

            // 4. Words.
            if Unit.isLetter(unit) || unit == 95 || unit >= 128 || language.identifierStart.contains(unit) {
                if let end = scanPrefixedOrRawString(language, at: index, limit: limit) {
                    index = end
                    previousIsValue = true
                    firstWord = false
                    statementStart = false
                    continue
                }
                var end = index + 1
                while end < limit, Unit.isWord(text[end]) || language.identifierChars.contains(text[end]) { end += 1 }
                if end < limit, language.identifierSuffixes.contains(text[end]),
                   !(end + 1 < limit && text[end + 1] == 61) {
                    end += 1
                }

                var kind: SyntaxTokenKind?
                if firstWord, !language.lineStartWords.isEmpty, language.lineStartWords.lookup(text, index, end) != nil {
                    kind = .keyword
                } else {
                    kind = language.words.lookup(text, index, end)
                }
                if kind == nil, let pending = pendingDefinition { kind = pending }
                pendingDefinition = nil
                if kind == .keyword, !language.definers.isEmpty {
                    pendingDefinition = language.definers.lookup(text, index, end)
                }
                if kind == nil, firstWord, let firstWordKind { kind = firstWordKind }
                if kind == nil, let keys, statementStart || !keys.statementStart,
                   isKeySeparator(language, at: end, limit: limit) {
                    kind = keys.kind
                }
                if kind == nil {
                    kind = classifyName(language, start: index, end: end, limit: limit, lastPunctuation: lastPunctuation)
                }
                if let kind { emit(kind, index, end) }

                previousIsValue = kind != .keyword
                if kind != .keyword { statementStart = false }
                firstWord = false
                lastPunctuation = 0
                index = end
                continue
            }

            // 5. Punctuation, and the character literals that look like it.
            if unit == Unit.apostrophe, charLiterals {
                if let end = charLiteralEnd(at: index, limit: limit) {
                    emit(.string, index, end)
                    index = end
                    previousIsValue = true
                    continue
                }
                if quoteLabels, index + 1 < limit, Unit.isLetter(text[index + 1]) || text[index + 1] == 95 {
                    var end = index + 1
                    while end < limit, Unit.isWord(text[end]) { end += 1 }
                    emit(.label, index, end)
                    index = end
                    continue
                }
            }
            if unit != 42 /* * */ { pendingDefinition = nil }
            if keys != nil, language.keyAfter.contains(unit) {
                statementStart = true
            } else if unit != 45 {
                statementStart = false
            }
            previousIsValue = unit == 41 || unit == 93 || unit == 125
            lastPunctuation = unit
            firstWord = false
            index += 1
        }
    }

    // MARK: - Comments

    private mutating func scanComment(
        _ language: CompiledLanguage, at index: Int, atLineStart: Bool, from: Int, limit: Int
    ) -> Int? {
        for comment in language.blockComments where matches(comment.open, at: index, limit: limit) {
            var depth = 1
            var cursor = index + comment.open.count
            while cursor < limit {
                if matches(comment.close, at: cursor, limit: limit) {
                    depth -= 1
                    cursor += comment.close.count
                    if depth == 0 || !comment.nests { break }
                    continue
                }
                if comment.nests, matches(comment.open, at: cursor, limit: limit) {
                    depth += 1
                    cursor += comment.open.count
                    continue
                }
                cursor += 1
            }
            emit(.comment, index, min(cursor, limit))
            return min(cursor, limit)
        }
        for marker in language.lineComments where matches(marker, at: index, limit: limit) {
            if language.commentsNeedBoundary, index > from {
                let previous = text[index - 1]
                guard Unit.isBlank(previous) || previous == Unit.newline || previous == 59
                    || previous == 124 || previous == 38 || previous == 40 else { continue }
            }
            let end = lineEnd(from: index, limit: limit)
            emit(.comment, index, end)
            return end
        }
        if atLineStart {
            for marker in language.lineStartComments where matchesIgnoringCase(marker, at: index, limit: limit) {
                // A word-like marker (`REM`) must be a whole word.
                let after = index + marker.count
                if let last = marker.last, Unit.isLetter(last), after < limit, Unit.isWord(text[after]) { continue }
                let end = lineEnd(from: index, limit: limit)
                emit(.comment, index, end)
                return end
            }
        }
        return nil
    }

    // MARK: - Strings

    /// Scans a string whose opener ends at `bodyStart`. Returns nil — with any
    /// tokens it emitted rolled back — when a single-line string doesn't close,
    /// so a stray apostrophe in prose doesn't paint the rest of the line.
    mutating func scanString(
        _ language: CompiledLanguage,
        _ rule: CompiledLanguage.CompiledString,
        tokenStart: Int,
        bodyStart: Int,
        limit: Int,
        escapes: Bool,
        interpolation: LanguageDefinition.Interpolation
    ) -> Int? {
        let kind = rule.rule.kind
        let savedCount = tokens.count
        let savedEnd = tokens.last?.end
        var segment = tokenStart
        var cursor = bodyStart
        let close = rule.close
        let multiline = rule.rule.multiline

        while cursor < limit {
            let unit = text[cursor]
            if matches(close, at: cursor, limit: limit) {
                if rule.rule.doubledClose, matches(close, at: cursor + close.count, limit: limit) {
                    cursor += close.count * 2
                    continue
                }
                cursor += close.count
                emit(kind, segment, cursor)
                return cursor
            }
            if unit == Unit.newline, !multiline { break }
            if interpolation == .brace, unit == 123 || unit == 125, cursor + 1 < limit, text[cursor + 1] == unit {
                cursor += 2
                continue
            }

            if interpolation != .none, let (openLength, openUnit, closeUnit) = interpolationOpener(
                interpolation, at: cursor, limit: limit
            ) {
                if interpolation == .shell, openLength == 2, openUnit == 123,
                   let end = matchingClose(from: cursor + 1, open: 123, close: 125, limit: lineEnd(from: cursor, limit: limit)) {
                    emit(kind, segment, cursor)
                    emit(.variableSpecial, cursor, end)
                    segment = end
                    cursor = end
                    continue
                }
                if openLength == 0 {
                    var end = cursor + 1
                    while end < limit, Unit.isWord(text[end]) { end += 1 }
                    emit(kind, segment, cursor)
                    emit(.variableSpecial, cursor, end)
                    segment = end
                    cursor = end
                    continue
                }
                let bracket = cursor + openLength - 1
                let searchLimit = multiline ? limit : lineEnd(from: cursor, limit: limit)
                if let end = matchingClose(from: bracket, open: openUnit, close: closeUnit, limit: searchLimit) {
                    emit(kind, segment, cursor)
                    emit(.punctuationSpecial, cursor, cursor + openLength)
                    lex(language, from: cursor + openLength, to: end - 1)
                    emit(.punctuationSpecial, end - 1, end)
                    segment = end
                    cursor = end
                    continue
                }
            }

            if escapes, unit == Unit.backslash, cursor + 1 < limit {
                var end = cursor + 2
                if text[cursor + 1] == 117 /* u */, end < limit, text[end] == 123 /* { */ {
                    var brace = end
                    while brace < min(limit, end + 10), text[brace] != 125 { brace += 1 }
                    if brace < limit, text[brace] == 125 { end = brace + 1 }
                }
                emit(kind, segment, cursor)
                if text[cursor + 1] != Unit.newline { emit(.stringEscape, cursor, end) }
                segment = end
                cursor = end
                continue
            }
            cursor += 1
        }

        if multiline, cursor >= limit {
            emit(kind, segment, limit)
            return limit
        }
        tokens.removeSubrange(savedCount...)
        if let savedEnd, !tokens.isEmpty { tokens[tokens.count - 1].end = savedEnd }
        return nil
    }

    /// (opener length, bracket to balance, its closer), or length 0 for a
    /// bare `$name`.
    private func interpolationOpener(
        _ style: LanguageDefinition.Interpolation, at index: Int, limit: Int
    ) -> (Int, UInt16, UInt16)? {
        guard index + 1 < limit else { return nil }
        let unit = text[index]
        let next = text[index + 1]
        switch style {
        case .none:
            return nil
        case .dollarBrace:
            return unit == 36 && next == 123 ? (2, 123, 125) : nil
        case .dollarBraceAndName:
            guard unit == 36 else { return nil }
            if next == 123 { return (2, 123, 125) }
            return Unit.isLetter(next) || next == 95 ? (0, 0, 0) : nil
        case .hashBrace:
            return unit == 35 && next == 123 ? (2, 123, 125) : nil
        case .backslashParen:
            return unit == Unit.backslash && next == 40 ? (2, 40, 41) : nil
        case .brace:
            return unit == 123 && next != 123 ? (1, 123, 125) : nil
        case .shell:
            guard unit == 36 else { return nil }
            if next == 123 { return (2, 123, 125) }
            if next == 40 { return (2, 40, 41) }
            return Unit.isLetter(next) || next == 95 ? (0, 0, 0) : nil
        }
    }

    private mutating func retag(from tokenIndex: Int, to kind: SyntaxTokenKind) {
        guard tokenIndex < tokens.count else { return }
        let start = tokens[tokenIndex].start
        let end = tokens[tokens.count - 1].end
        tokens.removeSubrange(tokenIndex...)
        emit(kind, start, end)
    }

    /// `f"…"`, `rb'…'`, `u8"…"`, Rust `r#"…"#`, C++ `R"x(…)x"` — strings
    /// whose opener starts with a word.
    private mutating func scanPrefixedOrRawString(_ language: CompiledLanguage, at index: Int, limit: Int) -> Int? {
        let raw = language.rawStrings
        if raw.contains(.rust), let end = scanRustRawString(at: index, limit: limit) { return end }
        if raw.contains(.cpp), let end = scanCppRawString(at: index, limit: limit) { return end }
        guard language.hasPrefixes else { return nil }
        var end = index
        while end < limit, end - index < 4, Unit.isLetter(text[end]) || Unit.isDigit(text[end]) { end += 1 }
        guard end < limit, end - index <= 3, language.openers.contains(text[end]) else { return nil }
        let word = String(utf16CodeUnits: Array(text[index..<end]), count: end - index).lowercased()
        guard let prefix = language.stringPrefixes[word] else { return nil }
        for rule in language.strings where matches(rule.open, at: end, limit: limit) {
            if let stringEnd = scanString(
                language, rule, tokenStart: index, bodyStart: end + rule.open.count, limit: limit,
                escapes: rule.rule.escapes && !prefix.raw,
                interpolation: prefix.interpolation == .none ? rule.rule.interpolation : prefix.interpolation
            ) {
                return stringEnd
            }
        }
        return nil
    }

    private mutating func scanRustRawString(at index: Int, limit: Int) -> Int? {
        var cursor = index
        if text[cursor] == 98 /* b */ || text[cursor] == 99 /* c */ { cursor += 1 }
        guard cursor < limit, text[cursor] == 114 /* r */ else { return nil }
        cursor += 1
        var hashes = 0
        while cursor < limit, text[cursor] == 35 { hashes += 1; cursor += 1 }
        guard cursor < limit, text[cursor] == Unit.quote else { return nil }
        cursor += 1
        while cursor < limit {
            if text[cursor] == Unit.quote {
                var count = 0
                while count < hashes, cursor + 1 + count < limit, text[cursor + 1 + count] == 35 { count += 1 }
                if count == hashes {
                    let end = cursor + 1 + hashes
                    emit(.string, index, end)
                    return end
                }
            }
            cursor += 1
        }
        emit(.string, index, limit)
        return limit
    }

    private mutating func scanSwiftRawString(at index: Int, limit: Int) -> Int? {
        var cursor = index
        var hashes = 0
        while cursor < limit, text[cursor] == 35 { hashes += 1; cursor += 1 }
        guard cursor < limit, text[cursor] == Unit.quote else { return nil }
        let triple = cursor + 2 < limit && text[cursor + 1] == Unit.quote && text[cursor + 2] == Unit.quote
        let quotes = triple ? 3 : 1
        cursor += quotes
        while cursor < limit {
            if !triple, text[cursor] == Unit.newline { return nil }
            var run = 0
            while run < quotes, cursor + run < limit, text[cursor + run] == Unit.quote { run += 1 }
            if run == quotes {
                var count = 0
                while count < hashes, cursor + quotes + count < limit, text[cursor + quotes + count] == 35 { count += 1 }
                if count == hashes {
                    let end = cursor + quotes + hashes
                    emit(.string, index, end)
                    return end
                }
            }
            cursor += 1
        }
        emit(.string, index, limit)
        return limit
    }

    private mutating func scanCppRawString(at index: Int, limit: Int) -> Int? {
        var cursor = index
        // Encoding prefixes: L, u, U, u8.
        while cursor < limit, cursor - index < 2,
              text[cursor] == 76 || text[cursor] == 117 || text[cursor] == 85 || text[cursor] == 56 { cursor += 1 }
        guard cursor + 1 < limit, text[cursor] == 82 /* R */, text[cursor + 1] == Unit.quote else { return nil }
        cursor += 2
        let delimiterStart = cursor
        while cursor < limit, cursor - delimiterStart <= 16, text[cursor] != 40 {
            if text[cursor] == Unit.newline || text[cursor] == Unit.space { return nil }
            cursor += 1
        }
        guard cursor < limit, text[cursor] == 40 else { return nil }
        var closer: [UInt16] = [41]
        closer.append(contentsOf: text[delimiterStart..<cursor])
        closer.append(Unit.quote)
        cursor += 1
        while cursor < limit {
            if matches(closer, at: cursor, limit: limit) {
                let end = cursor + closer.count
                emit(.string, index, end)
                return end
            }
            cursor += 1
        }
        emit(.string, index, limit)
        return limit
    }

    private func charLiteralEnd(at index: Int, limit: Int) -> Int? {
        guard index + 2 < limit else { return nil }
        var cursor = index + 1
        if text[cursor] == Unit.backslash {
            cursor += 2
            while cursor < limit, cursor - index < 12, text[cursor] != Unit.apostrophe, text[cursor] != Unit.newline {
                cursor += 1
            }
        } else if text[cursor] == Unit.newline || text[cursor] == Unit.apostrophe {
            return nil
        } else {
            cursor += (text[cursor] >= 0xD800 && text[cursor] <= 0xDBFF) ? 2 : 1
        }
        guard cursor < limit, text[cursor] == Unit.apostrophe else { return nil }
        return cursor + 1
    }

    // MARK: - Heredocs, regexes, preprocessor, sections

    /// `<<EOF`, `<<-EOF`, `<<~EOF`, `<<'EOF'`, `<<<EOT`. Requires the marker to
    /// touch the operator, so `a << b` stays a shift.
    private func heredocOpener(at index: Int, limit: Int) -> (Int, Heredoc)? {
        guard index + 2 < limit, text[index + 1] == 60 else { return nil }
        var cursor = index + 2
        if text[cursor] == 60 { cursor += 1 }
        if cursor < limit, text[cursor] == 45 || text[cursor] == 126 { cursor += 1 }
        var quote: UInt16 = 0
        if cursor < limit, text[cursor] == Unit.apostrophe || text[cursor] == Unit.quote {
            quote = text[cursor]
            cursor += 1
        }
        guard cursor < limit, Unit.isLetter(text[cursor]) || text[cursor] == 95 else { return nil }
        let markerStart = cursor
        while cursor < limit, Unit.isWord(text[cursor]) { cursor += 1 }
        let markerEnd = cursor
        if quote != 0 {
            guard cursor < limit, text[cursor] == quote else { return nil }
            cursor += 1
        }
        return (cursor, Heredoc(markerStart: markerStart, markerEnd: markerEnd))
    }

    private mutating func scanHeredocBody(_ heredoc: Heredoc, from: Int, limit: Int) -> Int {
        let marker = Array(text[heredoc.markerStart..<heredoc.markerEnd])
        var lineStart = from
        while lineStart < limit {
            let content = skipBlanks(from: lineStart, limit: limit)
            let end = lineEnd(from: lineStart, limit: limit)
            if matches(marker, at: content, limit: end) {
                let after = content + marker.count
                if after == end || !Unit.isWord(text[after]) {
                    emit(.string, from, content)
                    emit(.stringSpecial, content, after)
                    return after
                }
            }
            lineStart = end + 1
        }
        emit(.string, from, limit)
        return limit
    }

    private func regexEnd(at index: Int, limit: Int) -> Int? {
        guard index + 1 < limit else { return nil }
        let first = text[index + 1]
        if Unit.isBlank(first) || first == 47 || first == 42 || first == Unit.newline || first == 61 { return nil }
        var cursor = index + 1
        var inClass = false
        while cursor < limit {
            let unit = text[cursor]
            if unit == Unit.newline { return nil }
            if unit == Unit.backslash { cursor += 2; continue }
            if unit == 91 { inClass = true } else if unit == 93 { inClass = false } else if unit == 47, !inClass {
                cursor += 1
                while cursor < limit, Unit.isLetter(text[cursor]) { cursor += 1 }
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    private mutating func scanPreprocessor(at index: Int, limit: Int) -> Int {
        let wordStart = skipBlanks(from: index + 1, limit: limit)
        var wordEnd = wordStart
        while wordEnd < limit, Unit.isWord(text[wordEnd]) { wordEnd += 1 }
        guard wordEnd > wordStart else { return index + 1 }
        emit(.keyword, index, wordEnd)
        let argument = skipBlanks(from: wordEnd, limit: limit)
        if argument < limit, text[argument] == 60 /* < */ {
            let end = lineEnd(from: argument, limit: limit)
            var close = argument + 1
            while close < end, text[close] != 62 { close += 1 }
            if close < end {
                emit(.string, argument, close + 1)
                return close + 1
            }
        }
        return wordEnd
    }

    private func sectionHeaderEnd(at index: Int, limit: Int) -> Int? {
        let end = lineEnd(from: index, limit: limit)
        var cursor = index + 1
        while cursor < end {
            let unit = text[cursor]
            if unit == 93 {
                var close = cursor + 1
                if close < end, text[close] == 93 { close += 1 }
                let rest = skipBlanks(from: close, limit: end)
                if rest == end || text[rest] == 35 || text[rest] == 59 { return close }
                return nil
            }
            // Headers hold names, not values: `[1, 2]` is an array.
            if !(Unit.isWord(unit) || unit == 46 || unit == 45 || unit == 91 || unit == Unit.quote
                 || unit == Unit.apostrophe || unit == Unit.space || unit == 58 || unit == 47) {
                return nil
            }
            cursor += 1
        }
        return nil
    }

    // MARK: - Words

    private func isKeySeparator(_ language: CompiledLanguage, at index: Int, limit: Int) -> Bool {
        guard let keys = language.keys else { return false }
        let cursor = keys.spacesBeforeSeparator ? skipBlanks(from: index, limit: limit) : index
        guard cursor < limit, language.keySeparators.contains(text[cursor]) else { return false }
        let separator = text[cursor]
        let next: UInt16 = cursor + 1 < limit ? text[cursor + 1] : 0
        if next == separator { return false }
        if separator == 61, next == 62 || next == 126 { return false }
        return true
    }

    private func classifyName(
        _ language: CompiledLanguage, start: Int, end: Int, limit: Int, lastPunctuation: UInt16
    ) -> SyntaxTokenKind? {
        if language.lispCalls, lastPunctuation == 40 { return .function }
        let callFollows: Bool = {
            guard language.functionCalls else { return false }
            let next = skipBlanks(from: end, limit: limit)
            return next < limit && text[next] == 40
        }()
        if language.capitalizedTypes, Unit.isUpper(text[start]) {
            var hasLower = false
            for offset in start..<end where Unit.isLower(text[offset]) { hasLower = true; break }
            if !hasLower, end - start >= 2 { return .constant }
            if callFollows, language.capitalizedCallsAreFunctions { return .function }
            return .type
        }
        return callFollows ? .function : nil
    }

    private func numberEnd(_ language: CompiledLanguage, at index: Int, limit: Int, percent: Bool) -> Int {
        var cursor = index
        let separators = language.digitSeparators
        @inline(__always) func digitOrSeparator(_ at: Int, hex: Bool) -> Bool {
            let unit = text[at]
            if hex ? Unit.isHexDigit(unit) : Unit.isDigit(unit) { return true }
            return separators.contains(unit) && at + 1 < limit
                && (hex ? Unit.isHexDigit(text[at + 1]) : Unit.isDigit(text[at + 1]))
        }
        if text[cursor] == 48, cursor + 1 < limit {
            let marker = text[cursor + 1] | 0x20
            if marker == 120 /* x */ || marker == 98 /* b */ || marker == 111 /* o */ {
                cursor += 2
                while cursor < limit, digitOrSeparator(cursor, hex: marker == 120) { cursor += 1 }
                while cursor < limit, Unit.isWord(text[cursor]) { cursor += 1 }
                return cursor
            }
        }
        while cursor < limit, digitOrSeparator(cursor, hex: false) { cursor += 1 }
        if cursor + 1 < limit, text[cursor] == 46, Unit.isDigit(text[cursor + 1]) {
            cursor += 1
            while cursor < limit, digitOrSeparator(cursor, hex: false) { cursor += 1 }
        }
        if cursor + 1 < limit, text[cursor] | 0x20 == 101 /* e */ {
            var exponent = cursor + 1
            if text[exponent] == 43 || text[exponent] == 45 { exponent += 1 }
            if exponent < limit, Unit.isDigit(text[exponent]) {
                cursor = exponent
                while cursor < limit, Unit.isDigit(text[cursor]) { cursor += 1 }
            }
        }
        while cursor < limit, Unit.isLetter(text[cursor]) || Unit.isDigit(text[cursor]) || text[cursor] == 95 {
            cursor += 1
        }
        if percent, cursor < limit, text[cursor] == 37 { cursor += 1 }
        return cursor
    }

    private mutating func scanSigil(
        _ sigil: LanguageDefinition.Sigil, _ language: CompiledLanguage, at index: Int, from: Int, limit: Int
    ) -> Int? {
        guard index + 1 < limit else { return nil }
        let unit = text[index]
        if index > from {
            let previous = text[index - 1]
            // `a:b` and `a::b` are not symbols; `x$y` is one word.
            if (Unit.isWord(previous) && !sigil.escapesPunctuation) || previous == unit { return nil }
        }
        var body = index + 1
        if text[body] == unit {
            if sigil.specials.utf16.contains(unit) {
                emit(sigil.kind, index, index + 2)
                return index + 2
            }
            // `@@class_variable`, `::namespaced/keyword`, `%%i`.
            guard !sigil.escapesPunctuation, body + 1 < limit,
                  Unit.isLetter(text[body + 1]) || text[body + 1] == 95 else { return nil }
            body += 1
        }
        let next = text[body]
        let line = lineEnd(from: body, limit: limit)
        if let closer = sigil.closer?.utf16.first {
            var end = body
            while end < line, end - body < 64, text[end] != closer, !Unit.isBlank(text[end]) { end += 1 }
            if end < line, end > body, text[end] == closer {
                emit(sigil.kind, index, end + 1)
                return end + 1
            }
        }
        if sigil.braces, next == 123, let end = matchingClose(from: body, open: 123, close: 125, limit: line) {
            emit(sigil.kind, index, end)
            return end
        }
        if next == 40 {
            if sigil.parensAreVariables, let end = matchingClose(from: body, open: 40, close: 41, limit: line) {
                emit(sigil.kind, index, end)
                return end
            }
            if sigil.parens {
                var end = body + 1
                if end < limit, text[end] == 40 { end += 1 }
                emit(.punctuationSpecial, index, end)
                return end
            }
            return nil
        }
        if Unit.isLetter(next) || next == 95 || next >= 128 {
            var end = body + 1
            if sigil.escapesPunctuation {
                while end < limit, Unit.isLetter(text[end]) || text[end] == 64 { end += 1 }
            } else {
                while end < limit, Unit.isWord(text[end]) || language.identifierChars.contains(text[end]) { end += 1 }
            }
            emit(sigil.kind, index, end)
            return end
        }
        if sigil.specials.utf16.contains(next) {
            emit(sigil.kind, index, body + 1)
            return body + 1
        }
        if sigil.escapesPunctuation, !Unit.isBlank(next), next != Unit.newline {
            emit(.stringEscape, index, index + 2)
            return index + 2
        }
        return nil
    }

    // MARK: - JSX

    private mutating func scanJSXTag(_ language: CompiledLanguage, at index: Int, limit: Int) -> Int {
        var cursor = index + 1
        if text[cursor] == 47 { cursor += 1 }
        if cursor < limit, text[cursor] == 62 {
            emit(.punctuation, index, cursor + 1)
            return cursor + 1
        }
        let nameStart = cursor
        while cursor < limit, Unit.isWord(text[cursor]) || text[cursor] == 46 || text[cursor] == 45 || text[cursor] == 58 {
            cursor += 1
        }
        emit(.punctuation, index, nameStart)
        emit(Unit.isUpper(text[nameStart]) ? .type : .tag, nameStart, cursor)

        while cursor < limit {
            let unit = text[cursor]
            if Unit.isBlank(unit) || unit == Unit.newline {
                cursor += 1
            } else if unit == 62 {
                emit(.punctuation, cursor, cursor + 1)
                return cursor + 1
            } else if unit == 47, cursor + 1 < limit, text[cursor + 1] == 62 {
                emit(.punctuation, cursor, cursor + 2)
                return cursor + 2
            } else if unit == 123 {
                guard let end = matchingClose(from: cursor, open: 123, close: 125, limit: limit) else { return cursor + 1 }
                lex(language, from: cursor + 1, to: end - 1)
                cursor = end
            } else if unit == Unit.quote || unit == Unit.apostrophe {
                var end = cursor + 1
                while end < limit, text[end] != unit { end += 1 }
                end = min(end + 1, limit)
                emit(.string, cursor, end)
                cursor = end
            } else if Unit.isLetter(unit) || unit == 95 {
                var end = cursor + 1
                while end < limit, Unit.isWord(text[end]) || text[end] == 45 || text[end] == 58 { end += 1 }
                emit(.attribute, cursor, end)
                cursor = end
            } else if unit == 61 {
                cursor += 1
            } else {
                // Not a tag after all (`a <b && c`); resume ordinary lexing.
                return cursor
            }
        }
        return limit
    }
}
