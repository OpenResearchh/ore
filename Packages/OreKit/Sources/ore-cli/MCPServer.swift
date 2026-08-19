import Foundation
import OreGit
import OrePersistence
import OreProtocol

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Minimal MCP stdio server used by both Claude Code and Codex. Keeping this in
/// the headless executable means agents receive review context as tools without
/// the Mac UI needing to be alive or reachable over a private socket.
///
/// With `--assistant`, the server also exposes cross-workspace read tools,
/// answered from a read-only view of the app's database (`--db`, or the
/// default store). Reads need no IPC with the app at all — WAL lets this
/// process read while the app writes.
func runMCPServer(options: CommandLineOptions) async {
    let directory = options.workingDirectory
    let assistant = AssistantToolServer(
        enabled: options.flag("--assistant"),
        databaseURL: options.databaseURL
    )
    while let line = readLine() {
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = request["method"] as? String else { continue }
        let id = request["id"]
        if method == "notifications/initialized" { continue }
        let result: Any
        switch method {
        case "initialize":
            result = [
                "protocolVersion": "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "ore", "version": "0.1.0"],
            ]
        case "tools/list":
            result = ["tools": toolDefinitions() + assistant.toolDefinitions()]
        case "tools/call":
            let params = request["params"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            let arguments = params?["arguments"] as? [String: Any] ?? [:]
            if assistant.handles(name) {
                result = await assistant.call(name, arguments: arguments)
            } else {
                result = await callORETool(name, arguments: arguments, directory: directory)
            }
        default:
            writeMCP(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": [
                "code": -32601, "message": "Method not found",
            ]])
            continue
        }
        if let id { writeMCP(["jsonrpc": "2.0", "id": id, "result": result]) }
    }
}

private func toolDefinitions() -> [[String: Any]] { [
    [
        "name": "GetWorkspaceDiff",
        "description": "Read the current git diff for this ORE workspace, matching the Review pane: this branch versus its base, including untracked files.",
        "inputSchema": ["type": "object", "properties": [:]],
    ],
    [
        "name": "GetDiffComments",
        "description": "Read review comments the user anchored to the current diff.",
        "inputSchema": ["type": "object", "properties": [:]],
    ],
    [
        "name": "PostDiffComment",
        "description": "Anchor a numbered review finding to a file and line range in the current diff. Use this instead of describing findings in prose so the user can say 'fix 2 and 4'.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "filePath": ["type": "string", "description": "Path relative to the worktree."],
                "startLine": ["type": "integer"],
                "endLine": ["type": "integer"],
                "body": ["type": "string", "description": "The finding, as the user should read it."],
                "context": ["type": "string", "description": "Optional surrounding code for the comment."],
            ],
            "required": ["filePath", "startLine", "body"],
        ],
    ],
    [
        "name": "AskUserQuestion",
        "description": "Ask the ORE user a blocking question. The question appears in the workspace context inbox.",
        "inputSchema": [
            "type": "object",
            "properties": ["question": ["type": "string"]],
            "required": ["question"],
        ],
    ],
] }

private func callORETool(
    _ name: String, arguments: [String: Any], directory: URL
) async -> [String: Any] {
    let text: String
    switch name {
    case "GetWorkspaceDiff":
        text = await ReviewDiff.unifiedText(in: directory)
    case "GetDiffComments":
        if let data = try? JSONEncoder().encode(DiffCommentFile.load(in: directory)),
           let json = String(data: data, encoding: .utf8) {
            text = json
        } else {
            text = "[]"
        }
    case "PostDiffComment":
        text = postDiffComment(arguments: arguments, directory: directory)
    case "AskUserQuestion":
        let question = arguments["question"] as? String ?? "The agent has a question."
        let inbox = directory.appendingPathComponent(".context/ore-questions.txt")
        try? FileManager.default.createDirectory(
            at: inbox.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let entry = "\(ISO8601DateFormatter().string(from: Date()))\t\(question)\n"
        if let handle = try? FileHandle(forWritingTo: inbox) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(to: inbox, atomically: true, encoding: .utf8)
        }
        text = "Question recorded for the user: \(question)"
    default:
        return ["content": [["type": "text", "text": "Unknown ORE tool: \(name)"]], "isError": true]
    }
    return ["content": [["type": "text", "text": text]]]
}

private func postDiffComment(arguments: [String: Any], directory: URL) -> String {
    let filePath = arguments["filePath"] as? String ?? ""
    let startLine = (arguments["startLine"] as? Int)
        ?? (arguments["startLine"] as? Double).map(Int.init)
        ?? 0
    let endLine = (arguments["endLine"] as? Int)
        ?? (arguments["endLine"] as? Double).map(Int.init)
        ?? startLine
    let body = arguments["body"] as? String ?? ""
    let context = arguments["context"] as? String
    guard !filePath.isEmpty, !body.isEmpty, startLine > 0 else {
        return "PostDiffComment needs filePath, startLine, and body."
    }

    let comment = DiffCommentReference(
        filePath: filePath,
        startLine: startLine,
        endLine: endLine,
        body: body,
        context: context.flatMap { $0.isEmpty ? nil : $0 }
    )
    do {
        let count = try DiffCommentFile.append(comment, in: directory)
        return "Recorded finding #\(count) on \(filePath):\(startLine)-\(endLine)."
    } catch {
        return "Could not record the comment: \(error)"
    }
}

// MARK: - Assistant read tools

/// Cross-workspace read tools for the ORE assistant's session. Everything is
/// answered from a read-only store — this server can see all of the user's
/// workspaces, but it cannot change any of them (actions arrive in M2 over a
/// bridge the app enforces policy on).
private final class AssistantToolServer {
    private let enabled: Bool
    private let databaseURL: URL
    private var store: OreStore?

    private static let readToolNames: Set<String> = [
        "ListWorkspaces", "ListChats", "WorkspaceStatus",
        "SearchTranscripts", "GetTranscriptTail",
    ]
    private static let actionToolNames: Set<String> = [
        "CreateWorkspace", "CreateChat", "SendPromptToProject", "OpenWorkspace",
        "Commit", "Push", "CreatePullRequest", "ArchiveWorkspace", "ListHarnesses",
    ]

    init(enabled: Bool, databaseURL: URL) {
        self.enabled = enabled
        self.databaseURL = databaseURL
    }

    func handles(_ name: String) -> Bool {
        enabled && (Self.readToolNames.contains(name) || Self.actionToolNames.contains(name))
    }

    func toolDefinitions() -> [[String: Any]] {
        guard enabled else { return [] }
        return [
            [
                "name": "ListWorkspaces",
                "description": "List every workspace the user has in ORE, across all repositories: names, ids, branches, models, archived state and last activity. Start here to resolve which workspace the user means.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "includeArchived": ["type": "boolean", "description": "Include archived workspaces. Default false."],
                    ],
                ],
            ],
            [
                "name": "ListChats",
                "description": "List the chat tabs of one workspace: titles, harnesses, models, open/closed state and last activity.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                    ],
                    "required": ["workspaceID"],
                ],
            ],
            [
                "name": "WorkspaceStatus",
                "description": "One workspace in depth: branch, model, queued messages, and each chat's most recent turn (prompt, outcome, summary).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                    ],
                    "required": ["workspaceID"],
                ],
            ],
            [
                "name": "SearchTranscripts",
                "description": "Full-text search across every workspace's chat transcripts, newest first. Use to answer 'where was I doing X' or to resolve vague project references.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "limit": ["type": "integer", "description": "Max hits, default 20."],
                    ],
                    "required": ["query"],
                ],
            ],
            [
                "name": "GetTranscriptTail",
                "description": "The recent conversation of one chat: prior turn summaries plus the last few prompts and replies. Defaults to the workspace's first chat when chatID is omitted.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "chatID": ["type": "string"],
                    ],
                    "required": ["workspaceID"],
                ],
            ],
            [
                "name": "CreateWorkspace",
                "description": "Create a new workspace (an isolated git worktree with its own agent) in one of the user's repositories. Runs without confirmation. Pass `prompt` to start its agent on a task immediately. Match the user's usual harness/model for this kind of work (check other workspaces and your memory); omit both to use ORE's defaults.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "repository": ["type": "string", "description": "Repository name or path. Optional when the user has exactly one."],
                        "name": ["type": "string", "description": "Workspace name. Omit for an auto-generated one."],
                        "prompt": ["type": "string", "description": "Initial task for the workspace's agent."],
                        "harness": ["type": "string", "description": "claude | codex | cursor — must be ready per ListHarnesses. Omit for the default."],
                        "model": ["type": "string", "description": "A model id from ListHarnesses for the chosen harness. Omit for its default."],
                    ],
                ],
            ],
            [
                "name": "CreateChat",
                "description": "Open a new chat tab in a workspace, optionally sending it a first prompt. Runs without confirmation. Use for work unrelated to any existing tab's conversation — continuing existing work belongs in its own tab via SendPromptToProject(chatID:). Give it a short, specific title.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "title": ["type": "string"],
                        "prompt": ["type": "string"],
                    ],
                    "required": ["workspaceID"],
                ],
            ],
            [
                "name": "SendPromptToProject",
                "description": "Send a prompt to a workspace's own agent — the main way to delegate work the user asked for. Queues automatically if that agent is mid-turn. Runs without confirmation. Write `text` as a full brief, not a relay of the user's words: goal in one line, concrete context you gathered (branch, recent turns, file/PR names), what done looks like — and quote the user's original phrasing at the end.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "text": ["type": "string", "description": "A complete brief for the project agent, richer than the user's spoken request but inventing nothing."],
                        "chatID": ["type": "string", "description": "The tab already carrying this work (find it via ListChats + GetTranscriptTail); omit only for the workspace's main chat."],
                        "effort": ["type": "string", "description": "Reasoning depth for this one turn: low | medium | high. Reserve high for genuinely hard work."],
                    ],
                    "required": ["workspaceID", "text"],
                ],
            ],
            [
                "name": "ListHarnesses",
                "description": "Which agent CLIs are installed, signed in, and what models each offers. Consult before choosing a harness/model for CreateWorkspace, or when a provider seems rate-limited or broken.",
                "inputSchema": ["type": "object", "properties": [:]],
            ],
            [
                "name": "OpenWorkspace",
                "description": "Bring a workspace (optionally a specific chat tab) to the front of the ORE window so the user can see it. Runs without confirmation.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "chatID": ["type": "string"],
                    ],
                    "required": ["workspaceID"],
                ],
            ],
            [
                "name": "Commit",
                "description": "Commit all changes in a workspace. The user confirms this the first time in a task; if they decline, stop and ask what they want instead.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "message": ["type": "string"],
                    ],
                    "required": ["workspaceID", "message"],
                ],
            ],
            [
                "name": "Push",
                "description": "Push a workspace's branch to origin. The user confirms this the first time in a task.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["workspaceID": ["type": "string"]],
                    "required": ["workspaceID"],
                ],
            ],
            [
                "name": "CreatePullRequest",
                "description": "Push and open a pull request for a workspace's branch. The user confirms this the first time in a task.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "title": ["type": "string"],
                        "body": ["type": "string"],
                        "draft": ["type": "boolean"],
                    ],
                    "required": ["workspaceID", "title"],
                ],
            ],
            [
                "name": "ArchiveWorkspace",
                "description": "Archive a workspace: stops its agent and frees the worktree from disk, preserving the branch and chats. The user confirms this.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["workspaceID": ["type": "string"]],
                    "required": ["workspaceID"],
                ],
            ],
        ]
    }

    func call(_ name: String, arguments: [String: Any]) async -> [String: Any] {
        // Actions cross into the app process, where policy is enforced and the
        // user can be asked; reads are answered right here from the database.
        if Self.actionToolNames.contains(name) {
            return callBridge(name, arguments: arguments)
        }
        let store: OreStore
        do {
            store = try openStore()
        } catch {
            return failure("The ORE database could not be opened read-only at \(databaseURL.path): \(error)")
        }
        do {
            let text = try await dispatch(name, arguments: arguments, store: store)
            return ["content": [["type": "text", "text": text]]]
        } catch {
            return failure("\(name) failed: \(error)")
        }
    }

    // MARK: - Action bridge client

    /// One request, one response, blocking. The response can take minutes —
    /// a confirmation may be sitting in front of the user — so the receive
    /// timeout outlasts the app's own 120s confirmation timeout.
    private func callBridge(_ tool: String, arguments: [String: Any]) -> [String: Any] {
        let socketPath = AssistantBridgeLocator.socketURL(forDatabase: databaseURL).path

        guard let argumentsData = try? JSONSerialization.data(withJSONObject: arguments),
              let argumentsValue = try? JSONDecoder().decode(JSONValue.self, from: argumentsData),
              let payload = try? JSONEncoder().encode(AssistantBridgeRequest(
                  id: UUID().uuidString.lowercased(), tool: tool, arguments: argumentsValue
              ))
        else {
            return failure("Could not encode the \(tool) request.")
        }

        guard let line = bridgeExchange(socketPath: socketPath, payload: payload) else {
            return failure(
                "The ORE app isn't reachable, so \(tool) can't run. "
                    + "Tell the user to open (or restart) ORE and try again."
            )
        }
        guard let response = try? JSONDecoder().decode(AssistantBridgeResponse.self, from: line)
        else {
            return failure("The ORE app sent a malformed response for \(tool).")
        }
        if response.ok {
            return ["content": [["type": "text", "text": response.result ?? "Done."]]]
        }
        return failure(response.error ?? "\(tool) failed.")
    }

    private func bridgeExchange(socketPath: String, payload: Data) -> Data? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let fits: Bool = socketPath.withCString { path in
            guard strlen(path) < capacity else { return false }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                _ = strcpy(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), path)
            }
            return true
        }
        guard fits else { return nil }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, size)
            }
        }
        guard connected == 0 else { return nil }

        // Outlast the app's confirmation timeout, then fail rather than hang
        // the agent's tool call forever.
        var timeout = timeval(tv_sec: 150, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var out = payload
        out.append(UInt8(ascii: "\n"))
        let written = out.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == out.count else { return nil }

        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(descriptor, &scratch, scratch.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: scratch[0..<count])
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                return Data(buffer[buffer.startIndex..<newline])
            }
        }
    }

    private func openStore() throws -> OreStore {
        if let store { return store }
        let opened = try OreStore(readOnlyPath: databaseURL)
        store = opened
        return opened
    }

    private func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private func dispatch(
        _ name: String, arguments: [String: Any], store: OreStore
    ) async throws -> String {
        switch name {
        case "ListWorkspaces":
            let includeArchived = arguments["includeArchived"] as? Bool ?? false
            let workspaces = try await store.workspaces(includeArchived: includeArchived)
            return json(workspaces.map { record in
                var entry: [String: Any] = [
                    "id": record.id,
                    "name": record.name,
                    "repositoryPath": record.repositoryPath,
                    "branch": record.branch,
                    "baseBranch": record.baseBranch,
                    "harness": record.harness,
                    "isArchived": record.isArchived,
                    "hasUnread": record.hasUnread,
                ]
                entry["model"] = record.model
                entry["lastActivityAt"] = record.lastActivityAt.map(iso)
                return entry
            })

        case "ListChats":
            let workspaceID = try requireWorkspaceID(arguments)
            let chats = try await store.chats(workspaceID: workspaceID)
            return json(chats.map { chat in
                var entry: [String: Any] = [
                    "id": chat.id,
                    "title": chat.title,
                    "harness": chat.harness,
                    "isClosed": chat.isClosed,
                    "hasUnread": chat.hasUnread,
                ]
                entry["model"] = chat.model
                entry["lastActivityAt"] = chat.lastActivityAt.map(iso)
                return entry
            })

        case "WorkspaceStatus":
            let workspaceID = try requireWorkspaceID(arguments)
            guard let record = try await store.workspace(workspaceID) else {
                return "No workspace with id \(workspaceID.rawValue). Use ListWorkspaces first."
            }
            var chats: [[String: Any]] = []
            for chat in try await store.chats(workspaceID: workspaceID) {
                var entry: [String: Any] = [
                    "id": chat.id,
                    "title": chat.title,
                    "isClosed": chat.isClosed,
                    "queuedMessages": try await store.queuedMessages(chatID: chat.chatID).count,
                ]
                if let last = try await store.turns(chatID: chat.chatID).last {
                    var turn: [String: Any] = ["startedAt": iso(last.startedAt)]
                    turn["prompt"] = last.prompt.map { String($0.prefix(300)) }
                    turn["outcome"] = last.outcome
                    turn["summary"] = last.summary
                    entry["lastTurn"] = turn
                }
                chats.append(entry)
            }
            var result: [String: Any] = [
                "id": record.id,
                "name": record.name,
                "repositoryPath": record.repositoryPath,
                "worktreePath": record.worktreePath,
                "branch": record.branch,
                "baseBranch": record.baseBranch,
                "harness": record.harness,
                "isArchived": record.isArchived,
                "chats": chats,
            ]
            result["model"] = record.model
            result["lastActivityAt"] = record.lastActivityAt.map(iso)
            return json(result)

        case "SearchTranscripts":
            guard let query = arguments["query"] as? String, !query.isEmpty else {
                return "SearchTranscripts needs a query."
            }
            let limit = integer(arguments["limit"]) ?? 20
            let hits = try await store.search(query, limit: max(1, min(limit, 50)))
            guard !hits.isEmpty else { return "No transcript matches for “\(query)”." }
            return json(hits.map { hit in
                [
                    "workspaceID": hit.workspaceID.rawValue,
                    "workspaceName": hit.workspaceName,
                    "snippet": hit.snippet,
                    "createdAt": iso(hit.createdAt),
                ] as [String: Any]
            })

        case "GetTranscriptTail":
            let workspaceID = try requireWorkspaceID(arguments)
            let chatID: ChatID
            if let raw = arguments["chatID"] as? String, !raw.isEmpty {
                chatID = ChatID(rawValue: raw)
            } else if let first = try await store.chats(workspaceID: workspaceID).first {
                chatID = first.chatID
            } else {
                return "That workspace has no chats yet."
            }
            return try await store.handoffContext(chatID: chatID)
                ?? "That chat has no turns yet."

        default:
            return "Unknown assistant tool: \(name)"
        }
    }

    private func requireWorkspaceID(_ arguments: [String: Any]) throws -> WorkspaceID {
        guard let raw = arguments["workspaceID"] as? String, !raw.isEmpty else {
            throw AssistantToolError.missingWorkspaceID
        }
        return WorkspaceID(rawValue: raw)
    }

    private func integer(_ value: Any?) -> Int? {
        (value as? Int) ?? (value as? Double).map(Int.init)
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                  withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
              )
        else { return String(describing: object) }
        return String(decoding: data, as: UTF8.self)
    }

    private enum AssistantToolError: Error, CustomStringConvertible {
        case missingWorkspaceID
        var description: String { "workspaceID is required — get one from ListWorkspaces." }
    }
}

private func writeMCP(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    // `fflush(nil)` rather than `fflush(stdout)`: glibc declares `stdout` as a
    // mutable global, which Swift 6 rejects as shared mutable state, so naming
    // it here broke the Linux build while compiling fine against Darwin. A null
    // argument flushes every open output stream, which for a CLI whose whole job
    // is writing framed JSON to stdout is the same thing.
    fflush(nil)
}
