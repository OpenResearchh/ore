import OreGit
import OrePersistence
import OreProtocol
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The conversation with one agent, plus everything the user needs to answer it.
struct ChatPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let workspace: WorkspaceSummary

    @State private var draft = ""
    /// Prevents a tab switch from briefly writing the previous tab's text into
    /// the newly selected chat before its persisted draft has loaded.
    @State private var draftOwnerID: ChatID?
    @State private var composerTextHeight: CGFloat = 22
    @State private var queuedMessages: [QueuedMessageRecord] = []
    @State private var revertTarget: TurnID?
    @State private var expandedActivityGroups: Set<String> = []
    /// Attachment relative paths that live as inline chips in the draft (pasted
    /// images and long text) rather than in the attachment shelf above the composer.
    ///
    /// View state, so a tab switch destroys it while `chat.draftAttachments`
    /// survives on the chat — which is what demoted inline pills to shelf
    /// chips. It is rebuilt from the restored draft on every chat change; see
    /// `ComposerPasteboard.inlinePaths(inDraft:attachments:)`.
    @State private var inlinePastedPaths: Set<String> = []
    @State private var showModelChooser = false
    @State private var showEffortChooser = false
    @State private var reasoningEffort: ReasoningEffort = .high
    @State private var fastModeEnabled = false
    @State private var effortScrollProgress: CGFloat = 0
    @State private var effortStepPulse = 0
    @State private var modelScrollProgress: CGFloat = 0
    @State private var modelStepPulse = 0
    @State private var hoveredTabKey: String?
    @State private var renameChatTarget: ChatSummary?
    @State private var renameChatText = ""
    @State private var workspaceFileIndex: [WorkspaceFileNode] = []
    @FocusState private var composerFocused: Bool
    @State private var voice = VoiceInputController()
    @State private var voiceAttachedClipboard = false
    /// What dictation has recognized so far, shown as a fading trail so the user
    /// can see which words were taken out of the prompt and what they changed.
    @State private var voiceChanges: [VoiceChange] = []
    /// Recognized live but not committed until the mic stops: switching harness
    /// tears down the agent session, which is far too costly to do on a partial
    /// transcript the recognizer may still revise.
    @State private var voicePendingModel: VoiceModelCandidate?
    /// The live, intent-stripped transcript shown in the quote panel while the
    /// mic is hot. Dictation never touches `draft`; the words only land there
    /// (or go straight out as a turn) when the session ends.
    @State private var voiceQuote = ""
    /// Set between the mic stopping and the turn going out: the composer holds
    /// the whole dictated prompt on screen for that beat instead of the live
    /// one-line quote. Non-nil means a send is pending and still cancellable.
    @State private var voiceSettle: VoiceSettledTurn?
    @State private var voiceSettleTask: Task<Void, Never>?
    /// Spoken file matching runs against this pre-tokenized index.
    @State private var voiceFileMatcher = VoiceFileMatcher.empty
    /// File tags the user dismissed mid-dictation by tapping their chip. The
    /// matcher skips these paths for the rest of the session, which restores
    /// the spoken words to the quote and keeps the tag from committing.
    @State private var voiceCanceledFilePaths: Set<String> = []
    private var hotkey: VoiceHotkeyMonitor { .shared }

    private var chat: ChatState { model.chat(for: workspace.id) }
    private var chatSummary: ChatSummary? { model.activeChat(for: workspace.id) }

    /// The draft's attachments, stored on the chat rather than in this view's
    /// `@State` so switching tabs restores chips and mention pills instead of
    /// leaving bare `@pasted-image.png` text behind. Kept as a settable property
    /// so the composer reads and writes it exactly as it would local state.
    private var attachments: [Attachment] {
        get { chat.draftAttachments }
        nonmutating set { persistAttachments(newValue) }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                tabBar(availableWidth: geometry.size.width)

                // The centre column shows either a chat transcript or — when a file
                // tab is active — that file's diff, opened from the review list.
                if let filePath = model.activeFilePath[workspace.id] {
                    DiffDocumentView(workspace: workspace, path: filePath)
                } else {
                    chatBody(paneHeight: geometry.size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OreTheme.Surface.content)
        // Workspace identity lives in the window's title bar now, not a 58pt
        // header that repeated the tab title. The toolbar band was empty anyway.
        .navigationTitle(workspace.name)
        .navigationSubtitle("\(workspace.branch) → \(workspace.baseBranch)")
    }

    @ViewBuilder
    private func chatBody(paneHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                if chat.rows.isEmpty && !chat.isBusy {
                    ResearchEmptyState(
                        identity: chatSummary.flatMap { ResearchIdentity.matching(researchTitle: $0.title) }
                            ?? model.researchIdentity(for: workspace),
                        title: chatSummary?.title,
                        seed: chatSummary?.id.rawValue ?? workspace.id.rawValue,
                        onSuggestion: { suggestion in
                            draft = suggestion
                            composerFocused = true
                        }
                    )
                } else {
                    TranscriptView(
                        rows: displayRows,
                        worktreePath: workspace.worktreePath,
                        persistenceKey: "ore.chatScroll.\(chatSummary?.id.rawValue ?? workspace.id.rawValue)",
                        onRevert: { revertTarget = $0 },
                        onToggleActivity: { toggleActivity($0) },
                        onOpenFile: { openAgentFile($0) },
                        onTurnAction: { turn, action in
                            switch action {
                            case .fork: model.forkChat(into: workspace.id)
                            case .revert: revertTarget = turn
                            }
                        },
                        canFork: chatSummary?.capabilities.supportsSessionFork ?? false
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // The "agent is working" state now lives on the composer itself
                // (an animated border plus an inline status row), so there is no
                // longer a separate floating pill hovering over the transcript.
            }
            // Transition snapshots of an infinitely-sized empty view could
            // paint over sibling split-view columns while changing tabs. The
            // transcript viewport owns and clips all of its content now.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            .clipped()

            // Anything blocking the agent sits directly above the composer,
            // where the user is already looking. AskUserQuestion and
            // ExitPlanMode are both a permission gate *and* a dedicated card;
            // showing the generic Allow/Deny alongside that card is two
            // prompts for the same decision. The dedicated card owns it, and
            // answering there also allows (or denies) this permission.
            if let permission = chat.pendingPermission,
               !hidesGenericPermission(permission) {
                PermissionCard(request: permission) { decision in
                    model.resolvePermission(permission.id, decision: decision, for: workspace.id)
                }
                .frame(maxWidth: OreTheme.contentMaxWidth)
                .padding(.horizontal, OreTheme.Space.md)
                .padding(.top, OreTheme.Space.sm)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if case .proposal(let markdown, let requestID) = chat.plan {
                PlanApprovalCard(markdown: markdown) { feedback in
                    // Dismiss first, and unconditionally. The card used to
                    // linger until a `permissionResolved` that a proposal
                    // without a request id never sends — which is why a second
                    // proposal left two cards and answering one kept the other.
                    chat.dismissPlan()
                    if let requestID {
                        model.resolvePermission(requestID, decision: .allow, for: workspace.id)
                    }
                    model.setPermissionMode(.default, for: workspace.id)
                    if !feedback.isEmpty { model.send(feedback, to: workspace.id) }
                } onReject: { feedback in
                    chat.dismissPlan()
                    if let requestID {
                        model.resolvePermission(
                            requestID,
                            decision: .deny(reason: feedback.isEmpty ? "Revise the plan." : feedback),
                            for: workspace.id
                        )
                    }
                }
                .frame(maxWidth: OreTheme.contentMaxWidth)
                .padding(.horizontal, OreTheme.Space.md)
                .padding(.top, OreTheme.Space.sm)
                // A new proposal must reset the card's own feedback field;
                // without an identity SwiftUI reuses the previous card's state.
                .id(requestID?.rawValue ?? markdown)
            }

            if !queuedMessages.isEmpty {
                MessageQueueCard(messages: $queuedMessages) { id, text in
                    await model.updateQueuedMessage(id, text: text)
                } onDelete: { id in
                    await model.deleteQueuedMessage(id)
                    queuedMessages.removeAll { $0.id == id }
                }
                .frame(maxWidth: OreTheme.contentMaxWidth)
                .padding(.horizontal, OreTheme.Space.md)
            }

            if !chat.draftComments.isEmpty {
                DraftCommentsBar(comments: chat.draftComments) { index in
                    chat.removeDraftComment(at: index)
                }
            }

            // Hard failures — usage limits especially — belong where the user
            // is about to act, not buried as a red row up in the transcript.
            if let error = chat.prominentError {
                ProminentErrorBanner(
                    error: error,
                    scheduled: model.scheduledContinuation(for: chatSummary?.id),
                    onContinueWhenAvailable: scheduleContinuation,
                    onCancelSchedule: cancelScheduledContinuation,
                    onRetry: { model.retryLastTurn(in: workspace.id) },
                    onDismiss: { chat.dismissProminentError() }
                )
                    .frame(maxWidth: OreTheme.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, OreTheme.Space.md)
                    .padding(.top, OreTheme.Space.sm)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let scheduled = model.scheduledContinuation(for: chatSummary?.id) {
                ScheduledContinuationBanner(item: scheduled, onCancel: cancelScheduledContinuation)
                    .frame(maxWidth: OreTheme.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, OreTheme.Space.md)
                    .padding(.top, OreTheme.Space.sm)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let limit = chat.rateLimit, limit.status == .warning || limit.status == .exhausted {
                RateLimitBanner(report: limit, onRetry: { model.retryLastTurn(in: workspace.id) })
                    .frame(maxWidth: OreTheme.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, OreTheme.Space.md)
                    .padding(.top, OreTheme.Space.sm)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let question = chat.pendingQuestion {
                QuestionCard(
                    question: question,
                    harness: chatSummary?.harness ?? workspace.harness
                ) { answer in
                    // AskUserQuestion is a permission-gated tool: its result is
                    // whatever we return through the can_use_tool reply. Allowing
                    // it echoed the untouched input, so the agent saw an empty
                    // "answered:" and the real answer (sent separately as a user
                    // message) raced the still-open control request and was lost.
                    // Deliver the answer *as* the tool result instead.
                    if let permission = chat.pendingPermission,
                       permission.toolCallID == question.toolCallID {
                        model.answerQuestion(
                            question.id,
                            viaPermission: permission.id,
                            answer: answer,
                            for: workspace.id
                        )
                    } else {
                        model.answerQuestion(question.id, answer: answer, for: workspace.id)
                    }
                }
                .frame(maxWidth: OreTheme.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, OreTheme.Space.md)
                .padding(.vertical, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                composer(paneHeight: paneHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .task(id: chatSummary?.id) {
            draftOwnerID = chatSummary?.id
            if let injection = model.composerInjection, injection.chatID == chatSummary?.id {
                draft = injection.text
                composerFocused = true
            } else {
                draft = chatSummary?.draftText ?? ""
            }
            // The attachments survive a tab switch on the chat, but the record
            // of which ones were *inline* is view state that dies with the
            // pane — so without this every `@pasted-image.png` pill came back
            // as a chip above the composer. The tokens left in the restored
            // draft are what say which were inline.
            inlinePastedPaths = ComposerPasteboard.inlinePaths(
                inDraft: draft, attachments: chat.draftAttachments
            )
        }
        .onChange(of: model.composerInjection?.generation) { _, _ in
            guard let injection = model.composerInjection,
                  injection.chatID == chatSummary?.id else { return }
            draftOwnerID = injection.chatID
            draft = injection.text
            composerFocused = true
        }
        .task(id: "\(chatSummary?.id.rawValue ?? "")-\(chatSummary?.queuedMessageCount ?? 0)") {
            guard let id = chatSummary?.id else { queuedMessages = []; return }
            queuedMessages = await model.queuedMessages(for: id)
        }
        .onChange(of: draft) { _, value in
            // The guard keeps a tab switch from writing the previous tab's text
            // into the newly selected chat before its draft has loaded.
            guard let chatSummary, draftOwnerID == chatSummary.id else { return }
            // Mentions and inline pasted images/text live as `@name` tokens in
            // the draft; drop the attachment once its token is gone. Shelf files
            // (attached, not inline) persist regardless of the text.
            var next = chat.draftAttachments
            next.removeAll { attachment in
                let isInline = !attachment.relativePath.hasPrefix(".context/attachments/")
                    || inlinePastedPaths.contains(attachment.relativePath)
                return isInline && !value.contains("@\(attachment.displayName)")
            }
            if next != chat.draftAttachments {
                model.persistDraftAttachments(next, for: chatSummary.id)
            }
            inlinePastedPaths = inlinePastedPaths.filter { path in
                next.contains { $0.relativePath == path }
            }
            model.setDraft(value, for: chatSummary)
        }
        .onChange(of: voice.transcript) { _, text in
            guard voice.isActive else { return }
            applyLiveVoiceIntents(spoken: text)
        }
        .onChange(of: voice.status) { _, status in
            handleVoiceStatusChange(status)
        }
        .onChange(of: chatSummary?.id) { _, _ in
            finishVoice(.commitToDraft)
            voiceAttachedClipboard = false
        }
        .onChange(of: chat.pendingQuestion != nil) { _, hasQuestion in
            // The QuestionCard replaces the composer entirely; keep the words
            // rather than leaving a hot mic pointed at a vanished quote panel.
            if hasQuestion { finishVoice(.commitToDraft) }
        }
        .onChange(of: hotkey.command) { _, command in
            // Panes exist for background workspaces too; only the one on screen
            // should answer the global chord.
            guard let command, model.selectedWorkspaceID == workspace.id else { return }
            switch command.kind {
            case .toggle: toggleVoice()
            case .start: if !voice.isActive { startVoice() }
            case .stop: finishVoice(.send)
            }
        }
        .onDisappear {
            finishVoice(.commitToDraft)
        }
        .onExitCommand {
            finishVoice(.cancel)
        }
        .task(id: chatSummary?.id) {
            let key = "ore.reasoningEffort.\(chatSummary?.id.rawValue ?? workspace.id.rawValue)"
            if let raw = UserDefaults.standard.string(forKey: key),
               let effort = ReasoningEffort(rawValue: raw) { reasoningEffort = effort }
            let fastKey = "ore.fastMode.\(chatSummary?.id.rawValue ?? workspace.id.rawValue)"
            fastModeEnabled = UserDefaults.standard.bool(forKey: fastKey)
        }
        .onChange(of: reasoningEffort) { _, effort in
            let key = "ore.reasoningEffort.\(chatSummary?.id.rawValue ?? workspace.id.rawValue)"
            UserDefaults.standard.set(effort.rawValue, forKey: key)
        }
        .onChange(of: fastModeEnabled) { _, enabled in
            let key = "ore.fastMode.\(chatSummary?.id.rawValue ?? workspace.id.rawValue)"
            UserDefaults.standard.set(enabled, forKey: key)
        }
        .task(id: workspace.id) {
            workspaceFileIndex = Self.flattenFiles(await model.workspaceFiles(for: workspace))
            // Pre-tokenized once here, not on every partial transcript: spoken
            // file matching runs 5×/second while dictating.
            voiceFileMatcher = VoiceFileMatcher(
                files: workspaceFileIndex
                    .filter { !$0.isDirectory }
                    .map { (name: $0.name, path: $0.path) }
            )
        }
        .confirmationDialog(
            "Revert chat and workspace?",
            isPresented: revertDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Revert", role: .destructive) {
                if let revertTarget { model.revert(to: revertTarget, in: workspace.id) }
                revertTarget = nil
            }
            Button("Cancel", role: .cancel) { revertTarget = nil }
        } message: {
            Text("This restores both the transcript and working tree to the selected checkpoint.")
        }
        .confirmationDialog(
            "Close this tab while the agent is working?",
            isPresented: pendingChatClosePresented,
            titleVisibility: .visible
        ) {
            Button("Close Tab", role: .destructive) {
                if let pending = model.pendingChatClose {
                    model.closeChat(pending.chatID, in: pending.workspaceID)
                }
                model.pendingChatClose = nil
            }
            Button("Keep Working", role: .cancel) { model.pendingChatClose = nil }
        } message: {
            if let pending = model.pendingChatClose {
                Text("“\(pending.title)” still has a running turn. Closing the tab will stop the agent.")
            }
        }
        .alert("Rename Chat", isPresented: renameChatPresented) {
            TextField("Name", text: $renameChatText)
            Button("Rename") {
                guard let target = renameChatTarget else { return }
                let title = renameChatText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { model.renameChat(target.id, in: workspace.id, to: title) }
                renameChatTarget = nil
            }
            Button("Cancel", role: .cancel) { renameChatTarget = nil }
        }
    }

    // Extracted from the body's modifier chain: inline `Binding` closures there
    // push the type-checker past its expression limit.
    private var revertDialogPresented: Binding<Bool> {
        Binding(
            get: { revertTarget != nil },
            set: { if !$0 { revertTarget = nil } }
        )
    }

    private var pendingChatClosePresented: Binding<Bool> {
        Binding(
            get: { model.pendingChatClose != nil },
            set: { if !$0 { model.pendingChatClose = nil } }
        )
    }

    private var renameChatPresented: Binding<Bool> {
        Binding(
            get: { renameChatTarget != nil },
            set: { if !$0 { renameChatTarget = nil } }
        )
    }

    /// Memoization for `displayRows`. A class box rather than `@State` value
    /// storage: the cache is invisible to SwiftUI on purpose — filling it during
    /// a body evaluation must not schedule another one.
    private final class DisplayRowsMemo {
        struct Key: Equatable {
            var revision: Int
            var isBusy: Bool
            var expanded: Set<String>
        }
        var key: Key?
        var rows: [TranscriptRow] = []
    }
    @State private var displayRowsMemo = DisplayRowsMemo()

    private var displayRows: [TranscriptRow] {
        // Reading `rowsRevision` (not just `rows`) keeps observation intact:
        // any transcript mutation still re-evaluates the body, but unrelated
        // re-evaluations — hover, audio level, focus — reuse the last grouping
        // instead of re-deriving it from every row.
        let key = DisplayRowsMemo.Key(
            revision: chat.rowsRevision,
            isBusy: chat.isBusy,
            expanded: expandedActivityGroups
        )
        if displayRowsMemo.key == key { return displayRowsMemo.rows }
        let computed = computeDisplayRows()
        displayRowsMemo.key = key
        displayRowsMemo.rows = computed
        return computed
    }

    private func computeDisplayRows() -> [TranscriptRow] {
        let visible = chat.rows.compactMap { source -> TranscriptRow? in
            if source.kind == .error, !Self.isMeaningfulError(source.text, result: source.resultText) {
                return nil
            }
            var row = source
            // Some harnesses report a successful empty result as an error
            // carrying `null`. That should not paint a successful tool red or
            // inflate the issue count for the turn.
            if row.kind == .toolCall, row.isError,
               !Self.isMeaningfulError(row.text, result: row.resultText) {
                row.isError = false
            }
            if row.kind == .toolCall || row.kind == .thinking || row.kind == .error
                || row.kind == .activityGroup {
                row.isExpanded = expandedActivityGroups.contains(row.id)
            }
            return row
        }

        // A finished turn reads as three things: what the agent did (collapsed),
        // what it concluded (always visible), and what that cost. While the
        // agent is still working the live turn stays fully expanded, so its
        // tool calls read inline until the final response has landed.
        let activeTurn: TurnID? = chat.isBusy ? visible.last?.turnID : nil
        let subjects = Self.taskSubjects(in: visible)

        var result: [TranscriptRow] = []
        var index = visible.startIndex
        while index < visible.endIndex {
            // Turns arrive contiguously, so one pass over the transcript can
            // slice it into turns without sorting or grouping into a dictionary
            // — which is also what keeps the original order intact.
            let turn = visible[index].turnID
            var slice: [TranscriptRow] = []
            while index < visible.endIndex, visible[index].turnID == turn {
                var row = visible[index]
                row.resolvedSubject = Self.taskSubject(for: row, in: subjects)
                slice.append(row)
                index += 1
            }
            result.append(contentsOf: present(turn: slice, isActive: turn == activeTurn))
        }
        // Subagent nesting runs last, over the assembled transcript: a
        // subagent's rows have to find their Agent row wherever the turn layout
        // put it, including inside an expanded activity section.
        return nestSubagents(result)
    }

    /// Lays out one turn's rows.
    ///
    /// Everything the agent did on the way to its answer folds into a single
    /// collapsed section placed where the work happened; the last thing it said
    /// stays visible below as the turn's outcome. A live turn is returned
    /// untouched — collapsing work in progress hides the only thing worth
    /// watching.
    private func present(turn rows: [TranscriptRow], isActive: Bool) -> [TranscriptRow] {
        guard !isActive, let turnID = rows.first?.turnID else { return rows }

        // The answer is the last non-empty assistant block; everything before
        // it is preamble and folds away with the tool calls. Found once, not
        // per row — this runs on every transcript update while text streams.
        let answer = rows.lastIndex {
            $0.kind == .assistantText
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let collapsible = rows.indices.filter { Self.isCollapsible(rows[$0], isAnswer: $0 == answer) }
        // A turn that only answered has nothing to hide and nothing to report:
        // no tools ran, no files changed. It stays a bare response rather than
        // gaining an empty section and a footer saying so.
        guard let firstCollapsibleIndex = collapsible.first else { return rows }

        let hidden = Set(collapsible)
        let collapsed = collapsible.map { rows[$0] }
        let groupID = "activity-\(turnID.rawValue)"
        let expanded = expandedActivityGroups.contains(groupID)

        var group = TranscriptRow(
            id: groupID,
            turnID: turnID,
            kind: .activityGroup,
            text: Self.activitySummary(for: collapsed),
            groupedRows: collapsed,
            isExpanded: expanded
        )
        group.createdAt = collapsed.first?.createdAt ?? Date()

        var result: [TranscriptRow] = []
        for (offset, row) in rows.enumerated() {
            if offset == firstCollapsibleIndex {
                result.append(group)
                // Child rows are virtualized in only when the section is open,
                // and each keeps its own expansion, so a 100-call turn stays
                // quick to open and Bash/Edit/Read details expand separately.
                if expanded {
                    result.append(contentsOf: collapsed.map { child in
                        var item = child
                        item.isExpanded = expandedActivityGroups.contains(child.id)
                        return item
                    })
                }
                continue
            }
            guard !hidden.contains(offset) else { continue }
            result.append(row)
        }

        var footer = TranscriptRow(
            id: "footer-\(turnID.rawValue)",
            turnID: turnID,
            kind: .turnFooter,
            text: "",
            groupedRows: rows
        )
        footer.createdAt = rows.last?.createdAt ?? Date()
        result.append(footer)
        return result
    }

    /// Folds each subagent's tool uses under the Task ("Agent") row that spawned
    /// them, so a subagent reads as its own collapsible group rather than a flat
    /// indented run. A subagent's children appear only when its Agent row is
    /// expanded; a normal transcript with no subagents passes through untouched.
    private func nestSubagents(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        let childrenByParent = Dictionary(
            grouping: rows.filter { $0.parentToolCallID != nil },
            by: { $0.parentToolCallID! }
        )
        guard !childrenByParent.isEmpty else { return rows }
        let present = Set(rows.compactMap(\.toolCallID))

        var output: [TranscriptRow] = []
        func emit(_ row: TranscriptRow) {
            var item = row
            if item.kind == .toolCall || item.kind == .thinking
                || item.kind == .error || item.kind == .activityGroup {
                item.isExpanded = expandedActivityGroups.contains(row.id)
            }
            if let id = row.toolCallID, let children = childrenByParent[id] {
                item.subagentChildCount = children.count
                output.append(item)
                if item.isExpanded { children.forEach(emit) }
            } else {
                output.append(item)
            }
        }
        for row in rows {
            // A subagent child is emitted beneath its Agent, not at the top
            // level — unless its Agent isn't shown here, in which case it stays
            // inline so it never silently disappears.
            if let parent = row.parentToolCallID, present.contains(parent) { continue }
            emit(row)
        }
        return output
    }

    /// Which of a turn's rows fold away once it is done.
    ///
    /// Tool calls and thinking always do. Assistant prose does too — except the
    /// last block, which is the answer the whole turn was for. Without that
    /// exception a chatty turn showed three or four separate prose blocks and
    /// nothing marked which one was the conclusion.
    private static func isCollapsible(_ row: TranscriptRow, isAnswer: Bool) -> Bool {
        switch row.kind {
        case .toolCall, .thinking, .error:
            return true
        case .assistantText:
            return !isAnswer
        case .userMessage, .plan, .divider, .activityGroup, .turnFooter:
            return false
        }
    }

    private static func activitySummary(for rows: [TranscriptRow]) -> String {
        let tools = rows.filter { $0.kind == .toolCall }.count
        let thoughts = rows.filter { $0.kind == .thinking }.count
        let notes = rows.filter { $0.kind == .assistantText }.count
        let errors = rows.filter { $0.kind == .error || $0.isError }.count
        var parts: [String] = []
        if tools > 0 { parts.append("\(tools) tool call\(tools == 1 ? "" : "s")") }
        if thoughts > 0 { parts.append("\(thoughts) thought\(thoughts == 1 ? "" : "s")") }
        if notes > 0 { parts.append("\(notes) note\(notes == 1 ? "" : "s")") }
        if errors > 0 { parts.append("\(errors) issue\(errors == 1 ? "" : "s")") }
        return parts.isEmpty ? "Activity" : parts.joined(separator: ", ")
    }

    /// Task ids mapped to the subject they were created with.
    ///
    /// `TaskUpdate` identifies its task by id alone, so on its own it can only
    /// say "Task 8". The subject lives in the `TaskCreate` that made it, and
    /// the id it was assigned comes back in that call's result.
    private static func taskSubjects(in rows: [TranscriptRow]) -> [String: String] {
        var subjects: [String: String] = [:]
        for row in rows where row.kind == .toolCall {
            // Suffix, not equality: the same tool arrives namespaced when it
            // comes through MCP (`mcp__ore__TaskCreate`).
            guard (row.toolName ?? "").lowercased().hasSuffix("taskcreate"),
                  let subject = row.toolInput?["subject"]?.stringValue,
                  let id = firstNumber(in: row.resultText ?? "")
            else { continue }
            subjects[id] = subject
        }
        return subjects
    }

    private static func taskSubject(
        for row: TranscriptRow,
        in subjects: [String: String]
    ) -> String? {
        guard row.kind == .toolCall,
              (row.toolName ?? "").lowercased().contains("task") else { return nil }
        if let subject = row.toolInput?["subject"]?.stringValue { return subject }
        guard let id = row.toolInput?["taskId"]?.stringValue
            ?? row.toolInput?["taskId"]?.intValue.map(String.init)
        else { return nil }
        return subjects[id]
    }

    private static func firstNumber(in text: String) -> String? {
        let digits = text.drop { !$0.isNumber }.prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    private static func isMeaningfulError(_ text: String, result: String?) -> Bool {
        let value = (result?.isEmpty == false ? result! : text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !value.isEmpty && !["null", "nil", "<null>", "(null)", "\"null\""].contains(value)
    }

    private func toggleActivity(_ id: String) {
        if expandedActivityGroups.contains(id) { expandedActivityGroups.remove(id) }
        else { expandedActivityGroups.insert(id) }
    }

    private func tabBar(availableWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: OreTheme.Space.xs) {
                    ForEach(model.chats(for: workspace.id)) { tab in
                        Button {
                            model.selectChat(tab.id, in: workspace.id)
                            model.showChatInCenter(workspace.id)
                        } label: {
                            tabLabel(tab)
                        }
                        .buttonStyle(.plain)
                        .id("chat:\(tab.id.rawValue)")
                        .contextMenu {
                            Button("Rename…") { beginRenaming(tab) }
                            if model.chats(for: workspace.id).count > 1 {
                                Button("Close") { requestCloseChat(tab) }
                            }
                        }
                    }

                    // File diffs opened from the review list show up here as
                    // tabs, so a diff reads as an open document, not a side pane.
                    ForEach(model.openFilePaths[workspace.id] ?? [], id: \.self) { path in
                        Button { model.selectDiffFile(path, in: workspace.id) } label: {
                            fileTabLabel(path)
                        }
                        .buttonStyle(.plain)
                        .id("file:\(path)")
                    }

                }
                // Mirrored, not lopsided: padding only the trailing edge for the
                // controls pushes the whole strip left of centre by half their
                // width. With both edges reserved the tabs sit on the window's
                // centre line — the same line the transcript and composer use —
                // and the last tab still can't slide under the + button.
                .padding(.horizontal, tabControlAllowance)
                .frame(minWidth: availableWidth)
            }
            .frame(maxWidth: .infinity)
            .onChange(of: activeTabKey) { _, key in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(key, anchor: .center)
                }
            }
        }
        // The header's controls fold into the strip's trailing edge rather than
        // occupying a row of their own. Overlaying (instead of an HStack sibling)
        // means they don't skew the tabs off-centre.
        .overlay(alignment: .trailing) {
            trailingControls
                .padding(.horizontal, OreTheme.Space.xs)
                .background(.bar)
        }
        .frame(height: OreTheme.RowHeight.bar)
        .background(.bar)
    }

    /// Width reserved at *each* edge of the strip: the trailing side holds the
    /// fixed controls (new-tab, history, and the stop button while busy), and
    /// the leading side matches it so the tabs stay optically centred rather
    /// than shifted by the controls' width.
    private var tabControlAllowance: CGFloat {
        88
    }

    private var activeTabKey: String {
        if let path = model.activeFilePath[workspace.id] { return "file:\(path)" }
        if let id = chatSummary?.id { return "chat:\(id.rawValue)" }
        return ""
    }

    private func fileTabLabel(_ path: String) -> some View {
        let isSelected = model.activeFilePath[workspace.id] == path
        return HStack(spacing: 6) {
            SourceFileIcon(path: path, size: 16)
            HStack(spacing: 6) {
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: OreTheme.Font.body, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(hoveredTabKey == "file:\(path)" || isSelected ? 1 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { model.closeDiffFile(path, in: workspace.id) }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: 190, minHeight: 28)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .oreNavigationSelection(
            isSelected: isSelected,
            isHovered: hoveredTabKey == "file:\(path)"
        )
        .contentShape(RoundedRectangle(cornerRadius: OreTheme.tabRadius))
        .onHover { hovering in
            let key = "file:\(path)"
            if hovering { hoveredTabKey = key }
            else if hoveredTabKey == key { hoveredTabKey = nil }
        }
    }

    private func tabLabel(_ tab: ChatSummary) -> some View {
        let isSelected = tab.id == chatSummary?.id && model.activeFilePath[workspace.id] == nil
        let tabState = model.chat(for: tab.id)
        let isWorking = tabState.isBusy
        return HStack(spacing: 6) {
            HarnessMark(harness: tab.harness, size: 14, isMuted: !isSelected && !isWorking)
            HStack(spacing: 6) {
                // A working tab pulses an accent dot; an idle-but-unread one
                // shows the static blue dot. Either way the marker sits where
                // the eye already lands, so it reads at a glance.
                if isWorking {
                    BusyTabDot(reduceMotion: reduceMotion)
                } else if tab.hasUnread {
                    Circle().fill(.blue).frame(width: 6, height: 6)
                }
                Text(tab.title)
                    .font(.system(size: OreTheme.Font.body, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                if !tab.draftText.isEmpty || !tabState.draftAttachments.isEmpty {
                    Image(systemName: "pencil").font(.system(size: 8))
                }
                if tab.queuedMessageCount > 0 {
                    Text("\(tab.queuedMessageCount)")
                        .font(.caption2.monospacedDigit())
                }
                if model.chats(for: workspace.id).count > 1 {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .opacity(hoveredTabKey == "chat:\(tab.id.rawValue)" || isSelected ? 1 : 0)
                        .contentShape(Rectangle())
                        .onTapGesture { requestCloseChat(tab) }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: 190, minHeight: 28)
        .foregroundStyle(isSelected ? .primary : .secondary)
        // The active tab is at full strength; every other tab recedes — even a
        // working one — so which tab you're actually in is never in doubt. A
        // busy background tab still keeps enough presence to notice its dot.
        .opacity(isSelected ? 1 : (isWorking ? 0.9 : 0.72))
        .oreNavigationSelection(
            isSelected: isSelected,
            isHovered: hoveredTabKey == "chat:\(tab.id.rawValue)"
        )
        .overlay(alignment: .bottom) {
            // A solid accent underline is the single unambiguous "you are here"
            // marker: with several dim tabs, opacity alone is too subtle to pick
            // the active one out at a glance.
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(height: 2.5)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 1)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: OreTheme.tabRadius))
        .onHover { hovering in
            let key = "chat:\(tab.id.rawValue)"
            if hovering { hoveredTabKey = key }
            else if hoveredTabKey == key { hoveredTabKey = nil }
        }
    }

    private func beginRenaming(_ tab: ChatSummary) {
        renameChatText = tab.title
        renameChatTarget = tab
    }

    /// Route every tab-close through the model so a working tab gets a
    /// confirmation prompt instead of stopping the agent silently.
    private func requestCloseChat(_ tab: ChatSummary) {
        model.requestCloseChat(tab.id, in: workspace.id, title: tab.title)
    }

    @ViewBuilder
    private var trailingControls: some View {
        HStack(spacing: OreTheme.Space.xs) {
            Button { model.createChat(in: workspace.id) } label: {
                HStack(spacing: 5) {
                    if model.chatCreationsInFlight.contains(workspace.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "plus")
                    }
                    Text("⌘T")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 6)
                .frame(height: 26)
            }
            .buttonStyle(OrePressableButtonStyle())
            .disabled(model.chatCreationsInFlight.contains(workspace.id))
            .help("New tab (⌘T)")

            Menu {
                if !chat.revertableTurns.isEmpty {
                    Section("Checkpoints") {
                        ForEach(Array(chat.revertableTurns.enumerated().reversed()), id: \.offset) { index, turn in
                            Button("Before turn \(index + 1)") { revertTarget = turn }
                        }
                    }
                }
                let closed = model.chats(for: workspace.id, includeClosed: true).filter(\.isClosed)
                if !closed.isEmpty {
                    Section("Closed chats") {
                        ForEach(closed) { tab in
                            Button(tab.title) { model.reopenChat(tab.id, in: workspace.id) }
                        }
                    }
                }
                if chat.revertableTurns.isEmpty && closed.isEmpty {
                    Text("No history yet")
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Chat and checkpoint history")
        }
    }

    @ViewBuilder
    private func modelChoices(for tab: ChatSummary) -> some View {
        Text("Default model").tag("")
        ForEach(model.knownModels(for: tab.harness)) { choice in
            Text(choice.displayName).tag(choice.id)
        }
        if let selected = tab.model,
           !model.knownModels(for: tab.harness).contains(where: { $0.id == selected }) {
            Text(selected).tag(selected)
        }
    }

    // MARK: - Composer

    private func composer(paneHeight: CGFloat) -> some View {
        VStack(spacing: OreTheme.Space.sm) {
            if chat.isBusy {
                ComposerBusyStatus(
                    harness: chatSummary?.harness ?? workspace.harness,
                    status: chat.status,
                    startedAt: chat.turnStartedAt,
                    // Booting a one-shot CLI takes seconds before its first
                    // event; the status row says so rather than claiming work
                    // is already happening.
                    isStarting: !chat.hasTurnEventArrived,
                    onStop: { model.interrupt(workspace.id) }
                )
                .transition(.opacity)
            }

            if !voiceChanges.isEmpty {
                VoiceChangeTrail(changes: voiceChanges, onActivate: confirmVoiceChange)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 6)),
                                removal: .opacity
                            )
                    )
            }

            if !externalAttachments.isEmpty {
                AttachmentChipStrip(
                    attachments: externalAttachments.map {
                        AttachmentChipStrip.IndexedAttachment(index: $0.offset, attachment: $0.element)
                    },
                    worktreePath: workspace.worktreePath,
                    onRemove: { index in discardAttachments(at: IndexSet(integer: index)) }
                )
            }

            if !slashCommands.isEmpty {
                VStack(spacing: 2) {
                    ForEach(slashCommands) { command in
                        Button { run(command) } label: {
                            HStack {
                                Image(systemName: command.icon).frame(width: 22)
                                Text(command.name).fontWeight(.medium)
                                Text(command.detail).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 8).frame(minHeight: 36)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            if !mentionSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("REFERENCE A FILE")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("Tab to insert")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                    ForEach(mentionSuggestions.prefix(6)) { node in
                        Button { tagFile(node) } label: {
                            HStack(spacing: 8) {
                                SourceFileIcon(path: node.path, size: 17)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(node.name)
                                        .font(.system(size: OreTheme.Font.body, weight: .medium))
                                    Text(node.path)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 40)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(OrePressableButtonStyle())
                    }
                }
                .padding(4)
                .fixedSize(horizontal: false, vertical: true)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(OreTheme.hairline))
                .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
            }

            if voice.isActive || voiceSettle != nil {
                // In voice mode the input area itself becomes the transcript:
                // the words land where they will be sent from, set in serif
                // quotes so they read as speech-in-progress rather than typed
                // text.
                VoiceComposerTranscript(
                    prefix: draft,
                    transcript: voiceSettle?.quote ?? voiceQuote,
                    isListening: voice.isListening,
                    isSettled: voiceSettle != nil,
                    // Never let the settled prompt squeeze the toolbar out of a
                    // short window: cap it to a slice of the pane.
                    maxLines: min(6, max(2, Int(paneHeight * 0.35 / 22)))
                )
                .frame(minHeight: 38, alignment: .topLeading)
                .transition(.opacity)
            } else {
                InlineMentionTextEditor(
                    text: $draft,
                    mentionNames: attachments
                        .filter {
                            !$0.relativePath.hasPrefix(".context/attachments/")
                                || inlinePastedPaths.contains($0.relativePath)
                        }
                        .map(\.displayName),
                    onTab: acceptFirstMentionSuggestion,
                    onPaste: handlePasteboard,
                    onCopy: handleComposerCopy,
                    previewURL: previewURL(for:)
                )
                    .frame(height: min(max(composerTextHeight + 16, 38), 200))
                    .focused($composerFocused)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(placeholder)
                                .font(.system(size: OreTheme.Font.prose))
                                .foregroundStyle(.tertiary)
                                // Match the editor's textContainerInset (5×6) so the
                                // placeholder sits exactly where the caret and typed
                                // text do, instead of 6pt above them.
                                .padding(.leading, 5)
                                .padding(.top, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .background(
                        // A hidden copy of the text, measured at the editor's width,
                        // grows the composer with its content — one line by default,
                        // up to a scroll cap — instead of a fixed 72pt box.
                        Text(draft.isEmpty ? " " : draft)
                            .font(.system(size: OreTheme.Font.prose))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(GeometryReader { geo in
                                Color.clear
                                    .onAppear { composerTextHeight = geo.size.height }
                                    .onChange(of: draft) { _, _ in composerTextHeight = geo.size.height }
                            })
                            .hidden()
                    )
            }

            if let tab = chatSummary {
                composerToolbar(for: tab)
            }
        }
        // While the agent runs, the composer's own border animates — the input
        // box *is* the progress indicator, not a chip floating beside it.
        .oreComposerSurface(
            padding: 10,
            isBusy: chat.isBusy,
            reduceMotion: reduceMotion,
            // The glow keeps burning through the settle beat: the turn has not
            // gone out yet, so voice mode is not over yet either.
            voiceGlow: voice.isListening ? .full : (voice.isActive || voiceSettle != nil) ? .subdued : .off,
            voiceEnergy: voice.audioLevel
        )
        .animation(.easeOut(duration: 0.2), value: chat.isBusy)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: voice.isActive)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: voice.isListening)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: voiceSettle)
        // Left-aligned to sit in the same column as the transcript, rather than
        // centring while the prose above it starts at the leading edge.
        .frame(maxWidth: OreTheme.contentMaxWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, OreTheme.Space.md)
        .padding(.vertical, 10)
        .dropDestination(for: URL.self) { urls, _ in
            addFiles(urls)
            return true
        }
    }

    private func composerToolbar(for tab: ChatSummary) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: OreTheme.Space.xs) {
                attachmentMenu
                modelChooserButton(for: tab)
                if supportsEffort(for: tab) {
                    effortButton(for: tab)
                }
                permissionChip
                modeControls(for: tab)

                if let usage = chat.usage ?? tab.contextUsage,
                   let window = usage.contextWindow, window > 0 {
                    ContextMeter(
                        used: usage.totalContextTokens,
                        window: window,
                        usage: usage,
                        modelName: tab.model
                    )
                }

                Spacer(minLength: OreTheme.Space.md)
                composerSendCluster
            }

            HStack(spacing: OreTheme.Space.xs) {
                attachmentMenu
                modelChooserButton(for: tab)
                permissionChip
                modeControls(for: tab)
                Spacer(minLength: OreTheme.Space.md)
                composerSendCluster
            }
        }
        .frame(minHeight: 34)
    }

    private var permissionChip: some View {
        let current = chatSummary?.permissionMode ?? workspace.permissionMode
        // Switching is always allowed in an open chat. On a harness that binds
        // its policy per turn the change lands on the next one, and saying so
        // is the difference between "later" and "ignored".
        let landsNextTurn = chat.isBusy
            && !(chatSummary?.capabilities.supportsRuntimePermissionModeChange ?? true)
        return Menu {
            ForEach(PermissionMode.allCases, id: \.self) { mode in
                Button {
                    model.setPermissionMode(mode, for: workspace.id)
                } label: {
                    if mode == current {
                        Label(mode.displayName, systemImage: "checkmark")
                    } else {
                        Text(mode.displayName)
                    }
                }
            }
            if landsNextTurn {
                Divider()
                Text("Applies from the next turn")
            }
        } label: {
            chipLabel(current.displayName, systemImage: "shield.lefthalf.filled")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(landsNextTurn
            ? "Permission mode — \(chatSummary?.harness.displayName ?? "this agent") applies it from the next turn"
            : "Permission mode")
    }

    /// Generic Allow/Deny is the wrong surface when a dedicated card already
    /// answers the same permission request.
    private func hidesGenericPermission(_ permission: PermissionRequest) -> Bool {
        if permission.toolName == "AskUserQuestion" { return true }
        if permission.toolName == "ExitPlanMode", case .proposal = chat.plan {
            return true
        }
        return false
    }

    @ViewBuilder
    private func modeControls(for tab: ChatSummary) -> some View {
        if supportsFastMode(tab) {
            Menu {
                Button {
                    fastModeEnabled = false
                } label: {
                    Label("Standard", systemImage: fastModeEnabled ? "circle" : "checkmark")
                }
                Button {
                    fastModeEnabled = true
                } label: {
                    Label("Fast · higher credit use", systemImage: fastModeEnabled ? "checkmark" : "bolt.fill")
                }
            } label: {
                ComposerModeTag(
                    title: fastModeEnabled ? "Fast" : "Standard",
                    systemImage: fastModeEnabled ? "bolt.fill" : "speedometer",
                    tint: fastModeEnabled ? .orange : .secondary
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Codex processing tier. Fast increases speed and credit use.")
        }
    }

    private func supportsFastMode(_ tab: ChatSummary) -> Bool {
        guard tab.harness == .codex else { return false }
        let choices = model.knownModels(for: tab.harness)
        let selected = tab.model.flatMap { id in choices.first { $0.id == id } }
            ?? choices.first(where: \.isDefault)
        return selected?.supportedServiceTiers.contains("fast") == true
    }

    /// The composer's controls all read as one kind of object: a bordered
    /// capsule with an icon and a word. A shared height and padding is exactly
    /// what the old mix of plain labels, a fixed-width Picker, and bare icons
    /// was missing.
    private func chipLabel(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 11))
            Text(text).font(.system(size: OreTheme.Font.body)).lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(OreTheme.subduedFill, in: Capsule())
        .contentShape(Capsule())
    }

    private func iconChip(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 12))
            .frame(width: 26, height: 26)
            .background(OreTheme.subduedFill, in: Capsule())
            .contentShape(Capsule())
    }

    private var attachmentMenu: some View {
        Menu {
            Button("Attach Files…", systemImage: "paperclip") { chooseFiles() }
            Button("Reference Workspace File…", systemImage: "at") { referenceFiles() }
            Divider()
            Text("Drop files here, or type / for commands")
        } label: {
            iconChip("paperclip")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add files or references")
    }

    private func modelChooserButton(for tab: ChatSummary) -> some View {
        Button { handleModelChipTap(for: tab) } label: {
            modelChipLabel(for: tab)
        }
        .buttonStyle(OrePressableButtonStyle())
        .fixedSize()
        .overlay {
            // Scroll over the chip to switch harness (to each one's default
            // model) — the same gesture, animation, and haptics as the effort
            // chip beside it.
            ScrollWheelAdjuster(
                onProgress: { progress in
                    withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.2, dampingFraction: 0.8)) {
                        modelScrollProgress = progress
                    }
                },
                onStep: { direction in adjustHarnessDefault(direction, for: tab) }
            )
        }
        .popover(isPresented: $showModelChooser, arrowEdge: .bottom) {
            ModelChooser(
                currentHarness: tab.harness,
                currentModel: tab.model,
                harnesses: model.readyHarnesses,
                models: { model.knownModels(for: $0) }
            ) { harness, selectedModel in
                if harness == tab.harness { model.setModel(selectedModel, for: tab) }
                else { model.switchHarness(harness, model: selectedModel, for: tab) }
                showModelChooser = false
            }
        }
        .help(modelChipHelp(for: tab))
    }

    private func modelChipHelp(for tab: ChatSummary) -> String {
        if let pending = voicePendingModel {
            return "Click to switch to \(pending.displayName) now"
        }
        return "Model: \(modelDisplayName(for: tab)). Scroll to switch agent."
    }

    /// A highlighted pending model is a confirmation, not a prompt to pick
    /// something else. Opening the chooser stole focus into its search field
    /// and ate both clicks and the rest of the dictation.
    private func handleModelChipTap(for tab: ChatSummary) {
        if let pending = voicePendingModel {
            applyVoiceModel(pending, to: tab)
            voicePendingModel = nil
            return
        }
        showModelChooser.toggle()
    }

    private func modelChipLabel(for tab: ChatSummary) -> some View {
        HStack(spacing: 6) {
            HarnessMark(harness: voicePendingModel?.harness ?? tab.harness, size: 17)
            Text(voicePendingModel?.displayName ?? modelDisplayName(for: tab))
                .font(.system(size: OreTheme.Font.body))
                .lineLimit(1)
                .contentTransition(.numericText())
            Color.clear.frame(width: 7, height: 1)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            voicePendingModel == nil ? AnyShapeStyle(OreTheme.subduedFill)
                : AnyShapeStyle(Color.accentColor.opacity(0.16)),
            in: Capsule()
        )
        .overlay {
            Capsule().stroke(
                voicePendingModel != nil
                    ? Color.accentColor.opacity(0.75)
                    : modelScrollProgress == 0
                        ? OreTheme.hairline
                        : Color.accentColor.opacity(0.25 + 0.45 * abs(modelScrollProgress)),
                lineWidth: voicePendingModel != nil ? 1.5 : 1
            )
        }
        .overlay(alignment: .trailing) {
            Image(systemName: modelScrollProgress >= 0 ? "chevron.up" : "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .padding(.trailing, 7)
                .opacity(min(1, abs(modelScrollProgress) * 1.6))
                .offset(y: reduceMotion ? 0 : -modelScrollProgress * 1.5)
        }
        .overlay(alignment: .bottomLeading) {
            GeometryReader { geometry in
                Capsule()
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: max(0, geometry.size.width * abs(modelScrollProgress)), height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .clipShape(Capsule())
        }
        .scaleEffect(reduceMotion ? 1 : 1 + abs(modelScrollProgress) * 0.018)
        .contentShape(Capsule())
        .symbolEffect(.bounce, value: modelStepPulse)
    }

    /// Scrolling the model chip steps between ready harnesses, selecting each
    /// one's default model — "between the default models of different harnesses".
    private func adjustHarnessDefault(_ direction: Int, for tab: ChatSummary) -> Bool {
        let harnesses = model.readyHarnesses
        guard harnesses.count > 1 else { return false }
        let index = harnesses.firstIndex(of: tab.harness) ?? 0
        let next = harnesses[(index + direction).clamped(to: 0...(harnesses.count - 1))]
        guard next != tab.harness else { return false }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.68)) {
            modelStepPulse += 1
        }
        model.switchHarness(next, model: model.defaultModelID(for: next), for: tab)
        return true
    }

    private func modelDisplayName(for tab: ChatSummary) -> String {
        let models = model.knownModels(for: tab.harness)
        guard let selected = tab.model else {
            return models.first(where: \.isDefault)?.displayName
                ?? models.first?.displayName
                ?? tab.harness.displayName
        }
        return models.first { $0.id == selected }?.displayName ?? selected
    }

    private func effortButton(for tab: ChatSummary) -> some View {
        Button { showEffortChooser.toggle() } label: {
            effortChipLabel
        }
        .buttonStyle(OrePressableButtonStyle())
        .fixedSize()
        .overlay {
            ScrollWheelAdjuster(
                onProgress: { progress in
                    withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.2, dampingFraction: 0.8)) {
                        effortScrollProgress = progress
                    }
                },
                onStep: { direction in adjustEffort(direction, for: tab) }
            )
        }
        .popover(isPresented: $showEffortChooser, arrowEdge: .bottom) {
            EffortChooser(
                selection: $reasoningEffort,
                efforts: availableEfforts(for: tab),
                harness: tab.harness
            )
        }
        .help("Reasoning effort: \(reasoningEffort.displayName). Scroll to adjust.")
    }

    private var effortChipLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 11))
                .symbolEffect(.bounce, value: effortStepPulse)
            Text(reasoningEffort.displayName)
                .font(.system(size: OreTheme.Font.body))
                .lineLimit(1)
                .contentTransition(.numericText())
            Color.clear.frame(width: 7, height: 1)
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(OreTheme.subduedFill, in: Capsule())
        .overlay {
            Capsule().stroke(
                effortScrollProgress == 0
                    ? OreTheme.hairline
                    : Color.accentColor.opacity(0.25 + 0.45 * abs(effortScrollProgress)),
                lineWidth: 1
            )
        }
        .overlay(alignment: .trailing) {
            Image(systemName: effortScrollProgress >= 0 ? "chevron.up" : "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .padding(.trailing, 9)
                .opacity(min(1, abs(effortScrollProgress) * 1.6))
                .offset(y: reduceMotion ? 0 : -effortScrollProgress * 1.5)
        }
        .overlay(alignment: .bottomLeading) {
            GeometryReader { geometry in
                Capsule()
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(
                        width: max(0, geometry.size.width * abs(effortScrollProgress)),
                        height: 2
                    )
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .clipShape(Capsule())
        }
        .scaleEffect(reduceMotion ? 1 : 1 + abs(effortScrollProgress) * 0.018)
        .contentShape(Capsule())
    }

    private func supportsEffort(for tab: ChatSummary) -> Bool {
        !availableEfforts(for: tab).isEmpty
    }

    private func availableEfforts(for tab: ChatSummary) -> [ReasoningEffort] {
        let choices = model.knownModels(for: tab.harness)
        let selected = tab.model.flatMap { id in choices.first { $0.id == id } }
            ?? choices.first(where: \.isDefault)
        let advertised = Set(selected?.supportedReasoningEfforts ?? [])
        guard !advertised.isEmpty else { return [] }
        return ReasoningEffort.allCases.filter { advertised.contains($0.rawValue) }
    }

    private func adjustEffort(_ direction: Int, for tab: ChatSummary) -> Bool {
        let efforts = availableEfforts(for: tab)
        guard !efforts.isEmpty else { return false }
        let index = efforts.firstIndex(of: reasoningEffort)
            ?? efforts.lastIndex(where: { $0.rawValue == ReasoningEffort.high.rawValue })
            ?? 0
        let next = efforts[(index + direction).clamped(to: 0...(efforts.count - 1))]
        guard next != reasoningEffort else { return false }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.68)) {
            reasoningEffort = next
            effortStepPulse += 1
        }
        return true
    }

    private func harnessIcon(_ harness: HarnessKind) -> String {
        switch harness {
        case .claudeCode: "sparkles"
        case .codex: "bolt.fill"
        case .cursorAgent: "cursorarrow.rays"
        }
    }

    /// Mic and send are one trailing pair: same 30pt circle, 8pt between them,
    /// and a wider gap from the chips so the accent action isn't crowded.
    private var composerSendCluster: some View {
        HStack(spacing: OreTheme.Space.sm) {
            micButton
            sendButton
        }
    }

    private var micButton: some View {
        Button(action: toggleVoice) {
            Group {
                if voice.status == .downloadingModel || voice.status == .preparing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: voice.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 13, weight: .semibold))
                        .symbolEffect(.pulse, isActive: voice.isListening && !reduceMotion)
                }
            }
            .foregroundStyle(voice.isListening ? Color.red : .primary)
            .frame(width: 30, height: 30)
            .background(
                voice.isListening ? Color.red.opacity(0.14) : OreTheme.subduedFill,
                in: Circle()
            )
            .overlay(
                Circle().stroke(
                    voice.isListening ? Color.red.opacity(0.45) : OreTheme.hairline,
                    lineWidth: 1
                )
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("m", modifiers: [.option, .command])
        .help(micHelp)
    }

    private var micHelp: String {
        switch voice.status {
        case .listening: return "Finish and send (Esc cancels)"
        case .preparing: return "Starting dictation…"
        case .downloadingModel: return "Downloading on-device speech model…"
        case .requestingPermission: return "Waiting for microphone permission…"
        case .error(let message): return message
        case .idle: return "Dictate prompt (⌥⌘M)"
        }
    }

    private func toggleVoice() {
        // Pressing again during the hold means "go now": send the pending turn
        // rather than opening a second dictation on top of it.
        if voice.isActive || voiceSettle != nil {
            finishVoice(.send)
        } else {
            startVoice()
        }
    }

    private func startVoice() {
        guard !voice.isActive else { return }
        // Talking again before the previous turn's hold elapses flushes it, so
        // two dictations can never share a composer.
        resolveVoiceSettle(.send)
        voiceAttachedClipboard = false
        voicePendingModel = nil
        voiceChanges = []
        voiceCanceledFilePaths = []
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            voiceQuote = ""
        }
        composerFocused = true
        // Load the on-device model while the user talks, so the commit-time
        // refinement doesn't pay the cold start.
        VoiceIntentRefiner.shared.prewarm()
        voice.start()
    }

    /// The recognizer failing flips `isActive` off before `finishVoice` can
    /// run, which would silently drop everything already spoken. Park the words
    /// in the draft and let the placeholder surface the error.
    private func handleVoiceStatusChange(_ status: VoiceInputController.Status) {
        guard case .error = status else { return }
        let spoken = voice.transcript
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            voiceQuote = ""
        }
        clearVoiceTrail()
        let outcome = VoiceTurnCommit.resolve(
            .commitToDraft,
            prefix: draft,
            spokenFormatted: formattedVoiceText(spoken: spoken)
        )
        if case .updateDraft(let text) = outcome {
            draft = text
        }
    }

    /// Ends the voice session. Ending the chord (or the mic button, or ⌘↩)
    /// sends the dictated words as a turn — after a beat holding the finished
    /// prompt on screen; Esc throws them away; passive teardown — switching
    /// tabs, the pane disappearing — parks them in the draft so nothing fires
    /// that the user didn't ask for.
    private func finishVoice(_ disposition: VoiceTurnCommit.Disposition) {
        // A turn already waiting out its hold is what this disposition is
        // about: the recognizer is idle, but nothing has been sent yet.
        if resolveVoiceSettle(disposition) { return }
        guard voice.isActive else { return }
        let spoken = voice.transcript
        voice.stop()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            voiceQuote = ""
        }
        if case .cancel = disposition {
            clearVoiceTrail()
            voiceAttachedClipboard = false
            return
        }
        let finalText = finalizeVoiceIntents(spoken: spoken)
        switch VoiceTurnCommit.resolve(disposition, prefix: draft, spokenFormatted: finalText) {
        case .send(let text):
            holdThenSend(VoiceSettledTurn(quote: finalText, combined: text, spoken: spoken))
        case .updateDraft(let text):
            draft = text
        case .none:
            break
        }
    }

    /// Swaps the live one-line quote for the whole prompt, then sends it. The
    /// wait is what lets the user read what the recognizer actually heard
    /// before it reaches the agent.
    private func holdThenSend(_ turn: VoiceSettledTurn) {
        voiceSettleTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            voiceSettle = turn
        }
        voiceSettleTask = Task { @MainActor in
            try? await Task.sleep(for: VoiceSettledTurn.hold)
            guard !Task.isCancelled else { return }
            resolveVoiceSettle(.send)
        }
    }

    /// Settles a turn that is waiting out its hold, and reports whether there
    /// was one. Esc during the beat still cancels it, a second chord or mic
    /// press sends it early rather than waiting, and passive teardown parks it
    /// in the draft — the same three outcomes a live session has.
    @discardableResult
    private func resolveVoiceSettle(_ disposition: VoiceTurnCommit.Disposition) -> Bool {
        guard let settled = voiceSettle else { return false }
        voiceSettleTask?.cancel()
        voiceSettleTask = nil
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            voiceSettle = nil
        }
        switch disposition {
        case .send:
            sendVoiceTurn(regexCombined: settled.combined, spoken: settled.spoken)
        case .commitToDraft:
            draft = settled.combined
        case .cancel:
            clearVoiceTrail()
            voiceAttachedClipboard = false
        }
        return true
    }

    /// The auto-send path: before the turn goes out, one on-device language
    /// model call arbitrates what the regex pass may have missed — fuzzy file
    /// references, indirect settings requests — and produces the final
    /// cleaned prompt. Regex output is the floor: unavailable model, timeout,
    /// or an empty parse all fall back to it, so send never blocks on the
    /// refiner for more than its watchdog.
    private func sendVoiceTurn(regexCombined: String, spoken: String) {
        let prefix = draft
        // The words land in the draft before anything async happens: whatever
        // the refiner does — improve, time out, or fail — the user's speech is
        // already visible and sendable, never held hostage.
        draft = regexCombined
        guard VoiceIntentRefiner.shared.isAvailable else {
            performSend()
            return
        }
        let catalog = voiceSettingsCatalog()
        let candidates = VoiceFileCandidates.rank(
            transcript: spoken,
            files: workspaceFileIndex
                .filter { !$0.isDirectory }
                .map { VoiceFileCandidates.Candidate(name: $0.name, path: $0.path) }
        )
        Task {
            let refinement = await VoiceIntentRefiner.shared.refine(
                spoken: spoken,
                catalog: catalog,
                fileCandidates: candidates
            )
            if let refinement {
                if let id = refinement.modelID, let tab = chatSummary,
                   let chosen = catalog.models.first(where: { $0.id == id }) {
                    applyVoiceModel(chosen, to: tab)
                }
                if let effort = refinement.effort, let tab = chatSummary,
                   availableEfforts(for: tab).contains(effort) {
                    reasoningEffort = effort
                }
                if let mode = refinement.mode, mode != workspace.permissionMode {
                    model.setPermissionMode(mode, for: workspace.id)
                }
                // Prefer the model's cleaned prompt, but never let it drop
                // words: an empty parse means the model over-stripped, and
                // the regex floor wins.
                if let cleaned = refinement.cleanedPrompt {
                    draft = VoiceDraft.combined(
                        prefix: prefix,
                        transcript: VoiceDictationFormatter.format(cleaned)
                    )
                }
                // The deterministic pass may already have tagged a file inline;
                // appending its token again would double it up in the prompt.
                for file in refinement.files
                where !chat.draftAttachments.contains(where: { $0.relativePath == file.path }) {
                    insertWorkspaceReference(path: file.path, displayName: file.name)
                }
            }
            performSend()
        }
    }

    /// Runs on every partial transcript. Extraction costs well under a
    /// millisecond now that it is plain alias matching, so the chips can track
    /// speech instead of waiting for the mic to stop.
    ///
    /// Effort and mode are applied immediately — they are local state. The model
    /// is only *shown*; committing it is deferred to `finalizeVoiceIntents`.
    private func applyLiveVoiceIntents(spoken: String) {
        let intents = voiceIntents(from: spoken)

        if let effort = intents.effort, let tab = chatSummary,
           availableEfforts(for: tab).contains(effort), effort != reasoningEffort {
            reasoningEffort = effort
        }
        if let mode = intents.permissionMode, mode != workspace.permissionMode {
            model.setPermissionMode(mode, for: workspace.id)
        }

        // Recognized settings are sticky for the rest of the dictation. A later
        // partial no longer mentions the model — and if the user edits the
        // composer mid-dictation the spoken words are dropped entirely — so
        // reading them off the newest transcript alone would make the chip
        // flicker back and lose the change before it is committed.
        let animation: Animation? = reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.72)
        withAnimation(animation) {
            if let chosen = intents.model { voicePendingModel = chosen }
            mergeVoiceChanges(intents.changes)
        }

        // No animation on the streaming text itself: partials arrive several
        // times a second, and retargeting a transition on every one is churn
        // the transcript view no longer opts into. Chip and trail changes —
        // rare, deliberate — keep theirs above.
        //
        // The quote shows what was said, verbatim, and only ever grows.
        //
        // It used to show the *rewritten* text, with recognized command clauses
        // cut out. But recognition is unstable across partials — the recognizer
        // revises "switch to opus" into "switched to Op. 5", which no longer
        // matches — so the clause was removed on one partial and came back on
        // the next, and the words visibly shrank and regrew while being spoken.
        // The chip and the struck-through trail already report what was heard;
        // the command phrases come out at commit, where the on-device refiner
        // arbitrates instead of a per-partial alias match.
        voiceQuote = VoiceDictationFormatter.format(spoken)
    }

    /// The transcript with settings clauses stripped and spoken breaks applied,
    /// without any of the end-of-session side effects.
    private func formattedVoiceText(spoken: String) -> String {
        VoiceDictationFormatter.format(voiceIntents(from: spoken).rewritten)
    }

    /// Latest value per kind, first-spoken order. Files are the exception:
    /// several can be referenced in one dictation, so they merge by identity
    /// rather than replacing each other.
    private func mergeVoiceChanges(_ incoming: [VoiceChange]) {
        guard !incoming.isEmpty else { return }
        var merged = voiceChanges
        for change in incoming {
            let index = change.kind == .file
                ? merged.firstIndex(where: { $0.id == change.id })
                : merged.firstIndex(where: { $0.kind == change.kind })
            if let index {
                merged[index] = change
            } else {
                merged.append(change)
            }
        }
        voiceChanges = merged
    }

    private func clearVoiceTrail() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) {
            voiceChanges = []
            voicePendingModel = nil
        }
    }

    private func confirmVoiceChange(_ change: VoiceChange) {
        switch change.kind {
        case .model:
            guard let chosen = voicePendingModel, let tab = chatSummary else { return }
            applyVoiceModel(chosen, to: tab)
            voicePendingModel = nil
        case .file:
            // Tapping a file chip cancels that tag: the path is excluded for
            // the rest of the session, and re-running the live pass puts the
            // spoken words back into the quote.
            guard let path = change.detail else { return }
            voiceCanceledFilePaths.insert(path)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                voiceChanges.removeAll { $0.id == change.id }
            }
            applyLiveVoiceIntents(spoken: voice.transcript)
        case .effort, .mode, .clipboard:
            break
        }
    }

    private func voiceIntents(from spoken: String) -> VoiceIntents {
        VoiceIntentExtractor.extract(
            from: spoken,
            catalog: voiceSettingsCatalog(),
            fileMatcher: voiceFileMatcher,
            excludedFilePaths: voiceCanceledFilePaths
        )
    }

    private func voiceSettingsCatalog() -> VoiceSettingsCatalog {
        VoiceSettingsCatalog(
            models: HarnessKind.allCases.flatMap { harness -> [VoiceModelCandidate] in
                // Naming only the harness ("switch to Codex") should land on the
                // model the user actually defaults to, not the catalog's first row.
                let fallback = model.defaultModelID(for: harness)
                return model.knownModels(for: harness).map {
                    VoiceModelCandidate(
                        harness: harness,
                        id: $0.id,
                        displayName: $0.displayName,
                        isDefault: $0.id == fallback
                    )
                }
            },
            efforts: chatSummary.map { availableEfforts(for: $0) } ?? Array(ReasoningEffort.allCases),
            modes: Array(PermissionMode.allCases)
        )
    }

    /// Clipboard and mode/model/effort — applied when dictation ends, not on
    /// every partial transcript. Spoken filenames are left for the agent.
    /// Returns the formatted, intent-stripped text ready to send or park in
    /// the draft; settings commit even when nothing sendable was said.
    private func finalizeVoiceIntents(spoken: String) -> String {
        let intents = voiceIntents(from: spoken)
        var rewritten = intents.rewritten

        if intents.attachClipboard, !voiceAttachedClipboard {
            switch handlePasteboard(NSPasteboard.general, allowComposerDraft: false) {
            case .insert(let token):
                voiceAttachedClipboard = true
                rewritten = VoiceIntentExtractor.incorporateClipboardToken(token, into: rewritten)
            case .consumed:
                voiceAttachedClipboard = true
                rewritten = VoiceIntentExtractor.incorporateClipboardToken("", into: rewritten)
            case .ignored:
                break
            }
        }

        if let mode = intents.permissionMode {
            model.setPermissionMode(mode, for: workspace.id)
        }
        // The one change held back from the live pass — this is where the
        // session actually switches, once the transcript is final. Prefer the
        // value recognized at any point during dictation over whatever is still
        // present in the closing transcript.
        if let chosen = voicePendingModel ?? intents.model, let tab = chatSummary {
            applyVoiceModel(chosen, to: tab)
        }
        if let effort = intents.effort, let tab = chatSummary {
            let allowed = availableEfforts(for: tab)
            if allowed.contains(effort) { reasoningEffort = effort }
        }
        // The rewritten text already carries each file's `@Name` token where
        // the spoken reference was; this attaches the file behind the token,
        // exactly as a typed mention would. Cancelled chips never get here —
        // their paths are excluded from extraction.
        for file in intents.files {
            insertWorkspaceReference(path: file.path, displayName: file.name, appendToken: false)
        }

        voicePendingModel = nil

        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
            mergeVoiceChanges(intents.changes)
        }

        // Let the trail sit long enough to read, then fade it out.
        if !voiceChanges.isEmpty {
            let generation = voiceChanges
            Task {
                try? await Task.sleep(for: .seconds(3))
                guard voiceChanges == generation else { return }
                clearVoiceTrail()
            }
        }

        return VoiceDictationFormatter.format(rewritten)
    }

    private func applyVoiceModel(_ chosen: VoiceModelCandidate, to tab: ChatSummary) {
        if chosen.harness == tab.harness {
            model.setModel(chosen.id, for: tab)
        } else {
            model.switchHarness(chosen.harness, model: chosen.id, for: tab)
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if #available(macOS 26.0, *) {
            Button(action: send) {
                Image(systemName: chat.isBusy ? "text.append" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(.accentColor)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.draftAttachments.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .help(chat.isBusy ? "Queue this message (⌘↩)" : "Send (⌘↩)")
        } else {
            Button(action: send) {
                Image(systemName: chat.isBusy ? "text.append" : "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor, in: Circle())
                    .shadow(color: Color.accentColor.opacity(0.16), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.draftAttachments.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .help(chat.isBusy ? "Queue this message (⌘↩)" : "Send (⌘↩)")
        }
    }

    private var placeholder: String {
        if case .preparing = voice.status { return "Starting dictation…" }
        if case .downloadingModel = voice.status { return "Downloading speech model…" }
        if case .error(let message) = voice.status { return message }
        return chat.draftComments.isEmpty
            ? "Ask the agent to do something…"
            : "\(chat.draftComments.count) review comment"
                + (chat.draftComments.count == 1 ? "" : "s")
                + " will be sent with this message"
    }

    private func send() {
        // ⌘↩ mid-dictation ends the session, which sends exactly once through
        // `finishVoice` rather than racing it — including a turn still waiting
        // out its hold, whose words are not in the draft yet.
        if voice.isActive || voiceSettle != nil {
            finishVoice(.send)
            return
        }
        performSend()
    }

    private func performSend() {
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoing = attachments
        guard !text.isEmpty || !outgoing.isEmpty else { return }
        if text.isEmpty { text = "Review the attached files." }
        model.send(
            text,
            attachments: outgoing,
            effort: chatSummary.map { supportsEffort(for: $0) } == true ? reasoningEffort : nil,
            serviceTier: chatSummary.map { supportsFastMode($0) } == true && fastModeEnabled ? "fast" : nil,
            to: workspace.id
        )
        draft = ""
        // Cleared, not discarded: the files were just sent, so the copies under
        // .context/attachments are still referenced by the message.
        attachments = []
        inlinePastedPaths = []
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls)
    }

    private func referenceFiles() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: workspace.worktreePath)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let root = URL(fileURLWithPath: workspace.worktreePath).standardizedFileURL.path + "/"
        for url in panel.urls where url.standardizedFileURL.path.hasPrefix(root) {
            let relative = String(url.standardizedFileURL.path.dropFirst(root.count))
            insertWorkspaceReference(path: relative, displayName: url.lastPathComponent)
        }
    }

    private var externalAttachments: [(offset: Int, element: Attachment)] {
        Array(chat.draftAttachments.enumerated()).filter {
            $0.element.relativePath.hasPrefix(".context/attachments/")
                && !inlinePastedPaths.contains($0.element.relativePath)
        }
    }

    private func persistAttachments(_ attachments: [Attachment]) {
        if let chatSummary {
            model.persistDraftAttachments(attachments, for: chatSummary.id)
        } else {
            chat.draftAttachments = attachments
        }
    }

    /// Takes an attachment off the draft *and* off the disk.
    ///
    /// Dropping a file on the composer copies it into `.context/attachments/`.
    /// Removing the chip used to drop only the reference, so every screenshot
    /// the user pasted and then thought better of stayed in the worktree
    /// forever. Only ORE's own copies are deleted — a chip pointing at a file
    /// that already lived in the workspace is just a reference to it.
    private func discardAttachments(at indices: IndexSet) {
        var next = chat.draftAttachments
        for index in indices.sorted(by: >) {
            guard next.indices.contains(index) else { continue }
            deleteCopiedFile(next.remove(at: index))
        }
        persistAttachments(next)
    }

    private func deleteCopiedFile(_ attachment: Attachment) {
        guard attachment.relativePath.hasPrefix(".context/attachments/"),
              !attachment.relativePath.contains("..")
        else { return }
        try? FileManager.default.removeItem(
            at: attachment.fileURL(worktreePath: workspace.worktreePath)
        )
    }

    /// A file URL to preview when the pointer rests on an inline `@name` token —
    /// pasted images and long text dumps, not every workspace file mention.
    private func previewURL(for name: String) -> URL? {
        guard let attachment = attachments.first(where: { $0.displayName == name }),
              attachment.isHoverPreviewable else { return nil }
        return attachment.fileURL(worktreePath: workspace.worktreePath)
    }

    private func addFiles(_ urls: [URL]) {
        let folder = URL(fileURLWithPath: workspace.worktreePath)
            .appendingPathComponent(".context/attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var next = chat.draftAttachments
        for source in urls where source.isFileURL {
            let name = "\(UUID().uuidString.prefix(8))-\(source.lastPathComponent)"
            let destination = folder.appendingPathComponent(name)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                next.append(Attachment(
                    relativePath: ".context/attachments/\(name)",
                    displayName: source.lastPathComponent,
                    mimeType: UTType(filenameExtension: source.pathExtension)?.preferredMIMEType
                ))
            } catch { continue }
        }
        persistAttachments(next)
    }

    /// Attaches whatever was pasted: a copied file lands as a shelf attachment; a
    /// screenshot is written out as a PNG chip; a long text dump becomes
    /// `@pasted-text.txt` at the caret. Short text still types in as usual.
    private func handlePasteboard(_ pasteboard: NSPasteboard) -> PasteOutcome {
        handlePasteboard(pasteboard, allowComposerDraft: true)
    }

    private func handlePasteboard(
        _ pasteboard: NSPasteboard,
        allowComposerDraft: Bool
    ) -> PasteOutcome {
        if allowComposerDraft, restoreComposerDraft(from: pasteboard) {
            return .ignored
        }
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            addFiles(urls)
            return .consumed
        }
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)
            as? [NSImage], !images.isEmpty {
            return addPastedImages(images)
        }
        // Some sources (screenshots, certain apps) only put raw image data on the
        // board rather than an NSImage object; pick it up directly.
        for type: NSPasteboard.PasteboardType in [.png, .tiff] {
            if let data = pasteboard.data(forType: type), let image = NSImage(data: data) {
                return addPastedImages([image])
            }
        }
        if let text = pasteboard.string(forType: .string), Attachment.shouldAttachPastedText(text) {
            return addPastedText(text)
        }
        return .ignored
    }

    private func handleComposerCopy(_ pasteboard: NSPasteboard, selectedText: String) {
        let payload = ComposerPasteboard.payload(
            forCopiedText: selectedText,
            fullDraft: draft,
            attachments: attachments,
            inlinePaths: inlinePastedPaths
        )
        guard !payload.attachments.isEmpty else { return }
        ComposerPasteboard.write(payload, to: pasteboard)
    }

    /// Rehydrates `@` chips and the shelf when composer text is pasted into
    /// another tab. Files already live in this worktree; we only restore the
    /// attachment records so the tokens style again.
    @discardableResult
    private func restoreComposerDraft(from pasteboard: NSPasteboard) -> Bool {
        guard let payload = ComposerPasteboard.read(from: pasteboard),
              !payload.attachments.isEmpty else { return false }
        var next = attachments
        for item in payload.attachments where !next.contains(where: { $0.relativePath == item.relativePath }) {
            next.append(item)
        }
        persistAttachments(next)
        inlinePastedPaths.formUnion(payload.inlinePaths)
        return true
    }

    /// Writes each pasted image out and returns the `@name` tokens to insert at
    /// the caret. `.consumed` (no tokens) if nothing could be encoded.
    private func addPastedImages(_ images: [NSImage]) -> PasteOutcome {
        let folder = URL(fileURLWithPath: workspace.worktreePath)
            .appendingPathComponent(".context/attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var tokens: [String] = []
        for image in images {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let display = uniquePastedName(prefix: "pasted-image", ext: "png")
            let name = "\(UUID().uuidString.prefix(8))-\(display)"
            let destination = folder.appendingPathComponent(name)
            do {
                try png.write(to: destination)
                let relativePath = ".context/attachments/\(name)"
                attachments.append(Attachment(
                    relativePath: relativePath,
                    displayName: display,
                    mimeType: "image/png"
                ))
                inlinePastedPaths.insert(relativePath)
                tokens.append("@\(display)")
            } catch { continue }
        }
        guard !tokens.isEmpty else { return .consumed }
        // A trailing space leaves the caret outside the styled token, so the next
        // keystroke types plainly — the same feel as inserting a file mention.
        return .insert(tokens.joined(separator: " ") + " ")
    }

    /// Writes a long paste out as a text file and returns the `@name` token to
    /// insert at the caret — the same chip treatment as a pasted screenshot.
    private func addPastedText(_ text: String) -> PasteOutcome {
        let folder = URL(fileURLWithPath: workspace.worktreePath)
            .appendingPathComponent(".context/attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let display = uniquePastedName(prefix: "pasted-text", ext: "txt")
        let name = "\(UUID().uuidString.prefix(8))-\(display)"
        let destination = folder.appendingPathComponent(name)
        do {
            try text.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            return .ignored
        }
        let relativePath = ".context/attachments/\(name)"
        attachments.append(Attachment(
            relativePath: relativePath,
            displayName: display,
            mimeType: "text/plain"
        ))
        inlinePastedPaths.insert(relativePath)
        return .insert("@\(display) ")
    }

    /// A draft-unique display name so each inline `@pasted-image.png` /
    /// `@pasted-text.txt` token maps to exactly one attachment.
    private func uniquePastedName(prefix: String, ext: String) -> String {
        let existing = Set(attachments.map(\.displayName))
        var candidate = "\(prefix).\(ext)"
        var index = 1
        while existing.contains(candidate) {
            index += 1
            candidate = "\(prefix)-\(index).\(ext)"
        }
        return candidate
    }

    private var slashCommands: [ComposerCommand] {
        guard draft.hasPrefix("/"), !draft.contains("\n") else { return [] }
        let query = String(draft.dropFirst()).lowercased()
        return ComposerCommand.all.filter { query.isEmpty || $0.name.dropFirst().hasPrefix(query) }
    }

    private var mentionSuggestions: [WorkspaceFileNode] {
        guard let mention = activeMention else { return [] }
        let query = mention.query.lowercased()
        return workspaceFileIndex
            .filter { node in
                !node.isDirectory
                    && !chat.draftAttachments.contains(where: { $0.relativePath == node.path })
                    && (query.isEmpty
                        || node.name.lowercased().contains(query)
                        || node.path.lowercased().contains(query))
            }
            .sorted { first, second in
                let firstName = first.name.lowercased().hasPrefix(query)
                let secondName = second.name.lowercased().hasPrefix(query)
                if firstName != secondName { return firstName }
                // A bare `@` should lead with useful project files instead of
                // dotfiles such as .git and .replit. Explicit queries can still
                // find those files normally.
                if query.isEmpty {
                    let firstHidden = first.path.split(separator: "/").contains { $0.hasPrefix(".") }
                    let secondHidden = second.path.split(separator: "/").contains { $0.hasPrefix(".") }
                    if firstHidden != secondHidden { return !firstHidden }
                }
                if first.path.count != second.path.count { return first.path.count < second.path.count }
                return first.path.localizedCaseInsensitiveCompare(second.path) == .orderedAscending
            }
    }

    private var activeMention: (range: Range<String.Index>, query: String)? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at != draft.startIndex {
            let previous = draft[draft.index(before: at)]
            guard previous.isWhitespace else { return nil }
        }
        let start = draft.index(after: at)
        let suffix = draft[start...]
        guard !suffix.contains(where: \.isWhitespace) else { return nil }
        return (at..<draft.endIndex, String(suffix))
    }

    private func tagFile(_ node: WorkspaceFileNode) {
        guard let mention = activeMention else { return }
        draft.replaceSubrange(mention.range, with: "@\(node.name) ")
        insertWorkspaceReference(path: node.path, displayName: node.name, appendToken: false)
        composerFocused = true
    }

    private func insertWorkspaceReference(
        path: String,
        displayName: String,
        appendToken: Bool = true
    ) {
        if !chat.draftAttachments.contains(where: { $0.relativePath == path }) {
            persistAttachments(chat.draftAttachments + [
                Attachment(relativePath: path, displayName: displayName)
            ])
        }
        if appendToken {
            if !draft.isEmpty, !draft.last!.isWhitespace { draft.append(" ") }
            draft.append("@\(displayName) ")
        }
    }

    private func acceptFirstMentionSuggestion() -> Bool {
        guard let first = mentionSuggestions.first else { return false }
        tagFile(first)
        return true
    }

    private static func flattenFiles(_ nodes: [WorkspaceFileNode]) -> [WorkspaceFileNode] {
        nodes.flatMap { node in
            node.isDirectory ? flattenFiles(node.children ?? []) : [node]
        }
    }

    /// Agent output may use a repository-relative path, an absolute worktree
    /// path, or a short basename. Resolve all three into the workspace index so
    /// clicking a reference opens ORE's source tab rather than asking Finder to
    /// interpret a relative URL.
    private func openAgentFile(_ reference: String) {
        var candidate = reference.removingPercentEncoding ?? reference
        if candidate.hasPrefix("file://"), let url = URL(string: candidate) {
            candidate = url.path
        }
        // Capture a trailing `:line`, `:line:col`, or `:line,col` locator, then
        // strip it so the path resolves against the file index.
        var focusLine: Int?
        if let match = candidate.range(of: #":\d+(?:[:,]\d+)?$"#, options: .regularExpression) {
            let locator = candidate[match].dropFirst()  // drop the leading ':'
            focusLine = Int(locator.prefix { $0.isNumber })
            candidate.removeSubrange(match)
        }
        let root = workspace.worktreePath.hasSuffix("/")
            ? workspace.worktreePath
            : workspace.worktreePath + "/"
        if candidate.hasPrefix(root) { candidate.removeFirst(root.count) }
        while candidate.hasPrefix("./") { candidate.removeFirst(2) }
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "`'\"()[]{}<>.,"))

        let resolved = workspaceFileIndex.first(where: { $0.path == candidate })?.path
            ?? workspaceFileIndex.first(where: { $0.path.hasSuffix("/" + candidate) })?.path
            ?? workspaceFileIndex.first(where: { $0.name == candidate })?.path
        guard let path = resolved, !path.split(separator: "/").contains("..") else { return }
        model.openSourceFile(path, in: workspace.id, line: focusLine)
    }

    private func scheduleContinuation() {
        guard let chatSummary else { return }
        let resumeAt = chat.prominentError?.resetsAt
            ?? chat.rateLimit?.resetsAt
            ?? UsageLimitReset.parse(chat.prominentError?.message ?? "")
            ?? Date().addingTimeInterval(60 * 60)
        model.scheduleContinuation(
            workspaceID: workspace.id,
            chatID: chatSummary.id,
            resumeAt: resumeAt
        )
    }

    private func cancelScheduledContinuation() {
        guard let chatSummary else { return }
        model.cancelScheduledContinuation(for: chatSummary.id)
    }

    private func run(_ command: ComposerCommand) {
        switch command.name {
        case "/plan":
            model.setPermissionMode(.plan, for: workspace.id)
            draft = "Create a detailed implementation plan for "
        case "/review": draft = "Review the current workspace diff. Focus on correctness, regressions, and missing tests."
        case "/commit": draft = GitShipPrompt.commit()
        case "/pr": draft = GitShipPrompt.pullRequest(
            base: workspace.baseBranch,
            isStacked: workspace.stackedOn != nil
        )
        case "/test": draft = "Run the relevant test suite, diagnose any failures, and fix them."
        case "/fix": draft = "Diagnose and fix the issue: "
        case "/explain": draft = "Explain this code clearly: "
        case "/model": draft = ""; showModelChooser = true
        case "/clear":
            draft = ""
            discardAttachments(at: IndexSet(chat.draftAttachments.indices))
        default: break
        }
        composerFocused = true
    }
}

private struct ComposerCommand: Identifiable {
    var id: String { name }
    let name: String
    let detail: String
    let icon: String

    static let all = [
        ComposerCommand(name: "/plan", detail: "Plan before editing", icon: "list.bullet.clipboard"),
        ComposerCommand(name: "/review", detail: "Review the workspace diff", icon: "eye"),
        ComposerCommand(name: "/commit", detail: "Commit with a message from the diff", icon: "square.and.arrow.down"),
        ComposerCommand(name: "/pr", detail: "Open a pull request from the diff", icon: "arrow.triangle.pull"),
        ComposerCommand(name: "/test", detail: "Run and fix tests", icon: "checkmark.circle"),
        ComposerCommand(name: "/fix", detail: "Diagnose an issue", icon: "wrench.and.screwdriver"),
        ComposerCommand(name: "/explain", detail: "Explain code", icon: "text.bubble"),
        ComposerCommand(name: "/model", detail: "Choose harness and model", icon: "sparkles"),
        ComposerCommand(name: "/clear", detail: "Clear prompt and files", icon: "xmark.circle"),
    ]
}

/// A stable overlay rather than another transcript row. It makes work obvious
/// at a glance while keeping streamed text from repeatedly inserting/removing
/// loading content and shifting the scroll position.
/// The agent's live status, folded into the top of the composer instead of a
/// pill floating over the transcript. It reads as part of the input box — a
/// quiet row above the text, paired with the composer's animated busy border.
private struct ComposerBusyStatus: View {
    let harness: HarnessKind
    let status: AgentStatus
    var startedAt: Date?
    var isStarting: Bool = false
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
            Text(label)
                .font(.system(size: OreTheme.Font.caption, weight: .medium))
                .foregroundStyle(.secondary)
            if let startedAt {
                // A live counter that ticks each second while the turn runs.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsed(from: startedAt, to: context.date))
                        .font(.system(size: OreTheme.Font.caption, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            Button(action: onStop) {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 8, weight: .bold))
                    Text("Stop")
                        .font(.system(size: OreTheme.Font.caption, weight: .medium))
                }
                .foregroundStyle(.red)
            }
            .buttonStyle(OrePressableButtonStyle())
            .keyboardShortcut(".", modifiers: .command)
            .help("Stop the running turn (⌘.)")
        }
        .padding(.horizontal, 2)
    }

    private var label: String {
        // Booting a one-shot CLI can take several seconds before any event
        // arrives; name that state rather than claiming work is happening.
        if isStarting { return "Starting \(harness.displayName)…" }
        switch status {
        case .runningTool: return "\(harness.displayName) is running a tool"
        case .thinking: return "\(harness.displayName) is thinking"
        default: return "\(harness.displayName) is working"
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}

private struct ResearchEmptyState: View {
    let identity: ResearchIdentity?
    let title: String?
    let seed: String
    let onSuggestion: (String) -> Void

    /// Enriched biography from the local corpus (Wikipedia-backed). Loads
    /// after first render; the hardcoded fact covers the gap and any failure.
    @State private var profile: ScientistCorpus.Profile?
    @State private var portrait: NSImage?

    private struct Starter: Identifiable {
        let title: String
        let detail: String
        let icon: String
        let prompt: String
        var id: String { title }
    }

    private let starters = [
        Starter(
            title: "Understand the project",
            detail: "Get a quick map before changing anything",
            icon: "map",
            prompt: "Give me a concise tour of this project: its architecture, important entry points, and how to run it."
        ),
        Starter(
            title: "Plan the next change",
            detail: "Turn an idea into a small, testable path",
            icon: "list.bullet.clipboard",
            prompt: "Help me turn this idea into a small, testable implementation plan: "
        ),
        Starter(
            title: "Review what changed",
            detail: "Look for regressions and missing tests",
            icon: "eye",
            prompt: "Review the current workspace changes for correctness, regressions, and missing tests."
        ),
        Starter(
            title: "Run the right tests",
            detail: "Find the relevant checks and fix failures",
            icon: "checkmark.circle",
            prompt: "Find and run the tests relevant to this workspace, then diagnose and fix any failures."
        ),
    ]

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(0, geometry.size.width - OreTheme.Space.lg * 2)
            content(
                compact: geometry.size.height < 460,
                singleColumn: availableWidth < 410
            )
                .frame(width: min(700, availableWidth))
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: identity?.slug) {
            profile = nil
            portrait = nil
            guard let identity else { return }
            let loaded = await ScientistCorpus.shared.profile(for: identity)
            guard !Task.isCancelled else { return }
            profile = loaded
            if let loaded, let url = ScientistCorpus.shared.imageURL(for: loaded) {
                portrait = NSImage(contentsOf: url)
            }
        }
    }

    private func content(compact: Bool, singleColumn: Bool) -> some View {
        VStack(spacing: compact ? 8 : 24) {
            VStack(spacing: compact ? 4 : 8) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.pulse, options: .nonRepeating)
                    Text(title ?? "New conversation")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

                Text("What are we working on?")
                    .font(.system(size: compact ? 20 : 22, weight: .semibold, design: .rounded))
                Text("Pick a starting point, or describe the outcome in your own words.")
                    .font(.system(size: compact ? 13 : 14))
                    .foregroundStyle(.secondary)
            }

            // The starters earn one compact row of chips, not four cards —
            // they are the visible answer to the headline's question, and the
            // real call to action is the composer below.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: compact ? 6 : 8) {
                    ForEach(starters) { starter in starterChip(starter, compact: compact) }
                }
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: compact ? 6 : 8
                ) {
                    ForEach(starters) { starter in starterChip(starter, compact: compact) }
                }
            }

            if !compact {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        ForEach(shortcutHints, id: \.label) { hint in
                            ShortcutHint(keys: hint.keys, label: hint.label)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(shortcutHints, id: \.label) { hint in
                            ShortcutHint(keys: hint.keys, label: hint.label)
                        }
                    }
                }
            }

            if let identity {
                inspirationLine(identity: identity, compact: compact)
                    .padding(.top, compact ? 2 : 10)
            }
        }
        .padding(.vertical, compact ? 6 : 44)
    }

    /// The scientist this workspace is named for — a footnote, not a feature.
    ///
    /// This used to be a filled card carrying a portrait, a description line,
    /// four lines of Wikipedia and a "Learn more" link, sitting directly under
    /// the headline. At that weight it competed with the question the page is
    /// actually asking and read like an advertisement for a stranger. The point
    /// was only ever a quiet nod to someone who built something: one portrait,
    /// one sentence about what they did, parked below the shortcuts where it
    /// rewards a glance and costs nothing to ignore.
    private func inspirationLine(identity: ResearchIdentity, compact: Bool) -> some View {
        let side: CGFloat = compact ? 20 : 24
        return HStack(spacing: 8) {
            Group {
                if let portrait {
                    Image(nsImage: portrait)
                        .resizable()
                        .scaledToFill()
                } else {
                    Text(Self.monogram(for: identity.name))
                        .font(.system(size: side * 0.42, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.accentColor.opacity(0.12))
                }
            }
            .frame(width: side, height: side)
            .clipShape(Circle())

            // The catalog's `fact` is the inspiring sentence — what this person
            // actually did. Wikipedia's extract is an encyclopedia entry, which
            // is what made the old card read like a biography stapled to a
            // to-do list.
            (
                Text(identity.name).foregroundStyle(.secondary)
                    + Text("  ") + Text(identity.fact).foregroundStyle(.tertiary)
            )
            .font(.system(size: compact ? 10.5 : 11.5))
            .lineLimit(compact ? 1 : 2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The link survives, but as behaviour rather than furniture: the row
        // itself opens Wikipedia. Nothing here announces itself.
        .contentShape(Rectangle())
        .help(wikipediaURL == nil ? identity.fact : "Read about \(identity.name) on Wikipedia")
        .onTapGesture {
            if let url = wikipediaURL { NSWorkspace.shared.open(url) }
        }
        .onHover { hovering in
            guard wikipediaURL != nil else { return }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var wikipediaURL: URL? {
        guard let page = profile?.pageURL else { return nil }
        return URL(string: page)
    }

    private func starterChip(_ starter: Starter, compact: Bool) -> some View {
        Button { onSuggestion(starter.prompt) } label: {
            HStack(spacing: 6) {
                Image(systemName: starter.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(starter.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: compact ? 24 : 28)
            .background(OreTheme.subduedFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(OrePressableButtonStyle())
        .help(starter.detail)
    }

    private static func monogram(for name: String) -> String {
        let initials = name.split(separator: " ")
            .compactMap(\.first)
            .prefix(2)
        return String(initials)
    }

    private struct Hint {
        let keys: String
        let label: String
    }

    private var shortcutHints: [Hint] {
        let groups: [[Hint]] = [
            [Hint(keys: "⌘P", label: "Open file"), Hint(keys: "@", label: "Reference file"), Hint(keys: "⌘↩", label: "Send")],
            [Hint(keys: "⌘K", label: "Command palette"), Hint(keys: "/", label: "Prompt commands"), Hint(keys: "⌘.", label: "Stop agent")],
            [Hint(keys: "⌘T", label: "New chat"), Hint(keys: "⌘W", label: "Close chat"), Hint(keys: "⇧⌘[ / ]", label: "Switch chats")],
            [Hint(keys: "⌥⌘T", label: "Terminal"), Hint(keys: "⌘1–9", label: "Jump workspace"), Hint(keys: "⌘/", label: "All shortcuts")],
        ]
        let value = seed.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return groups[abs(value) % groups.count]
    }
}

private struct ShortcutHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).stroke(OreTheme.hairline) }
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

/// Voice mode's take on the input area: the transcript rendered exactly where
/// typed text would be, in serif italic between curly quotes, so speech reads
/// as speech until the session ends and it becomes the sent prompt. Any
/// pre-typed draft stays visible in the normal prompt face ahead of the quote.
///
/// While the mic is hot this is a *single line* ending on the newest words.
/// Streaming the whole paragraph in restated what the user had only just said
/// and grew the box under their pointer while they were still talking. The
/// finished prompt then takes over the box for a beat before it sends, which is
/// where reading the whole thing actually matters.
private struct VoiceComposerTranscript: View {
    let prefix: String
    let transcript: String
    let isListening: Bool
    /// The mic has stopped and the turn is waiting out its hold: wrap the whole
    /// prompt instead of clipping to the tail.
    let isSettled: Bool
    /// Wrap cap for the settled prompt, already clamped to the pane's height by
    /// the caller so a short window keeps its toolbar.
    var maxLines: Int = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Widths behind the live line's roll: the words' own, and the composer's.
    @State private var lineWidth: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0

    private var spoken: String {
        isSettled
            ? transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            : VoiceLiveQuote.tail(of: transcript)
    }

    var body: some View {
        content
            // Match the editor's textContainerInset so the words sit exactly
            // where the caret and typed text would.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 5)
            .padding(.vertical, 6)
            // The live line has a fixed height and the settled one is
            // line-capped, so the box takes its height straight from its
            // content. The old growing transcript needed a hidden measuring
            // mirror to avoid a layout cycle that froze dictation; bounded
            // content needs none.
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        if spoken.isEmpty && prefix.isEmpty {
            HStack(spacing: OreTheme.Space.sm) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.blue)
                    .symbolEffect(.pulse, isActive: isListening && !reduceMotion)
                Text(isListening ? "Listening…" : "Starting dictation…")
                    .font(.system(size: 15, design: .serif))
                    .italic()
                    .foregroundStyle(.secondary)
            }
            .frame(height: Self.lineHeight)
        } else if isSettled {
            // The hold is for reading, so the whole prompt wraps. Past the cap
            // — six lines, so only a dictation of a minute or so reaches it —
            // head truncation drops the middle and keeps both the opening and
            // the real ending, which is what you need to confirm what is about
            // to be sent. Tail truncation would hide the ending instead.
            quoted
                .lineLimit(maxLines)
                .truncationMode(.head)
        } else {
            rollingLine
        }
    }

    /// The live line, held against its trailing edge: the quote is laid out at
    /// its full width and slid left by whatever overflows, so short speech sits
    /// exactly where typed text would and a long tail rolls past the leading
    /// edge. Each new word lands off the right edge and the line glides over to
    /// reveal it, which is what makes dictation read as speech going by rather
    /// than a label being retyped in place.
    ///
    /// An offset rather than a scroll view: partials land several times a
    /// second, and an offset is an animatable value that retargets mid-flight,
    /// where a scroll animation restarted that often stutters. It is also inert
    /// in layout — nothing here feeds a measured size back into the frame that
    /// produced it, which is what used to freeze the growing transcript.
    private var rollingLine: some View {
        // The line rides in an *overlay*, which is sized by what it sits on and
        // never the reverse. `fixedSize` makes the text rigid — it reports one
        // width and refuses to compress — so laying it out as a normal child
        // would push that width all the way up and stretch the composer to the
        // length of the sentence.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Self.lineHeight)
            .background { width(into: $visibleWidth) }
            .overlay(alignment: .leading) {
                quoted
                    .lineLimit(1)
                    // Take the line's width from the text, not from whatever
                    // happens to be visible, so it can roll rather than
                    // truncate.
                    .fixedSize()
                    .background { width(into: $lineWidth) }
                    .offset(x: rollOffset)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: rollOffset)
            }
            .mask(rollMask)
    }

    /// Zero until the line outgrows the composer, then however far left it has
    /// to sit for its last word to land on the trailing edge — short of it by a
    /// hair, so the closing quote is never kissed by the clip.
    ///
    /// Written against the overflow rather than as `min(0, visible - line - 3)`:
    /// both widths are zero until the first measurement lands, and that form
    /// reads as a 3pt overflow on the frame before it, nudging a line that fits
    /// and switching the fade on over its opening quote.
    private var rollOffset: CGFloat {
        let overflow = lineWidth - visibleWidth
        return overflow > 0 ? -(overflow + 3) : 0
    }

    /// Words leaving at the leading edge dissolve rather than being guillotined
    /// by the clip. Only once the line is actually rolling: fading a line that
    /// still fits would put a gradient across its opening quote for no reason.
    private var rollMask: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: rollOffset < 0 ? 0.05 : 0),
                .init(color: .black, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Both widths are read off the geometry the parent already imposed and
    /// only ever drive an offset, never a frame — so unlike the measuring
    /// mirror this replaced, there is no size feeding itself.
    private func width(into binding: Binding<CGFloat>) -> some View {
        GeometryReader { geo in
            Color.clear.onChange(of: geo.size.width, initial: true) { _, width in
                binding.wrappedValue = width
            }
        }
    }

    /// One line of the 15pt quote face. Fixed rather than measured: the live
    /// line never wraps, so its height is a constant of the type face.
    private static let lineHeight: CGFloat = 20

    private var quoted: Text {
        let quote = Text(
            spoken.isEmpty ? "\u{201C}…\u{201D}" : "\u{201C}\(spoken)\u{201D}"
        )
        .font(.system(size: 15, design: .serif))
        .italic()
        .foregroundStyle(.primary.opacity(0.85))
        guard !prefix.isEmpty else { return quote }
        return Text(prefix)
            .font(.system(size: OreTheme.Font.prose))
            .foregroundStyle(.primary)
            + Text(" ") + quote
    }
}

/// The words dictation took out of the prompt, and what they set.
///
/// Voice silently deletes part of what you said — "switch this chat to Opus 5"
/// never reaches the agent. Showing the struck-through phrase next to the new
/// value is what makes that legible rather than alarming.
private struct VoiceChangeTrail: View {
    let changes: [VoiceChange]
    var onActivate: (VoiceChange) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: OreTheme.Space.sm) {
            Image(systemName: "waveform")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, isActive: !reduceMotion)

            ForEach(changes) { change in
                Button {
                    onActivate(change)
                } label: {
                    HStack(spacing: 5) {
                        if !change.consumed.isEmpty {
                            Text(change.consumed)
                                .strikethrough(true, color: .secondary.opacity(0.7))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 190, alignment: .leading)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        Label(change.label, systemImage: change.symbol)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                        if change.kind == .model {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.10), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(
                    change.kind == .model ? "Click to switch to \(change.label) now"
                        : change.kind == .file ? "Click to remove \(change.label)"
                        : change.label
                )
                .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: changes)
    }
}

private extension VoiceChange {
    var symbol: String {
        switch kind {
        case .model: "cpu"
        case .effort: "gauge.with.dots.needle.67percent"
        case .mode: "lock.shield"
        case .clipboard: "doc.on.clipboard"
        case .file: "doc.text"
        }
    }
}

private struct ModelChooser: View {
    let currentHarness: HarnessKind
    let currentModel: String?
    let harnesses: [HarnessKind]
    let models: (HarnessKind) -> [AgentModel]
    let onSelect: (HarnessKind, String?) -> Void
    @State private var search = ""
    @State private var hoveredModelKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose model").font(.headline)
            TextField("Search models", text: $search)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(harnesses, id: \.self) { harness in
                        Text(harness.displayName.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                        if search.isEmpty {
                            modelRow(harness, nil)
                        }
                        ForEach(filteredModels(for: harness)) { choice in
                            modelRow(harness, choice)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 410, height: 520)
    }

    private func filteredModels(for harness: HarnessKind) -> [AgentModel] {
        models(harness).filter {
            search.isEmpty
                || $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.id.localizedCaseInsensitiveContains(search)
                || $0.description.localizedCaseInsensitiveContains(search)
        }
    }

    private func modelRow(_ harness: HarnessKind, _ model: AgentModel?) -> some View {
        let key = harness.rawValue + ":" + (model?.id ?? "default")
        return Button { onSelect(harness, model?.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: currentHarness == harness && currentModel == model?.id
                    ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(currentHarness == harness && currentModel == model?.id
                        ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model?.displayName ?? "Default model").fontWeight(.medium)
                    Text(model?.description.isEmpty == false
                        ? model?.description ?? ""
                        : modelDetail(model?.id, harness: harness))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model?.isDefault == true {
                    Text("DEFAULT")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).frame(minHeight: 48)
            .background(
                hoveredModelKey == key ? OreTheme.subduedFill : .clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(OrePressableButtonStyle())
        .onHover { hovering in
            if hovering { hoveredModelKey = key }
            else if hoveredModelKey == key { hoveredModelKey = nil }
        }
    }

    private func modelDetail(_ name: String?, harness: HarnessKind) -> String {
        guard let name else { return "Use the harness default" }
        if name.contains("opus") { return "Deepest Claude reasoning" }
        if name.contains("sonnet") { return "Balanced speed and capability" }
        if name.contains("haiku") { return "Fastest Claude model" }
        if name.contains("codex") { return "Optimized for agentic coding" }
        if harness == .cursorAgent { return "Available through Cursor" }
        return "General-purpose model"
    }
}

private struct EffortChooser: View {
    @Binding var selection: ReasoningEffort
    let efforts: [ReasoningEffort]
    let harness: HarnessKind

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Reasoning effort", systemImage: "chart.bar.fill")
                    .font(.headline)
                Spacer()
                Text(selection.displayName).foregroundStyle(.secondary)
            }
            Slider(value: indexBinding, in: 0...Double(max(0, efforts.count - 1)), step: 1)
            HStack {
                Text("Faster")
                Spacer()
                Text("Deeper")
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(harness == .claudeCode
                ? "Applied through your Claude Code session. Scroll the chip to adjust."
                : "Applied to the next Codex turn. Scroll the chip to adjust.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 300)
    }

    private var indexBinding: Binding<Double> {
        Binding(
            get: { Double(efforts.firstIndex(of: selection) ?? min(2, max(0, efforts.count - 1))) },
            set: {
                guard !efforts.isEmpty else { return }
                selection = efforts[Int($0.rounded()).clamped(to: 0...(efforts.count - 1))]
            }
        )
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

/// How much of the model's context this conversation has used.
private struct ContextMeter: View {
    let used: Int
    let window: Int
    var usage: UsageReport?
    var modelName: String?

    @State private var hovering = false

    private var fraction: Double {
        min(1, Double(used) / Double(window))
    }

    var body: some View {
        HStack(spacing: 5) {
            Text("Context")
                .font(.system(size: OreTheme.Font.caption, weight: .medium))
                .foregroundStyle(.secondary)
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(width: 48)
                .tint(fraction > 0.9 ? .orange : .accentColor)
            Text("\(Int(fraction * 100))%")
                .font(.system(size: OreTheme.Font.caption, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help("\(used.formatted()) of \(window.formatted()) tokens in the current model context")
        .onHover { hovering = $0 }
        .popover(isPresented: $hovering) {
            VStack(alignment: .leading, spacing: 8) {
                if let modelName, !modelName.isEmpty {
                    Text(modelName)
                        .font(.headline)
                }
                tokenRow("Input", usage?.inputTokens ?? used)
                tokenRow("Output", usage?.outputTokens ?? 0)
                if let cache = usage?.cacheReadTokens, cache > 0 {
                    tokenRow("Cache read", cache)
                }
                if let created = usage?.cacheCreationTokens, created > 0 {
                    tokenRow("Cache write", created)
                }
                Divider()
                tokenRow("Context", used)
                Text("of \(window.formatted()) window")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let cost = usage?.costUSD {
                    Text(cost, format: .currency(code: "USD"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(width: 220)
        }
    }

    private func tokenRow(_ title: String, _ value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.formatted())
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

/// A hard failure raised right above the composer so it can't be missed — most
/// often a usage/rate limit the user needs to act on before sending again.
private struct ProminentErrorBanner: View {
    let error: ChatState.ProminentError
    var scheduled: ScheduledContinuation?
    var onContinueWhenAvailable: () -> Void
    var onCancelSchedule: () -> Void
    var onRetry: () -> Void
    let onDismiss: () -> Void

    private var tint: Color { error.isUsageLimit ? OreTheme.warning : .red }
    private var icon: String {
        error.isUsageLimit ? "hourglass.circle.fill" : "exclamationmark.triangle.fill"
    }
    private var title: String {
        error.isUsageLimit ? "Usage limit reached" : "The agent hit an error"
    }
    private var resetDate: Date? { scheduled?.resumeAt ?? error.resetsAt }

    var body: some View {
        HStack(alignment: .top, spacing: OreTheme.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: OreTheme.Font.body, weight: .semibold))
                Text(.init(error.message))
                    .font(.system(size: OreTheme.Font.caption))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if error.isUsageLimit {
                    if let scheduled {
                        scheduledActions(scheduled)
                    } else {
                        continueButton
                    }
                } else {
                    Button(action: onRetry) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.system(size: OreTheme.Font.caption, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(tint.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Send the last prompt again")
                }
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: OreTheme.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: OreTheme.controlRadius)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        }
    }

    private var continueButton: some View {
        Button(action: onContinueWhenAvailable) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                Text(continueButtonTitle)
            }
            .font(.system(size: OreTheme.Font.caption, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Automatically continue this chat when the session limit resets")
    }

    private var continueButtonTitle: String {
        if let resetDate {
            return "Continue when it resets · \(UsageLimitReset.format(resetDate))"
        }
        return "Continue when it resets"
    }

    private func scheduledActions(_ scheduled: ScheduledContinuation) -> some View {
        HStack(spacing: 8) {
            Label(
                "Will continue at \(UsageLimitReset.format(scheduled.resumeAt))",
                systemImage: "checkmark.circle.fill"
            )
            .font(.system(size: OreTheme.Font.caption, weight: .medium))
            .foregroundStyle(.secondary)
            Button("Cancel", action: onCancelSchedule)
                .font(.system(size: OreTheme.Font.caption, weight: .semibold))
                .buttonStyle(.plain)
        }
    }
}

private struct ScheduledContinuationBanner: View {
    let item: ScheduledContinuation
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: OreTheme.Space.sm) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OreTheme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Continuing when the limit resets")
                    .font(.system(size: OreTheme.Font.body, weight: .semibold))
                Text(UsageLimitReset.format(item.resumeAt))
                    .font(.system(size: OreTheme.Font.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: onCancel)
                .font(.system(size: OreTheme.Font.caption, weight: .semibold))
                .buttonStyle(.plain)
        }
        .padding(12)
        .background(OreTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: OreTheme.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: OreTheme.controlRadius)
                .stroke(OreTheme.warning.opacity(0.35), lineWidth: 1)
        }
    }
}

/// A standalone rate-limit warning when the turn itself didn't fail, so the
/// composer still shows when the window resets and offers Retry.
private struct RateLimitBanner: View {
    let report: RateLimitReport
    var onRetry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: OreTheme.Space.sm) {
            Image(systemName: report.status == .exhausted
                ? "hourglass.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(OreTheme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.status == .exhausted ? "Rate limit reached" : "Approaching rate limit")
                    .font(.system(size: OreTheme.Font.body, weight: .semibold))
                if let reset = report.resetsAt {
                    Text(UsageLimitReset.format(reset))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let window = report.window {
                    Text(window)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button(action: onRetry) {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.system(size: OreTheme.Font.caption, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(OreTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: OreTheme.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: OreTheme.controlRadius)
                .stroke(OreTheme.warning.opacity(0.35), lineWidth: 1)
        }
    }
}

/// A tool call the agent is blocked on.
private struct PermissionCard: View {
    let request: PermissionRequest
    let onDecision: (PermissionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.sm) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text(request.displayName ?? request.toolName).fontWeight(.semibold)
                Spacer()
            }

            if let summary = request.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }

            HStack(spacing: 8) {
                Button("Allow") { onDecision(.allow) }
                    .buttonStyle(OrePrimaryButtonStyle())
                    .keyboardShortcut("a", modifiers: [.command, .shift])

                Button("Deny") {
                    onDecision(.deny(reason: "The user denied this in ORE."))
                }
                .buttonStyle(OreSecondaryButtonStyle())
                .keyboardShortcut("d", modifiers: [.command, .shift])

                // Harness-suggested shortcuts, kept as raw payloads so what we
                // send back is exactly what was offered.
                ForEach(Array(request.suggestions.enumerated()), id: \.offset) { _, suggestion in
                    Button(suggestion.title) { onDecision(.allowWithSuggestion(suggestion.raw)) }
                        .buttonStyle(.link)
                }

                Spacer()
            }
        }
        .oreCard(padding: 12)
    }
}

private struct PlanApprovalCard: View {
    let markdown: String
    let onApprove: (String) -> Void
    let onReject: (String) -> Void
    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.sm) {
            Label("Plan ready for review", systemImage: "checklist")
                .fontWeight(.semibold)
            Text(markdown).lineLimit(8).textSelection(.enabled)
            TextField("Optional feedback…", text: $feedback)
            HStack {
                Button("Approve") { onApprove("") }.buttonStyle(OrePrimaryButtonStyle())
                Button("Approve with Feedback") { onApprove(feedback) }
                    .disabled(feedback.isEmpty)
                    .buttonStyle(OreSecondaryButtonStyle())
                Button("Reject / Revise") { onReject(feedback) }
                    .buttonStyle(OreSecondaryButtonStyle())
                Spacer()
            }
        }
        .oreCard(padding: 12)
    }
}

private struct MessageQueueCard: View {
    @Binding var messages: [QueuedMessageRecord]
    let onSave: (Int64, String) async -> Void
    let onDelete: (Int64) async -> Void

    var body: some View {
        DisclosureGroup("Queued messages (\(messages.count))") {
            VStack(spacing: 6) {
                ForEach(messages.indices, id: \.self) { index in
                    HStack {
                        TextField("Queued message", text: $messages[index].text)
                            .onSubmit {
                                guard let id = messages[index].id else { return }
                                Task { await onSave(id, messages[index].text) }
                            }
                        Button(role: .destructive) {
                            guard let id = messages[index].id else { return }
                            Task { await onDelete(id) }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 6)
        }
        .oreCard(padding: 12, radius: 14)
    }
}

/// The agent asking the user something directly.
private struct QuestionCard: View {
    let question: AgentQuestion
    let harness: HarnessKind
    let onAnswer: (String) -> Void
    @State private var freeform = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                HarnessMark(harness: harness, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Agent needs your input")
                        .font(.system(size: OreTheme.Font.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(question.prompt)
                        .font(.system(size: OreTheme.Font.title, weight: .semibold))
                }
                Spacer(minLength: 0)
            }

            if !question.options.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        Button { onAnswer(option.label) } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 22, height: 22)
                                    .background(Color.accentColor.opacity(0.10), in: Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .font(.system(size: OreTheme.Font.body, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    if let detail = option.detail, !detail.isEmpty {
                                        Text(detail)
                                            .font(.system(size: OreTheme.Font.caption))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(OreTheme.subduedFill, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(OrePressableButtonStyle())
                        .help(option.detail ?? "")
                    }
                }
            }

            if question.allowsFreeform {
                HStack(spacing: 8) {
                    TextField("Or answer in your own words…", text: $freeform)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(OreTheme.subduedFill, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(OreTheme.hairline))
                        .onSubmit { submit() }
                    Button(action: submit) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .disabled(freeform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .oreComposerSurface(padding: 12)
    }

    private func submit() {
        let answer = freeform.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        onAnswer(answer)
        freeform = ""
    }
}

private struct ComposerModeTag: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(tint.opacity(0.09), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.18), lineWidth: 1))
            .accessibilityLabel("\(title) mode")
    }
}

/// A small accent dot that breathes while an agent works, so a background tab
/// reads as "running" even after the sheen is dimmed by the tab's reduced
/// opacity.
private struct BusyTabDot: View {
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .opacity(reduceMotion ? 1 : (pulse ? 0.3 : 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

/// Comments left on the diff, waiting to go out with the next message.
private struct DraftCommentsBar: View {
    let comments: [DiffCommentReference]
    let onRemove: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(comments.enumerated()), id: \.offset) { index, comment in
                    HStack(spacing: 4) {
                        Text("\((comment.filePath as NSString).lastPathComponent):\(comment.startLine)")
                            .font(.caption2.monospaced())
                        Button {
                            onRemove(index)
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(OreTheme.subduedFill, in: Capsule())
                    .help(comment.body)
                }
            }
            .padding(.horizontal, OreTheme.Space.md)
        }
        .frame(height: 28)
    }
}
