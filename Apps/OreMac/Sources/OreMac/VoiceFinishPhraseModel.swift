import Foundation

/// What the finish-phrase matcher accepts: the canonical phrase plus the
/// transcription variants this user's recognizer actually produces.
///
/// The stock model encodes exactly the historical rule for "yip yap yip yip".
/// Enrollment (Settings → Voice → Tune…) widens it with token sequences
/// recorded through the real recognition pipeline, so matching tolerates the
/// mistakes this microphone and this voice actually make — not hypothetical
/// ones.
struct FinishPhraseModel: Codable, Equatable, Sendable {
    /// The phrase as the user says it, for prompts and captions.
    var spoken: String
    /// The phrase as word tokens, one per slot.
    var canonicalTokens: [String]
    /// Per-slot accepted tokens for a full-confidence match. This preserves
    /// only the stock phrase's historical yip/yep accommodation; enrollment
    /// uses whole sequences below so it cannot invent cross-product variants.
    var slotAlternatives: [[String]]
    /// Whole trailing token sequences the recognizer produced during tuning
    /// and the user approved. Matched token-exact at full confidence.
    var enrolledVariants: [[String]]

    /// Today's shipping rule, verbatim: {yip,yep} yap {yip,yep} {yip,yep}.
    static let standard = FinishPhraseModel(
        spoken: "yip yap yip yip",
        canonicalTokens: ["yip", "yap", "yip", "yip"],
        slotAlternatives: [["yip", "yep"], ["yap"], ["yip", "yep"], ["yip", "yep"]],
        enrolledVariants: []
    )

    /// Curated near-mistranscriptions, one hop wider than the exact slots.
    /// Deliberately excludes "yep" for "yap": "yep yep yep yep" is a person
    /// agreeing, and it must never submit (a single-slot "yep" slip is still
    /// caught by the joined-suffix edit distance instead).
    static let defaultFuzz: [String: [String]] = [
        "yip": ["yep", "hip", "tip"],
        "yap": ["yak", "app"],
    ]

    /// What to feed the recognizer's contextual-strings biasing.
    var vocabulary: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for token in canonicalTokens + slotAlternatives.flatMap({ $0 })
            + enrolledVariants.flatMap({ $0 }) {
            if seen.insert(token).inserted { out.append(token) }
        }
        for phrase in [spoken] + enrolledVariants.map({ $0.joined(separator: " ") }) {
            if seen.insert(phrase).inserted { out.append(phrase) }
        }
        return out
    }

    /// Exact-tier acceptance for one slot.
    func exactSlotContains(_ token: String, slot: Int) -> Bool {
        guard slotAlternatives.indices.contains(slot) else { return false }
        return slotAlternatives[slot].contains(token) || canonicalTokens[slot] == token
    }

    /// Fuzzy-tier acceptance for one slot: the exact set, the curated fuzz
    /// table, or — for longer custom-phrase words the table doesn't know —
    /// one edit off the canonical token with the first letter intact.
    func fuzzySlotContains(_ token: String, slot: Int) -> Bool {
        if exactSlotContains(token, slot: slot) { return true }
        guard canonicalTokens.indices.contains(slot) else { return false }
        let canonical = canonicalTokens[slot]
        if Self.defaultFuzz[canonical]?.contains(token) == true { return true }
        guard canonical.count >= 5, token.first == canonical.first else { return false }
        return FinishPhraseMatching.editDistance(token, canonical, limit: 1) <= 1
    }

    /// Every token the phrase could plausibly surface as — the gate that
    /// keeps prose out of stretched match windows.
    var phraseTokens: Set<String> {
        var tokens = Set(canonicalTokens)
        for alternatives in slotAlternatives { tokens.formUnion(alternatives) }
        for variant in enrolledVariants { tokens.formUnion(variant) }
        for canonical in canonicalTokens {
            tokens.formUnion(Self.defaultFuzz[canonical] ?? [])
        }
        return tokens
    }

    /// UserDefaults is not a trust boundary: old builds, hand-edited defaults,
    /// or a partial write must not leave the matcher with mismatched slot arrays
    /// or an accidentally broad phrase. Normalize and cap everything before a
    /// model reaches a live microphone.
    func validated() -> FinishPhraseModel? {
        let canonical = canonicalTokens.flatMap { FinishPhraseMatching.words(in: $0) }
        guard (3...6).contains(canonical.count) else { return nil }

        var exactSlots = Array(repeating: [String](), count: canonical.count)
        for slot in canonical.indices {
            var seen = Set<String>()
            // Per-slot cross-products are safe only for the narrow historical
            // yip/yep rule. User calibration is represented by complete
            // enrolled sequences, never by independently combinable slots.
            let candidates = canonical == Self.standard.canonicalTokens
                ? Self.standard.slotAlternatives[slot]
                : [canonical[slot]]
            for candidate in candidates {
                let words = FinishPhraseMatching.words(in: candidate)
                guard words.count == 1 else { continue }
                if seen.insert(words[0]).inserted { exactSlots[slot].append(words[0]) }
                if exactSlots[slot].count == 6 { break }
            }
        }

        let minimumVariantCharacters = max(6, canonical.joined().count / 2)
        var seenVariants = Set<[String]>()
        var variants: [[String]] = []
        for raw in enrolledVariants {
            let variant = raw.flatMap { FinishPhraseMatching.words(in: $0) }
            guard (1...(canonical.count + 2)).contains(variant.count),
                  variant.joined().count >= minimumVariantCharacters,
                  variant != canonical,
                  seenVariants.insert(variant).inserted
            else { continue }
            variants.append(variant)
            if variants.count == 8 { break }
        }

        return FinishPhraseModel(
            spoken: canonical.joined(separator: " "),
            canonicalTokens: canonical,
            slotAlternatives: exactSlots,
            enrolledVariants: variants
        )
    }
}

/// The tuned model, persisted whole. Absent means stock behavior.
enum FinishPhraseStore {
    static let key = "ore.voice.finishPhraseModel"
    private static let schemaVersion = 1

    private struct Stored: Codable {
        let version: Int
        let model: FinishPhraseModel
    }

    static func load(defaults: UserDefaults = .standard) -> FinishPhraseModel? {
        guard let data = defaults.data(forKey: key) else { return nil }
        if let stored = try? JSONDecoder().decode(Stored.self, from: data),
           stored.version == schemaVersion {
            return stored.model.validated()
        }
        // Migration for the short-lived unversioned development format.
        return (try? JSONDecoder().decode(FinishPhraseModel.self, from: data))?.validated()
    }

    static func save(_ model: FinishPhraseModel, defaults: UserDefaults = .standard) {
        guard let model = model.validated(),
              let data = try? JSONEncoder().encode(Stored(version: schemaVersion, model: model))
        else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    /// The active phrase for captions and prompts, stock or tuned.
    static var currentSpoken: String {
        (load() ?? .standard).spoken
    }
}

/// Opt-in JSON-lines record of hands-free sessions, for diagnosing why a
/// finish phrase didn't land: what the recognizer actually transcribed, and
/// what the matcher made of it. Written only when
/// `defaults write <bundle> ore.voice.debugFinishLog -bool YES` is set;
/// capped so it never grows past the last fifty sessions.
enum FinishPhraseDebugLog {
    static let enabledKey = "ore.voice.debugFinishLog"
    static let sessionCap = 50

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    struct Entry: Codable, Sendable {
        /// Milliseconds since the mic opened.
        let ms: Int
        /// Only the trailing words relevant to phrase recognition. Full spoken
        /// requests are deliberately never written to this diagnostic log.
        let suffix: String
        /// Matcher/guard state: exact/fuzzy finish, near miss, silence, or timeout.
        let saw: String
    }

    struct Session: Codable, Sendable {
        let endedAt: Date
        /// "finish", "silence", "timeout", "ended", "error", or "cancel".
        let outcome: String
        let recognizer: String?
        let contextApplied: Bool
        let entries: [Entry]
    }

    static func suffix(of transcript: String, maximumTokens: Int = 8) -> String {
        FinishPhraseMatching.words(in: transcript)
            .suffix(maximumTokens)
            .joined(separator: " ")
    }

    static var fileURL: URL? {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else { return nil }
        let bundle = Bundle.main.bundleIdentifier ?? "com.ore.OreMac"
        let directory = caches
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("Voice", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        } catch {
            return nil
        }
        return directory.appendingPathComponent("finish-phrase.jsonl", isDirectory: false)
    }

    /// Best-effort, called off the main actor: a lost log line is nothing.
    static func append(_ session: Session) {
        guard let url = fileURL,
              let line = try? JSONEncoder().encode(session),
              let encoded = String(data: line, encoding: .utf8)
        else { return }
        var lines = (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init) ?? []
        lines.append(encoded)
        if lines.count > sessionCap { lines.removeFirst(lines.count - sessionCap) }
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }
}

enum FinishPhraseMatching {
    static func words(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Bounded Levenshtein: gives up (returns `limit + 1`) as soon as the
    /// distance can't come back under the budget. Same shape as
    /// `VoiceVocabulary`'s — duplicated so that struct stays sealed.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let left = Array(a.unicodeScalars)
        let right = Array(b.unicodeScalars)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }
        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)

        for row in 1...left.count {
            current[0] = row
            var rowMinimum = current[0]
            for column in 1...right.count {
                let substitution = previous[column - 1] + (left[row - 1] == right[column - 1] ? 0 : 1)
                current[column] = min(previous[column] + 1, current[column - 1] + 1, substitution)
                rowMinimum = min(rowMinimum, current[column])
            }
            if rowMinimum > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[right.count]
    }
}
