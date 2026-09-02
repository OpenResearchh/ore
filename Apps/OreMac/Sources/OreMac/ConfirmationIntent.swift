import Foundation
import NaturalLanguage
import OreProtocol

/// A spoken reply to a pending confirmation, read as an utterance.
///
/// The microphone is answering a yes/no question, so this walks the phrase
/// left to right: collocations first ("no problem", "go ahead"), then the
/// leftover words. A bag of words would see "no" inside "no problem, go ahead"
/// and refuse the action the user just agreed to.
enum ConfirmationIntent {
    /// `nil` means this was not a confirmation reply — send it as a message.
    static func decision(from transcript: String) -> AssistantConfirmationDecision? {
        let words = tokens(in: transcript)
        guard !words.isEmpty, words.count <= 8 else { return nil }

        var index = 0
        var assent = false
        var deny = false
        var always = false
        var leftover = 0

        while index < words.count {
            let word = words[index]
            // Collocations before fillers: "please do" is an assent, not a
            // skipped "please" plus a leftover "do".
            if let phrase = phrase(at: index, in: words) {
                switch phrase.polarity {
                case .assent: assent = true
                case .deny: deny = true
                }
                index += phrase.length
                continue
            }
            if fillers.contains(word) {
                index += 1
                continue
            }
            if word == "always" || word == "auto" {
                always = true
                index += 1
                continue
            }
            leftover += 1
            index += 1
        }

        // Extra content ("show me the diff") is a request, not a yes/no.
        guard leftover == 0, assent || deny else { return nil }
        if deny { return .deny }
        if always, assent { return .allow(.always) }
        if assent { return .allow(.task) }
        return nil
    }

    // MARK: - Phrases

    private enum Polarity {
        case assent, deny
    }

    private struct Phrase {
        var polarity: Polarity
        var length: Int
    }

    /// Longest match at `index` wins, so "go ahead" is one assent, not a stray
    /// "go", and "no problem" is not a "no".
    private static func phrase(at index: Int, in words: [String]) -> Phrase? {
        let remaining = words.count - index
        for (parts, polarity) in collocations where parts.count <= remaining {
            let length = parts.count
            if words[index..<(index + length)].elementsEqual(parts) {
                return Phrase(polarity: polarity, length: length)
            }
        }
        return nil
    }

    /// Longest first so a prefix never steals a longer collocation.
    private static let collocations: [([String], Polarity)] = [
        (["not", "a", "problem"], .assent),
        (["no", "problem"], .assent),
        (["no", "problems"], .assent),
        (["no", "worries"], .assent),
        (["no", "worry"], .assent),
        (["no", "doubt"], .assent),
        (["go", "ahead"], .assent),
        (["go", "for", "it"], .assent),
        (["of", "course"], .assent),
        (["sounds", "good"], .assent),
        (["all", "right"], .assent),
        (["alright"], .assent),
        (["do", "it"], .assent),
        (["do", "that"], .assent),
        (["please", "do"], .assent),
        (["yes"], .assent),
        (["yeah"], .assent),
        (["yep"], .assent),
        (["yup"], .assent),
        (["sure"], .assent),
        (["ok"], .assent),
        (["okay"], .assent),
        (["allow"], .assent),
        (["approve"], .assent),
        (["approved"], .assent),
        (["confirm"], .assent),
        (["go"], .assent),
        (["do", "not"], .deny),
        (["dont"], .deny),
        (["no", "thanks"], .deny),
        (["no", "thank"], .deny),
        (["not", "now"], .deny),
        (["no"], .deny),
        (["nope"], .deny),
        (["nah"], .deny),
        (["deny"], .deny),
        (["denied"], .deny),
        (["reject"], .deny),
        (["rejected"], .deny),
        (["cancel"], .deny),
        (["stop"], .deny),
        (["never"], .deny),
        (["decline"], .deny),
    ]

    private static let fillers: Set<String> = [
        "um", "uh", "er", "ah", "hmm", "please", "just", "that", "this",
        "it", "the", "a", "to", "for", "me", "you", "and", "then",
        "tab", "chat", "everything", "all",
    ]

    // MARK: - Tokenizing

    /// Word tokens, apostrophes folded so "don't" is one denial ("dont").
    private static func tokens(in transcript: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = transcript
        var words: [String] = []
        tokenizer.enumerateTokens(in: transcript.startIndex..<transcript.endIndex) { range, _ in
            let folded = transcript[range]
                .lowercased()
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "’", with: "")
                .filter(\.isLetter)
            if !folded.isEmpty { words.append(folded) }
            return true
        }
        return words
    }
}
