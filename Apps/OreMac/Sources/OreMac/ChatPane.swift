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
    /// Reported by the editor's layout manager, including its container inset,
    /// so it is the composer's height directly rather than a text height that
    /// needs padding added. Seeded at the one-line floor.
    @State private var composerTextHeight: CGFloat = 38
    @State private var queuedMessages: [QueuedMessageRecord] = []
    /// Suggestion ids the user waved away this session; a dismissed nudge must
    /// not reappear the moment conditions re-match. Dies with the pane.
    @State private var dismissedSuggestions: Set<String> = []
    /// The find bar (⌘F). The field's live text lives *inside* the bar (see
    /// `TranscriptSearchBar`); the pane only holds the debounced query the
    /// transcript actually searches, so typing never re-evaluates this body.
    /// The token bumps on every ⌘F so an already-open bar refocuses its field
    /// instead of toggling away.
    @State private var isSearching = false
    @State private var effectiveSearchQuery = ""
    @State private var searchFocusRequest = 0
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
    @State private var renameChatTarget: ChatSummary?
    @State private var renameChatText = ""
    @State private var workspaceFileIndex: [WorkspaceFileNode] = []
    /// Owns the transcript's "jump to latest" affordance. Held here rather than
    /// in `TranscriptHost` so its identity survives every body pass.
    @State private var scrollAnchor = TranscriptScrollAnchor()
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
    /// The floating dock's measured height, fed into the transcript's bottom
    /// content inset so rows can scroll clear of the glass above them.
    @State private var dockHeight: CGFloat = 0
    private var hotkey: VoiceHotkeyMonitor { .shared }

    /// Fresh lookups, for event handlers. Each access filters and sorts every
    /// chat summary, so render paths resolve both once in `chatBody` and take
    /// them as parameters (named the same, shadowing these) instead.
    private var chat: ChatState { model.chat(for: workspace.id) }
    private var chatSummary: ChatSummary? { model.activeChat(for: workspace.id) }

    /// The split partner, validated against the live tab list — a chat closed
    /// out from under the split must fold the column, not strand it.
    private var resolvedSplitChatID: ChatID? {
        guard let id = model.splitChat[workspace.id] else { return nil }
        guard model.chats(for: workspace.id).contains(where: { $0.id == id }) else { return nil }
        return id
    }

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
            // The tab strip floats *over* the conversation — Apple's content-
            // under-chrome: the transcript extends to the window's top edge and
            // rows slide beneath the tab pills, held apart at rest by the
            // scroll view's head inset. Documents and the split column keep
            // their own headers, so they are simply laid out below the strip.
            ZStack(alignment: .top) {
                // The presence roster ("Claude is working · Cursor is idle")
                // lives in the bottom dock bar now — see `bottomDock`.

                // The centre column shows either a chat transcript or — when a file
                // tab is active — that file's diff, opened from the review list.
                // With a split open it shares the width evenly with a second,
                // lighter conversation column — the reference design's
                // side-by-side chats.
                HStack(spacing: 0) {
                    Group {
                        if let filePath = model.activeFilePath[workspace.id] {
                            DiffDocumentView(workspace: workspace, path: filePath)
                                .padding(.top, OreTheme.RowHeight.bar)
                        } else {
                            // Own view identity so transcript/composer observation
                            // (ChatState, live git, voice) does not rebuild the tab bar.
                            ChatConversationColumn {
                                chatBody(paneHeight: geometry.size.height)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    if let splitID = resolvedSplitChatID {
                        // The reference design's seam: a live accent line, not a
                        // hairline — the one place a divider is the point.
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.55))
                            .frame(width: 2)
                        SplitChatColumn(workspace: workspace, chatID: splitID)
                            .padding(.top, OreTheme.RowHeight.bar)
                            .frame(maxWidth: .infinity)
                            .id(splitID)
                    }
                }

                ChatTabBar(
                    workspace: workspace,
                    availableWidth: geometry.size.width,
                    revertTarget: $revertTarget,
                    renameChatTarget: $renameChatTarget,
                    renameChatText: $renameChatText,
                    isSearching: $isSearching,
                    searchFocusRequest: $searchFocusRequest
                )
                // No scrim. A full-width gradient here ended in hard
                // rectangular edges — the "square shadow" against the
                // inspector's seam. Legibility over scrolled rows is the tabs'
                // own job now: every pill carries its own glass backdrop (see
                // `OreNavigationSelection`), which is also how the system's
                // floating tab groups solve this.
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No opaque fill. The transcript scrolls directly over the window's
        // glass base (`OreWindowGlassBase`), which is what lets the tab strip's
        // bar material, the floating composer, and the HUD refract wallpaper
        // light instead of flat white — prose stays legible for the same
        // reason sidebar labels do: the base material is the system's own.
        // Workspace identity lives in the window's title bar now, not a 58pt
        // header that repeated the tab title. The toolbar band was empty anyway.
        .navigationTitle(workspace.name)
        .navigationSubtitle("\(workspace.branch) → \(workspace.baseBranch)")
    }

    private struct ComposerSuggestion {
        enum Action {
            /// Send this prompt to the current chat.
            case send(String)
            /// Ask this tab's agent to commit (`AppModel.commitWithAgent`).
            case commitAgent
            /// Close this tab — offered on a finished commit tab.
            case closeTab
        }

        let id: String
        let title: String
        let icon: String
        let action: Action
    }

    /// The one nudge worth showing right now, or nothing. Only when it's
    /// genuinely quiet — agent idle, nothing pending, no draft in progress —
    /// and ordered as a priority ladder over live signals: a finished commit
    /// tab offers to close itself, a failure offers a diagnosis, a stale base
    /// offers a sync, uncommitted work offers the commit clerk, a diff offers
    /// a summary, and only then the generic recap.
    private func composerSuggestion(chat: ChatState, chatSummary: ChatSummary?) -> ComposerSuggestion? {
        guard chat.hasRows, !chat.isBusy else { return nil }
        guard chat.pendingPermission == nil, chat.pendingQuestion == nil,
              chat.prominentError == nil, chat.draftComments.isEmpty,
              queuedMessages.isEmpty else { return nil }
        if case .proposal = chat.plan { return nil }
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let git = model.gitChrome(for: workspace.id)
        let title = chatSummary?.title ?? ""
        let isCommitTab = title.hasPrefix("Commit")
        let isShipTab = title.hasPrefix("Ship")
        // A temporary git tab is done when its job is: a commit tab once the
        // tree is clean, a ship tab once everything is also pushed.
        let tempTabDone = (isCommitTab && !git.hasUncommittedChanges)
            || (isShipTab && !git.hasUncommittedChanges && git.aheadOfBase == 0)

        let ladder: [ComposerSuggestion?] = [
            tempTabDone
                ? ComposerSuggestion(
                    id: "close-commit-tab",
                    title: isShipTab
                        ? "Shipped — close this tab"
                        : "All committed — close this tab",
                    icon: "checkmark.circle",
                    action: .closeTab
                ) : nil,
            chatSummary?.status == .failed
                ? ComposerSuggestion(
                    id: "diagnose-failure",
                    title: "Diagnose what went wrong",
                    icon: "stethoscope",
                    action: .send(
                        "The last turn failed. Diagnose what went wrong and fix it."
                    )
                ) : nil,
            git.behindBase > 0
                ? ComposerSuggestion(
                    id: "sync-base",
                    title: "Sync with \(workspace.baseBranch)",
                    icon: "arrow.triangle.merge",
                    action: .send(
                        "This branch is behind \(workspace.baseBranch). Rebase or merge "
                            + "the latest \(workspace.baseBranch) and resolve any conflicts."
                    )
                ) : nil,
            // Only when the git action bar isn't already offering Commit —
            // two commit affordances stacked on one screen say the same
            // thing twice.
            git.hasUncommittedChanges && !isCommitTab && !isShipTab && !gitBarOffersCommit
                ? ComposerSuggestion(
                    id: "commit-changes",
                    title: "Commit these changes",
                    icon: "tray.and.arrow.down",
                    action: .commitAgent
                ) : nil,
            git.changedFileCount > 0
                ? ComposerSuggestion(
                    id: "summarize-changes",
                    title: "Give me a summary of the changes",
                    icon: "doc.text.magnifyingglass",
                    action: .send(
                        "Give me a concise summary of the changes in this workspace so far: "
                            + "what changed, why, and anything still unfinished."
                    )
                ) : nil,
            ComposerSuggestion(
                id: "recap-session",
                title: "Recap this conversation",
                icon: "text.bubble",
                action: .send(
                    "Recap this conversation so far: what we set out to do, "
                        + "what's done, and what a sensible next step would be."
                )
            ),
        ]
        return ladder
            .compactMap { $0 }
            .first { !dismissedSuggestions.contains($0.id) }
    }

    private var gitBarOffersCommit: Bool {
        if case .commit = model.gitAction(for: workspace.id) { return true }
        return false
    }

    /// A ready plan is its own response surface. Keeping the ordinary composer
    /// beneath it produces two competing places to type and, under vertical
    /// compression, lets the transcript squeeze the plan body to zero height.
    private func isReviewingPlan(_ chat: ChatState) -> Bool {
        if case .proposal = chat.plan { return true }
        return false
    }

    private func closeSearch() {
        isSearching = false
        // An empty query clears the coordinator's matches and the highlight.
        effectiveSearchQuery = ""
        // The answers chat is scoped to the bar: closing one closes the other.
        if let answers = model.answersChat(in: workspace.id) {
            model.closeChat(answers.id, in: workspace.id)
        }
    }

    private func performSuggestion(_ suggestion: ComposerSuggestion) {
        switch suggestion.action {
        case .send(let prompt):
            model.send(prompt, to: workspace.id)
        case .commitAgent:
            model.commitWithAgent(in: workspace.id)
        case .closeTab:
            guard let id = chatSummary?.id else { return }
            model.closeChat(id, in: workspace.id)
        }
    }

    /// Reloads the queued-message strip when the tab changes or its queue does.
    private func queuedMessagesTaskID(_ chatSummary: ChatSummary?) -> String {
        let id = chatSummary?.id.rawValue ?? ""
        let count = chatSummary?.queuedMessageCount ?? 0
        return "\(id)-\(count)"
    }

    private func handleTurnAction(_ turn: TurnID, _ action: TranscriptView.TurnAction) {
        switch action {
        case .fork:
            model.forkChat(into: workspace.id)
        case .handoffPlan:
            let plan = chat.rows.last { $0.turnID == turn && $0.kind == .plan }
            if let markdown = plan?.text {
                model.handoffPlan(markdown, in: workspace.id)
            }
        case .revert:
            revertTarget = turn
        }
    }

    /// Bottom-trailing, in the band the turn rail deliberately leaves clear (it
    /// stops 50pt short of the foot), so the button sits on neither the rail nor
    /// the centred prose.
    @ViewBuilder
    private var jumpToLatestOverlay: some View {
        let away = scrollAnchor.isAwayFromBottom
        ZStack {
            if away {
                JumpToLatestButton { scrollAnchor.jumpToBottom() }
                    .transition(
                        reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity)
                    )
            }
        }
        .padding(.trailing, OreTheme.Space.md)
        .padding(.bottom, OreTheme.Space.sm)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.8), value: away)
    }

    /// The transcript itself, or the empty state before a chat has any rows.
    ///
    /// Split out of `chatBody` because that one expression had grown past what
    /// the type checker will solve in reasonable time.
    @ViewBuilder
    private func transcriptViewport(chat: ChatState, chatSummary: ChatSummary?) -> some View {
        ZStack(alignment: .bottomLeading) {
            if !chat.hasRows && !chat.isBusy {
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
                // Centered in the part of the pane the floating dock leaves
                // uncovered, so its suggestion chips never hide behind glass.
                .padding(.bottom, dockHeight)
            } else {
                TranscriptHost(
                    chat: chat,
                    worktreePath: workspace.worktreePath,
                    agentName: chatSummary.map { AgentPresenceStrip.shortName($0.harness) } ?? "",
                    searchQuery: isSearching ? effectiveSearchQuery : "",
                    persistenceKey: transcriptScrollKey(chatSummary),
                    expandedActivityGroups: expandedActivityGroups,
                    canFork: chatSummary?.capabilities.supportsSessionFork ?? false,
                    onRevert: { revertTarget = $0 },
                    onToggleActivity: { toggleActivity($0) },
                    onOpenFile: { openAgentFile($0) },
                    onTurnAction: { turn, action in handleTurnAction(turn, action) },
                    scrollAnchor: scrollAnchor,
                    // A hair of air between the newest row and the dock's glass.
                    bottomInset: dockHeight + OreTheme.Space.sm,
                    // …and head room under the floating tab strip, so the top
                    // row rests below the pills while scrolled rows slide
                    // underneath them.
                    topInset: OreTheme.RowHeight.bar + OreTheme.Space.sm
                )
                .equatable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The scroll-edge treatment, done on the content instead of
                // the chrome: rows dissolve as they slide up toward the tab
                // pills. A mask is clipped to this pane by construction, so —
                // unlike the scrim rectangle it replaces — it cannot print an
                // edge against the inspector, and full-contrast text can never
                // sit level with the pills or the window title.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [.clear, .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: OreTheme.RowHeight.bar + OreTheme.Space.sm)
                        Color.black
                        // The dock is translucent by design, but transcript
                        // prose must not remain readable through an alert or
                        // the composer while the reader scrolls. The resting
                        // bottom inset already keeps the newest row above this
                        // boundary; this fade handles rows moving underneath
                        // it, preserving the wallpaper refraction without
                        // mixing two layers of text.
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: dockHeight + OreTheme.Space.sm)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // Riding above the floating dock, not behind it.
                    jumpToLatestOverlay.padding(.bottom, dockHeight)
                }
            }
            // The "agent is working" state now lives on the composer itself
            // (an animated border plus an inline status row), so there is no
            // longer a separate floating pill hovering over the transcript.
        }
    }

    private func transcriptScrollKey(_ chatSummary: ChatSummary?) -> String {
        "ore.chatScroll.\(chatSummary?.id.rawValue ?? workspace.id.rawValue)"
    }

    @ViewBuilder
    private func chatBody(paneHeight: CGFloat) -> some View {
        // Resolved once per pass and handed down. As computed properties these
        // were re-resolved at every one of the body's ~100 reads, each one a
        // filter and sort over every chat in the app.
        let chatSummary = model.activeChat(for: workspace.id)
        let chat = chatSummary.map { model.chat(for: $0.id) } ?? ChatState()
        let reviewingPlan = isReviewingPlan(chat)
        let nudge = composerSuggestion(chat: chat, chatSummary: chatSummary)
        // The transcript fills the column and the dock *floats over its foot*
        // on glass — rows scroll underneath the composer, which is what gives
        // Liquid Glass something to refract. Stacking the composer below the
        // transcript put its glass over a flat fill, where it read as matte.
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
            if isSearching {
                TranscriptSearchBar(
                    anchor: scrollAnchor,
                    focusRequest: searchFocusRequest,
                    onQueryChange: { effectiveSearchQuery = $0 },
                    onAskTabs: { model.askAcrossTabs($0, in: workspace.id) },
                    onClose: closeSearch
                )
                // Below the floating tab strip, not underneath it.
                .padding(.top, OreTheme.RowHeight.bar)
                // The reply streams right here — no tab appears, focus never
                // moves. The chat behind it is ephemeral and dies with the bar.
                if let answers = model.answersChat(in: workspace.id) {
                    CrossTabAnswerPanel(
                        state: model.chat(for: answers.id),
                        onAnswer: { answer in
                            guard let question = model.chat(for: answers.id).pendingQuestion
                            else { return }
                            model.answerQuestion(
                                question.id, answer: answer,
                                for: workspace.id, chatID: answers.id
                            )
                        }
                    )
                }
            }
            transcriptViewport(chat: chat, chatSummary: chatSummary)
                // Transition snapshots of an infinitely-sized empty view could
                // paint over sibling split-view columns while changing tabs. The
                // transcript viewport owns and clips all of its content now.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .clipped()
            }

            // The dock: everything that talks to the user right now, floating
            // over the transcript. Its measured height drives the scroll's
            // bottom inset, so the newest row always rests just above the
            // glass rather than hiding behind it.
            VStack(spacing: 0) {
            // Anything blocking the agent sits directly above the composer,
            // where the user is already looking. AskUserQuestion and
            // ExitPlanMode are both a permission gate *and* a dedicated card;
            // showing the generic Allow/Deny alongside that card is two
            // prompts for the same decision. The dedicated card owns it, and
            // answering there also allows (or denies) this permission.
            if let permission = chat.pendingPermission,
               !hidesGenericPermission(permission, in: chat) {
                PermissionCard(request: permission) { decision in
                    model.resolvePermission(permission.id, decision: decision, for: workspace.id)
                }
                .frame(maxWidth: OreTheme.contentMaxWidth)
                .padding(.horizontal, OreTheme.Space.md)
                .padding(.top, OreTheme.Space.sm)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if case .proposal(let markdown, let requestID) = chat.plan,
               let planChatID = chatSummary?.id {
                PlanApprovalCard(
                    markdown: markdown,
                    comments: chat.draftComments,
                    paneHeight: paneHeight,
                    commentOrigin: model.isReviewCommentInbox(planChatID, in: workspace.id)
                        ? "Review"
                        : nil,
                    onRemoveComment: { index in
                        model.removeDraftComment(at: index, from: planChatID, in: workspace.id)
                    },
                    onClearComments: {
                        model.clearDraftComments(from: planChatID, in: workspace.id)
                    },
                    onHandoff: {
                        model.handoffPlan(markdown, in: workspace.id)
                    },
                    onApprove: { feedback in
                        model.respondToPlan(
                            chatID: planChatID, workspaceID: workspace.id,
                            approve: true, feedback: feedback
                        )
                    },
                    onReject: { feedback in
                        model.respondToPlan(
                            chatID: planChatID, workspaceID: workspace.id,
                            approve: false, feedback: feedback
                        )
                    }
                )
                .frame(maxWidth: OreTheme.contentMaxWidth)
                .padding(.horizontal, OreTheme.Space.md)
                .padding(.top, OreTheme.Space.sm)
                // The decision surface must win vertical compression over the
                // transcript; approving a plan the user cannot see is unsafe.
                .layoutPriority(2)
                // A new proposal must reset the card's own feedback field;
                // without an identity SwiftUI reuses the previous card's state.
                .id(requestID?.rawValue ?? markdown)
            }

            if !queuedMessages.isEmpty {
                MessageQueueCard(messages: $queuedMessages) { record, text in
                    await model.updateQueuedMessage(record, text: text)
                } onDelete: { record in
                    await model.deleteQueuedMessage(record)
                    queuedMessages.removeAll { $0.id == record.id }
                }
                .frame(maxWidth: OreTheme.contentMaxWidth)
                .padding(.horizontal, OreTheme.Space.md)
            }

            if !chat.draftComments.isEmpty && !reviewingPlan {
                DraftCommentsBar(
                    comments: chat.draftComments,
                    origin: chatSummary.flatMap {
                        model.isReviewCommentInbox($0.id, in: workspace.id) ? "Review" : nil
                    },
                    onRemove: { index in
                        guard let chatID = chatSummary?.id else { return }
                        model.removeDraftComment(at: index, from: chatID, in: workspace.id)
                    },
                    onClearAll: {
                        guard let chatID = chatSummary?.id else { return }
                        model.clearDraftComments(from: chatID, in: workspace.id)
                    }
                )
            }

            // The reference design's floating nudge: one contextual next step
            // hovering above the composer when the agent is idle and nothing
            // else is asking for the user's attention.
            if let suggestion = nudge {
                ComposerSuggestionChip(
                    text: suggestion.title,
                    icon: suggestion.icon,
                    onSend: { performSuggestion(suggestion) },
                    onDismiss: { dismissedSuggestions.insert(suggestion.id) }
                )
                .frame(maxWidth: .infinity)
                .padding(.top, OreTheme.Space.sm)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                // Identity per suggestion: a new nudge animates in rather than
                // morphing the old one's label in place.
                .id(suggestion.id)
            }

            // Hard failures — usage limits especially — belong where the user
            // is about to act, not buried as a red row up in the transcript.
            if let error = chat.prominentError {
                composerErrorBanner(error, chat: chat, chatSummary: chatSummary)
            } else if let scheduled = model.scheduledContinuation(for: chatSummary?.id) {
                ScheduledContinuationBanner(item: scheduled, onCancel: cancelScheduledContinuation)
                    .frame(maxWidth: OreTheme.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, OreTheme.Space.md)
                    .padding(.top, OreTheme.Space.sm)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            // `applies()` again, not just `chat.rateLimit != nil`: the state's
            // expiry timer is the thing that redraws this, but a report that
            // went stale while the view was off screen shouldn't flash back.
            } else if let limit = chat.rateLimit, limit.applies() {
                composerRateLimitBanner(limit)
            }

            if let question = chat.pendingQuestion {
                QuestionCard(
                    question: question,
                    harness: chatSummary?.harness ?? workspace.harness
                ) { answer in
                    // `answerQuestion` decides whether this one has to travel
                    // back through a permission reply — the same routing every
                    // other answer surface gets.
                    model.answerQuestion(
                        question.id, answer: answer,
                        for: workspace.id, chatID: chatSummary?.id
                    )
                }
                .frame(maxWidth: OreTheme.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, OreTheme.Space.md)
                .padding(.vertical, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !reviewingPlan {
                composer(paneHeight: paneHeight, chat: chat, chatSummary: chatSummary)
            }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ComposerDockHeightKey.self,
                        value: proxy.size.height
                    )
                }
            )
            // The dock's cards declare transitions, but nothing *drove* them:
            // with no animation bound to these state changes, a suggestion
            // chip vanished in a single frame, the measured dock height
            // snapped, and the transcript's inset — pinned to it — jumped with
            // a visible jerk. Animating the dock lets the height glide, and
            // the scroll inset follows it frame by frame.
            .animation(.easeOut(duration: 0.18), value: nudge?.id)
            .animation(.easeOut(duration: 0.18), value: chat.pendingQuestion?.id)
            .animation(.easeOut(duration: 0.18), value: chat.draftComments.isEmpty)
        }
        .onPreferenceChange(ComposerDockHeightKey.self) { dockHeight = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .task(id: chatSummary?.id) {
            dismissedSuggestions = []
            draftOwnerID = chatSummary?.id
            if let injection = model.composerInjection, injection.chatID == chatSummary?.id {
                draft = injection.text
                composerFocused = true
                model.consumeComposerInjection(injection.generation)
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
            model.consumeComposerInjection(injection.generation)
        }
        .task(id: queuedMessagesTaskID(chatSummary)) {
            guard let id = chatSummary?.id else { queuedMessages = []; return }
            queuedMessages = await model.queuedMessages(for: id)
        }
        .onChange(of: draft) { _, value in
            // The guard keeps a tab switch from writing the previous tab's text
            // into the newly selected chat before its draft has loaded.
            guard let chatSummary, draftOwnerID == chatSummary.id else { return }
            // The common case is a draft with no attachments at all, which the
            // scan below would still walk on every keystroke.
            guard !chat.draftAttachments.isEmpty else {
                model.setDraft(value, for: chatSummary)
                return
            }
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
        .onChange(of: voice.isActive) { _, active in
            // Dictation owns the audio: narration stops for the mic's whole
            // lifetime so the user isn't talked over and TTS can't leak into
            // the transcription.
            model.narration.setMicActive(active)
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
            // should answer the global chord — and only for its own target:
            // assistant-bound holds are handled app-wide, not here.
            guard let command, command.target == .composer,
                  model.selectedWorkspaceID == workspace.id else { return }
            switch command.kind {
            case .toggle: toggleVoice()
            case .start: if !voice.isActive { startVoice() }
            case .stop: finishVoice(.send)
            // Cancel is only ever published for the assistant, so this is
            // unreachable today; parking the draft is the safe reading of
            // "stop" if it ever isn't.
            case .arm, .disarm, .commit, .cancel: finishVoice(.commitToDraft)
            }
        }
        .onDisappear {
            finishVoice(.commitToDraft)
            // Covers the workspace switch, which tears this pane down without
            // going through `selectChat`.
            //
            // The explicit `setDraft` is not redundant: `onChange(of: draft)` is
            // what normally records the text, and it cannot fire on a view that
            // is going away — so a prompt `finishVoice` just committed would be
            // lost without this.
            // A fresh lookup, not this pass's snapshot: the pane can be torn
            // down in the same update that changed the active chat.
            if let chatSummary = self.chatSummary, draftOwnerID == chatSummary.id {
                model.setDraft(draft, for: chatSummary)
            }
            model.flushPendingDrafts()
            // The pane is gone before `voice.isActive`'s onChange can fire;
            // without this a dying mic would leave narration muted forever.
            model.narration.setMicActive(false)
        }
        .onExitCommand {
            finishVoice(.cancel)
        }
        .task(id: chatSummary?.id) {
            let key = "ore.reasoningEffort.\(chatSummary?.id.rawValue ?? workspace.id.rawValue)"
            if let stored = chatSummary?.reasoningEffort {
                reasoningEffort = stored
            } else if let raw = UserDefaults.standard.string(forKey: key),
               let effort = ReasoningEffort(rawValue: raw) { reasoningEffort = effort }
            if let tab = chatSummary { clampEffort(to: tab) }
            let fastKey = "ore.fastMode.\(chatSummary?.id.rawValue ?? workspace.id.rawValue)"
            fastModeEnabled = UserDefaults.standard.bool(forKey: fastKey)
        }
        .onChange(of: reasoningEffort) { _, effort in
            persistEffort(effort)
        }
        .task(id: chatSummary?.reasoningEffort) {
            if let effort = chatSummary?.reasoningEffort, effort != reasoningEffort {
                reasoningEffort = effort
            }
            // Commands can also come from voice, MCP, or the assistant. Treat
            // their value as a request and normalize it against the current
            // model just like a direct picker change.
            if let tab = chatSummary { clampEffort(to: tab) }
        }
        // Model catalogs can refresh after the pane appears, and model changes
        // can arrive from the assistant/MCP rather than this view's picker.
        // Reconcile either case automatically so an effort from the previous
        // model never remains selected for a different capability set.
        .task(id: effortCapabilityKey(chatSummary)) {
            if let tab = chatSummary { clampEffort(to: tab) }
        }
        .onChange(of: fastModeEnabled) { _, enabled in
            let key = "ore.fastMode.\(chatSummary?.id.rawValue ?? workspace.id.rawValue)"
            UserDefaults.standard.set(enabled, forKey: key)
        }
        .task(id: workspace.id) {
            workspaceFileIndex = Self.flattenFiles(await model.workspaceFiles(for: workspace))
            voiceFileMatcher = makeVoiceFileMatcher()
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

    private func toggleActivity(_ id: String) {
        if expandedActivityGroups.contains(id) { expandedActivityGroups.remove(id) }
        else { expandedActivityGroups.insert(id) }
    }

    /// Tab chrome is its own view so streaming `rowsRevision` cannot rebuild
    /// the close buttons. Clicks on those used to sit behind 40 Hz transcript
    /// invalidations.
    private struct ChatConversationColumn<Content: View>: View {
        var content: () -> Content
        var body: some View { content() }
    }

    private struct ChatTabBar: View {
        @Environment(AppModel.self) private var model
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let workspace: WorkspaceSummary
        let availableWidth: CGFloat
        @Binding var revertTarget: TurnID?
        @Binding var renameChatTarget: ChatSummary?
        @Binding var renameChatText: String
        @Binding var isSearching: Bool
        @Binding var searchFocusRequest: Int
        @State private var hoveredTabKey: String?

        var body: some View {
        // Resolved once per pass. Each label used to re-filter and re-sort the
        // tab list for its own crowding and close-button checks — quadratic in
        // tabs, on every summary change anywhere.
        let allTabs = model.chats(for: workspace.id)
        // Ephemeral chats (the find bar's Answers chat) never render as tabs.
        let tabs = allTabs.filter {
            !model.isEphemeralChat($0.id)
                && !$0.title.hasPrefix(AppModel.ephemeralChatPrefix)
        }
        let activeID = model.activeChat(for: workspace.id)?.id
        let activeFilePath = model.activeFilePath[workspace.id]
        let openFilePaths = model.openFilePaths[workspace.id] ?? []
        // Past four tabs the strip drowns in truncated titles; background tabs
        // collapse to mark + short name and the selected tab keeps its full one.
        let isCrowded = tabs.count + openFilePaths.count > 4
        let activeTabKey = activeFilePath.map { "file:\($0)" }
            ?? activeID.map { "chat:\($0.rawValue)" }
            ?? ""
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: OreTheme.Space.xs) {
                    ForEach(tabs) { tab in
                        Button {
                            model.selectChat(tab.id, in: workspace.id)
                            model.showChatInCenter(workspace.id)
                        } label: {
                            tabLabel(
                                tab,
                                isSelected: tab.id == activeID && activeFilePath == nil,
                                isCrowded: isCrowded,
                                isClosable: tabs.count > 1
                            )
                        }
                        .buttonStyle(.plain)
                        .id("chat:\(tab.id.rawValue)")
                        .contextMenu {
                            Button("Rename…") { beginRenaming(tab) }
                            Menu("Copy for Another Tab") {
                                Button("Short Transcript · Last 3 Turns") {
                                    copyTranscript(tab, length: .short)
                                }
                                Button("Long Transcript · Everything") {
                                    copyTranscript(tab, length: .full)
                                }
                            }
                            if model.splitChat[workspace.id] == tab.id {
                                Button("Close Split") {
                                    model.closeSplitChat(in: workspace.id)
                                }
                            } else {
                                Button("Open in Split") {
                                    model.openSplitChat(tab.id, in: workspace.id)
                                }
                            }
                            if allTabs.count > 1 {
                                Button("Close") { requestCloseChat(tab) }
                            }
                        }
                    }

                    // File diffs opened from the review list show up here as
                    // tabs, so a diff reads as an open document, not a side pane.
                    ForEach(openFilePaths, id: \.self) { path in
                        Button { model.selectDiffFile(path, in: workspace.id) } label: {
                            fileTabLabel(path, isSelected: activeFilePath == path, isCrowded: isCrowded)
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
            // A glass capsule instead of a rectangular bar patch: tabs sliding
            // underneath stay readable through the blur, and the cluster reads
            // as one floating control group the way Apple gathers toolbar
            // buttons on shared glass.
            // Only the active tab's state, and created if missing as before:
            // the checkpoint menu needs it even while a file tab is showing.
            trailingControls(chat: activeID.map { model.chat(for: $0) })
                .padding(.horizontal, OreTheme.Space.xs)
                .oreGlassSurface(.capsule, elevation: .inset)
                .padding(.trailing, OreTheme.Space.xs)
        }
        .frame(height: OreTheme.RowHeight.bar)
        // No full-width bar fill. The strip sits directly on the window's glass
        // base, so tabs read as floating glass pills — the selected one is cut
        // from real Liquid Glass in `OreNavigationSelection` — rather than as a
        // browser-style opaque header welded to the window.
    }

    /// Width reserved at *each* edge of the strip: the trailing side holds the
    /// fixed controls (search, new-tab, history, and the stop button while
    /// busy), and the leading side matches it so the tabs stay optically
    /// centred rather than shifted by the controls' width. Must track the
    /// controls' real width — reserved short, the last tab's tail (and its
    /// close button) hides underneath them and no amount of scrolling brings
    /// it back.
    private var tabControlAllowance: CGFloat {
        136
    }

    /// "Femtosecond Chemistry" → "Femtosecond": the first word carries the
    /// scientist identity; the rest is what was drowning the strip.
    private func shortTitle(_ title: String) -> String {
        let first = title.split(separator: " ").first.map(String.init) ?? title
        return String(first.prefix(12))
    }

    /// Copies context without choosing a destination on the user's behalf.
    /// They can switch to any tab and paste; long pastes automatically use the
    /// composer's existing attachment treatment instead of flooding the field.
    private func copyTranscript(_ tab: ChatSummary, length: TabTranscriptCopy.Length) {
        let text = TabTranscriptCopy.render(
            tabTitle: tab.title,
            agentName: tab.harness.displayName,
            rows: model.chat(for: tab.id).rows,
            length: length
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func fileTabLabel(_ path: String, isSelected: Bool, isCrowded: Bool) -> some View {
        let compact = isCrowded && !isSelected
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
        .padding(.horizontal, compact ? 8 : 10)
        .frame(maxWidth: compact ? 130 : 190, minHeight: 28)
        .help(compact ? path : "")
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

    private func tabLabel(
        _ tab: ChatSummary, isSelected: Bool, isCrowded: Bool, isClosable: Bool
    ) -> some View {
        // Read without creating. `chat(for:)` here built state and loaded the
        // history of every tab in the strip; a tab with no state yet is not
        // running and has no draft attachments this session. Hovering warms
        // it (below), so a click or a transcript copy still finds it loaded.
        let tabState = model.chatStates[tab.id]
        let isWorking = tabState?.isBusy ?? false
        let compact = isCrowded && !isSelected
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
                Text(compact ? shortTitle(tab.title) : tab.title)
                    .font(.system(size: OreTheme.Font.body, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                if !compact, !tab.draftText.isEmpty || !(tabState?.draftAttachments.isEmpty ?? true) {
                    Image(systemName: "pencil").font(.system(size: 8))
                }
                if tab.queuedMessageCount > 0 {
                    Text("\(tab.queuedMessageCount)")
                        .font(.caption2.monospacedDigit())
                }
                // Compact tabs keep the close affordance on hover — hiding it
                // entirely forced a select-then-close dance.
                if isClosable,
                   !compact || hoveredTabKey == "chat:\(tab.id.rawValue)" {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .opacity(hoveredTabKey == "chat:\(tab.id.rawValue)" || isSelected ? 1 : 0)
                        .contentShape(Rectangle())
                        .onTapGesture { requestCloseChat(tab) }
                }
            }
        }
        .padding(.horizontal, compact ? 8 : 10)
        .frame(maxWidth: compact ? 130 : 190, minHeight: 28)
        .help(compact ? tab.title : "")
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
            // the active one out at a glance. On macOS 26 the selected tab is a
            // tinted Liquid Glass pill — its own marker — and an underline over
            // real glass reads as a sticker, so it's reserved for the fallback.
            if #available(macOS 26.0, *) {
                EmptyView()
            } else if isSelected {
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
            if hovering {
                hoveredTabKey = key
                if model.chatStates[tab.id] == nil { _ = model.chat(for: tab.id) }
            } else if hoveredTabKey == key {
                hoveredTabKey = nil
            }
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
    private func trailingControls(chat: ChatState?) -> some View {
        let revertableTurns = chat?.revertableTurns ?? []
        HStack(spacing: OreTheme.Space.xs) {
            Button {
                // ⌘F never closes: pressed with the bar already open it
                // returns focus to the field. Esc is what closes.
                isSearching = true
                searchFocusRequest += 1
            } label: {
                Image(systemName: "magnifyingglass")
                    .padding(.horizontal, 6)
                    .frame(height: 26)
            }
            .buttonStyle(OrePressableButtonStyle())
            .keyboardShortcut("f", modifiers: .command)
            .help("Find in transcript (⌘F)")

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
                if !revertableTurns.isEmpty {
                    Section("Checkpoints") {
                        ForEach(Array(revertableTurns.enumerated().reversed()), id: \.offset) { index, turn in
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
                if revertableTurns.isEmpty && closed.isEmpty {
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
    }

    // MARK: - Composer

    private func composer(paneHeight: CGFloat, chat: ChatState, chatSummary: ChatSummary?) -> some View {
        let external = externalAttachments(chat)
        let mentions = mentionSuggestions(chat)
        return VStack(spacing: OreTheme.Space.sm) {
            if chat.isBusy {
                // Handed the state, not its values: the status row reads
                // `lastEventAt` and friends itself, so a streaming event
                // redraws that row instead of this whole conversation column.
                ComposerBusyStatus(
                    harness: chatSummary?.harness ?? workspace.harness,
                    chat: chat,
                    onStop: { model.interrupt(workspace.id) }
                )
                .transition(.opacity)
            } else if !chat.backgroundTasks.isEmpty {
                ComposerWaitingStatus(
                    tasks: chat.backgroundTasks,
                    startedAt: chat.backgroundWaitStartedAt
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

            if !external.isEmpty {
                AttachmentChipStrip(
                    attachments: external.map {
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
                .oreGlassSurface(.rect(cornerRadius: 12), elevation: .popover)
            }

            if !mentions.isEmpty {
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

                    ForEach(mentions.prefix(6)) { node in
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
                .oreGlassSurface(.rect(cornerRadius: 12), elevation: .popover)
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
                    mentionNames: chat.draftAttachments
                        .filter {
                            !$0.relativePath.hasPrefix(".context/attachments/")
                                || inlinePastedPaths.contains($0.relativePath)
                        }
                        .map(\.displayName),
                    onTab: acceptFirstMentionSuggestion,
                    onPaste: handlePasteboard,
                    onCopy: handleComposerCopy,
                    previewURL: previewURL(for:),
                    onHeightChange: { composerTextHeight = $0 }
                )
                    .frame(height: min(max(composerTextHeight, 38), 200))
                    .focused($composerFocused)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(placeholder(chat))
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
            }

            if let tab = chatSummary {
                composerToolbar(for: tab, chat: chat)
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
            voiceInput: voice
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

    /// `tab` is the active chat's summary: the toolbar only exists when there is one.
    private func composerToolbar(for tab: ChatSummary, chat: ChatState) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: OreTheme.Space.xs) {
                attachmentMenu
                modelChooserButton(for: tab)
                if supportsEffort(for: tab) {
                    effortButton(for: tab)
                }
                permissionChip(chat: chat, chatSummary: tab)
                modeControls(for: tab)
                ComposerContextMeter(chat: chat, tab: tab)
                Spacer(minLength: OreTheme.Space.md)
                composerSendCluster(chat: chat, chatSummary: tab)
            }

            HStack(spacing: OreTheme.Space.xs) {
                attachmentMenu
                modelChooserButton(for: tab)
                permissionChip(chat: chat, chatSummary: tab)
                modeControls(for: tab)
                Spacer(minLength: OreTheme.Space.md)
                composerSendCluster(chat: chat, chatSummary: tab)
            }
        }
        .frame(minHeight: 34)
    }

    private func permissionChip(chat: ChatState, chatSummary: ChatSummary?) -> some View {
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
    private func hidesGenericPermission(_ permission: PermissionRequest, in chat: ChatState) -> Bool {
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
        // Same rule as effort: an unknown/remapped model id must not inherit
        // the default model's tiers.
        let selected: AgentModel?
        if let id = tab.model {
            selected = choices.first { $0.id == id }
            if selected == nil { return false }
        } else {
            selected = choices.first(where: \.isDefault) ?? choices.first
        }
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
                clampEffort(to: tab, harness: harness, modelID: selectedModel)
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
        let efforts = availableEfforts(for: tab)
        return Button { showEffortChooser.toggle() } label: {
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
                efforts: efforts,
                harness: tab.harness
            )
        }
        .help(efforts.count == 1
            ? "Reasoning effort: \(efforts[0].displayName), selected automatically for this model."
            : "Reasoning effort: \(reasoningEffort.displayName). Scroll to adjust.")
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

    /// Changes whenever the selected model's effective effort capabilities do.
    /// It deliberately includes the discovered values, not only the model id:
    /// a late CLI catalog refresh can correct a stale built-in catalog in place.
    private func effortCapabilityKey(_ chatSummary: ChatSummary?) -> String {
        guard let tab = chatSummary else { return "none" }
        return ([tab.harness.rawValue, tab.model ?? "default"]
            + availableEfforts(for: tab).map(\.rawValue))
            .joined(separator: "|")
    }

    private func availableEfforts(
        for tab: ChatSummary,
        harness: HarnessKind? = nil,
        modelID: String? = nil
    ) -> [ReasoningEffort] {
        let kind = harness ?? tab.harness
        guard kind.supportsReasoningEffort else { return [] }
        let choices = model.knownModels(for: kind)
        let requestedID = modelID ?? tab.model
        let selected: AgentModel?
        if let requestedID {
            selected = choices.first { $0.id == requestedID }
            // An unknown id (provider remaps like `gpt-5.5-codex-…`) must not
            // inherit the default model's ladder — that is how Max was sent to
            // a model that only accepts none…xhigh.
            if selected == nil { return [] }
        } else {
            selected = choices.first(where: \.isDefault) ?? choices.first
        }
        let advertised = Set(selected?.supportedReasoningEfforts ?? [])
        guard !advertised.isEmpty else { return [] }
        return ReasoningEffort.allCases.filter { advertised.contains($0.rawValue) }
    }

    /// Effort the next send should actually apply. A leftover High from another
    /// model must not ride onto Fable 5, which only advertises adaptive.
    private func resolvedEffort(for tab: ChatSummary?) -> ReasoningEffort? {
        guard let tab, supportsEffort(for: tab) else { return nil }
        let efforts = availableEfforts(for: tab)
        if efforts.contains(reasoningEffort) { return reasoningEffort }
        return preferredEffort(in: efforts)
    }

    private func clampEffort(
        to tab: ChatSummary,
        harness: HarnessKind? = nil,
        modelID: String? = nil
    ) {
        let efforts = availableEfforts(for: tab, harness: harness, modelID: modelID)
        guard !efforts.isEmpty else { return }
        let resolved = efforts.contains(reasoningEffort)
            ? reasoningEffort
            : preferredEffort(in: efforts)
        if reasoningEffort != resolved {
            reasoningEffort = resolved
        }
        // If an out-of-band command persisted an unsupported value while the
        // local state was already valid, `onChange` above will not fire. Repair
        // the stored chat too, but only when resolving its current model (the
        // picker also calls this speculatively before its model-change event).
        if harness == nil, modelID == nil,
           tab.reasoningEffort != nil, tab.reasoningEffort != resolved {
            model.setEffort(resolved, for: tab)
        }
    }

    private func persistEffort(_ effort: ReasoningEffort) {
        let key = "ore.reasoningEffort.\(chatSummary?.id.rawValue ?? workspace.id.rawValue)"
        UserDefaults.standard.set(effort.rawValue, forKey: key)
        if let tab = chatSummary, tab.reasoningEffort != effort {
            model.setEffort(effort, for: tab)
        }
    }

    private func makeVoiceFileMatcher() -> VoiceFileMatcher {
        VoiceFileMatcher(
            files: workspaceFileIndex
                .filter { !$0.isDirectory }
                .map { (name: $0.name, path: $0.path) }
        )
    }

    private func preferredEffort(in efforts: [ReasoningEffort]) -> ReasoningEffort {
        if let adaptive = efforts.first(where: { $0 == .adaptive }) { return adaptive }
        if let high = efforts.first(where: { $0 == .high }) { return high }
        return efforts[efforts.count / 2]
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

    /// Speaker, mic and send are one trailing cluster: same 30pt circle, 8pt
    /// between them, and a wider gap from the chips so the accent action
    /// isn't crowded.
    private func composerSendCluster(chat: ChatState, chatSummary: ChatSummary?) -> some View {
        HStack(spacing: OreTheme.Space.sm) {
            speakerButton(chatSummary)
            micButton
            sendButton(chat)
        }
    }

    /// Per-tab narration toggle: on means this chat's agent activity is
    /// spoken aloud, even when the tab is in the background (where it only
    /// interjects for things that need the user).
    private func speakerButton(_ chatSummary: ChatSummary?) -> some View {
        let assistantMuted = model.narration.isMuted
        let narrationOn = !assistantMuted
            && (chatSummary.map { model.narration.isEnabled($0.id) } ?? false)
        let isSpeaking = narrationOn && chatSummary != nil
            && model.narration.speakingChatID == chatSummary?.id
        return Button {
            guard let chatID = chatSummary?.id else { return }
            if assistantMuted {
                // Muted everywhere: flipping a toggle nobody can hear would
                // look broken, so this speaker lifts the mute and narrates
                // this tab.
                model.narration.setMuted(false)
                if !model.narration.isEnabled(chatID) { model.narration.toggle(chatID) }
            } else {
                model.narration.toggle(chatID)
            }
        } label: {
            Image(systemName: narrationOn ? "speaker.wave.2.fill" : "speaker.slash")
                .font(.system(size: 13, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: isSpeaking && !reduceMotion)
                .foregroundStyle(narrationOn ? Color.accentColor : .primary)
                .frame(width: 30, height: 30)
                .background(
                    narrationOn ? Color.accentColor.opacity(0.14) : OreTheme.subduedFill,
                    in: Circle()
                )
                .overlay(
                    Circle().stroke(
                        narrationOn ? Color.accentColor.opacity(0.45) : OreTheme.hairline,
                        lineWidth: 1
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(chatSummary == nil)
        // ⌥⌘S next to the mic's ⌥⌘M: the two voice controls are one pair, and
        // S is the only free letter that names what it does.
        .keyboardShortcut("s", modifiers: [.option, .command])
        .help(assistantMuted
            ? "The assistant is muted — unmute and narrate this tab (⌥⌘S)"
            : narrationOn
                ? "Stop narrating agent activity (⌥⌘S)"
                : "Narrate agent activity aloud (⌥⌘S)")
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
        clampEffort(to: tab, harness: chosen.harness, modelID: chosen.id)
    }

    @ViewBuilder
    private func sendButton(_ chat: ChatState) -> some View {
        if #available(macOS 26.0, *) {
            Button(action: send) {
                Image(systemName: chat.willQueueNextMessage ? "text.append" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(.accentColor)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.draftAttachments.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .help(chat.queueHint ?? "Send (⌘↩)")
        } else {
            Button(action: send) {
                Image(systemName: chat.willQueueNextMessage ? "text.append" : "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor, in: Circle())
                    .shadow(color: Color.accentColor.opacity(0.16), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.draftAttachments.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .help(chat.queueHint ?? "Send (⌘↩)")
        }
    }

    private func placeholder(_ chat: ChatState) -> String {
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
            effort: resolvedEffort(for: chatSummary),
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

    private func externalAttachments(_ chat: ChatState) -> [(offset: Int, element: Attachment)] {
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

    private func mentionSuggestions(_ chat: ChatState) -> [WorkspaceFileNode] {
        guard let mention = activeMention else { return [] }
        let query = mention.query.lowercased()
        // One set, not an array `contains` per file: with hundreds of files
        // in the index the per-keystroke filter was quadratic.
        let attachedPaths = Set(chat.draftAttachments.map(\.relativePath))
        return workspaceFileIndex
            .filter { node in
                !node.isDirectory
                    && !attachedPaths.contains(node.path)
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
        guard let first = mentionSuggestions(chat).first else { return false }
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

    private func composerErrorBanner(
        _ error: ChatState.ProminentError, chat: ChatState, chatSummary: ChatSummary?
    ) -> some View {
        let harness = chatSummary?.harness ?? workspace.harness
        let update = model.harnessCLIUpdate
        let matchingUpdate: AppModel.HarnessCLIUpdate? = update?.kind == harness ? update : nil
        return ProminentErrorBanner(
            error: error,
            harnessName: harness.displayName,
            scheduled: model.scheduledContinuation(for: chatSummary?.id),
            cliUpdate: matchingUpdate,
            onContinueWhenAvailable: scheduleContinuation,
            onCancelSchedule: cancelScheduledContinuation,
            onRetry: { model.retryLastTurn(in: workspace.id) },
            onUpdateCLI: {
                guard let chatSummary else { return }
                model.updateHarnessCLI(for: chatSummary)
            },
            onDismiss: { chat.dismissProminentError() }
        )
        .frame(maxWidth: OreTheme.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, OreTheme.Space.md)
        .padding(.top, OreTheme.Space.sm)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func composerRateLimitBanner(_ limit: RateLimitReport) -> some View {
        let retryWhenAvailable: (() -> Void)? = limit.status == .exhausted
            ? { self.scheduleRateLimitRetry() }
            : nil
        return RateLimitBanner(
            report: limit,
            onRetry: { model.retryLastTurn(in: workspace.id) },
            onRetryWhenAvailable: retryWhenAvailable
        )
        .frame(maxWidth: OreTheme.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, OreTheme.Space.md)
        .padding(.top, OreTheme.Space.sm)
        .transition(.move(edge: .bottom).combined(with: .opacity))
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

    private func scheduleRateLimitRetry() {
        guard let chatSummary else { return }
        let resumeAt = chat.rateLimit?.resetsAt
            ?? chat.prominentError?.resetsAt
            ?? Date().addingTimeInterval(60 * 60)
        model.scheduleContinuation(
            workspaceID: workspace.id,
            chatID: chatSummary.id,
            resumeAt: resumeAt,
            retriesLastTurn: true
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

/// Copy for the composer's live status row. Kept out of the view so the stall
/// wording can be tested without spinning SwiftUI.
enum ComposerBusyCopy {
    static let stallSilence: TimeInterval = 90

    static func label(
        harness: HarnessKind,
        status: AgentStatus,
        runningToolLabel: String?,
        isStarting: Bool,
        lastEventAt: Date?,
        now: Date
    ) -> String {
        if isStarting { return "Starting \(harness.displayName)…" }
        if let lastEventAt, now.timeIntervalSince(lastEventAt) >= stallSilence {
            return "No output for \(elapsed(from: lastEventAt, to: now))"
        }
        switch status {
        case .runningTool:
            if let runningToolLabel, !runningToolLabel.isEmpty {
                return runningToolLabel
            }
            return "\(harness.displayName) is running a tool"
        case .thinking:
            return "\(harness.displayName) is thinking"
        case .requesting:
            return "\(harness.displayName) is waiting on the model"
        default:
            return "\(harness.displayName) is working"
        }
    }

    static func turnElapsed(from start: Date, to now: Date) -> String {
        "\(elapsed(from: start, to: now)) this turn"
    }

    /// The waiting row's wording. Names the work when there is one piece of it,
    /// because "a background task" says nothing a person can act on; counts
    /// it when there are several, because a list does not fit on one line.
    static func waitingLabel(_ tasks: [AgentBackgroundTask]) -> String {
        guard let first = tasks.first else { return "" }
        if tasks.count > 1 { return "Waiting on \(tasks.count) background tasks" }
        let description = first.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty
            ? "Waiting on a background task"
            : "Waiting on background work · \(description)"
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}

/// The find bar (⌘F): live query over the visible transcript with next /
/// previous navigation, plus the escape hatch upward — "Ask All Tabs" (⌘↩)
/// turns the query into a question answered with every tab's recent context.
///
/// The query is *local* state, deliberately: bound to the pane, every
/// keystroke re-evaluated the whole ChatPane body — tab strip, suggestion
/// ladder, transcript host diffing — which is the lag the composer had
/// already eliminated. The pane only hears the debounced query.
private struct TranscriptSearchBar: View {
    let anchor: TranscriptScrollAnchor
    /// Bumped by ⌘F while the bar is already open — refocus the field.
    var focusRequest = 0
    let onQueryChange: (String) -> Void
    let onAskTabs: (String) -> Void
    let onClose: () -> Void
    @State private var query = ""
    @State private var debounce: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: OreTheme.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Find in transcript — or ask a question…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: OreTheme.Font.body))
                .focused($focused)
                // Enter walks *older* — the search starts at the newest match
                // and climbs up through history.
                .onSubmit { anchor.findPrevious() }
                .onExitCommand(perform: onClose)
                .onChange(of: query) { _, value in
                    debounce?.cancel()
                    debounce = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(180))
                        guard !Task.isCancelled else { return }
                        onQueryChange(value)
                    }
                }

            if anchor.searchMatchCount > 0 {
                Text("\(anchor.searchMatchOrdinal) of \(anchor.searchMatchCount)")
                    .font(.system(size: OreTheme.Font.caption).monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if !query.isEmpty {
                Text("No matches")
                    .font(.system(size: OreTheme.Font.caption))
                    .foregroundStyle(.tertiary)
            }

            Button { anchor.findPrevious() } label: {
                Image(systemName: "chevron.up").frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(anchor.searchMatchCount == 0)
            .help("Previous match (⇧⌘G)")

            Button { anchor.findNext() } label: {
                Image(systemName: "chevron.down").frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("g", modifiers: .command)
            .disabled(anchor.searchMatchCount == 0)
            .help("Next match (⌘G)")

            Divider().frame(height: 14)

            Button("Ask All Tabs ⌘↩") { onAskTabs(query) }
                .buttonStyle(.link)
                .font(.system(size: OreTheme.Font.body, weight: .medium))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(
                    "Answer this as a question right here (⌘↩), using the "
                        + "recent context of every conversation in this workspace"
                )

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, OreTheme.Space.sm)
        .frame(height: 32)
        .background(OreTheme.subduedFill, in: RoundedRectangle(cornerRadius: OreTheme.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: OreTheme.controlRadius)
                .stroke(OreTheme.hairline, lineWidth: 1)
        }
        .padding(.horizontal, OreTheme.Space.md)
        .padding(.vertical, OreTheme.Space.xs)
        .onAppear { focused = true }
        .onChange(of: focusRequest) { _, _ in focused = true }
    }
}

/// The find bar's answer surface: the ephemeral chat's reply, streamed in
/// place — and, when that agent needs to ask something back, the question
/// itself, fully readable with its options and a free-form reply. The chat
/// behind it never becomes a tab and closes with the bar.
private struct CrossTabAnswerPanel: View {
    var state: ChatState
    let onAnswer: (String) -> Void
    @State private var freeform = ""

    private var answer: String? {
        state.rows.last { $0.kind == .assistantText && !$0.text.isEmpty }?.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.sm) {
            HStack(spacing: 6) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("Answer from all tabs")
                    .font(.system(size: OreTheme.Font.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if state.isBusy {
                    ProgressView().controlSize(.small)
                }
            }

            if let question = state.pendingQuestion {
                questionView(question)
            } else if let answer {
                ScrollView {
                    Text((try? AttributedString(markdown: answer)) ?? AttributedString(answer))
                        .font(.system(size: OreTheme.Font.prose))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            } else {
                Text(state.isBusy ? "Reading every tab…" : "Waiting for the agent…")
                    .font(.system(size: OreTheme.Font.body))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(OreTheme.Space.sm + 2)
        .background(OreTheme.subduedFill, in: RoundedRectangle(cornerRadius: OreTheme.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: OreTheme.controlRadius)
                .stroke(OreTheme.hairline, lineWidth: 1)
        }
        .padding(.horizontal, OreTheme.Space.md)
        .padding(.bottom, OreTheme.Space.xs)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// The agent's counter-question, in full: the whole prompt (no
    /// truncation), each option as its own readable button, and the free-form
    /// field when the question allows one.
    @ViewBuilder
    private func questionView(_ question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(question.prompt)
                    .font(.system(size: OreTheme.Font.prose))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                Button {
                    onAnswer(option.label)
                } label: {
                    Text(option.label)
                        .font(.system(size: OreTheme.Font.body, weight: .medium))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(OreTheme.selectedFill, in: RoundedRectangle(cornerRadius: OreTheme.tabRadius))
                        .contentShape(RoundedRectangle(cornerRadius: OreTheme.tabRadius))
                }
                .buttonStyle(OrePressableButtonStyle())
            }

            if question.allowsFreeform {
                HStack(spacing: OreTheme.Space.xs) {
                    TextField("Or answer in your own words…", text: $freeform)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submitFreeform() }
                    Button { submitFreeform() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .disabled(freeform.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func submitFreeform() {
        let text = freeform.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onAnswer(text)
        freeform = ""
    }
}

/// The floating capsule above the composer — the reference design's "Give me
/// a summary of the changes today". Tap sends it; hovering reveals a dismiss.
private struct ComposerSuggestionChip: View {
    let text: String
    var icon: String = "sparkles"
    let onSend: () -> Void
    let onDismiss: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onSend) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text(text)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .contentShape(Capsule())
            }
            .buttonStyle(OrePressableButtonStyle())
            .help("Send this prompt")

            if isHovering {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .help("Dismiss")
            }
        }
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().stroke(OreTheme.hairline, lineWidth: 1) }
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

/// The pane's presence line: one dot per agent under the tab strip — "Claude
/// is thinking · Codex is idle" — so who is live in this workspace is readable
/// without hunting for the composer's animated border. One entry per harness,
/// not per tab: presence is about the agent, and its most alive chat speaks
/// for it.
struct AgentPresenceStrip: View {
    let chats: [ChatSummary]
    /// When set, every harness appears — "Cursor is idle" included — so the
    /// roster reads as the full crew, not just whoever has a tab open.
    var showsAllHarnesses = false

    struct Entry: Equatable, Identifiable {
        var id: String
        var text: String
        var isLive: Bool
        var needsYou: Bool
        var failed: Bool
    }

    var body: some View {
        HStack(spacing: OreTheme.Space.md) {
            ForEach(displayEntries) { entry in
                HStack(spacing: 5) {
                    Circle()
                        .fill(dotColor(for: entry))
                        .frame(width: 6, height: 6)
                    Text(entry.text)
                        .font(.system(size: OreTheme.Font.caption))
                        .foregroundStyle(entry.needsYou || entry.failed ? .primary : .secondary)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: displayEntries)
        .accessibilityElement(children: .combine)
    }

    /// The roster with the boring parts folded: whoever needs you or is
    /// working gets named; the idle remainder collapses to one entry —
    /// "Claude is idle · Codex is idle · Cursor is idle" said nothing three
    /// times that "All agents idle" says once.
    var displayEntries: [Entry] {
        let all = entries
        let interesting = all.filter { $0.isLive || $0.needsYou || $0.failed }
        let idle = all.filter { !$0.isLive && !$0.needsYou && !$0.failed }

        if interesting.isEmpty {
            guard !idle.isEmpty else { return [] }
            if idle.count == 1 { return idle }
            return [Entry(
                id: "all-idle",
                text: "All agents idle",
                isLive: false, needsYou: false, failed: false
            )]
        }
        var result = interesting
        if idle.count == 1 {
            result.append(idle[0])
        } else if idle.count > 1 {
            result.append(Entry(
                id: "idle-rest",
                text: "\(idle.count) idle",
                isLive: false, needsYou: false, failed: false
            ))
        }
        return result
    }

    private func dotColor(for entry: Entry) -> Color {
        if entry.failed { return OreTheme.Status.failed }
        if entry.needsYou { return OreTheme.Status.needsYou }
        return entry.isLive ? OreTheme.Presence.active : OreTheme.Presence.idle.opacity(0.6)
    }

    var entries: [Entry] {
        var byHarness: [HarnessKind: AgentStatus] = [:]
        var order: [HarnessKind] = []
        if showsAllHarnesses {
            order = HarnessKind.allCases
            for harness in order { byHarness[harness] = .idle }
        }
        for chat in chats {
            if byHarness[chat.harness] == nil { order.append(chat.harness) }
            byHarness[chat.harness] = Self.livelier(byHarness[chat.harness], chat.status)
        }
        return order.map { harness in
            let status = byHarness[harness] ?? .idle
            return Entry(
                id: harness.rawValue,
                text: "\(Self.shortName(harness)) is \(Self.phrase(for: status))",
                isLive: Self.rank(status) >= Self.rank(.requesting),
                needsYou: status == .awaitingInput,
                failed: status == .failed
            )
        }
    }

    /// "Claude", not "Claude Code" — the presence line reads like the
    /// reference design's roster, and the surname is chrome.
    static func shortName(_ harness: HarnessKind) -> String {
        harness.displayName.split(separator: " ").first.map(String.init)
            ?? harness.displayName
    }

    static func phrase(for status: AgentStatus) -> String {
        switch status {
        case .runningTool: "running a tool"
        case .thinking: "thinking"
        case .requesting: "working"
        case .awaitingInput: "waiting on you"
        case .failed: "stopped on an error"
        case .interrupted: "paused"
        case .idle: "idle"
        }
    }

    static func livelier(_ current: AgentStatus?, _ next: AgentStatus) -> AgentStatus {
        guard let current else { return next }
        return rank(next) > rank(current) ? next : current
    }

    private static func rank(_ status: AgentStatus) -> Int {
        switch status {
        case .runningTool: 6
        case .thinking: 5
        case .requesting: 4
        case .awaitingInput: 3
        case .failed: 2
        case .interrupted: 1
        case .idle: 0
        }
    }
}

/// A stable overlay rather than another transcript row. It makes work obvious
/// at a glance while keeping streamed text from repeatedly inserting/removing
/// loading content and shifting the scroll position.
/// The agent's live status, folded into the top of the composer instead of a
/// pill floating over the transcript. It reads as part of the input box — a
/// quiet row above the text, paired with the composer's animated busy border.
private struct ComposerBusyStatus: View {
    let harness: HarnessKind
    /// Read here rather than unpacked by the caller: `lastEventAt` moves on
    /// every streamed event, and only this row should redraw for it.
    let chat: ChatState
    let onStop: () -> Void
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        let status = chat.status
        let startedAt = chat.turnStartedAt
        let lastEventAt = chat.lastEventAt
        let runningToolLabel = chat.runningToolLabel
        // Booting a one-shot CLI takes seconds before its first event; the
        // status row says so rather than claiming work is already happening.
        let isStarting = !chat.hasTurnEventArrived
        HStack(spacing: 7) {
            // Who is working, in the same visual language as the header's
            // presence line: the agent's mark and a live green dot. The
            // composer's sweeping border already supplies the motion.
            HarnessMark(harness: harness, size: 15)
            Circle()
                .fill(OreTheme.Presence.active)
                .frame(width: 6, height: 6)
            // Only the clock-driven labels sit inside the timeline, so the
            // mark and the Stop button aren't rebuilt every second.
            TimelineView(StatusClockSchedule(
                anchor: startedAt ?? .distantPast,
                paused: controlActiveState != .key
            )) { context in
                HStack(spacing: 7) {
                    Text(ComposerBusyCopy.label(
                        harness: harness,
                        status: status,
                        runningToolLabel: runningToolLabel,
                        isStarting: isStarting,
                        lastEventAt: lastEventAt,
                        now: context.date
                    ))
                    .font(.system(size: OreTheme.Font.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                    if let startedAt {
                        Text(ComposerBusyCopy.turnElapsed(from: startedAt, to: context.date))
                            .font(.system(size: OreTheme.Font.caption, weight: .medium).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
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
}

/// The composer's quieter sibling to `ComposerBusyStatus`: the turn is over
/// and the composer is free, but the agent handed work off — a build, a test
/// run, a subagent — and will pick its result up on its own. Without this a
/// chat waiting on a ten-minute build read exactly like one with nothing left
/// to do. No live dot and no Stop: nothing here is the agent working, and the
/// work belongs to the harness until it reports back.
private struct ComposerWaitingStatus: View {
    let tasks: [AgentBackgroundTask]
    var startedAt: Date?
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "hourglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            Text(ComposerBusyCopy.waitingLabel(tasks))
                .font(.system(size: OreTheme.Font.caption, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let startedAt {
                // The clock ticks only this label, not the whole row.
                TimelineView(StatusClockSchedule(
                    anchor: startedAt,
                    paused: controlActiveState != .key
                )) { context in
                    Text(ComposerBusyCopy.elapsed(from: startedAt, to: context.date))
                        .font(.system(size: OreTheme.Font.caption, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .help(tasks.map(\.description).filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}

/// The composer status rows' one-second clock.
///
/// `.periodic(from: .now, by: 1)` restarted its phase on every parent render,
/// and kept ticking behind a window nobody was looking at. This one ticks on
/// whole seconds from a fixed anchor, so a redraw lands on the same grid, and
/// stops while the window isn't key — the pause every decorative timeline in
/// the app already takes. The labels catch up when the window is focused.
struct StatusClockSchedule: TimelineSchedule {
    var anchor: Date
    var paused: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        if paused {
            var pending: Date? = startDate
            return AnyIterator {
                defer { pending = nil }
                return pending
            }
        }
        // The last whole second from the anchor at or before `startDate`.
        // Whole seconds are exact in `Double` for any date this far from the
        // anchor, and an anchor at `.distantPast` just means "no alignment".
        let offset = startDate.timeIntervalSince(anchor)
        var next = offset.isFinite && abs(offset) < 1e12
            ? anchor.addingTimeInterval(offset.rounded(.down))
            : startDate
        return AnyIterator {
            defer { next = next.addingTimeInterval(1) }
            return next
        }
    }
}

/// The toolbar's context meter, split out so `usage` — rewritten as a turn
/// streams — redraws the meter instead of the whole composer column.
private struct ComposerContextMeter: View {
    let chat: ChatState
    let tab: ChatSummary

    var body: some View {
        if let usage = chat.usage ?? tab.contextUsage,
           let window = usage.contextWindow, window > 0 {
            ContextMeter(
                used: usage.totalContextTokens,
                window: window,
                usage: usage,
                modelName: tab.model
            )
        }
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
            [Hint(keys: "⌘K", label: "Command palette"), Hint(keys: "↩ / Esc", label: "Allow / deny"), Hint(keys: "⌘.", label: "Stop agent")],
            [Hint(keys: "⌘T", label: "New chat"), Hint(keys: "⌘W", label: "Close chat"), Hint(keys: "⇧⌘[ / ]", label: "Switch chats")],
            [Hint(keys: "⌥⌘T", label: "Terminal"), Hint(keys: "⌘1–9", label: "Jump workspace"), Hint(keys: "⌘/", label: "All shortcuts")],
        ]
        let value = seed.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return groups[abs(value) % groups.count]
    }
}

private struct ShortcutCaption: View {
    let title: String
    let keys: String
    var onPrimary = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if !keys.isEmpty {
                Text(keys)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .opacity(onPrimary ? 0.72 : 0.55)
            }
        }
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
        let scale = EffortPickerScale(efforts: efforts)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Reasoning effort", systemImage: "chart.bar.fill")
                    .font(.headline)
                Spacer()
                Text(selection.displayName).foregroundStyle(.secondary)
            }
            if let range = scale.sliderRange {
                Slider(value: indexBinding, in: range, step: 1)
                HStack {
                    Text("Faster")
                    Spacer()
                    Text("Deeper")
                }
                .font(.caption).foregroundStyle(.secondary)
            } else if let only = efforts.first {
                Label(
                    "\(only.displayName) is selected automatically for this model.",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("This model does not expose a reasoning-effort control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(harness == .claudeCode
                ? "Applied through your Claude Code session. Scroll the chip to adjust."
                : "Applied to the next Codex turn. Scroll the chip to adjust.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 300)
    }

    private var indexBinding: Binding<Double> {
        let scale = EffortPickerScale(efforts: efforts)
        return Binding(
            get: { scale.value(for: selection) },
            set: {
                guard let resolved = scale.selection(at: $0) else { return }
                selection = resolved
            }
        )
    }
}

/// The safe, testable index mapping behind the effort slider. A slider exists
/// only when there are at least two choices; SwiftUI treats `0...0` as an
/// invalid slider interval and traps while presenting the popover.
struct EffortPickerScale {
    let efforts: [ReasoningEffort]

    var sliderRange: ClosedRange<Double>? {
        guard efforts.count > 1 else { return nil }
        return 0...Double(efforts.count - 1)
    }

    func value(for selection: ReasoningEffort) -> Double {
        Double(efforts.firstIndex(of: selection) ?? min(2, max(0, efforts.count - 1)))
    }

    func selection(at value: Double) -> ReasoningEffort? {
        guard !efforts.isEmpty else { return nil }
        let index = Int(value.rounded()).clamped(to: 0...(efforts.count - 1))
        return efforts[index]
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
    var harnessName: String = "CLI"
    var scheduled: ScheduledContinuation?
    var cliUpdate: AppModel.HarnessCLIUpdate?
    var onContinueWhenAvailable: () -> Void
    var onCancelSchedule: () -> Void
    var onRetry: () -> Void
    var onUpdateCLI: () -> Void
    let onDismiss: () -> Void

    private var tint: Color {
        if error.needsCLIUpgrade { return OreTheme.warning }
        return error.isUsageLimit ? OreTheme.warning : .red
    }
    private var icon: String {
        if error.needsCLIUpgrade { return "arrow.down.app.fill" }
        return error.isUsageLimit ? "hourglass.circle.fill" : "exclamationmark.triangle.fill"
    }
    private var title: String {
        if error.needsCLIUpgrade { return "\(harnessName) needs an update" }
        return error.isUsageLimit ? "Usage limit reached" : "The agent hit an error"
    }
    private var resetDate: Date? { scheduled?.resumeAt ?? error.resetsAt }
    private var isUpdatingCLI: Bool { cliUpdate?.isRunning == true }

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

                if let updateError = cliUpdate?.error, !isUpdatingCLI {
                    Text(updateError)
                        .font(.system(size: OreTheme.Font.caption))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if error.needsCLIUpgrade {
                    updateCLIButton
                } else if error.isUsageLimit {
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

    private var updateCLIButton: some View {
        Button(action: onUpdateCLI) {
            HStack(spacing: 6) {
                if isUpdatingCLI {
                    ProgressView().controlSize(.small)
                    Text("Updating \(harnessName)…")
                } else {
                    Image(systemName: "arrow.down.app")
                    Text("Update \(harnessName)")
                }
            }
            .font(.system(size: OreTheme.Font.caption, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isUpdatingCLI)
        .help("Install the latest \(harnessName) CLI, then retry this prompt")
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
                Text(item.retriesLastTurn
                     ? "Retrying when the limit resets"
                     : "Continuing when the limit resets")
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
    var onRetryWhenAvailable: (() -> Void)?

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
            if let onRetryWhenAvailable {
                Button(action: onRetryWhenAvailable) {
                    Label("Retry when it resets", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: OreTheme.Font.caption, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Automatically retry the last prompt when the rate limit resets")
            } else {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.system(size: OreTheme.Font.caption, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
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
    @FocusState private var allowFocused: Bool
    /// Whether the user has asked to see a command too long for the card's
    /// six lines. Until they have, Allow is not an informed answer.
    @State private var isTargetExpanded = false

    private static let collapsedLineLimit = 6

    var body: some View {
        let content = PermissionPresentation(request: request)
        let overflowing = Self.lineCount(content.target) > Self.collapsedLineLimit
        let isHidingPart = overflowing && !isTargetExpanded
        VStack(alignment: .leading, spacing: OreTheme.Space.sm) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text(content.action).fontWeight(.semibold)
                Spacer(minLength: OreTheme.Space.sm)
                if let tool = content.toolLabel {
                    Text(tool)
                        .font(.system(size: OreTheme.Font.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("The tool the agent is asking to use")
                }
            }

            // The act itself — the command, the path, the URL. This is what is
            // being approved, so it leads and it is never paraphrased.
            if let target = content.target {
                Text(target)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(isTargetExpanded ? nil : Self.collapsedLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                if overflowing {
                    // A tooltip would not do: the hidden tail of a command is
                    // where `&& rm -rf` lives, and a benign first line is
                    // exactly how a card gets approved without being read.
                    Button {
                        isTargetExpanded = true
                        allowFocused = true
                    } label: {
                        Label(
                            isTargetExpanded
                                ? "Showing all \(Self.lineCount(target)) lines"
                                : "+\(Self.lineCount(target) - Self.collapsedLineLimit) more lines — show the whole command",
                            systemImage: isTargetExpanded ? "checkmark" : "chevron.down"
                        )
                        .font(.system(size: OreTheme.Font.caption, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isTargetExpanded ? .secondary : Color.orange)
                    .disabled(isTargetExpanded)
                }
            }

            // The agent's reason, under the act rather than instead of it.
            if let detail = content.detail {
                Text(detail)
                    .font(.system(size: OreTheme.Font.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Allow and Deny get a row to themselves. A single "Always allow
            // Bash(curl -s "http://…&max_results=…")" offer used to sit beside
            // them at its full intrinsic width, which squeezed both buttons
            // down to a few points of blue: the primary action, present but
            // unreadable and effectively unclickable.
            HStack(spacing: OreTheme.Space.sm) {
                Button {
                    onDecision(.allow)
                } label: {
                    ShortcutCaption(title: "Allow", keys: isHidingPart ? "" : "↩", onPrimary: true)
                }
                    .buttonStyle(OrePrimaryButtonStyle())
                    // ↩ is muscle memory. Leaving it armed while part of the
                    // command is off-screen turns a reflex into consent to
                    // something unread.
                    .modifier(DefaultActionShortcut(enabled: !isHidingPart))
                    .focused($allowFocused)
                    .disabled(isHidingPart)
                    .help(isHidingPart
                        ? "Show the whole command before allowing it"
                        : "Allow this tool once (↩). From the composer, ⇧⌘A.")

                Button {
                    onDecision(.deny(reason: "The user denied this in ORE."))
                } label: {
                    ShortcutCaption(title: "Deny", keys: "Esc")
                }
                .buttonStyle(OreSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .help("Deny this tool (Esc). From the composer, ⇧⌘D.")

                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)

            // Harness-suggested standing grants, kept as raw payloads so what
            // we send back is exactly what was offered. They answer a different
            // question from Allow — "and every time after this" — so they sit
            // on their own line and can never crowd the once-only choice.
            // Hidden while part of the command is, for the same reason Allow
            // is: a standing rule is a broader yes than the one-off.
            if !isHidingPart { grants(content.grants) }
        }
        .oreCard(padding: 12)
        .id(request.id)
        .onAppear { allowFocused = true }
    }

    private static func lineCount(_ text: String?) -> Int {
        guard let text else { return 0 }
        return text.components(separatedBy: .newlines).count
    }

    @ViewBuilder
    private func grants(_ grants: [PermissionPresentation.Grant]) -> some View {
        if grants.count == 1, let only = grants.first {
            Button {
                onDecision(.allowWithSuggestion(only.raw))
            } label: {
                // A scoped rule is the way out of answering the same question
                // all afternoon, so it earns a chord. Mode switches change how
                // every later tool is treated and stay click-only.
                ShortcutCaption(title: only.label, keys: only.kind == .addRule ? "⇧↩" : "")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(OreSecondaryButtonStyle())
            .modifier(GrantShortcut(enabled: only.kind == .addRule))
            .help(only.full)
            .accessibilityLabel(only.full)
        } else if !grants.isEmpty {
            Menu {
                ForEach(Array(grants.enumerated()), id: \.offset) { _, grant in
                    Button(grant.full) { onDecision(.allowWithSuggestion(grant.raw)) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Always allow…")
                        .font(.system(size: OreTheme.Font.body, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .frame(minHeight: OreTheme.RowHeight.button)
                .background(OreTheme.subduedFill, in: Capsule())
                .overlay { Capsule().stroke(OreTheme.hairline) }
                .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Standing approvals offered by the agent — read each before granting")
        }
    }
}

/// ⇧↩ on the standing-grant button, only where granting one is a scoped rule.
/// Arms ↩ only when pressing it would be an informed answer.
private struct DefaultActionShortcut: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}

private struct GrantShortcut: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(.return, modifiers: .shift)
        } else {
            content
        }
    }
}

private struct PlanApprovalCard: View {
    let markdown: String
    let comments: [DiffCommentReference]
    let paneHeight: CGFloat
    var commentOrigin: String? = nil
    let onRemoveComment: (Int) -> Void
    let onClearComments: () -> Void
    let onHandoff: () -> Void
    let onApprove: (String) -> Void
    let onReject: (String) -> Void
    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.sm) {
            Label("Plan ready for review", systemImage: "checklist")
                .font(.system(size: OreTheme.Font.title, weight: .semibold))
            ScrollView {
                Text(planBody)
                    .font(.system(size: OreTheme.Font.prose))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A max height alone lets this collapse all the way to zero when
            // the surrounding VStack is tight. Preserve enough of the plan to
            // make the decision informed, and scroll longer proposals.
            .frame(
                minHeight: 180,
                idealHeight: 260,
                maxHeight: min(420, paneHeight * 0.45)
            )
            .layoutPriority(1)

            if !comments.isEmpty {
                VStack(alignment: .leading, spacing: OreTheme.Space.xs) {
                    Label(
                        "\(comments.count) review \(comments.count == 1 ? "comment" : "comments") included with this decision",
                        systemImage: "text.bubble"
                    )
                    .font(.system(size: OreTheme.Font.caption, weight: .medium))
                    .foregroundStyle(.secondary)

                    DraftCommentsBar(
                        comments: comments,
                        origin: commentOrigin,
                        horizontalPadding: 0,
                        onRemove: onRemoveComment,
                        onClearAll: onClearComments
                    )
                }
            }

            TextField("Feedback or revision notes…", text: $feedback)
                .onSubmit { onApprove(feedback) }
            HStack {
                Button {
                    onApprove("")
                } label: {
                    ShortcutCaption(title: "Approve", keys: "↩", onPrimary: true)
                }
                .buttonStyle(OrePrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .help("Approve this plan (↩)")

                Button("Approve with Feedback") { onApprove(feedback) }
                    .disabled(feedback.isEmpty)
                    .buttonStyle(OreSecondaryButtonStyle())

                Button {
                    onReject(feedback)
                } label: {
                    ShortcutCaption(title: "Reject / Revise", keys: "Esc")
                }
                    .buttonStyle(OreSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .help("Reject this plan (Esc)")
                Spacer()
                Button("Handoff") { onHandoff() }
                    .buttonStyle(OreSecondaryButtonStyle())
                    .help("Open this plan in a new tab so you can run it with another agent")
            }
        }
        .oreCard(padding: 12)
        .overlay {
            RoundedRectangle(cornerRadius: OreTheme.cardRadius, style: .continuous)
                .fill(Color.purple.opacity(0.08))
                .allowsHitTesting(false)
        }
    }

    private var displayMarkdown: String {
        PlanProposalPolicy.normalizedMarkdown(markdown) ?? ""
    }

    private var planBody: AttributedString {
        let source = displayMarkdown
        guard !source.isEmpty else { return AttributedString("Plan body is still being written.") }
        let rendered = MarkdownRenderer(
            baseFont: .systemFont(ofSize: OreTheme.Font.prose),
            textColor: .labelColor,
            highlighter: SyntaxHighlighter.shared
        ).render(source, highlighting: .all)
        return AttributedString(rendered)
    }
}

private struct MessageQueueCard: View {
    @Binding var messages: [QueuedMessageRecord]
    let onSave: (QueuedMessageRecord, String) async -> Void
    let onDelete: (QueuedMessageRecord) async -> Void

    var body: some View {
        DisclosureGroup("Queued messages (\(messages.count))") {
            VStack(spacing: 6) {
                ForEach(messages.indices, id: \.self) { index in
                    HStack {
                        TextField("Queued message", text: $messages[index].text)
                            .onSubmit {
                                let record = messages[index]
                                Task { await onSave(record, record.text) }
                            }
                        Button(role: .destructive) {
                            let record = messages[index]
                            Task { await onDelete(record) }
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

            QuestionOptionList(options: question.options, onAnswer: onAnswer)

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

/// Observes transcript rows without invalidating the composer or tab bar — and,
/// via `Equatable`, without being invalidated *by* them.
/// The choices of an agent question, as full-width rows.
///
/// Shared by the chat pane and the Assistant window. Rows rather than a row of
/// buttons because option labels are written by the agent and are routinely
/// long enough to run off a narrow window — and because the number of them is
/// whatever the agent decided.
struct QuestionOptionList: View {
    let options: [AgentQuestion.Option]
    let onAnswer: (String) -> Void

    var body: some View {
        if !options.isEmpty {
            VStack(spacing: 6) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
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
    }
}

/// Shared with the Assistant window, which needs the same equality discipline
/// for the same reason: its composer is a sibling of the transcript, so without
/// this every keystroke would re-derive and re-diff every row.
/// The floating dock's height, measured where it is laid out and delivered to
/// the transcript's scroll inset — the two must agree or rows hide behind glass.
private struct ComposerDockHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct TranscriptHost: View, Equatable {
    var chat: ChatState
    var worktreePath: String
    /// Short agent name ("Claude") for the transcript's turn headers.
    var agentName: String
    /// The find bar's live query; empty when the bar is closed.
    var searchQuery: String
    var persistenceKey: String
    var expandedActivityGroups: Set<String>
    var canFork: Bool
    var onRevert: (TurnID) -> Void
    var onToggleActivity: (String) -> Void
    var onOpenFile: (String) -> Void
    var onTurnAction: (TurnID, TranscriptView.TurnAction) -> Void
    var scrollAnchor: TranscriptScrollAnchor
    /// Foot clearance for the floating composer dock — see `TranscriptView`.
    /// Defaults to the resting inset for hosts whose composer does not float
    /// (the assistant window).
    var bottomInset: CGFloat = 12
    /// Head clearance for the floating tab strip; plain default for hosts
    /// without floating top chrome.
    var topInset: CGFloat = 10

    /// Compared on identity-bearing inputs only.
    ///
    /// The four action closures are deliberately excluded. A capturing closure
    /// is `{function pointer, context box}` and allocates a fresh context box on
    /// every evaluation of the parent's body, and it has no `Equatable`
    /// conformance — so including them would make this view unequal on every
    /// keystroke in the composer. That is exactly what made typing cost
    /// O(transcript): an unequal host re-runs `displayRows`, which hashes every
    /// row of every completed turn, and then re-diffs every row in
    /// `TranscriptView.updateNSView`.
    ///
    /// The consequence, and the rule for anyone adding a closure here: the
    /// transcript may hold closures from an *older* body evaluation. That is
    /// safe only because each one reaches its data through a stable
    /// indirection — `@State` storage boxes, the `AppModel` reference, and ids
    /// that are fixed for the workspace's lifetime. A closure that captures a
    /// *value* which can change (a `ChatSummary`, a diff snapshot) would
    /// silently go stale; add it to `==` or route it through `@State`.
    ///
    /// Streaming is unaffected: `@Observable` invalidates this view's body
    /// directly when `chat` changes, which is independent of the equality
    /// verdict — that only suppresses updates pushed down from the parent.
    /// `nonisolated` because `Equatable` is: SwiftUI compares view values
    /// without promising the main actor. Only reference identity is read from
    /// `chat`, never its isolated state, so this is race-free.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.chat === rhs.chat
            && lhs.scrollAnchor === rhs.scrollAnchor
            && lhs.worktreePath == rhs.worktreePath
            && lhs.agentName == rhs.agentName
            && lhs.searchQuery == rhs.searchQuery
            && lhs.persistenceKey == rhs.persistenceKey
            && lhs.canFork == rhs.canFork
            && lhs.bottomInset == rhs.bottomInset
            && lhs.topInset == rhs.topInset
            && lhs.expandedActivityGroups == rhs.expandedActivityGroups
    }

    @State private var memo = TranscriptDisplay.Memo()

    var body: some View {
        TranscriptView(
            rows: displayRows,
            isBusy: chat.isBusy,
            agentName: agentName,
            searchQuery: searchQuery,
            worktreePath: worktreePath,
            persistenceKey: persistenceKey,
            onRevert: onRevert,
            onToggleActivity: onToggleActivity,
            onOpenFile: onOpenFile,
            onTurnAction: onTurnAction,
            canFork: canFork,
            // Passing the reference registers no observation — only the button
            // below reads `isAwayFromBottom`, so the transcript is not rebuilt
            // when the reader scrolls away.
            scrollAnchor: scrollAnchor,
            bottomInset: bottomInset,
            topInset: topInset,
            // Read after `displayRows` above, which is what bumps it.
            structureToken: memo.structureToken
        )
        // An NSViewRepresentable keeps its coordinator when only its inputs
        // change. Without an explicit conversation identity, switching tabs
        // reused the previous tab's scroll policy; if that reader had stopped
        // part-way up, the newly selected chat also opened part-way up even
        // though saved-offset restoration was disabled. A fresh coordinator
        // starts in bottom-following mode and also keeps row caches, pending
        // reloads, and scroll callbacks owned by the conversation that made
        // them.
        .id(persistenceKey)
    }

    private var displayRows: [TranscriptRow] {
        // The revision both pins observation and keys the memo: it is bumped by
        // every mutation of `chat.rows`, so an unchanged one means the derived
        // transcript cannot have changed either. Completed turns are reused
        // inside the memo so a live stream does not regroup history.
        _ = chat.plan
        return TranscriptDisplay.rows(
            from: chat.rows,
            keepLiveTurnExpanded: chat.isTurnActive,
            expanded: expandedActivityGroups,
            memo: memo,
            hidingPlanTurnID: {
                if case .proposal = chat.plan { return chat.planTurnID }
                return nil
            }(),
            revision: chat.rowsRevision,
            structuralRevision: chat.structuralRevision
        )
    }
}

/// Returns the reader to the newest output after they have scrolled up.
///
/// Only rendered while the transcript is actually scrolled away, which is what
/// keeps ⌘↓ out of the composer's way: with no button on screen there is no key
/// equivalent to claim, so the keystroke falls through to the text view's own
/// "move to end of document".
struct JumpToLatestButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(OreTheme.hairline))
                .overlay(Circle().fill(Color.primary.opacity(isHovered ? 0.06 : 0)))
                .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .keyboardShortcut(.downArrow, modifiers: .command)
        .help("Jump to latest (⌘↓)")
        .accessibilityLabel("Jump to latest")
    }
}

/// A small accent dot that breathes while an agent works, so a background tab
/// reads as "running" even after the sheen is dimmed by the tab's reduced
/// opacity.
private struct BusyTabDot: View {
    let reduceMotion: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        // Breathes in CoreAnimation (`PulsingDot`): a strip of busy tabs no
        // longer wakes the main thread twelve times a second per tab.
        PulsingDot(isAnimated: !reduceMotion, isPaused: controlActiveState != .key)
            .frame(width: 6, height: 6)
    }
}

/// Comments left on the diff, waiting to go out with the next message.
private struct DraftCommentsBar: View {
    let comments: [DiffCommentReference]
    var origin: String? = nil
    var horizontalPadding: CGFloat = OreTheme.Space.md
    let onRemove: (Int) -> Void
    let onClearAll: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let origin {
                    Text(origin)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .help("These comments were posted by the \(origin) button on this tab")
                }
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

                // A batch of chips deserves a batch exit — culling ten pending
                // comments one ✕ at a time was busywork.
                if comments.count > 1 {
                    Button("Clear all", action: onClearAll)
                        .buttonStyle(.link)
                        .font(.caption2)
                        .help("Remove every pending comment from this tab")
                }
            }
            .padding(.horizontal, horizontalPadding)
        }
        .frame(height: 28)
    }
}
