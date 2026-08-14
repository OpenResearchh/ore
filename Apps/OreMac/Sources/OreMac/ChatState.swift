import Foundation
import Observation
import OreProtocol

/// One workspace's transcript, as the UI needs it.
///
/// The event stream is a sequence of edits; a transcript is a list of rows.
/// This is where one becomes the other — and where streaming is made cheap:
/// a delta mutates the last row's text in place rather than appending a row, so
/// a paragraph arriving as three hundred deltas is three hundred text mutations
/// and one row insertion, not three hundred insertions.
@MainActor
@Observable
final class ChatState {
    private(set) var rows: [TranscriptRow] = []
    private(set) var status: AgentStatus = .idle
    private(set) var usage: UsageReport?
    private(set) var pendingPermission: PermissionRequest?
    private(set) var pendingQuestion: AgentQuestion?
    private(set) var plan: PlanUpdate.Content?
    private(set) var rateLimit: RateLimitReport?
    private(set) var lastError: SessionError?

    /// The most recent hard failure worth surfacing next to the composer — a
    /// failed turn (usage limits, provider errors) or a session error — instead
    /// of only as a red row that scrolls away in the transcript. Cleared when
    /// the next turn starts, and dismissable by the user.
    struct ProminentError: Equatable {
        var message: String
        var isUsageLimit: Bool
        var resetsAt: Date?
    }
    private(set) var prominentError: ProminentError?

    func dismissProminentError() { prominentError = nil }

    /// Files attached to the unsent draft. Kept on the chat, not the pane, so
    /// switching tabs restores chips and mention pills instead of leaving bare
    /// `@pasted-image.png` text.
    var draftAttachments: [Attachment] = []

    private static func looksLikeUsageLimit(_ text: String) -> Bool {
        let value = text.lowercased()
        return value.contains("usage limit")
            || value.contains("session limit")
            || value.contains("rate limit")
            || value.contains("rate-limit")
            || value.contains("quota")
            || value.contains("upgrade to pro")
            || value.contains("purchase more credits")
            || value.contains("too many requests")
    }

    /// Comments the user has left on the diff but not yet sent. Review is a
    /// pass over the diff, not one message per note.
    private(set) var draftComments: [DiffCommentReference] = []

    var isBusy: Bool {
        status == .thinking || status == .requesting || status == .runningTool
    }

    /// When the current turn began, for the live "time elapsed" counter. Nil
    /// while idle.
    private(set) var turnStartedAt: Date?

    /// Index of the row a delta should append to, so streaming doesn't scan.
    private var streamingRowIndex: [BlockID: Int] = [:]
    private var currentTurnID: TurnID?

    // MARK: - Applying events

    func apply(_ event: AgentEvent) {
        switch event {
        case .sessionStarted:
            break

        case .statusChanged(let newStatus):
            status = newStatus

        case .turnStarted(let turn):
            currentTurnID = turn.turnID
            streamingRowIndex.removeAll()
            turnStartedAt = Date()
            // A new turn means the user pressed on past the last failure.
            prominentError = nil

        case .textDelta(let delta):
            append(delta: delta, kind: .assistantText)

        case .thinkingDelta(let delta):
            append(delta: delta, kind: .thinking)

        case .blockCompleted(let block):
            complete(block)

        case .toolCall(let call):
            rows.append(TranscriptRow(
                id: "tool-\(call.id.rawValue)",
                turnID: call.turnID,
                kind: .toolCall,
                text: call.displayName ?? call.name,
                toolName: call.name,
                toolCallID: call.id,
                parentToolCallID: call.parentToolCallID,
                toolInput: call.input
            ))

        case .toolResult(let result):
            attach(result)

        case .planUpdated(let update):
            plan = update.content
            if case .proposal(let markdown, let requestID) = update.content {
                rows.append(TranscriptRow(
                    id: "plan-\(update.turnID.rawValue)-\(rows.count)",
                    turnID: update.turnID,
                    kind: .plan,
                    text: markdown,
                    permissionRequestID: requestID
                ))
            }

        case .permissionRequest(let request):
            pendingPermission = request
            status = .awaitingInput

        case .permissionResolved(let resolution):
            if pendingPermission?.id == resolution.id { pendingPermission = nil }

        case .question(let question):
            pendingQuestion = question
            status = .awaitingInput

        case .usage(let report):
            usage = report

        case .rateLimit(let report):
            rateLimit = report
            if prominentError?.isUsageLimit == true {
                prominentError?.resetsAt = report.resetsAt ?? prominentError?.resetsAt
            }

        case .turnCompleted(let result):
            currentTurnID = nil
            streamingRowIndex.removeAll()
            turnStartedAt = nil
            if result.outcome == .failed, let message = result.errorMessage {
                rows.append(TranscriptRow(
                    id: "error-\(result.turnID.rawValue)",
                    turnID: result.turnID,
                    kind: .error,
                    text: message
                ))
                prominentError = ProminentError(
                    message: message,
                    isUsageLimit: Self.looksLikeUsageLimit(message),
                    resetsAt: rateLimit?.resetsAt
                        ?? UsageLimitReset.parse(message)
                )
            }

        case .sessionError(let error):
            lastError = error
            rows.append(TranscriptRow(
                id: "session-error-\(rows.count)",
                turnID: currentTurnID ?? TurnID(rawValue: "none"),
                kind: .error,
                text: error.message
            ))
            prominentError = ProminentError(
                message: error.message,
                isUsageLimit: error.kind == .rateLimited
                    || Self.looksLikeUsageLimit(error.message),
                resetsAt: rateLimit?.resetsAt
                    ?? UsageLimitReset.parse(error.message)
                    ?? UsageLimitReset.parse(error.detail ?? "")
            )

        case .sessionEnded:
            status = .idle
        }
    }

    /// Replaces the transcript with rows loaded from storage.
    ///
    /// A workspace's conversation outlives the app: the agent session is
    /// resumed on relaunch, so showing an empty chat would misrepresent what
    /// the agent remembers. History is loaded once, before live events are
    /// applied on top.
    func loadHistory(_ historicalRows: [TranscriptRow]) {
        guard !hasLoadedHistory else { return }
        hasLoadedHistory = true
        // Live events may already have arrived; history belongs before them.
        rows = historicalRows + rows
    }

    private(set) var hasLoadedHistory = false

    // MARK: - Local edits

    func appendUserMessage(
        _ text: String,
        attachments: [Attachment] = [],
        comments: [DiffCommentReference]
    ) {
        rows.append(TranscriptRow(
            id: "user-\(UUID().uuidString)",
            turnID: currentTurnID ?? TurnID(rawValue: "pending"),
            kind: .userMessage,
            text: text,
            attachedComments: comments,
            attachments: attachments
        ))
        // Optimistic: the agent hasn't reported anything yet, but the user
        // pressed send and the UI must not look idle.
        status = .requesting
    }

    func addDraftComment(_ reference: DiffCommentReference) {
        draftComments.append(reference)
    }

    func removeDraftComment(at index: Int) {
        guard draftComments.indices.contains(index) else { return }
        draftComments.remove(at: index)
    }

    func takeDraftComments() -> [DiffCommentReference] {
        defer { draftComments.removeAll() }
        return draftComments
    }

    func resolvePermission(_ id: PermissionRequestID) {
        if pendingPermission?.id == id { pendingPermission = nil }
    }

    func resolveQuestion(_ id: QuestionID) {
        if pendingQuestion?.id == id { pendingQuestion = nil }
    }

    /// Turns the user can revert to — every turn that produced something.
    var revertableTurns: [TurnID] {
        var seen: Set<TurnID> = []
        return rows.compactMap { row in
            guard row.kind == .userMessage, !seen.contains(row.turnID) else { return nil }
            seen.insert(row.turnID)
            return row.turnID
        }
    }

    // MARK: - Row assembly

    private func append(delta: BlockDelta, kind: TranscriptRow.Kind) {
        if let index = streamingRowIndex[delta.blockID], rows.indices.contains(index) {
            rows[index].text += delta.text
            return
        }
        rows.append(TranscriptRow(
            id: delta.blockID.rawValue,
            turnID: delta.turnID,
            kind: kind,
            text: delta.text,
            parentToolCallID: delta.parentToolCallID
        ))
        streamingRowIndex[delta.blockID] = rows.count - 1
    }

    /// The completed block is authoritative: it replaces whatever the deltas
    /// assembled, so a dropped delta can't leave the transcript subtly wrong.
    private func complete(_ block: BlockCompleted) {
        let kind: TranscriptRow.Kind = block.kind == .thinking ? .thinking : .assistantText
        if let index = streamingRowIndex[block.blockID], rows.indices.contains(index) {
            rows[index].text = block.text
            rows[index].isComplete = true
            return
        }
        guard !block.text.isEmpty else { return }
        rows.append(TranscriptRow(
            id: block.blockID.rawValue,
            turnID: block.turnID,
            kind: kind,
            text: block.text,
            parentToolCallID: block.parentToolCallID,
            isComplete: true
        ))
    }

    private func attach(_ result: ToolResult) {
        guard let index = rows.lastIndex(where: { $0.toolCallID == result.toolCallID }) else {
            return
        }
        rows[index].resultText = result.text
        rows[index].resultMetadata = result.metadata
        rows[index].isError = result.isError
        rows[index].isComplete = true
    }
}

/// One row in the transcript.
struct TranscriptRow: Identifiable, Sendable {
    enum Kind: Sendable {
        case userMessage
        case assistantText
        case thinking
        case toolCall
        case plan
        case error
        case divider
        /// Intermediate reasoning, progress messages, and tool calls folded
        /// into one turn-level activity section.
        case activityGroup
    }

    let id: String
    let turnID: TurnID
    let kind: Kind
    var text: String
    var toolName: String?
    var toolCallID: ToolCallID?
    /// The subagent (Task) tool call this row belongs to, when it was produced
    /// inside a subagent rather than the main conversation. Drives indentation.
    var parentToolCallID: ToolCallID?
    var toolInput: JSONValue?
    var resultText: String?
    var resultMetadata: JSONValue?
    var isError = false
    var isComplete = false
    var permissionRequestID: PermissionRequestID?
    var attachedComments: [DiffCommentReference] = []
    var attachments: [Attachment] = []
    var groupedRows: [TranscriptRow] = []
    var isExpanded = false
    var createdAt: Date = Date()

    var activitySignature: Int {
        var hasher = Hasher()
        for row in groupedRows {
            hasher.combine(row.id)
            hasher.combine(row.text)
            hasher.combine(row.resultText)
            hasher.combine(row.isComplete)
            hasher.combine(row.isError)
        }
        return hasher.finalize()
    }
}
