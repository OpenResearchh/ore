import Foundation
import OreCore
import OreGit
import OrePersistence
import OreProtocol
import OreSupport

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
        databaseURL: options.databaseURL,
        homeURL: directory
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
            result = ["tools": annotateToolDefinitions(toolDefinitions() + assistant.toolDefinitions())]
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

/// MCP clients use tool annotations as approval hints. Without them, a client
/// has to treat a harmless review read the same as a workspace mutation and may
/// reject the call before it ever reaches this server.
private func annotateToolDefinitions(_ tools: [[String: Any]]) -> [[String: Any]] {
    tools.map { tool in
        guard let name = tool["name"] as? String else { return tool }
        var copy = tool
        copy["annotations"] = MCPToolAnnotation.forTool(named: name).json
        return copy
    }
}

private struct MCPToolAnnotation {
    let readOnly: Bool
    let destructive: Bool
    let idempotent: Bool
    let openWorld: Bool

    var json: [String: Any] {
        [
            "readOnlyHint": readOnly,
            "destructiveHint": destructive,
            "idempotentHint": idempotent,
            "openWorldHint": openWorld,
        ]
    }

    static func forTool(named name: String) -> Self {
        if localReadOnlyTools.contains(name)
            || AssistantToolServer.readOnlyToolNames.contains(name)
            || AssistantToolServer.readOnlyBridgeToolNames.contains(name) {
            return .readOnly
        }
        if nonDestructiveLocalWriteTools.contains(name) {
            return .localWrite
        }
        if destructiveTools.contains(name) {
            return .destructiveLocalWrite
        }
        if openWorldTools.contains(name) {
            return .openWorldAction
        }
        return .appAction
    }

    private static let localReadOnlyTools: Set<String> = [
        "GetWorkspaceDiff", "GetDiffComments",
    ]
    private static let nonDestructiveLocalWriteTools: Set<String> = [
        "PostDiffComment", "AskUserQuestion", "WriteMemory",
        "SetChatModel", "SwitchChatHarness", "SetChatPermissionMode", "SetChatEffort",
        "RenameChat", "ReopenChat", "OpenWorkspace", "AnswerChatQuestion",
        "SetComposerDraft", "TagComposerFile", "RenameWorkspace", "SetWorkspacePinned",
        "RestoreWorkspace", "AddDiffComment", "MarkFileViewed", "UpdateQueuedMessage",
    ]
    private static let destructiveTools: Set<String> = [
        "DeleteMemory", "CloseChat", "InterruptChatTurn", "Commit", "ArchiveWorkspace",
        "ResolveChatPermission", "UntagComposerFile", "ClearComposerTags", "DeleteWorkspace",
        "RevertChatToCheckpoint", "DeleteQueuedMessage", "MergePullRequest",
        "ContinueAfterMerge", "PullDefaultBranch", "ResolveConflict", "ResolveConflictHunk",
    ]
    private static let openWorldTools: Set<String> = [
        "CreateWorkspace", "CreateChat", "SendPromptToProject", "Push", "CreatePullRequest",
        "CreateGitHubRepository", "RetargetPullRequest", "RerunFailedChecks",
    ]

    private static let readOnly = Self(
        readOnly: true, destructive: false, idempotent: true, openWorld: false
    )
    private static let localWrite = Self(
        readOnly: false, destructive: false, idempotent: false, openWorld: false
    )
    private static let destructiveLocalWrite = Self(
        readOnly: false, destructive: true, idempotent: false, openWorld: false
    )
    private static let openWorldAction = Self(
        readOnly: false, destructive: false, idempotent: false, openWorld: true
    )
    private static let appAction = Self(
        readOnly: false, destructive: false, idempotent: false, openWorld: false
    )
}

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
    private let homeURL: URL
    private var store: OreStore?

    fileprivate static let readOnlyToolNames: Set<String> = [
        "ListWorkspaces", "ListChats", "ListChatCheckpoints", "WorkspaceStatus",
        "SearchTranscripts", "GetTranscriptTail",
        "ListMemory", "ReadMemory",
    ]
    private static let readWriteToolNames: Set<String> = [
        "WriteMemory", "DeleteMemory",
    ]
    private static let readToolNames: Set<String> = readOnlyToolNames.union(readWriteToolNames)
    private static let actionToolNames: Set<String> = [
        "CreateWorkspace", "CreateChat", "SendPromptToProject", "OpenWorkspace",
        "Commit", "Push", "CreatePullRequest", "ArchiveWorkspace", "ListHarnesses",
        "GetAppState", "RouteTask", "SetChatModel", "SwitchChatHarness", "SetChatPermissionMode",
        "SetChatEffort", "RenameChat", "CloseChat", "ReopenChat", "InterruptChatTurn",
        "ResolveChatPermission", "AnswerChatQuestion",
        "SetComposerDraft", "TagComposerFile", "UntagComposerFile", "ClearComposerTags",
        "OpenFile", "CloseFile", "RespondToPlan", "HandoffPlan",
        "RetryLastTurn", "AddRepository",
        "RenameWorkspace", "SetWorkspacePinned", "RestoreWorkspace", "DeleteWorkspace",
        "AddDiffComment", "MarkFileViewed", "RevertChatToCheckpoint",
        "UpdateQueuedMessage", "DeleteQueuedMessage",
        "CreateGitHubRepository", "RetargetPullRequest", "MergePullRequest",
        "ContinueAfterMerge", "PullDefaultBranch", "ResolveConflict",
        "ResolveConflictHunk", "RerunFailedChecks",
    ]
    fileprivate static let readOnlyBridgeToolNames: Set<String> = [
        "ListHarnesses", "GetAppState", "RouteTask",
    ]

    init(enabled: Bool, databaseURL: URL, homeURL: URL) {
        self.enabled = enabled
        self.databaseURL = databaseURL
        self.homeURL = homeURL
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
                "name": "ListChatCheckpoints",
                "description": "List the restorable turn checkpoints for one chat, newest first. Use the returned turnID with RevertChatToCheckpoint.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "chatID": ["type": "string"],
                    ],
                    "required": ["workspaceID", "chatID"],
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
                "description": "Full-text search across chat transcripts, newest first. Use to answer 'where was I doing X', to resolve vague project references, and to find the exact tab a piece of work already lives in — every hit carries its chatID, so the follow-up can go to the conversation that already has the context. Hits mark closed tabs (`isClosed`); do not SendPromptToProject to those — ReopenChat or CreateChat instead.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "scope": [
                            "type": "string",
                            "enum": ["projects", "assistant", "all"],
                            "description": "Which conversations to search. `projects` (default) is the user's project tabs. `assistant` is your own past conversations with the user — use it when they refer back to something the two of you discussed and your memory files don't cover it. `all` is both.",
                        ],
                        "workspaceID": ["type": "string", "description": "Restrict to one workspace. Omit to search every one in scope."],
                        "limit": ["type": "integer", "description": "Max hits, default 20."],
                    ],
                    "required": ["query"],
                ],
            ],
            [
                "name": "GetTranscriptTail",
                "description": "The recent conversation of one chat: prior turn summaries plus the last few prompts and replies. Always pass chatID when you have it — omitting it reads the oldest tab, not the focused one. Closed tabs are labelled so you reopen or start fresh instead of sending more work into them.",
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
                "name": "ListMemory",
                "description": "List your memory files (MEMORY.md index and memory/*.md). Call this or ReadMemory rather than guessing paths.",
                "inputSchema": ["type": "object", "properties": [:]],
            ],
            [
                "name": "ReadMemory",
                "description": "Read one memory file. Path must be MEMORY.md or memory/<file>.md.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["path": ["type": "string"]],
                    "required": ["path"],
                ],
            ],
            [
                "name": "WriteMemory",
                "description": "Write a memory file (replace or append) and keep MEMORY.md's index current. Path must be MEMORY.md or memory/<file>.md. Use this the same turn the user states a durable fact.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "contents": ["type": "string"],
                        "mode": ["type": "string", "description": "replace (default) or append"],
                    ],
                    "required": ["path", "contents"],
                ],
            ],
            [
                "name": "DeleteMemory",
                "description": "Retire a memory topic that no longer applies, and drop its line from MEMORY.md. Path must be memory/<file>.md — the index itself cannot be deleted. Prefer rewriting a file with WriteMemory when only some of it went stale.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["path": ["type": "string"]],
                    "required": ["path"],
                ],
            ],
            [
                "name": "CreateWorkspace",
                "description": "Create a new workspace (an isolated git worktree with its own agent) in one of the user's repositories. If that repository already has a project worktree and you omit seed (or pass seed=default), ORE reuses the existing worktree instead of forking — a restarted session is not a new project. Pass seed=branch, seed=pr, or seed=issue when the user asked for isolation or a new worktree. Forking beside a dirty sibling asks the user first. Pass `prompt` to start its agent on a task immediately. Match the user's usual harness/model for this kind of work (check other workspaces and your memory); omit both to use ORE's defaults. Use this for a new branch/worktree, not for a new tab on an existing worktree (that is CreateChat).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "repository": ["type": "string", "description": "Repository name or path. Optional when the user has exactly one."],
                        "name": ["type": "string", "description": "Workspace name. Omit for an auto-generated one."],
                        "prompt": ["type": "string", "description": "Initial task for the workspace's agent."],
                        "harness": ["type": "string", "description": "claude | codex | cursor — must be ready per ListHarnesses. Omit for the default."],
                        "model": ["type": "string", "description": "A model id from ListHarnesses for the chosen harness. Omit for its default."],
                        "seed": ["type": "string", "description": "default | branch | workspace | issue | pr. Omit for the default branch."],
                        "seedRef": ["type": "string", "description": "Branch name, parent workspace id, or GitHub issue/PR number — required for non-default seeds."],
                        "branchPrefix": ["type": "string"],
                    ],
                ],
            ],
            [
                "name": "CreateChat",
                "description": "Open a new chat tab in a workspace, optionally sending it a first prompt. Runs without confirmation. Use for work that belongs on this worktree but is unrelated to any existing tab's conversation. Continuing existing work belongs in its own tab via SendPromptToProject(chatID:). Give it a short, specific title. Do not use this for a new git worktree — that is CreateWorkspace.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "title": ["type": "string"],
                        "prompt": ["type": "string"],
                        "harness": ["type": "string"],
                        "model": ["type": "string"],
                        "permissionMode": ["type": "string", "description": "default | acceptEdits | plan | bypassPermissions"],
                        "forkFrom": ["type": "string", "description": "Chat id to fork from."],
                        "effort": ["type": "string", "description": "none | low | medium | high | xhigh | max | adaptive"],
                    ],
                    "required": ["workspaceID"],
                ],
            ],
            [
                "name": "SendPromptToProject",
                "description": "Send a prompt to a workspace's own agent — the main way to delegate work the user asked for. Queues automatically if that agent is mid-turn. Runs without confirmation. Write `text` as a full brief, not a relay of the user's words: goal in one line, concrete context you gathered (branch, recent turns, file/PR names), what done looks like — and quote the user's original phrasing at the end. Pass chatID whenever the workspace has more than one open tab; omitting it is refused rather than guessed.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "text": ["type": "string", "description": "A complete brief for the project agent, richer than the user's spoken request but inventing nothing."],
                        "chatID": ["type": "string", "description": "The tab already carrying this work (find it via ListChats + GetTranscriptTail). Required when the workspace has more than one open tab; omit only if it has a single open chat."],
                        "effort": ["type": "string", "description": "Reasoning depth for this one turn: none | low | medium | high | xhigh | max | adaptive."],
                        "serviceTier": ["type": "string", "description": "Optional processing tier, e.g. fast for Codex."],
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
                "name": "GetAppState",
                "description": "Live app state: focused workspace and tab, open tabs with harness/model/mode/effort/status, git dirt, and anything waiting on the user. Prefer the hidden snapshot on each turn; call this to refresh.",
                "inputSchema": ["type": "object", "properties": [:]],
            ],
            [
                "name": "RouteTask",
                "description": "Recommend where a user request should land before you CreateChat, CreateWorkspace, or SendPromptToProject. Pass the user's request as `utterance`. Returns action (sendExistingTab | createChat | createWorkspace | assistantChat | clarify), optional workspaceID/chatID, confidence, a short reason, and a single `question` when two destinations still fit. Follow high-confidence results; ask the question instead of guessing.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "utterance": ["type": "string", "description": "The user's request, in their words."],
                    ],
                    "required": ["utterance"],
                ],
            ],
            [
                "name": "SetChatModel",
                "description": "Change the model on a chat tab. Runs without confirmation.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "chatID": ["type": "string"],
                        "model": ["type": "string"],
                    ],
                    "required": ["workspaceID", "chatID"],
                ],
            ],
            [
                "name": "SwitchChatHarness",
                "description": "Switch a chat tab to a different agent CLI (and optional model). Runs without confirmation.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "chatID": ["type": "string"],
                        "harness": ["type": "string"],
                        "model": ["type": "string"],
                    ],
                    "required": ["workspaceID", "chatID", "harness"],
                ],
            ],
            [
                "name": "SetChatPermissionMode",
                "description": "Set a tab's permission mode: default (Ask), acceptEdits, plan, or bypassPermissions (auto-allow everything). Bypass is confirmed with the user.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "chatID": ["type": "string"],
                        "mode": ["type": "string"],
                    ],
                    "required": ["workspaceID", "chatID", "mode"],
                ],
            ],
            [
                "name": "SetChatEffort",
                "description": "Persist the reasoning-effort chip for a tab so later sends use it. Runs without confirmation.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "chatID": ["type": "string"],
                        "effort": ["type": "string"],
                    ],
                    "required": ["workspaceID", "chatID"],
                ],
            ],
            [
                "name": "RenameChat",
                "description": "Rename a chat tab. Runs without confirmation.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "chatID": ["type": "string"],
                        "title": ["type": "string"],
                    ],
                    "required": ["workspaceID", "chatID", "title"],
                ],
            ],
            [
                "name": "CloseChat",
                "description": "Close a chat tab (reopenable). Runs without confirmation.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "chatID": ["type": "string"],
                    ],
                    "required": ["workspaceID", "chatID"],
                ],
            ],
            [
                "name": "ReopenChat",
                "description": "Reopen a closed chat tab. Runs without confirmation.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "chatID": ["type": "string"],
                    ],
                    "required": ["workspaceID", "chatID"],
                ],
            ],
            [
                "name": "InterruptChatTurn",
                "description": "Stop the in-flight turn on a tab. Runs without confirmation.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "chatID": ["type": "string"],
                    ],
                    "required": ["workspaceID", "chatID"],
                ],
            ],
            [
                "name": "ResolveChatPermission",
                "description": "Allow or deny a project tab's pending tool permission. Confirmed unless the tab already has auto-allow. Pass allow=true/false.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "chatID": ["type": "string"],
                        "permissionID": ["type": "string"],
                        "allow": ["type": "boolean"],
                        "reason": ["type": "string"],
                    ],
                    "required": ["workspaceID", "chatID", "permissionID"],
                ],
            ],
            [
                "name": "AnswerChatQuestion",
                "description": "Answer a project tab's pending question. Runs without confirmation — only use when the user told you the answer.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "chatID": ["type": "string"],
                        "questionID": ["type": "string"],
                        "answer": ["type": "string"],
                    ],
                    "required": ["workspaceID", "chatID", "questionID", "answer"],
                ],
            ],
            [
                "name": "SetComposerDraft",
                "description": "Stage text in a chat tab's composer without sending it — the same box the user types into. The tab is brought to the front and focused so they can edit and press send. Replaces the current draft unless append=true. This does not send anything: use SendPromptToProject to actually hand work to the agent. Runs without confirmation.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "chatID": ["type": "string"],
                        "text": ["type": "string"],
                        "append": ["type": "boolean", "description": "Add to the existing draft instead of replacing it. Default false."],
                    ],
                    "required": ["workspaceID", "chatID", "text"],
                ],
            ],
            [
                "name": "TagComposerFile",
                "description": "Tag a workspace file onto a chat tab's composer — the same as the user typing @file or attaching one. The file must exist in that workspace's worktree; pass `path` relative to the worktree root (e.g. \"src/main.swift\"). It appears as a chip above the composer and travels with the next message. Runs without confirmation.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "chatID": ["type": "string"],
                        "path": ["type": "string", "description": "Workspace-relative path of the file to tag."],
                    ],
                    "required": ["workspaceID", "chatID", "path"],
                ],
            ],
            [
                "name": "UntagComposerFile",
                "description": "Remove one tagged file from a chat tab's composer, matched by its path or display name. No-ops if that file isn't tagged. Runs without confirmation.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "chatID": ["type": "string"],
                        "path": ["type": "string", "description": "Path or name of the tagged file to remove."],
                    ],
                    "required": ["workspaceID", "chatID", "path"],
                ],
            ],
            [
                "name": "ClearComposerTags",
                "description": "Remove every tagged file from a chat tab's composer at once — the whole shelf of chips. Files ORE copied in (pasted images, dropped files) are deleted from the worktree; plain references are just dropped. Pass clearDraft=true to also empty the draft text. Runs without confirmation.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "workspaceID": ["type": "string"],
                        "chatID": ["type": "string"],
                        "clearDraft": ["type": "boolean", "description": "Also clear the composer's draft text. Default false."],
                    ],
                    "required": ["workspaceID", "chatID"],
                ],
            ],
            [
                "name": "OpenFile",
                "description": "Open a workspace file as a centre-column tab, the same as clicking it in the Review pane. mode is diff, source, or preview (markdown). Pass line to jump to that line in source. Runs without confirmation.",
                "inputSchema": objectSchema([
                    "workspaceID": stringProperty(),
                    "path": stringProperty("Workspace-relative path of the file to open."),
                    "mode": ["type": "string", "enum": ["diff", "source", "preview"]],
                    "line": ["type": "integer", "description": "1-based line to reveal in source."],
                ], required: ["workspaceID", "path"]),
            ],
            [
                "name": "CloseFile",
                "description": "Close a centre-column file tab. No-ops if that file is not open. Runs without confirmation.",
                "inputSchema": objectSchema([
                    "workspaceID": stringProperty(),
                    "path": stringProperty(),
                ], required: ["workspaceID", "path"]),
            ],
            [
                "name": "RespondToPlan",
                "description": "Approve or reject a project tab's pending plan — the same Approve / Reject buttons on the plan card. Only use when the user told you the decision. Optional feedback is included with the decision, including any review comments already on the diff. Runs without confirmation.",
                "inputSchema": objectSchema([
                    "workspaceID": stringProperty(),
                    "chatID": stringProperty(),
                    "approve": ["type": "boolean"],
                    "feedback": stringProperty("Optional notes to send with the decision."),
                ], required: ["workspaceID", "chatID", "approve"]),
            ],
            [
                "name": "HandoffPlan",
                "description": "Copy a pending plan into a new tab's composer, unsent, so the user can pick a different harness or edit before sending. The source tab keeps its plan card. Runs without confirmation.",
                "inputSchema": objectSchema([
                    "workspaceID": stringProperty(),
                    "chatID": stringProperty(),
                ], required: ["workspaceID", "chatID"]),
            ],
            [
                "name": "RetryLastTurn",
                "description": "Resend the last user prompt on a tab — the same Retry button after a failed or interrupted turn. Runs without confirmation.",
                "inputSchema": objectSchema([
                    "workspaceID": stringProperty(),
                    "chatID": stringProperty(),
                ], required: ["workspaceID", "chatID"]),
            ],
            [
                "name": "AddRepository",
                "description": "Register a local git repository with ORE so workspaces can be created in it. Path must be the repository root (or inside it). Runs without confirmation.",
                "inputSchema": objectSchema([
                    "path": stringProperty("Local filesystem path of the git repository."),
                ], required: ["path"]),
            ],
            [
                "name": "RenameWorkspace",
                "description": "Rename a workspace, exactly like editing its name in the sidebar. Runs without confirmation.",
                "inputSchema": objectSchema(
                    ["workspaceID": stringProperty(), "name": stringProperty()],
                    required: ["workspaceID", "name"]
                ),
            ],
            [
                "name": "SetWorkspacePinned",
                "description": "Pin or unpin a workspace in the sidebar. Runs without confirmation.",
                "inputSchema": objectSchema(
                    ["workspaceID": stringProperty(), "pinned": ["type": "boolean"]],
                    required: ["workspaceID", "pinned"]
                ),
            ],
            [
                "name": "RestoreWorkspace",
                "description": "Restore an archived workspace and its preserved working state. Runs without confirmation because archiving remains available as its inverse.",
                "inputSchema": workspaceSchema(),
            ],
            [
                "name": "DeleteWorkspace",
                "description": "Permanently delete an archived workspace. The workspace must already be archived. Its branch is preserved unless deleteBranch=true. Always requires the user's consequential-action confirmation.",
                "inputSchema": objectSchema([
                    "workspaceID": stringProperty(),
                    "deleteBranch": ["type": "boolean", "description": "Also delete the git branch. Default false."],
                ], required: ["workspaceID"]),
            ],
            [
                "name": "AddDiffComment",
                "description": "Add a review comment anchored to a workspace diff. It will travel with the next prompt just like a comment created in the Review pane. Runs without confirmation.",
                "inputSchema": objectSchema([
                    "workspaceID": stringProperty(), "path": stringProperty(),
                    "startLine": ["type": "integer"], "endLine": ["type": "integer"],
                    "body": stringProperty(), "context": stringProperty(),
                ], required: ["workspaceID", "path", "startLine", "body"]),
            ],
            [
                "name": "MarkFileViewed",
                "description": "Mark a changed file viewed at a particular content hash, or unview it with viewed=false. Runs without confirmation.",
                "inputSchema": objectSchema([
                    "workspaceID": stringProperty(), "path": stringProperty(),
                    "viewed": ["type": "boolean"],
                    "contentHash": ["type": "string", "description": "Required when viewed=true; use the hash reported by the diff surface."],
                ], required: ["workspaceID", "path"]),
            ],
            [
                "name": "RevertChatToCheckpoint",
                "description": "Restore both the working tree and one chat's transcript to the state before a turn. Use a checkpoint-capable turnID from WorkspaceStatus. Requires confirmation because later files and conversation are removed from the active branch.",
                "inputSchema": objectSchema([
                    "workspaceID": stringProperty(), "chatID": stringProperty(),
                    "turnID": stringProperty(),
                ], required: ["workspaceID", "chatID", "turnID"]),
            ],
            [
                "name": "UpdateQueuedMessage",
                "description": "Edit a prompt waiting behind a running turn. Use queuedMessageID from WorkspaceStatus. Runs without confirmation.",
                "inputSchema": queuedMessageSchema(includingText: true),
            ],
            [
                "name": "DeleteQueuedMessage",
                "description": "Remove a prompt waiting behind a running turn before it is sent. Use queuedMessageID from WorkspaceStatus. Runs without an extra confirmation because the prompt has not executed and can be re-created.",
                "inputSchema": queuedMessageSchema(includingText: false),
            ],
            [
                "name": "CreateGitHubRepository",
                "description": "Create and publish a GitHub repository for a local-only project. Requires confirmation because it creates remote state.",
                "inputSchema": workspaceSchema(),
            ],
            [
                "name": "RetargetPullRequest",
                "description": "Change an open pull request's base branch. Requires confirmation because it mutates remote review state.",
                "inputSchema": objectSchema([
                    "workspaceID": stringProperty(), "number": ["type": "integer"],
                    "base": stringProperty(),
                ], required: ["workspaceID", "number", "base"]),
            ],
            [
                "name": "MergePullRequest",
                "description": "Merge the workspace's open pull request with merge, squash, or rebase. Requires confirmation.",
                "inputSchema": objectSchema([
                    "workspaceID": stringProperty(),
                    "method": ["type": "string", "enum": ["merge", "squash", "rebase"]],
                ], required: ["workspaceID"]),
            ],
            [
                "name": "ContinueAfterMerge",
                "description": "After a PR merges, update the default branch and restart this worktree on a fresh branch. Requires confirmation because it changes git history and the checked-out branch.",
                "inputSchema": workspaceSchema(),
            ],
            [
                "name": "PullDefaultBranch",
                "description": "Fast-forward the repository's local default branch from origin without switching the worktree onto it. Requires confirmation.",
                "inputSchema": workspaceSchema(),
            ],
            [
                "name": "ResolveConflict",
                "description": "Resolve and stage an entire conflicted file by accepting ours or theirs. Requires confirmation because it replaces file contents.",
                "inputSchema": conflictSchema(hunk: false),
            ],
            [
                "name": "ResolveConflictHunk",
                "description": "Resolve one conflict hunk by accepting ours or theirs. Requires confirmation because it replaces file contents.",
                "inputSchema": conflictSchema(hunk: true),
            ],
            [
                "name": "RerunFailedChecks",
                "description": "Rerun the latest failed GitHub workflow checks for the workspace branch. Requires confirmation because it starts remote jobs.",
                "inputSchema": workspaceSchema(),
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
                        "base": ["type": "string", "description": "Base branch. Omit for the workspace default."],
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

    private func stringProperty(_ description: String? = nil) -> [String: Any] {
        var property: [String: Any] = ["type": "string"]
        property["description"] = description
        return property
    }

    private func objectSchema(
        _ properties: [String: [String: Any]], required: [String]
    ) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    private func workspaceSchema() -> [String: Any] {
        objectSchema(["workspaceID": stringProperty()], required: ["workspaceID"])
    }

    private func queuedMessageSchema(includingText: Bool) -> [String: Any] {
        var properties: [String: [String: Any]] = [
            "workspaceID": stringProperty(),
            "chatID": stringProperty(),
            "queuedMessageID": ["type": "integer"],
        ]
        var required = ["workspaceID", "chatID", "queuedMessageID"]
        if includingText {
            properties["text"] = stringProperty()
            required.append("text")
        }
        return objectSchema(properties, required: required)
    }

    private func conflictSchema(hunk: Bool) -> [String: Any] {
        var properties: [String: [String: Any]] = [
            "workspaceID": stringProperty(),
            "path": stringProperty(),
            "side": ["type": "string", "enum": ["ours", "theirs"]],
        ]
        var required = ["workspaceID", "path", "side"]
        if hunk {
            properties["startLine"] = ["type": "integer"]
            required.append("startLine")
        }
        return objectSchema(properties, required: required)
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
        let descriptor = UnixStreamSocket.open()
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
                    "isPinned": record.isPinned,
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
                entry["permissionMode"] = chat.permissionMode
                entry["reasoningEffort"] = chat.reasoningEffort
                entry["lastActivityAt"] = chat.lastActivityAt.map(iso)
                return entry
            })

        case "ListChatCheckpoints":
            let workspaceID = try requireWorkspaceID(arguments)
            guard let rawChatID = arguments["chatID"] as? String, !rawChatID.isEmpty else {
                return "ListChatCheckpoints needs chatID."
            }
            let chatID = ChatID(rawValue: rawChatID)
            guard let chat = try await store.chat(chatID),
                  chat.workspaceID == workspaceID.rawValue
            else { return "That chat does not belong to the requested workspace." }
            return json(try await store.turns(chatID: chatID).reversed().compactMap {
                turn -> [String: Any]? in
                guard turn.checkpointCommit != nil else { return nil }
                var entry: [String: Any] = [
                    "turnID": turn.id,
                    "ordinal": turn.ordinal,
                    "startedAt": iso(turn.startedAt),
                ]
                entry["prompt"] = turn.prompt.map { String($0.prefix(300)) }
                entry["summary"] = turn.summary
                return entry
            })

        case "WorkspaceStatus":
            let workspaceID = try requireWorkspaceID(arguments)
            guard let record = try await store.workspace(workspaceID) else {
                return "No workspace with id \(workspaceID.rawValue). Use ListWorkspaces first."
            }
            var chats: [[String: Any]] = []
            for chat in try await store.chats(workspaceID: workspaceID) {
                let queued = try await store.queuedMessages(chatID: chat.chatID)
                var entry: [String: Any] = [
                    "id": chat.id,
                    "title": chat.title,
                    "isClosed": chat.isClosed,
                    "queuedMessages": queued.compactMap { message -> [String: Any]? in
                        guard let id = message.id else { return nil }
                        return [
                            "id": id,
                            "text": message.text,
                            "createdAt": iso(message.createdAt),
                        ]
                    },
                ]
                if let last = try await store.turns(chatID: chat.chatID).last {
                    var turn: [String: Any] = [
                        "id": last.id,
                        "startedAt": iso(last.startedAt),
                        "hasCheckpoint": last.checkpointCommit != nil,
                    ]
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
            let rawScope = (arguments["scope"] as? String) ?? OreStore.SearchScope.projects.rawValue
            guard let scope = OreStore.SearchScope(rawValue: rawScope) else {
                return "scope must be projects, assistant, or all."
            }
            let scopedWorkspace = (arguments["workspaceID"] as? String)
                .flatMap { $0.isEmpty ? nil : WorkspaceID(rawValue: $0) }
            let hits = try await store.search(
                query, scope: scope, workspaceID: scopedWorkspace, limit: max(1, min(limit, 50))
            )
            guard !hits.isEmpty else {
                return "No transcript matches for “\(query)”"
                    + (scope == .projects ? " in the user's projects." : " in scope \(rawScope).")
            }
            return json(hits.map { hit in
                var entry: [String: Any] = [
                    "workspaceID": hit.workspaceID.rawValue,
                    "workspaceName": hit.workspaceName,
                    "snippet": hit.snippet,
                    "createdAt": iso(hit.createdAt),
                    "isClosed": hit.isClosed,
                ]
                // The tab, so a follow-up can be sent where the context already
                // is instead of opening a fresh one beside it.
                entry["chatID"] = hit.chatID?.rawValue
                entry["chatTitle"] = hit.chatTitle
                return entry
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
            let closedNote: String
            if let chat = try await store.chat(chatID), chat.isClosed {
                closedNote = "This tab is closed. ReopenChat if the conversation is still the right one, or CreateChat for a fresh one — do not SendPromptToProject here.\n\n"
            } else {
                closedNote = ""
            }
            let tail = try await store.handoffContext(chatID: chatID)
                ?? "That chat has no turns yet."
            return closedNote + tail

        case "ListMemory":
            return AssistantMemory.listingText(home: homeURL)

        case "ReadMemory":
            guard let path = arguments["path"] as? String, !path.isEmpty else {
                return "ReadMemory needs a path (MEMORY.md or memory/<file>.md)."
            }
            return try AssistantMemory.read(home: homeURL, path: path)

        case "WriteMemory":
            guard let path = arguments["path"] as? String, !path.isEmpty else {
                return "WriteMemory needs a path."
            }
            guard let contents = arguments["contents"] as? String else {
                return "WriteMemory needs contents."
            }
            let append = (arguments["mode"] as? String)?.lowercased() == "append"
            try AssistantMemory.write(home: homeURL, path: path, contents: contents, append: append)
            return append ? "Appended \(path)." : "Wrote \(path)."

        case "DeleteMemory":
            guard let path = arguments["path"] as? String, !path.isEmpty else {
                return "DeleteMemory needs a path (memory/<file>.md)."
            }
            try AssistantMemory.delete(home: homeURL, path: path)
            return "Deleted \(path) and removed it from MEMORY.md."

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
