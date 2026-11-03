import AppKit
import CoreImage
import Darwin
import Foundation
import Network
import OreProtocol

/// A local HTTP surface so an iPhone or iPad can drive this Mac's workspaces
/// while the lid is closed. Pairing is a QR code of the LAN URL plus a token;
/// nothing is published off the machine.
@MainActor
@Observable
final class RemoteControlServer {
    static let shared = RemoteControlServer()
    static let enabledKey = "ore.remote.enabled"
    static let tokenKey = "ore.remote.token"

    private(set) var isRunning = false
    private(set) var port: UInt16 = 0
    private(set) var lanURL: URL?
    private(set) var endpoints: [RemoteEndpoint] = []
    private(set) var tailscale = TailscaleStatus(kind: .missing, appURL: nil)
    private(set) var clientCount = 0
    private(set) var lastError: String?
    private(set) var tokenVersion = 0

    private var listener: NWListener?
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
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters, on: .any)
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
        isRunning = false
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
                guard let self, self.isRunning else { return }
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
        let found = Self.endpoints(port: port, tailscale: tailscale)
        endpoints = found
        lanURL = found.first?.pageURL
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        RemoteHTTPSession(connection: connection, server: self).receive()
    }

    fileprivate func notePresence() {
        clientCount = 1
        presenceExpire?.cancel()
        presenceExpire = Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            clientCount = 0
        }
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
                let chat = payload["chatID"].map { ChatID(rawValue: $0) }
                guard let workspace else { return }
                if let chat {
                    model.send(text, origin: .user, to: workspace, chatID: chat, fromComposer: false)
                } else {
                    _ = model.send(text, origin: .user, to: workspace)
                }
            }
        case "/api/stop":
            return mutate(body) { payload in
                let workspace = workspaceID(payload["workspaceID"])
                    ?? model.selectedWorkspaceID
                guard let workspace else { return }
                if let raw = payload["chatID"] {
                    model.interrupt(workspace, chatID: ChatID(rawValue: raw))
                } else {
                    model.interrupt(workspace)
                }
            }
        case "/api/select":
            return mutate(body) { payload in
                if let workspace = workspaceID(payload["workspaceID"]) {
                    model.selectedWorkspaceID = workspace
                    if let raw = payload["chatID"] {
                        model.selectChat(ChatID(rawValue: raw), in: workspace)
                    }
                }
            }
        case "/api/new-chat":
            return mutate(body) { payload in
                guard let workspace = workspaceID(payload["workspaceID"])
                    ?? model.selectedWorkspaceID else { return }
                model.createChat(in: workspace)
            }
        case "/api/permission":
            return mutate(body) { payload in
                guard let workspace = workspaceID(payload["workspaceID"])
                    ?? model.selectedWorkspaceID,
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
                    ?? model.selectedWorkspaceID,
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
            if let text = value as? String { result[key] = text }
        }
        return result
    }

    private func workspaceID(_ raw: String?) -> WorkspaceID? {
        guard let raw, !raw.isEmpty else { return nil }
        return WorkspaceID(rawValue: raw)
    }

    private func state(model: AppModel, query: [String: String]) -> [String: Any] {
        let workspaceID = query["workspace"].map(WorkspaceID.init(rawValue:))
            ?? model.selectedWorkspaceID
        let chatID = query["chat"].map(ChatID.init(rawValue:))
            ?? workspaceID.flatMap { model.activeChat(for: $0)?.id }
        let workspaces = model.sortedWorkspaces
            .filter { !$0.isAssistant && !$0.isDream }
            .prefix(40)
            .map { workspace -> [String: String] in
                [
                    "id": workspace.id.rawValue,
                    "name": workspace.name,
                    "branch": workspace.branch,
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
        if let chatID {
            let chat = model.chat(for: chatID)
            busy = chat.isBusy
            willQueue = chat.willQueueNextMessage
            if willQueue {
                queueHint = chat.status == .awaitingInput
                    ? "This will queue — the agent is waiting on you."
                    : "This will queue behind the current turn."
            }
            error = chat.prominentError?.message ?? ""
            let rows = chat.rows.filter { row in
                switch row.kind {
                case .divider, .turnFooter: return false
                default: return true
                }
            }
            messages = rows.suffix(50).map { Self.message(from: $0) }
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
        ]
    }

    private static func message(from row: TranscriptRow) -> [String: Any] {
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
        let title = row.toolName ?? row.resolvedSubject ?? ""
        let body = row.resultText.flatMap { $0.isEmpty ? nil : $0 } ?? row.text
        return [
            "kind": kind,
            "title": String(title.prefix(80)),
            "text": String(body.prefix(2_000)),
            "queued": row.isQueued,
        ]
    }

    private static func endpoints(port: UInt16, tailscale: TailscaleStatus) -> [RemoteEndpoint] {
        var found: [RemoteEndpoint] = []
        if case .connected(let ipv4, let magicDNS, _) = tailscale.kind {
            if let magicDNS {
                found.append(RemoteEndpoint(
                    kind: .tailscale,
                    label: "Tailscale",
                    host: magicDNS,
                    port: port,
                    detail: "Away from home — iPad also needs Tailscale, same account"
                ))
            }
            if !found.contains(where: { $0.host == ipv4 }) {
                found.append(RemoteEndpoint(
                    kind: .tailscale,
                    label: magicDNS == nil ? "Tailscale" : "Tailscale IP",
                    host: ipv4,
                    port: port,
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
            found.append(RemoteEndpoint(
                kind: kind,
                label: label,
                host: ip,
                port: port,
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
    var detail: String?
    var id: String { host }

    var pageURL: URL { URL(string: "http://\(host):\(port)/")! }

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

    init(connection: NWConnection, server: RemoteControlServer) {
        self.connection = connection
        self.server = server
    }

    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty { self.buffer.append(data) }
                self.consume()
                if isComplete || error != nil {
                    self.finish()
                } else if self.connection.state == .ready {
                    self.receive()
                }
            }
        }
    }

    private func consume() {
        if !sawHeaders {
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            parseHeaders(String(decoding: headerData, as: UTF8.self))
            sawHeaders = true
        }
        guard sawHeaders, buffer.count >= expectedBody else { return }
        let body = buffer.prefix(expectedBody)
        buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: expectedBody))
        respond(body: Data(body))
    }

    private func parseHeaders(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let request = lines.first else { return }
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
            if lower.hasPrefix("content-length:") {
                expectedBody = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
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
            server?.notePresence()
            result = server?.handleAuthorized(path: path, query: query, body: body)
                ?? (503, "text/plain", Data())
        }
        let statusText = result.0 == 200 ? "OK" : result.0 == 204 ? "No Content"
            : result.0 == 401 ? "Unauthorized" : "Error"
        var head = "HTTP/1.1 \(result.0) \(statusText)\r\n"
        head += "Content-Type: \(result.1)\r\n"
        head += "Content-Length: \(result.2.count)\r\n"
        head += "Connection: close\r\n"
        head += "Access-Control-Allow-Origin: *\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(result.2)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
            Task { @MainActor in self?.finish() }
        })
    }

    private func finish() {
        connection.cancel()
    }
}
