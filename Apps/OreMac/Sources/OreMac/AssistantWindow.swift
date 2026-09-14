import OreCore
import OrePersistence
import OreProtocol
import SwiftUI

/// The Assistant's activity window: the one surface where the hidden
/// assistant workspace is visible.
///
/// Deliberately not a `ChatPane` — there is no diff, no git action, no tab
/// bar. What the user needs here is an auditable record (what did it do, what
/// does it remember) and a composer to talk to it with until voice mode
/// arrives.
struct AssistantActivityView: View {
    @Environment(AppModel.self) private var model

    private enum Tab: String, CaseIterable {
        case activity = "Activity"
        case actions = "Actions"
        case memory = "Memory"
    }

    @State private var tab: Tab = .activity
    @State private var draft = ""
    @State private var expandedActivityGroups: Set<String> = []
    /// Owns the transcript's "jump to latest" affordance. Held here, like the
    /// chat pane's, so its identity survives every body pass — `TranscriptHost`
    /// compares it by reference.
    @State private var scrollAnchor = TranscriptScrollAnchor()
    @FocusState private var composerFocused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let assistant = model.assistantWorkspace, let chatID = model.assistantChatID {
                content(assistant: assistant, chatID: chatID)
            } else {
                ContentUnavailableView(
                    "The assistant is starting up",
                    systemImage: "sparkles",
                    description: Text("Its workspace appears here once ORE finishes loading.")
                )
            }
        }
        // The same smoked glass as the main window — this was the one room
        // still wearing the old opaque chrome, which read as a different app
        // the moment the two windows sat side by side.
        .preferredColorScheme(.dark)
        // And the same transparent title bar: without this the window kept an
        // opaque lid over its glass, which is most of why it still didn't
        // read as glass at all.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background {
            ZStack {
                OreWindowGlassBase()
                Color.black.opacity(0.22)
            }
            .ignoresSafeArea()
        }
        .frame(minWidth: 440, minHeight: 480)
    }

    private func content(assistant: WorkspaceSummary, chatID: ChatID) -> some View {
        let state = model.chat(for: chatID)
        // Resolved once. `chats(for:)` filters and sorts every summary in the
        // app, and this body used to call it three times per pass.
        let summary = model.chats(for: assistant.id).first { $0.id == chatID }
        return VStack(spacing: 0) {
            header(assistant: assistant, chatID: chatID, summary: summary, state: state)
            Divider()
            switch tab {
            case .activity:
                activity(
                    assistant: assistant, chatID: chatID, summary: summary, state: state
                )
            case .actions:
                AssistantAuditView()
            case .memory:
                AssistantMemoryView(
                    homePath: assistant.worktreePath,
                    reloadToken: summary?.turnCount ?? 0
                )
            }
        }
        // No opaque fill — the window's glass base shows through, exactly as
        // in the main window's conversation column.
        // Row caches belong to the conversation that built them. The draft
        // deliberately survives: a compaction switches conversations without
        // being asked, and destroying a half-typed question would be the user's
        // loss for ORE's housekeeping.
        .onChange(of: chatID) { _, _ in
            expandedActivityGroups = []
        }
    }

    private func header(
        assistant: WorkspaceSummary,
        chatID: ChatID,
        summary: ChatSummary?,
        state: ChatState
    ) -> some View {
        HStack(spacing: OreTheme.Space.md) {
            OreAppIcon(size: 22)
            conversationMenu(assistant: assistant, chatID: chatID, current: summary)
            HeaderStatus(harness: summary?.harness ?? .claudeCode, state: state)
            Spacer(minLength: OreTheme.Space.sm)
            TabPicker(tab: $tab)
        }
        .padding(.horizontal, OreTheme.Space.md)
        .frame(height: OreTheme.RowHeight.bar)
        // Every other bar in the app floats on the toolbar material; without it
        // this header fused into the content below it.
        .background(.bar)
    }

    /// The agent's live status beside the title. Its own view so a status or
    /// tool change redraws this label, not the whole window body above it.
    private struct HeaderStatus: View {
        let harness: HarnessKind
        let state: ChatState

        var body: some View {
            if state.status != .idle {
                // Humanized, like the chat pane's composer status. This used to
                // print the raw enum — the user was shown "runningTool".
                Text(ComposerBusyCopy.label(
                    harness: harness,
                    status: state.status,
                    runningToolLabel: state.runningToolLabel,
                    isStarting: false,
                    lastEventAt: nil,
                    now: Date()
                ))
                .font(.system(size: OreTheme.Font.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    /// The segmented tab switcher, isolated behind its binding. Rebuilt inline,
    /// every status or chat change re-created its tagged segments.
    private struct TabPicker: View {
        @Binding var tab: Tab

        var body: some View {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
        }
    }

    /// The title doubles as the conversation switcher. A window this narrow has
    /// no room for a tab bar, and the assistant is one conversation at a time
    /// by nature — the others are history, not parallel work.
    ///
    /// ORE starts and retires these on its own, so the user is never asked to
    /// keep count: there is no turn counter, and the list holds only what a
    /// person would call a conversation (see `AssistantConversationList`). A
    /// retired conversation is picked like any other — choosing it reopens it.
    private func conversationMenu(
        assistant: WorkspaceSummary,
        chatID: ChatID,
        current: ChatSummary?
    ) -> some View {
        let list = AssistantConversationList(
            model.chats(for: assistant.id, includeClosed: true), current: chatID
        )
        return Menu {
            Button("New Conversation") { model.createAssistantConversation() }
            if !list.recent.isEmpty {
                Divider()
                ForEach(list.recent) {
                    conversationButton($0, assistant: assistant, current: chatID)
                }
            }
            if !list.earlier.isEmpty {
                Menu("Earlier") {
                    ForEach(list.earlier) {
                        conversationButton($0, assistant: assistant, current: chatID)
                    }
                }
            }
        } label: {
            Text(current?.title ?? "Assistant")
                .font(.system(size: OreTheme.Font.body, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func conversationButton(
        _ conversation: ChatSummary,
        assistant: WorkspaceSummary,
        current: ChatID
    ) -> some View {
        Button {
            if conversation.isClosed { model.reopenChat(conversation.id, in: assistant.id) }
            model.selectChat(conversation.id, in: assistant.id)
        } label: {
            Label(
                conversation.title,
                systemImage: conversation.id == current ? "checkmark" : "bubble.left"
            )
        }
    }

    private func activity(
        assistant: WorkspaceSummary,
        chatID: ChatID,
        summary: ChatSummary?,
        state: ChatState
    ) -> some View {
        VStack(spacing: 0) {
            Group {
                if state.hasRows {
                    // The same `Equatable` host the main chat pane uses. Read
                    // its `==` before touching this: `state.rows` must not be
                    // read here, or every keystroke in the composer below
                    // re-derives and re-diffs the whole transcript.
                    TranscriptHost(
                        chat: state,
                        worktreePath: assistant.worktreePath,
                        agentName: summary?.harness.displayName ?? "ORE",
                        searchQuery: "",
                        persistenceKey: "assistant-\(chatID.rawValue)",
                        expandedActivityGroups: expandedActivityGroups,
                        canFork: false,
                        onRevert: { _ in },
                        onToggleActivity: { group in
                            if !expandedActivityGroups.insert(group).inserted {
                                expandedActivityGroups.remove(group)
                            }
                        },
                        onOpenFile: { _ in },
                        onTurnAction: { _, _ in },
                        scrollAnchor: scrollAnchor
                    )
                    .equatable()
                } else {
                    ContentUnavailableView(
                        "Ask about your work",
                        systemImage: "sparkles",
                        description: Text(
                            "Try “what's happening across my workspaces?” — everything "
                            + "the assistant does and remembers is auditable here."
                        )
                    )
                    .frame(maxHeight: .infinity)
                }
            }
            // The transcript rides the window's glass directly, exactly as the
            // main chat column does now.
            .layoutPriority(1)

            ForEach(model.assistantConfirmations) { confirmation in
                confirmationCard(confirmation)
                    .id(confirmation.id)
            }
            if let permission = state.pendingPermission {
                permissionCard(permission, workspaceID: assistant.id)
                    .id(permission.id)
            }
            if let question = state.pendingQuestion {
                questionCard(question, workspaceID: assistant.id)
                    .id(question.id)
            }
            needsYouStrip

            composer(assistant: assistant, chatID: chatID, state: state)
        }
        .overlay(alignment: .bottomLeading) { jumpToLatestOverlay }
    }

    @ViewBuilder
    private var jumpToLatestOverlay: some View {
        if scrollAnchor.isAwayFromBottom {
            JumpToLatestButton { scrollAnchor.jumpToBottom() }
                .padding(.leading, OreTheme.Space.md)
                .padding(.bottom, 76)
                .transition(.opacity)
        }
    }

    /// Project tabs blocked on the user, answerable without leaving here.
    ///
    /// The assistant already narrates these as "[ORE needs you]" — and until
    /// now the only thing the user could do about one from this window was
    /// read about it, then go hunting for the tab. The ask is the same ask the
    /// tab and the HUD are showing; resolving it in any of the three resolves
    /// it everywhere, because they all go through the same model call.
    @ViewBuilder
    private var needsYouStrip: some View {
        if !model.tabNeedsYou.isEmpty {
            // Bounded: this strip shares a narrow window with the transcript,
            // and a fleet that blocks on six things at once must not push the
            // conversation off screen. The overflow is one line, because the
            // main window is where a queue that long is actually worked.
            let shown = model.tabNeedsYou.prefix(Self.needsYouRowLimit)
            let overflow = model.tabNeedsYou.count - shown.count
            VStack(alignment: .leading, spacing: OreTheme.Space.sm) {
                Text("Waiting on you")
                    .font(.system(size: OreTheme.Font.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(shown) { item in
                    needsYouRow(item)
                }
                if overflow > 0 {
                    Text("and \(overflow) more in the main window")
                        .font(.system(size: OreTheme.Font.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardLayout()
        }
    }

    private static let needsYouRowLimit = 3

    @ViewBuilder
    private func needsYouRow(_ item: TabNeedsYou) -> some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.sm) {
            HStack(alignment: .top, spacing: OreTheme.Space.sm) {
                Image(systemName: needsYouSymbol(item))
                    .foregroundStyle(needsYouTint(item))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.headline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(placeLabel(item))
                        .font(.system(size: OreTheme.Font.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: OreTheme.Space.sm)
                Button("Open tab") { openTab(item) }
                    .buttonStyle(OreSecondaryButtonStyle())
                    .help("Bring \(placeLabel(item)) to the front")
            }
            HStack(spacing: OreTheme.Space.sm) {
                switch item {
                case .permission(let payload):
                    Button("Deny") {
                        model.resolvePermission(
                            payload.request.id,
                            decision: .deny(
                                reason: "The user denied this from the Assistant window."
                            ),
                            for: payload.workspaceID,
                            chatID: payload.chatID
                        )
                    }
                    .buttonStyle(OreSecondaryButtonStyle())
                    Button("Allow") {
                        model.resolvePermission(
                            payload.request.id,
                            decision: .allow,
                            for: payload.workspaceID,
                            chatID: payload.chatID
                        )
                    }
                    .buttonStyle(OrePrimaryButtonStyle())
                    ForEach(
                        Array(payload.request.suggestions.enumerated()), id: \.offset
                    ) { _, suggestion in
                        Button(suggestion.title) {
                            model.resolvePermission(
                                payload.request.id,
                                decision: .allowWithSuggestion(suggestion.raw),
                                for: payload.workspaceID,
                                chatID: payload.chatID
                            )
                        }
                    }

                case .question:
                    EmptyView()
                case .plan(let payload):
                    Button("Reject") {
                        model.respondToPlan(
                            chatID: payload.chatID,
                            workspaceID: payload.workspaceID,
                            approve: false
                        )
                    }
                    .buttonStyle(OreSecondaryButtonStyle())
                    Button("Approve") {
                        model.respondToPlan(
                            chatID: payload.chatID,
                            workspaceID: payload.workspaceID,
                            approve: true
                        )
                    }
                    .buttonStyle(OrePrimaryButtonStyle())
                }
                Spacer(minLength: 0)
            }
            // Questions get the app's option rows rather than a row of
            // buttons — every option, not the HUD's first two, because this
            // window has the height for them.
            if case .question(let payload) = item {
                QuestionOptionList(options: payload.question.options) { answer in
                    model.answerQuestion(
                        payload.question.id,
                        answer: answer,
                        for: payload.workspaceID,
                        chatID: payload.chatID
                    )
                }
                if payload.question.options.isEmpty {
                    Text("Open the tab to type an answer.")
                        .font(.system(size: OreTheme.Font.caption))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func openTab(_ item: TabNeedsYou) {
        model.reveal(workspaceID: item.workspaceID, chatID: item.chatID)
        openWindow(id: "main")
    }

    private func needsYouSymbol(_ item: TabNeedsYou) -> String {
        switch item {
        case .permission: "hand.raised.fill"
        case .question: "questionmark.circle.fill"
        case .plan: "checklist"
        }
    }

    private func needsYouTint(_ item: TabNeedsYou) -> Color {
        switch item {
        case .permission: .orange
        case .question: .accentColor
        case .plan: .purple
        }
    }

    private func placeLabel(_ item: TabNeedsYou) -> String {
        item.placeLabel(
            workspace: model.workspaces.first { $0.id == item.workspaceID }?.name,
            tab: model.chatSummaries.first { $0.id == item.chatID }?.title
        )
    }

    /// The assistant wants to do something consequential. "Allow for this
    /// task" is the default-prominent choice: a user who asked for the work
    /// shouldn't be re-asked for every step of it.
    private func confirmationCard(_ confirmation: AssistantConfirmation) -> some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.sm) {
            HStack(spacing: OreTheme.Space.sm) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                Text(confirmation.summary).fontWeight(.medium)
                Spacer()
            }
            HStack(spacing: OreTheme.Space.sm) {
                Button("Deny") {
                    model.resolveAssistantConfirmation(confirmation.id, decision: .deny)
                }
                .buttonStyle(OreSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                Spacer(minLength: OreTheme.Space.sm)
                Button("Once") {
                    model.resolveAssistantConfirmation(
                        confirmation.id, decision: .allow(.once)
                    )
                }
                .buttonStyle(OreSecondaryButtonStyle())
                Button("Allow for this task") {
                    model.resolveAssistantConfirmation(
                        confirmation.id, decision: .allow(.task)
                    )
                }
                .buttonStyle(OrePrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                Button("Always") {
                    model.resolveAssistantConfirmation(
                        confirmation.id, decision: .allow(.always)
                    )
                }
                .buttonStyle(OreSecondaryButtonStyle())
                .help("Never ask about \(confirmation.actionClass.displayName.lowercased()) again")
            }
        }
        .cardLayout()
    }

    private func permissionCard(
        _ permission: PermissionRequest,
        workspaceID: WorkspaceID
    ) -> some View {
        let content = PermissionPresentation(request: permission)
        return HStack(spacing: OreTheme.Space.md) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.action)
                    .fontWeight(.medium)
                // The command, path or URL — the same act the chat pane shows,
                // so answering here means answering the same question.
                if let target = content.target {
                    Text(target)
                        .font(.system(size: OreTheme.Font.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: OreTheme.Space.sm)
            Button("Deny") {
                model.resolvePermission(
                    permission.id,
                    decision: .deny(reason: "The user denied this in ORE."),
                    for: workspaceID
                )
            }
            .buttonStyle(OreSecondaryButtonStyle())
            .keyboardShortcut(.cancelAction)
            Button("Allow") {
                model.resolvePermission(permission.id, decision: .allow, for: workspaceID)
            }
            .buttonStyle(OrePrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .cardLayout()
    }

    private func questionCard(
        _ question: AgentQuestion,
        workspaceID: WorkspaceID
    ) -> some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.sm) {
            Text(question.prompt)
                .font(.system(size: OreTheme.Font.title, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            // The same rows the chat pane draws. As a row of plain buttons these
            // ran off the right edge of a 440pt window.
            QuestionOptionList(options: question.options) { answer in
                model.answerQuestion(question.id, answer: answer, for: workspaceID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardLayout()
    }

    private func composer(
        assistant: WorkspaceSummary,
        chatID: ChatID,
        state: ChatState
    ) -> some View {
        let isEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            if state.isBusy {
                Button {
                    model.interruptAssistant(chatID: chatID)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: OreTheme.Font.caption, weight: .medium))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: .command)
                .foregroundStyle(.secondary)
                .help("Stop the assistant (⌘.)")
            }
            HStack(alignment: .bottom, spacing: OreTheme.Space.sm) {
                TextField("Ask across all your projects…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: OreTheme.Font.prose))
                    // Up to eight lines, and Return inserts one. `onSubmit` used
                    // to send, which made a second paragraph impossible to type.
                    .lineLimit(1...8)
                    .focused($composerFocused)
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isEmpty)
                .help("Send (⌘↩)")
            }
            // The same surface the chat pane's composer uses, so the input box
            // is the progress indicator here too.
            .oreComposerSurface(padding: 10, isBusy: state.isBusy)
        }
        .padding(.horizontal, OreTheme.Space.md)
        .padding(.vertical, 10)
    }

    private func sendDraft() {
        guard let assistant = model.assistantWorkspace else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        model.send(text, to: assistant.id)
    }
}

private extension View {
    /// The card treatment shared by every decision surface in this window:
    /// material, one radius from the theme's family, a hairline, and the
    /// content width the rest of the app centres on. Replaces four different
    /// square, edge-to-edge colour washes.
    func cardLayout() -> some View {
        self
            .oreCard(padding: 12)
            .frame(maxWidth: OreTheme.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, OreTheme.Space.md)
            .padding(.top, OreTheme.Space.sm)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Every action the assistant has taken (or been refused), newest first.
/// Trust in an agent that acts for you is built on being able to check.
private struct AssistantAuditView: View {
    @Environment(AppModel.self) private var model
    @State private var actions: [AssistantActionRecord] = []
    @State private var alwaysGrants: [String] = []
    @State private var tabGrantIDs: [ChatID] = []

    var body: some View {
        VStack(spacing: 0) {
            if !alwaysGrants.isEmpty || !tabGrantIDs.isEmpty {
                grants
                Divider()
            }
            auditList
        }
        .task { await reload() }
        .onChange(of: model.assistantConfirmations.count) { _, _ in
            Task { await reload() }
        }
    }

    private var grants: some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.sm) {
            Text("Standing permissions")
                .font(.system(size: OreTheme.Font.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(alwaysGrants, id: \.self) { grant in
                HStack {
                    Text(AssistantActionClass(rawValue: grant)?.displayName ?? grant)
                    Spacer()
                    Button("Revoke") {
                        model.revokeAssistantAlwaysGrant(grant)
                        Task { await reload() }
                    }
                    .controlSize(.small)
                }
            }
            ForEach(tabGrantIDs, id: \.rawValue) { chatID in
                HStack {
                    Text(tabGrantLabel(chatID))
                    Spacer()
                    Button("Revoke") {
                        model.revokeTabAutoAllow(chatID)
                        Task { await reload() }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(OreTheme.Space.md)
    }

    private var auditList: some View {
        Group {
            if actions.isEmpty {
                ContentUnavailableView(
                    "No actions yet",
                    systemImage: "checklist",
                    description: Text("Everything the assistant does on your behalf is recorded here.")
                )
            } else {
                List(actions, id: \.id) { action in
                    HStack(alignment: .top, spacing: OreTheme.Space.md) {
                        Image(systemName: symbol(for: action.decision))
                            .foregroundStyle(tint(for: action.decision))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.summary)
                            Text(decisionLabel(action.decision))
                                .font(.system(size: OreTheme.Font.caption))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(action.createdAt.formatted(.relative(presentation: .named)))
                            .font(.system(size: OreTheme.Font.caption))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .background(OreListScrollerOverlay())
            }
        }
    }

    private func reload() async {
        actions = await model.assistantAuditActions()
        alwaysGrants = (try? await model.assistantAlwaysGrantNames()) ?? []
        tabGrantIDs = (try? await model.assistantTabGrantIDs()) ?? []
    }

    private func tabGrantLabel(_ chatID: ChatID) -> String {
        if let chat = model.chatSummaries.first(where: { $0.id == chatID }) {
            return "Auto-allow “\(chat.title)”"
        }
        return "Auto-allow a tab"
    }

    private func symbol(for decision: String) -> String {
        if decision == "denied" || decision == "timedOut" { return "xmark.circle" }
        if decision == "failed" { return "exclamationmark.triangle" }
        return "checkmark.circle"
    }

    private func tint(for decision: String) -> Color {
        if decision == "denied" || decision == "timedOut" { return .secondary }
        if decision == "failed" { return .orange }
        return .green
    }

    private func decisionLabel(_ decision: String) -> String {
        switch decision {
        case "auto": "Ran automatically"
        case "allowed:once": "You allowed it"
        case "allowed:task", "granted:task": "Covered by a task approval"
        case "allowed:always", "granted:always": "Always allowed"
        case "denied": "You declined"
        case "timedOut": "Timed out unanswered"
        case "failed": "Failed"
        default: decision
        }
    }
}

/// Read-only view of the assistant's memory files. The assistant writes them;
/// the user audits them. Editing belongs in a conversation ("forget that"),
/// not a text editor racing the agent.
private struct AssistantMemoryView: View {
    let homePath: String
    /// Changes once per assistant turn. The assistant writes these files
    /// through its MCP process, which the app never sees, so a turn boundary is
    /// the cheapest honest signal that the list may be stale.
    let reloadToken: Int

    private struct MemoryFile: Identifiable, Sendable {
        let id: String
        let name: String
        let url: URL
    }

    @State private var files: [MemoryFile] = []
    @State private var selectedID: String?
    @State private var contents = ""

    var body: some View {
        HSplitView {
            List(files, selection: $selectedID) { file in
                Label(file.name, systemImage: "doc.text")
                    .tag(file.id)
            }
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .background(OreListScrollerOverlay())
            .frame(minWidth: 150, idealWidth: 180, maxWidth: 240)

            ScrollView {
                // Deliberately raw and monospaced: this pane exists so the user
                // can audit exactly what the assistant wrote to disk, and
                // rendering the markdown would hide the syntax it wrote.
                Text(contents.isEmpty ? "Empty." : contents)
                    .font(.system(size: OreTheme.Font.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(OreTheme.Space.md)
            }
            .scrollIndicators(.hidden)
            // Raw memory files are a reading surface: mostly paper, the same
            // bargain the diff documents strike over the glass.
            .background(OreTheme.Surface.content.opacity(0.85))
        }
        // Re-listed whenever the assistant acts: it writes these files while
        // this tab is open, and a list loaded once goes stale in front of the
        // user. Directory enumeration and the file reads happen off the main
        // actor — they used to block it from inside `body`'s `.task`.
        .task(id: reloadToken) { await load() }
        .task(id: selectedID) { await loadSelection() }
    }

    private func load() async {
        let home = URL(fileURLWithPath: homePath)
        let found = await Self.listFiles(home: home)
        files = found
        if selectedID == nil || !found.contains(where: { $0.id == selectedID }) {
            selectedID = found.first?.id
        }
        await loadSelection()
    }

    private func loadSelection() async {
        guard let file = files.first(where: { $0.id == selectedID }) else {
            contents = ""
            return
        }
        contents = await Self.read(file.url)
    }

    private static func listFiles(home: URL) async -> [MemoryFile] {
        await Task.detached(priority: .userInitiated) {
            var found = [MemoryFile(
                id: "MEMORY.md",
                name: "MEMORY.md",
                url: home.appendingPathComponent("MEMORY.md")
            )]
            let directory = home.appendingPathComponent("memory", isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? []
            for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where url.pathExtension == "md" {
                found.append(MemoryFile(
                    id: "memory/\(url.lastPathComponent)",
                    name: url.lastPathComponent,
                    url: url
                ))
            }
            return found
        }.value
    }

    private static func read(_ url: URL) async -> String {
        await Task.detached(priority: .userInitiated) {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }.value
    }
}
