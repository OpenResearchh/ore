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
    private var currentTurn: TurnState?

    private struct TurnState {
        var id: TurnID
        var ordinal: Int
        var nextBlockOrdinal: Int
        var startedAt: Date
        var prompt: String?
        var usage: UsageReport?
    }

    public init(
        store: OreStore,
        sessionID: SessionID,
        harness: HarnessKind = .claudeCode,
        chatID: ChatID? = nil
    ) {
        self.store = store
        self.sessionID = sessionID
        self.harness = harness
        self.chatID = chatID
    }

    /// Records the prompt that opens the next turn. Called on send, before the
    /// harness has told us anything, so the user's own message is never the
    /// thing that goes missing.
    public func recordPrompt(_ text: String) {
        pendingPrompt = text
    }

    private var pendingPrompt: String?

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
                prompt: pendingPrompt
            )
            pendingPrompt = nil
            currentTurn = state
            try await store.saveTurn(TurnRecord(
                id: state.id,
                sessionID: sessionID,
                ordinal: ordinal,
                prompt: state.prompt,
                checkpointCommit: pendingCheckpointCommit,
                checkpointProviderSessionID: pendingCheckpointSessionID,
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
            try await append(BlockRecord(
                id: "tool-\(call.id.rawValue)",
                turnID: call.turnID,
                ordinal: nextOrdinal(),
                kind: .toolCall,
                text: call.displayName ?? call.name,
                toolName: call.name,
                toolCallID: call.id,
                displayName: call.displayName,
                payload: call.input,
                parentToolCallID: call.parentToolCallID
            ))

        case .toolResult(let result):
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
            switch update.content {
            case .todos(let items):
                text = items.map { "\($0.status == .completed ? "x" : " ") \($0.text)" }
                    .joined(separator: "\n")
                payload = .array(items.map { item in
                    .object(["text": .string(item.text), "status": .string(item.status.rawValue)])
                })
            case .proposal(let markdown, let requestID):
                text = markdown
                payload = .object([
                    "kind": .string("proposal"),
                    "permissionRequestID": requestID.map { .string($0.rawValue) } ?? .null,
                ])
            }
            try await append(BlockRecord(
                id: "plan-\(update.turnID.rawValue)-\(nextOrdinalPreview())",
                turnID: update.turnID,
                ordinal: nextOrdinal(),
                kind: .plan,
                text: text,
                payload: payload
            ))

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
            guard var turn = currentTurn else { return }
            let usage = result.usage ?? turn.usage
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
                checkpointCommit: try await store.turn(result.turnID)?.checkpointCommit,
                checkpointProviderSessionID:
                    try await store.turn(result.turnID)?.checkpointProviderSessionID,
                startedAt: turn.startedAt,
                endedAt: Date()
            ))
            turn.usage = usage
            currentTurn = nil

        case .sessionEnded:
            currentTurn = nil

        case .textDelta, .thinkingDelta, .statusChanged, .rateLimit,
             .permissionResolved, .sessionError:
            // Deltas are for the live view only; the rest is either transient
            // state or already captured on the turn.
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
