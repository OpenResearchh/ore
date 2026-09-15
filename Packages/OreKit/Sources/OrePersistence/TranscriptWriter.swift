import Foundation
import OreProtocol

/// Turns the agent event stream into durable transcript rows.
///
/// The stream is the wrong shape for storage: a block of text arrives as
/// hundreds of deltas, and writing each one would mean hundreds of transactions
/// per paragraph. So deltas are only rendered live and never written — the
/// authoritative text arrives once, as `blockCompleted`, and that is what gets
/// persisted. What survives a crash is therefore whole blocks, which is exactly
/// what a transcript is made of.
public actor TranscriptWriter {
    private let store: OreStore
    private let sessionID: SessionID
    private let harness: HarnessKind
    private let chatID: ChatID?
    private let coalescingInterval: Duration
    private var currentTurn: TurnState?

    private struct TurnState {
        var id: TurnID
        var ordinal: Int
        var nextBlockOrdinal: Int
        var startedAt: Date
        var prompt: String?
        var promptAttachments: [Attachment]
        var promptOrigin: MessageOrigin
        var usage: UsageReport?
    }

    /// A tool call or plan row that is rewritten in place as it grows.
    ///
    /// Cursor re-emits a tool call every time its content grows and Codex
    /// streams plan deltas, and each write is a transaction plus a search-index
    /// update. So the row is written when first seen and when it completes; in
    /// between, a revision lands at most once per `coalescingInterval` and the
    /// newest one waits in `pending` for the next boundary.
    private struct UpsertedBlock {
        var ordinal: Int
        var createdAt: Date
        var lastWrite: ContinuousClock.Instant
        var pending: BlockRecord?
    }

    private var upserted: [String: UpsertedBlock] = [:]

    public init(
        store: OreStore,
        sessionID: SessionID,
        harness: HarnessKind = .claudeCode,
        chatID: ChatID? = nil,
        coalescingInterval: Duration = .milliseconds(500)
    ) {
        self.store = store
        self.sessionID = sessionID
        self.harness = harness
        self.chatID = chatID
        self.coalescingInterval = coalescingInterval
    }

    /// Records the prompt that opens the next turn. Called on send, before the
    /// harness has told us anything, so the user's own message is never the
    /// thing that goes missing.
    public func recordPrompt(
        _ text: String,
        attachments: [Attachment] = [],
        origin: MessageOrigin = .user
    ) {
        pendingPrompt = text
        pendingAttachments = attachments
        pendingOrigin = origin
    }

    private var pendingPrompt: String?
    private var pendingAttachments: [Attachment] = []
    private var pendingOrigin: MessageOrigin = .user

    /// Whether `handle` has anything to do with the event. Text and thinking
    /// deltas arrive at token rate and are never written, so the engine can
    /// skip the hop onto this actor for them.
    public static func persists(_ event: AgentEvent) -> Bool {
        switch event {
        case .textDelta, .thinkingDelta: false
        default: true
        }
    }

    public func handle(_ event: AgentEvent) async {
        do {
            try await apply(event)
        } catch {
            // Persistence failures must not take a live session down: the user
            // would rather keep talking to the agent than lose the session
            // because a write failed.
            persistenceFailures += 1
            lastPersistenceError = String(describing: error)
        }
    }

    /// Writes every coalesced revision still held in memory. The engine calls
    /// this when it stops a session, since a cancelled event loop never
    /// delivers the `sessionEnded` that would otherwise flush.
    public func flush() async {
        do {
            try await flushPending()
        } catch {
            persistenceFailures += 1
            lastPersistenceError = String(describing: error)
        }
    }

    public private(set) var persistenceFailures = 0
    public private(set) var lastPersistenceError: String?

    private func apply(_ event: AgentEvent) async throws {
        switch event {
        case .sessionStarted(let started):
            try await store.saveSession(SessionRecord(
                id: sessionID,
                workspaceID: workspaceID,
                chatID: chatID,
                providerSessionID: started.providerSessionID,
                harness: started.harness,
                model: started.model,
                harnessVersion: started.harnessVersion
            ))
            hasPersistedSession = true

        case .turnStarted(let started):
            // A turn that never completed must not strand its last revisions.
            try await flushPending()
            upserted.removeAll()
            // Every turn and block hangs off the session row by foreign key.
            // Waiting for `.sessionStarted` to create it would mean losing the
            // whole transcript from any harness that doesn't announce itself —
            // so the row is created on demand and enriched later.
            try await ensureSessionRow()
            let ordinal = try await store.nextTurnOrdinal(sessionID: sessionID)
            let state = TurnState(
                id: started.turnID,
                ordinal: ordinal,
                nextBlockOrdinal: 0,
                startedAt: Date(),
                prompt: pendingPrompt,
                promptAttachments: pendingAttachments,
                promptOrigin: pendingOrigin
            )
            pendingPrompt = nil
            pendingAttachments = []
            pendingOrigin = .user
            currentTurn = state
            try await store.saveTurn(TurnRecord(
                id: state.id,
                sessionID: sessionID,
                ordinal: ordinal,
                prompt: state.prompt,
                checkpointCommit: pendingCheckpointCommit,
                checkpointProviderSessionID: pendingCheckpointSessionID,
                attachments: state.promptAttachments,
                origin: state.promptOrigin,
                startedAt: state.startedAt
            ))
            pendingCheckpointCommit = nil
            pendingCheckpointSessionID = nil

        case .blockCompleted(let block):
            try await append(BlockRecord(
                id: block.blockID.rawValue,
                turnID: block.turnID,
                ordinal: nextOrdinal(),
                kind: block.kind == .thinking ? .thinking : .text,
                text: block.text,
                parentToolCallID: block.parentToolCallID
            ))

        case .toolCall(let call):
            // A call is complete when its result arrives, which flushes it.
            try await upsert(id: "tool-\(call.id.rawValue)", isFinal: false) { ordinal, createdAt in
                BlockRecord(
                    id: "tool-\(call.id.rawValue)",
                    turnID: call.turnID,
                    ordinal: ordinal,
                    kind: .toolCall,
                    text: call.displayName ?? call.name,
                    toolName: call.name,
                    toolCallID: call.id,
                    displayName: call.displayName,
                    payload: call.input,
                    parentToolCallID: call.parentToolCallID,
                    createdAt: createdAt
                )
            }

        case .toolResult(let result):
            try await flushPending(id: "tool-\(result.toolCallID.rawValue)")
            try await append(BlockRecord(
                id: "result-\(result.toolCallID.rawValue)",
                turnID: result.turnID,
                ordinal: nextOrdinal(),
                kind: .toolResult,
                // Tool output can be a whole file. Storing all of it would
                // bloat the database and the search index for text nobody
                // rereads; the head is what a reader actually scans.
                text: String(result.text.prefix(16_000)),
                toolCallID: result.toolCallID,
                isError: result.isError
            ))

        case .planUpdated(let update):
            let payload: JSONValue
            let text: String
            let stableID: String
            let isFinal: Bool
            switch update.content {
            case .todos(let items):
                text = items.map { "\($0.status == .completed ? "x" : " ") \($0.text)" }
                    .joined(separator: "\n")
                payload = .array(items.map { item in
                    .object(["text": .string(item.text), "status": .string(item.status.rawValue)])
                })
                stableID = "plan-\(update.turnID.rawValue)-todos"
                // A checklist has no completion of its own; turn end flushes it.
                isFinal = false
            case .proposal(let markdown, let requestID):
                text = markdown
                payload = .object([
                    "kind": .string("proposal"),
                    "permissionRequestID": requestID.map { .string($0.rawValue) } ?? .null,
                    "isReady": .bool(update.isReady),
                ])
                // One proposal row per turn: a CreatePlan `started` draft then
                // `completed` ready must not append a second block the tail
                // would miss or double.
                stableID = "plan-\(update.turnID.rawValue)-proposal"
                // A ready plan, or one an approval hangs off, is what a
                // relaunch must find — never left waiting in memory.
                isFinal = update.isReady || requestID != nil
            }
            try await upsert(id: stableID, isFinal: isFinal) { ordinal, createdAt in
                BlockRecord(
                    id: stableID,
                    turnID: update.turnID,
                    ordinal: ordinal,
                    kind: .plan,
                    text: text,
                    payload: payload,
                    createdAt: createdAt
                )
            }

        case .permissionRequest(let request):
            try await append(BlockRecord(
                id: "perm-\(request.id.rawValue)",
                turnID: request.turnID,
                ordinal: nextOrdinal(),
                kind: .permission,
                text: request.summary ?? request.toolName,
                toolName: request.toolName,
                toolCallID: request.toolCallID,
                displayName: request.displayName,
                payload: request.input
            ))

        case .question(let question):
            try await append(BlockRecord(
                id: "question-\(question.id.rawValue)",
                turnID: question.turnID,
                ordinal: nextOrdinal(),
                kind: .question,
                text: question.prompt,
                toolCallID: question.toolCallID,
                payload: .array(question.options.map { .string($0.label) })
            ))

        case .usage(let usage):
            currentTurn?.usage = usage

        case .turnCompleted(let result):
            try await flushPending()
            upserted.removeAll()
            guard var turn = currentTurn else { return }
            let usage = result.usage ?? turn.usage
            let stored = try await store.turn(result.turnID)
            try await store.saveTurn(TurnRecord(
                id: result.turnID,
                sessionID: sessionID,
                ordinal: turn.ordinal,
                prompt: turn.prompt,
                outcome: result.outcome,
                summary: result.summary,
                inputTokens: usage?.inputTokens ?? 0,
                outputTokens: usage?.outputTokens ?? 0,
                cacheReadTokens: usage?.cacheReadTokens ?? 0,
                cacheCreationTokens: usage?.cacheCreationTokens ?? 0,
                contextWindow: usage?.contextWindow,
                checkpointCommit: stored?.checkpointCommit,
                checkpointProviderSessionID: stored?.checkpointProviderSessionID,
                attachments: turn.promptAttachments,
                // The completed turn is written as a whole record, so the origin
                // has to be carried across or finishing a turn would relabel an
                // assistant-sent prompt as the user's.
                origin: turn.promptOrigin,
                startedAt: turn.startedAt,
                endedAt: Date()
            ))
            turn.usage = usage
            currentTurn = nil

        case .sessionEnded:
            try await flushPending()
            upserted.removeAll()
            currentTurn = nil

        case .contextCompacted(let compaction):
            // Persist as a notice block so the marker survives a relaunch, hung
            // off whichever turn was active when the harness compacted.
            guard let turn = currentTurn else { break }
            try await append(BlockRecord(
                id: "compaction-\(turn.id.rawValue)-\(nextOrdinalPreview())",
                turnID: compaction.turnID ?? turn.id,
                ordinal: nextOrdinal(),
                kind: .notice,
                text: compaction.summary
            ))

        case .textDelta, .thinkingDelta, .statusChanged, .rateLimit,
             .permissionResolved, .sessionError, .backgroundTasksChanged:
            // Deltas are for the live view only; the rest is either transient
            // state or already captured on the turn. Background work in
            // particular dies with the session, so a stored set would only ever
            // come back stale.
            break
        }
    }

    // MARK: - Checkpoint linkage

    private var hasPersistedSession = false

    private func ensureSessionRow() async throws {
        guard !hasPersistedSession else { return }
        try await store.saveSession(SessionRecord(
            id: sessionID,
            workspaceID: workspaceID,
            chatID: chatID,
            harness: harness
        ))
        hasPersistedSession = true
    }

    private var pendingCheckpointCommit: String?
    private var pendingCheckpointSessionID: String?
    private var workspaceID: WorkspaceID = WorkspaceID(rawValue: "")

    public func configure(workspaceID: WorkspaceID) {
        self.workspaceID = workspaceID
    }

    /// Attaches the checkpoint taken before the next turn runs, so a revert can
    /// restore both the tree and the conversation to the same instant.
    public func recordCheckpoint(commit: String, providerSessionID: String?) {
        pendingCheckpointCommit = commit
        pendingCheckpointSessionID = providerSessionID
    }

    // MARK: - Helpers

    private func append(_ record: BlockRecord) async throws {
        try await store.appendBlock(record)
    }

    /// Writes a row that is rewritten in place, keeping its first ordinal and
    /// creation time. See `UpsertedBlock` for when a revision is held back.
    private func upsert(
        id: String,
        isFinal: Bool,
        _ record: (_ ordinal: Int, _ createdAt: Date) -> BlockRecord
    ) async throws {
        let now = ContinuousClock.now
        if var known = upserted[id] {
            let revision = record(known.ordinal, known.createdAt)
            guard isFinal || known.lastWrite.duration(to: now) >= coalescingInterval else {
                known.pending = revision
                upserted[id] = known
                return
            }
            known.pending = nil
            known.lastWrite = now
            upserted[id] = known
            try await append(revision)
            return
        }
        // First sight in this writer. The row can still exist from an earlier
        // writer on the same session, so it is looked up once, not per revision.
        let existing = try await store.block(id)
        let ordinal = existing?.ordinal ?? nextOrdinal()
        let createdAt = existing?.createdAt ?? Date()
        try await append(record(ordinal, createdAt))
        upserted[id] = UpsertedBlock(ordinal: ordinal, createdAt: createdAt, lastWrite: now)
    }

    /// Writes held-back revisions — one row's, or all of them. Each is taken
    /// out before its write so a reentrant event can't write it twice.
    private func flushPending(id: String? = nil) async throws {
        let ids = id.map { [$0] } ?? upserted.compactMap { $0.value.pending == nil ? nil : $0.key }
        for id in ids {
            guard var known = upserted[id], let revision = known.pending else { continue }
            known.pending = nil
            known.lastWrite = ContinuousClock.now
            upserted[id] = known
            try await append(revision)
        }
    }

    private func nextOrdinal() -> Int {
        guard var turn = currentTurn else { return 0 }
        let ordinal = turn.nextBlockOrdinal
        turn.nextBlockOrdinal += 1
        currentTurn = turn
        return ordinal
    }

    private func nextOrdinalPreview() -> Int {
        currentTurn?.nextBlockOrdinal ?? 0
    }
}
