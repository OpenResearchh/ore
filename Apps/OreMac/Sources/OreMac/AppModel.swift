import AppKit
import Foundation
import Observation
import OreCore
import OreGit
import OrePersistence
import OreProtocol
import UserNotifications

/// The app's view state.
///
/// One `@Observable` object holding what every surface reads. It is the only
/// thing in the app that talks to the core: views send commands through it and
/// read state from it, so there is exactly one place where the boundary is
/// crossed and exactly one ordering of updates.
@MainActor
@Observable
final class AppModel {
    private(set) var workspaces: [WorkspaceSummary] = []
    private(set) var harnesses: [HarnessProbeResult] = []
    private(set) var modelCatalog: [HarnessKind: [AgentModel]] = [:]
    private(set) var repositories: [String] = []
    private(set) var isLoaded = false

    var selectedWorkspaceID: WorkspaceID? {
        didSet {
            guard selectedWorkspaceID != oldValue else { return }
            focusChanged(from: oldValue, to: selectedWorkspaceID)
        }
    }

    private(set) var chatSummaries: [ChatSummary] = []
    /// Live transcript state is keyed by durable chat identity, never by
    /// workspace: several tabs in one worktree can stream concurrently.
    private(set) var chatStates: [ChatID: ChatState] = [:]
    private(set) var activeChatIDs: [WorkspaceID: ChatID] = [:]
    /// Files opened as diff tabs in the centre column, per workspace, and which
    /// one is showing. When `activeFilePath[workspace]` is nil the centre shows
    /// the active chat; when it's set, it shows that file's diff instead. This
    /// is what lets the review list (on the right) open a diff as a centre tab.
    private(set) var openFilePaths: [WorkspaceID: [String]] = [:]
    private(set) var activeFilePath: [WorkspaceID: String] = [:]
    private(set) var filePresentationModes: [WorkspaceID: [String: FilePresentationMode]] = [:]
    private(set) var banners: [Banner] = []

    /// Cached workspace diffs so switching back to a worktree — or opening the
    /// review pane right after selecting one — paints instantly instead of
    /// waiting on a cold `git diff`. Keyed by workspace and stamped with the
    /// git-status generation it was computed against, so a stale entry is shown
    /// immediately while a fresh one loads in the background.
    struct DiffSnapshot {
        var generation: UInt64
        var diffs: [FileDiff]
        var gitAction: SuggestedGitAction
    }
    private(set) var diffCache: [WorkspaceID: DiffSnapshot] = [:]

    private let client: InProcessCoreClient
    private var eventTask: Task<Void, Never>?
    /// Batches streaming deltas so a fast model can't drive the transcript's
    /// layout at the rate the tokens arrive.
    private var coalescers: [ChatID: TextDeltaCoalescer] = [:]
    private var chatOwners: [ChatID: WorkspaceID] = [:]
    private var pendingNewChatMessages: [WorkspaceID: [String]] = [:]
    /// Draft text to drop into a chat that hasn't been published yet, so Commit
    /// / Create PR can open a tab without sending until the user hits return.
    private var pendingNewChatDrafts: [WorkspaceID: [String]] = [:]
    /// Signals the visible composer to pick up a draft written from outside
    /// (toolbar Commit / Create PR) without waiting for a tab switch.
    private(set) var composerInjection: ComposerInjection?

    struct ComposerInjection: Equatable {
        let chatID: ChatID
        let text: String
        let generation: UInt64
    }
    private var composerInjectionGeneration: UInt64 = 0
    private var identityRenamesInFlight: Set<WorkspaceID> = []
    private var chatRenamesInFlight: Set<ChatID> = []
    private(set) var chatCreationsInFlight: Set<WorkspaceID> = []
    private var flushTask: Task<Void, Never>?

    struct Banner: Identifiable, Sendable {
        let id = UUID()
        var message: String
        var detail: String?
    }

    init(client: InProcessCoreClient) {
        self.client = client
    }

    // MARK: - Lifecycle

    func start() {
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in await self.client.events {
                await self.apply(event)
            }
        }
        Task {
            try? await client.start()
            await refreshRepositories()
            isLoaded = true
        }
        startFlushTimer()
        restoreScheduledContinuations()
        NotificationCenter.default.addObserver(
            forName: .oreOpenFromNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let workspace = notification.userInfo?["workspaceID"] as? String
            let chat = notification.userInfo?["chatID"] as? String
            Task { @MainActor in
                self?.openFromNotification(workspaceID: workspace, chatID: chat)
            }
        }
    }

    /// Flushes coalesced deltas at ~40Hz.
    ///
    /// The transcript is the app's hottest surface, and every delta that
    /// reaches it costs a layout pass. Batching at a fixed cadence decouples
    /// rendering cost from token rate.
    private func startFlushTimer() {
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
                guard let self else { return }
                self.flushCoalescedDeltas()
            }
        }
    }

    private func flushCoalescedDeltas() {
        for chatID in Array(coalescers.keys) {
            guard var coalescer = coalescers[chatID], coalescer.hasPendingDeltas else { continue }
            guard let workspaceID = chatOwners[chatID] else { continue }
            for event in coalescer.flush() {
                applyToChat(workspaceID: workspaceID, chatID: chatID, event: event)
            }
            coalescers[chatID] = coalescer
        }
    }

    func shutdown() async {
        eventTask?.cancel()
        flushTask?.cancel()
        for task in continuationTasks.values { task.cancel() }
        continuationTasks.removeAll()
        await client.shutdown()
    }

    // MARK: - Reading

    var selectedWorkspace: WorkspaceSummary? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    var selectedChat: ChatState? {
        selectedChatSummary.map { chat(for: $0.id) }
    }

    var selectedChatSummary: ChatSummary? {
        guard let workspaceID = selectedWorkspaceID else { return nil }
        return activeChat(for: workspaceID)
    }

    func chats(for workspaceID: WorkspaceID, includeClosed: Bool = false) -> [ChatSummary] {
        chatSummaries
            .filter { $0.workspaceID == workspaceID && (includeClosed || !$0.isClosed) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func activeChat(for workspaceID: WorkspaceID) -> ChatSummary? {
        let open = chats(for: workspaceID)
        if let id = activeChatIDs[workspaceID], let chat = open.first(where: { $0.id == id }) {
            return chat
        }
        return open.first
    }

    func chat(for id: ChatID) -> ChatState {
        if let existing = chatStates[id] { return existing }
        let state = ChatState()
        state.draftAttachments = Self.loadDraftAttachments(for: id)
        chatStates[id] = state
        Task { await loadHistory(for: id) }
        return state
    }

    func chat(for workspaceID: WorkspaceID) -> ChatState {
        guard let id = activeChat(for: workspaceID)?.id else { return ChatState() }
        return chat(for: id)
    }

    /// Rebuilds a workspace's transcript from storage.
    ///
    /// The persisted form is turns and blocks; the UI wants a flat list of
    /// rows. Doing the conversion here — rather than storing rows — keeps the
    /// database shaped like the domain rather than like this particular view.
    private func loadHistory(for id: ChatID) async {
        let state = chat(for: id)
        guard !state.hasLoadedHistory else { return }
        guard let turns = try? await client.transcript(chatID: id) else { return }

        var rows: [TranscriptRow] = []
        for turn in turns {
            let turnID = turn.turnID
            if let prompt = turn.prompt, !prompt.isEmpty {
                rows.append(TranscriptRow(
                    id: "prompt-\(turn.id)",
                    turnID: turnID,
                    kind: .userMessage,
                    text: prompt,
                    isComplete: true,
                    attachments: turn.attachments,
                    createdAt: turn.startedAt
                ))
            }

            guard let blocks = try? await client.blocks(turnID: turnID) else { continue }
            for block in blocks {
                if block.blockKind == .toolResult,
                   let rawID = block.toolCallID,
                   let index = rows.lastIndex(where: { $0.toolCallID?.rawValue == rawID }) {
                    rows[index].resultText = block.text
                    rows[index].isError = block.isError
                    rows[index].isComplete = true
                    continue
                }
                guard let row = Self.row(from: block, turnID: turnID) else { continue }
                rows.append(row)
            }
        }
        if let transitions = try? await client.chatTransitions(chatID: id) {
            for transition in transitions {
                rows.append(TranscriptRow(
                    id: "transition-\(transition.id)",
                    turnID: TurnID(rawValue: "transition"),
                    kind: .divider,
                    text: transition.displayText,
                    isComplete: true,
                    createdAt: transition.createdAt
                ))
            }
        }
        rows.sort { $0.createdAt < $1.createdAt }
        state.loadHistory(rows)
        if let workspaceID = chatOwners[id],
           let comments = try? await client.pendingDiffComments(workspaceID: workspaceID) {
            for comment in comments where !state.draftComments.contains(comment) {
                state.addDraftComment(comment)
            }
        }
    }

    private static func row(
        from block: BlockRecord,
        turnID: TurnID
    ) -> TranscriptRow? {
        switch block.blockKind {
        case .text:
            return TranscriptRow(
                id: block.id, turnID: turnID, kind: .assistantText,
                text: block.text,
                parentToolCallID: block.parentToolCallID.map(ToolCallID.init(rawValue:)),
                isComplete: true, createdAt: block.createdAt
            )
        case .thinking:
            return TranscriptRow(
                id: block.id, turnID: turnID, kind: .thinking,
                text: block.text,
                parentToolCallID: block.parentToolCallID.map(ToolCallID.init(rawValue:)),
                isComplete: true, createdAt: block.createdAt
            )
        case .toolCall:
            // Restore the subagent link so a reloaded transcript nests each
            // Task's tool uses under it, exactly as a live one does.
            return TranscriptRow(
                id: block.id, turnID: turnID, kind: .toolCall,
                text: block.text, toolName: block.toolName,
                toolCallID: block.toolCallID.map(ToolCallID.init(rawValue:)),
                parentToolCallID: block.parentToolCallID.map(ToolCallID.init(rawValue:)),
                toolInput: block.decodedPayload,
                isComplete: true, createdAt: block.createdAt
            )
        case .toolResult:
            // Results are folded into the call they belong to, the same way a
            // live session shows them.
            return nil
        case .plan:
            return TranscriptRow(
                id: block.id, turnID: turnID, kind: .plan,
                text: block.text, isComplete: true, createdAt: block.createdAt
            )
        case .permission, .question:
            // Both are resolved by the time history is read; replaying them
            // would show a prompt nobody can answer.
            return nil
        case .notice:
            return TranscriptRow(
                id: block.id, turnID: turnID, kind: .divider,
                text: block.text, isComplete: true, createdAt: block.createdAt
            )
        }
    }

    /// Sidebar order: pinned first, then anything that needs attention, then
    /// by recency. "Needs me" outranks "was recent" because that is the
    /// question the sidebar exists to answer.
    var sortedWorkspaces: [WorkspaceSummary] {
        workspaces
            .filter { !$0.isArchived }
            .sorted { first, second in
                if first.isPinned != second.isPinned { return first.isPinned }
                if first.needsAttention != second.needsAttention { return first.needsAttention }
                return (first.lastActivity ?? .distantPast) > (second.lastActivity ?? .distantPast)
            }
    }

    var archivedWorkspaces: [WorkspaceSummary] {
        workspaces.filter(\.isArchived)
    }

    var attentionCount: Int {
        workspaces.filter { !$0.isArchived && $0.needsAttention }.count
    }

    // MARK: - Commands

    func addRepository(path: String) {
        Task { await client.send(.addRepository(path: path)) }
    }

    func createWorkspace(_ request: CreateWorkspaceRequest) {
        var request = request
        if request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.name = suggestedResearchIdentity().name
        }
        Task { await client.send(.createWorkspace(request)) }
    }

    /// The ⌘N action: spin up a fresh worktree in the same repository as the
    /// active tab, seeded from the default branch and inheriting its harness and
    /// model, without stopping to fill out the picker. Falls back to the picker
    /// (via `nil` return) when there's no active workspace to borrow a project
    /// from. ⇧⌘N still opens the full `NewWorkspaceSheet`.
    @discardableResult
    func createWorktreeInCurrentProject() -> Bool {
        guard let source = selectedWorkspace else { return false }
        createWorkspace(CreateWorkspaceRequest(
            repositoryPath: source.repositoryPath,
            name: suggestedResearchIdentity().name,
            seed: .defaultBranch,
            harness: source.harness,
            model: source.model,
            initialPrompt: nil,
            branchPrefix: UserDefaults.standard.string(forKey: "ore.branchPrefix")
        ))
        return true
    }

    func send(
        _ text: String,
        attachments: [Attachment] = [],
        effort: ReasoningEffort? = nil,
        serviceTier: String? = nil,
        to id: WorkspaceID
    ) {
        guard let chatID = activeChat(for: id)?.id else { return }
        send(text, attachments: attachments, effort: effort, serviceTier: serviceTier, to: id, chatID: chatID)
    }

    private func send(
        _ text: String,
        attachments: [Attachment] = [],
        effort: ReasoningEffort? = nil,
        serviceTier: String? = nil,
        to id: WorkspaceID,
        chatID: ChatID
    ) {
        let state = chat(for: chatID)
        let comments = state.takeDraftComments()
        cancelScheduledContinuation(for: chatID)
        persistDraftAttachments([], for: chatID)
        state.appendUserMessage(text, attachments: attachments, comments: comments)
        Task {
            await client.send(.sendMessage(SendMessageRequest(
                workspaceID: id,
                chatID: chatID,
                text: text,
                attachments: attachments,
                diffComments: comments,
                reasoningEffort: effort,
                serviceTier: serviceTier
            )))
        }
    }

    func interrupt(_ id: WorkspaceID) {
        guard let chatID = activeChat(for: id)?.id else { return }
        Task { await client.send(.interruptChatTurn(id, chatID)) }
    }

    func setPermissionMode(_ mode: PermissionMode, for id: WorkspaceID) {
        guard let chatID = activeChat(for: id)?.id else { return }
        Task { await client.send(.setChatPermissionMode(id, chatID, mode)) }
    }

    func resolvePermission(
        _ requestID: PermissionRequestID,
        decision: PermissionDecision,
        for id: WorkspaceID
    ) {
        guard let chatID = activeChat(for: id)?.id else { return }
        chat(for: chatID).resolvePermission(requestID)
        Task { await client.send(.resolveChatPermission(id, chatID, requestID, decision)) }
    }

    func answerQuestion(_ questionID: QuestionID, answer: String, for id: WorkspaceID) {
        guard let chatID = activeChat(for: id)?.id else { return }
        chat(for: chatID).resolveQuestion(questionID)
        Task { await client.send(.answerChatQuestion(id, chatID, questionID, answer: answer)) }
    }

    /// Answer a permission-gated question (Claude's AskUserQuestion) by returning
    /// the answer *through* the tool-permission reply, which both delivers it as
    /// the tool result and unblocks the turn — instead of allowing the tool (an
    /// empty answer) and racing a separate, droppable user message.
    func answerQuestion(
        _ questionID: QuestionID,
        viaPermission permissionID: PermissionRequestID,
        answer: String,
        for id: WorkspaceID
    ) {
        guard let chatID = activeChat(for: id)?.id else { return }
        chat(for: chatID).resolveQuestion(questionID)
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmed.isEmpty
            ? "The user dismissed the question without choosing; continue."
            : "The user answered your question: \"\(trimmed)\". Continue with this answer in mind."
        resolvePermission(permissionID, decision: .deny(reason: message), for: id)
    }

    func revert(to turnID: TurnID, in id: WorkspaceID) {
        guard let chatID = activeChat(for: id)?.id else { return }
        Task { await client.send(.revertChatToCheckpoint(id, chatID, turnID)) }
    }

    func createChat(
        in workspaceID: WorkspaceID,
        initialMessage: String? = nil,
        draft: String? = nil,
        defaults: ChatDefaults? = nil,
        model: String? = nil
    ) {
        if let initialMessage {
            pendingNewChatMessages[workspaceID, default: []].append(initialMessage)
        }
        if let draft {
            // Latest click wins if a tab is already spinning up.
            pendingNewChatDrafts[workspaceID] = [draft]
        }
        guard chatCreationsInFlight.insert(workspaceID).inserted else { return }
        // A new conversation is a chat destination even when it was invoked
        // while reading a source tab. Keep the existing chat visible until the
        // core publishes the new one, then switch in one atomic event.
        showChatInCenter(workspaceID)
        let workspace = workspaces.first { $0.id == workspaceID }
        let usedTitles = Set(chats(for: workspaceID, includeClosed: true).map(\.title))
        let title = ResearchIdentity.nextResearchTitle(
            excluding: usedTitles,
            preferred: workspace.flatMap(researchIdentity(for:))
        )
        let resolved = defaults ?? newChatDefaults(for: workspaceID)
        Task { await client.send(.createChat(CreateChatRequest(
            workspaceID: workspaceID,
            title: title,
            harness: resolved.harness,
            model: model ?? resolved.model,
            permissionMode: workspace?.permissionMode ?? .default
        ))) }
    }

    /// Branches the active chat into a new tab.
    ///
    /// The new tab resumes the same provider session with a fork, so the agent
    /// still remembers the conversation while the original tab keeps its own
    /// copy — two directions from one point, rather than a choice between them.
    func forkChat(into workspaceID: WorkspaceID) {
        guard let source = activeChat(for: workspaceID),
              chatCreationsInFlight.insert(workspaceID).inserted else { return }
        showChatInCenter(workspaceID)
        let used = Set(chats(for: workspaceID, includeClosed: true).map(\.title))
        Task { await client.send(.createChat(CreateChatRequest(
            workspaceID: workspaceID,
            title: ResearchIdentity.unique("\(source.title) (fork)", excluding: used),
            harness: source.harness,
            model: source.model,
            permissionMode: source.permissionMode,
            forkFrom: source.id
        ))) }
    }

    func selectChat(_ chatID: ChatID, in workspaceID: WorkspaceID) {
        let previous = activeChatIDs[workspaceID]
        activeChatIDs[workspaceID] = chatID
        UserDefaults.standard.set(chatID.rawValue, forKey: "ore.activeChat.\(workspaceID.rawValue)")
        _ = chat(for: chatID)
        Task {
            if let previous {
                try? await client.setFocused(workspaceID: workspaceID, chatID: previous, focused: false)
            }
            try? await client.setFocused(workspaceID: workspaceID, chatID: chatID, focused: true)
        }
    }

    func closeChat(_ chatID: ChatID, in workspaceID: WorkspaceID) {
        // Pick the neighbor before the close lands, so the UI never flashes
        // the first remaining tab via `activeChat`'s fallback.
        if let replacement = TabCloseSelection.replacement(
            closing: chatID,
            active: activeChat(for: workspaceID)?.id,
            open: chats(for: workspaceID).map(\.id)
        ) {
            selectChat(replacement, in: workspaceID)
        }
        Task { await client.send(.closeChat(workspaceID, chatID)) }
    }

    /// A tab whose agent is still working, staged for a confirmation prompt
    /// before it is actually closed. Presented by the visible `ChatPane`.
    struct PendingChatClose: Identifiable {
        let workspaceID: WorkspaceID
        let chatID: ChatID
        let title: String
        var id: ChatID { chatID }
    }

    var pendingChatClose: PendingChatClose?

    /// Close a chat, but if its agent is mid-turn, stage a confirmation instead
    /// of tearing the conversation down from under a running turn.
    func requestCloseChat(_ chatID: ChatID, in workspaceID: WorkspaceID, title: String) {
        if chat(for: chatID).isBusy {
            pendingChatClose = PendingChatClose(
                workspaceID: workspaceID, chatID: chatID, title: title
            )
        } else {
            closeChat(chatID, in: workspaceID)
        }
    }

    func renameChat(
        _ chatID: ChatID,
        in workspaceID: WorkspaceID,
        to title: String,
        userInitiated: Bool = true
    ) {
        Task {
            await client.send(.renameChat(
                workspaceID, chatID, title: title, userInitiated: userInitiated
            ))
        }
    }

    // MARK: - Centre diff tabs

    /// Opens (or re-focuses) a file's diff as a tab in the centre column.
    func openDiffFile(_ path: String, in workspaceID: WorkspaceID) {
        openFile(path, in: workspaceID, mode: .diff)
    }

    /// A line to reveal when a file opens, from a `file.py:711`-style reference.
    /// The token forces a re-scroll even when the same line is requested twice.
    struct FileFocus: Equatable {
        var line: Int
        var token: Int
    }
    private(set) var fileFocus: [WorkspaceID: [String: FileFocus]] = [:]
    private var fileFocusToken = 0

    func openSourceFile(_ path: String, in workspaceID: WorkspaceID, line: Int? = nil) {
        if let line {
            fileFocusToken += 1
            fileFocus[workspaceID, default: [:]][path] = FileFocus(line: line, token: fileFocusToken)
        }
        openFile(path, in: workspaceID, mode: .source)
    }

    private func openFile(_ path: String, in workspaceID: WorkspaceID, mode: FilePresentationMode) {
        var files = openFilePaths[workspaceID] ?? []
        if !files.contains(path) {
            files.append(path)
            openFilePaths[workspaceID] = files
        }
        filePresentationModes[workspaceID, default: [:]][path] = mode
        activeFilePath[workspaceID] = path
    }

    func setFilePresentationMode(_ mode: FilePresentationMode, path: String, in workspaceID: WorkspaceID) {
        filePresentationModes[workspaceID, default: [:]][path] = mode
    }

    func selectDiffFile(_ path: String, in workspaceID: WorkspaceID) {
        activeFilePath[workspaceID] = path
    }

    func closeDiffFile(_ path: String, in workspaceID: WorkspaceID) {
        var files = openFilePaths[workspaceID] ?? []
        files.removeAll { $0 == path }
        openFilePaths[workspaceID] = files
        filePresentationModes[workspaceID]?[path] = nil
        if activeFilePath[workspaceID] == path {
            // Fall back to the last remaining file tab, else the chat.
            activeFilePath[workspaceID] = files.last
        }
    }

    /// Switches the centre back to the chat transcript (a chat tab was picked).
    func showChatInCenter(_ workspaceID: WorkspaceID) {
        activeFilePath[workspaceID] = nil
    }

    func reopenChat(_ chatID: ChatID, in workspaceID: WorkspaceID) {
        Task { await client.send(.reopenChat(workspaceID, chatID)) }
    }

    func switchHarness(_ harness: HarnessKind, model selectedModel: String?, for chat: ChatSummary) {
        Task { await client.send(.switchChatHarness(
            chat.workspaceID, chat.id, harness: harness, model: selectedModel
        )) }
    }

    func setModel(_ selectedModel: String?, for chat: ChatSummary) {
        Task { await client.send(.setChatModel(chat.workspaceID, chat.id, model: selectedModel)) }
    }

    func setDraft(_ text: String, for chat: ChatSummary) {
        upsertChat({ var copy = chat; copy.draftText = text; return copy }())
        Task { await client.send(.setChatDraft(chat.workspaceID, chat.id, text: text)) }
    }

    func persistDraftAttachments(_ attachments: [Attachment], for chatID: ChatID) {
        chat(for: chatID).draftAttachments = attachments
        let key = Self.draftAttachmentsKey(for: chatID)
        if attachments.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(attachments) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func loadDraftAttachments(for chatID: ChatID) -> [Attachment] {
        let key = draftAttachmentsKey(for: chatID)
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Attachment].self, from: data)) ?? []
    }

    private static func draftAttachmentsKey(for chatID: ChatID) -> String {
        "ore.draftAttachments.\(chatID.rawValue)"
    }

    // MARK: - Scheduled continuation after usage limits

    private(set) var scheduledContinuations: [ChatID: ScheduledContinuation] = [:]
    private var continuationTasks: [ChatID: Task<Void, Never>] = [:]

    func scheduledContinuation(for chatID: ChatID?) -> ScheduledContinuation? {
        guard let chatID else { return nil }
        return scheduledContinuations[chatID]
    }

    func scheduleContinuation(
        workspaceID: WorkspaceID,
        chatID: ChatID,
        resumeAt: Date,
        prompt: String = ScheduledContinuation.defaultPrompt
    ) {
        let item = ScheduledContinuation(
            workspaceID: workspaceID,
            chatID: chatID,
            resumeAt: resumeAt,
            prompt: prompt
        )
        scheduledContinuations[chatID] = item
        persistScheduledContinuations()
        arm(item)
        scheduleContinuationNotification(item)
    }

    func cancelScheduledContinuation(for chatID: ChatID) {
        continuationTasks[chatID]?.cancel()
        continuationTasks[chatID] = nil
        scheduledContinuations[chatID] = nil
        persistScheduledContinuations()
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.continuationNotificationID(for: chatID)])
    }

    private func restoreScheduledContinuations() {
        guard let data = UserDefaults.standard.data(forKey: "ore.scheduledContinuations"),
              let items = try? JSONDecoder().decode([ScheduledContinuation].self, from: data)
        else { return }
        for item in items {
            scheduledContinuations[item.chatID] = item
            arm(item)
        }
    }

    private func persistScheduledContinuations() {
        let items = Array(scheduledContinuations.values)
        if items.isEmpty {
            UserDefaults.standard.removeObject(forKey: "ore.scheduledContinuations")
        } else if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: "ore.scheduledContinuations")
        }
    }

    private func arm(_ item: ScheduledContinuation) {
        continuationTasks[item.chatID]?.cancel()
        continuationTasks[item.chatID] = Task { [weak self] in
            let delay = item.resumeAt.timeIntervalSinceNow
            if delay > 0 {
                // A short buffer so the provider has actually opened the window
                // before we send, rather than racing the reset second.
                try? await Task.sleep(for: .seconds(delay + 15))
            }
            guard !Task.isCancelled else { return }
            await self?.fireScheduledContinuation(item)
        }
    }

    private func fireScheduledContinuation(_ item: ScheduledContinuation) async {
        guard scheduledContinuations[item.chatID]?.resumeAt == item.resumeAt else { return }
        scheduledContinuations[item.chatID] = nil
        continuationTasks[item.chatID] = nil
        persistScheduledContinuations()
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.continuationNotificationID(for: item.chatID)])

        selectedWorkspaceID = item.workspaceID
        selectChat(item.chatID, in: item.workspaceID)
        showChatInCenter(item.workspaceID)
        NSApp.activate(ignoringOtherApps: true)
        send(item.prompt, to: item.workspaceID, chatID: item.chatID)
        postNotification(
            title: "Continuing \(workspaceName(item.workspaceID))",
            body: "Session limit reset. Picking up where you left off.",
            workspaceID: item.workspaceID,
            chatID: item.chatID
        )
    }

    private func scheduleContinuationNotification(_ item: ScheduledContinuation) {
        let content = UNMutableNotificationContent()
        content.title = "Session limit reset"
        content.body = "Continuing \(workspaceName(item.workspaceID)) where you left off."
        if UserDefaults.standard.object(forKey: "ore.notifications.sound") as? Bool ?? true {
            content.sound = .default
        }
        content.userInfo = [
            "workspaceID": item.workspaceID.rawValue,
            "chatID": item.chatID.rawValue,
        ]
        let interval = max(item.resumeAt.timeIntervalSinceNow + 15, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: Self.continuationNotificationID(for: item.chatID),
            content: content,
            trigger: trigger
        ))
    }

    private static func continuationNotificationID(for chatID: ChatID) -> String {
        "ore.continue.\(chatID.rawValue)"
    }

    func cycleChat(in workspaceID: WorkspaceID, offset: Int) {
        let tabs = chats(for: workspaceID)
        guard tabs.count > 1 else { return }
        let current = activeChat(for: workspaceID)?.id
        let index = tabs.firstIndex { $0.id == current } ?? 0
        let next = (index + offset + tabs.count) % tabs.count
        selectChat(tabs[next].id, in: workspaceID)
    }

    func archive(_ id: WorkspaceID) {
        Task { await client.send(.archiveWorkspace(id)) }
    }

    /// A workspace staged for the archive confirmation dialog. Confirming
    /// calls `archive(_:)`; the dialog explains what archiving preserves.
    struct PendingArchive: Identifiable {
        let workspace: WorkspaceSummary
        var id: WorkspaceID { workspace.id }
    }

    var pendingArchive: PendingArchive?

    /// Archive is reversible but disruptive (it stops the agent and removes
    /// the checkout), so it always goes through a confirmation.
    func requestArchive(_ id: WorkspaceID) {
        guard let workspace = workspaces.first(where: { $0.id == id }), !workspace.isArchived
        else { return }
        pendingArchive = PendingArchive(workspace: workspace)
    }

    /// An archived workspace staged for permanent deletion — the one archive
    /// action that cannot be undone.
    struct PendingArchivedDelete: Identifiable {
        let workspace: WorkspaceSummary
        var id: WorkspaceID { workspace.id }
    }

    var pendingArchivedDelete: PendingArchivedDelete?

    func requestPermanentDelete(_ workspace: WorkspaceSummary) {
        pendingArchivedDelete = PendingArchivedDelete(workspace: workspace)
    }

    func unarchive(_ id: WorkspaceID) {
        Task { await client.send(.unarchiveWorkspace(id)) }
    }

    func delete(_ id: WorkspaceID, deleteBranch: Bool) {
        Task { await client.send(.deleteWorkspace(id, deleteBranch: deleteBranch)) }
    }

    func rename(_ id: WorkspaceID, to name: String, userInitiated: Bool = true) {
        Task {
            await client.send(.renameWorkspace(id, name: name, userInitiated: userInitiated))
        }
    }

    func setPinned(_ pinned: Bool, for id: WorkspaceID) {
        Task { await client.send(.setWorkspacePinned(id, pinned: pinned)) }
    }

    /// After the PR merged: pull the base and restart the workspace on a fresh
    /// branch, leaving a memo in the chat so the agent knows what happened.
    func continueAfterMerge(_ id: WorkspaceID) {
        Task { await client.send(.continueAfterMerge(id)) }
    }

    /// The coloured toolbar button — Commit, Push, Create PR, Merge, and so on.
    /// `baseOverride` is the review pane's "into …" picker; the ⌥⌘G shortcut
    /// uses the suggested base.
    func performSuggestedGitAction(
        for workspace: WorkspaceSummary? = nil,
        baseOverride: String? = nil
    ) {
        guard let workspace = workspace ?? selectedWorkspace else { return }
        let action = cachedDiff(for: workspace.id)?.gitAction ?? .none
        switch action {
        case .merged:
            continueAfterMerge(workspace.id)
        case .createPullRequest(let defaultBase, let isStacked):
            createPullRequest(
                base: baseOverride ?? defaultBase,
                isStacked: isStacked,
                for: workspace
            )
        default:
            guard action.isActionable else { return }
            performGitAction(action, for: workspace)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            _ = try? await refreshDiff(for: workspace)
        }
    }

    /// The next step for a workspace, as last computed.
    func gitAction(for id: WorkspaceID) -> SuggestedGitAction {
        cachedDiff(for: id)?.gitAction ?? .none
    }

    var selectedGitAction: SuggestedGitAction {
        guard let id = selectedWorkspaceID else { return .none }
        return gitAction(for: id)
    }

    /// Whether ⌥⌘G has something to run. The actionable steps, plus the
    /// post-merge "start a fresh branch" state — `.merged` reports as
    /// non-actionable (it's a status, not a git command) but still has a
    /// keyboard path through `performSuggestedGitAction`.
    var canPerformSuggestedGitAction: Bool {
        if case .merged = selectedGitAction { return true }
        return selectedGitAction.isActionable
    }

    func performGitAction(_ action: SuggestedGitAction, for workspace: WorkspaceSummary) {
        if let prompt = action.agentDraftPrompt {
            placePromptInComposer(prompt, in: workspace.id)
            return
        }
        Task {
            switch action {
            case .commit, .createPullRequest:
                break
            case .createGitHubRepo:
                await client.send(.createGitHubRepo(workspace.id))
            case .push:
                await client.send(.push(workspace.id))
            case .retargetAfterParentMerged(let number, let base):
                guard let number else { return }
                await client.send(.retargetPullRequest(workspace.id, number: number, base: base))
            case .merge:
                let method = UserDefaults.standard.string(forKey: "ore.mergeMethod") ?? "squash"
                await client.send(.mergePullRequest(workspace.id, method: method))
            case .fixFailingChecks:
                forwardFailingChecks(workspace.id)
            case .resolveConflicts(_, let base):
                send("Rebase onto `\(base)`, resolve all conflicts, and explain the resolution.", to: workspace.id)
            default:
                break
            }
        }
    }

    func submitCommit(message: String, for workspace: WorkspaceSummary) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await client.send(.commit(workspace.id, message: trimmed)) }
    }

    func submitPullRequest(
        title: String,
        body: String,
        base: String,
        draft: Bool,
        for workspace: WorkspaceSummary
    ) {
        Task {
            await client.send(.createPullRequest(
                workspace.id,
                title: title,
                body: body,
                base: base,
                draft: draft
            ))
        }
    }

    func submitMerge(method: String, for workspace: WorkspaceSummary) {
        UserDefaults.standard.set(method, forKey: "ore.mergeMethod")
        Task { await client.send(.mergePullRequest(workspace.id, method: method)) }
    }

    func resolveConflict(path: String, side: ConflictSide, in workspaceID: WorkspaceID) {
        Task { await client.send(.resolveConflict(workspaceID, path: path, side: side.rawValue)) }
    }

    func resolveConflictHunk(
        path: String,
        startLine: Int,
        side: ConflictSide,
        in workspaceID: WorkspaceID
    ) {
        Task {
            await client.send(.resolveConflictHunk(
                workspaceID, path: path, startLine: startLine, side: side.rawValue
            ))
        }
    }

    func rerunFailedChecks(_ id: WorkspaceID) {
        Task { await client.send(.rerunFailedChecks(id)) }
    }

    func retryLastTurn(in workspaceID: WorkspaceID) {
        guard let chatID = activeChat(for: workspaceID)?.id else { return }
        let state = chat(for: chatID)
        guard let row = state.rows.last(where: { $0.kind == .userMessage }) else { return }
        state.dismissProminentError()
        send(row.text, attachments: row.attachments, to: workspaceID, chatID: chatID)
    }

    func openFromNotification(workspaceID: String?, chatID: String?) {
        if let workspaceID {
            selectedWorkspaceID = WorkspaceID(rawValue: workspaceID)
            showChatInCenter(WorkspaceID(rawValue: workspaceID))
        }
        if let workspaceID, let chatID {
            selectChat(ChatID(rawValue: chatID), in: WorkspaceID(rawValue: workspaceID))
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func markAllNotificationsRead() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().setBadgeCount(0)
    }

    /// Open a PR against a user-chosen base branch (the review pane's picker),
    /// rather than the workspace's default base.
    func createPullRequest(base: String, isStacked: Bool = false, for workspace: WorkspaceSummary) {
        placePromptInComposer(
            GitShipPrompt.pullRequest(base: base, isStacked: isStacked),
            in: workspace.id
        )
    }

    /// Drops a shipping prompt into an idle composer so the user can edit and send.
    ///
    /// Tab choice: the selected chat if it's idle and empty; otherwise any idle
    /// empty tab (newest first); otherwise a new tab. Never interrupts a running
    /// turn or overwrites a draft the user is still writing.
    func placePromptInComposer(_ text: String, in workspaceID: WorkspaceID) {
        showChatInCenter(workspaceID)
        if let chat = ComposerPlacement.target(
            active: activeChat(for: workspaceID),
            open: chats(for: workspaceID),
            isOccupied: composerIsOccupied
        ) {
            selectChat(chat.id, in: workspaceID)
            injectComposerText(text, into: chat)
            return
        }
        createChat(in: workspaceID, draft: text)
    }

    private func composerIsOccupied(_ chat: ChatSummary) -> Bool {
        chat.status.occupiesComposer
            || chat.queuedMessageCount > 0
            || self.chat(for: chat.id).isBusy
    }

    private func injectComposerText(_ text: String, into chat: ChatSummary) {
        setDraft(text, for: chat)
        composerInjectionGeneration += 1
        composerInjection = ComposerInjection(
            chatID: chat.id,
            text: text,
            generation: composerInjectionGeneration
        )
    }

    func remoteBranches(for id: WorkspaceID) async -> [String] {
        await client.remoteBranches(workspaceID: id)
    }

    func pullRequestURL(for id: WorkspaceID) async -> String? {
        await client.pullRequestURL(workspaceID: id)
    }

    func forwardFailingChecks(_ id: WorkspaceID) {
        Task {
            do { try await client.forwardFailingChecks(workspaceID: id) }
            catch { show(error) }
        }
    }

    // MARK: - Direct reads

    // These throw rather than swallowing into `[]` / `.none`: a failed git read
    // is not "no changes", and reporting it as such is how a real diff ended up
    // labelled "No changes". The caller decides how to surface the failure.
    func loadDiff(for id: WorkspaceID) async throws -> [FileDiff] {
        try await client.diff(workspaceID: id, againstBase: true)
    }

    func loadGitAction(for id: WorkspaceID) async throws -> SuggestedGitAction {
        try await client.suggestedGitAction(workspaceID: id)
    }

    func loadUnpushedCommits(for id: WorkspaceID) async -> [CommitInfo] {
        (try? await client.unpushedCommits(workspaceID: id)) ?? []
    }

    func loadWorkingTreeStatus(for id: WorkspaceID) async -> GitStatusSnapshot? {
        await client.workingTreeStatus(workspaceID: id)
    }

    func loadPullRequestStatus(for id: WorkspaceID) async -> GitHubClient.PullRequest? {
        try? await client.pullRequestStatus(workspaceID: id)
    }

    func loadConflictHunks(path: String, for id: WorkspaceID) async -> [ConflictHunk] {
        (try? await client.conflictHunks(workspaceID: id, path: path)) ?? []
    }

    func loadTurnCheckpoints(for id: WorkspaceID) async -> [TurnCheckpoint] {
        guard let chatID = activeChat(for: id)?.id else { return [] }
        return (try? await client.turnCheckpoints(workspaceID: id, chatID: chatID)) ?? []
    }

    func loadDiffFromCheckpoint(_ commit: String, for id: WorkspaceID) async throws -> [FileDiff] {
        try await client.diffFromCheckpoint(workspaceID: id, commit: commit)
    }

    func loadDiffBetweenCheckpoints(
        from: String,
        to: String,
        for id: WorkspaceID
    ) async throws -> [FileDiff] {
        try await client.diffBetweenCheckpoints(workspaceID: id, from: from, to: to)
    }

    func loadCheckLog(named name: String, for id: WorkspaceID) async -> String? {
        await client.checkLog(workspaceID: id, named: name)
    }

    func loadStackNeighbors(for id: WorkspaceID) async -> (parent: WorkspaceSummary?, children: [WorkspaceSummary]) {
        (try? await client.stackNeighbors(workspaceID: id)) ?? (nil, [])
    }

    func localBranches(for id: WorkspaceID) async -> [String] {
        await client.localBranches(workspaceID: id)
    }

    func localBranches(repositoryPath: String) async -> [String] {
        await client.localBranches(repositoryPath: repositoryPath)
    }

    func githubIssues(repositoryPath: String) async -> [GitHubClient.IssueListItem] {
        (try? await client.githubIssues(repositoryPath: repositoryPath)) ?? []
    }

    func githubPullRequests(repositoryPath: String) async -> [GitHubClient.IssueListItem] {
        (try? await client.githubPullRequests(repositoryPath: repositoryPath)) ?? []
    }

    /// The last cached diff for a workspace, if any — used to paint the review
    /// pane instantly on switch before a fresh read completes.
    func cachedDiff(for id: WorkspaceID) -> DiffSnapshot? { diffCache[id] }

    /// Loads a workspace's diff and suggested git action together, caches the
    /// result, and returns it. The concurrent reads mean the review pane waits
    /// on the slower of the two rather than their sum.
    @discardableResult
    func refreshDiff(for workspace: WorkspaceSummary) async throws -> DiffSnapshot {
        async let diffs = loadDiff(for: workspace.id)
        async let action = loadGitAction(for: workspace.id)
        let snapshot = DiffSnapshot(
            generation: workspace.gitStatus.generation,
            diffs: try await diffs,
            gitAction: try await action
        )
        // Reads race: the review pane refreshes on both workspace switch and
        // every git-status bump, and `prefetchDiff` runs more in the
        // background. They finish out of order, so an older read landing last
        // used to overwrite fresh changes with the empty diff from before the
        // agent wrote anything — the "Changes 0 even though files are
        // modified" that only showed up sometimes. The newest generation wins,
        // and a stale caller is handed the newer snapshot rather than its own.
        if let cached = diffCache[workspace.id], cached.generation > snapshot.generation {
            return cached
        }
        diffCache[workspace.id] = snapshot
        return snapshot
    }

    /// Recomputes just the suggested git action, leaving the cached diff alone.
    ///
    /// Everything else here refreshes on the git-status generation, which only
    /// moves when the *worktree* does. Half of what the action depends on lives
    /// on GitHub: opening a PR, a review landing, CI going red, someone merging
    /// in a browser tab — none of which touch a local file, so none of which
    /// bump the generation. Without a trigger of its own the toolbar kept
    /// offering "Create pull request" for a PR that was already open, and the
    /// button did the one thing that could not work.
    ///
    /// Cheap enough to call on turn boundaries and workspace switches: it is one
    /// `gh pr view` and a `git status`, and it never refetches the diff.
    func refreshGitAction(for workspaceID: WorkspaceID) async {
        guard let action = try? await loadGitAction(for: workspaceID) else { return }
        guard var snapshot = diffCache[workspaceID] else { return }
        guard snapshot.gitAction != action else { return }
        snapshot.gitAction = action
        diffCache[workspaceID] = snapshot
    }

    /// Best-effort background warm-up of a workspace's diff so a later switch is
    /// instant. Skips work when the cache already matches the current git-status
    /// generation; failures are swallowed since the real refresh reports them.
    func prefetchDiff(for workspace: WorkspaceSummary) {
        if let cached = diffCache[workspace.id],
           cached.generation == workspace.gitStatus.generation { return }
        Task(priority: .utility) { [weak self] in
            _ = try? await self?.refreshDiff(for: workspace)
        }
    }

    /// Warms the transcript for a workspace's active chat so its centre column
    /// shows history immediately on switch instead of the empty state. Reading
    /// the `ChatState` is enough — it kicks off `loadHistory` on first access.
    func prefetchHistory(for workspaceID: WorkspaceID) {
        guard let chatID = activeChatIDs[workspaceID] else { return }
        if let state = chatStates[chatID], state.hasLoadedHistory { return }
        _ = chat(for: chatID)
    }

    /// Warms diffs and transcripts for every workspace shortly after they load,
    /// so navigating between worktrees feels instant rather than cold.
    private func warmWorkspaces() {
        for workspace in workspaces {
            prefetchDiff(for: workspace)
            prefetchHistory(for: workspace.id)
        }
    }

    func addDiffComment(_ reference: DiffCommentReference, for id: WorkspaceID) {
        chat(for: id).addDraftComment(reference)
        Task { await client.send(.addDiffComment(id, reference)) }
    }

    func loadViewedFiles(for id: WorkspaceID) async -> [String: String] {
        (try? await client.viewedFiles(workspaceID: id)) ?? [:]
    }

    func markViewed(_ path: String, hash: String?, for id: WorkspaceID) {
        Task { await client.send(.markFileViewed(id, path: path, contentHash: hash)) }
    }

    func queuedMessages(for chatID: ChatID) async -> [QueuedMessageRecord] {
        (try? await client.queuedMessages(chatID: chatID)) ?? []
    }

    func updateQueuedMessage(_ id: Int64, text: String) async {
        try? await client.updateQueuedMessage(id: id, text: text)
    }

    func deleteQueuedMessage(_ id: Int64) async {
        try? await client.deleteQueuedMessage(id: id)
        if let chat = selectedChatSummary {
            var updated = chat
            updated.queuedMessageCount = max(0, updated.queuedMessageCount - 1)
            upsertChat(updated)
        }
    }

    func search(_ query: String) async -> [SearchResult] {
        guard let hits = try? await client.search(query) else { return [] }
        return hits.map {
            SearchResult(
                workspaceID: $0.workspaceID,
                workspaceName: $0.workspaceName,
                snippet: $0.snippet
            )
        }
    }

    func workspaceEnvironment(
        for id: WorkspaceID
    ) async -> InProcessCoreClient.WorkspaceEnvironment? {
        try? await client.workspaceEnvironment(workspaceID: id)
    }

    func refreshRepositories() async {
        repositories = ((try? await client.repositories()) ?? []).map(\.path)
    }

    func githubStatus() async -> GitHubClient.Status {
        await GitHubClient(repositoryURL: OreHome.directory).status()
    }

    func githubRepositories() async throws -> [GitHubClient.Repository] {
        try await GitHubClient(repositoryURL: OreHome.directory).repositories()
    }

    func authenticateGitHub() async throws {
        try await GitHubClient(repositoryURL: OreHome.directory).authenticate()
    }

    /// Clones into ORE's repository library using owner/name folders, which
    /// avoids collisions between identically named projects from two owners.
    /// The canonical clone is registered with core before this returns, so the
    /// caller can immediately create its first worktree.
    func cloneGitHubRepository(_ reference: String) async throws -> String {
        let value = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let identity = Self.githubIdentity(from: value) else {
            throw GitHubRepositoryInputError.invalidReference
        }
        let destination = OreHome.directory
            .appendingPathComponent("repositories", isDirectory: true)
            .appendingPathComponent(identity.owner, isDirectory: true)
            .appendingPathComponent(identity.name, isDirectory: true)

        if FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(".git").path
        ) {
            await client.send(.addRepository(path: destination.path))
            await refreshRepositories()
            return destination.path
        }

        try await GitHubClient(repositoryURL: OreHome.directory)
            .clone(repository: value, to: destination)
        await client.send(.addRepository(path: destination.path))
        await refreshRepositories()
        return destination.path
    }

    private nonisolated static func githubIdentity(from reference: String) -> (owner: String, name: String)? {
        var value = reference
        if let url = URL(string: value), url.host?.contains("github.com") == true {
            value = url.path
        } else if value.hasPrefix("git@github.com:") {
            value.removeFirst("git@github.com:".count)
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if value.hasSuffix(".git") { value.removeLast(4) }
        let parts = value.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        return (parts[0], parts[1])
    }

    func refreshHarnesses() {
        Task { await client.send(.probeHarnesses) }
    }

    /// Starts the provider's own browser-based login. Credentials remain in
    /// the CLI's credential store; ORE only observes the process exit and then
    /// re-runs its readiness probe.
    func authenticateHarness(_ kind: HarnessKind) async throws {
        guard kind != .claudeCode else { throw HarnessAuthenticationError.interactiveOnly }
        guard let executable = harnesses.first(where: { $0.kind == kind })?.executablePath
        else { throw HarnessAuthenticationError.notInstalled(kind.displayName) }

        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["login"]
            process.currentDirectoryURL = OreHome.directory
            process.environment = ProcessInfo.processInfo.environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { child in
                continuation.resume(returning: child.terminationStatus)
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
        guard exitCode == 0 else { throw HarnessAuthenticationError.failed(exitCode) }
        await client.send(.probeHarnesses)
    }

    func suggestedResearchIdentity() -> ResearchIdentity {
        let used = Set(workspaces.flatMap { workspace in
            [workspace.name, (workspace.worktreePath as NSString).lastPathComponent]
        })
        return ResearchIdentity.next(excluding: used)
    }

    func researchIdentity(for workspace: WorkspaceSummary) -> ResearchIdentity? {
        let key = "ore.researchIdentity.\(workspace.id.rawValue)"
        if let saved = UserDefaults.standard.string(forKey: key),
           let identity = ResearchIdentity.matching(nameOrSlug: saved) {
            return identity
        }
        let folder = (workspace.worktreePath as NSString).lastPathComponent
        return ResearchIdentity.matching(nameOrSlug: workspace.name)
            ?? ResearchIdentity.matching(nameOrSlug: folder)
    }

    // MARK: - Workspace files

    func workspaceFiles(for workspace: WorkspaceSummary) async -> [WorkspaceFileNode] {
        let root = workspace.worktreePath
        return await Task.detached(priority: .userInitiated) {
            Self.scanWorkspace(at: root)
        }.value
    }

    func fileContents(path: String, in workspace: WorkspaceSummary) async throws -> String {
        let root = workspace.worktreePath
        return try await Task.detached(priority: .userInitiated) {
            let url = try Self.safeFileURL(root: root, relativePath: path)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            guard values.isDirectory != true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            guard (values.fileSize ?? 0) <= 2_000_000 else {
                throw CocoaError(.fileReadTooLarge)
            }
            let data = try Data(contentsOf: url)
            guard !data.prefix(8_192).contains(0), let value = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            return value
        }.value
    }

    func saveFileContents(_ contents: String, path: String, in workspace: WorkspaceSummary) async throws {
        let root = workspace.worktreePath
        try await Task.detached(priority: .userInitiated) {
            let url = try Self.safeFileURL(root: root, relativePath: path)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }

    private nonisolated static func safeFileURL(root: String, relativePath: String) throws -> URL {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
        let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard url.path == rootURL.path || url.path.hasPrefix(prefix) else {
            throw CocoaError(.fileReadNoPermission)
        }
        return url
    }

    private nonisolated static func scanWorkspace(at root: String) -> [WorkspaceFileNode] {
        let manager = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        let skipped = Set(["node_modules", ".build", "DerivedData", "Pods", ".swiftpm"])
        var visited = 0

        func children(of directory: URL, relativeBase: String) -> [WorkspaceFileNode] {
            guard visited < 6_000,
                  let urls = try? manager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: []
                  ) else { return [] }
            return urls.sorted { first, second in
                let firstDirectory = (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let secondDirectory = (try? second.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if firstDirectory != secondDirectory { return firstDirectory }
                return first.lastPathComponent.localizedStandardCompare(second.lastPathComponent) == .orderedAscending
            }.compactMap { url in
                guard visited < 6_000 else { return nil }
                visited += 1
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let isDirectory = values?.isDirectory == true
                let relative = relativeBase.isEmpty ? url.lastPathComponent : relativeBase + "/" + url.lastPathComponent
                if url.lastPathComponent == ".git", isDirectory { return nil }
                let nested = isDirectory && values?.isSymbolicLink != true && !skipped.contains(url.lastPathComponent)
                    ? children(of: url, relativeBase: relative)
                    : nil
                return WorkspaceFileNode(
                    path: relative,
                    name: url.lastPathComponent,
                    isDirectory: isDirectory,
                    children: nested
                )
            }
        }
        return children(of: rootURL, relativeBase: "")
    }

    struct SearchResult: Identifiable, Sendable {
        var id: String { workspaceID.rawValue + snippet }
        var workspaceID: WorkspaceID
        var workspaceName: String
        var snippet: String
    }

    // MARK: - Events

    private func apply(_ event: CoreEvent) {
        switch event {
        case .snapshot(let snapshot):
            workspaces = snapshot.workspaces
            chatSummaries = snapshot.chats
            chatOwners = Dictionary(
                snapshot.chats.map { ($0.id, $0.workspaceID) },
                uniquingKeysWith: { _, last in last }
            )
            harnesses = snapshot.harnesses
            restoreActiveChats()
            adoptResearchIdentities()
            if selectedWorkspaceID == nil {
                if let saved = UserDefaults.standard.string(forKey: "ore.selectedWorkspace"),
                   workspaces.contains(where: { $0.id.rawValue == saved }) {
                    selectedWorkspaceID = WorkspaceID(rawValue: saved)
                } else {
                    selectedWorkspaceID = sortedWorkspaces.first?.id
                }
            }
            warmWorkspaces()

        case .workspaceAdded(let summary):
            upsert(summary)
            rememberIdentityIfPresent(for: summary)
            selectedWorkspaceID = summary.id
            prefetchDiff(for: summary)

        case .workspaceUpdated(let summary):
            upsert(summary)
            identityRenamesInFlight.remove(summary.id)
            rememberIdentityIfPresent(for: summary)

        case .workspaceRemoved(let id):
            workspaces.removeAll { $0.id == id }
            let removed = chatSummaries.filter { $0.workspaceID == id }.map(\.id)
            chatSummaries.removeAll { $0.workspaceID == id }
            for chatID in removed { forget(chatID) }
            activeChatIDs.removeValue(forKey: id)
            openFilePaths.removeValue(forKey: id)
            activeFilePath.removeValue(forKey: id)
            filePresentationModes.removeValue(forKey: id)
            fileFocus.removeValue(forKey: id)
            pendingNewChatMessages.removeValue(forKey: id)
            pendingNewChatDrafts.removeValue(forKey: id)
            identityRenamesInFlight.remove(id)
            chatCreationsInFlight.remove(id)
            // The workspace's terminals keep their PTYs and scrollback alive
            // for as long as the registry holds them, which outlived the
            // worktree they were running in.
            TerminalRegistry.shared.closeTerminal(for: id)
            for key in ["ore.activeChat", "ore.researchIdentity"] {
                UserDefaults.standard.removeObject(forKey: "\(key).\(id.rawValue)")
            }
            if selectedWorkspaceID == id { selectedWorkspaceID = sortedWorkspaces.first?.id }

        case .agent(let id, let chatID, let agentEvent):
            chatOwners[chatID] = id
            // Deltas are buffered; everything else flushes them first so a
            // tool call can never appear above the text that introduced it.
            var coalescer = coalescers[chatID] ?? TextDeltaCoalescer()
            for flushed in coalescer.absorb(agentEvent) {
                applyToChat(workspaceID: id, chatID: chatID, event: flushed)
            }
            coalescers[chatID] = coalescer
            // An agent that ends its turn by pushing and opening a PR leaves the
            // worktree byte-for-byte identical to how it started it, so nothing
            // else asks whether the next step changed.
            if case .turnCompleted = agentEvent {
                Task { [weak self] in await self?.refreshGitAction(for: id) }
            }

        case .chatAdded(let chat):
            chatCreationsInFlight.remove(chat.workspaceID)
            chatOwners[chat.id] = chat.workspaceID
            upsertChat(chat)
            adoptResearchChatTitles(in: chat.workspaceID)
            selectChat(chat.id, in: chat.workspaceID)
            if var pending = pendingNewChatMessages[chat.workspaceID], !pending.isEmpty {
                let message = pending.removeFirst()
                pendingNewChatMessages[chat.workspaceID] = pending.isEmpty ? nil : pending
                send(message, to: chat.workspaceID, chatID: chat.id)
            } else if var drafts = pendingNewChatDrafts[chat.workspaceID], !drafts.isEmpty {
                let text = drafts.removeFirst()
                pendingNewChatDrafts[chat.workspaceID] = drafts.isEmpty ? nil : drafts
                injectComposerText(text, into: chat)
            }

        case .chatUpdated(let chat):
            chatOwners[chat.id] = chat.workspaceID
            chatRenamesInFlight.remove(chat.id)
            // Neighbor is computed while the closed chat is still in the open
            // list. After `upsertChat` it is filtered out, and `.first` would
            // jump to the oldest remaining tab.
            let replacement: ChatID? = {
                guard chat.isClosed else { return nil }
                return TabCloseSelection.replacement(
                    closing: chat.id,
                    active: activeChat(for: chat.workspaceID)?.id,
                    open: chats(for: chat.workspaceID).map(\.id)
                )
            }()
            upsertChat(chat)
            if let replacement {
                selectChat(replacement, in: chat.workspaceID)
            }

        case .chatRemoved(_, let chatID):
            forget(chatID)
            chatSummaries.removeAll { $0.id == chatID }

        case .chatsListed(let workspaceID, let chats):
            for chat in chats {
                chatOwners[chat.id] = workspaceID
                upsertChat(chat)
            }
            adoptResearchChatTitles(in: workspaceID)

        case .gitStatusChanged(let id, let status):
            guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
            workspaces[index].gitStatus = status
            // The tree changed, so any cached diff is now stale — warm a fresh
            // one in the background so the review pane stays instant.
            prefetchDiff(for: workspaces[index])

        case .harnessProbeCompleted(let probes):
            harnesses = probes

        case .modelCatalogUpdated(let harness, let models):
            modelCatalog[harness] = models

        case .commandFailed(let failure):
            if let workspaceID = failure.workspaceID {
                chatCreationsInFlight.remove(workspaceID)
            }
            banners.append(Banner(message: failure.message, detail: failure.detail))
        }
    }

    func knownModels(for harness: HarnessKind) -> [AgentModel] {
        let curated: [AgentModel] = switch harness {
        case .claudeCode:
            [
                AgentModel(id: "claude-fable-5", displayName: "Fable 5", description: "Highest capability for long-running agents", supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
                AgentModel(id: "claude-opus-5", displayName: "Opus 5", description: "Complex agentic coding and enterprise work", supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
                AgentModel(id: "claude-opus-4-8[1m]", displayName: "Opus 4.8 · 1M", description: "Deep reasoning with long context", supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
                AgentModel(id: "claude-opus-4-7[1m]", displayName: "Opus 4.7 · 1M", description: "Previous Opus generation", supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
                AgentModel(id: "claude-opus-4-6[1m]", displayName: "Opus 4.6 · 1M", description: "Long-context Opus model", supportedReasoningEfforts: ["low", "medium", "high", "max"]),
                AgentModel(id: "claude-sonnet-5[1m]", displayName: "Sonnet 5 · 1M", description: "Fast frontier model for coding and agents", isDefault: true, supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
                AgentModel(id: "claude-sonnet-4-6[1m]", displayName: "Sonnet 4.6 · 1M", description: "Balanced long-context model", supportedReasoningEfforts: ["low", "medium", "high", "max"]),
                AgentModel(id: "claude-sonnet-4-6", displayName: "Sonnet 4.6", description: "Balanced speed and capability", supportedReasoningEfforts: ["low", "medium", "high", "max"]),
                AgentModel(id: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5", description: "Fastest Claude model"),
            ]
        case .codex:
            [
                AgentModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", description: "Frontier capability for complex coding", isDefault: true, supportedReasoningEfforts: ["none", "low", "medium", "high", "xhigh", "max"], supportedServiceTiers: ["fast"]),
                AgentModel(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", description: "Balanced intelligence, speed, and cost", supportedReasoningEfforts: ["none", "low", "medium", "high", "xhigh", "max"], supportedServiceTiers: ["fast"]),
                AgentModel(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna", description: "Fast, efficient agent work", supportedReasoningEfforts: ["none", "low", "medium", "high", "xhigh", "max"], supportedServiceTiers: ["fast"]),
                AgentModel(id: "gpt-5.5", displayName: "GPT-5.5", description: "Previous frontier generation", supportedServiceTiers: ["fast"]),
                AgentModel(id: "gpt-5.4", displayName: "GPT-5.4", description: "Compatible prior generation", supportedServiceTiers: ["fast"]),
            ]
        case .cursorAgent:
            // Fallback only — the full catalogue comes from the CLI via
            // `CursorAgentHarness.discoverModels()` and merges in below. These
            // real ids keep the picker useful if discovery hasn't run yet.
            [
                AgentModel(id: "auto", displayName: "Auto", isDefault: true),
                AgentModel(id: "composer-2.5", displayName: "Composer 2.5"),
                AgentModel(id: "cursor-grok-4.6-high", displayName: "Cursor Grok 4.6"),
                AgentModel(id: "cursor-grok-4.5-high", displayName: "Cursor Grok 4.5"),
            ]
        }
        let discovered = modelCatalog[harness] ?? []
        var seen: Set<String> = []
        return (curated + discovered).filter { seen.insert($0.id).inserted }
    }

    /// UserDefaults key for a harness's user-chosen default model.
    static func defaultModelKey(for harness: HarnessKind) -> String {
        "ore.defaultModel.\(harness.rawValue)"
    }

    /// Settings keys for the agent and model a new tab opens with, and for the
    /// Review button's own override. An empty stored value means "inherit", so
    /// nothing is pinned until the user actually picks something.
    enum DefaultKey {
        static let newChatHarness = "ore.defaultHarness"
        static let newChatModel = "ore.defaultModel"
        static let reviewHarness = "ore.review.harness"
        static let reviewModel = "ore.review.model"
    }

    /// The agent and model a chat starts with. Both are optional because either
    /// can be left to the core's own fallbacks.
    struct ChatDefaults: Equatable {
        var harness: HarnessKind?
        var model: String?
    }

    private static func pinned(_ key: String) -> String? {
        guard let value = UserDefaults.standard.string(forKey: key), !value.isEmpty else { return nil }
        return value
    }

    /// What the `+` button opens: the Settings pin if the user set one, else
    /// whatever the workspace is already using.
    func newChatDefaults(for workspaceID: WorkspaceID) -> ChatDefaults {
        let workspace = workspaces.first { $0.id == workspaceID }
        return resolveDefaults(
            harnessKey: DefaultKey.newChatHarness,
            modelKey: DefaultKey.newChatModel,
            inherited: ChatDefaults(harness: workspace?.harness, model: workspace?.model)
        )
    }

    /// What the Review button opens. Review pins fall back to the new-chat pins,
    /// which fall back to the workspace — one chain, so leaving review unset
    /// keeps it behaving exactly like any other new tab.
    func reviewDefaults(for workspaceID: WorkspaceID) -> ChatDefaults {
        resolveDefaults(
            harnessKey: DefaultKey.reviewHarness,
            modelKey: DefaultKey.reviewModel,
            inherited: newChatDefaults(for: workspaceID)
        )
    }

    private func resolveDefaults(
        harnessKey: String,
        modelKey: String,
        inherited: ChatDefaults
    ) -> ChatDefaults {
        let harness = Self.pinned(harnessKey).flatMap(HarnessKind.init(rawValue:)) ?? inherited.harness
        if let model = Self.pinned(modelKey) {
            return ChatDefaults(harness: harness, model: model)
        }
        // Switching agent invalidates the inherited model id — it names a model
        // in the other provider's catalogue, and handing it over is exactly what
        // produces "the selected model may not exist" once the agent starts.
        guard harness == inherited.harness else {
            return ChatDefaults(harness: harness, model: harness.flatMap { defaultModelID(for: $0) })
        }
        return ChatDefaults(harness: harness, model: inherited.model)
    }

    /// The default model id for a harness: the user's per-harness choice from
    /// Settings if set, else the catalogue's `isDefault` model. Drives the model
    /// chip's scroll-to-switch between harnesses.
    func defaultModelID(for harness: HarnessKind) -> String? {
        let key = Self.defaultModelKey(for: harness)
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            return saved
        }
        return knownModels(for: harness).first(where: \.isDefault)?.id
    }

    private func applyToChat(workspaceID: WorkspaceID, chatID: ChatID, event: AgentEvent) {
        chat(for: chatID).apply(event)
        let isBackground = selectedWorkspaceID != workspaceID
            || activeChatIDs[workspaceID] != chatID
        guard isBackground else { return }
        switch event {
        case .permissionRequest:
            postNotification(
                title: "ORE needs you",
                body: workspaceName(workspaceID) + " is waiting for permission.",
                workspaceID: workspaceID,
                chatID: chatID
            )
        case .question:
            postNotification(
                title: "ORE needs you",
                body: workspaceName(workspaceID) + " has a question.",
                workspaceID: workspaceID,
                chatID: chatID
            )
        case .turnCompleted where UserDefaults.standard.object(forKey: "ore.notifications.turnComplete") as? Bool ?? true:
            postNotification(
                title: "Agent finished",
                body: workspaceName(workspaceID) + " completed a turn.",
                workspaceID: workspaceID,
                chatID: chatID
            )
        default:
            break
        }
    }

    /// Drops everything keyed by a chat that no longer exists.
    ///
    /// Each of these is small, and each used to outlive its chat: a scheduled
    /// continuation would still fire against a deleted conversation, and the
    /// per-chat defaults accumulated one set of orphans per chat ever created.
    private func forget(_ chatID: ChatID) {
        chatOwners.removeValue(forKey: chatID)
        coalescers.removeValue(forKey: chatID)
        chatStates.removeValue(forKey: chatID)
        chatRenamesInFlight.remove(chatID)
        continuationTasks.removeValue(forKey: chatID)?.cancel()
        scheduledContinuations.removeValue(forKey: chatID)
        persistScheduledContinuations()
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Self.continuationNotificationID(for: chatID)]
        )
        for key in [
            "ore.draftAttachments", "ore.chatScroll",
            "ore.reasoningEffort", "ore.fastMode",
        ] {
            UserDefaults.standard.removeObject(forKey: "\(key).\(chatID.rawValue)")
        }
    }

    private func workspaceName(_ id: WorkspaceID) -> String {
        workspaces.first { $0.id == id }?.name ?? "A workspace"
    }

    private func postNotification(
        title: String,
        body: String,
        workspaceID: WorkspaceID? = nil,
        chatID: ChatID? = nil
    ) {
        guard UserDefaults.standard.object(forKey: "ore.notifications.enabled") as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if UserDefaults.standard.object(forKey: "ore.notifications.sound") as? Bool ?? true {
            content.sound = .default
        }
        var userInfo: [String: String] = [:]
        if let workspaceID { userInfo["workspaceID"] = workspaceID.rawValue }
        if let chatID { userInfo["chatID"] = chatID.rawValue }
        content.userInfo = userInfo
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        ))
    }

    private func upsert(_ summary: WorkspaceSummary) {
        if let index = workspaces.firstIndex(where: { $0.id == summary.id }) {
            workspaces[index] = summary
        } else {
            workspaces.append(summary)
        }
    }

    private func upsertChat(_ summary: ChatSummary) {
        if let index = chatSummaries.firstIndex(where: { $0.id == summary.id }) {
            chatSummaries[index] = summary
        } else {
            chatSummaries.append(summary)
        }
        if activeChatIDs[summary.workspaceID] == nil, !summary.isClosed {
            let saved = UserDefaults.standard.string(
                forKey: "ore.activeChat.\(summary.workspaceID.rawValue)"
            )
            activeChatIDs[summary.workspaceID] = saved.flatMap { raw in
                chats(for: summary.workspaceID).first { $0.id.rawValue == raw }?.id
            } ?? chats(for: summary.workspaceID).first?.id
        }
    }

    private func restoreActiveChats() {
        for workspace in workspaces {
            let saved = UserDefaults.standard.string(
                forKey: "ore.activeChat.\(workspace.id.rawValue)"
            )
            activeChatIDs[workspace.id] = saved.flatMap { raw in
                chats(for: workspace.id).first { $0.id.rawValue == raw }?.id
            } ?? chats(for: workspace.id).first?.id
        }
    }

    private func adoptResearchIdentities() {
        var used = Set(workspaces.flatMap { workspace in
            [workspace.name, (workspace.worktreePath as NSString).lastPathComponent]
        })
        for workspace in workspaces {
            if let identity = researchIdentity(for: workspace) {
                UserDefaults.standard.set(
                    identity.slug,
                    forKey: "ore.researchIdentity.\(workspace.id.rawValue)"
                )
                // Repair a name the auto-namer poisoned with a provider error
                // ("You've hit your session limit"). The workspace's real
                // identity is still on file, so put it back rather than leaving
                // the window titled with a stale failure.
                if Self.looksLikeErrorTitle(workspace.name),
                   workspace.name != identity.name,
                   !identityRenamesInFlight.contains(workspace.id) {
                    identityRenamesInFlight.insert(workspace.id)
                    rename(workspace.id, to: identity.name)
                }
            } else if Self.isGenericWorkspaceName(workspace.name),
                      !identityRenamesInFlight.contains(workspace.id) {
                let identity = ResearchIdentity.next(excluding: used)
                used.insert(identity.name)
                used.insert(identity.slug)
                UserDefaults.standard.set(
                    identity.slug,
                    forKey: "ore.researchIdentity.\(workspace.id.rawValue)"
                )
                identityRenamesInFlight.insert(workspace.id)
                rename(workspace.id, to: identity.name, userInitiated: false)
            }
            adoptResearchChatTitles(in: workspace.id)
        }
    }

    private func adoptResearchChatTitles(in workspaceID: WorkspaceID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        let preferred = researchIdentity(for: workspace)
        var used = Set(chats(for: workspaceID, includeClosed: true)
            .filter { !Self.isGenericChatTitle($0.title, workspaceName: workspace.name) }
            .map(\.title))
        // A title that is really a provider error is renamed whether or not the
        // chat has run since: it was never a name, so there is no user intent
        // behind it to preserve.
        for chat in chats(for: workspaceID, includeClosed: true)
        where (Self.isGenericChatTitle(chat.title, workspaceName: workspace.name)
                && chat.lastActivity == nil
                || Self.looksLikeErrorTitle(chat.title))
            && !chatRenamesInFlight.contains(chat.id) {
            let title = ResearchIdentity.nextResearchTitle(excluding: used, preferred: preferred)
            used.insert(title)
            chatRenamesInFlight.insert(chat.id)
            renameChat(chat.id, in: workspaceID, to: title, userInitiated: false)
        }
    }

    private func rememberIdentityIfPresent(for workspace: WorkspaceSummary) {
        let key = "ore.researchIdentity.\(workspace.id.rawValue)"
        guard UserDefaults.standard.string(forKey: key) == nil,
              let identity = ResearchIdentity.matching(nameOrSlug: workspace.name) else { return }
        UserDefaults.standard.set(identity.slug, forKey: key)
    }

    /// A name that is actually a failure the auto-namer captured. The naming
    /// session runs on the same metered subscription as the chat, so when that
    /// hits a limit the limit notice is what comes back — and it reads exactly
    /// like a title, which is why it was adopted as one.
    nonisolated static func looksLikeErrorTitle(_ title: String) -> Bool {
        let value = title.lowercased()
        return [
            "session limit", "usage limit", "rate limit", "rate-limit",
            "quota", "too many requests", "try again later",
        ].contains { value.contains($0) }
    }

    private nonisolated static func isGenericWorkspaceName(_ name: String) -> Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty || value == "workspace" || value == "new workspace"
    }

    private nonisolated static func isGenericChatTitle(_ title: String, workspaceName: String) -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return true }
        if value.caseInsensitiveCompare("workspace") == .orderedSame
            || value.caseInsensitiveCompare("new workspace") == .orderedSame { return true }
        if value.caseInsensitiveCompare(workspaceName) == .orderedSame { return true }
        guard value.lowercased().hasPrefix("chat ") else { return false }
        return Int(value.dropFirst(5)) != nil
    }

    private func focusChanged(from previous: WorkspaceID?, to next: WorkspaceID?) {
        if let next { UserDefaults.standard.set(next.rawValue, forKey: "ore.selectedWorkspace") }
        Task {
            if let previous, let chatID = activeChatIDs[previous] {
                try? await client.setFocused(
                    workspaceID: previous, chatID: chatID, focused: false
                )
            }
            if let next, let chatID = activeChatIDs[next] {
                try? await client.setFocused(workspaceID: next, chatID: chatID, focused: true)
            }
        }
        // Looking at a workspace again is the other moment its remote state may
        // have moved without us — a PR reviewed or merged in a browser tab.
        if let next { Task { [weak self] in await self?.refreshGitAction(for: next) } }
    }

    func dismissBanner(_ id: UUID) {
        banners.removeAll { $0.id == id }
    }

    private func show(_ error: any Error) {
        banners.append(Banner(
            message: (error as? CustomStringConvertible)?.description
                ?? error.localizedDescription,
            detail: nil
        ))
    }
}

private enum HarnessAuthenticationError: LocalizedError, Sendable {
    case interactiveOnly
    case notInstalled(String)
    case failed(Int32)

    var errorDescription: String? {
        switch self {
        case .interactiveOnly:
            "Claude Code sign-in is interactive. The command has been copied for Terminal."
        case .notInstalled(let name):
            "\(name) is not installed."
        case .failed(let status):
            "The provider login exited with status \(status)."
        }
    }
}

private enum GitHubRepositoryInputError: LocalizedError, Sendable {
    case invalidReference
    var errorDescription: String? {
        "Enter a repository as owner/name or a GitHub URL."
    }
}

enum FilePresentationMode: String, Sendable {
    case source
    case diff
}

struct WorkspaceFileNode: Identifiable, Hashable, Sendable {
    var id: String { path }
    var path: String
    var name: String
    var isDirectory: Bool
    var children: [WorkspaceFileNode]?
}

extension WorkspaceSummary {
    /// The one thing the sidebar is for: does this agent need me right now.
    var needsAttention: Bool {
        hasUnread || status == .awaitingInput || status == .failed
    }
}
