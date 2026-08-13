import Foundation

/// Merges consecutive text/thinking deltas that belong to the same block.
///
/// A fast model emits deltas far more often than a display can use them. Every
/// delta that reaches the UI costs a layout pass on the transcript, which is the
/// single hottest surface in the app, so we batch them: the core buffers deltas
/// and flushes at a fixed cadence (~30–60Hz), coalescing each block's pending
/// text into one event. Non-delta events flush the buffer first so ordering is
/// never disturbed — a tool call always lands after the text that preceded it.
public struct TextDeltaCoalescer: Sendable {
    private struct PendingKey: Hashable {
        var blockID: BlockID
        var isThinking: Bool
    }

    private struct Pending {
        var delta: BlockDelta
        /// Preserves relative order between blocks when several stream at once
        /// (an agent writing text while a subagent thinks).
        var sequence: Int
    }

    private var pending: [PendingKey: Pending] = [:]
    private var nextSequence = 0

    public init() {}

    public var hasPendingDeltas: Bool { !pending.isEmpty }

    /// Absorbs one event. Returns the events to forward *now* — empty when the
    /// event was buffered, and for a non-delta event the buffered deltas
    /// followed by the event itself.
    public mutating func absorb(_ event: AgentEvent) -> [AgentEvent] {
        switch event {
        case .textDelta(let delta):
            append(delta, isThinking: false)
            return []
        case .thinkingDelta(let delta):
            append(delta, isThinking: true)
            return []
        default:
            return flush() + [event]
        }
    }

    /// Emits everything buffered so far. Call on the flush timer, and before
    /// any state the UI reads synchronously.
    public mutating func flush() -> [AgentEvent] {
        guard !pending.isEmpty else { return [] }
        let ordered = pending.sorted { $0.value.sequence < $1.value.sequence }
        pending.removeAll(keepingCapacity: true)
        nextSequence = 0
        return ordered.map { key, value in
            key.isThinking ? .thinkingDelta(value.delta) : .textDelta(value.delta)
        }
    }

    private mutating func append(_ delta: BlockDelta, isThinking: Bool) {
        let key = PendingKey(blockID: delta.blockID, isThinking: isThinking)
        if var existing = pending[key] {
            existing.delta.text += delta.text
            pending[key] = existing
        } else {
            pending[key] = Pending(delta: delta, sequence: nextSequence)
            nextSequence += 1
        }
    }
}
