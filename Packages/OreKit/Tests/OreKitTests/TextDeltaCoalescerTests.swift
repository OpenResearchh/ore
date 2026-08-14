import Testing

@testable import OreProtocol

struct TextDeltaCoalescerTests {
    private func delta(_ block: String, _ text: String) -> BlockDelta {
        BlockDelta(turnID: TurnID(rawValue: "t1"), blockID: BlockID(rawValue: block), text: text)
    }

    @Test func consecutiveDeltasForOneBlockCollapseIntoOne() {
        var coalescer = TextDeltaCoalescer()
        #expect(coalescer.absorb(.textDelta(delta("b1", "hel"))).isEmpty)
        #expect(coalescer.absorb(.textDelta(delta("b1", "lo "))).isEmpty)
        #expect(coalescer.absorb(.textDelta(delta("b1", "ore"))).isEmpty)

        let flushed = coalescer.flush()
        #expect(flushed.count == 1)
        guard case .textDelta(let merged)? = flushed.first else {
            Issue.record("expected one merged text delta")
            return
        }
        #expect(merged.text == "hello ore")
        #expect(!coalescer.hasPendingDeltas)
    }

    @Test func textAndThinkingAreNeverMerged() {
        var coalescer = TextDeltaCoalescer()
        _ = coalescer.absorb(.thinkingDelta(delta("b1", "hmm")))
        _ = coalescer.absorb(.textDelta(delta("b1", "answer")))

        let flushed = coalescer.flush()
        #expect(flushed.count == 2)
        // The thinking arrived first and must still be first.
        guard case .thinkingDelta = flushed[0] else {
            Issue.record("thinking must keep its position")
            return
        }
    }

    @Test func interleavedBlocksKeepTheirRelativeOrder() {
        var coalescer = TextDeltaCoalescer()
        _ = coalescer.absorb(.textDelta(delta("b1", "a")))
        _ = coalescer.absorb(.textDelta(delta("b2", "x")))
        _ = coalescer.absorb(.textDelta(delta("b1", "b")))

        let flushed = coalescer.flush()
        #expect(flushed.count == 2)
        guard case .textDelta(let first) = flushed[0], case .textDelta(let second) = flushed[1]
        else {
            Issue.record("expected two text deltas")
            return
        }
        #expect(first.blockID == BlockID(rawValue: "b1"))
        #expect(first.text == "ab")
        #expect(second.blockID == BlockID(rawValue: "b2"))
    }

    @Test func nonDeltaEventsFlushPendingTextFirst() {
        // Ordering is the whole point: a tool call must never appear above the
        // text that introduced it.
        var coalescer = TextDeltaCoalescer()
        _ = coalescer.absorb(.textDelta(delta("b1", "running tests")))

        let call = ToolCall(
            turnID: TurnID(rawValue: "t1"),
            id: ToolCallID(rawValue: "tool1"),
            name: "Bash",
            input: .object([:])
        )
        let emitted = coalescer.absorb(.toolCall(call))

        #expect(emitted.count == 2)
        guard case .textDelta = emitted[0], case .toolCall = emitted[1] else {
            Issue.record("text must be flushed before the tool call")
            return
        }
        #expect(!coalescer.hasPendingDeltas)
    }

    @Test func flushingAnEmptyBufferProducesNothing() {
        var coalescer = TextDeltaCoalescer()
        #expect(coalescer.flush().isEmpty)
    }
}
