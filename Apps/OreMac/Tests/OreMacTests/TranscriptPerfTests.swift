import AppKit
import OreProtocol
import Testing

@testable import OreMac

/// A streaming reply is rendered by re-parsing only its tail. That is only
/// acceptable if what it draws is exactly what one full render draws.
@MainActor
struct StreamingMarkdownRenderTests {
    private let renderer = MarkdownRenderer(highlighter: SyntaxHighlighter.shared)

    private static let reply = """
    # Plan

    Read `ChatState.swift` first, then https://github.com/OpenResearchh/ore/pull/1 and Sources/App.swift:12.

    ```swift
    let first = 1

    let second = first + 1
    ```

    - one
    - two

    1. alpha
    2. beta

    **Why:** keeps *streaming* cheap.

    | a | b |
    |---|---|
    | 1 | 2 |

    > quoted

    ~~~
    tilde fence
    ~~~

    Done.
    """

    /// Per character: the character and every attribute a reader can see.
    /// Colours are resolved to components, since dynamic colours built per
    /// render are distinct objects with equal values.
    private func fingerprint(_ string: NSAttributedString) -> [String] {
        let characters = string.string as NSString
        func color(_ value: Any?) -> String {
            guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else { return value == nil ? "-" : "?" }
            return "\(color.redComponent) \(color.greenComponent) \(color.blueComponent) \(color.alphaComponent)"
        }
        return (0..<string.length).map { index in
            let attributes = string.attributes(at: index, effectiveRange: nil)
            let font = (attributes[.font] as? NSFont).map { "\($0.fontName) \($0.pointSize)" } ?? "-"
            let link = attributes[.link].map { "\($0)" } ?? "-"
            let paragraph = (attributes[.paragraphStyle] as? NSParagraphStyle).map {
                "\($0.paragraphSpacing) \($0.paragraphSpacingBefore) \($0.headIndent) "
                    + "\($0.firstLineHeadIndent) \($0.lineSpacing) \($0.textBlocks.count)"
            } ?? "-"
            let attachment = attributes[.attachment] == nil ? "" : "attachment"
            return "\(characters.character(at: index)) \(font) \(color(attributes[.foregroundColor])) "
                + "\(color(attributes[.backgroundColor])) \(link) \(paragraph) \(attachment)"
        }
    }

    @Test func aStreamedReplyDrawsExactlyWhatAFullRenderDraws() {
        let characters = Array(Self.reply)
        var prefix: MarkdownRenderer.StreamingPrefix?
        var reusedAHead = false
        var end = 0
        while end < characters.count {
            end = min(characters.count, end + 2)
            let text = String(characters[0..<end])
            let streamed = renderer.renderStreaming(text, reusing: prefix)
            let full = renderer.render(text, highlighting: .stablePrefix)
            #expect(streamed.rendered.string == full.string, "diverged at \(end)")
            #expect(fingerprint(streamed.rendered) == fingerprint(full), "diverged at \(end)")
            if prefix != nil, streamed.prefix != nil { reusedAHead = true }
            prefix = streamed.prefix
        }
        // Otherwise this only proved that a full render equals itself.
        #expect(reusedAHead)
        #expect((prefix?.sourceLength ?? 0) > 0)
    }

    /// The cell's label and the height measurer both keep the previous render
    /// and replace only what follows `reusedLength`, so that run has to be
    /// identical — characters *and* attributes — in both renders. If it ever
    /// isn't, a streaming reply draws stale text or is measured at the wrong
    /// height, with nothing on screen to say why.
    @Test func theReusedRunIsIdenticalInBothRenders() {
        let characters = Array(Self.reply)
        var prefix: MarkdownRenderer.StreamingPrefix?
        var previous: NSAttributedString?
        var splicedSomething = false
        var end = 0
        while end < characters.count {
            end = min(characters.count, end + 2)
            let streamed = renderer.renderStreaming(String(characters[0..<end]), reusing: prefix)
            if let previous, streamed.reusedLength > 0 {
                let shared = min(streamed.reusedLength, min(previous.length, streamed.rendered.length))
                #expect(shared > 0, "a reused head that shares nothing, at \(end)")
                #expect(
                    Array(fingerprint(previous).prefix(shared))
                        == Array(fingerprint(streamed.rendered).prefix(shared)),
                    "the reused run diverged at \(end)"
                )
                splicedSomething = true
            }
            previous = streamed.rendered
            prefix = streamed.prefix
        }
        // Otherwise this proved nothing about splicing at all.
        #expect(splicedSomething)
    }

    @Test func aHeadIsNotReusedForTextThatReplacedIt() {
        let first = renderer.renderStreaming("One.\n\nTwo.", reusing: nil)
        #expect(first.prefix != nil)
        let replaced = renderer.renderStreaming("# Uno\n\nDos.", reusing: first.prefix)
        let full = renderer.render("# Uno\n\nDos.", highlighting: .stablePrefix)
        #expect(fingerprint(replaced.rendered) == fingerprint(full))
    }

    @Test func aCutIsOnlyTakenBeforeABlockThatStandsAlone() {
        #expect(MarkdownRenderer.streamingBoundary(in: "One.\n\nTwo.") == .split(at: 6))
        // A list item after a blank line may still belong to the list above.
        #expect(MarkdownRenderer.streamingBoundary(in: "- a\n\n- b") == .split(at: nil))
        #expect(MarkdownRenderer.streamingBoundary(in: "1. a\n\n2. b") == .split(at: nil))
        // Indented: the item's continuation, or code.
        #expect(MarkdownRenderer.streamingBoundary(in: "- a\n\n  more") == .split(at: nil))
        // Still arriving: a lone `-` could yet become a list marker.
        #expect(MarkdownRenderer.streamingBoundary(in: "One.\n\n-") == .split(at: nil))
        // Blank lines inside a fence are code.
        #expect(MarkdownRenderer.streamingBoundary(in: "```\na\n\nb") == .split(at: nil))
        #expect(MarkdownRenderer.streamingBoundary(in: "```\na\n```\n\nb") == .split(at: 11))
    }

    @Test func constructsThatReachAcrossBlocksRenderWhole() {
        #expect(MarkdownRenderer.streamingBoundary(in: "See [x].\n\n[x]: https://example.com") == .unsplittable)
        #expect(MarkdownRenderer.streamingBoundary(in: "<!--\n\nstill a comment\n-->") == .unsplittable)
        #expect(MarkdownRenderer.streamingBoundary(in: "- item\n  ```\n  code\n  ```") == .unsplittable)
    }

    /// The two link patterns are compiled once now; what they match must not move.
    @Test func fileReferencesAndBareURLsStillLink() {
        let rendered = renderer.render(
            "Open Sources/App.swift:12 or https://github.com/OpenResearchh/ore/pull/1."
        )
        let characters = rendered.string as NSString
        let file = characters.range(of: "Sources/App.swift:12")
        #expect(file.location != NSNotFound)
        if file.location != NSNotFound {
            let link = rendered.attribute(.link, at: file.location, effectiveRange: nil) as? URL
            #expect(link == MarkdownRenderer.fileReferenceURL("Sources/App.swift:12"))
        }
        #expect(!rendered.string.contains("https://"))
        #expect(rendered.string.contains("github.com/…/pull/1"))
    }

    @Test func aStreamingRowGrowsThroughTheCellRenderPath() {
        var row = TranscriptRow(
            id: "perf-stream-\(UUID().uuidString)",
            turnID: TurnID(rawValue: "perf"),
            kind: .assistantText,
            text: "First paragraph.\n\nSecond"
        )
        let head = TranscriptCell.attributedText(for: row)
        #expect(head.string.hasSuffix("Second"))
        row.text += " paragraph grows."
        row.contentRevision += 1
        let grown = TranscriptCell.attributedText(for: row)
        // The same text as a finished row under a fresh id: a full render.
        let finished = TranscriptRow(
            id: "perf-full-\(UUID().uuidString)",
            turnID: row.turnID,
            kind: .assistantText,
            text: row.text,
            isComplete: true
        )
        let full = TranscriptCell.attributedText(for: finished)
        #expect(grown.string == full.string)
        #expect(grown.length == full.length)
        TranscriptCell.dropRenderCache(turnIDs: [row.turnID])
    }
}

@MainActor
struct TranscriptRenderCacheTests {
    private func text(_ length: Int) -> NSAttributedString {
        NSAttributedString(string: String(repeating: "x", count: length))
    }

    @Test func theByteBoundEvictsTheLeastRecentlyUsedRenders() {
        let entry = TranscriptCell.RenderCache.cost(of: text(100))
        var cache = TranscriptCell.RenderCache(byteBudget: entry * 3 + 100, entryLimit: 100)
        let turn = TurnID(rawValue: "t1")
        for id in ["a", "b", "c"] {
            cache.store(text(100), id: id, turnID: turn, signature: 1)
        }
        #expect(cache.count == 3)
        // Reading a render keeps it warm.
        #expect(cache.value(forID: "a", signature: 1) != nil)

        cache.store(text(100), id: "d", turnID: turn, signature: 1)
        #expect(cache.totalCost <= cache.byteBudget)
        #expect(cache.contains(id: "a"))
        #expect(cache.contains(id: "d"))
        #expect(!cache.contains(id: "b"))
    }

    @Test func aChangedSignatureMissesAndReplaces() {
        var cache = TranscriptCell.RenderCache()
        let turn = TurnID(rawValue: "t1")
        cache.store(text(10), id: "a", turnID: turn, signature: 1)
        #expect(cache.value(forID: "a", signature: 2) == nil)
        cache.store(text(20), id: "a", turnID: turn, signature: 2)
        #expect(cache.count == 1)
        #expect(cache.totalCost == TranscriptCell.RenderCache.cost(of: text(20)))
    }

    @Test func droppingAChatsTurnsDropsOnlyItsRenders() {
        var cache = TranscriptCell.RenderCache()
        cache.store(text(10), id: "a", turnID: TurnID(rawValue: "t1"), signature: 1)
        cache.store(text(10), id: "b", turnID: TurnID(rawValue: "t2"), signature: 1)
        cache.removeEntries(forTurns: [TurnID(rawValue: "t1")])
        #expect(!cache.contains(id: "a"))
        #expect(cache.contains(id: "b"))
        #expect(cache.totalCost == TranscriptCell.RenderCache.cost(of: text(10)))
    }

    /// Rows reusing an id at revision zero (history, tests) must still miss
    /// when their payload differs, without hashing the payload whole.
    @Test func theSignatureTellsApartRowsThatShareAnID() {
        let base = TranscriptRow(
            id: "task-1", turnID: TurnID(rawValue: "t1"), kind: .toolCall, text: "TaskUpdate",
            toolInput: .object(["taskId": .string("8"), "status": .string("completed")])
        )
        var changed = base
        changed.toolInput = .object(["taskId": .string("8"), "status": .string("in_progress")])
        #expect(
            TranscriptCell.renderSignature(for: base, appearance: "a")
                != TranscriptCell.renderSignature(for: changed, appearance: "a")
        )
        #expect(
            TranscriptCell.renderSignature(for: base, appearance: "a")
                == TranscriptCell.renderSignature(for: base, appearance: "a")
        )
    }
}

@MainActor
struct HighlightCacheBoundTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    @Test func aHitIsOnlyEverTheSameCode() {
        let highlighter = SyntaxHighlighter()
        let first = highlighter.highlight("let a = 1", language: "swift", font: font)
        #expect(highlighter.highlight("let a = 1", language: "swift", font: font) === first)
        // Same length and language, different code.
        let other = highlighter.highlight("let b = 2", language: "swift", font: font)
        #expect(other !== first)
        #expect(other.string == "let b = 2")
    }

    @Test func theCacheStaysWithinItsBudget() {
        let highlighter = SyntaxHighlighter(highlightCacheBudget: 4_000, highlightCacheCapacity: 48)
        for index in 0..<30 {
            _ = highlighter.highlight(
                "let value\(index) = \(index) // padding padding padding", language: "swift", font: font
            )
        }
        let usage = highlighter.highlightCacheUsage
        #expect(usage.cost <= 4_000)
        #expect(usage.count > 0)
        #expect(usage.count < 30)
    }

    @Test func uncachedHighlightsLeaveTheCacheAlone() {
        let highlighter = SyntaxHighlighter()
        _ = highlighter.highlight("let a = 1", language: "swift", font: font, cache: false)
        #expect(highlighter.highlightCacheUsage.count == 0)
    }
}

@MainActor
struct StreamingChatStateTests {
    private let turn = TurnID(rawValue: "t1")

    private func delta(_ text: String, block: String = "t1#text-0") -> AgentEvent {
        .textDelta(BlockDelta(turnID: turn, blockID: BlockID(rawValue: block), text: text))
    }

    @Test func aDeltaEditsTheLastRowInPlaceAsOneMutation() {
        let state = ChatState()
        state.apply(.turnStarted(TurnStarted(turnID: turn)))
        state.apply(delta("Hel"))
        let revision = state.rowsRevision
        let structural = state.structuralRevision
        let content = state.rows[0].contentRevision

        state.apply(delta("lo"))
        #expect(state.rows.count == 1)
        #expect(state.rows[0].text == "Hello")
        #expect(state.rowsRevision == revision + 1)
        #expect(state.rows[0].contentRevision == content + 1)
        #expect(state.structuralRevision == structural)
        #expect(state.lastMutation == .appendedText(rowIndex: 0))
    }

    @Test func anAppendToAnEarlierRowCountsAsStructural() {
        let state = ChatState()
        state.apply(.turnStarted(TurnStarted(turnID: turn)))
        state.apply(.thinkingDelta(BlockDelta(turnID: turn, blockID: BlockID(rawValue: "t1#think-0"), text: "Hm")))
        state.apply(delta("Answer"))
        let structural = state.structuralRevision

        state.apply(.thinkingDelta(BlockDelta(turnID: turn, blockID: BlockID(rawValue: "t1#think-0"), text: "m")))
        #expect(state.rows[0].text == "Hmm")
        #expect(state.lastMutation == .structural)
        #expect(state.structuralRevision == structural + 1)
    }

    @Test func removingAQueuedRowKeepsTheStreamingRowAddressable() {
        let state = ChatState()
        state.apply(.turnStarted(TurnStarted(turnID: turn)))
        state.appendUserMessage("later", comments: [], submissionID: "q1", isQueued: true)
        state.apply(delta("Hel"))
        state.removeQueuedRow(submissionID: "q1")
        state.apply(delta("lo"))
        #expect(state.rows.map(\.text) == ["Hello"])
    }

    @Test func streamingIntoTheLastRowReplacesOnlyThatDisplayRow() {
        let state = ChatState()
        state.apply(.turnStarted(TurnStarted(turnID: turn)))
        state.apply(.toolCall(ToolCall(
            turnID: turn, id: ToolCallID(rawValue: "c1"), name: "Read",
            displayName: "x.txt", input: .object(["file_path": .string("x.txt")])
        )))
        state.apply(delta("Hel"))
        let memo = TranscriptDisplay.Memo()
        func derive() -> [TranscriptRow] {
            TranscriptDisplay.rows(
                from: state.rows, keepLiveTurnExpanded: true, expanded: [], memo: memo,
                revision: state.rowsRevision, structuralRevision: state.structuralRevision
            )
        }
        let first = derive()
        let token = memo.structureToken

        state.apply(delta("lo"))
        let streamed = derive()
        #expect(memo.structureToken == token)
        #expect(streamed.count == first.count)
        let full = TranscriptDisplay.rows(
            from: state.rows, keepLiveTurnExpanded: true, expanded: [], memo: TranscriptDisplay.Memo()
        )
        #expect(streamed.map(\.id) == full.map(\.id))
        #expect(streamed.map(\.text) == full.map(\.text))
        #expect(streamed.map(\.contentRevision) == full.map(\.contentRevision))
        #expect(streamed.last?.text == "Hello")

        // Anything structural takes the full path again.
        state.apply(.toolCall(ToolCall(
            turnID: turn, id: ToolCallID(rawValue: "c2"), name: "Read",
            displayName: "y.txt", input: .object(["file_path": .string("y.txt")])
        )))
        _ = derive()
        #expect(memo.structureToken != token)
    }

    @Test func anUnconfirmedClaimExpiresWhenEngineAndHarnessStaySilent() {
        let state = ChatState()
        state.appendUserMessage("first", comments: [])
        let sent = state.lastEventAt ?? Date()

        state.reconcileTurnActive(false, now: sent.addingTimeInterval(2))
        #expect(state.isTurnActive)

        state.reconcileTurnActive(false, now: sent.addingTimeInterval(ChatState.unconfirmedClaimTimeout + 1))
        #expect(!state.isTurnActive)
        #expect(!state.isBusy)
        #expect(!state.willQueueNextMessage)
    }

    @Test func harnessOutputKeepsAnUnconfirmedClaimAlive() {
        let state = ChatState()
        state.appendUserMessage("first", comments: [])
        state.apply(.statusChanged(.requesting))
        let heard = state.lastEventAt ?? Date()
        state.reconcileTurnActive(false, now: heard.addingTimeInterval(ChatState.unconfirmedClaimTimeout - 2))
        #expect(state.isTurnActive)
    }
}
