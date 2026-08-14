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
    private var gitStatus: GitStatusSummary = GitStatusSummary()
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
        return record.summary(status: status, gitStatus: gitStatus, contextUsage: usage)
    }

    public func currentRecord() -> WorkspaceRecord { record }

    public func pendingPermissionRequests() -> [PermissionRequest] {
        chats.values.flatMap { $0.pendingPermissions.values }
    }

    // MARK: - Lifecycle

    public func start() async {
        _ = try? await loadChats()
        await startStatusWatching()
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
                    contextUsage: runtime.latestUsage
                )
            }
    }

    public func createChat(_ request: CreateChatRequest) async throws -> ChatSummary {
        try await loadChats()
        let index = try await store.nextChatSortIndex(workspaceID: workspaceID)
        let defaultRuntime = try await runtime(for: nil)
        let harness = request.harness
            ?? HarnessKind(rawValue: defaultRuntime.record.harness) ?? .claudeCode
        let chat = ChatRecord(
            id: ChatID.generate(),
            workspaceID: workspaceID,
            title: request.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "Chat \(index + 1)",
            harness: harness,
            model: request.model ?? defaultRuntime.record.model,
            permissionMode: request.permissionMode,
            sortIndex: index
        )
        try await store.saveChat(chat)
        let runtime = ChatRuntime(record: chat)
        chats[chat.chatID] = runtime
        publishChatChange(runtime)
        return try await summary(for: runtime)
    }

    public func closeChat(_ chatID: ChatID, closed: Bool = true) async throws -> ChatSummary {
        let runtime = try await runtime(for: chatID)
        if closed { await stopSession(chatID: chatID) }
        runtime.record.isClosed = closed
        try await store.saveChat(runtime.record)
        publishChatChange(runtime)
        return try await summary(for: runtime)
    }

    public func renameChat(_ chatID: ChatID, title: String) async throws -> ChatSummary {
        let runtime = try await runtime(for: chatID)
        let proposed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposed.isEmpty else { return try await summary(for: runtime) }
        let used = Set(chats.values.filter { $0.record.chatID != chatID }.map { $0.record.title })
        runtime.record.title = ResearchIdentity.unique(proposed, excluding: used)
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
        return try await summary(for: runtime)
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
            mcpServer: oreMCPServer()
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

    /// What ORE tells the agent about the workspace it's in.
    private func systemPromptAddition(handoffContext: String? = nil) -> String {
        var prompt = """
        You are working in an ORE workspace: an isolated git worktree on branch \
        `\(record.branch)`, based on `\(record.baseBranch)`.

        - Scratch space for plans, notes and attachments is in `.context/`. It is \
        excluded from git, so nothing you put there will appear in the user's diff.
        - Review feedback arrives as comments anchored to specific lines of a diff. \
        Address the code at those lines directly.
        - Do not switch branches or create commits on another branch; this worktree \
        exists so that parallel work stays isolated.
        """
        if let handoffContext, !handoffContext.isEmpty {
            prompt += """


            This chat was handed off from another agent harness. Continue the same
            visible conversation using this locally generated context summary:

            \(handoffContext)
            """
        }
        return prompt
    }

    private func oreMCPServer() -> SessionConfiguration.MCPServer? {
        let current = URL(fileURLWithPath: CommandLine.arguments[0])
        let sibling = current.deletingLastPathComponent().appendingPathComponent("ore-cli")
        let executable: String?
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            executable = sibling.path
        } else {
            executable = ShellEnvironment.locate("ore-cli")
        }
        return executable.map {
            SessionConfiguration.MCPServer(
                command: $0, arguments: ["mcp-server", "--dir", worktreeURL.path]
            )
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
        let text = composeMessage(request)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        // Titles the user hasn't chosen give way to one drawn from the first
        // prompt: an empty title, the "Chat N" fallback from createChat, or the
        // workspace name that the default chat is seeded with (see
        // OreStore.ensureDefaultChat). Without the last case the sole chat in a
        // workspace keeps the workspace's name forever, since it never matches
        // the "Chat " prefix. A title the user typed is left alone.
        let currentTitle = runtime.record.title
        let isPlaceholderTitle = currentTitle.isEmpty
            || currentTitle.hasPrefix("Chat ")
            || currentTitle == record.name
            || runtime.record.lastActivityAt == nil
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
                    let shouldRenameWorkspace = ResearchIdentity.matching(nameOrSlug: record.name) != nil
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
                serviceTier: request.serviceTier
            ))
            runtime.queuedMessageCount += 1
            publishChatChange(runtime)
            return false
        }

        let harnessKind = HarnessKind(rawValue: runtime.record.harness) ?? .claudeCode
        if harnessKind == .claudeCode,
           runtime.session != nil,
           let requestedEffort = request.reasoningEffort,
           runtime.sessionEffort != requestedEffort {
            // Claude's effort override is session-scoped. Restarting and
            // resuming the provider session applies the new level without
            // losing the conversation.
            await stopSession(chatID: runtime.record.chatID)
        }
        let session = try await ensureSession(
            chatID: runtime.record.chatID,
            reasoningEffort: request.reasoningEffort
        )
        try await captureCheckpoint(runtime: runtime)
        await runtime.transcript?.recordPrompt(text, attachments: request.attachments)
        try await session.send(UserMessage(
            text: text,
            attachmentPaths: request.attachments.map(\.relativePath),
            reasoningEffort: request.reasoningEffort,
            serviceTier: request.serviceTier
        ))
        runtime.isTurnActive = true

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
                    case .turnCompleted:
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
        return title
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
            serviceTier: next.serviceTier
        ))
    }

    public func interrupt(chatID: ChatID? = nil) async throws {
        let runtime = try await runtime(for: chatID)
        try await runtime.session?.interrupt()
        runtime.isTurnActive = false
    }

    public func setPermissionMode(_ mode: PermissionMode, chatID: ChatID? = nil) async throws {
        let runtime = try await runtime(for: chatID)
        try await runtime.session?.setPermissionMode(mode)
        runtime.record.permissionMode = mode.rawValue
        try await store.saveChat(runtime.record)
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
        try await runtime.session?.resolvePermission(id, with: decision)
    }

    public func answerQuestion(
        _ id: QuestionID,
        answer: String,
        chatID: ChatID? = nil
    ) async throws {
        let runtime = try await runtime(for: chatID)
        runtime.pendingQuestions.removeValue(forKey: id)
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
        _ = try await store.addDiffComment(DiffCommentRecord(
            workspaceID: workspaceID,
            filePath: reference.filePath,
            startLine: reference.startLine,
            endLine: reference.endLine,
            body: reference.body,
            context: reference.context
        ))
        let comments = try await pendingDiffComments()
        let contextDirectory = worktreeURL.appendingPathComponent(".context", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contextDirectory, withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(comments)
        try data.write(
            to: contextDirectory.appendingPathComponent("ore-diff-comments.json"),
            options: .atomic
        )
    }

    public func pendingDiffComments() async throws -> [DiffCommentReference] {
        try await store.pendingDiffComments(workspaceID: workspaceID).map(\.reference)
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
            commitsAheadOfBase: await commitCount(
                range: "\(record.baseBranch)..HEAD"
            ),
            hasUpstream: await hasUpstream(),
            hasRemote: await git.hasRemote(),
            baseBranch: record.baseBranch,
            pullRequest: pullRequest,
            gitHubStatus: gitHubStatus,
            parentBranch: parentBranch,
            parentPullRequest: parentPullRequest
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

    private func unpushedCommitCount() async -> Int {
        await commitCount(range: "@{upstream}..HEAD")
    }

    private func commitCount(range: String) async -> Int {
        guard let output = try? await git.run(
            ["rev-list", "--count", range], in: worktreeURL
        ) else { return 0 }
        return Int(output.trimmedStandardOutput) ?? 0
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
        gitStatus = snapshot.summary()
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

    private func persistRecord() async throws {
        try await store.saveWorkspace(record)
    }

    /// Summary changes ride the same stream as agent events so a consumer has
    /// one ordered source of truth rather than two it has to reconcile.
    private func publishSummaryChange() {
        summaryContinuation?.yield(summary())
    }

    public func rename(_ name: String) async throws {
        record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
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
        }
    }
}
