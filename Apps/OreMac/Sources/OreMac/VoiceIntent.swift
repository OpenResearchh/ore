import Foundation
import OreProtocol

/// What the composer should do with a stretch of dictation besides typing it.
struct VoiceIntents: Equatable, Sendable {
    var attachClipboard: Bool
    var permissionMode: PermissionMode?
    var model: VoiceModelCandidate?
    var effort: ReasoningEffort?
    var rewritten: String
    /// What was recognized, in spoken order — drives the composer's change trail.
    var changes: [VoiceChange] = []
}

/// One setting the dictation changed, plus the words that were consumed saying it.
/// The composer animates these: the chip pulses, the consumed clause strikes out.
struct VoiceChange: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable, Equatable {
        case model, effort, mode, clipboard
    }

    var kind: Kind
    /// User-facing name of the new value, e.g. "GPT-5.6 Sol" or "Max".
    var label: String
    /// The literal spoken words that were removed from the draft.
    var consumed: String

    var id: String { "\(kind.rawValue)\u{1e}\(label)" }
}

struct VoiceModelCandidate: Equatable, Sendable {
    var harness: HarnessKind
    var id: String
    var displayName: String
    /// The model this harness falls back to when only the harness was named
    /// ("switch to Codex"). Mirrors the user's saved per-harness default.
    var isDefault: Bool = false
}

struct VoiceSettingsCatalog: Equatable, Sendable {
    var models: [VoiceModelCandidate]
    var efforts: [ReasoningEffort]
    var modes: [PermissionMode]
}

// MARK: - Lexing

/// A word of dictation, normalized for matching but still pointing at the
/// original text so a matched clause can be cut out verbatim.
struct VoiceToken: Equatable {
    var text: String
    var range: Range<String.Index>
}

enum VoiceLexer {
    static func tokenize(_ text: String) -> [VoiceToken] {
        var tokens: [VoiceToken] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard isWordCharacter(text[index]) else {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, isWordCharacter(text[end]) {
                end = text.index(after: end)
            }
            if let normalized = normalize(String(text[index..<end])) {
                tokens.append(VoiceToken(text: normalized, range: index..<end))
            }
            index = end
        }
        return mergeSpokenDecimals(tokens)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
            || character == "." || character == "'" || character == "\u{2019}"
    }

    private static func normalize(_ raw: String) -> String? {
        var value = raw.lowercased()
        let strippable: Set<Character> = [".", "'", "\u{2019}"]
        while let first = value.first, strippable.contains(first) { value.removeFirst() }
        while let last = value.last, strippable.contains(last) { value.removeLast() }
        guard !value.isEmpty else { return nil }

        // "5.6" is a version and must survive; "e.g" is not.
        let isDecimal = value.range(of: #"^\d+\.\d+$"#, options: .regularExpression) != nil
        if !isDecimal { value = value.replacingOccurrences(of: ".", with: "") }
        value = value.replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        guard !value.isEmpty else { return nil }
        return numberWords[value] ?? value
    }

    /// Dictation writes "five point six", the catalog says "5.6".
    private static func mergeSpokenDecimals(_ tokens: [VoiceToken]) -> [VoiceToken] {
        var result: [VoiceToken] = []
        var index = 0
        while index < tokens.count {
            if index + 2 < tokens.count,
               tokens[index].text.allSatisfy(\.isNumber),
               tokens[index + 1].text == "point" || tokens[index + 1].text == "dot",
               tokens[index + 2].text.allSatisfy(\.isNumber) {
                result.append(VoiceToken(
                    text: tokens[index].text + "." + tokens[index + 2].text,
                    range: tokens[index].range.lowerBound..<tokens[index + 2].range.upperBound
                ))
                index += 3
            } else {
                result.append(tokens[index])
                index += 1
            }
        }
        return result
    }

    private static let numberWords: [String: String] = [
        "zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "ten": "10", "eleven": "11", "twelve": "12",
    ]

    /// Dictation mishears product names constantly — "Sol" comes back as "sole",
    /// "Grok" as "grock". One edit on a reasonably long word is almost always the
    /// same word; short words are compared exactly so "max" cannot match "man".
    /// Tokens here are lowercased ASCII words, so everything works over UTF-8:
    /// `utf8.count` is O(1) on a native string where `count` is O(n), and the
    /// distance table skips grapheme segmentation entirely. That matters because
    /// this is the innermost call of a matcher that runs on every partial.
    static func tokensMatch(_ spoken: String, _ alias: String) -> Bool {
        if spoken == alias { return true }
        let spokenLength = spoken.utf8.count
        let aliasLength = alias.utf8.count
        let longest = max(spokenLength, aliasLength)
        guard longest >= 4 else { return false }
        let budget = longest >= 9 ? 2 : 1

        // Almost every pair must be rejected without touching the O(n·m) table.
        // Two linear guards do it: an edit changes the length by at most one,
        // and each edit disturbs at most two distinct letters.
        guard abs(spokenLength - aliasLength) <= budget else { return false }
        let difference = letterMask(spoken) ^ letterMask(alias)
        guard difference.nonzeroBitCount <= 2 * budget else { return false }

        return editDistance(spoken, alias) <= budget
    }

    /// One bit per a–z. Digits and anything else fold into the top bit, which
    /// keeps the guard conservative rather than wrong.
    private static func letterMask(_ text: String) -> UInt32 {
        var mask: UInt32 = 0
        for byte in text.utf8 {
            if byte >= 97, byte <= 122 {
                mask |= 1 << UInt32(byte - 97)
            } else {
                mask |= 1 << 31
            }
        }
        return mask
    }

    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }
        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)
        for i in 1...left.count {
            current[0] = i
            for j in 1...right.count {
                let substitution = previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[right.count]
    }
}

// MARK: - Extraction

/// Turns spoken composer text into settings changes.
///
/// Deliberately deterministic. An earlier version scored spans with Apple's
/// English sentence embedding, which cannot do this job: model names are proper
/// nouns carrying version numbers, and `gpt`, `sol`, `grok` and `claude` are not
/// even in the embedding's vocabulary. Measured, "sonnet" scored 0.535 against
/// "Sonnet 5 · 1M" and "GPT sole" scored 0.483 against "GPT-5.6 Sol" — both far
/// under the thresholds — so in practice only a name typed exactly as the
/// catalog spells it ever matched. Alias matching with a one-edit tolerance
/// handles the misrecognitions instead, and needs no model load at all, which is
/// what makes it fast enough to run on every partial transcript.
enum VoiceIntentExtractor {
    static func extract(from spoken: String, catalog: VoiceSettingsCatalog) -> VoiceIntents {
        let tokens = VoiceLexer.tokenize(spoken)
        guard !tokens.isEmpty else {
            return VoiceIntents(
                attachClipboard: wantsClipboard(spoken),
                permissionMode: nil, model: nil, effort: nil,
                rewritten: spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        var spans: [Range<Int>] = []
        var changes: [(index: Int, change: VoiceChange)] = []

        /// A span already claimed by an earlier setting cannot be spent twice —
        /// "max" inside "GPT-5.6 Max" is part of the model, not an effort.
        func claim(_ span: Range<Int>, kind: VoiceChange.Kind, label: String) -> Bool {
            guard !spans.contains(where: { $0.overlaps(span) }) else { return false }
            spans.append(span)
            changes.append((span.lowerBound, VoiceChange(
                kind: kind,
                label: label,
                consumed: text(of: span, in: spoken, tokens: tokens)
            )))
            return true
        }

        var model: VoiceModelCandidate?
        if let hit = matchModel(tokens: tokens, catalog: catalog),
           claim(hit.span, kind: .model, label: hit.value.displayName) {
            model = hit.value
        }

        var effort: ReasoningEffort?
        if let hit = matchEffort(tokens: tokens, allowed: catalog.efforts),
           claim(hit.span, kind: .effort, label: hit.value.displayName) {
            effort = hit.value
        }

        var mode: PermissionMode?
        if let hit = matchMode(tokens: tokens, allowed: catalog.modes),
           claim(hit.span, kind: .mode, label: hit.value.displayName) {
            mode = hit.value
        }

        return VoiceIntents(
            attachClipboard: wantsClipboard(spoken),
            permissionMode: mode,
            model: model,
            effort: effort,
            rewritten: remove(spans, from: spoken, tokens: tokens),
            changes: changes.sorted { $0.index < $1.index }.map(\.change)
        )
    }

    private struct Hit<Value> {
        var value: Value
        /// Token indices to cut from the draft, cue phrase included.
        var span: Range<Int>
    }

    // MARK: Models

    private static func matchModel(
        tokens: [VoiceToken],
        catalog: VoiceSettingsCatalog
    ) -> Hit<VoiceModelCandidate>? {
        var best: (value: VoiceModelCandidate, range: Range<Int>, specificity: Int)?

        func consider(_ candidate: VoiceModelCandidate, _ range: Range<Int>, _ specificity: Int) {
            guard let current = best else {
                best = (candidate, range, specificity)
                return
            }
            if specificity > current.specificity {
                best = (candidate, range, specificity)
            }
        }

        for candidate in catalog.models {
            for alias in aliases(for: candidate) {
                guard let range = firstMatch(of: alias, in: tokens) else { continue }
                guard !isGeneric(alias) || hasQualifier(around: range, in: tokens) else { continue }
                consider(candidate, range, alias.count)
            }
        }

        // "switch to Codex" names a harness, not a model — resolve its default.
        // Catalog order, not a Set: iteration order decides ties, so it has to
        // be stable across launches.
        var seenHarnesses: Set<HarnessKind> = []
        let harnesses = catalog.models.map(\.harness).filter { seenHarnesses.insert($0).inserted }
        for harness in harnesses {
            for alias in harnessAliases(harness) {
                guard let range = firstMatch(of: alias, in: tokens) else { continue }
                let members = catalog.models.filter { $0.harness == harness }
                guard let fallback = members.first(where: \.isDefault) ?? members.first else {
                    continue
                }
                consider(fallback, range, alias.count)
            }
        }

        guard let best else { return nil }
        guard let span = settingSpan(for: best.range, in: tokens) else { return nil }
        return Hit(value: best.value, span: span)
    }

    /// Every way a user might say a model out loud: growing prefixes of the
    /// display name ("Sonnet", "Sonnet 5"), the name with version numbers
    /// dropped ("GPT Sol"), vendor+version skipping the middle ("cursor 4.6"
    /// for "Cursor Grok 4.6"), and the raw id.
    private static func aliases(for model: VoiceModelCandidate) -> [[String]] {
        let name = VoiceLexer.tokenize(model.displayName).map(\.text)
        let identifier = VoiceLexer.tokenize(model.id).map(\.text)
        var result: [[String]] = []
        if !name.isEmpty {
            for length in 1...name.count { result.append(Array(name.prefix(length))) }
        }
        let nameCore = name.filter { !isVersionLike($0) }
        if !nameCore.isEmpty { result.append(nameCore) }
        if name.count >= 2, let version = name.last, isVersionLike(version) {
            result.append([name[0], version])
            if name.count >= 3 {
                result.append([name[name.count - 2], version])
            }
        }
        // Dictation hears "cursor" as "curse" (two edits, over the usual budget).
        if name.first == "cursor" {
            var cursed = name
            cursed[0] = "curse"
            for length in 1...cursed.count { result.append(Array(cursed.prefix(length))) }
            if let version = name.last, isVersionLike(version) {
                result.append(["curse", version])
            }
        }
        if !identifier.isEmpty { result.append(identifier) }
        let identifierCore = identifier.filter { !isVersionLike($0) }
        if !identifierCore.isEmpty { result.append(identifierCore) }

        var seen: Set<String> = []
        return result.filter { seen.insert($0.joined(separator: " ")).inserted }
    }

    private static func harnessAliases(_ harness: HarnessKind) -> [[String]] {
        let name = VoiceLexer.tokenize(harness.displayName).map(\.text)
        var result: [[String]] = [name]
        if let first = name.first, name.count > 1 { result.append([first]) }
        if harness == .cursorAgent {
            result.append(["cursor"])
            result.append(["curse"])
        }
        var seen: Set<String> = []
        return result.filter { !$0.isEmpty && seen.insert($0.joined(separator: " ")).inserted }
    }

    private static func isVersionLike(_ token: String) -> Bool {
        token.first?.isNumber == true
    }

    /// Single words that are ordinary English as well as model names. They only
    /// count as a model when "model" or "harness" is sitting right next to them.
    private static let genericAliases: Set<String> = [
        "auto", "fast", "max", "code", "agent", "pro", "mini", "air", "full", "default",
    ]

    private static func isGeneric(_ alias: [String]) -> Bool {
        alias.count == 1 && genericAliases.contains(alias[0])
    }

    private static func hasQualifier(around range: Range<Int>, in tokens: [VoiceToken]) -> Bool {
        let qualifiers: Set<String> = ["model", "harness", "agent", "engine"]
        for index in max(0, range.lowerBound - 2)..<min(tokens.count, range.upperBound + 2)
        where !range.contains(index) {
            if qualifiers.contains(tokens[index].text) { return true }
        }
        return false
    }

    // MARK: Effort

    private static func matchEffort(
        tokens: [VoiceToken],
        allowed: [ReasoningEffort]
    ) -> Hit<ReasoningEffort>? {
        var best: (value: ReasoningEffort, range: Range<Int>, length: Int)?
        for effort in allowed {
            for alias in effort.spokenAliases {
                guard let range = firstMatch(of: alias, in: tokens) else { continue }
                guard hasEffortContext(around: range, in: tokens) else { continue }
                if best == nil || alias.count > best!.length {
                    best = (effort, range, alias.count)
                }
            }
        }
        guard let best else { return nil }
        var lower = best.range.lowerBound
        var upper = best.range.upperBound
        // Swallow the trailing "reasoning effort" / "thinking" the level modifies.
        while upper < tokens.count, effortContextWords.contains(tokens[upper].text) { upper += 1 }
        while lower > 0, effortContextWords.contains(tokens[lower - 1].text) { lower -= 1 }
        // "high reasoning effort" already says it is a setting, so like the mode
        // aliases this needs no cue verb — `hasEffortContext` is the gate that
        // keeps "high hopes" out. A cue just widens the cut when one is there.
        let span = settingSpan(for: lower..<upper, in: tokens, requiresCue: false) ?? lower..<upper
        return Hit(value: best.value, span: span)
    }

    private static let effortContextWords: Set<String> = [
        "effort", "reasoning", "thinking", "reason", "thought",
    ]

    private static func hasEffortContext(around range: Range<Int>, in tokens: [VoiceToken]) -> Bool {
        for index in max(0, range.lowerBound - 2)..<min(tokens.count, range.upperBound + 3)
        where !range.contains(index) {
            if effortContextWords.contains(tokens[index].text) { return true }
        }
        return false
    }

    // MARK: Mode

    private static func matchMode(
        tokens: [VoiceToken],
        allowed: [PermissionMode]
    ) -> Hit<PermissionMode>? {
        var best: (value: PermissionMode, range: Range<Int>, length: Int)?
        for mode in allowed {
            for alias in mode.spokenAliases {
                guard let range = firstMatch(of: alias, in: tokens) else { continue }
                if best == nil || alias.count > best!.length {
                    best = (mode, range, alias.count)
                }
            }
        }
        guard let best else { return nil }
        // Unlike a model name, every mode alias carries its own qualifier
        // ("plan mode", "bypass permissions"), so it does not need a cue verb to
        // prove it is a setting — "in plan mode" is already unambiguous.
        let span = settingSpan(for: best.range, in: tokens, requiresCue: false) ?? best.range
        return Hit(value: best.value, span: span)
    }

    // MARK: Span helpers

    private static func firstMatch(of alias: [String], in tokens: [VoiceToken]) -> Range<Int>? {
        guard !alias.isEmpty, alias.count <= tokens.count else { return nil }
        for start in 0...(tokens.count - alias.count) {
            let matched = alias.indices.allSatisfy {
                VoiceLexer.tokensMatch(tokens[start + $0].text, alias[$0])
            }
            if matched { return start..<(start + alias.count) }
        }
        return matchAllowingFillers(of: alias, in: tokens)
    }

    /// "curse a 4.6" for "cursor 4.6": a short filler between alias words is
    /// almost always dictation inserting an article, not a different name.
    private static let aliasFillers: Set<String> = [
        "a", "an", "the", "to", "of", "and",
    ]

    private static func matchAllowingFillers(of alias: [String], in tokens: [VoiceToken]) -> Range<Int>? {
        guard alias.count >= 2 else { return nil }
        for start in 0..<tokens.count {
            var aliasIndex = 0
            var position = start
            var fillers = 0
            while position < tokens.count, aliasIndex < alias.count {
                if VoiceLexer.tokensMatch(tokens[position].text, alias[aliasIndex]) {
                    aliasIndex += 1
                    position += 1
                    fillers = 0
                    continue
                }
                if aliasIndex > 0, fillers < 2, aliasFillers.contains(tokens[position].text) {
                    position += 1
                    fillers += 1
                    continue
                }
                break
            }
            if aliasIndex == alias.count { return start..<position }
        }
        return nil
    }

    /// A bare name is a settings change only when something asked for it:
    /// "switch this chat to Opus" changes the model, "I wrote a sonnet" does not.
    /// The cut extends back over the request so the agent never reads it.
    private static func settingSpan(
        for range: Range<Int>,
        in tokens: [VoiceToken],
        requiresCue: Bool = true
    ) -> Range<Int>? {
        var lower = range.lowerBound
        var upper = range.upperBound
        var found = false

        var index = range.lowerBound - 1
        var filler = 0
        while index >= 0, filler <= 5 {
            let word = tokens[index].text
            if switchCues.contains(word) {
                lower = index
                found = true
                break
            }
            guard fillerWords.contains(word) else { break }
            filler += 1
            index -= 1
        }

        // "use GPT sol model" — the qualifier after the name asks just as clearly.
        if upper < tokens.count, trailingQualifiers.contains(tokens[upper].text) {
            upper += 1
            found = true
        }

        guard found || !requiresCue else { return nil }
        return lower..<upper
    }

    private static let switchCues: Set<String> = [
        "switch", "switching", "switched", "change", "changing", "changed",
        "use", "using", "run", "rerun", "set", "swap", "try", "pick", "choose",
        "move", "flip", "with", "model", "models", "harness", "engine",
    ]

    private static let fillerWords: Set<String> = [
        "this", "that", "the", "a", "an", "to", "into", "over", "on", "onto",
        "for", "chat", "tab", "session", "it", "please", "my", "our", "us",
        "now", "back", "everything", "and", "model", "harness", "agent", "with",
        "of", "in", "at", "just", "instead",
    ]

    private static let trailingQualifiers: Set<String> = [
        "model", "harness", "instead", "mode",
    ]

    private static func text(
        of span: Range<Int>,
        in spoken: String,
        tokens: [VoiceToken]
    ) -> String {
        guard let range = characterRange(of: span, in: tokens) else { return "" }
        return String(spoken[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func characterRange(
        of span: Range<Int>,
        in tokens: [VoiceToken]
    ) -> Range<String.Index>? {
        guard span.lowerBound >= 0, span.upperBound <= tokens.count, !span.isEmpty else {
            return nil
        }
        let lower = tokens[span.lowerBound].range.lowerBound
        let upper = tokens[span.upperBound - 1].range.upperBound
        return lower..<upper
    }

    private static func remove(
        _ spans: [Range<Int>],
        from spoken: String,
        tokens: [VoiceToken]
    ) -> String {
        let ranges = spans.compactMap { characterRange(of: $0, in: tokens) }
            .sorted { $0.lowerBound > $1.lowerBound }
        var result = spoken
        var cut: [Range<String.Index>] = []
        for range in ranges {
            if cut.contains(where: { $0.overlaps(range) }) { continue }
            result.replaceSubrange(range, with: " ")
            cut.append(range)
        }
        return tidy(result)
    }

    /// Cutting a clause out of the middle leaves seams — doubled spaces, a
    /// dangling "and", a comma with nothing before it.
    static func tidy(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"([,;:])\s*([,.;:])"#, with: "$2", options: .regularExpression
        )
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        let danglers: Set<String> = ["and", "then", "also", "but", "so", "with", "to", "or"]
        var words = result.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        while let first = words.first,
              danglers.contains(first.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            words.removeFirst()
        }
        while let last = words.last,
              danglers.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            words.removeLast()
        }
        return words.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))
    }

    // MARK: - Clipboard

    /// After a successful paste, drop the "it's on my clipboard" talk and put
    /// the `@pasted-image.png` chip where that clause was.
    static func incorporateClipboardToken(_ token: String, into text: String) -> String {
        let chip = token.trimmingCharacters(in: .whitespaces)
        var result = text
        var inserted = false
        for phrase in clipboardPhrases {
            guard let range = result.range(of: phrase, options: [.caseInsensitive]) else {
                continue
            }
            if inserted {
                result.replaceSubrange(range, with: " ")
            } else {
                result.replaceSubrange(range, with: " \(chip) ")
                inserted = true
            }
        }
        if !inserted {
            if !result.isEmpty, let last = result.last, !last.isWhitespace {
                result.append(" ")
            }
            result.append(chip)
        }
        return result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let clipboardPhrases = [
        "that screenshot is in my clipboard",
        "the screenshot is in my clipboard",
        "this screenshot is in my clipboard",
        "screenshot is in my clipboard",
        "that image is in my clipboard",
        "the image is in my clipboard",
        "image is in my clipboard",
        "what's on my clipboard",
        "whats on my clipboard",
        "whatever is on my clipboard",
        "whatever is in my clipboard",
        "from my clipboard",
        "in my clipboard",
        "on my clipboard",
        "from the clipboard",
        "on the clipboard",
        "i have a screenshot attached",
        "i have a screenshot",
        "paste the screenshot",
        "paste the image",
        "use that screenshot",
        "use the screenshot",
        "use that image",
        "the screenshot i copied",
        "the image i copied",
        "take that look that",
        "take a look at that",
        "use that",
    ]

    private static func wantsClipboard(_ spoken: String) -> Bool {
        let folded = spoken.lowercased()
        let signals = clipboardPhrases.filter { $0 != "use that" && $0 != "take a look at that" }
        return signals.contains { folded.contains($0) }
    }
}

private extension ReasoningEffort {
    /// Levels only. A level counts as an effort change when "effort",
    /// "reasoning" or "thinking" is next to it, so "high hopes" stays prose.
    var spokenAliases: [[String]] {
        switch self {
        case .none: [["no"], ["none"], ["zero"], ["without"], ["disable"]]
        case .low: [["low"], ["minimal"]]
        case .medium: [["medium"], ["moderate"], ["normal"]]
        case .high: [["high"]]
        case .xhigh: [["extra", "high"], ["x", "high"], ["very", "high"], ["extremely", "high"]]
        case .max: [["maximum"], ["max"], ["highest"], ["full"]]
        }
    }
}

private extension PermissionMode {
    /// Every alias carries its own qualifier ("mode", "permissions", "edits"),
    /// which is what keeps "plan a vacation" and "bypass the flaky test" prose.
    var spokenAliases: [[String]] {
        switch self {
        case .default:
            [["ask", "mode"], ["default", "mode"], ["ask", "permission"],
             ["ask", "permissions"], ["default", "permissions"], ["ask", "first"]]
        case .acceptEdits:
            [["accept", "edits"], ["accept", "edit"], ["auto", "accept", "edits"],
             ["auto", "approve", "edits"], ["accept", "all", "edits"], ["auto", "accept"]]
        case .plan:
            [["plan", "mode"], ["planning", "mode"], ["plan", "only"]]
        case .bypassPermissions:
            [["bypass", "permissions"], ["bypass", "permission"], ["bypass", "mode"],
             ["yolo", "mode"], ["full", "access"], ["danger", "mode"]]
        }
    }
}
