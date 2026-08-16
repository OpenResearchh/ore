import Foundation

/// Minimal MCP stdio server used by both Claude Code and Codex. Keeping this in
/// the headless executable means agents receive review context as tools without
/// the Mac UI needing to be alive or reachable over a private socket.
func runMCPServer(options: CommandLineOptions) {
    let directory = options.workingDirectory
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
            result = ["tools": toolDefinitions()]
        case "tools/call":
            let params = request["params"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            let arguments = params?["arguments"] as? [String: Any] ?? [:]
            result = callORETool(name, arguments: arguments, directory: directory)
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
        "description": "Read the current git diff for this ORE workspace.",
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
) -> [String: Any] {
    let text: String
    switch name {
    case "GetWorkspaceDiff":
        text = runGitDiff(in: directory)
    case "GetDiffComments":
        let url = directory.appendingPathComponent(".context/ore-diff-comments.json")
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? "[]"
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

    let contextDirectory = directory.appendingPathComponent(".context", isDirectory: true)
    try? FileManager.default.createDirectory(
        at: contextDirectory, withIntermediateDirectories: true
    )
    let url = contextDirectory.appendingPathComponent("ore-diff-comments.json")
    var comments: [[String: Any]] = []
    if let data = try? Data(contentsOf: url),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        comments = existing
    }
    var entry: [String: Any] = [
        "filePath": filePath,
        "startLine": startLine,
        "endLine": endLine,
        "body": body,
    ]
    if let context, !context.isEmpty { entry["context"] = context }
    comments.append(entry)
    if let data = try? JSONSerialization.data(withJSONObject: comments, options: [.prettyPrinted]) {
        try? data.write(to: url, options: .atomic)
    }
    return "Recorded finding #\(comments.count) on \(filePath):\(startLine)-\(endLine)."
}

private func runGitDiff(in directory: URL) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["diff", "--no-ext-diff", "HEAD", "--"]
    process.currentDirectoryURL = directory
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        // Drain the pipe *before* waiting for exit. A large diff overflows the
        // 64KB pipe buffer; git then blocks on write while we block on
        // `waitUntilExit()`, and neither side ever advances — the review agent
        // hangs on this tool call. Reading to EOF first lets git finish writing.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    } catch {
        return "Unable to read workspace diff: \(error)"
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
