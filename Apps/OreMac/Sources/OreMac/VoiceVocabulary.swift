import Foundation

/// Fixes near-miss workspace and repository names in a finished transcript —
/// "met calf" or "metcalf" become "metcalfe" — so the assistant resolves the
/// project the user actually named.
///
/// Deliberately conservative: it only ever rewrites toward a known name, only
/// when the sounds are close (tight edit-distance budget, matching first
/// letter), and never when the words already spell a different known name.
/// The recognizer's contextual-strings biasing catches most of this upstream;
/// this is the engine-independent backstop.
struct VoiceVocabulary {
    private struct Candidate {
        let name: String
        let wordCount: Int
        let normalized: String
    }

    private let candidates: [Candidate]
    private let exactForms: Set<String>

    init(names: [String]) {
        var seen = Set<String>()
        var built: [Candidate] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = Self.normalize(trimmed)
            guard normalized.count >= 4, seen.insert(normalized).inserted else { continue }
            built.append(Candidate(
                name: trimmed,
                wordCount: trimmed.split(separator: " ").count,
                normalized: normalized
            ))
        }
        // Longest first, so "book of optics" wins before "optics" could.
        candidates = built.sorted { $0.normalized.count > $1.normalized.count }
        exactForms = seen
    }

    func corrected(_ transcript: String) -> String {
        guard !candidates.isEmpty, !transcript.isEmpty else { return transcript }
        var tokens = transcript.split(separator: " ", omittingEmptySubsequences: false)
            .map(String.init)

        for candidate in candidates {
            var index = 0
            while index + candidate.wordCount <= tokens.count {
                let window = Array(tokens[index..<(index + candidate.wordCount)])
                let joined = Self.normalize(window.joined(separator: " "))
                if shouldReplace(joined, with: candidate) {
                    tokens.replaceSubrange(
                        index..<(index + candidate.wordCount),
                        with: rewrite(window, as: candidate.name)
                    )
                }
                index += 1
            }
        }
        return tokens.joined(separator: " ")
    }

    private func shouldReplace(_ heard: String, with candidate: Candidate) -> Bool {
        guard !heard.isEmpty, heard != candidate.normalized else { return false }
        // The words already are a known name — never rewrite one name into
        // another, however close they sound.
        guard !exactForms.contains(heard) else { return false }
        guard heard.first == candidate.normalized.first else { return false }
        let budget = Self.editBudget(for: candidate.normalized.count)
        guard budget > 0 else { return false }
        // Cheap length gate before the O(n·m) distance.
        guard abs(heard.count - candidate.normalized.count) <= budget else { return false }
        return Self.editDistance(heard, candidate.normalized, limit: budget) <= budget
    }

    /// Short names get no fuzz at all — at four letters, one edit is a
    /// different word ("care" is not "core"), not an accent.
    private static func editBudget(for length: Int) -> Int {
        switch length {
        case ..<5: 0
        case 5..<8: 1
        default: 2
        }
    }

    /// The canonical name, wearing the punctuation the heard words had —
    /// "metcalf," stays a clause boundary after it becomes "metcalfe,".
    private func rewrite(_ window: [String], as name: String) -> [String] {
        guard let first = window.first, let last = window.last else { return [name] }
        let leading = String(first.prefix(while: { !$0.isLetter && !$0.isNumber }))
        let trailing = String(last.reversed().prefix(while: { !$0.isLetter && !$0.isNumber }).reversed())
        return [leading + name + trailing]
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    /// Bounded Levenshtein: gives up (returns `limit + 1`) as soon as the
    /// distance can't come back under the budget.
    private static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let left = Array(a.unicodeScalars)
        let right = Array(b.unicodeScalars)
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
