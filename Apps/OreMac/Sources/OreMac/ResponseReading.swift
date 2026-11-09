import Foundation
import Markdown
import OreProtocol

/// How a tap on an agent response's speaker should read the reply.
///
/// Ambient narration already summarises *what the agent is doing*. This is the
/// other half: the user pointed at a finished answer and asked to hear it,
/// either word-for-word or as the headings and key information that make a
/// long reply scannable.
enum ResponseReadingMode: String, CaseIterable, Sendable, Identifiable {
    /// Every speakable word of the reply, code fences excepted.
    case full
    /// Headings, list items, and bold — the skeleton of the answer.
    case important

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: "All words"
        case .important: "Headings and key information"
        }
    }

    var menuTitle: String {
        switch self {
        case .full: "Read All Words"
        case .important: "Read Headings and Key Information"
        }
    }
}

/// Whether the speaker on a response is idle, voicing, or holding.
enum ResponsePlaybackPhase: Equatable, Sendable {
    case idle
    case speaking
    case paused
}

/// A snapshot the transcript paints without going through SwiftUI observation.
/// Progress ticks many times a second; a body pass of the chat pane at that
/// rate is how a streaming reply used to hitch, so the table observes this
/// through a callback instead.
struct ResponsePlaybackUpdate: Equatable, Sendable {
    var rowID: String?
    var phase: ResponsePlaybackPhase
    var highlight: NSRange?
    var mode: ResponseReadingMode

    static let idle = ResponsePlaybackUpdate(
        rowID: nil, phase: .idle, highlight: nil, mode: .full
    )
}

/// One stretch of the reply: what the voice says, and where that lives in the
/// rendered transcript so the highlight can follow.
struct ResponseSpokenSpan: Equatable, Sendable {
    /// UTF-16 range in the concatenated spoken string.
    var spoken: NSRange
    /// UTF-16 range in the displayed transcript string. Zero-length when the
    /// spoken words could not be placed — the voice still says them, the
    /// underline just has nowhere to go.
    var display: NSRange
}

/// The spoken form of one agent response, with a map back onto the rendered
/// text so playback can underline what is being said.
struct ResponseReadingScript: Equatable, Sendable {
    var spokenText: String
    var spans: [ResponseSpokenSpan]
    /// The displayed string the display ranges were measured against.
    var displayed: String

    var isEmpty: Bool { spokenText.isEmpty }

    /// The display range that should be underlined for a spoken UTF-16 offset.
    /// Prefers the current word so the highlight walks with the voice; falls
    /// back to the enclosing sentence or heading when the word cannot be
    /// placed (sanitising dropped punctuation, a list marker, and so on).
    func highlightRange(atSpokenUTF16 offset: Int) -> NSRange? {
        guard !spans.isEmpty else { return nil }
        let span = span(coveringSpokenUTF16: offset) ?? spans[0]
        guard span.display.length > 0 else { return nil }
        let local = max(0, offset - span.spoken.location)
        let spokenSlice = (spokenText as NSString).substring(with: span.spoken)
        let prefix = NarrationEngine.wholeWords(of: spokenSlice, upTo: local)
        let word = prefix.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        guard !word.isEmpty else { return span.display }
        let display = displayed as NSString
        let found = display.range(
            of: word,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: span.display
        )
        if found.location != NSNotFound { return found }
        return span.display
    }

    func span(coveringSpokenUTF16 offset: Int) -> ResponseSpokenSpan? {
        if let exact = spans.first(where: { NSLocationInRange(offset, $0.spoken) }) {
            return exact
        }
        // A count on a boundary, or just past the last character the voice
        // reported, still belongs to the span that just finished — otherwise
        // the underline blinks off between sentences.
        if let previous = spans.last(where: { offset >= $0.spoken.location }) {
            return previous
        }
        return spans.first
    }
}

enum ResponseReading {
    /// Top-level, finished agent prose. Nested subagent output and streaming
    /// fragments are someone else's sentence — speaking them as "the response"
    /// would read half a thought, or a tool trace the user did not tap.
    static func isSpeakableResponse(_ row: TranscriptRow) -> Bool {
        row.kind == .assistantText
            && row.parentToolCallID == nil
            && row.isComplete
            && !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Builds the spoken script for a reply.
    ///
    /// `displayed` is the transcript cell's plain string (markdown already
    /// rendered). Spans are located in that string so the underline lands on
    /// the glyphs the user is looking at, not on the source's `#` markers.
    static func script(
        markdown: String,
        displayed: String,
        mode: ResponseReadingMode
    ) -> ResponseReadingScript {
        var segments = collect(markdown: markdown, mode: mode)
        if mode == .important, segments.isEmpty {
            segments = collect(markdown: markdown, mode: .full)
        }
        return locate(segments, in: displayed)
    }

    /// Closed sentences, including a trailing fragment — this is a finished
    /// reply, not a stream, so the last clause is worth saying even without a
    /// terminator.
    nonisolated static func sentences(in text: String) -> [String] {
        let flattened = text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return [] }
        var out: [String] = []
        var start = flattened.startIndex
        var index = flattened.startIndex
        while index < flattened.endIndex {
            let character = flattened[index]
            let next = flattened.index(after: index)
            if character == "." || character == "!" || character == "?" {
                let closed = next == flattened.endIndex || flattened[next].isWhitespace
                if closed {
                    let sentence = flattened[start...index]
                        .trimmingCharacters(in: .whitespaces)
                    if !sentence.isEmpty { out.append(sentence) }
                    index = next
                    if index < flattened.endIndex, flattened[index].isWhitespace {
                        index = flattened.index(after: index)
                    }
                    start = index
                    continue
                }
            }
            index = next
        }
        let rest = flattened[start...].trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }
}

// MARK: - Collection

private extension ResponseReading {
    static func collect(markdown: String, mode: ResponseReadingMode) -> [String] {
        let document = Document(parsing: markdown, options: [.parseBlockDirectives])
        var collector = SegmentCollector(mode: mode)
        collector.visit(document)
        return collector.segments
    }

    static func locate(_ segments: [String], in displayed: String) -> ResponseReadingScript {
        let haystack = displayed as NSString
        var cursor = 0
        var spoken = ""
        var spans: [ResponseSpokenSpan] = []
        for segment in segments {
            let needle = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { continue }
            let sanitized = NarrationPhraser.sanitize(needle, limit: .max)
            guard !sanitized.isEmpty else { continue }
            if !spoken.isEmpty { spoken += " " }
            let spokenStart = (spoken as NSString).length
            spoken += sanitized
            let spokenLength = (spoken as NSString).length - spokenStart
            let display = range(of: needle, in: haystack, from: cursor)
                ?? NSRange(location: 0, length: 0)
            if display.length > 0 { cursor = NSMaxRange(display) }
            spans.append(ResponseSpokenSpan(
                spoken: NSRange(location: spokenStart, length: spokenLength),
                display: display
            ))
        }
        return ResponseReadingScript(spokenText: spoken, spans: spans, displayed: displayed)
    }

    static func range(of needle: String, in haystack: NSString, from: Int) -> NSRange? {
        guard from < haystack.length else { return nil }
        let window = NSRange(location: from, length: haystack.length - from)
        let exact = haystack.range(of: needle, options: [], range: window)
        if exact.location != NSNotFound { return exact }
        // Rendered list items keep their marker (`• `, `1. `); the collector
        // hands over the item body. A short unique prefix still pins the span
        // when a leading marker or collapsed newline is the only difference.
        let prefixLimit = min(needle.count, 32)
        guard prefixLimit >= 8 else { return nil }
        let prefix = String(needle.prefix(prefixLimit))
        let fuzzy = haystack.range(of: prefix, options: [], range: window)
        guard fuzzy.location != NSNotFound else { return nil }
        let remaining = haystack.length - fuzzy.location
        return NSRange(
            location: fuzzy.location,
            length: min((needle as NSString).length, remaining)
        )
    }
}

/// Walks the CommonMark tree the transcript already parsed for drawing, and
/// picks the pieces worth saying. Code fences stay silent — the same rule
/// `AssistantOpener` uses — because nobody asked to hear a shell command.
private struct SegmentCollector: MarkupVisitor {
    typealias Result = Void

    let mode: ResponseReadingMode
    var segments: [String] = []

    mutating func defaultVisit(_ markup: any Markup) {
        visitChildren(markup)
    }

    private mutating func visitChildren(_ markup: any Markup) {
        for child in markup.children { visit(child) }
    }

    mutating func visitHeading(_ heading: Heading) {
        collect(plainText(heading), splitSentences: false)
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        switch mode {
        case .full:
            collect(plainText(paragraph), splitSentences: true)
        case .important:
            visitChildren(paragraph)
        }
    }

    mutating func visitListItem(_ item: ListItem) {
        collect(plainText(item), splitSentences: mode == .full)
    }

    mutating func visitStrong(_ strong: Strong) {
        guard mode == .important else { return }
        collect(plainText(strong), splitSentences: false)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {}
    mutating func visitTable(_ table: Table) {}
    mutating func visitImage(_ image: Image) {}
    mutating func visitHTMLBlock(_ html: HTMLBlock) {}

    private mutating func collect(_ text: String, splitSentences: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if splitSentences {
            for sentence in ResponseReading.sentences(in: trimmed) {
                segments.append(sentence)
            }
        } else {
            segments.append(trimmed)
        }
    }

    private func plainText(_ markup: any Markup) -> String {
        if let text = markup as? Markdown.Text { return text.string }
        if let code = markup as? InlineCode { return code.code }
        return markup.children.map { plainText($0) }.joined()
    }
}
