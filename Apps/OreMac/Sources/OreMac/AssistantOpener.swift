import Foundation

/// The assistant's own first sentence, pulled out of the reply as it streams.
///
/// Mid-turn the ear used to get nothing at all: canned per-tool phrases are
/// deliberately never spoken (`VoiceSpeechPolicy.shouldSpeakMilestones`), so
/// between "go and do this" and the finished answer there was silence, while
/// the one sentence actually about the user's task sat unread in the assistant
/// window. This is that sentence — the assistant's account of what it is about
/// to do, in its own words, spoken as soon as it has formed.
enum AssistantOpener {
    /// Long enough to carry a real thought, short enough to be over before the
    /// work is.
    static let limit = 180

    /// Below this a sentence is an acknowledgement, not an opener ("Sure.",
    /// "Got it."). Worth waiting one more sentence for something with content.
    static let minimum = 24

    /// The opening sentence, or `nil` while it is still forming.
    ///
    /// Returns nothing until a sentence has actually closed: half a sentence
    /// read aloud is worse than the silence it replaced. Streaming text is
    /// markdown, so a reply that opens with a heading or a bullet has that
    /// marker stripped, and a reply that opens with a code fence is left alone
    /// entirely — nobody wants a shell command read to them.
    static func firstSentence(of streamed: String) -> String? {
        let prose = proseHead(of: streamed)
        guard !prose.isEmpty else { return nil }
        var spoken = ""
        for sentence in sentences(in: prose) {
            spoken = spoken.isEmpty ? sentence : "\(spoken) \(sentence)"
            // One sentence is the rule; a second is only borrowed when the
            // first was too slight to be worth the interruption.
            if spoken.count >= minimum { break }
        }
        guard spoken.count >= minimum else { return nil }
        return spoken.count > limit ? nil : spoken
    }

    /// Drops `opener` from the front of the finished answer.
    ///
    /// A short turn's closing narration often begins with the very sentence
    /// already spoken on the way in; hearing it twice reads as a stutter.
    static func removing(_ opener: String?, from answer: String?) -> String? {
        guard let answer, let opener, !opener.isEmpty else { return answer }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(opener.lowercased()) else { return answer }
        let rest = trimmed.dropFirst(opener.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? answer : rest
    }

    /// The part of the stream that is prose the assistant means to be read:
    /// everything before the first code fence, with list and heading markers
    /// off the front.
    private static func proseHead(of streamed: String) -> String {
        let beforeCode = streamed.components(separatedBy: "```")[0]
        let flattened = beforeCode
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripMarker(from: flattened)
    }

    /// `## Plan`, `- first`, `1. first`, `> quoted` — markdown furniture that
    /// would otherwise be read out as part of the sentence.
    private static func stripMarker(from text: String) -> String {
        var rest = Substring(text)
        while let first = rest.first {
            if first == "#" || first == ">" || first == "*" || first == "-" || first == " " {
                rest = rest.dropFirst()
                continue
            }
            // "1." / "12)" at the very front of a numbered list.
            let digits = rest.prefix(while: \.isNumber)
            if !digits.isEmpty {
                let after = rest.dropFirst(digits.count)
                if let mark = after.first, mark == "." || mark == ")" {
                    rest = after.dropFirst()
                    continue
                }
            }
            break
        }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    /// Closed sentences only — a trailing fragment is still being written.
    private static func sentences(in text: String) -> [String] {
        let characters = Array(text)
        var out: [String] = []
        var start = 0
        for index in characters.indices {
            let character = characters[index]
            guard character == "." || character == "!" || character == "?" else { continue }
            // A stop mid-word closes nothing: the "." in "e.g." and the one in
            // "6.1" are both followed by more word, not by a space.
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if let next, next != " " { continue }
            if character == ".", closesNothing(characters, at: index, since: start) { continue }
            let sentence = String(characters[start...index]).trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { out.append(sentence) }
            start = index + 1
        }
        return out
    }

    /// Whether the stop at `terminator` belongs to an abbreviation or a number
    /// rather than ending the thought.
    ///
    /// Deliberately narrow: a false negative only delays the opener by a
    /// sentence, while a false positive speaks half a thought and stops.
    private static func closesNothing(
        _ characters: [Character], at terminator: Int, since start: Int
    ) -> Bool {
        if terminator > start, characters[terminator - 1].isNumber { return true }
        var wordStart = terminator
        while wordStart > start, characters[wordStart - 1] != " " { wordStart -= 1 }
        let token = String(characters[wordStart...terminator]).lowercased()
        // A stop inside the word itself — "e.g.", "i.e.", "a.m.".
        if token.dropLast().contains(".") { return true }
        return abbreviations.contains(token)
    }

    private static let abbreviations: Set<String> = [
        "etc.", "vs.", "mr.", "ms.", "mrs.", "dr.", "prof.", "fig.", "no.", "approx.",
    ]
}
