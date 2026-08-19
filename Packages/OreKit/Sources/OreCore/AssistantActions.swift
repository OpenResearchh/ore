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

    static func tier(forTool tool: String) -> Tier {
        switch tool {
        // Reversible, contained, and usually the very thing the user just
        // asked for. Prompting on these is how an assistant becomes paperwork.
        case "CreateWorkspace", "CreateChat", "SendPromptToProject", "OpenWorkspace":
            return .auto

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
        "Commit", "Push", "CreatePullRequest", "ArchiveWorkspace",
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

        switch AssistantActionPolicy.tier(forTool: request.tool) {
        case .deny(let reason):
            await audit(request, summary: summary, decision: "denied")
            return AssistantBridgeResponse(id: request.id, ok: false, error: reason)

        case .auto:
            return await performAudited(request, summary: summary, decision: "auto")

        case .confirm(let actionClass):
            if let standing = await standingGrant(
                for: actionClass, workspaceID: requestWorkspaceID(request)
            ) {
                return await performAudited(request, summary: summary, decision: standing)
            }

            continuation.yield(.assistantConfirmationRequested(AssistantConfirmation(
                id: request.id,
                actionClass: actionClass,
                workspaceID: requestWorkspaceID(request),
                summary: summary
            )))
            let resolution = await awaitAssistantResolution(id: request.id)
            continuation.yield(.assistantConfirmationResolved(request.id))

            switch resolution {
            case .allowed(let scope):
                await applyAssistantGrant(
                    scope, to: actionClass, workspaceID: requestWorkspaceID(request)
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
    }

    // MARK: - Grants

    /// A grant that already covers this action class: an unexpired task grant
    /// for this workspace (which slides on use) or a persistent "always allow".
    private func standingGrant(
        for actionClass: AssistantActionClass,
        workspaceID: WorkspaceID?
    ) async -> String? {
        let key = AssistantTaskGrantKey(actionClass: actionClass, workspaceID: workspaceID)
        if let expiry = assistantTaskGrants[key], expiry > Date() {
            assistantTaskGrants[key] = Date()
                .addingTimeInterval(AssistantActionPolicy.taskGrantWindow)
            return "granted:task"
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
        workspaceID: WorkspaceID?
    ) async {
        switch scope {
        case .once:
            break
        case .task:
            assistantTaskGrants[AssistantTaskGrantKey(
                actionClass: actionClass, workspaceID: workspaceID
            )] = Date().addingTimeInterval(AssistantActionPolicy.taskGrantWindow)
        case .always:
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
            let record = try await createWorkspace(CreateWorkspaceRequest(
                repositoryPath: repository.path,
                name: arguments["name"]?.stringValue ?? "",
                initialPrompt: arguments["prompt"]?.stringValue
            ))
            return "Created workspace \"\(record.name)\" (id \(record.id)) "
                + "on branch \(record.branch) in \(repository.name)."
                + (arguments["prompt"]?.stringValue == nil
                    ? "" : " The initial prompt was sent to its agent.")

        case "CreateChat":
            let workspaceID = try requireWorkspace(arguments)
            let chat = try await engine(for: workspaceID).createChat(CreateChatRequest(
                workspaceID: workspaceID,
                title: arguments["title"]?.stringValue
            ))
            continuation.yield(.chatAdded(chat))
            if let prompt = arguments["prompt"]?.stringValue, !prompt.isEmpty {
                _ = try await engine(for: workspaceID).send(SendMessageRequest(
                    workspaceID: workspaceID, chatID: chat.id, text: prompt
                ))
            }
            return "Created chat \"\(chat.title)\" (id \(chat.id.rawValue))."

        case "SendPromptToProject":
            let workspaceID = try requireWorkspace(arguments)
            guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
                throw AssistantActionError.badRequest("SendPromptToProject needs text.")
            }
            let chatID = arguments["chatID"]?.stringValue.map(ChatID.init(rawValue:))
            let sent = try await engine(for: workspaceID).send(SendMessageRequest(
                workspaceID: workspaceID, chatID: chatID, text: text
            ))
            return sent
                ? "Sent. The project's agent is working on it."
                : "The agent was mid-turn, so the prompt was queued and will run next."

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
                base: "",
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

    private func requestWorkspaceID(_ request: AssistantBridgeRequest) -> WorkspaceID? {
        request.arguments["workspaceID"]?.stringValue.map(WorkspaceID.init(rawValue:))
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

    public func revokeAssistantGrant(_ actionClass: String) async throws {
        try await store.deleteAssistantGrant(actionClass)
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
}
