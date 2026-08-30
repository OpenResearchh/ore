import Foundation

/// The private convention between ORE and the agent for spoken narration.
///
/// ORE's system prompt asks the agent to end each turn with one spoken-shaped
/// line wrapped in these delimiters. The line is meant for the ear, not the
/// transcript: translators strip it from every surface the user reads and
/// carry it on `TurnResult.narration` for the narration engine to speak.
///
/// Both halves of the convention — the instruction that teaches the tag and
/// the extraction that consumes it — reference these constants, so the
/// delimiter can never drift between them.
public enum NarrationTag {
    public static let open = "<narration>"
    public static let close = "</narration>"

    /// Splits a completed text into the visible body and the narration line.
    ///
    /// Every real occurrence is stripped from the body; when the agent emits
    /// the tag more than once, the last non-empty one wins — its final word is
    /// the freshest account of the turn.
    ///
    /// Two shapes are deliberately *not* treated as tags, because both are an
    /// agent writing the delimiter as prose — most often while explaining this
    /// very convention — and taking either one as a real tag deletes the rest
    /// of the message from the transcript and speaks it instead:
    ///
    /// - An opener with another opener before its closer. Tags do not nest, so
    ///   the outer one is prose that happened to find a later tag's closer.
    /// - An unclosed opener whose tail spans lines. The unclosed case exists
    ///   for an agent cut off mid-tag, which leaves a partial *single* line;
    ///   paragraphs after the opener mean it was never a tag at all.
    public static func extract(from text: String) -> (body: String, narration: String?) {
        // The overwhelmingly common case is no tag at all (thinking blocks,
        // subagent text, harnesses that ignore the instruction) — one scan,
        // no allocation.
        guard text.contains(open) else { return (text, nil) }

        var body = ""
        var narration: String?
        var remainder = Substring(text)
        while let openRange = remainder.range(of: open) {
            let afterOpen = remainder[openRange.upperBound...]
            let closeRange = afterOpen.range(of: close)

            // Prose, not a tag: keep the delimiter in the body verbatim and
            // resume scanning after it.
            let isProse: Bool
            if let nextOpen = afterOpen.range(of: open) {
                isProse = closeRange.map { nextOpen.lowerBound < $0.lowerBound } ?? true
            } else if closeRange == nil {
                isProse = afterOpen
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .contains(where: \.isNewline)
            } else {
                isProse = false
            }
            guard !isProse else {
                body += remainder[..<openRange.upperBound]
                remainder = afterOpen
                continue
            }

            body += remainder[..<openRange.lowerBound]
            let inner: Substring
            if let closeRange {
                inner = afterOpen[..<closeRange.lowerBound]
                remainder = afterOpen[closeRange.upperBound...]
            } else {
                inner = afterOpen
                remainder = Substring("")
            }
            let spoken = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            if !spoken.isEmpty { narration = spoken }
        }
        body += remainder
        // Stripping a tag that sat on its own final line leaves a dangling
        // newline; the body should end where the prose ends.
        while let last = body.last, last.isWhitespace || last.isNewline {
            body.removeLast()
        }
        return (body, narration)
    }
}

/// Keeps a narration tag from flashing in the live transcript.
///
/// Deltas arrive in arbitrary slices — the opener can be split across many of
/// them — so a per-block filter withholds any tail that might still become
/// the opener, and once the opener completes, swallows everything up to the
/// closer. Whole-text extraction at block completion is the authoritative
/// pass; this filter only exists so the user never sees `<narration>` render
/// and then vanish.
public struct NarrationTagStreamFilter: Sendable {
    /// Tail of emitted-so-far text that is a strict prefix of the opener —
    /// held back until it either completes the opener or turns out to be
    /// ordinary prose.
    private var held = ""
    /// Everything seen since the opener completed, awaiting the closer.
    private var captured = ""
    private var isCapturing = false
    private var narration: String?

    public init() {}

    /// Returns the part of `delta` that is safe to show live.
    public mutating func filter(_ delta: String) -> String {
        var emitted = ""
        var input = held + delta
        held = ""
        while !input.isEmpty {
            if isCapturing {
                captured += input
                input = ""
                // Tags do not nest, so a second opener before the closer means
                // the one being captured was prose. Hand it back to the
                // transcript verbatim and capture from the new one instead —
                // the same rule `NarrationTag.extract` applies to the settled
                // text, so the live view and the final view agree.
                while let nextOpen = captured.range(of: NarrationTag.open),
                      captured.range(of: NarrationTag.close)
                          .map({ nextOpen.lowerBound < $0.lowerBound }) ?? true {
                    emitted += NarrationTag.open + captured[..<nextOpen.lowerBound]
                    captured = String(captured[nextOpen.upperBound...])
                }
                if let closeRange = captured.range(of: NarrationTag.close) {
                    let spoken = captured[..<closeRange.lowerBound]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !spoken.isEmpty { narration = spoken }
                    // Prose after the closer (the instruction says there is
                    // none, but the model decides) goes back through the
                    // ordinary path — it may even open another tag.
                    input = String(captured[closeRange.upperBound...])
                    captured = ""
                    isCapturing = false
                }
            } else if let openRange = input.range(of: NarrationTag.open) {
                emitted += input[..<openRange.lowerBound]
                input = String(input[openRange.upperBound...])
                isCapturing = true
            } else {
                let tail = Self.longestOpenerPrefixSuffix(of: input)
                emitted += input.dropLast(tail.count)
                held = tail
                input = ""
            }
        }
        return emitted
    }

    /// Settles the block at completion: text held back on a false alarm is
    /// flushed, and an opener that never closed yields its content as the
    /// narration rather than reappearing in the transcript.
    public mutating func finish() -> (flush: String, narration: String?) {
        var flush = held
        if isCapturing {
            let spoken = captured.trimmingCharacters(in: .whitespacesAndNewlines)
            // An unclosed opener is a cut-off tag only while it still looks
            // like the single spoken line the convention asks for; a tail
            // spanning lines was prose, and swallowing it would take the rest
            // of the message out of the transcript.
            if spoken.contains(where: \.isNewline) {
                flush = NarrationTag.open + captured
            } else if !spoken.isEmpty {
                narration = spoken
            }
        }
        defer { self = NarrationTagStreamFilter() }
        return (flush, narration)
    }

    /// The longest suffix of `text` that is a strict prefix of the opener —
    /// the only part of a delta that might still be the start of a tag.
    private static func longestOpenerPrefixSuffix(of text: String) -> String {
        let opener = NarrationTag.open
        let longest = min(text.count, opener.count - 1)
        guard longest > 0 else { return "" }
        for length in stride(from: longest, through: 1, by: -1) {
            let candidate = opener.prefix(length)
            if text.hasSuffix(candidate) { return String(candidate) }
        }
        return ""
    }
}
