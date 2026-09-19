import Foundation
import OreCore
import OreGit
import OrePersistence
import OreHarness
import OreProtocol
import OreSupport

// ore-cli is the test rig for OreKit: it exercises the whole headless core from
// a terminal, with no Mac app in the picture. Every harness capability the app
// will use has to be reachable here first — that is the M0 exit criterion, and
// afterwards it stays the fastest way to reproduce a harness bug.

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"
let options = CommandLineOptions(arguments: Array(arguments.dropFirst()))

switch command {
case "mcp-server":
    await runMCPServer(options: options)
case "doctor":
    await runDoctor()
case "chat":
    await runChat(options: options)
case "record":
    await runRecord(options: options)
case "replay":
    runReplay(options: options)
case "repos", "add-repo", "new-project", "delete-project", "workspaces", "new", "say", "diff", "git-action",
     "archive", "delete", "search", "turns", "revert":
    await runWorkspaceCommand(command, options: options)
default:
    printUsage()
    if command != "help" && command != "--help" && command != "-h" {
        exit(1)
    }
}

func printUsage() {
    print("""
    ore-cli — OreKit test rig

    USAGE
      ore-cli doctor
          Check which agent CLIs are installed, their versions, and login state.

      ore-cli mcp-server --dir <workspace>
          Serve ORE review tools over MCP stdio (normally launched by an agent CLI).

      ore-cli chat [--dir <path>] [--harness claude|codex] [--model <name>]
                   [--permission-mode default|acceptEdits|plan|bypassPermissions]
                   [--prompt <text>] [--raw]
                   [--resume <session-id> | --fork <session-id>]
          Interactive session. --fork resumes into a new session id, leaving
          the original intact; that is the chat half of a checkpoint revert.
          While chatting:
            /interrupt        cancel the running turn
            /mode <mode>      switch permission mode
            /allow, /deny     answer a pending permission request
            /quit             end the session

      ore-cli record --out <file.jsonl> [--dir <path>] --prompt <text> [--model <name>]
          Capture the CLI's raw stdout as a golden transcript fixture.

      ore-cli replay <file.jsonl>
          Run a recorded transcript through the translator and print the
          normalized events. No network, no CLI — this is what CI runs.

    WORKSPACES  (drives the whole core, exactly as the Mac app does)
      ore-cli add-repo <path>
      ore-cli repos
      ore-cli new-project <name> [--parent <dir>] [--no-workspace]
                  [--harness claude|codex] [--model <id>] [--prompt <text>]
          Create an empty local repository for a project that doesn't exist
          yet, register it, and open its first workspace.
      ore-cli delete-project <repository-path> [--keep-files]
          Stop and remove every workspace in a project and forget it. The
          worktrees and repository folder go to the Trash unless --keep-files.
      ore-cli new --repo <path> --name <name> [--harness claude|codex]
                  [--branch <name> | --stack-on <workspace-id> | --issue <n>]
                  [--model <name>] [--prompt <text>]
      ore-cli workspaces
      ore-cli say --workspace <id> --text <message> [--auto-allow] [--timeout <seconds>]
      ore-cli diff --workspace <id> [--full]
      ore-cli git-action --workspace <id>
      ore-cli turns --workspace <id>
      ore-cli revert --workspace <id> --turn <turn-id>
      ore-cli archive --workspace <id>
      ore-cli delete --workspace <id> [--delete-branch]
      ore-cli search <query>

      State lives in ~/ore/ore.sqlite unless --db is given; worktrees go under
      ~/ore/workspaces unless --worktree-root is.
    """)
}

// MARK: - doctor

func runDoctor() async {
    print("PATH: \(ShellEnvironment.searchPathDescription)\n")

    let registry = HarnessRegistry.standard()
    for harness in registry.available {
        let result = await harness.probe()
        let mark = result.isReady ? "✓" : (result.isInstalled ? "!" : "✗")
        print("\(mark) \(result.kind.displayName)")
        print("    path:    \(result.executablePath ?? "not found")")
        print("    version: \(result.version ?? "unknown")")
        print("    auth:    \(result.authState.rawValue)")
        if let diagnostic = result.diagnostic {
            print("    note:    \(diagnostic)")
        }
        let capabilities = harness.capabilities
        print("    caps:    plan=\(capabilities.supportsPlanMode) "
            + "steer=\(capabilities.supportsSteering) "
            + "fork=\(capabilities.supportsSessionFork) "
            + "permissions=\(capabilities.permissionModel.rawValue)")
    }
}

// MARK: - chat

func runChat(options: CommandLineOptions) async {
    let directory = options.workingDirectory
    guard FileManager.default.fileExists(atPath: directory.path) else {
        FileHandle.standardError.write(Data("No such directory: \(directory.path)\n".utf8))
        exit(1)
    }

    let registry = HarnessRegistry.standard()
    guard let harness = registry.harness(for: options.harnessKind) else {
        FileHandle.standardError.write(Data("unknown harness: \(options.harnessKind.rawValue)\n".utf8))
        exit(1)
    }
    let session: any AgentSession
    do {
        session = try await harness.makeSession(SessionConfiguration(
            workingDirectory: directory,
            model: options.value(for: "--model"),
            permissionMode: options.permissionMode,
            resume: options.resumeMode
        ))
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }

    print("· starting \(harness.kind.displayName) in \(directory.path)")
    let printer = EventPrinter(showRaw: options.flag("--raw"))

    // Iterate before start() so the first events cannot be missed.
    let renderTask = Task {
        for await event in session.events {
            await printer.render(event)
        }
    }

    do {
        try await session.start()
    } catch {
        FileHandle.standardError.write(Data("failed to start: \(error)\n".utf8))
        exit(1)
    }

    if let prompt = options.value(for: "--prompt") {
        print("› \(prompt)")
        try? await session.send(UserMessage(text: prompt))
    }

    for await line in StandardInput.lines() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "":
            continue
        case "/quit", "/exit":
            await session.stop()
            renderTask.cancel()
            return
        case "/interrupt":
            do { try await session.interrupt() } catch { print("· interrupt failed: \(error)") }
        case "/allow":
            await answerPending(session: session, printer: printer, decision: .allow)
        case "/deny":
            await answerPending(
                session: session, printer: printer,
                decision: .deny(reason: "Denied by the user in ore-cli")
            )
        default:
            if trimmed.hasPrefix("/mode ") {
                let raw = String(trimmed.dropFirst("/mode ".count))
                guard let mode = PermissionMode(rawValue: raw) else {
                    print("· unknown mode: \(raw)")
                    continue
                }
                do {
                    try await session.setPermissionMode(mode)
                    print("· permission mode → \(mode.rawValue)")
                } catch {
                    print("· mode change failed: \(error)")
                }
            } else {
                do {
                    try await session.send(UserMessage(text: trimmed))
                } catch {
                    print("· send failed: \(error)")
                }
            }
        }
    }

    await session.stop()
    renderTask.cancel()
}

func answerPending(
    session: any AgentSession,
    printer: EventPrinter,
    decision: PermissionDecision
) async {
    guard let pending = await printer.takePendingPermission() else {
        print("· no permission request is pending")
        return
    }
    do {
        try await session.resolvePermission(pending, with: decision)
    } catch {
        print("· could not answer permission: \(error)")
    }
}

// MARK: - record / replay

func runRecord(options: CommandLineOptions) async {
    guard let outputPath = options.value(for: "--out"),
          let prompt = options.value(for: "--prompt")
    else {
        FileHandle.standardError.write(Data("record requires --out and --prompt\n".utf8))
        exit(1)
    }

    let directory = options.workingDirectory
    guard let executablePath = ShellEnvironment.locate("claude") else {
        FileHandle.standardError.write(Data("claude CLI not found on PATH\n".utf8))
        exit(1)
    }

    var launchArguments = [
        "-p",
        "--output-format", "stream-json",
        "--input-format", "stream-json",
        "--include-partial-messages",
        "--verbose",
        "--permission-prompt-tool", "stdio",
        "--permission-mode", options.permissionMode.rawValue,
    ]
    if let model = options.value(for: "--model") {
        launchArguments += ["--model", model]
    }

    let process: ChildProcess
    do {
        process = try ChildProcess(
            executablePath: executablePath,
            arguments: launchArguments,
            workingDirectory: directory,
            environment: ShellEnvironment.childEnvironment()
        )
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }

    let message = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"\#(prompt.jsonEscaped)"}]}}"#
    process.writeLine(message)

    var captured: [String] = []
    for await line in process.stdoutChunks.lines() {
        captured.append(line)
        FileHandle.standardError.write(Data(".".utf8))
        if line.contains("\"type\":\"result\"") { break }
    }
    process.closeStandardInput()
    await process.terminate()

    do {
        try captured.joined(separator: "\n").write(
            toFile: outputPath, atomically: true, encoding: .utf8
        )
        print("\n· recorded \(captured.count) lines → \(outputPath)")
    } catch {
        FileHandle.standardError.write(Data("could not write fixture: \(error)\n".utf8))
        exit(1)
    }
}

func runReplay(options: CommandLineOptions) {
    guard let path = options.positional.first else {
        FileHandle.standardError.write(Data("replay requires a fixture path\n".utf8))
        exit(1)
    }
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
        FileHandle.standardError.write(Data("could not read \(path)\n".utf8))
        exit(1)
    }

    let events = ClaudeCodeTranscriptReplay.events(transcript: contents)
    for event in events {
        print(EventPrinter.describe(event))
    }
    print("· \(events.count) events")
}

// MARK: - Rendering

/// Renders normalized events the way the app will: streamed text inline,
/// everything else as a labelled line. Also holds the pending permission id so
/// `/allow` and `/deny` have something to answer.
actor EventPrinter {
    private let showRaw: Bool
    private var pendingPermission: PermissionRequestID?
    private var isStreamingText = false

    init(showRaw: Bool) {
        self.showRaw = showRaw
    }

    func takePendingPermission() -> PermissionRequestID? {
        defer { pendingPermission = nil }
        return pendingPermission
    }

    func render(_ event: AgentEvent) {
        switch event {
        case .textDelta(let delta):
            if !isStreamingText {
                FileHandle.standardOutput.write(Data("\n".utf8))
                isStreamingText = true
            }
            FileHandle.standardOutput.write(Data(delta.text.utf8))
            return
        case .thinkingDelta where !showRaw:
            return
        case .blockCompleted:
            // The deltas already rendered this block; only close the line.
            if isStreamingText {
                FileHandle.standardOutput.write(Data("\n".utf8))
                isStreamingText = false
            }
            return
        case .permissionRequest(let request):
            pendingPermission = request.id
        default:
            break
        }

        if isStreamingText {
            FileHandle.standardOutput.write(Data("\n".utf8))
            isStreamingText = false
        }
        print(EventPrinter.describe(event))
    }

    static func describe(_ event: AgentEvent) -> String {
        switch event {
        case .sessionStarted(let started):
            let version = started.harnessVersion.map { " \($0)" } ?? ""
            let tools = started.availableTools.isEmpty
                ? ""
                : " · \(started.availableTools.count) tools"
            return "· session \(started.providerSessionID) · \(started.model ?? "default model")"
                + " · \(started.harness.displayName)\(version)\(tools)"
        case .statusChanged(let status):
            return "· \(status.rawValue)"
        case .turnStarted(let turn):
            return "· turn \(turn.turnID.rawValue.prefix(8))"
        case .textDelta(let delta):
            return "text+ \(delta.text)"
        case .thinkingDelta(let delta):
            return "think+ \(delta.text)"
        case .blockCompleted(let block):
            return "\(block.kind.rawValue) [\(block.text.count) chars]"
        case .toolCall(let call):
            let label = call.displayName ?? String(call.input.description.prefix(60))
            return "→ \(call.name)(\(label))"
        case .toolResult(let result):
            let firstLine = result.text.split(separator: "\n").first.map(String.init) ?? ""
            return "← \(result.isError ? "error" : "ok") \(firstLine.prefix(100))"
        case .planUpdated(let update):
            switch update.content {
            case .todos(let items):
                let done = items.filter { $0.status == .completed }.count
                return "☑ plan \(done)/\(items.count)"
            case .proposal(let markdown, _):
                return "☰ plan proposed (\(markdown.count) chars)"
            }
        case .permissionRequest(let request):
            return "? permission: \(request.toolName) \(request.summary ?? "")\n"
                + "    \(request.input.description.prefix(200))\n"
                + "    /allow or /deny"
                + (request.suggestions.isEmpty
                    ? ""
                    : "\n    suggestions: " + request.suggestions.map(\.title).joined(separator: " | "))
        case .permissionResolved(let resolution):
            if case .allow = resolution.decision { return "✓ allowed" }
            return "✗ denied"
        case .question(let question):
            let options = question.options.map(\.label).joined(separator: " | ")
            return "? \(question.prompt)\(options.isEmpty ? "" : "\n    \(options)")"
        case .usage(let usage):
            return "· tokens in=\(usage.inputTokens) out=\(usage.outputTokens) "
                + "cache=\(usage.cacheReadTokens)"
                + (usage.contextWindow.map { " / \($0) window" } ?? "")
        case .rateLimit(let report):
            return "· rate limit: \(report.status.rawValue)"
        case .turnCompleted(let result):
            let duration = result.duration.map { String(format: " in %.1fs", $0) } ?? ""
            return "· turn \(result.outcome.rawValue)\(duration)"
        case .sessionError(let error):
            return "! \(error.message)" + (error.detail.map { "\n    \($0)" } ?? "")
        case .sessionEnded(let ended):
            return "· session ended (exit \(ended.exitCode.map(String.init) ?? "?"))"
        case .contextCompacted(let compaction):
            return "· \(compaction.summary)"
        case .backgroundTasksChanged(let tasks):
            return tasks.isEmpty
                ? "· background work finished"
                : "· waiting on \(tasks.count) background task\(tasks.count == 1 ? "" : "s"): "
                    + tasks.map(\.description).joined(separator: "; ")
        }
    }
}

// MARK: - Input plumbing

enum StandardInput {
    /// `readLine` blocks, so it gets its own thread rather than a slot in the
    /// cooperative pool.
    static func lines() -> AsyncStream<String> {
        AsyncStream { continuation in
            let thread = Thread {
                while let line = readLine(strippingNewline: true) {
                    continuation.yield(line)
                }
                continuation.finish()
            }
            thread.name = "ore-cli.stdin"
            thread.start()
        }
    }
}

struct CommandLineOptions {
    let arguments: [String]

    init(arguments: [String]) {
        self.arguments = arguments
    }

    func value(for name: String) -> String? {
        guard let index = arguments.firstIndex(of: name),
              arguments.index(after: index) < arguments.endIndex
        else { return nil }
        return arguments[arguments.index(after: index)]
    }

    func flag(_ name: String) -> Bool {
        arguments.contains(name)
    }

    /// Arguments that aren't a flag or a flag's value.
    var positional: [String] {
        var result: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                // Flags take no value; everything else consumes the next word.
                let isFlag = ["--raw", "--full", "--auto-allow", "--delete-branch", "--assistant", "--dream", "--keep-files"]
                    .contains(argument)
                index = arguments.index(index, offsetBy: isFlag ? 1 : 2)
            } else {
                result.append(argument)
                index = arguments.index(after: index)
            }
        }
        return result
    }

    var workingDirectory: URL {
        if let path = value(for: "--dir") {
            return FilePath.expandingTildeURL(path)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    var permissionMode: PermissionMode {
        value(for: "--permission-mode").flatMap(PermissionMode.init(rawValue:)) ?? .default
    }

    var databaseURL: URL {
        if let path = value(for: "--db") {
            return FilePath.expandingTildeURL(path)
        }
        return OreStore.defaultURL
    }

    var timeoutSeconds: Double {
        value(for: "--timeout").flatMap(Double.init) ?? 180
    }

    var harnessKind: HarnessKind {
        guard let raw = value(for: "--harness") else { return .claudeCode }
        switch raw.lowercased() {
        case "claude", "claudecode", "claude-code": return .claudeCode
        case "codex": return .codex
        case "cursor", "cursor-agent", "grok": return .cursorAgent
        default: return HarnessKind(rawValue: raw) ?? .claudeCode
        }
    }

    var resumeMode: SessionRequest.ResumeMode {
        if let id = value(for: "--fork") { return .fork(providerSessionID: id) }
        if let id = value(for: "--resume") { return .resume(providerSessionID: id) }
        return .fresh
    }
}

extension String {
    var jsonEscaped: String {
        var result = ""
        for character in unicodeScalars {
            switch character {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.unicodeScalars.append(character)
            }
        }
        return result
    }
}
