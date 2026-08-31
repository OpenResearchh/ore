import Foundation
import OrePersistence
import OreProtocol

/// Which actions the assistant may take, and on whose say-so.
///
/// Tiered so a clear instruction runs without ceremony: everything reversible
/// and contained runs automatically, only consequential actions confirm (and a
/// confirmation can be widened to "this task" or "always"), and destructive
/// ones aren't exposed at all. Enforced app-side — the model never sees this
/// table, it only sees results.
enum AssistantActionPolicy {
    enum Tier {
        case auto
        case confirm(AssistantActionClass)
        case deny(String)
    }

    static func tier(forTool tool: String, arguments: JSONValue = .null) -> Tier {
        switch tool {
        // Reversible, contained, and usually the very thing the user just
        // asked for. Prompting on these is how an assistant becomes paperwork.
        // ListHarnesses / GetAppState are pure reads that happen to need the
        // app process. Memory writes stay in the MCP process.
        case "CreateWorkspace", "CreateChat", "SendPromptToProject", "OpenWorkspace",
             "ListHarnesses", "GetAppState", "RouteTask",
             "SetChatModel", "SwitchChatHarness", "SetChatEffort",
             "RenameChat", "CloseChat", "ReopenChat", "InterruptChatTurn",
             "AnswerChatQuestion":
            return .auto

        case "SetChatPermissionMode":
            if arguments["mode"]?.stringValue == PermissionMode.bypassPermissions.rawValue {
                return .confirm(.autoAllowTab)
            }
            return .auto

        case "ResolveChatPermission":
            return .confirm(.autoAllowTab)

        // Consequential: they publish or remove things. Confirm — once.
        case "Commit": return .confirm(.commit)
        case "Push": return .confirm(.push)
        case "CreatePullRequest": return .confirm(.createPullRequest)
        case "ArchiveWorkspace": return .confirm(.archiveWorkspace)

        default:
            return .deny("The assistant can't perform \(tool).")
        }
    }

    static let actionToolNames: Set<String> = [
        "CreateWorkspace", "CreateChat", "SendPromptToProject", "OpenWorkspace",
        "Commit", "Push", "CreatePullRequest", "ArchiveWorkspace", "ListHarnesses",
        "GetAppState", "RouteTask", "SetChatModel", "SwitchChatHarness", "SetChatPermissionMode",
        "SetChatEffort", "RenameChat", "CloseChat", "ReopenChat", "InterruptChatTurn",
        "ResolveChatPermission", "AnswerChatQuestion",
    ]

    /// The harness tools the assistant is launched without.
    ///
    /// The assistant is an orchestrator: it answers questions about the fleet
    /// and hands work to the agent that owns the repository. Left with a shell
    /// and an editor it does the opposite — reaches into a worktree it doesn't
    /// own, runs `git` there, and lands the user in a half-applied change with
    /// no tab holding the context. A system prompt asking it not to is a
    /// suggestion; taking the tools away is the boundary.
    ///
    /// Nothing is lost: the fleet is visible through ORE's own read tools
    /// (`ListWorkspaces`, `WorkspaceStatus`, `SearchTranscripts`,
    /// `GetTranscriptTail`), its memory through `ReadMemory` / `WriteMemory`,
    /// and every change through the project agent it delegates to.
    static let disallowedHarnessTools: [String] = [
        "Bash", "BashOutput", "KillShell", "KillBash",
        "Edit", "MultiEdit", "Write", "NotebookEdit",
        "Read", "Glob", "Grep",
        "Task", "WebFetch", "WebSearch",
    ]

    /// How long a "for this task" grant lasts, sliding on use. Long enough to
    /// cover a multi-step request with the agent working in between; short
    /// enough that tomorrow is a fresh question.
    static let taskGrantWindow: TimeInterval = 15 * 60

    static let confirmationTimeout: Duration = .seconds(120)
}

/// How a pending confirmation ended. Internal to the core; the audit log and
/// the response to the model both derive from it.
enum AssistantResolution: Sendable {
    case allowed(AssistantGrantScope)
    case denied
    case timedOut
}

extension InProcessCoreClient {
    /// The bridge socket lives beside the assistant home:
    /// `<ORE home>/assistant/.bridge.sock` (see `AssistantBridgeLocator`).
    func startAssistantBridge() {
        guard assistantBridge == nil, let databaseURL = store.url else { return }
        let socketURL = AssistantBridgeLocator.socketURL(forDatabase: databaseURL)
        let server = AssistantBridgeServer(socketURL: socketURL) { [weak self] request in
            await self?.handleAssistantRequest(request) ?? AssistantBridgeResponse(
                id: request.id, ok: false, error: "ORE is shutting down."
            )
        }
        do {
            try server.start()
            assistantBridge = server
        } catch {
            continuation.yield(.commandFailed(CommandFailure(
                message: "The assistant's action bridge couldn't start.",
                detail: String(describing: error)
            )))
        }
    }

    func stopAssistantBridge() {
        assistantBridge?.stop()
        assistantBridge = nil
        for (_, continuation) in pendingAssistantConfirmations {
            continuation.resume(returning: .denied)
        }
        pendingAssistantConfirmations.removeAll()
    }

    // MARK: - Request handling

    func handleAssistantRequest(_ request: AssistantBridgeRequest) async -> AssistantBridgeResponse {
        let summary = await assistantActionSummary(request)

        switch AssistantActionPolicy.tier(forTool: request.tool, arguments: request.arguments) {
        case .deny(let reason):
            await audit(request, summary: summary, decision: "denied")
            return AssistantBridgeResponse(id: request.id, ok: false, error: reason)

        case .auto:
            if request.tool == "CreateWorkspace",
               let dirty = await dirtyCreateWorkspaceConfirmation(request) {
                return await confirm(
                    request,
                    summary: dirty.summary,
                    actionClass: .createWorkspace,
                    workspaceID: dirty.workspaceID
                )
            }
            return await performAudited(request, summary: summary, decision: "auto")

        case .confirm(let actionClass):
            return await confirm(
                request,
                summary: summary,
                actionClass: actionClass,
                workspaceID: requestWorkspaceID(request)
            )
        }
    }

    /// Ask the user, honoring a standing grant if one already covers this class.
    private func confirm(
        _ request: AssistantBridgeRequest,
        summary: String,
        actionClass: AssistantActionClass,
        workspaceID: WorkspaceID?
    ) async -> AssistantBridgeResponse {
        if let standing = await standingGrant(
            for: actionClass,
            workspaceID: workspaceID,
            chatID: requestChatID(request)
        ) {
            return await performAudited(request, summary: summary, decision: standing)
        }

        continuation.yield(.assistantConfirmationRequested(AssistantConfirmation(
            id: request.id,
            actionClass: actionClass,
            workspaceID: workspaceID,
            chatID: requestChatID(request),
            summary: summary
        )))
        let resolution = await awaitAssistantResolution(id: request.id)
        continuation.yield(.assistantConfirmationResolved(request.id))

        switch resolution {
        case .allowed(let scope):
            await applyAssistantGrant(
                scope,
                to: actionClass,
                workspaceID: workspaceID,
                chatID: requestChatID(request)
            )
            return await performAudited(
                request, summary: summary, decision: "allowed:\(scope.rawValue)"
            )
        case .denied:
            await audit(request, summary: summary, decision: "denied")
            return AssistantBridgeResponse(
                id: request.id, ok: false,
                error: "The user declined this action. Do not retry it; "
                    + "ask them what they'd like instead."
            )
        case .timedOut:
            await audit(request, summary: summary, decision: "timedOut")
            return AssistantBridgeResponse(
                id: request.id, ok: false,
                error: "The user didn't answer the confirmation in time. "
                    + "The action was not performed."
            )
        }
    }

    // MARK: - Grants

    /// A grant that already covers this action class: an unexpired task grant
    /// for this workspace (which slides on use) or a persistent "always allow".
    private func standingGrant(
        for actionClass: AssistantActionClass,
        workspaceID: WorkspaceID?,
        chatID: ChatID? = nil
    ) async -> String? {
        let key = AssistantTaskGrantKey(
            actionClass: actionClass, workspaceID: workspaceID, chatID: chatID
        )
        if let expiry = assistantTaskGrants[key], expiry > Date() {
            assistantTaskGrants[key] = Date()
                .addingTimeInterval(AssistantActionPolicy.taskGrantWindow)
            return "granted:task"
        }
        if actionClass == .autoAllowTab, let chatID,
           ((try? await store.hasAssistantTabGrant(chatID)) ?? false) {
            return "granted:always"
        }
        if assistantAlwaysGrants.contains(actionClass) {
            return "granted:always"
        }
        if ((try? await store.assistantGrants()) ?? []).contains(actionClass.rawValue) {
            assistantAlwaysGrants.insert(actionClass)
            return "granted:always"
        }
        return nil
    }

    private func applyAssistantGrant(
        _ scope: AssistantGrantScope,
        to actionClass: AssistantActionClass,
        workspaceID: WorkspaceID?,
        chatID: ChatID? = nil
    ) async {
        switch scope {
        case .once:
            break
        case .task:
            assistantTaskGrants[AssistantTaskGrantKey(
                actionClass: actionClass, workspaceID: workspaceID, chatID: chatID
            )] = Date().addingTimeInterval(AssistantActionPolicy.taskGrantWindow)
        case .always:
            if actionClass == .autoAllowTab, let chatID {
                do {
                    try await store.saveAssistantTabGrant(chatID)
                } catch {
                    continuation.yield(.commandFailed(CommandFailure(
                        message: "Could not remember the tab auto-allow.",
                        detail: String(describing: error)
                    )))
                }
            } else {
                assistantAlwaysGrants.insert(actionClass)
                do {
                    try await store.saveAssistantGrant(actionClass.rawValue)
                } catch {
                    continuation.yield(.commandFailed(CommandFailure(
                        message: "Could not remember the always-allow grant.",
                        detail: String(describing: error)
                    )))
                }
            }
        }
    }

    // MARK: - Confirmation plumbing

    private func awaitAssistantResolution(id: String) async -> AssistantResolution {
        await withCheckedContinuation { continuation in
            pendingAssistantConfirmations[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: AssistantActionPolicy.confirmationTimeout)
                await self?.expireAssistantConfirmation(id: id)
            }
        }
    }

    private func expireAssistantConfirmation(id: String) {
        pendingAssistantConfirmations.removeValue(forKey: id)?.resume(returning: .timedOut)
    }

    func resolveAssistantConfirmation(id: String, decision: AssistantConfirmationDecision) {
        guard let continuation = pendingAssistantConfirmations.removeValue(forKey: id) else {
            return
        }
        switch decision {
        case .allow(let scope): continuation.resume(returning: .allowed(scope))
        case .deny: continuation.resume(returning: .denied)
        }
    }

    // MARK: - Performing

    private func performAudited(
        _ request: AssistantBridgeRequest,
        summary: String,
        decision: String
    ) async -> AssistantBridgeResponse {
        do {
            let result = try await perform(request)
            await audit(request, summary: summary, decision: decision)
            return AssistantBridgeResponse(id: request.id, ok: true, result: result)
        } catch {
            await audit(request, summary: summary, decision: "failed")
            let message = (error as CustomStringConvertible).description
            return AssistantBridgeResponse(id: request.id, ok: false, error: message)
        }
    }

    private func perform(_ request: AssistantBridgeRequest) async throws -> String {
        let arguments = request.arguments

        switch request.tool {
        case "CreateWorkspace":
            let repository = try await resolveRepository(arguments["repository"]?.stringValue)
            let harness = try resolveHarness(arguments["harness"]?.stringValue)
            let record = try await createWorkspace(CreateWorkspaceRequest(
                repositoryPath: repository.path,
                name: arguments["name"]?.stringValue ?? "",
                seed: try resolveSeed(arguments),
                harness: harness ?? .claudeCode,
                model: arguments["model"]?.stringValue,
                initialPrompt: arguments["prompt"]?.stringValue,
                promptOrigin: .agent,
                branchPrefix: arguments["branchPrefix"]?.stringValue
            ))
            return "Created workspace \"\(record.name)\" (id \(record.id)) "
                + "on branch \(record.branch) in \(repository.name)."
                + (arguments["prompt"]?.stringValue == nil
                    ? "" : " The initial prompt was sent to its agent.")

        case "CreateChat":
            let workspaceID = try requireWorkspace(arguments)
            let harness = try resolveHarness(arguments["harness"]?.stringValue)
            let mode = arguments["permissionMode"]?.stringValue
                .flatMap(PermissionMode.init(rawValue:)) ?? .default
            let chat = try await engine(for: workspaceID).createChat(CreateChatRequest(
                workspaceID: workspaceID,
                title: arguments["title"]?.stringValue,
                harness: harness,
                model: arguments["model"]?.stringValue,
                permissionMode: mode,
                forkFrom: arguments["forkFrom"]?.stringValue.map(ChatID.init(rawValue:)),
                reasoningEffort: arguments["effort"]?.stringValue
                    .flatMap(ReasoningEffort.init(rawValue:))
            ))
            markListMutation()
            continuation.yield(.chatAdded(chat))
            if let prompt = arguments["prompt"]?.stringValue, !prompt.isEmpty {
                _ = try await engine(for: workspaceID).send(SendMessageRequest(
                    workspaceID: workspaceID, chatID: chat.id, text: prompt, origin: .agent
                ))
            }
            return "Created chat \"\(chat.title)\" (id \(chat.id.rawValue))."

        case "SendPromptToProject":
            let workspaceID = try requireWorkspace(arguments)
            guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
                throw AssistantActionError.badRequest("SendPromptToProject needs text.")
            }
            let chatID = try await requireDelegatedChatID(arguments, workspaceID: workspaceID)
            let effort = arguments["effort"]?.stringValue
                .flatMap(ReasoningEffort.init(rawValue:))
            let sent = try await engine(for: workspaceID).send(SendMessageRequest(
                workspaceID: workspaceID,
                chatID: chatID,
                text: text,
                reasoningEffort: effort,
                serviceTier: arguments["serviceTier"]?.stringValue,
                origin: .agent
            ))
            return sent
                ? "Sent. The project's agent is working on it."
                : "The agent was mid-turn, so the prompt was queued and will run next."

        case "ListHarnesses":
            return harnessCatalogText()

        case "GetAppState":
            return await assistantAppStateText()

        case "RouteTask":
            guard let utterance = arguments["utterance"]?.stringValue, !utterance.isEmpty else {
                throw AssistantActionError.badRequest("RouteTask needs the user's request as utterance.")
            }
            let snapshot = await routingSnapshot()
            return AssistantTaskRouter.render(
                AssistantTaskRouter.route(utterance: utterance, snapshot: snapshot)
            )

        case "SetChatModel":
            let workspaceID = try requireWorkspace(arguments)
            let chatID = try requireChat(arguments)
            let chat = try await engine(for: workspaceID).setModel(
                chatID: chatID, model: arguments["model"]?.stringValue
            )
            return "Model on \"\(chat.title)\" is now \(chat.model ?? "the default")."

        case "SwitchChatHarness":
            let workspaceID = try requireWorkspace(arguments)
            let chatID = try requireChat(arguments)
            let harness = try resolveHarness(arguments["harness"]?.stringValue)
            guard let harness else {
                throw AssistantActionError.badRequest("SwitchChatHarness needs a harness.")
            }
            let chat = try await engine(for: workspaceID).switchHarness(
                chatID: chatID, harness: harness, model: arguments["model"]?.stringValue
            )
            return "\"\(chat.title)\" is on \(chat.harness.displayName)"
                + (chat.model.map { " / \($0)" } ?? "") + "."

        case "SetChatPermissionMode":
            let workspaceID = try requireWorkspace(arguments)
            let chatID = try requireChat(arguments)
            guard let raw = arguments["mode"]?.stringValue,
                  let mode = PermissionMode(rawValue: raw)
            else {
                throw AssistantActionError.badRequest(
                    "mode must be default, acceptEdits, plan, or bypassPermissions."
                )
            }
            try await engine(for: workspaceID).setPermissionMode(mode, chatID: chatID)
            if mode == .bypassPermissions {
                try? await store.saveAssistantTabGrant(chatID)
            }
            return "Permission mode on that tab is now \(mode.displayName)."

        case "SetChatEffort":
            let workspaceID = try requireWorkspace(arguments)
            let chatID = try requireChat(arguments)
            let effort = arguments["effort"]?.stringValue
                .flatMap(ReasoningEffort.init(rawValue:))
            let chat = try await engine(for: workspaceID).setEffort(chatID: chatID, effort: effort)
            return "Effort on \"\(chat.title)\" is now "
                + (effort?.displayName ?? "the default") + "."

        case "RenameChat":
            let workspaceID = try requireWorkspace(arguments)
            let chatID = try requireChat(arguments)
            guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
                throw AssistantActionError.badRequest("RenameChat needs a title.")
            }
            let chat = try await engine(for: workspaceID).renameChat(
                chatID, title: title, userInitiated: true
            )
            markListMutation()
            return "Renamed the tab to \"\(chat.title)\"."

        case "CloseChat":
            let workspaceID = try requireWorkspace(arguments)
            let chatID = try requireChat(arguments)
            let chat = try await engine(for: workspaceID).closeChat(chatID)
            markListMutation()
            continuation.yield(.chatUpdated(chat))
            return "Closed \"\(chat.title)\"."

        case "ReopenChat":
            let workspaceID = try requireWorkspace(arguments)
            let chatID = try requireChat(arguments)
            let chat = try await engine(for: workspaceID).closeChat(chatID, closed: false)
            markListMutation()
            continuation.yield(.chatUpdated(chat))
            return "Reopened \"\(chat.title)\"."

        case "InterruptChatTurn":
            let workspaceID = try requireWorkspace(arguments)
            let chatID = try requireChat(arguments)
            try await engine(for: workspaceID).interrupt(chatID: chatID)
            return "Interrupted the turn."

        case "ResolveChatPermission":
            let workspaceID = try requireWorkspace(arguments)
            let chatID = try requireChat(arguments)
            guard let rawID = arguments["permissionID"]?.stringValue, !rawID.isEmpty else {
                throw AssistantActionError.badRequest("ResolveChatPermission needs permissionID.")
            }
            let workspaceEngine = try await engine(for: workspaceID)
            guard await workspaceEngine.pendingInput().contains(where: {
                $0.chatID == chatID && $0.kind == "permission" && $0.id == rawID
            }) else {
                throw AssistantActionError.badRequest(
                    "Permission \(rawID) is not pending on that tab. "
                        + "Refresh app state and use the current permissionID and chatID."
                )
            }
            let allowed = arguments["allow"]?.boolValue ?? true
            let decision: PermissionDecision = allowed
                ? .allow
                : .deny(reason: arguments["reason"]?.stringValue
                    ?? "The user denied this via the assistant.")
            try await workspaceEngine.resolvePermission(
                PermissionRequestID(rawValue: rawID), with: decision, chatID: chatID
            )
            if allowed, (try? await store.hasAssistantTabGrant(chatID)) == true {
                try? await workspaceEngine.setPermissionMode(.bypassPermissions, chatID: chatID)
            }
            return allowed ? "Allowed." : "Denied."

        case "AnswerChatQuestion":
            let workspaceID = try requireWorkspace(arguments)
            let chatID = try requireChat(arguments)
            guard let rawID = arguments["questionID"]?.stringValue, !rawID.isEmpty else {
                throw AssistantActionError.badRequest("AnswerChatQuestion needs questionID.")
            }
            guard let answer = arguments["answer"]?.stringValue, !answer.isEmpty else {
                throw AssistantActionError.badRequest("AnswerChatQuestion needs an answer.")
            }
            try await engine(for: workspaceID).answerQuestion(
                QuestionID(rawValue: rawID), answer: answer, chatID: chatID
            )
            return "Answered."

        case "OpenWorkspace":
            let workspaceID = try requireWorkspace(arguments)
            if let chatID = arguments["chatID"]?.stringValue.map(ChatID.init(rawValue:)) {
                continuation.yield(.assistantUIAction(.revealChat(workspaceID, chatID)))
            } else {
                continuation.yield(.assistantUIAction(.revealWorkspace(workspaceID)))
            }
            return "Brought it to the front for the user."

        case "Commit":
            let workspaceID = try requireWorkspace(arguments)
            guard let message = arguments["message"]?.stringValue, !message.isEmpty else {
                throw AssistantActionError.badRequest("Commit needs a message.")
            }
            try await commit(workspaceID, message: message)
            return "Committed."

        case "Push":
            let workspaceID = try requireWorkspace(arguments)
            try await push(workspaceID)
            return "Pushed."

        case "CreatePullRequest":
            let workspaceID = try requireWorkspace(arguments)
            let url = try await createPullRequest(
                workspaceID,
                title: arguments["title"]?.stringValue ?? "",
                body: arguments["body"]?.stringValue ?? "",
                base: arguments["base"]?.stringValue ?? "",
                draft: arguments["draft"]?.boolValue ?? false
            )
            return "Opened pull request: \(url)"

        case "ArchiveWorkspace":
            let workspaceID = try requireWorkspace(arguments)
            try await archiveWorkspace(workspaceID)
            return "Archived. The branch and chats are preserved; the worktree is freed."

        default:
            throw AssistantActionError.badRequest("Unknown action: \(request.tool)")
        }
    }

    // MARK: - Argument resolution

    private func requireWorkspace(_ arguments: JSONValue) throws -> WorkspaceID {
        guard let raw = arguments["workspaceID"]?.stringValue, !raw.isEmpty else {
            throw AssistantActionError.badRequest(
                "workspaceID is required — get one from ListWorkspaces."
            )
        }
        return WorkspaceID(rawValue: raw)
    }

    private func requireChat(_ arguments: JSONValue) throws -> ChatID {
        guard let raw = arguments["chatID"]?.stringValue, !raw.isEmpty else {
            throw AssistantActionError.badRequest(
                "chatID is required — get one from ListChats or the app-state snapshot."
            )
        }
        return ChatID(rawValue: raw)
    }

    /// Follow-ups that change code must name the tab when the workspace has
    /// more than one. Omitting chatID used to land on the oldest tab — the
    /// wrong conversation more often than the main one.
    private func requireDelegatedChatID(
        _ arguments: JSONValue,
        workspaceID: WorkspaceID
    ) async throws -> ChatID? {
        if let raw = arguments["chatID"]?.stringValue, !raw.isEmpty {
            return ChatID(rawValue: raw)
        }
        let open = ((try? await store.chats(workspaceID: workspaceID)) ?? [])
            .filter { !$0.isClosed }
        if open.count > 1 {
            let named = open.map { "\"\($0.title)\" (\($0.id))" }.joined(separator: ", ")
            throw AssistantActionError.badRequest(
                "This workspace has \(open.count) open tabs — pass chatID so the "
                    + "follow-up reaches the conversation that already has the context. "
                    + "Open tabs: \(named)."
            )
        }
        return nil
    }

    private func requestWorkspaceID(_ request: AssistantBridgeRequest) -> WorkspaceID? {
        request.arguments["workspaceID"]?.stringValue.map(WorkspaceID.init(rawValue:))
    }

    private func requestChatID(_ request: AssistantBridgeRequest) -> ChatID? {
        request.arguments["chatID"]?.stringValue.map(ChatID.init(rawValue:))
    }

    /// CreateWorkspace stays automatic on a clean fleet. Forking a sibling
    /// while another worktree on the same repo is dirty asks first.
    private func dirtyCreateWorkspaceConfirmation(
        _ request: AssistantBridgeRequest
    ) async -> (summary: String, workspaceID: WorkspaceID?)? {
        guard let repository = try? await resolveRepository(
            request.arguments["repository"]?.stringValue
        ) else { return nil }
        guard let sibling = await dirtySibling(onRepository: repository.path) else {
            return nil
        }
        let files = sibling.files == 1 ? "1 uncommitted file" : "\(sibling.files) uncommitted files"
        return (
            "Create a new worktree while “\(sibling.name)” still has \(files)",
            sibling.id
        )
    }

    private func resolveSeed(_ arguments: JSONValue) throws -> CreateWorkspaceRequest.Seed {
        switch arguments["seed"]?.stringValue?.lowercased() {
        case nil, "", "default", "defaultbranch":
            return .defaultBranch
        case "branch":
            guard let name = arguments["seedRef"]?.stringValue, !name.isEmpty else {
                throw AssistantActionError.badRequest("seed=branch needs seedRef as the branch name.")
            }
            return .branch(name)
        case "workspace":
            guard let raw = arguments["seedRef"]?.stringValue, !raw.isEmpty else {
                throw AssistantActionError.badRequest(
                    "seed=workspace needs seedRef as the parent workspace id."
                )
            }
            return .workspace(WorkspaceID(rawValue: raw))
        case "issue", "githubissue":
            guard let number = arguments["seedRef"]?.stringValue.flatMap(Int.init)
                    ?? arguments["seedRef"]?.intValue
            else {
                throw AssistantActionError.badRequest("seed=issue needs seedRef as the issue number.")
            }
            return .githubIssue(number: number)
        case "pr", "pull", "githubpullrequest":
            guard let number = arguments["seedRef"]?.stringValue.flatMap(Int.init)
                    ?? arguments["seedRef"]?.intValue
            else {
                throw AssistantActionError.badRequest("seed=pr needs seedRef as the PR number.")
            }
            return .githubPullRequest(number: number)
        default:
            throw AssistantActionError.badRequest(
                "seed must be default, branch, workspace, issue, or pr."
            )
        }
    }

    /// Accepts a repository by name or path; with exactly one repository
    /// registered, no argument is needed at all.
    private func resolveRepository(_ reference: String?) async throws -> RepositoryRecord {
        let repositories = try await store.repositories()
        guard !repositories.isEmpty else {
            throw AssistantActionError.badRequest(
                "No repositories are registered in ORE yet — the user must add one first."
            )
        }
        guard let reference, !reference.isEmpty else {
            if repositories.count == 1 { return repositories[0] }
            throw AssistantActionError.badRequest(
                "Several repositories exist; pass `repository` as one of: "
                    + repositories.map(\.name).joined(separator: ", ")
            )
        }
        if let match = repositories.first(where: {
            $0.path == reference || $0.name.caseInsensitiveCompare(reference) == .orderedSame
        }) {
            return match
        }
        throw AssistantActionError.badRequest(
            "No repository named \"\(reference)\". Registered: "
                + repositories.map(\.name).joined(separator: ", ")
        )
    }

    /// A harness by name, but only if this machine can actually run it —
    /// creating a workspace on an agent that isn't installed produces a
    /// mysterious dead tab ten minutes later.
    private func resolveHarness(_ reference: String?) throws -> HarnessKind? {
        guard let reference, !reference.isEmpty else { return nil }
        let kind: HarnessKind? = switch reference.lowercased() {
        case "claude", "claudecode", "claude-code": .claudeCode
        case "codex": .codex
        case "cursor", "cursor-agent", "agent": .cursorAgent
        default: HarnessKind(rawValue: reference)
        }
        guard let kind else {
            throw AssistantActionError.badRequest("Unknown harness \"\(reference)\".")
        }
        guard harnessProbes.first(where: { $0.kind == kind })?.isReady ?? false else {
            let ready = harnessProbes.filter(\.isReady).map(\.kind.rawValue)
            throw AssistantActionError.badRequest(
                "\(kind.displayName) isn't ready on this Mac. Ready: "
                    + (ready.isEmpty ? "none yet — ask again in a moment" : ready.joined(separator: ", "))
            )
        }
        return kind
    }

    /// What's installed, signed in, and which models each agent offers —
    /// the assistant's basis for choosing a configuration.
    private func harnessCatalogText() -> String {
        guard !harnessProbes.isEmpty else {
            return "Harnesses are still being probed — ask again in a few seconds."
        }
        var lines: [String] = []
        for probe in harnessProbes {
            var line = "\(probe.kind.rawValue): "
            if !probe.isInstalled {
                line += "not installed"
            } else if probe.isEnabled == false {
                line += "installed but disabled"
            } else if probe.authState == .notAuthenticated {
                line += "installed but not signed in"
            } else {
                line += "ready"
                if let version = probe.version { line += " (v\(version))" }
                let models = modelCatalog[probe.kind] ?? []
                if !models.isEmpty {
                    let described = models.map { model in
                        model.id + (model.isDefault ? " (default)" : "")
                    }
                    line += " — models: " + described.joined(separator: ", ")
                }
            }
            if let diagnostic = probe.diagnostic { line += " — note: \(diagnostic)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Self-configuration

    /// Moves the assistant onto a harness that actually works here. Runs after
    /// every probe pass: first launch on a codex-only machine, or claude
    /// disappearing between launches, must not leave the assistant mute.
    func reconcileAssistantConfiguration() async {
        guard let assistant = try? await store.assistantWorkspace(),
              let chats = try? await store.chats(workspaceID: assistant.workspaceID),
              !chats.isEmpty
        else { return }
        var warnedProfiles: Set<String> = []
        for chat in chats where !chat.isClosed {
            let current = HarnessKind(rawValue: chat.harness)
            var seen: Set<HarnessKind> = []
            let candidates = ([current].compactMap { $0 }
                + harnessProbes.filter(\.isReady).map(\.kind))
                .filter { seen.insert($0).inserted }
            let target = candidates.compactMap({ harness -> (
                harness: HarnessKind, profile: AssistantManager.ModelProfile
            )? in
                guard harnessProbes.first(where: { $0.kind == harness })?.isReady ?? false,
                      let profile = Self.assistantProfile(
                          for: harness,
                          catalog: self.modelCatalog
                      )
                else { return nil }
                return (harness, profile)
            }).first

            if let target {
                let currentEffort = chat.reasoningEffort.flatMap(ReasoningEffort.init(rawValue:))
                guard current != target.harness
                        || chat.model != target.profile.model
                        || currentEffort != target.profile.reasoningEffort
                else { continue }
                await moveAssistant(
                    to: target.harness,
                    profile: target.profile,
                    workspaceID: assistant.workspaceID,
                    chatID: chat.chatID
                )
                continue
            }

            // A stale CLI or restricted account may advertise only expensive
            // models. Pin the lean id anyway so the next turn fails loudly
            // instead of consuming the provider's implicit frontier default.
            guard let harness = candidates.first(where: { candidate in
                harnessProbes.first(where: { $0.kind == candidate })?.isReady ?? false
            }) else { continue }
            let profile = AssistantManager.modelProfile(for: harness)
            let currentEffort = chat.reasoningEffort.flatMap(ReasoningEffort.init(rawValue:))
            if current != harness || chat.model != profile.model
                || currentEffort != profile.reasoningEffort {
                await moveAssistant(
                    to: harness,
                    profile: profile,
                    workspaceID: assistant.workspaceID,
                    chatID: chat.chatID
                )
            }
            let warningKey = "\(harness.rawValue):\(profile.model)"
            guard warnedProfiles.insert(warningKey).inserted else { continue }
            continuation.yield(.commandFailed(CommandFailure(
                workspaceID: assistant.workspaceID,
                message: "The Assistant's lean model is unavailable.",
                detail: "\(harness.displayName) did not advertise \(profile.model). ORE pinned "
                    + "that model rather than silently using a more expensive default."
            )))
        }
    }

    /// The assistant's own provider hit a hard limit; move it to another
    /// ready harness so the user's next question still gets answered. The
    /// engine's harness switch carries a locally generated handoff summary,
    /// so the conversation continues rather than restarting.
    public func assistantRateLimited(chatID: ChatID) async {
        guard let assistant = try? await store.assistantWorkspace(),
              let chat = try? await store.chat(chatID),
              chat.workspaceID == assistant.id
        else { return }
        let current = HarnessKind(rawValue: chat.harness)
        guard let alternate = harnessProbes.lazy.compactMap({ probe -> (
            harness: HarnessKind, profile: AssistantManager.ModelProfile
        )? in
            guard probe.isReady, probe.kind != current,
                  let profile = Self.assistantProfile(for: probe.kind, catalog: self.modelCatalog)
            else { return nil }
            return (probe.kind, profile)
        }).first else { return }
        await moveAssistant(
            to: alternate.harness,
            profile: alternate.profile,
            workspaceID: assistant.workspaceID,
            chatID: chatID
        )
    }

    private func moveAssistant(
        to harness: HarnessKind,
        profile: AssistantManager.ModelProfile,
        workspaceID: WorkspaceID,
        chatID: ChatID
    ) async {
        guard let engine = try? await engine(for: workspaceID),
              let moved = try? await engine.switchHarness(
                chatID: chatID,
                harness: harness,
                model: profile.model
              )
        else { return }
        let configured = (try? await engine.setEffort(
            chatID: chatID,
            effort: profile.reasoningEffort
        )) ?? moved
        continuation.yield(.chatUpdated(configured))
    }

    /// The Assistant may use only the product-owned lean profile for a
    /// harness. A nonempty live catalog is authoritative: if that account or
    /// CLI does not advertise the lean model, skip the harness instead of
    /// silently spending against its frontier default.
    static func assistantProfile(
        for harness: HarnessKind,
        catalog: [HarnessKind: [AgentModel]]
    ) -> AssistantManager.ModelProfile? {
        let profile = AssistantManager.modelProfile(for: harness)
        guard let models = catalog[harness], !models.isEmpty else { return profile }
        return models.contains(where: { $0.id == profile.model }) ? profile : nil
    }

    // MARK: - Audit

    /// Human-readable line for the confirmation card and the Actions tab —
    /// names the workspace, not its id.
    private func assistantActionSummary(_ request: AssistantBridgeRequest) async -> String {
        var place = ""
        if let id = requestWorkspaceID(request),
           let record = try? await store.workspace(id) {
            place = " in “\(record.name)”"
        }
        switch request.tool {
        case "CreateWorkspace":
            let repository = request.arguments["repository"]?.stringValue ?? "the repository"
            return "Create a workspace in \(repository)"
        case "CreateChat": return "Open a new chat tab\(place)"
        case "SendPromptToProject": return "Send a prompt to the agent\(place)"
        case "OpenWorkspace": return "Show\(place.isEmpty ? " a workspace" : place) on screen"
        case "GetAppState": return "Read the live app state"
        case "RouteTask": return "Recommend where a request should land"
        case "SetChatModel": return "Change the model\(place)"
        case "SwitchChatHarness": return "Switch the harness\(place)"
        case "SetChatPermissionMode":
            if request.arguments["mode"]?.stringValue == PermissionMode.bypassPermissions.rawValue {
                return "Auto-allow everything this tab asks\(place)"
            }
            return "Change the permission mode\(place)"
        case "SetChatEffort": return "Change reasoning effort\(place)"
        case "RenameChat": return "Rename a chat tab\(place)"
        case "CloseChat": return "Close a chat tab\(place)"
        case "ReopenChat": return "Reopen a chat tab\(place)"
        case "InterruptChatTurn": return "Stop the agent\(place)"
        case "ResolveChatPermission": return "Allow or deny a tool\(place)"
        case "AnswerChatQuestion": return "Answer a question\(place)"
        case "Commit": return "Commit changes\(place)"
        case "Push": return "Push the branch\(place)"
        case "CreatePullRequest": return "Open a pull request\(place)"
        case "ArchiveWorkspace": return "Archive the workspace\(place)"
        default: return request.tool
        }
    }

    private func audit(
        _ request: AssistantBridgeRequest,
        summary: String,
        decision: String
    ) async {
        let arguments = (try? JSONEncoder().encode(request.arguments))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        try? await store.recordAssistantAction(AssistantActionRecord(
            tool: request.tool,
            summary: summary,
            arguments: arguments,
            decision: decision,
            workspaceID: requestWorkspaceID(request)
        ))
    }

    // MARK: - Reads for the app

    public func assistantActions() async throws -> [AssistantActionRecord] {
        try await store.assistantActions()
    }

    public func assistantAlwaysGrants() async throws -> [String] {
        try await store.assistantGrants()
    }

    public func assistantTabGrantIDs() async throws -> [ChatID] {
        try await store.assistantTabGrants()
    }

    public func revokeAssistantGrant(_ actionClass: String) async throws {
        try await store.deleteAssistantGrant(actionClass)
        if let parsed = AssistantActionClass(rawValue: actionClass) {
            assistantAlwaysGrants.remove(parsed)
        }
    }

    public func revokeAssistantTabGrant(_ chatID: ChatID) async throws {
        try await store.deleteAssistantTabGrant(chatID)
    }

    public func grantTabAutoAllow(_ chatID: ChatID) async throws {
        try await store.saveAssistantTabGrant(chatID)
    }
}

enum AssistantActionError: Error, CustomStringConvertible {
    case badRequest(String)

    var description: String {
        switch self {
        case .badRequest(let message): message
        }
    }
}

struct AssistantTaskGrantKey: Hashable, Sendable {
    var actionClass: AssistantActionClass
    var workspaceID: WorkspaceID?
    var chatID: ChatID?
}
