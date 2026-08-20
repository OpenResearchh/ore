import Foundation
import OreGit
import OreHarness
import OrePersistence
import OreProtocol
import OreSupport

/// Everything happening in one workspace.
///
/// One engine per workspace, each owning its agent session, its status watcher
/// and its slice of the transcript. That isolation is the product: N agents run
/// in parallel and nothing one does can disturb another, because they share no
/// mutable state and no working directory.
public actor WorkspaceEngine {
    public nonisolated let workspaceID: WorkspaceID
    public nonisolated let events: AsyncStream<WorkspaceAgentEvent>

    private nonisolated let continuation: AsyncStream<WorkspaceAgentEvent>.Continuation

    private let store: OreStore
    private let git: GitClient
    private let gitHub: GitHubClient
    private let diffEngine: DiffEngine
    private let checkpoints: CheckpointStore
    private let harnessRegistry: HarnessRegistry
    private let worktreeURL: URL
    private let allowAPIKeyFallback: Bool

    private var record: WorkspaceRecord
    private var statusWatcher: StatusWatcher?
    private var statusTask: Task<Void, Never>?
    private var baseSyncTask: Task<Void, Never>?
    private var gitStatus: GitStatusSummary = GitStatusSummary()
    private var baseSync: BaseSyncStatus?
    private var chats: [ChatID: ChatRuntime] = [:]

    private final class ChatRuntime: @unchecked Sendable {
        var record: ChatRecord
        var session: (any AgentSession)?
        var transcript: TranscriptWriter?
        var sessionTask: Task<Void, Never>?
        var status: AgentStatus = .idle
        var latestUsage: UsageReport?
        var pendingPermissions: [PermissionRequestID: PermissionRequest] = [:]
        var pendingQuestions: [QuestionID: AgentQuestion] = [:]
        var currentTurnID: TurnID?
        var isTurnActive = false
        var sessionEffort: ReasoningEffort?
        var isGeneratingTitle = false
        var handoffContext: String?
        var queuedMessageCount = 0
        /// Workspace-level facts the agent must learn on its next real turn
        /// (e.g. "your PR merged; you're on a fresh branch now"). Prepended to
        /// the next outgoing message and cleared — a note in the database
        /// alone never reaches a resumed provider session's context.
        var pendingContextNotes: [String] = []

        init(record: ChatRecord) { self.record = record }
    }

    public init(
        record: WorkspaceRecord,
        store: OreStore,
        git: GitClient,
        harnessRegistry: HarnessRegistry,
        allowAPIKeyFallback: Bool = false
    ) {
        self.workspaceID = record.workspaceID
        self.record = record
        self.store = store
        self.git = git
        self.harnessRegistry = harnessRegistry
        self.allowAPIKeyFallback = allowAPIKeyFallback
        self.worktreeURL = URL(fileURLWithPath: record.worktreePath)
        self.gitHub = GitHubClient(repositoryURL: URL(fileURLWithPath: record.repositoryPath))
        self.diffEngine = DiffEngine(git: git)
        self.checkpoints = CheckpointStore(git: git)

        let (stream, continuation) = AsyncStream<WorkspaceAgentEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.continuation = continuation
    }

    // MARK: - Snapshot

    public func summary() -> WorkspaceSummary {
        let active = chats.values.filter { !$0.record.isClosed }
        let status = active.map(\.status).max(by: { $0.attentionRank < $1.attentionRank }) ?? .idle
        let usage = active
            .sorted { ($0.record.lastActivityAt ?? .distantPast) > ($1.record.lastActivityAt ?? .distantPast) }
            .first?.latestUsage
        return record.summary(
            status: status, gitStatus: gitStatus, contextUsage: usage, baseSync: baseSync
        )
    }

    public func currentRecord() -> WorkspaceRecord { record }

    public func pendingPermissionRequests() -> [PermissionRequest] {
        chats.values.flatMap { $0.pendingPermissions.values }
    }

    // MARK: - Lifecycle

    public func start() async {
        _ = try? await loadChats()
        await startStatusWatching()
        await startBaseSyncWatching()
    }

    /// Marks the workspace read. Notification hygiene is capped at one unread
    /// per workspace, so this is a boolean and not a count — a badge of 37
    /// tells the user nothing they can act on.
    public func markRead(chatID: ChatID? = nil) async {
        guard let runtime = try? await runtime(for: chatID) else { return }
        if runtime.record.hasUnread {
            runtime.record.hasUnread = false
            try? await store.saveChat(runtime.record)
            publishChatChange(runtime)
        }
        let stillUnread = chats.values.contains { $0.record.hasUnread }
        guard record.hasUnread != stillUnread else { return }
        record.hasUnread = stillUnread
        try? await persistRecord()
        publishSummaryChange()
    }

    public func stop() async {
        statusTask?.cancel()
        baseSyncTask?.cancel()
        await statusWatcher?.stop()
        for runtime in chats.values {
            runtime.sessionTask?.cancel()
            await runtime.session?.stop()
            runtime.session = nil
        }
        continuation.finish()
    }

    // MARK: - Sessions

    private func loadChats() async throws {
        let records = try await store.chats(workspaceID: workspaceID)
        for record in records where chats[record.chatID] == nil {
            let runtime = ChatRuntime(record: record)
            runtime.queuedMessageCount = try await store.queuedMessages(chatID: record.chatID).count
            chats[record.chatID] = runtime
            publishChatChange(runtime)
        }
        if chats.isEmpty {
            let defaultRecord = try await store.ensureDefaultChat(for: record)
            chats[defaultRecord.chatID] = ChatRuntime(record: defaultRecord)
            if let runtime = chats[defaultRecord.chatID] { publishChatChange(runtime) }
        }
    }

    private func runtime(for chatID: ChatID?) async throws -> ChatRuntime {
        try await loadChats()
        if let chatID {
            guard let runtime = chats[chatID], runtime.record.workspaceID == workspaceID.rawValue else {
                throw OreCoreError.chatNotFound(chatID)
            }
            return runtime
        }
        guard let runtime = chats.values.min(by: {
            if $0.record.sortIndex != $1.record.sortIndex {
                return $0.record.sortIndex < $1.record.sortIndex
            }
            return $0.record.createdAt < $1.record.createdAt
        }) else {
            throw OreCoreError.workspaceNotFound(workspaceID)
        }
        return runtime
    }

    public func chatSummaries(includeClosed: Bool = true) async throws -> [ChatSummary] {
        try await loadChats()
        return chats.values
            .filter { includeClosed || !$0.record.isClosed }
            .sorted { $0.record.sortIndex < $1.record.sortIndex }
            .map { runtime in
                runtime.record.summary(
                    status: runtime.status,
                    capabilities: harnessRegistry.harness(
                        for: HarnessKind(rawValue: runtime.record.harness) ?? .claudeCode
                    )?.capabilities ?? HarnessCapabilities(),
                    queuedMessageCount: runtime.queuedMessageCount,
                    isTurnActive: runtime.isTurnActive,
                    contextUsage: runtime.latestUsage
                )
            }
    }

    public func createChat(_ request: CreateChatRequest) async throws -> ChatSummary {
        try await loadChats()
        let index = try await store.nextChatSortIndex(workspaceID: workspaceID)
        let defaultRuntime = try await runtime(for: nil)
        // A fork inherits the source chat's agent and model, not the
        // workspace's: branching a conversation onto a different model would
        // hand the new session a transcript its model never produced.
        let source = request.forkFrom.flatMap { chats[$0] }
        let harness = request.harness
            ?? source.flatMap { HarnessKind(rawValue: $0.record.harness) }
            ?? HarnessKind(rawValue: defaultRuntime.record.harness) ?? .claudeCode
        let chat = ChatRecord(
            id: ChatID.generate(),
            workspaceID: workspaceID,
            title: request.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "Chat \(index + 1)",
            harness: harness,
            model: request.model ?? source?.record.model ?? defaultRuntime.record.model,
            permissionMode: request.permissionMode,
            sortIndex: index,
            reasoningEffort: request.reasoningEffort
                ?? source?.record.reasoningEffort.flatMap(ReasoningEffort.init(rawValue:))
        )
        try await store.saveChat(chat)
        let runtime = ChatRuntime(record: chat)
        chats[chat.chatID] = runtime
        publishChatChange(runtime)
        if let source { await forkSession(from: source, into: runtime, harness: harness) }
        return try await summary(for: runtime)
    }

    /// Branches the source chat's provider session into the new chat.
    ///
    /// Best-effort by design: the fork is a convenience, and a harness that
    /// cannot fork — or a source that has never run — should still yield a
    /// usable empty chat rather than failing the creation the user asked for.
    private func forkSession(
        from source: ChatRuntime,
        into runtime: ChatRuntime,
        harness harnessKind: HarnessKind
    ) async {
        guard harnessRegistry.harness(for: harnessKind)?.capabilities.supportsSessionFork == true,
              let previous = try? await store.latestSession(for: source.record.chatID),
              let providerSessionID = previous.providerSessionID
        else { return }
        _ = try? await ensureSession(
            SessionRequest(
                harness: harnessKind,
                model: runtime.record.model,
                resume: .fork(providerSessionID: providerSessionID)
            ),
            chatID: runtime.record.chatID
        )
    }

    public func closeChat(_ chatID: ChatID, closed: Bool = true) async throws -> ChatSummary {
        let runtime = try await runtime(for: chatID)
        if closed { await stopSession(chatID: chatID) }
        runtime.record.isClosed = closed
        try await store.saveChat(runtime.record)
        publishChatChange(runtime)
        return try await summary(for: runtime)
    }

    public func renameChat(
        _ chatID: ChatID,
        title: String,
        userInitiated: Bool = false
    ) async throws -> ChatSummary {
        let runtime = try await runtime(for: chatID)
        let proposed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposed.isEmpty else { return try await summary(for: runtime) }
        let used = Set(chats.values.filter { $0.record.chatID != chatID }.map { $0.record.title })
        runtime.record.title = ResearchIdentity.unique(proposed, excluding: used)
        // A name the user typed is theirs to keep; automatic research-title
        // assignment must not claim it, so it only ever sets the flag true.
        if userInitiated { runtime.record.isTitleUserSet = true }
        try await store.saveChat(runtime.record)
        publishChatChange(runtime)
        return try await summary(for: runtime)
    }

    public func setDraft(chatID: ChatID, text: String) async throws -> ChatSummary {
        let runtime = try await runtime(for: chatID)
        runtime.record.draftText = text
        try await store.saveChat(runtime.record)
        publishChatChange(runtime)
        return try await summary(for: runtime)
    }

    public func switchHarness(
        chatID: ChatID,
        harness: HarnessKind,
        model: String?
    ) async throws -> ChatSummary {
        let runtime = try await runtime(for: chatID)
        guard harnessRegistry.harness(for: harness) != nil else {
            throw OreCoreError.harnessUnavailable(harness)
        }
        if runtime.record.harness == harness.rawValue {
            return try await setModel(chatID: chatID, model: model)
        }

        let previousHarness = HarnessKind(rawValue: runtime.record.harness)
        let previousModel = runtime.record.model
        runtime.handoffContext = try await store.handoffContext(chatID: chatID)
        await stopSession(chatID: chatID)
        runtime.record.harness = harness.rawValue
        runtime.record.model = model
        runtime.record.lastActivityAt = Date()
        try await store.saveChat(runtime.record)
        try await store.saveChatTransition(ChatTransition(
            chatID: chatID,
            kind: .harnessChanged,
            fromHarness: previousHarness,
            toHarness: harness,
            fromModel: previousModel,
            toModel: model
        ))
        publishChatChange(runtime)
        let result = try await summary(for: runtime)
        scheduleQueueDrain(runtime: runtime)
        return result
    }

    public func setModel(chatID: ChatID, model: String?) async throws -> ChatSummary {
        let runtime = try await runtime(for: chatID)
        let previousModel = runtime.record.model
        guard previousModel != model else { return try await summary(for: runtime) }
        if let session = runtime.session {
            do {
                try await session.setModel(model)
            } catch HarnessError.unsupportedCapability {
                guard !runtime.isTurnActive else {
                    throw OreCoreError.modelChangeRequiresIdle(chatID)
                }
                runtime.handoffContext = try await store.handoffContext(chatID: chatID)
                await stopSession(chatID: chatID)
            }
        }
        runtime.record.model = model
        runtime.record.lastActivityAt = Date()
        try await store.saveChat(runtime.record)
        try await store.saveChatTransition(ChatTransition(
            chatID: chatID,
            kind: .modelChanged,
            fromHarness: HarnessKind(rawValue: runtime.record.harness),
            toHarness: HarnessKind(rawValue: runtime.record.harness),
            fromModel: previousModel,
            toModel: model
        ))
        await syncWorkspaceCompatibility(from: runtime)
        publishChatChange(runtime)
        let result = try await summary(for: runtime)
        scheduleQueueDrain(runtime: runtime)
        return result
    }

    public func setEffort(chatID: ChatID, effort: ReasoningEffort?) async throws -> ChatSummary {
        let runtime = try await runtime(for: chatID)
        let raw = effort?.rawValue
        guard runtime.record.reasoningEffort != raw else { return try await summary(for: runtime) }
        runtime.record.reasoningEffort = raw
        try await store.saveChat(runtime.record)
        publishChatChange(runtime)
        return try await summary(for: runtime)
    }

    private func summary(for runtime: ChatRuntime) async throws -> ChatSummary {
        runtime.queuedMessageCount = try await store.queuedMessages(chatID: runtime.record.chatID).count
        return runtime.record.summary(
            status: runtime.status,
            capabilities: harnessRegistry.harness(
                for: HarnessKind(rawValue: runtime.record.harness) ?? .claudeCode
            )?.capabilities ?? HarnessCapabilities(),
            queuedMessageCount: runtime.queuedMessageCount,
            isTurnActive: runtime.isTurnActive,
            contextUsage: runtime.latestUsage
        )
    }

    private func syncWorkspaceCompatibility(from runtime: ChatRuntime) async {
        guard runtime.record.sortIndex == 0 else { return }
        record.harness = runtime.record.harness
        record.model = runtime.record.model
        record.permissionMode = runtime.record.permissionMode
        try? await store.saveWorkspace(record)
        publishSummaryChange()
    }

    public func ensureSession(
        _ request: SessionRequest? = nil,
        chatID: ChatID? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) async throws -> any AgentSession {
        let runtime = try await runtime(for: chatID)
        if let session = runtime.session { return session }

        let harnessKind = request?.harness
            ?? HarnessKind(rawValue: runtime.record.harness) ?? .claudeCode
        guard let harness = harnessRegistry.harness(for: harnessKind) else {
            throw HarnessError.executableNotFound(
                harnessKind,
                searchedPath: ShellEnvironment.searchPathDescription
            )
        }

        // Resuming continues the conversation the workspace already had —
        // switching to a workspace, or relaunching the app, must not mean
        // starting over.
        let previous = try? await store.latestSession(for: runtime.record.chatID)
        let resume: SessionRequest.ResumeMode
        var transcriptSessionID: SessionID?

        if let explicit = request?.resume, !isFresh(explicit) {
            resume = explicit
            // A fork deliberately branches the conversation, so it gets its
            // own transcript; a plain resume continues the existing one.
            if case .resume = explicit, let previous {
                transcriptSessionID = SessionID(rawValue: previous.id)
            }
        } else if let previous,
                  previous.harness == harnessKind.rawValue,
                  let providerSessionID = previous.providerSessionID,
                  harness.capabilities.supportsResume {
            resume = .resume(providerSessionID: providerSessionID)
            transcriptSessionID = SessionID(rawValue: previous.id)
        } else {
            resume = .fresh
        }

        var environmentOverrides: [String: String] = [:]
        if harnessKind == .claudeCode, let reasoningEffort {
            // Claude Code's supported, non-persistent session override. Older
            // CLI builds simply ignore this environment variable.
            environmentOverrides["CLAUDE_CODE_EFFORT_LEVEL"] = reasoningEffort.rawValue
        }

        let configuration = SessionConfiguration(
            workingDirectory: worktreeURL,
            model: request?.model ?? runtime.record.model,
            permissionMode: request?.permissionMode
                ?? PermissionMode(rawValue: runtime.record.permissionMode) ?? .default,
            resume: resume,
            appendSystemPrompt: systemPromptAddition(handoffContext: runtime.handoffContext),
            environmentOverrides: environmentOverrides,
            allowAPIKeyFallback: allowAPIKeyFallback,
            mcpServer: oreMCPServer(),
            // The assistant's ORE tools never prompt at the CLI layer: the
            // real gate is ORE's own action policy, and a second prompt on
            // top of it is what makes an assistant feel like paperwork.
            allowedTools: record.workspaceKind == .assistant ? ["mcp__ore"] : []
        )

        let session = try await harness.makeSession(configuration)
        runtime.session = session
        runtime.sessionEffort = reasoningEffort
        runtime.handoffContext = nil

        // The transcript is the workspace's, not the process's. Resuming into
        // a fresh session id would split one conversation across rows and make
        // the history look like it restarted every time the app did.
        let writer = TranscriptWriter(
            store: store,
            sessionID: transcriptSessionID ?? session.id,
            harness: harnessKind,
            chatID: runtime.record.chatID
        )
        await writer.configure(workspaceID: workspaceID)
        runtime.transcript = writer

        // Consume before starting, so the first events can't be missed.
        let id = runtime.record.chatID
        runtime.sessionTask = Task { [weak self] in
            for await event in session.events {
                await self?.handle(event, chatID: id)
            }
        }
        try await session.start()
        return session
    }

    private func isFresh(_ mode: SessionRequest.ResumeMode) -> Bool {
        if case .fresh = mode { return true }
        return false
    }

    /// What ORE tells the agent about the workspace it's in. The assistant
    /// workspace gets its own identity instead — it isn't working on a
    /// project, it's the product's concierge across all of them.
    private func systemPromptAddition(handoffContext: String? = nil) -> String {
        var prompt: String
        if record.workspaceKind == .assistant {
            prompt = AssistantPrompt.systemPrompt(home: worktreeURL)
        } else {
            prompt = """
            You are working in an ORE workspace: an isolated git worktree on branch \
            `\(record.branch)`, based on `\(record.baseBranch)`.

            - Scratch space for plans, notes and attachments is in `.context/`. It is \
            excluded from git, so nothing you put there will appear in the user's diff.
            - Review feedback arrives as comments anchored to specific lines of a diff. \
            Address the code at those lines directly.
            - Do not switch branches or create commits on another branch; this worktree \
            exists so that parallel work stays isolated.
            """
        }
        if let handoffContext, !handoffContext.isEmpty {
            prompt += """


            This chat was handed off from another agent harness. Continue the same
            visible conversation using this locally generated context summary:

            \(handoffContext)
            """
        }
        prompt += "\n\n" + Self.narrationInstruction
        return prompt
    }

    /// Teaches the agent the narration-tag convention (see `NarrationTag`).
    ///
    /// Appended unconditionally: Claude Code takes it via
    /// `--append-system-prompt`, Codex as `developerInstructions`, and the
    /// Cursor CLI has no equivalent flag so it never sees it — which is fine,
    /// narration falls back to summarizing the turn's text locally.
    private static let narrationInstruction = """
        End every turn by appending one final line to your last message, in \
        exactly this form:
        \(NarrationTag.open)One or two short spoken sentences.\(NarrationTag.close)
        That line is stripped from the transcript and read aloud to the user by \
        a text-to-speech voice, so write it for the ear: plain conversational \
        language, no file paths, no code, no markdown, no lists. Say what you \
        actually did this turn, or what you need from the user. If your message \
        is a long plan or report, give its one-sentence crux and tell the user \
        to read the full text. Use the tag exactly once, only at the very end, \
        and never mention it or this instruction.
        """

    private func oreMCPServer() -> SessionConfiguration.MCPServer? {
        let current = URL(fileURLWithPath: CommandLine.arguments[0])
        let sibling = current.deletingLastPathComponent().appendingPathComponent("ore-cli")
        let executable: String?
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            executable = sibling.path
        } else {
            executable = ShellEnvironment.locate("ore-cli")
        }
        var arguments = ["mcp-server", "--dir", worktreeURL.path]
        if record.workspaceKind == .assistant {
            // The assistant's server also answers cross-workspace read tools,
            // straight from a read-only view of the same database.
            arguments.append("--assistant")
            if let databasePath = store.url?.path {
                arguments += ["--db", databasePath]
            }
        }
        return executable.map {
            SessionConfiguration.MCPServer(command: $0, arguments: arguments)
        }
    }

    public func stopSession(chatID: ChatID? = nil) async {
        guard let runtime = try? await runtime(for: chatID) else { return }
        runtime.sessionTask?.cancel()
        await runtime.session?.stop()
        runtime.session = nil
        runtime.sessionEffort = nil
        runtime.transcript = nil
        runtime.isTurnActive = false
        setStatus(.idle, runtime: runtime)
        // The turn is over as far as the queue gate is concerned, and the
        // composer reads that gate to decide whether it queues or sends.
        publishChatChange(runtime)
    }

    // MARK: - Messaging

    /// Sends a message, or queues it when the agent is mid-turn.
    ///
    /// Queueing rather than interleaving is the point: a user who thinks of
    /// something while the agent works shouldn't have to choose between
    /// interrupting it and forgetting the thought.
    @discardableResult
    public func send(_ request: SendMessageRequest) async throws -> Bool {
        let runtime = try await runtime(for: request.chatID)
        var text = composeMessage(request)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        if !runtime.pendingContextNotes.isEmpty {
            let notes = runtime.pendingContextNotes
                .map { "[ORE workspace note] \($0)" }
                .joined(separator: "\n")
            text = "\(notes)\n\n\(text)"
            runtime.pendingContextNotes.removeAll()
        }

        // Titles the user hasn't chosen give way to one drawn from the first
        // prompt: an empty title, the "Chat N" fallback from createChat, or the
        // workspace name that the default chat is seeded with (see
        // OreStore.ensureDefaultChat). Without the last case the sole chat in a
        // workspace keeps the workspace's name forever, since it never matches
        // the "Chat " prefix. A title the user typed is left alone.
        let currentTitle = runtime.record.title
        // A title the user typed is never a placeholder — the whole point of
        // the flag is that a rename made before the first turn survives it.
        let isPlaceholderTitle = !runtime.record.isTitleUserSet
            && (currentTitle.isEmpty
                || currentTitle.hasPrefix("Chat ")
                || currentTitle == record.name
                || runtime.record.lastActivityAt == nil)
        if isPlaceholderTitle {
            let normalized = ResearchIdentity.taskTitle(from: request.text, fallback: currentTitle)
            if !normalized.isEmpty {
                let used = Set(chats.values
                    .filter { $0.record.chatID != runtime.record.chatID }
                    .map { $0.record.title })
                runtime.record.title = ResearchIdentity.unique(normalized, excluding: used)
                try await store.saveChat(runtime.record)
                publishChatChange(runtime)

                if !runtime.isGeneratingTitle {
                    runtime.isGeneratingTitle = true
                    let expectedChatTitle = runtime.record.title
                    let expectedWorkspaceName = record.name
                    let shouldRenameWorkspace = !record.isNameUserSet
                        && ResearchIdentity.matching(nameOrSlug: record.name) != nil
                    Task { [weak self] in
                        await self?.generateAndApplyTitle(
                            for: runtime.record.chatID,
                            prompt: request.text,
                            harness: HarnessKind(rawValue: runtime.record.harness) ?? .claudeCode,
                            model: runtime.record.model,
                            expectedChatTitle: expectedChatTitle,
                            expectedWorkspaceName: expectedWorkspaceName,
                            shouldRenameWorkspace: shouldRenameWorkspace
                        )
                    }
                }
            }
        }

        if runtime.isTurnActive, request.queueIfBusy {
            try await store.enqueueMessage(QueuedMessageRecord(
                workspaceID: workspaceID,
                chatID: runtime.record.chatID,
                text: text,
                attachmentPaths: request.attachments.map(\.relativePath),
                serviceTier: request.serviceTier,
                origin: request.origin,
                submissionID: request.submissionID
            ))
            runtime.queuedMessageCount += 1
            publishPromptSubmission(request, runtime: runtime, isQueued: true)
            publishChatChange(runtime)
            return false
        }
        // Announced before the session is ensured, which can take seconds while
        // a CLI boots. A prompt the client didn't originate — the assistant's,
        // or a new workspace's opening instruction — has to appear in the
        // transcript at the moment it is accepted, not once the harness answers.
        publishPromptSubmission(request, runtime: runtime, isQueued: false)

        // Claim the turn before the first suspension point, not after the last.
        //
        // This is an actor, so every `await` below is a place another `send` can
        // interleave — and `ensureSession` can spend seconds spawning a CLI. A
        // second message arriving in that window used to read `isTurnActive` as
        // false, skip the queue above, and hand a running harness a second
        // prompt: cursor-agent rejects that outright, and the message is lost.
        // Claiming first makes the queue gate cover the whole send.
        runtime.isTurnActive = true
        do {
            let harnessKind = HarnessKind(rawValue: runtime.record.harness) ?? .claudeCode
            let storedEffort = runtime.record.reasoningEffort
                .flatMap(ReasoningEffort.init(rawValue:))
            let requestedEffort = harnessKind.supportsReasoningEffort
                ? (request.reasoningEffort ?? storedEffort)
                : nil
            if harnessKind == .claudeCode,
               runtime.session != nil,
               let requestedEffort,
               runtime.sessionEffort != requestedEffort {
                // Claude's effort override is session-scoped. Restarting and
                // resuming the provider session applies the new level without
                // losing the conversation.
                await stopSession(chatID: runtime.record.chatID)
                // `stopSession` releases the claim on its way past; the turn this
                // call is about to start still needs it held.
                runtime.isTurnActive = true
            }
            let session = try await ensureSession(
                chatID: runtime.record.chatID,
                reasoningEffort: requestedEffort
            )
            try await captureCheckpoint(runtime: runtime)
            await runtime.transcript?.recordPrompt(
                text,
                attachments: request.attachments,
                origin: request.origin
            )
            var modelText = text
            if let hidden = request.hiddenContext?
                .trimmingCharacters(in: .whitespacesAndNewlines), !hidden.isEmpty {
                modelText = "\(hidden)\n\n\(text)"
            }
            try await session.send(UserMessage(
                text: modelText,
                attachmentPaths: request.attachments.map(\.relativePath),
                reasoningEffort: requestedEffort,
                serviceTier: request.serviceTier
            ))
        } catch {
            // The turn never started. Releasing the claim keeps the composer, and
            // anything queued behind it, from waiting on a completion that can
            // never arrive. Surface it as a session error so the composer can
            // offer Upgrade CLI / Retry rather than a toast of raw JSON.
            runtime.isTurnActive = false
            let raw = (error as? HarnessError)?.description ?? error.localizedDescription
            let message = ProviderErrorCopy.unwrap(raw)
            await handle(.sessionError(SessionError(
                kind: ProviderErrorCopy.sessionKind(for: message),
                message: message,
                detail: raw == message ? nil : raw,
                isRecoverable: true
            )), chatID: runtime.record.chatID)
            publishChatChange(runtime)
            return false
        }
        publishChatChange(runtime)

        if !request.diffComments.isEmpty {
            try? await store.markDiffCommentsSent(workspaceID: workspaceID)
        }
        return true
    }

    /// Uses the same local CLI and subscription the user selected for the chat,
    /// but in a short, isolated session. Naming never pollutes the working
    /// conversation's context and the heuristic title remains a graceful
    /// fallback if the auxiliary request cannot run.
    private func generateAndApplyTitle(
        for chatID: ChatID,
        prompt: String,
        harness harnessKind: HarnessKind,
        model: String?,
        expectedChatTitle: String,
        expectedWorkspaceName: String,
        shouldRenameWorkspace: Bool
    ) async {
        guard let runtime = chats[chatID] else { return }
        defer { runtime.isGeneratingTitle = false }
        guard let generated = await generateTitle(
            from: prompt,
            harness: harnessKind,
            model: model
        ) else { return }

        // A title explicitly changed while the auxiliary request was running
        // always wins over the generated suggestion.
        if runtime.record.title == expectedChatTitle {
            let usedChatTitles = Set(chats.values
                .filter { $0.record.chatID != chatID }
                .map { $0.record.title })
            runtime.record.title = ResearchIdentity.unique(generated, excluding: usedChatTitles)
            try? await store.saveChat(runtime.record)
            publishChatChange(runtime)
        }

        if shouldRenameWorkspace, record.name == expectedWorkspaceName {
            let usedWorkspaceNames = Set(
                ((try? await store.workspaces(includeArchived: true)) ?? [])
                    .filter { $0.workspaceID != workspaceID }
                    .map(\.name)
            )
            record.name = ResearchIdentity.unique(generated, excluding: usedWorkspaceNames)
            try? await persistRecord()
            publishSummaryChange()
        }
    }

    private func generateTitle(
        from userPrompt: String,
        harness harnessKind: HarnessKind,
        model: String?
    ) async -> String? {
        guard let harness = harnessRegistry.harness(for: harnessKind),
              harness.supportsAuxiliarySessions
        else { return nil }
        // Name with the cheapest model of the chat's own (already authenticated)
        // harness rather than whatever expensive model the user picked — Haiku
        // for Claude, the harness default elsewhere. Keeping the same harness
        // avoids assuming another one is installed/signed in.
        let namingModel: String? = harnessKind == .claudeCode
            ? "claude-haiku-4-5-20251001"
            : nil
        let configuration = SessionConfiguration(
            workingDirectory: worktreeURL,
            model: namingModel,
            permissionMode: .plan,
            appendSystemPrompt: "Do not use tools. Return only the requested short title.",
            environmentOverrides: harnessKind == .claudeCode
                ? ["CLAUDE_CODE_EFFORT_LEVEL": ReasoningEffort.low.rawValue]
                : [:],
            allowAPIKeyFallback: allowAPIKeyFallback
        )

        guard let session = try? await harness.makeSession(configuration) else { return nil }
        do {
            try await session.start()
            try await session.send(UserMessage(
                text: """
                Name this software task from the user's request below. Return only a clear, specific title of 2–6 words. Do not quote it, explain it, or end it with punctuation.

                User request:
                \(userPrompt.prefix(4_000))
                """,
                reasoningEffort: .low
            ))
        } catch {
            await session.stop()
            return nil
        }

        let result = await withTaskGroup(of: String?.self, returning: String?.self) { group in
            group.addTask {
                var completedBlocks: [String] = []
                var streamed = ""
                for await event in session.events {
                    if Task.isCancelled { return nil }
                    switch event {
                    case .textDelta(let delta): streamed += delta.text
                    case .blockCompleted(let block) where block.kind == .text:
                        completedBlocks.append(block.text)
                    case .turnCompleted(let result):
                        // A failed naming turn still produces prose — a usage
                        // limit notice, a provider error — and that prose is
                        // shaped exactly like a title. Adopting it is how a
                        // workspace ended up called "You've hit your session
                        // limit". Nothing a failed turn said is a name.
                        guard result.outcome == .completed else { return nil }
                        return completedBlocks.last ?? streamed
                    case .sessionError, .sessionEnded:
                        return nil
                    default:
                        break
                    }
                }
                return completedBlocks.last ?? (streamed.isEmpty ? nil : streamed)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(30))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        await session.stop()
        return result.flatMap(Self.cleanGeneratedTitle)
    }

    private static func cleanGeneratedTitle(_ raw: String) -> String? {
        var title = raw
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "`'\"*_#—–-:;.!? "))
        for prefix in ["Title:", "Task:", "Name:"] where title.lowercased().hasPrefix(prefix.lowercased()) {
            title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let words = title.split(whereSeparator: \.isWhitespace).prefix(6)
        title = words.joined(separator: " ")
        guard words.count >= 2, title.count <= 64 else { return nil }
        guard !isRefusalOrError(title) else { return nil }
        return title
    }

    /// A second gate behind the failed-turn check, for providers that report a
    /// limit or refusal as ordinary assistant text on a turn they call
    /// successful. Short apologies and quota notices pass every structural test
    /// a title has — length, word count, no punctuation — so they have to be
    /// recognised by what they say.
    private static func isRefusalOrError(_ title: String) -> Bool {
        let value = title.lowercased()
        let markers = [
            "session limit", "usage limit", "rate limit", "rate-limit",
            "quota", "too many requests", "try again later", "upgrade to",
            "i can't", "i cannot", "i'm unable", "i am unable", "sorry",
            "unable to", "error", "failed to", "no response",
        ]
        return markers.contains { value.contains($0) }
    }

    /// Folds diff comments into the prompt with enough anchoring that the agent
    /// can act on them without being told which file to open.
    private func composeMessage(_ request: SendMessageRequest) -> String {
        guard !request.diffComments.isEmpty else { return request.text }

        var sections: [String] = []
        if !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(request.text)
        }
        sections.append("Review comments on the current diff:")

        for comment in request.diffComments {
            let location = comment.startLine == comment.endLine
                ? "\(comment.filePath):\(comment.startLine)"
                : "\(comment.filePath):\(comment.startLine)-\(comment.endLine)"
            var section = "\n**\(location)**\n\(comment.body)"
            if let context = comment.context, !context.isEmpty {
                section += "\n\n```\n\(context)\n```"
            }
            sections.append(section)
        }
        return sections.joined(separator: "\n")
    }

    /// Drains the queue after a turn ended somewhere other than `.turnCompleted`
    /// — a model or agent switch, or a provider session that died mid-turn.
    ///
    /// Without this the queued message is stranded forever: the drain only ran
    /// on turn completion, and a session that was stopped rather than finished
    /// never emits one. The user sees "Queued messages (1)" and an idle agent,
    /// and the only way out is to retype the message.
    ///
    /// Detached so the caller — usually a `setModel` the UI is awaiting — isn't
    /// blocked on the replacement session starting up.
    private func scheduleQueueDrain(runtime: ChatRuntime) {
        guard runtime.queuedMessageCount > 0 else { return }
        Task { [weak self] in await self?.drainQueue(runtime: runtime) }
    }

    private func drainQueue(runtime: ChatRuntime) async {
        guard !runtime.isTurnActive else { return }
        guard let next = try? await store.dequeueMessage(chatID: runtime.record.chatID) else { return }
        runtime.queuedMessageCount = max(0, runtime.queuedMessageCount - 1)
        _ = try? await send(SendMessageRequest(
            workspaceID: workspaceID,
            chatID: runtime.record.chatID,
            text: next.text,
            attachments: next.paths.map {
                Attachment(relativePath: $0, displayName: FilePath.lastComponent($0))
            },
            queueIfBusy: false,
            serviceTier: next.serviceTier,
            origin: next.messageOrigin,
            // Reusing the id the message was queued under is what stops the
            // client from drawing it twice: once as the queued row it already
            // has, and again when the queue finally lets it through. Rows
            // queued before this column existed carry no id, and a shared empty
            // string would make every one of them look like the same message.
            submissionID: next.submissionID.isEmpty
                ? UUID().uuidString
                : next.submissionID
        ))
        // `send` doesn't publish on its success path, and the drain can run
        // after the caller's own publish, so the count the queue card watches
        // has to be republished here or the card outlives the message.
        publishChatChange(runtime)
    }

    public func interrupt(chatID: ChatID? = nil) async throws {
        let runtime = try await runtime(for: chatID)
        try await runtime.session?.interrupt()
        runtime.isTurnActive = false
        publishChatChange(runtime)
    }

    /// Switches the running chat's permission mode. Never requires a new chat.
    ///
    /// The stored mode is written first and unconditionally: it is what any
    /// later spawn is configured from, so losing it because a live session
    /// refused the change is what used to leave "Accept Edits" selected in the
    /// UI and nothing accepting edits.
    public func setPermissionMode(_ mode: PermissionMode, chatID: ChatID? = nil) async throws {
        let runtime = try await runtime(for: chatID)
        guard PermissionMode(rawValue: runtime.record.permissionMode) != mode else { return }
        runtime.record.permissionMode = mode.rawValue
        try await store.saveChat(runtime.record)

        if let session = runtime.session {
            do {
                try await session.setPermissionMode(mode)
            } catch HarnessError.unsupportedCapability {
                // A harness that can only take the mode at launch. Recycling
                // the session while idle makes the change real for the next
                // turn; mid-turn we leave the turn alone and it lands when the
                // session is next started.
                if !runtime.isTurnActive {
                    runtime.handoffContext = try await store.handoffContext(
                        chatID: runtime.record.chatID
                    )
                    await stopSession(chatID: runtime.record.chatID)
                    // Nothing will complete a turn now to trigger the drain, so
                    // anything queued behind the stopped session would strand.
                    scheduleQueueDrain(runtime: runtime)
                }
            }
        }

        await syncWorkspaceCompatibility(from: runtime)
        publishChatChange(runtime)
    }

    public func resolvePermission(
        _ id: PermissionRequestID,
        with decision: PermissionDecision,
        chatID: ChatID? = nil
    ) async throws {
        let runtime = try await runtime(for: chatID)
        runtime.pendingPermissions.removeValue(forKey: id)

        // The CLI applies a `setMode` suggestion in the permission reply
        // itself. Mirror it into the stored mode so the composer chip — which
        // reads this, not the CLI — doesn't keep showing Ask.
        if let mode = decision.impliedPermissionMode,
           PermissionMode(rawValue: runtime.record.permissionMode) != mode {
            runtime.record.permissionMode = mode.rawValue
            try await store.saveChat(runtime.record)
            await syncWorkspaceCompatibility(from: runtime)
            publishChatChange(runtime)
        }

        try await runtime.session?.resolvePermission(id, with: decision)
    }

    public func answerQuestion(
        _ id: QuestionID,
        answer: String,
        chatID: ChatID? = nil
    ) async throws {
        let runtime = try await runtime(for: chatID)
        runtime.pendingQuestions.removeValue(forKey: id)
        resumeTurnAfterInput(runtime: runtime)
        try await runtime.session?.answerQuestion(id, answer: answer)
    }

    // MARK: - Checkpoints

    /// Snapshots the worktree before a turn runs, with the agent quiesced.
    private func captureCheckpoint(runtime: ChatRuntime) async throws {
        let turnID = TurnID.generate()
        guard let checkpoint = try? await checkpoints.capture(
            worktree: worktreeURL,
            workspaceID: workspaceID,
            turnID: turnID,
            providerSessionID: await runtime.session?.providerSessionID
        ) else { return }

        await runtime.transcript?.recordCheckpoint(
            commit: checkpoint.commit,
            providerSessionID: checkpoint.providerSessionID
        )
        await pruneCheckpoints()
    }

    /// How many turns back a revert can still reach. Deep on purpose: pruning a
    /// checkpoint makes that turn unrevertable, so it must only ever reach
    /// history nobody is going back to.
    private static let checkpointDepth = 250

    /// How many checkpoints may be captured before the next sweep. Sweeping on
    /// every turn put a transcript read on the path a queued message drains
    /// through, for a condition that can only become true once in fifty turns.
    private static let checkpointPruneInterval = 50
    private var checkpointsSincePrune = 0

    /// Drops checkpoint refs for turns far enough back that no one will revert
    /// to them, so a long-lived workspace stops accumulating one pinned tree
    /// per turn it has ever run.
    ///
    /// Best-effort, and always after the checkpoint the current turn needs:
    /// losing old snapshots is a cost worth paying, failing to take a new one
    /// is not.
    private func pruneCheckpoints() async {
        checkpointsSincePrune += 1
        guard checkpointsSincePrune >= Self.checkpointPruneInterval else { return }
        checkpointsSincePrune = 0

        var turns: [TurnRecord] = []
        for chatID in chats.keys {
            turns += (try? await store.turns(chatID: chatID)) ?? []
        }
        guard turns.count > Self.checkpointDepth else { return }
        let keep = Set(
            turns.sorted { $0.startedAt > $1.startedAt }
                .prefix(Self.checkpointDepth)
                .map { TurnID(rawValue: $0.id) }
        )
        try? await checkpoints.prune(workspaceID: workspaceID, keeping: keep)
    }

    /// Reverts the workspace to the state a turn started from.
    ///
    /// Both halves have to move together. Restoring the files alone leaves the
    /// agent remembering work that no longer exists, and it will happily build
    /// on that memory — so the conversation is forked back to the same instant.
    public func revert(to turnID: TurnID, chatID: ChatID? = nil) async throws {
        let runtime = try await runtime(for: chatID)
        guard let turn = try await store.turn(turnID),
              let commit = turn.checkpointCommit,
              let turnSession = try await store.session(SessionID(rawValue: turn.sessionID))
        else { throw OreCoreError.noCheckpoint(turnID) }

        await stopSession(chatID: runtime.record.chatID)

        try await checkpoints.restore(
            worktree: worktreeURL,
            to: Checkpoint(
                workspaceID: workspaceID,
                turnID: turnID,
                commit: commit,
                ref: CheckpointStore.ref(workspaceID: workspaceID, turnID: turnID),
                providerSessionID: turn.checkpointProviderSessionID
            )
        )

        try await store.deleteTranscriptFrom(chatID: runtime.record.chatID, turnID: turnID)

        runtime.record.harness = turnSession.harness
        runtime.record.model = turnSession.model
        try await store.saveChat(runtime.record)
        await syncWorkspaceCompatibility(from: runtime)

        // Fork rather than resume: the original session stays intact, so a
        // revert is undoable and two branches of the conversation can coexist.
        if let providerSessionID = turn.checkpointProviderSessionID {
            _ = try? await ensureSession(SessionRequest(
                harness: HarnessKind(rawValue: turnSession.harness) ?? .claudeCode,
                model: turnSession.model,
                resume: .fork(providerSessionID: providerSessionID)
            ), chatID: runtime.record.chatID)
        }

        await statusWatcher?.refreshNow()
    }

    // MARK: - Review

    public func diff(againstBase: Bool = true) async throws -> [FileDiff] {
        againstBase
            ? try await diffEngine.diffAgainstBase(
                worktree: worktreeURL, baseBranch: record.baseBranch
            )
            : try await diffEngine.workingTreeDiff(worktree: worktreeURL)
    }

    public func addDiffComment(_ reference: DiffCommentReference) async throws {
        try await ingestPostedComments()
        _ = try await store.addDiffComment(DiffCommentRecord(
            workspaceID: workspaceID,
            filePath: reference.filePath,
            startLine: reference.startLine,
            endLine: reference.endLine,
            body: reference.body,
            context: reference.context
        ))
        try await persistPendingComments()
    }

    public func pendingDiffComments() async throws -> [DiffCommentReference] {
        try await ingestPostedComments()
        return try await store.pendingDiffComments(workspaceID: workspaceID).map(\.reference)
    }

    /// Agent `PostDiffComment` writes the JSON file; the Review pane and the
    /// next send read the database. Pull new file entries in so the two stay
    /// one list — and so a UI comment cannot wipe the agent's.
    private func ingestPostedComments() async throws {
        let incoming = DiffCommentFile.load(in: worktreeURL)
        guard !incoming.isEmpty else { return }
        let existing = try await store.pendingDiffComments(workspaceID: workspaceID)
        var seen: Set<String> = Set(existing.map {
            "\($0.filePath):\($0.startLine):\($0.endLine):\($0.body)"
        })
        var added = false
        for comment in incoming {
            let key = "\(comment.filePath):\(comment.startLine):\(comment.endLine):\(comment.body)"
            guard seen.insert(key).inserted else { continue }
            _ = try await store.addDiffComment(DiffCommentRecord(
                workspaceID: workspaceID,
                filePath: comment.filePath,
                startLine: comment.startLine,
                endLine: comment.endLine,
                body: comment.body,
                context: comment.context
            ))
            added = true
        }
        if added { try await persistPendingComments() }
    }

    private func persistPendingComments() async throws {
        let comments = try await store.pendingDiffComments(workspaceID: workspaceID).map(\.reference)
        try DiffCommentFile.save(comments, in: worktreeURL)
    }

    public func conflictHunks(path: String) throws -> [ConflictHunk] {
        let url = worktreeURL.appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return ConflictMarkers.hunks(in: text)
    }

    public func resolveConflict(path: String, side: ConflictSide) async throws {
        try await git.checkoutConflictSide(side, path: path, in: worktreeURL)
        await statusWatcher?.refreshNow()
    }

    public func resolveConflictHunk(
        path: String,
        startLine: Int,
        side: ConflictSide
    ) async throws {
        let url = worktreeURL.appendingPathComponent(path)
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let next = ConflictMarkers.resolving(
            text, hunkStartingAt: startLine, side: side
        ) else {
            throw OreCoreError.conflictHunkMissing(path, startLine)
        }
        try next.write(to: url, atomically: true, encoding: .utf8)
        if ConflictMarkers.hunks(in: next).isEmpty {
            try await git.runSerialized(["add", "--", path], in: worktreeURL)
        }
        await statusWatcher?.refreshNow()
    }

    public func turnCheckpoints(chatID: ChatID) async throws -> [TurnCheckpoint] {
        try await store.turns(chatID: chatID).compactMap { turn in
            guard let commit = turn.checkpointCommit else { return nil }
            return TurnCheckpoint(
                turnID: TurnID(rawValue: turn.id),
                ordinal: turn.ordinal,
                commit: commit,
                summary: turn.summary,
                prompt: turn.prompt
            )
        }
    }

    public func diffFromCheckpoint(_ commit: String) async throws -> [FileDiff] {
        try await diffEngine.diffFromCommit(worktree: worktreeURL, commit: commit)
    }

    public func diffBetweenTurnCheckpoints(from: String, to: String) async throws -> [FileDiff] {
        try await diffEngine.diffBetweenCheckpoints(
            worktree: worktreeURL, from: from, to: to
        )
    }

    public func rerunFailedChecks() async throws {
        try await gitHub.rerunFailedChecks(forBranch: record.branch)
    }

    public func checkLog(named name: String) async -> String? {
        await gitHub.checkLog(named: name, forBranch: record.branch)
    }

    public func stackNeighbors() async throws -> (parent: WorkspaceRecord?, children: [WorkspaceRecord]) {
        let parent: WorkspaceRecord?
        if let parentID = record.stackedOnWorkspaceID {
            parent = try await store.workspace(WorkspaceID(rawValue: parentID))
        } else {
            parent = nil
        }
        return (parent, try await store.children(of: workspaceID))
    }

    // MARK: - Git actions

    /// Gathers the state the action resolver needs. Only this part does I/O;
    /// the decision itself is a pure function.
    public func gitActionContext() async -> GitActionContext {
        let gitHubStatus = await gitHub.status()
        let pullRequest = gitHubStatus.isAuthenticated
            ? await gitHub.pullRequest(forBranch: record.branch)
            : nil

        var parentBranch: String?
        var parentPullRequest: GitHubClient.PullRequest?
        if let parentID = record.stackedOnWorkspaceID,
           let parent = try? await store.workspace(WorkspaceID(rawValue: parentID)) {
            parentBranch = parent.branch
            if gitHubStatus.isAuthenticated {
                parentPullRequest = await gitHub.pullRequest(forBranch: parent.branch)
            }
        }

        // Read the working tree live so the suggested action agrees with the
        // diff, which is always computed live against the base. The cached
        // `gitStatus` can lag the tree by a debounce/poll interval, and that gap
        // showed up as a "No changes" action sitting next to a real diff.
        let liveStatus = await statusWatcher?.currentSnapshot()?.summary() ?? gitStatus

        return GitActionContext(
            hasUncommittedChanges: liveStatus.hasUncommittedChanges,
            changedFileCount: liveStatus.changedFileCount,
            insertions: liveStatus.insertions,
            deletions: liveStatus.deletions,
            unpushedCommitCount: await unpushedCommitCount(),
            commitsAheadOfBase: await git.commitsAheadOfBase(
                record.baseBranch, in: worktreeURL
            ),
            hasUpstream: await hasUpstream(),
            hasRemote: await git.hasRemote(),
            baseBranch: record.baseBranch,
            pullRequest: pullRequest,
            gitHubStatus: gitHubStatus,
            parentBranch: parentBranch,
            parentPullRequest: parentPullRequest,
            wouldConflictWithOriginDefault: baseSync?.wouldConflict ?? false
        )
    }

    public func suggestedGitAction() async -> SuggestedGitAction {
        SuggestedGitActionResolver.resolve(await gitActionContext())
    }

    /// Hands a failing CI run to the agent.
    public func forwardFailingChecks() async throws {
        guard let logs = await gitHub.failedCheckLogs(forBranch: record.branch) else {
            throw OreCoreError.noFailingChecks
        }
        _ = try await send(SendMessageRequest(
            workspaceID: workspaceID,
            text: """
            CI is failing on this branch. Here are the failing job logs — please \
            diagnose and fix the cause, then explain what was wrong.

            \(logs)
            """,
            queueIfBusy: false
        ))
    }

    /// Rolls the workspace forward after its PR merged: pull the repository's
    /// default branch (`main`/`master`) into the local ref, then cut a fresh
    /// branch from that local default in this same worktree.
    ///
    /// A fresh branch rather than a rebase: the merged branch's work now lives
    /// in the default branch, and continuing on top of it would show
    /// already-merged commits in every diff and PR that follows. Archive is
    /// never implied — the worktree stays until the user archives it.
    public func continueAfterMerge() async throws {
        guard let pullRequest = await gitHub.pullRequest(forBranch: record.branch),
              pullRequest.isMerged
        else { throw OreCoreError.pullRequestNotMerged(record.branch) }

        // Uncommitted work used to stop this dead — "commit or discard first".
        // But the reason to continue is to keep working, and the edits in
        // flight *are* that work; making the user commit half a thought just to
        // get a fresh branch is a decision they shouldn't have to make. They
        // come along instead, still uncommitted, exactly as they were.
        let defaultBranch = await git.defaultBranch()
        try await pullDefaultBranch(forceFetch: true)
        let newBranch = try await git.unusedBranchName(stem: nextContinueStem())

        let carried = try await BranchSwitch(git: git, worktree: worktreeURL)
            .create(newBranch, from: defaultBranch)

        let baseSHA = (try? await git.run(
            ["rev-parse", "--short", "HEAD"], in: worktreeURL
        ).trimmedStandardOutput) ?? "HEAD"

        let oldBranch = record.branch
        record.branch = newBranch
        record.baseBranch = defaultBranch
        try await persistRecord()
        publishSummaryChange()
        await statusWatcher?.refreshNow()
        await refreshBaseSync(forceFetch: false)

        let carriedNote = carried
            ? " The uncommitted changes from the old branch came across and are " +
              "still uncommitted here."
            : ""
        let memo = """
        PR #\(pullRequest.number) (\(pullRequest.title)) was merged into \(defaultBranch). \
        The old branch `\(oldBranch)` is done; this workspace continues on the fresh \
        branch `\(newBranch)`, cut from local `\(defaultBranch)` at \(baseSHA).\(carriedNote)
        """
        try await recordWorkspaceMemo(memo)
    }

    /// Fast-forward the local default branch from origin without checking it
    /// out in this worktree.
    public func pullDefaultBranch(forceFetch: Bool = true) async throws {
        guard await git.hasRemote() else { return }
        let defaultBranch = await git.defaultBranch()
        try await git.fetchRemoteBranch(defaultBranch, force: forceFetch)
        try await git.fastForwardLocalBranch(defaultBranch, to: "origin/\(defaultBranch)")
        await refreshBaseSync(forceFetch: false)
    }

    /// `ore/foo` → `ore/foo-2` → `ore/foo-3`…, reusing the numbering idiom from
    /// WorktreeManager.uniqueBranch.
    private func nextContinueStem() -> String {
        record.branch.replacingOccurrences(
            of: #"-\d+$"#, with: "", options: .regularExpression
        )
    }

    /// Persists a memo as a synthetic completed turn (so it renders in the
    /// transcript and is search-indexed) and stages it as a context note for
    /// the agent's next real turn.
    private func recordWorkspaceMemo(_ memo: String) async throws {
        let runtime = try await runtime(for: nil)
        let chatID = runtime.record.chatID

        let session: SessionRecord
        if let existing = try await store.latestSession(for: chatID) {
            session = existing
        } else {
            session = SessionRecord(
                id: SessionID.generate(),
                workspaceID: workspaceID,
                chatID: chatID,
                harness: HarnessKind(rawValue: runtime.record.harness) ?? .claudeCode,
                model: runtime.record.model
            )
            try await store.saveSession(session)
        }

        let turnID = TurnID.generate()
        let now = Date()
        try await store.saveTurn(TurnRecord(
            id: turnID,
            sessionID: SessionID(rawValue: session.id),
            ordinal: try await store.nextTurnOrdinal(sessionID: SessionID(rawValue: session.id)),
            outcome: .completed,
            summary: memo,
            startedAt: now,
            endedAt: now
        ))
        try await store.appendBlock(BlockRecord(
            id: "memo-\(turnID.rawValue)",
            turnID: turnID,
            ordinal: 0,
            kind: .text,
            text: memo
        ))

        runtime.pendingContextNotes.append(memo)
        runtime.record.hasUnread = true
        try? await store.saveChat(runtime.record)
        publishChatChange(runtime)
    }

    /// The commits the ship panel lists: not yet on any remote, or — with no
    /// remote at all — everything ahead of the base. Comparing only against
    /// `@{upstream}` treated fast-forwards onto `origin/main` as unpushed work.
    public func unpushedCommits(limit: Int = 50) async -> [CommitInfo] {
        (try? await git.unpushedCommits(
            fallbackRange: "\(record.baseBranch)..HEAD",
            in: worktreeURL,
            limit: limit
        )) ?? []
    }

    /// Live staged / unstaged files for the ship panel and the Changes list.
    public func workingTreeStatus() async -> GitStatusSnapshot? {
        await statusWatcher?.currentSnapshot()
    }

    public func currentPullRequest() async -> GitHubClient.PullRequest? {
        guard await gitHub.status().isAuthenticated else { return nil }
        return await gitHub.pullRequest(forBranch: record.branch)
    }

    private func unpushedCommitCount() async -> Int {
        if await git.hasRemote() {
            return await git.unpushedCommitCount(in: worktreeURL)
        }
        return await git.commitsAheadOfBase(record.baseBranch, in: worktreeURL)
    }

    private func hasUpstream() async -> Bool {
        (try? await git.run(
            ["rev-parse", "--abbrev-ref", "@{upstream}"], in: worktreeURL
        )) != nil
    }

    // MARK: - Status watching

    private func startStatusWatching() async {
        guard statusWatcher == nil else { return }
        let watcher = StatusWatcher(git: git, worktreeURL: worktreeURL)
        statusWatcher = watcher

        statusTask = Task { [weak self] in
            for await snapshot in watcher.updates {
                await self?.applyStatus(snapshot)
            }
        }
        await watcher.start()
    }

    private func applyStatus(_ snapshot: GitStatusSnapshot) {
        // Out-of-order FSEvents batches are discarded rather than applied.
        guard snapshot.generation >= gitStatus.generation else { return }
        gitStatus = snapshot.summary(
            aheadOfBase: gitStatus.aheadOfBase,
            behindBase: baseSync?.workspaceBehindOrigin ?? gitStatus.behindBase
        )
        publishSummaryChange()
    }

    private func startBaseSyncWatching() async {
        guard baseSyncTask == nil else { return }
        await refreshBaseSync(forceFetch: true)
        baseSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled else { return }
                await self?.refreshBaseSync(forceFetch: false)
            }
        }
    }

    /// Fetch origin's default branch and compare it to the local default ref
    /// and to this worktree. Cheap when the fetch is coalesced; the comparison
    /// is local rev-list / merge-tree.
    private func refreshBaseSync(forceFetch: Bool) async {
        guard await git.hasRemote() else {
            if baseSync != nil {
                baseSync = nil
                publishSummaryChange()
            }
            return
        }
        let defaultBranch = await git.defaultBranch()
        try? await git.fetchRemoteBranch(defaultBranch, force: forceFetch)
        let origin = "origin/\(defaultBranch)"
        let localBehind = await git.branchExists(defaultBranch)
            ? await git.commitCount(from: defaultBranch, to: origin)
            : await git.commitCount(from: "HEAD", to: origin)
        let workspaceBehind = await git.commitCount(
            from: "HEAD", to: origin, in: worktreeURL
        )
        let wouldConflict: Bool
        if workspaceBehind > 0 {
            wouldConflict = await git.mergeWouldConflict(with: origin, in: worktreeURL)
        } else {
            wouldConflict = false
        }
        let next = BaseSyncStatus(
            defaultBranch: defaultBranch,
            localDefaultBehindOrigin: localBehind,
            workspaceBehindOrigin: workspaceBehind,
            wouldConflict: wouldConflict
        )
        guard next != baseSync else { return }
        baseSync = next
        gitStatus.behindBase = workspaceBehind
        publishSummaryChange()
    }

    // MARK: - Event handling

    private func handle(_ event: AgentEvent, chatID: ChatID) async {
        guard let runtime = chats[chatID] else { return }
        await runtime.transcript?.handle(event)

        switch event {
        case .statusChanged(let newStatus):
            setStatus(newStatus, runtime: runtime)

        case .turnStarted(let turn):
            runtime.currentTurnID = turn.turnID
            runtime.isTurnActive = true

        case .permissionRequest(let request):
            runtime.pendingPermissions[request.id] = request
            setStatus(.awaitingInput, runtime: runtime)
            await markUnread(runtime)

        case .permissionResolved(let resolution):
            runtime.pendingPermissions.removeValue(forKey: resolution.id)
            // The card is gone; the turn is not. Dropping back to requesting
            // is what makes the composer show "working" again instead of
            // looking idle while the agent continues the same turn.
            resumeTurnAfterInput(runtime: runtime)

        case .question(let question):
            runtime.pendingQuestions[question.id] = question
            setStatus(.awaitingInput, runtime: runtime)
            await markUnread(runtime)

        case .usage(let usage):
            runtime.latestUsage = usage

        case .turnCompleted:
            runtime.isTurnActive = false
            runtime.currentTurnID = nil
            await markUnread(runtime)
            runtime.record.lastActivityAt = Date()
            record.lastActivityAt = Date()
            try? await store.saveChat(runtime.record)
            try? await persistRecord()
            // The agent has stopped writing, so this is the moment the diff is
            // both interesting and stable.
            await statusWatcher?.refreshNow()
            await drainQueue(runtime: runtime)

        case .sessionError(let error):
            if !error.isRecoverable { setStatus(.failed, runtime: runtime) }
            await markUnread(runtime)

        case .sessionEnded:
            runtime.session = nil
            runtime.sessionEffort = nil
            runtime.isTurnActive = false
            setStatus(.idle, runtime: runtime)
            // A session that dies mid-turn never reports `.turnCompleted`, so
            // this is the only chance anything queued behind it gets sent.
            scheduleQueueDrain(runtime: runtime)

        case .contextCompacted:
            if record.workspaceKind == .assistant {
                runtime.pendingContextNotes.append(
                    "Your context window was compacted. Re-read MEMORY.md with ReadMemory. "
                        + "Persist anything that must survive and is not already in memory/."
                )
            }

        default:
            break
        }

        publishChatChange(runtime)
        continuation.yield(WorkspaceAgentEvent(chatID: chatID, event: event))
    }

    private func setStatus(_ newStatus: AgentStatus, runtime: ChatRuntime) {
        guard runtime.status != newStatus else { return }
        runtime.status = newStatus
        publishSummaryChange()
    }

    /// After a permission or question is answered the harness is running
    /// again, but it often doesn't emit a new status until the next tool or
    /// token. Without this the composer stays on `awaitingInput` — no busy
    /// chrome — while the turn is still open and new messages still queue.
    private func resumeTurnAfterInput(runtime: ChatRuntime) {
        guard runtime.isTurnActive, runtime.status == .awaitingInput else { return }
        setStatus(.requesting, runtime: runtime)
    }

    /// One unread per workspace, and never for the workspace the user is
    /// looking at — the point is "which of my agents needs me", not a count of
    /// everything that happened.
    private func markUnread(_ runtime: ChatRuntime) async {
        guard focusedChatID != runtime.record.chatID else { return }
        if !runtime.record.hasUnread {
            runtime.record.hasUnread = true
            try? await store.saveChat(runtime.record)
            publishChatChange(runtime)
        }
        guard !record.hasUnread else { return }
        record.hasUnread = true
        try? await persistRecord()
        publishSummaryChange()
    }

    private var focusedChatID: ChatID?

    public func setFocused(_ focused: Bool, chatID: ChatID? = nil) async {
        if focused {
            guard let runtime = try? await runtime(for: chatID) else { return }
            focusedChatID = runtime.record.chatID
            await markRead(chatID: runtime.record.chatID)
        } else if chatID == nil || focusedChatID == chatID {
            focusedChatID = nil
        }
    }

    public func focusedChatIDValue() -> ChatID? { focusedChatID }

    public func gitStatusValue() -> GitStatusSummary { gitStatus }

    public func pendingInput() -> [(chatID: ChatID, title: String, kind: String, summary: String)] {
        var rows: [(ChatID, String, String, String)] = []
        for runtime in chats.values {
            for permission in runtime.pendingPermissions.values {
                rows.append((
                    runtime.record.chatID,
                    runtime.record.title,
                    "permission",
                    permission.summary.map { "\(permission.toolName): \($0)" } ?? permission.toolName
                ))
            }
            for question in runtime.pendingQuestions.values {
                rows.append((
                    runtime.record.chatID,
                    runtime.record.title,
                    "question",
                    String(question.prompt.prefix(160))
                ))
            }
        }
        return rows
    }

    private func persistRecord() async throws {
        try await store.saveWorkspace(record)
    }

    /// Summary changes ride the same stream as agent events so a consumer has
    /// one ordered source of truth rather than two it has to reconcile.
    private func publishSummaryChange() {
        summaryContinuation?.yield(summary())
    }

    public func rename(_ name: String, userInitiated: Bool = false) async throws {
        record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // A name the user typed is theirs to keep; automatic research-identity
        // assignment must not claim it, so it only ever sets the flag true.
        if userInitiated { record.isNameUserSet = true }
        try await persistRecord()
        publishSummaryChange()
    }

    public func setPinned(_ pinned: Bool) async throws {
        record.isPinned = pinned
        try await persistRecord()
        publishSummaryChange()
    }

    private func publishChatChange(_ runtime: ChatRuntime) {
        chatContinuation?.yield(runtime.record.summary(
            status: runtime.status,
            capabilities: harnessRegistry.harness(
                for: HarnessKind(rawValue: runtime.record.harness) ?? .claudeCode
            )?.capabilities ?? HarnessCapabilities(),
            queuedMessageCount: runtime.queuedMessageCount,
            isTurnActive: runtime.isTurnActive,
            contextUsage: runtime.latestUsage
        ))
    }

    private var summaryContinuation: AsyncStream<WorkspaceSummary>.Continuation?

    public func summaryUpdates() -> AsyncStream<WorkspaceSummary> {
        let (stream, continuation) = AsyncStream<WorkspaceSummary>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        summaryContinuation = continuation
        continuation.yield(summary())
        return stream
    }

    private var chatContinuation: AsyncStream<ChatSummary>.Continuation?

    public func chatUpdates() -> AsyncStream<ChatSummary> {
        let (stream, continuation) = AsyncStream<ChatSummary>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        chatContinuation = continuation
        for runtime in chats.values { publishChatChange(runtime) }
        return stream
    }

    private var promptContinuation: AsyncStream<RoutedPromptSubmission>.Continuation?

    /// Every prompt the engine accepts, so a client can show one it didn't send
    /// itself. Unbuffered dropping is not an option here — a lost submission is
    /// a prompt the user never learns about — so this stream is unbounded.
    public func promptSubmissions() -> AsyncStream<RoutedPromptSubmission> {
        let (stream, continuation) = AsyncStream<RoutedPromptSubmission>.makeStream(
            bufferingPolicy: .unbounded
        )
        promptContinuation = continuation
        return stream
    }

    private func publishPromptSubmission(
        _ request: SendMessageRequest,
        runtime: ChatRuntime,
        isQueued: Bool
    ) {
        promptContinuation?.yield(RoutedPromptSubmission(
            chatID: runtime.record.chatID,
            submission: PromptSubmission(
                submissionID: request.submissionID,
                // `request.text` rather than the composed message: workspace
                // notes and diff-comment context are machinery the transcript
                // renders its own way, and repeating them in the bubble is not
                // what the user or the assistant actually said.
                text: request.text,
                attachments: request.attachments,
                origin: request.origin,
                isQueued: isQueued
            )
        ))
    }
}

public struct RoutedPromptSubmission: Sendable {
    public var chatID: ChatID
    public var submission: PromptSubmission

    public init(chatID: ChatID, submission: PromptSubmission) {
        self.chatID = chatID
        self.submission = submission
    }
}

public struct WorkspaceAgentEvent: Sendable {
    public var chatID: ChatID
    public var event: AgentEvent

    public init(chatID: ChatID, event: AgentEvent) {
        self.chatID = chatID
        self.event = event
    }
}

private extension AgentStatus {
    var attentionRank: Int {
        switch self {
        case .failed: return 7
        case .awaitingInput: return 6
        case .runningTool: return 5
        case .thinking: return 4
        case .requesting: return 3
        case .interrupted: return 2
        case .idle: return 1
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public enum OreCoreError: Error, Sendable, CustomStringConvertible {
    case workspaceNotFound(WorkspaceID)
    case chatNotFound(ChatID)
    case repositoryNotFound(String)
    case noCheckpoint(TurnID)
    case noFailingChecks
    case harnessUnavailable(HarnessKind)
    case modelChangeRequiresIdle(ChatID)
    case noPullRequest(String)
    case pullRequestNotMerged(String)
    case conflictHunkMissing(String, Int)
    case assistantWorkspaceProtected

    public var description: String {
        switch self {
        case .workspaceNotFound(let id): return "No workspace with id \(id.rawValue)."
        case .chatNotFound(let id): return "No chat with id \(id.rawValue)."
        case .repositoryNotFound(let path): return "No repository at \(path)."
        case .noCheckpoint(let turnID):
            return "That turn has no checkpoint, so it can't be reverted to (turn \(turnID.rawValue))."
        case .noFailingChecks: return "No failing CI checks were found for this branch."
        case .harnessUnavailable(let kind): return "\(kind.displayName) is not available."
        case .modelChangeRequiresIdle:
            return "This harness can only change models between turns."
        case .noPullRequest(let branch):
            return "No pull request exists for \(branch)."
        case .pullRequestNotMerged(let branch):
            return "The pull request for \(branch) has not been merged."
        case .conflictHunkMissing(let path, let line):
            return "No conflict hunk at \(path):\(line)."
        case .assistantWorkspaceProtected:
            return "The assistant workspace belongs to ORE and can't be archived or deleted."
        }
    }
}
