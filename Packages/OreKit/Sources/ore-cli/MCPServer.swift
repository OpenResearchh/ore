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
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    } catch {
        return "Unable to read workspace diff: \(error)"
    }
}

private func writeMCP(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}
