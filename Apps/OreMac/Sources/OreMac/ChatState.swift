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
    private(set) var rows: [TranscriptRow] = [] {
        didSet { rowsRevision &+= 1 }
    }
    /// Bumped on every `rows` mutation (in-place edits included). Lets the pane
    /// memoize its derived display rows instead of regrouping the whole
    /// transcript on every body evaluation — at 40 flushes/second while text
    /// streams, that regrouping was a large share of the main thread.
    private(set) var rowsRevision = 0
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

    /// The agent is actively producing — the spinner, the elapsed timer, the
    /// live turn staying expanded. Deliberately *not* the same question as
    /// whether a message would queue: an agent blocked on a permission prompt
    /// has stopped working but has not finished its turn.
    var isBusy: Bool {
        status == .thinking || status == .requesting || status == .runningTool
    }

    /// Whether the next message sent will be queued instead of delivered.
    ///
    /// Mirrors the engine's own gate rather than guessing from `status`. The two
    /// disagree precisely where it matters — an agent awaiting a permission
    /// answer reads as not-busy while its turn is still open — and the composer
    /// promising "Send" for a message the engine then queued is what made a sent
    /// message appear to vanish.
    var willQueueNextMessage: Bool { isTurnActive }

    /// What the send button promises, when what it promises is not "send".
    /// `awaitingInput` gets its own wording because it is the case that used to
    /// look idle: the agent has stopped working, so "queued" on its own reads as
    /// a bug rather than as the turn still being open on a question.
    var queueHint: String? {
        guard willQueueNextMessage else { return nil }
        if status == .awaitingInput {
            return "Queue this message — the agent is waiting on your answer (⌘↩)"
        }
        return "Queue this message (⌘↩)"
    }

    /// The client's copy of the engine's `isTurnActive`. Driven by turn events,
    /// and optimistically by our own send so the very next keystroke is judged
    /// against the turn we just started rather than the one that just ended.
    private(set) var isTurnActive = false

    /// Reconciles against the engine's published gate. Events are the fast path;
    /// this is the correction when the two have drifted — a turn that ended in a
    /// way the client never saw an event for, say a session killed underneath it.
    func reconcileTurnActive(_ serverValue: Bool) {
        // Our optimistic claim is newer than the summary that crossed it in
        // flight: keep it until a turn event or a later summary agrees.
        if isTurnActive, !serverValue, !hasTurnEventArrived { return }
        isTurnActive = serverValue
    }

    /// When the current turn began, for the live "time elapsed" counter. Nil
    /// while idle.
    private(set) var turnStartedAt: Date?

    /// False between the user pressing send and the harness reporting its
    /// first turn event — the window where a one-shot CLI (Cursor) is still
    /// booting and the UI would otherwise look stuck.
    private(set) var hasTurnEventArrived = true

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
            isTurnActive = true
            streamingRowIndex.removeAll()
            turnStartedAt = Date()
            hasTurnEventArrived = true
            // A turn starting is what a queued message was waiting for. The
            // oldest pending row is the one it drained, so it stops being
            // pending and joins the turn it actually became.
            claimOldestPendingRow(turnID: turn.turnID)
            // A new turn means the user pressed on past the last failure, and
            // past any plan that was still awaiting an answer.
            prominentError = nil
            plan = nil

        case .textDelta(let delta):
            append(delta: delta, kind: .assistantText)

        case .thinkingDelta(let delta):
            append(delta: delta, kind: .thinking)

        case .blockCompleted(let block):
            complete(block)

        case .toolCall(let call):
            // Cursor (and similar) re-emits the same call as `streamContent`
            // grows and again on completion with the real diff. Updating the
            // existing row keeps the chip live without duplicating it.
            if let index = rows.lastIndex(where: { $0.toolCallID == call.id }) {
                rows[index].text = call.displayName ?? call.name
                rows[index].toolName = call.name
                rows[index].toolInput = call.input
                rows[index].parentToolCallID = call.parentToolCallID
                return
            }
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
            // The plan card is gated on the *same* permission request. Without
            // this it survived its own approval, so a second proposal left two
            // cards and answering either one left the other on screen forever.
            resolvePlan(requestID: resolution.id)

        case .question(let question):
            pendingQuestion = question
            status = .awaitingInput

        case .usage(let report):
            // Mid-turn usage reports (one per assistant message) don't carry the
            // context window — only the end-of-turn `result` does. Overwriting
            // wholesale therefore blanked the context meter for the rest of the
            // turn (it hides when the window is nil), which read as "the meter
            // stopped updating". Carry the last known window forward instead, so
            // it keeps tracking as the harness streams and after it auto-compacts.
            var merged = report
            if merged.contextWindow == nil { merged.contextWindow = usage?.contextWindow }
            usage = merged

        case .rateLimit(let report):
            rateLimit = report
            if prominentError?.isUsageLimit == true {
                prominentError?.resetsAt = report.resetsAt ?? prominentError?.resetsAt
            }

        case .turnCompleted(let result):
            currentTurnID = nil
            isTurnActive = false
            streamingRowIndex.removeAll()
            turnStartedAt = nil
            hasTurnEventArrived = true
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
            // The engine drops its own claim here; a session that died mid-turn
            // never reports `.turnCompleted`, and a composer left believing a
            // turn is open would queue every later message behind a dead one.
            isTurnActive = false

        case .contextCompacted(let compaction):
            // The harness summarised its own history to stay under the window.
            // A divider makes that visible instead of the conversation just
            // carrying on as if nothing changed.
            rows.append(TranscriptRow(
                id: "compaction-\(rows.count)",
                turnID: compaction.turnID ?? currentTurnID ?? TurnID(rawValue: "compaction"),
                kind: .divider,
                text: compaction.summary,
                isComplete: true
            ))
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
        // The engine queues whenever a turn is open, so predicting the same
        // thing here is what keeps the row the user sees honest.
        let willQueue = willQueueNextMessage
        rows.append(TranscriptRow(
            id: "user-\(UUID().uuidString)",
            turnID: currentTurnID ?? TurnID(rawValue: "pending"),
            kind: .userMessage,
            text: text,
            isQueued: willQueue,
            attachedComments: comments,
            attachments: attachments
        ))
        guard !willQueue else {
            // Nothing has been handed to the agent, so claiming a turn started
            // would run a spinner and an elapsed timer against a message that is
            // sitting in a queue. The row says "queued" instead.
            return
        }
        // Optimistic: the agent hasn't reported anything yet, but the user
        // pressed send and the UI must not look idle. The timer starts now so
        // a slow-booting CLI still shows elapsed time; `.turnStarted`
        // overwrites it with the harness's own clock.
        status = .requesting
        turnStartedAt = Date()
        hasTurnEventArrived = false
        // Claim the turn locally for the same reason the engine claims it before
        // its own awaits: a second message typed in the gap before `.turnStarted`
        // must be judged against this turn, not the absence of one.
        isTurnActive = true
    }

    /// A queued row becomes a real one when the turn it was waiting for starts.
    private func claimOldestPendingRow(turnID: TurnID) {
        guard let index = rows.firstIndex(where: { $0.isQueued }) else { return }
        rows[index].isQueued = false
        rows[index].turnID = turnID
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
        resolvePlan(requestID: id)
    }

    /// Dismisses the plan card once its approval has been answered.
    ///
    /// A proposal with no request id is informational — the harness is showing
    /// a plan, not asking about one — so it is dismissed on any resolution
    /// rather than waiting for an id that will never arrive.
    private func resolvePlan(requestID: PermissionRequestID) {
        guard case .proposal(_, let planRequestID) = plan else { return }
        guard planRequestID == nil || planRequestID == requestID else { return }
        plan = nil
    }

    /// The user answered the plan card directly (approve, or reject with
    /// feedback). Clears it immediately rather than waiting for the harness to
    /// echo a resolution that, for a plan with no request id, never comes.
    func dismissPlan() { plan = nil }

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
        /// The closing line of a finished turn: what it changed, how long it
        /// took, and the actions that apply to the turn as a whole.
        case turnFooter
    }

    let id: String
    /// Not `let`: a queued message is written before the turn it will land in
    /// exists, and adopts that turn's id when the turn finally starts.
    var turnID: TurnID
    let kind: Kind
    var text: String
    /// Written but not yet handed to the agent — it is sitting in the engine's
    /// queue behind an open turn. Drawn as pending, and cleared when a turn
    /// starts and claims it.
    var isQueued = false
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
    /// When this row launched a subagent (a Task tool call), how many tool uses
    /// ran inside it. Set while assembling the display list; it turns the row
    /// into a collapsible group whose children fold away beneath it.
    var subagentChildCount: Int?
    var createdAt: Date = Date()
    /// A subject resolved from elsewhere in the transcript rather than from
    /// this row's own payload. A `TaskUpdate` names its task only by id, so the
    /// human title has to come from the `TaskCreate` that made it.
    var resolvedSubject: String?

    var activitySignature: Int {
        var hasher = Hasher()
        hasher.combine(resolvedSubject)
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
