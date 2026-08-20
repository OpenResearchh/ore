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
        didSet {
            rowsRevision &+= 1
            let nowHasRows = !rows.isEmpty
            if hasRows != nowHasRows { hasRows = nowHasRows }
        }
    }
    /// Bumped on every `rows` mutation (in-place edits included). Lets the pane
    /// memoize its derived display rows instead of regrouping the whole
    /// transcript on every body evaluation — at 40 flushes/second while text
    /// streams, that regrouping was a large share of the main thread.
    private(set) var rowsRevision = 0
    /// Emptiness without observing `rows` itself. The empty-state check used to
    /// subscribe the whole chat pane to every streaming mutation.
    private(set) var hasRows = false
    private(set) var status: AgentStatus = .idle
    private(set) var usage: UsageReport?
    private(set) var pendingPermission: PermissionRequest?
    private(set) var pendingQuestion: AgentQuestion?
    private(set) var plan: PlanUpdate.Content?
    /// Turn that currently owns the approval card, so the transcript can hide
    /// its duplicate PLAN row while the card is up.
    private(set) var planTurnID: TurnID?
    private(set) var rateLimit: RateLimitReport?
    private(set) var lastError: SessionError?

    /// The most recent hard failure worth surfacing next to the composer — a
    /// failed turn (usage limits, provider errors) or a session error — instead
    /// of only as a red row that scrolls away in the transcript. Cleared when
    /// the next turn starts, and dismissable by the user.
    struct ProminentError: Equatable {
        var message: String
        var isUsageLimit: Bool
        var needsCLIUpgrade: Bool
        var resetsAt: Date?

        init(message: String, isUsageLimit: Bool, resetsAt: Date?, needsCLIUpgrade: Bool = false) {
            let unwrapped = ProviderErrorCopy.unwrap(message)
            self.message = unwrapped
            self.needsCLIUpgrade = needsCLIUpgrade || ProviderErrorCopy.needsCLIUpgrade(unwrapped)
            self.isUsageLimit = !self.needsCLIUpgrade && isUsageLimit
            self.resetsAt = resetsAt
        }
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

    /// The agent is actively producing — the spinner, the elapsed timer.
    /// Deliberately *not* the same question as whether a turn is still open:
    /// an agent blocked on a permission prompt has stopped working (`isBusy`
    /// is false) but the turn stays expanded via `isTurnActive`, so thinking
    /// does not collapse the moment a permission card appears.
    ///
    /// An open turn still counts as busy even if the last status event was
    /// `idle`. Claude reports `session_state_changed: idle` between tool calls,
    /// and treating that as a finished turn hid the composer chrome while
    /// messages kept queueing.
    var isBusy: Bool {
        if status == .awaitingInput { return false }
        if isTurnActive { return true }
        return status == .thinking || status == .requesting || status == .runningTool
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

    /// Last agent event in the open turn. The composer uses this to say
    /// "No output for Xm" when the harness goes silent mid-tool.
    private(set) var lastEventAt: Date?

    /// Human-readable phrase for the in-flight tool, e.g. "Reading ChatPane.swift".
    private(set) var runningToolLabel: String?

    /// False between the user pressing send and the harness reporting its
    /// first turn event — the window where a one-shot CLI (Cursor) is still
    /// booting and the UI would otherwise look stuck.
    private(set) var hasTurnEventArrived = true

    /// Index of the row a delta should append to, so streaming doesn't scan.
    private var streamingRowIndex: [BlockID: Int] = [:]
    private var currentTurnID: TurnID?

    // MARK: - Applying events

    func apply(_ event: AgentEvent) {
        lastEventAt = Date()
        switch event {
        case .sessionStarted:
            break

        case .statusChanged(let newStatus):
            // A Cursor (and similar) turn that proposed a plan then exits still
            // needs the user. Don't let the harness's trailing `idle` hide that.
            if (newStatus == .idle || newStatus == .interrupted),
               case .proposal = plan {
                status = .awaitingInput
            } else {
                status = newStatus
            }

        case .turnStarted(let turn):
            currentTurnID = turn.turnID
            isTurnActive = true
            streamingRowIndex.removeAll()
            turnStartedAt = Date()
            lastEventAt = turnStartedAt
            runningToolLabel = nil
            hasTurnEventArrived = true
            // A turn starting is what a queued message was waiting for. The
            // oldest pending row is the one it drained, so it stops being
            // pending and joins the turn it actually became.
            claimOldestPendingRow(turnID: turn.turnID)
            // A new turn means the user pressed on past the last failure, and
            // past any plan that was still awaiting an answer.
            prominentError = nil
            clearPlan()

        case .textDelta(let delta):
            append(delta: delta, kind: .assistantText)

        case .thinkingDelta(let delta):
            append(delta: delta, kind: .thinking)

        case .blockCompleted(let block):
            complete(block)

        case .toolCall(let call):
            // Cursor (and similar) often CreatePlan then edit in the same turn.
            // The card is only for a decision; once the agent is writing, it
            // has moved on — leaving `.proposal` up is why it survived Approve
            // and came back after an app switch.
            if case .proposal = plan, Self.proceedsPastPlanProposal(call.name) {
                clearPlan()
            }
            // Cursor (and similar) re-emits the same call as `streamContent`
            // grows and again on completion with the real diff. Updating the
            // existing row keeps the chip live without duplicating it.
            if let index = rows.lastIndex(where: { $0.toolCallID == call.id }) {
                mutateRow(at: index) { row in
                    row.text = call.displayName ?? call.name
                    row.toolName = call.name
                    row.toolInput = call.input
                    row.parentToolCallID = call.parentToolCallID
                }
                runningToolLabel = Self.runningToolPhrase(name: call.name, displayName: call.displayName)
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
            runningToolLabel = Self.runningToolPhrase(name: call.name, displayName: call.displayName)

        case .toolResult(let result):
            attach(result)

        case .planUpdated(let update):
            if case .proposal(let markdown, let requestID) = update.content {
                plan = update.content
                planTurnID = update.turnID
                status = .awaitingInput
                if let index = rows.lastIndex(where: {
                    $0.kind == .plan && $0.turnID == update.turnID
                }) {
                    mutateRow(at: index) { row in
                        row.text = markdown
                        row.permissionRequestID = requestID
                    }
                } else {
                    rows.append(TranscriptRow(
                        id: "plan-\(update.turnID.rawValue)-\(rows.count)",
                        turnID: update.turnID,
                        kind: .plan,
                        text: markdown,
                        permissionRequestID: requestID
                    ))
                }
            } else if case .proposal = plan {
                // A TodoWrite after CreatePlan must not dismiss the approval card.
                break
            } else {
                plan = update.content
                planTurnID = nil
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
            resumeTurnAfterInput()

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
            lastEventAt = nil
            runningToolLabel = nil
            hasTurnEventArrived = true
            // A proposal that arrived before we saw the Edit events still has
            // to drop: the turn already mutated the tree, so there is nothing
            // left to approve. Status was forced to `awaitingInput` by the
            // trailing `idle` while `.proposal` was still set.
            if clearPlanIfTurnAlreadyProceeded(result.turnID),
               status == .awaitingInput {
                status = .idle
            }
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
                    ?? UsageLimitReset.parse(error.detail ?? ""),
                needsCLIUpgrade: error.kind == .protocolMismatch
                    || ProviderErrorCopy.needsCLIUpgrade(error.message)
            )
            // A turn claimed on send that no harness event ever confirmed, and
            // now the session has failed: the turn never started, so release it.
            //
            // Nothing else will. The engine drops its own claim and republishes,
            // but `reconcileTurnActive` keeps an unconfirmed local claim on
            // purpose — it can't tell a correction from a summary that crossed
            // the send in flight. Without this the tab runs an elapsed timer
            // against a turn that does not exist, and the composer queues every
            // later message behind it. A claim the harness *has* reported on is
            // left alone: that turn is real and may still complete.
            if isTurnActive, !hasTurnEventArrived {
                status = .idle
                isTurnActive = false
                turnStartedAt = nil
                lastEventAt = nil
                runningToolLabel = nil
            }

        case .sessionEnded:
            status = .idle
            // The engine drops its own claim here; a session that died mid-turn
            // never reports `.turnCompleted`, and a composer left believing a
            // turn is open would queue every later message behind a dead one.
            isTurnActive = false
            turnStartedAt = nil
            lastEventAt = nil
            runningToolLabel = nil

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
        refreshRevertableTurns()
    }

    private(set) var hasLoadedHistory = false

    // MARK: - Local edits

    func appendUserMessage(
        _ text: String,
        attachments: [Attachment] = [],
        comments: [DiffCommentReference],
        origin: MessageOrigin = .user,
        submissionID: String = UUID().uuidString,
        isQueued: Bool? = nil
    ) {
        // The engine queues whenever a turn is open, so predicting the same
        // thing here is what keeps the row the user sees honest. A prompt the
        // engine already ruled on brings its own answer and skips the guess.
        let willQueue = isQueued ?? willQueueNextMessage
        rows.append(TranscriptRow(
            id: Self.promptRowID(submissionID),
            turnID: currentTurnID ?? TurnID(rawValue: "pending"),
            kind: .userMessage,
            text: text,
            isQueued: willQueue,
            origin: origin,
            attachedComments: comments,
            attachments: attachments
        ))
        refreshRevertableTurns()
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
        lastEventAt = turnStartedAt
        runningToolLabel = nil
        hasTurnEventArrived = false
        // Claim the turn locally for the same reason the engine claims it before
        // its own awaits: a second message typed in the gap before `.turnStarted`
        // must be judged against this turn, not the absence of one.
        isTurnActive = true
    }

    /// Row identity for a prompt, shared by the optimistic draw and the engine's
    /// echo of the same submission. Matching on it is what lets the transcript
    /// accept prompts from anywhere without ever showing one twice.
    static func promptRowID(_ submissionID: String) -> String { "prompt-\(submissionID)" }

    /// A prompt the engine accepted, which this window may or may not have sent.
    ///
    /// The composer draws its own message the instant the user presses send, so
    /// the echo of that submission is dropped here. What survives is everything
    /// the window could not have known about — the assistant's prompts, and the
    /// opening prompt of a workspace created from a sheet — which is exactly
    /// the set that used to leave a tab working on something invisible.
    func applyPromptSubmission(_ submission: PromptSubmission) {
        let id = Self.promptRowID(submission.submissionID)
        guard !rows.contains(where: { $0.id == id }) else { return }
        appendUserMessage(
            submission.text,
            attachments: submission.attachments,
            comments: [],
            origin: submission.origin,
            submissionID: submission.submissionID,
            isQueued: submission.isQueued
        )
    }

    /// A queued row becomes a real one when the turn it was waiting for starts.
    private func claimOldestPendingRow(turnID: TurnID) {
        guard let index = rows.firstIndex(where: { $0.isQueued }) else { return }
        mutateRow(at: index) { row in
            row.isQueued = false
            row.turnID = turnID
        }
        refreshRevertableTurns()
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
        resumeTurnAfterInput()
    }

    /// Dismisses the plan card once its approval has been answered.
    ///
    /// A proposal with no request id is informational — the harness is showing
    /// a plan, not asking about one — so it is dismissed on any resolution
    /// rather than waiting for an id that will never arrive.
    private func resolvePlan(requestID: PermissionRequestID) {
        guard case .proposal(_, let planRequestID) = plan else { return }
        guard planRequestID == nil || planRequestID == requestID else { return }
        clearPlan()
    }

    /// The user answered the plan card directly (approve, or reject with
    /// feedback). Clears it immediately rather than waiting for the harness to
    /// echo a resolution that, for a plan with no request id, never comes.
    func dismissPlan() {
        clearPlan()
        if !isTurnActive, status == .awaitingInput {
            status = .idle
        }
    }

    private func clearPlan() {
        plan = nil
        planTurnID = nil
    }

    /// True when the tool means the agent is implementing rather than still
    /// researching a plan the user has not answered.
    private static func proceedsPastPlanProposal(_ toolName: String) -> Bool {
        switch toolName {
        case "Edit", "Write", "Delete", "Bash":
            return true
        default:
            return false
        }
    }

    /// Drops a leftover proposal when this turn already mutated the tree —
    /// whether the Edit landed before or after the PLAN row (a late CreatePlan
    /// replay after writes would otherwise resurrect the card).
    /// Returns whether a card was showing.
    @discardableResult
    private func clearPlanIfTurnAlreadyProceeded(_ turnID: TurnID) -> Bool {
        guard case .proposal = plan else { return false }
        let proceeded = rows.contains { row in
            row.turnID == turnID
                && row.kind == .toolCall
                && Self.proceedsPastPlanProposal(row.toolName ?? "")
        }
        guard proceeded else { return false }
        clearPlan()
        return true
    }

    func resolveQuestion(_ id: QuestionID) {
        if pendingQuestion?.id == id { pendingQuestion = nil }
        resumeTurnAfterInput()
    }

    /// The permission/question card is gone; the turn is not. Show the
    /// composer as working until the harness's next real status arrives.
    private func resumeTurnAfterInput() {
        guard isTurnActive, status == .awaitingInput else { return }
        status = .requesting
    }

    /// Turns the user can revert to — every turn that produced something.
    /// Stored so the tab bar's history menu does not observe `rows` (and
    /// therefore does not rebuild on every streaming delta).
    private(set) var revertableTurns: [TurnID] = []

    // MARK: - Row assembly

    private func mutateRow(at index: Int, _ body: (inout TranscriptRow) -> Void) {
        guard rows.indices.contains(index) else { return }
        var row = rows[index]
        body(&row)
        row.contentRevision &+= 1
        rows[index] = row
    }

    private func refreshRevertableTurns() {
        var seen: Set<TurnID> = []
        revertableTurns = rows.compactMap { row in
            guard row.kind == .userMessage, !seen.contains(row.turnID) else { return nil }
            seen.insert(row.turnID)
            return row.turnID
        }
    }

    private func append(delta: BlockDelta, kind: TranscriptRow.Kind) {
        if let index = streamingRowIndex[delta.blockID], rows.indices.contains(index) {
            mutateRow(at: index) { $0.text += delta.text }
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
            mutateRow(at: index) { row in
                row.text = block.text
                row.isComplete = true
            }
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
        mutateRow(at: index) { row in
            row.resultText = result.text
            row.resultMetadata = result.metadata
            row.isError = result.isError
            row.isComplete = true
        }
    }

    /// A short live phrase for the composer, so "running a tool" can name the file.
    static func runningToolPhrase(name: String, displayName: String?) -> String {
        let subject = displayName.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return URL(fileURLWithPath: trimmed).lastPathComponent
        }
        switch name {
        case "Read": return subject.map { "Reading \($0)" } ?? "Reading a file"
        case "Write", "Edit", "NotebookEdit":
            return subject.map { "Editing \($0)" } ?? "Editing a file"
        case "Bash": return displayName.map { "Running \($0)" } ?? "Running a command"
        case "Grep", "Glob", "LS": return displayName.map { "Searching \($0)" } ?? "Searching"
        case "Task": return displayName.map { "Running subagent · \($0)" } ?? "Running a subagent"
        case "WebFetch": return displayName.map { "Fetching \($0)" } ?? "Fetching a page"
        case "WebSearch": return displayName.map { "Searching the web for \($0)" } ?? "Searching the web"
        default:
            if let displayName, !displayName.isEmpty { return "\(name) · \(displayName)" }
            return name
        }
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
    /// Who asked for this, on `.userMessage` rows. A prompt the assistant sent
    /// on the user's behalf is drawn on the same side of the transcript — it is
    /// still a prompt — but labelled, so scrolling back never leaves the user
    /// wondering which of these they wrote.
    var origin: MessageOrigin = .user
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
    /// Bumped when this row's visible content changes. The table diffs on this
    /// instead of hashing `text` / `toolInput` / grouped tool output on every
    /// flush — that walk grew with the session and is what froze the UI.
    var contentRevision: UInt64 = 0
    /// Stored, not computed from grouped text. Derived rows (activity groups,
    /// footers) seal this once from children's `contentRevision`s.
    var activitySignature: Int = 0

    /// Records a cheap identity for a derived row so the table can diff it
    /// without hashing the turn's tool output on every flush.
    mutating func sealDerivedContent() {
        var hasher = Hasher()
        hasher.combine(resolvedSubject)
        hasher.combine(groupedRows.count)
        for row in groupedRows {
            hasher.combine(row.id)
            hasher.combine(row.contentRevision)
            hasher.combine(row.isComplete)
            hasher.combine(row.isError)
        }
        activitySignature = hasher.finalize()
        contentRevision = UInt64(truncatingIfNeeded: activitySignature)
    }
}
