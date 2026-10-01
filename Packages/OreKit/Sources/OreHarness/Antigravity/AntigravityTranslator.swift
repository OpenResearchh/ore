import Foundation
import OreProtocol

/// Converts Antigravity CLI's `--output-format stream-json` NDJSON into
/// `AgentEvent`s.
///
/// The documented stream is `init`, then `step_update`s, then a terminal
/// `result`. Fields are treated as optional: this harness ships experimental
/// and a CLI that adds a step type must not take the session down.
struct AntigravityTranslator {
    struct Output {
        var events: [AgentEvent] = []
        var isEmpty: Bool { events.isEmpty }
    }

    let sessionID: SessionID

    private(set) var providerSessionID: String?
    private var currentTurnID: TurnID?
    private var status: AgentStatus = .idle
    private var decoder = JSONDecoder()
    private var model: String?
    private var textBlockID: BlockID?
    private var streamedText = ""
    private var reportedToolCallIDs: Set<ToolCallID> = []
    private var inFlightToolCalls = 0
    private var didReportResult = false
    private var backgroundTasks: [AgentBackgroundTask] = []
    private var lastUsage: UsageReport?

    init(sessionID: SessionID) {
        self.sessionID = sessionID
    }

    mutating func translate(line: String) -> Output {
        var output = Output()
        guard let data = line.data(using: .utf8),
              let message = try? decoder.decode(JSONValue.self, from: data)
        else { return output }

        if providerSessionID == nil {
            providerSessionID = message["conversation_id"]?.stringValue
                ?? message["init"]?["conversation_id"]?.stringValue
        }

        switch message["event"]?.stringValue {
        case "init":
            applyInit(message, to: &output)
        case "step_update":
            applyStep(message["step_update"] ?? message, to: &output)
        case "result":
            applyResult(message["result"] ?? message, to: &output)
        default:
            break
        }
        return output
    }

    /// Process exit is the fallback end-of-turn signal when the CLI dies
    /// without a `result` event.
    mutating func closeTurn(exitCode: Int32, stderr: String = "") -> Output {
        var output = Output()
        if !backgroundTasks.isEmpty {
            backgroundTasks.removeAll()
            output.events.append(.backgroundTasksChanged([]))
        }
        guard let turnID = currentTurnID else {
            if exitCode != 0, !didReportResult {
                output.events.append(.sessionError(classifyFailure(exitCode: exitCode, stderr: stderr)))
                append(status: .failed, to: &output)
            } else {
                append(status: .idle, to: &output)
            }
            return output
        }
        flushText(turnID: turnID, to: &output)
        if !didReportResult {
            let failure = exitCode == 0 ? nil : classifyFailure(exitCode: exitCode, stderr: stderr)
            let (summary, narration) = NarrationTag.extract(from: streamedText)
            output.events.append(.turnCompleted(TurnResult(
                turnID: turnID,
                outcome: exitCode == 0 ? .completed : .failed,
                summary: summary.isEmpty ? nil : summary,
                narration: narration,
                usage: lastUsage,
                errorMessage: failure?.message
            )))
            append(status: exitCode == 0 ? .idle : .failed, to: &output)
        }
        currentTurnID = nil
        return output
    }

    // MARK: - Events

    private mutating func applyInit(_ message: JSONValue, to output: inout Output) {
        let payload = message["init"] ?? message
        if let conversationID = message["conversation_id"]?.stringValue
            ?? payload["conversation_id"]?.stringValue {
            providerSessionID = conversationID
        }
        model = payload["model"]?.stringValue ?? model
        let permissionMode = PermissionMode(agy: payload["permission_mode"]?.stringValue)
        output.events.append(.sessionStarted(SessionStarted(
            sessionID: sessionID,
            providerSessionID: providerSessionID ?? "",
            harness: .antigravity,
            model: model,
            workingDirectory: payload["cwd"]?.stringValue ?? "",
            permissionMode: permissionMode,
            availableTools: payload["tools"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )))
    }

    private mutating func applyStep(_ step: JSONValue, to output: inout Output) {
        if let conversationID = step["conversation_id"]?.stringValue, providerSessionID == nil {
            providerSessionID = conversationID
        }
        let turnID = ensureTurn(&output)
        let stepType = step["step_type"]?.stringValue
        let state = step["state"]?.stringValue
        if let usage = usage(from: step["usage"], turnID: turnID) {
            lastUsage = usage
            output.events.append(.usage(usage))
        }

        switch stepType {
        case "user_input":
            break
        case "agent_response":
            applyText(step["text_delta"]?.stringValue, turnID: turnID, to: &output)
            if state == "DONE" { flushText(turnID: turnID, to: &output) }
        case "tool":
            applyTool(step, turnID: turnID, to: &output)
        default:
            if let text = step["text_delta"]?.stringValue {
                applyText(text, turnID: turnID, to: &output)
            }
            if let subagents = step["subagent_info"]?["subagents"]?.arrayValue {
                applySubagents(subagents, to: &output)
            }
        }
    }

    private mutating func applyResult(_ result: JSONValue, to output: inout Output) {
        if let conversationID = result["conversation_id"]?.stringValue {
            providerSessionID = conversationID
        }
        let turnID = currentTurnID ?? ensureTurn(&output)
        flushText(turnID: turnID, to: &output)
        if let usage = usage(from: result["usage"], turnID: turnID) {
            lastUsage = usage
            output.events.append(.usage(usage))
        }

        let statusName = result["status"]?.stringValue ?? ""
        let error = result["error"]?.stringValue
        let response = result["response"]?.stringValue ?? streamedText
        let (summary, narration) = NarrationTag.extract(from: response)
        let outcome: TurnResult.Outcome
        let nextStatus: AgentStatus
        switch statusName {
        case "SUCCESS":
            outcome = .completed
            nextStatus = .idle
        case "INTERRUPTED", "CANCELED":
            outcome = .interrupted
            nextStatus = .interrupted
        default:
            outcome = .failed
            nextStatus = .failed
            if let error, AntigravityAuthStatus.looksLikeAuthFailure(error) {
                output.events.append(.sessionError(SessionError(
                    kind: .notAuthenticated,
                    message: "Antigravity isn't signed in. Run `agy` in a terminal, "
                        + "finish Google Sign-In, then send the message again.",
                    detail: error,
                    isRecoverable: false
                )))
            }
        }

        output.events.append(.turnCompleted(TurnResult(
            turnID: turnID,
            outcome: outcome,
            summary: summary.isEmpty ? nil : summary,
            narration: narration,
            usage: lastUsage,
            duration: result["duration_seconds"]?.doubleValue,
            errorMessage: error
        )))
        append(status: nextStatus, to: &output)
        didReportResult = true
        currentTurnID = nil
        streamedText = ""
        textBlockID = nil
        reportedToolCallIDs.removeAll()
        inFlightToolCalls = 0
    }

    private mutating func applyText(_ delta: String?, turnID: TurnID, to output: inout Output) {
        guard let delta, !delta.isEmpty else { return }
        if textBlockID == nil { textBlockID = BlockID(rawValue: "agy-text-\(turnID.rawValue.prefix(8))") }
        guard let blockID = textBlockID else { return }
        streamedText += delta
        append(status: .requesting, to: &output)
        output.events.append(.textDelta(BlockDelta(turnID: turnID, blockID: blockID, text: delta)))
    }

    private mutating func flushText(turnID: TurnID, to output: inout Output) {
        guard let blockID = textBlockID else { return }
        output.events.append(.blockCompleted(BlockCompleted(
            turnID: turnID, blockID: blockID, kind: .text, text: streamedText
        )))
        textBlockID = nil
    }

    private mutating func applyTool(_ step: JSONValue, turnID: TurnID, to output: inout Output) {
        let info = step["tool_info"] ?? .object([:])
        let name = step["tool_name"]?.stringValue
            ?? info["name"]?.stringValue
            ?? "tool"
        let index = step["step_index"]?.intValue.map(String.init) ?? UUID().uuidString
        let toolCallID = ToolCallID(rawValue: "agy-tool-\(index)")
        let input = info["parameters"] ?? .object([:])
        let state = step["state"]?.stringValue
        let isNew = reportedToolCallIDs.insert(toolCallID).inserted
        if isNew {
            flushText(turnID: turnID, to: &output)
            inFlightToolCalls += 1
            append(status: .runningTool, to: &output)
            output.events.append(.toolCall(ToolCall(
                turnID: turnID,
                id: toolCallID,
                name: name,
                displayName: Self.displayName(tool: name, input: input),
                input: input
            )))
        }
        if state == "DONE" {
            let error = info["error"]?["message"]?.stringValue ?? info["error"]?.stringValue
            let text = info["output"]?.stringValue ?? error ?? ""
            output.events.append(.toolResult(ToolResult(
                turnID: turnID,
                toolCallID: toolCallID,
                isError: error != nil,
                text: text,
                metadata: info["error"]
            )))
            inFlightToolCalls = max(0, inFlightToolCalls - 1)
            if inFlightToolCalls == 0 {
                append(status: .requesting, to: &output)
            }
        }
    }

    private mutating func applySubagents(_ subagents: [JSONValue], to output: inout Output) {
        backgroundTasks = subagents.compactMap { item in
            let id = item["conversation_id"]?.stringValue
                ?? item["type_name"]?.stringValue
            guard let id else { return nil }
            return AgentBackgroundTask(
                id: id,
                kind: item["type_name"]?.stringValue,
                description: item["role"]?.stringValue ?? "Subagent"
            )
        }
        output.events.append(.backgroundTasksChanged(backgroundTasks))
    }

    // MARK: - Helpers

    private mutating func ensureTurn(_ output: inout Output) -> TurnID {
        if let currentTurnID { return currentTurnID }
        let turnID = TurnID.generate()
        currentTurnID = turnID
        didReportResult = false
        streamedText = ""
        textBlockID = nil
        reportedToolCallIDs.removeAll()
        inFlightToolCalls = 0
        lastUsage = nil
        output.events.append(.turnStarted(TurnStarted(turnID: turnID, model: model)))
        append(status: .requesting, to: &output)
        return turnID
    }

    private mutating func append(status next: AgentStatus, to output: inout Output) {
        guard status != next else { return }
        status = next
        output.events.append(.statusChanged(next))
    }

    private func usage(from value: JSONValue?, turnID: TurnID) -> UsageReport? {
        guard let value else { return nil }
        let input = value["input_tokens"]?.intValue ?? 0
        let output = value["output_tokens"]?.intValue ?? 0
        let cacheRead = value["cache_read_tokens"]?.intValue ?? 0
        guard input != 0 || output != 0 || cacheRead != 0 else { return nil }
        return UsageReport(
            turnID: turnID,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead
        )
    }

    private func classifyFailure(exitCode: Int32, stderr: String) -> SessionError {
        let lower = stderr.lowercased()
        if AntigravityAuthStatus.looksLikeAuthFailure(lower) {
            return SessionError(
                kind: .notAuthenticated,
                message: "Antigravity isn't signed in. Run `agy` in a terminal, "
                    + "finish Google Sign-In, then send the message again.",
                detail: stderr,
                isRecoverable: false
            )
        }
        if lower.contains("rate limit") || lower.contains("quota") || lower.contains("usage limit") {
            return SessionError(
                kind: .rateLimited,
                message: "Antigravity hit a usage limit.",
                detail: stderr,
                isRecoverable: true
            )
        }
        return SessionError(
            kind: .processFailed,
            message: "Antigravity exited unexpectedly (status \(exitCode)).",
            detail: stderr.isEmpty ? nil : stderr,
            isRecoverable: false
        )
    }

    static func displayName(tool: String, input: JSONValue) -> String? {
        switch tool {
        case "run_command":
            return input["CommandLine"]?.stringValue
                ?? input["command"]?.stringValue
                ?? input["command_line"]?.stringValue
        case "write_to_file", "write_file", "view_file", "replace_file_content":
            let path = input["Path"]?.stringValue
                ?? input["path"]?.stringValue
                ?? input["file_path"]?.stringValue
            return path.map { URL(fileURLWithPath: $0).lastPathComponent }
        default:
            return ClaudeToolSemantics.displayName(tool: tool, input: input)
        }
    }
}

extension PermissionMode {
    /// Antigravity's headless `permission_mode` strings.
    fileprivate init(agy raw: String?) {
        switch raw {
        case "always-proceed": self = .bypassPermissions
        case "proceed-in-sandbox": self = .acceptEdits
        case "strict": self = .default
        default: self = .default
        }
    }
}
