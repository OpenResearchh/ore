import AppKit
import CoreImage
import Darwin
import Foundation
import Network
import OreProtocol

/// A local HTTPS surface so an iPhone or iPad can drive this Mac's workspaces
/// while the lid is closed. Pairing is a QR code of the URL plus a token;
/// nothing is published off the machine. Wi-Fi pairing is omitted if TLS
/// cannot be issued, so the token is never sent in the clear on a café AP.
@MainActor
@Observable
final class RemoteControlServer {
    static let shared = RemoteControlServer()
    static let enabledKey = "ore.remote.enabled"
    static let tokenKey = "ore.remote.token"

    private(set) var isRunning = false
    private(set) var usesTLS = false
    private(set) var certificateFingerprint: String?
    private(set) var port: UInt16 = 0
    private(set) var lanURL: URL?
    private(set) var endpoints: [RemoteEndpoint] = []
    private(set) var tailscale = TailscaleStatus(kind: .missing, appURL: nil)
    private(set) var clientCount = 0
    private(set) var lastError: String?
    private(set) var tokenVersion = 0

    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: RemoteHTTPSession] = [:]
    private var model: AppModel?
    private var presenceExpire: Task<Void, Never>?
    private var endpointRefresh: Task<Void, Never>?

    var pairingToken: String {
        if let existing = UserDefaults.standard.string(forKey: Self.tokenKey), !existing.isEmpty {
            return existing
        }
        return rotateToken()
    }

    var pairingURL: URL? {
        endpoints.first?.pairingURL(token: pairingToken)
    }

    func refreshTailscale() async {
        tailscale = await TailscaleStatus.probe()
        if isRunning { refreshEndpoints() }
    }

    func bind(model: AppModel) {
        self.model = model
        if UserDefaults.standard.bool(forKey: Self.enabledKey) {
            start()
        }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { start() } else { stop() }
    }

    @discardableResult
    func rotateToken() -> String {
        let token = UUID().uuidString.lowercased()
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        tokenVersion &+= 1
        return token
    }

    func start() {
        guard listener == nil else { return }
        lastError = nil
        do {
            let configured = RemoteControlTLS.listenerParameters()
            usesTLS = configured.usesTLS
            certificateFingerprint = configured.usesTLS
                ? RemoteControlTLS.certificateFingerprint()
                : nil
            let listener = try NWListener(using: configured.0, on: .any)
            listener.service = NWListener.Service(name: "ORE", type: "_ore-remote._tcp")
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        if let port = self?.listener?.port?.rawValue {
                            self?.port = port
                            self?.refreshEndpoints()
                        }
                    case .failed(let error):
                        self?.lastError = error.localizedDescription
                        self?.isRunning = false
                        RemoteControlSleep.update(enabled: false)
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            RemoteControlSleep.update(enabled: true)
            startEndpointRefresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let open = Array(sessions.values)
        sessions.removeAll()
        for session in open { session.finish() }
        isRunning = false
        usesTLS = false
        certificateFingerprint = nil
        port = 0
        lanURL = nil
        endpoints = []
        tailscale = TailscaleStatus(kind: .missing, appURL: tailscale.appURL)
        clientCount = 0
        presenceExpire?.cancel()
        presenceExpire = nil
        endpointRefresh?.cancel()
        endpointRefresh = nil
        RemoteControlSleep.update(enabled: false)
    }

    func qrImage(dimension: CGFloat = 280) -> NSImage? {
        guard let pairingURL,
              let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }
        filter.setValue(Data(pairingURL.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = dimension / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    private func startEndpointRefresh() {
        endpointRefresh?.cancel()
        endpointRefresh = Task { [weak self] in
            while !Task.isCancelled {
                // `isRunning` is only set once the listener is `.ready`. Poll
                // while the listener still exists so Tailscale is not missed
                // during that window.
                guard let self, self.listener != nil else { return }
                if self.port == 0 {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                let status = await TailscaleStatus.probe()
                guard !Task.isCancelled else { return }
                self.tailscale = status
                self.refreshEndpoints()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    private func refreshEndpoints() {
        guard port != 0 else { return }
        let found = Self.endpoints(port: port, tailscale: tailscale, encrypted: usesTLS)
        endpoints = found
        lanURL = found.first?.pageURL
    }

    private func accept(_ connection: NWConnection) {
        if sessions.count >= RemoteHTTPLimits.maxSessions {
            connection.cancel()
            return
        }
        connection.start(queue: .main)
        let session = RemoteHTTPSession(connection: connection, server: self)
        sessions[ObjectIdentifier(session)] = session
        clientCount = sessions.count
        session.receive()
    }

    fileprivate func endSession(_ session: RemoteHTTPSession) {
        sessions.removeValue(forKey: ObjectIdentifier(session))
        clientCount = sessions.count
    }

    fileprivate func isAuthorized(_ token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        return token == pairingToken
    }

    fileprivate func handleAuthorized(path: String, query: [String: String], body: Data) -> (Int, String, Data) {
        if path == "/" {
            return (200, "text/html; charset=utf-8", Data(RemoteControlPage.html.utf8))
        }
        return route(path: path, query: query, body: body)
    }

    private func route(path: String, query: [String: String], body: Data) -> (Int, String, Data) {
        guard let model else {
            return (503, "text/plain", Data("ORE is starting\n".utf8))
        }
        switch path {
        case "/api/state":
            return json(state(model: model, query: query))
        case "/api/send":
            return mutate(body) { payload in
                guard let text = payload["text"], !text.isEmpty else { return }
                let workspace = workspaceID(payload["workspaceID"])
                    ?? model.selectedWorkspaceID
                    ?? model.assistantWorkspace?.id
                let chat = payload["chatID"].flatMap { raw -> ChatID? in
                    raw.isEmpty ? nil : ChatID(rawValue: raw)
                }
                guard let workspace else { return }
                let effort = payload["effort"].flatMap(ReasoningEffort.init(rawValue:))
                let fast = payload["fast"] == "1" || payload["fast"] == "true"
                let summary = chat.flatMap { model.chatIndex.summary(for: $0) }
                    ?? model.activeChat(for: workspace)
                let serviceTier = summary.flatMap {
                    resolvedServiceTier(model: model, chat: $0, fast: fast)
                }
                if let chat {
                    model.send(
                        text,
                        effort: effort,
                        serviceTier: serviceTier,
                        origin: .user,
                        to: workspace,
                        chatID: chat,
                        fromComposer: false
                    )
                } else {
                    _ = model.send(
                        text,
                        effort: effort,
                        serviceTier: serviceTier,
                        origin: .user,
                        to: workspace
                    )
                }
            }
        case "/api/stop":
            return mutate(body) { payload in
                let workspace = workspaceID(payload["workspaceID"])
                    ?? model.selectedWorkspaceID
                    ?? model.assistantWorkspace?.id
                guard let workspace else { return }
                if let raw = payload["chatID"], !raw.isEmpty {
                    model.interrupt(workspace, chatID: ChatID(rawValue: raw))
                } else {
                    model.interrupt(workspace)
                }
            }
        case "/api/select":
            return mutate(body) { payload in
                if let workspace = workspaceID(payload["workspaceID"]) {
                    // Assistant is not a sidebar selection on the Mac; pinning
                    // it here would blank the main window.
                    if !isAssistant(workspace, model: model) {
                        model.selectedWorkspaceID = workspace
                    }
                    if let raw = payload["chatID"], !raw.isEmpty {
                        model.selectChat(ChatID(rawValue: raw), in: workspace)
                    }
                }
            }
        case "/api/new-chat":
            return mutate(body) { payload in
                guard let workspace = workspaceID(payload["workspaceID"])
                    ?? model.selectedWorkspaceID
                    ?? model.assistantWorkspace?.id else { return }
                if isAssistant(workspace, model: model) {
                    model.createAssistantConversation()
                } else {
                    model.createChat(in: workspace)
                }
            }
        case "/api/composer":
            return mutate(body) { payload in
                applyComposer(model: model, payload: payload)
            }
        case "/api/permission":
            return mutate(body) { payload in
                guard let workspace = workspaceID(payload["workspaceID"])
                    ?? model.selectedWorkspaceID
                    ?? model.assistantWorkspace?.id,
                      let requestID = payload["requestID"], !requestID.isEmpty
                else { return }
                let chat = payload["chatID"].map { ChatID(rawValue: $0) }
                let allow = payload["decision"] != "deny"
                model.resolvePermission(
                    PermissionRequestID(rawValue: requestID),
                    decision: allow
                        ? .allow
                        : .deny(reason: "Denied from remote control."),
                    for: workspace,
                    chatID: chat
                )
            }
        case "/api/answer":
            return mutate(body) { payload in
                guard let workspace = workspaceID(payload["workspaceID"])
                    ?? model.selectedWorkspaceID
                    ?? model.assistantWorkspace?.id,
                      let questionID = payload["questionID"], !questionID.isEmpty,
                      let answer = payload["answer"]
                else { return }
                model.answerQuestion(
                    QuestionID(rawValue: questionID),
                    answer: answer,
                    for: workspace,
                    chatID: payload["chatID"].map { ChatID(rawValue: $0) }
                )
            }
        default:
            return (404, "text/plain", Data("not found\n".utf8))
        }
    }

    private func mutate(_ body: Data, _ work: ([String: String]) -> Void) -> (Int, String, Data) {
        let payload = jsonObject(body)
        work(payload)
        return (204, "text/plain", Data())
    }

    private func json(_ value: [String: Any]) -> (Int, String, Data) {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [])) ?? Data("{}".utf8)
        return (200, "application/json", data)
    }

    private func jsonObject(_ body: Data) -> [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in object {
            if let text = value as? String {
                result[key] = text
            } else if let flag = value as? Bool {
                result[key] = flag ? "1" : ""
            }
        }
        return result
    }

    private func workspaceID(_ raw: String?) -> WorkspaceID? {
        guard let raw, !raw.isEmpty else { return nil }
        return WorkspaceID(rawValue: raw)
    }

    private func isAssistant(_ id: WorkspaceID, model: AppModel) -> Bool {
        model.assistantWorkspace?.id == id
    }

    private func listedWorkspaces(model: AppModel) -> [WorkspaceSummary] {
        var listed: [WorkspaceSummary] = []
        if let assistant = model.assistantWorkspace {
            listed.append(assistant)
        }
        listed.append(contentsOf: model.sortedWorkspaces.filter { !$0.isDream })
        return Array(listed.prefix(40))
    }

    private func state(model: AppModel, query: [String: String]) -> [String: Any] {
        let workspaceID = self.workspaceID(query["workspace"])
            ?? model.selectedWorkspaceID
            ?? model.assistantWorkspace?.id
        let chatID = query["chat"].flatMap { raw -> ChatID? in
            raw.isEmpty ? nil : ChatID(rawValue: raw)
        } ?? workspaceID.flatMap { model.activeChat(for: $0)?.id }
        let workspaces = listedWorkspaces(model: model).map { workspace -> [String: String] in
            [
                "id": workspace.id.rawValue,
                "name": workspace.isAssistant ? (workspace.name.isEmpty ? "Assistant" : workspace.name) : workspace.name,
                "branch": workspace.isAssistant ? "Conversations" : workspace.branch,
                "kind": workspace.kind?.rawValue ?? "standard",
                "needsYou": workspace.hasUnread ? "1" : "",
            ]
        }
        var chats: [[String: String]] = []
        if let workspaceID {
            chats = model.chats(for: workspaceID).prefix(30).map { chat in
                [
                    "id": chat.id.rawValue,
                    "workspaceID": workspaceID.rawValue,
                    "title": chat.title,
                    "busy": chat.isTurnActive ? "1" : "",
                    "unread": chat.hasUnread ? "1" : "",
                ]
            }
        }
        var messages: [[String: Any]] = []
        var permissions: [[String: String]] = []
        var questions: [[String: Any]] = []
        var busy = false
        var willQueue = false
        var queueHint = ""
        var error = ""
        var usage: UsageReport?
        if let chatID {
            let chat = model.chat(for: chatID)
            busy = chat.isBusy
            willQueue = chat.willQueueNextMessage
            usage = chat.usage
            if willQueue {
                queueHint = chat.status == .awaitingInput
                    ? "This will queue — the agent is waiting on you."
                    : "This will queue behind the current turn."
            }
            error = chat.prominentError?.message ?? ""
            let hiding: TurnID? = {
                if case .proposal = chat.plan { return chat.planTurnID }
                return nil
            }()
            let displayed = TranscriptDisplay.rows(
                from: chat.rows,
                keepLiveTurnExpanded: chat.isTurnActive,
                expanded: [],
                memo: TranscriptDisplay.Memo(),
                hidingPlanTurnID: hiding
            )
            let agentName = model.chatIndex.summary(for: chatID)?.harness.displayName ?? "Agent"
            let stamp = ISO8601DateFormatter()
            var headerTurns = Set<TurnID>()
            messages = displayed.suffix(80).compactMap { row in
                guard row.kind != .divider, row.kind != .turnFooter else { return nil }
                var payload = Self.message(from: row)
                if (row.kind == .activityGroup || row.kind == .assistantText || row.kind == .plan),
                   headerTurns.insert(row.turnID).inserted {
                    payload["header"] = agentName
                    payload["at"] = stamp.string(from: row.createdAt)
                }
                return payload
            }
            permissions = chat.pendingPermissions.compactMap { request in
                if request.toolName == "AskUserQuestion" { return nil }
                if request.toolName == "ExitPlanMode", case .proposal = chat.plan { return nil }
                let shown = PermissionPresentation(request: request)
                return [
                    "id": request.id.rawValue,
                    "action": shown.action,
                    "target": shown.target ?? "",
                    "detail": shown.detail ?? "",
                ]
            }
            questions = chat.pendingQuestions.map { question in
                [
                    "id": question.id.rawValue,
                    "prompt": question.prompt,
                    "freeform": question.allowsFreeform,
                    "options": question.options.map { $0.label },
                ] as [String: Any]
            }
        }
        let summary = chatID.flatMap { model.chatIndex.summary(for: $0) }
        return [
            "workspaces": workspaces,
            "chats": chats,
            "messages": messages,
            "permissions": permissions,
            "questions": questions,
            "busy": busy,
            "willQueue": willQueue,
            "queueHint": queueHint,
            "error": error,
            "selectedWorkspace": workspaceID?.rawValue ?? "",
            "selectedChat": chatID?.rawValue ?? "",
            "composer": composerSnapshot(model: model, chat: summary, usage: usage),
        ]
    }

    private func composerSnapshot(
        model: AppModel,
        chat: ChatSummary?,
        usage: UsageReport?
    ) -> [String: Any] {
        var kinds = model.readyHarnesses
        if let chat, !kinds.contains(chat.harness) {
            kinds.insert(chat.harness, at: 0)
        }
        let harnesses: [[String: Any]] = kinds.map { kind in
            [
                "id": kind.rawValue,
                "name": kind.displayName,
                "models": composerModels(model: model, harness: kind),
            ]
        }
        let permissionModes: [[String: String]] = PermissionMode.allCases.map {
            ["id": $0.rawValue, "name": $0.displayName]
        }
        guard let chat else {
            return [
                "harnesses": harnesses,
                "permissionModes": permissionModes,
                "harness": kinds.first?.rawValue ?? "",
                "model": "",
                "effort": "",
                "permissionMode": PermissionMode.default.rawValue,
                "fast": false,
                "supportsFast": false,
                "supportsEffort": false,
                "efforts": [] as [Any],
                "context": "",
            ]
        }
        let choices = model.knownModels(for: chat.harness)
        let family = ModelVariantCatalog.family(containing: chat.model, in: choices)
        let efforts = availableEfforts(model: model, chat: chat)
        let fast = isFastEnabled(chat: chat, family: family)
        let supportsFast = supportsFastMode(chat, family: family, choices: choices)
        let selectedModel = family?.id ?? chat.model ?? model.defaultModelID(for: chat.harness) ?? ""
        let selectedName = family?.displayName
            ?? choices.first { $0.id == chat.model }?.displayName
            ?? chat.model
            ?? chat.harness.displayName
        let effort = chat.reasoningEffort
            ?? family?.encodedEffort(of: chat.model)
            ?? storedEffort(for: chat)
        let report = usage ?? chat.contextUsage
        var context = ""
        if let report, let window = report.contextWindow, window > 0 {
            let percent = min(100, (report.totalContextTokens * 100) / window)
            context = "\(percent)%"
        }
        return [
            "harnesses": harnesses,
            "permissionModes": permissionModes,
            "harness": chat.harness.rawValue,
            "model": selectedModel,
            "modelName": selectedName,
            "effort": effort?.rawValue ?? "",
            "permissionMode": chat.permissionMode.rawValue,
            "fast": fast,
            "supportsFast": supportsFast,
            "supportsEffort": !efforts.isEmpty,
            "efforts": efforts.map { ["id": $0.rawValue, "name": $0.displayName] },
            "context": context,
        ]
    }

    private func composerModels(model: AppModel, harness: HarnessKind) -> [[String: Any]] {
        let choices = model.knownModels(for: harness)
        let families = ModelVariantCatalog.families(from: choices)
        if families.isEmpty {
            return choices.map { agent in
                [
                    "id": agent.id,
                    "name": agent.displayName,
                    "description": agent.description,
                    "default": agent.isDefault,
                ] as [String: Any]
            }
        }
        return families.map { family in
            [
                "id": family.id,
                "name": family.displayName,
                "description": family.description,
                "default": family.isDefault,
            ] as [String: Any]
        }
    }

    private func applyComposer(model: AppModel, payload: [String: String]) {
        let workspace = workspaceID(payload["workspaceID"])
            ?? model.selectedWorkspaceID
            ?? model.assistantWorkspace?.id
        guard let workspace else { return }
        let chatID = payload["chatID"].flatMap { raw -> ChatID? in
            raw.isEmpty ? nil : ChatID(rawValue: raw)
        } ?? model.activeChat(for: workspace)?.id
        guard let chatID, let chat = model.chatIndex.summary(for: chatID) else { return }
        model.selectChat(chatID, in: workspace)
        let effort = payload["effort"].flatMap(ReasoningEffort.init(rawValue:))
        let fast = payload["fast"] == "1" || payload["fast"] == "true"
        let harness = payload["harness"].flatMap(HarnessKind.init(rawValue:)) ?? chat.harness
        let desiredModel = resolvedModelID(
            payload["model"],
            harness: harness,
            effort: effort,
            fast: fast,
            model: model
        )
        if harness != chat.harness {
            model.switchHarness(harness, model: desiredModel, for: chat)
        } else if desiredModel != nil, desiredModel != chat.model {
            model.setModel(desiredModel, for: chat)
        }
        if let effort {
            model.setEffort(effort, for: chat)
            UserDefaults.standard.set(effort.rawValue, forKey: "ore.reasoningEffort.\(chat.id.rawValue)")
        }
        if let mode = payload["permissionMode"].flatMap(PermissionMode.init(rawValue:)),
           mode != chat.permissionMode {
            model.setPermissionMode(mode, for: workspace)
        }
        UserDefaults.standard.set(fast, forKey: "ore.fastMode.\(chat.id.rawValue)")
    }

    private func resolvedModelID(
        _ raw: String?,
        harness: HarnessKind,
        effort: ReasoningEffort?,
        fast: Bool,
        model: AppModel
    ) -> String? {
        let choices = model.knownModels(for: harness)
        guard let raw, !raw.isEmpty else { return model.defaultModelID(for: harness) }
        let families = ModelVariantCatalog.families(from: choices)
        if let family = families.first(where: {
            $0.id == raw || $0.variants.contains { $0.id == raw }
        }) {
            return family.resolve(effort: effort, fast: family.supportsFast && fast).id
        }
        return raw
    }

    private func availableEfforts(model: AppModel, chat: ChatSummary) -> [ReasoningEffort] {
        let choices = model.knownModels(for: chat.harness)
        if let family = ModelVariantCatalog.family(containing: chat.model, in: choices),
           family.encodedEfforts.count > 1 {
            return family.encodedEfforts
        }
        guard chat.harness.supportsReasoningEffort else { return [] }
        let selected: AgentModel?
        if let requestedID = chat.model {
            selected = choices.first { $0.id == requestedID }
            if selected == nil { return [] }
        } else {
            selected = choices.first(where: \.isDefault) ?? choices.first
        }
        let advertised = Set(selected?.supportedReasoningEfforts ?? [])
        guard !advertised.isEmpty else { return [] }
        return ReasoningEffort.allCases.filter { advertised.contains($0.rawValue) }
    }

    private func supportsFastMode(
        _ chat: ChatSummary,
        family: ModelFamily?,
        choices: [AgentModel]
    ) -> Bool {
        if family?.supportsFast == true { return true }
        guard chat.harness == .codex else { return false }
        let selected: AgentModel?
        if let id = chat.model {
            selected = choices.first { $0.id == id }
            if selected == nil { return false }
        } else {
            selected = choices.first(where: \.isDefault) ?? choices.first
        }
        return selected?.supportedServiceTiers.contains("fast") == true
    }

    private func isFastEnabled(
        chat: ChatSummary,
        family: ModelFamily?
    ) -> Bool {
        if let family, family.supportsFast {
            return family.isFast(chat.model)
        }
        return UserDefaults.standard.bool(forKey: "ore.fastMode.\(chat.id.rawValue)")
    }

    private func storedEffort(for chat: ChatSummary) -> ReasoningEffort? {
        let key = "ore.reasoningEffort.\(chat.id.rawValue)"
        return UserDefaults.standard.string(forKey: key).flatMap(ReasoningEffort.init(rawValue:))
    }

    private func resolvedServiceTier(
        model: AppModel,
        chat: ChatSummary,
        fast: Bool
    ) -> String? {
        guard fast else { return nil }
        let choices = model.knownModels(for: chat.harness)
        if let family = ModelVariantCatalog.family(containing: chat.model, in: choices),
           family.supportsFast {
            return nil
        }
        guard supportsFastMode(
            chat,
            family: ModelVariantCatalog.family(containing: chat.model, in: choices),
            choices: choices
        ) else { return nil }
        return "fast"
    }

    private static func message(from row: TranscriptRow, nested: Bool = false) -> [String: Any] {
        let kind: String
        switch row.kind {
        case .userMessage: kind = "you"
        case .assistantText: kind = "agent"
        case .toolCall: kind = "tool"
        case .activityGroup: kind = "activity"
        case .thinking: kind = "thinking"
        case .error: kind = "error"
        case .plan: kind = "plan"
        case .divider, .turnFooter: kind = "agent"
        }
        let title: String
        switch row.kind {
        case .activityGroup:
            title = row.text
        case .thinking:
            title = "Thinking"
        case .toolCall:
            title = row.toolName ?? row.resolvedSubject ?? row.text
        default:
            title = row.toolName ?? row.resolvedSubject ?? ""
        }
        let detail = row.resultText.flatMap { $0.isEmpty ? nil : $0 }
        let body: String
        switch row.kind {
        case .toolCall:
            body = detail ?? row.text
        case .activityGroup:
            body = row.text
        default:
            body = row.text
        }
        let expandable = row.kind == .activityGroup
            || row.kind == .toolCall
            || row.kind == .thinking
            || row.kind == .error
        var payload: [String: Any] = [
            "id": row.id,
            "kind": kind,
            "turn": row.turnID.rawValue,
            "title": String(title.prefix(120)),
            "text": String(body.prefix(12_000)),
            "queued": row.isQueued,
            "complete": row.isComplete,
            "expandable": expandable,
            "nested": nested,
        ]
        if let detail, row.kind == .toolCall || row.kind == .error {
            payload["detail"] = String(detail.prefix(8_000))
        }
        if row.kind == .activityGroup, !row.groupedRows.isEmpty {
            payload["steps"] = row.groupedRows.map { message(from: $0, nested: true) }
        }
        return payload
    }

    private static func endpoints(
        port: UInt16,
        tailscale: TailscaleStatus,
        encrypted: Bool
    ) -> [RemoteEndpoint] {
        var found: [RemoteEndpoint] = []
        if case .connected(let ipv4, let magicDNS, _) = tailscale.kind {
            if let magicDNS {
            found.append(RemoteEndpoint(
                kind: .tailscale,
                label: "Tailscale",
                host: magicDNS,
                port: port,
                encrypted: encrypted,
                detail: "Away from home — iPad also needs Tailscale, same account"
            ))
            }
            if !found.contains(where: { $0.host == ipv4 }) {
                found.append(RemoteEndpoint(
                    kind: .tailscale,
                    label: magicDNS == nil ? "Tailscale" : "Tailscale IP",
                    host: ipv4,
                    port: port,
                    encrypted: encrypted,
                    detail: magicDNS == nil
                        ? "Away from home — iPad also needs Tailscale, same account"
                        : nil
                ))
            }
        }

        var address: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&address) == 0, let first = address else { return found }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sa = current.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                sa, socklen_t(sa.pointee.sa_len),
                &hostname, socklen_t(hostname.count),
                nil, 0, NI_NUMERICHOST
            )
            let ip = String(cString: hostname)
            if ip.hasPrefix("127.") { continue }
            if found.contains(where: { $0.host == ip }) { continue }
            let name = String(cString: current.pointee.ifa_name)
            let kind: RemoteEndpoint.Kind
            let label: String
            if Self.isTailscale(ip) {
                if tailscale.isConnected { continue }
                kind = .tailscale
                label = "Tailscale"
            } else if name.hasPrefix("en") {
                kind = .wifi
                label = "Wi-Fi / Ethernet"
            } else if name.hasPrefix("utun") {
                kind = .vpn
                label = "VPN"
            } else {
                kind = .other
                label = name
            }
            // Wi-Fi pairing with a self-signed cert is first-use MITM: Safari
            // will offer to continue on an attacker's certificate. Tailscale
            // and VPN already encrypt the path, so those stay.
            if kind == .wifi || kind == .other { continue }
            found.append(RemoteEndpoint(
                kind: kind,
                label: label,
                host: ip,
                port: port,
                encrypted: encrypted,
                detail: kind == .wifi ? "Same network as this Mac" : nil
            ))
        }
        return found.sorted { lhs, rhs in
            if lhs.kind.rank != rhs.kind.rank { return lhs.kind.rank < rhs.kind.rank }
            return lhs.host < rhs.host
        }
    }

    private static func isTailscale(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4, parts[0] == "100", let second = Int(parts[1]) else {
            return false
        }
        return (64...127).contains(second)
    }
}

struct RemoteEndpoint: Identifiable, Equatable {
    enum Kind: Equatable {
        case tailscale, wifi, vpn, other
        var rank: Int {
            switch self {
            case .tailscale: 0
            case .vpn: 1
            case .wifi: 2
            case .other: 3
            }
        }
    }

    var kind: Kind
    var label: String
    var host: String
    var port: UInt16
    var encrypted: Bool
    var detail: String?
    var id: String { host }

    var pageURL: URL {
        let host = self.host.contains(":") ? "[\(self.host)]" : self.host
        let scheme = encrypted ? "https" : "http"
        return URL(string: "\(scheme)://\(host):\(port)/")!
    }

    func pairingURL(token: String) -> URL {
        URL(string: pageURL.absoluteString + "#" + token)!
    }
}

/// One HTTP/1.1 request on an `NWConnection`.
@MainActor
private final class RemoteHTTPSession {
    let connection: NWConnection
    weak var server: RemoteControlServer?
    private var buffer = Data()
    private var sawHeaders = false
    private var expectedBody = 0
    private var method = "GET"
    private var path = "/"
    private var query: [String: String] = [:]
    private var headerToken: String?
    private var closed = false
    private var didRespond = false
    private var idleTask: Task<Void, Never>?
    private var lifetimeTask: Task<Void, Never>?

    init(connection: NWConnection, server: RemoteControlServer) {
        self.connection = connection
        self.server = server
    }

    func receive() {
        armLifetime()
        armIdle()
        read()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.armIdle()
                }
                self.consume()
                if isComplete || error != nil {
                    self.finish()
                } else if self.connection.state == .ready {
                    self.read()
                }
            }
        }
    }

    private func armIdle() {
        idleTask?.cancel()
        idleTask = Task { @MainActor in
            try? await Task.sleep(for: RemoteHTTPLimits.idleTimeout)
            guard !Task.isCancelled else { return }
            self.finish()
        }
    }

    private func armLifetime() {
        guard lifetimeTask == nil else { return }
        lifetimeTask = Task { @MainActor in
            try? await Task.sleep(for: RemoteHTTPLimits.maxLifetime)
            guard !Task.isCancelled else { return }
            self.finish()
        }
    }

    private func consume() {
        guard !closed, !didRespond else { return }
        if !sawHeaders {
            if RemoteHTTPLimits.headersTooLarge(buffer) {
                respond(status: 413, type: "text/plain", body: Data("payload too large\n".utf8))
                return
            }
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if parseHeaders(String(decoding: headerData, as: UTF8.self)) == false {
                respond(status: 400, type: "text/plain", body: Data("bad request\n".utf8))
                return
            }
            sawHeaders = true
        }
        if buffer.count > RemoteHTTPLimits.maxBodyBytes {
            respond(status: 413, type: "text/plain", body: Data("payload too large\n".utf8))
            return
        }
        guard sawHeaders, buffer.count >= expectedBody else { return }
        let body = Data(buffer.prefix(expectedBody))
        buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: expectedBody))
        respond(body: body)
    }

    /// Returns false when the request must be rejected before reading a body.
    @discardableResult
    private func parseHeaders(_ text: String) -> Bool {
        switch RemoteHTTPLimits.contentLength(from: text) {
        case .missing:
            expectedBody = 0
        case .valid(let length):
            expectedBody = length
        case .invalid:
            return false
        }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let request = lines.first else { return true }
        let parts = request.split(separator: " ")
        if parts.count >= 2 {
            method = String(parts[0])
            let target = String(parts[1])
            if let components = URLComponents(string: "http://local\(target)") {
                path = components.path
                for item in components.queryItems ?? [] {
                    if let value = item.value { query[item.name] = value }
                }
            } else {
                path = target
            }
        }
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("x-ore-token:") {
                headerToken = line.split(separator: ":", maxSplits: 1)[1]
                    .trimmingCharacters(in: .whitespaces)
            }
            if lower.hasPrefix("authorization:") {
                let value = line.split(separator: ":", maxSplits: 1)[1]
                    .trimmingCharacters(in: .whitespaces)
                if value.lowercased().hasPrefix("bearer ") {
                    headerToken = String(value.dropFirst(7))
                }
            }
        }
        return true
    }

    private func respond(body: Data) {
        if let headerToken { query["token"] = headerToken }
        let authorized = server?.isAuthorized(query["token"]) == true
        let result: (Int, String, Data)
        if path == "/" {
            result = (200, "text/html; charset=utf-8", Data(RemoteControlPage.html.utf8))
        } else if !authorized {
            result = (401, "text/plain", Data("unauthorized\n".utf8))
        } else {
            result = server?.handleAuthorized(path: path, query: query, body: body)
                ?? (503, "text/plain", Data())
        }
        respond(status: result.0, type: result.1, body: result.2)
    }

    private func respond(status: Int, type: String, body: Data) {
        guard !closed, !didRespond else { return }
        didRespond = true
        let statusText = status == 200 ? "OK" : status == 204 ? "No Content"
            : status == 400 ? "Bad Request"
            : status == 401 ? "Unauthorized"
            : status == 413 ? "Payload Too Large" : "Error"
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "Access-Control-Allow-Origin: *\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.finish() }
        })
    }

    fileprivate func finish() {
        guard !closed else { return }
        closed = true
        idleTask?.cancel()
        lifetimeTask?.cancel()
        idleTask = nil
        lifetimeTask = nil
        connection.cancel()
        server?.endSession(self)
    }
}
