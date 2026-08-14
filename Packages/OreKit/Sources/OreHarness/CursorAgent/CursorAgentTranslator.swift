import Foundation
import OreProtocol

/// Converts cursor-agent's `--output-format stream-json` output into
/// `AgentEvent`s.
///
/// Written defensively even by the standards of the other translators. This
/// harness ships experimental and its output format is not documented as a
/// stable contract, so every field is optional, two plausible shapes are
/// accepted for the same idea, and anything unrecognized is dropped rather than
/// treated as an error.
struct CursorAgentTranslator {
    struct Output {
        var events: [AgentEvent] = []
        var isEmpty: Bool { events.isEmpty }
    }

    let sessionID: SessionID

    private(set) var providerSessionID: String?
    private var currentTurnID: TurnID?
    private var status: AgentStatus = .idle
    private var decoder = JSONDecoder()
    private var streamedText: [BlockID: String] = [:]
    private var reportedToolCallIDs: Set<ToolCallID> = []
    private var thinkingSegment = 0
    private var model: String?

    init(sessionID: SessionID) {
        self.sessionID = sessionID
    }

    mutating func translate(line: String) -> Output {
        var output = Output()
        guard let data = line.data(using: .utf8),
              let message = try? decoder.decode(JSONValue.self, from: data)
        else { return output }

        // Session id shows up under several names depending on the shape.
        if providerSessionID == nil {
            providerSessionID = message["session_id"]?.stringValue
                ?? message["chatId"]?.stringValue
                ?? message["chat_id"]?.stringValue
        }

        switch message["type"]?.stringValue {
        case "system":
            applySystem(message, to: &output)
        case "thinking":
            applyThinking(message, to: &output)
        case "tool_call":
            applyToolCall(message, to: &output)
        case "assistant":
            applyAssistant(message, to: &output)
        case "user":
            applyToolResults(message, to: &output)
        case "result":
            applyResult(message, to: &output)
        default:
            break
        }
        return output
    }

    /// The process exiting is the only reliable end-of-turn signal here: a
    /// one-shot CLI may exit without a final `result` record.
    mutating func closeTurn(exitCode: Int32) -> Output {
        var output = Output()
        guard let turnID = currentTurnID else {
            append(status: .idle, to: &output)
            return output
        }
        flushStreamedBlocks(turnID: turnID, to: &output)
        output.events.append(.turnCompleted(TurnResult(
            turnID: turnID,
            outcome: exitCode == 0 ? .completed : .failed,
            errorMessage: exitCode == 0 ? nil : "cursor-agent exited with status \(exitCode)"
        )))
        append(status: exitCode == 0 ? .idle : .failed, to: &output)
        currentTurnID = nil
        return output
    }

    // MARK: - Message shapes

    private mutating func applySystem(_ message: JSONValue, to output: inout Output) {
        guard message["subtype"]?.stringValue == "init" else { return }
        model = message["model"]?.stringValue ?? model
        output.events.append(.sessionStarted(SessionStarted(
            sessionID: sessionID,
            providerSessionID: providerSessionID ?? "",
            harness: .cursorAgent,
            model: model,
            workingDirectory: message["cwd"]?.stringValue ?? "",
            availableTools: message["tools"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )))
    }

    /// Tool activity arrives as top-level `{"type":"tool_call", subtype:
    /// started|completed, call_id, tool_call:{ <name>ToolCall:{ args, result }}}`
    /// messages — NOT as `tool_use` blocks inside the assistant content — so
    /// without this every tool a Cursor turn runs was silently dropped and a
    /// coding task looked like it did nothing.
    private mutating func applyToolCall(_ message: JSONValue, to output: inout Output) {
        let turnID = ensureTurn(&output)
        guard let rawID = message["call_id"]?.stringValue,
              let call = message["tool_call"]?.objectValue,
              let (rawKey, payload) = call.first
        else { return }
        let toolCallID = ToolCallID(rawValue: rawID)
        let name = Self.cursorToolName(rawKey)
        let input = Self.cursorToolInput(from: payload["args"])

        func emitCall() {
            guard reportedToolCallIDs.insert(toolCallID).inserted else { return }
            output.events.append(.toolCall(ToolCall(
                turnID: turnID, id: toolCallID, name: name,
                displayName: ClaudeToolSemantics.displayName(tool: name, input: input),
                input: input
            )))
        }

        switch message["subtype"]?.stringValue {
        case "started":
            emitCall()
            append(status: .runningTool, to: &output)
        case "completed":
            emitCall()  // in case "started" was never seen
            let result = payload["result"]
            output.events.append(.toolResult(ToolResult(
                turnID: turnID,
                toolCallID: toolCallID,
                isError: result?["error"] != nil || result?["failure"] != nil,
                text: Self.cursorResultText(result)
            )))
        default:
            break
        }
    }

    private static func cursorToolName(_ rawKey: String) -> String {
        let base = rawKey.replacingOccurrences(of: "ToolCall", with: "").lowercased()
        switch base {
        case "edit": return "Edit"
        case "write", "create": return "Write"
        case "read": return "Read"
        case "glob": return "Glob"
        case "grep", "search": return "Grep"
        case "shell", "bash", "terminal", "run", "command": return "Bash"
        case "ls", "list": return "LS"
        case "delete": return "Delete"
        case "webfetch", "fetch", "web": return "WebFetch"
        case "task", "agent": return "Task"
        default: return base.isEmpty ? "Tool" : base.prefix(1).uppercased() + base.dropFirst()
        }
    }

    /// Maps Cursor's per-tool arg names onto the keys the UI's presentation
    /// layer already understands (`file_path`, `command`, `pattern`, …).
    private static func cursorToolInput(from args: JSONValue?) -> JSONValue {
        guard var dict = args?.objectValue else { return args ?? .object([:]) }
        if let path = dict["path"]?.stringValue { dict["file_path"] = .string(path) }
        if let glob = dict["globPattern"]?.stringValue { dict["pattern"] = .string(glob) }
        if let content = dict["streamContent"]?.stringValue { dict["new_string"] = .string(content) }
        return .object(dict)
    }

    private static func cursorResultText(_ result: JSONValue?) -> String {
        guard let result else { return "" }
        if let text = result.stringValue { return text }
        guard let object = result.objectValue else { return "" }
        if let error = object["error"]?.stringValue { return error }
        if let success = object["success"] {
            if let text = success.stringValue { return text }
            for key in ["content", "output", "stdout", "text"] {
                if let value = success[key]?.stringValue { return value }
            }
        }
        return ""
    }

    /// Top-level reasoning stream: `{"type":"thinking","subtype":"delta","text":…}`
    /// chunks followed by a `completed`. Accumulated into one thinking row.
    private mutating func applyThinking(_ message: JSONValue, to output: inout Output) {
        let turnID = ensureTurn(&output)
        // A turn can have several thinking segments (interleaved with tool
        // calls); give each its own block so a later one doesn't overwrite the
        // earlier row. The segment advances when one completes.
        let blockID = BlockID(rawValue: "\(turnID.rawValue)#thinking-\(thinkingSegment)")
        switch message["subtype"]?.stringValue {
        case "delta":
            guard let text = message["text"]?.stringValue, !text.isEmpty else { return }
            append(status: .thinking, to: &output)
            streamedText[blockID, default: ""] += text
            output.events.append(.thinkingDelta(BlockDelta(
                turnID: turnID, blockID: blockID, text: text
            )))
        case "completed":
            defer { thinkingSegment += 1 }
            let text = streamedText.removeValue(forKey: blockID) ?? ""
            guard !text.isEmpty else { return }
            output.events.append(.blockCompleted(BlockCompleted(
                turnID: turnID, blockID: blockID, kind: .thinking, text: text
            )))
        default:
            break
        }
    }

    private mutating func applyAssistant(_ message: JSONValue, to output: inout Output) {
        let turnID = ensureTurn(&output)
        let body = message["message"] ?? message

        // cursor-agent streams a *full* assistant message per chunk (not a bare
        // delta): each partial carries `content:[{text: "<next fragment>"}]` and
        // a top-level `timestamp_ms`, then the run ends with ONE final message
        // that has no `timestamp_ms` and the whole concatenated text. So partials
        // must accumulate as text deltas into a single row, and only the final
        // message completes that row. Treating every partial as a completed block
        // (the previous behaviour) appended one row per word — the "each word on
        // its own line" bug.
        let isPartial = message["timestamp_ms"] != nil
        if isPartial { append(status: .requesting, to: &output) }
        let textBlockID = BlockID(rawValue: "\(turnID.rawValue)#text")

        // A bare `delta` field is an alternate shape; keep handling it.
        if let delta = message["delta"]?.stringValue ?? body["delta"]?.stringValue,
           !delta.isEmpty {
            streamedText[textBlockID, default: ""] += delta
            output.events.append(.textDelta(BlockDelta(
                turnID: turnID, blockID: textBlockID, text: delta
            )))
            return
        }

        guard let content = body["content"]?.arrayValue else {
            if let text = body["content"]?.stringValue, !text.isEmpty {
                streamedText.removeValue(forKey: textBlockID)
                output.events.append(.blockCompleted(BlockCompleted(
                    turnID: turnID,
                    blockID: textBlockID,
                    kind: .text,
                    text: text
                )))
            }
            return
        }

        for (index, block) in content.enumerated() {
            switch block["type"]?.stringValue {
            case "text":
                guard let text = block["text"]?.stringValue, !text.isEmpty else { break }
                if isPartial {
                    streamedText[textBlockID, default: ""] += text
                    output.events.append(.textDelta(BlockDelta(
                        turnID: turnID, blockID: textBlockID, text: text
                    )))
                } else {
                    streamedText.removeValue(forKey: textBlockID)
                    output.events.append(.blockCompleted(BlockCompleted(
                        turnID: turnID, blockID: textBlockID, kind: .text, text: text
                    )))
                }

            case "thinking", "reasoning":
                let text = block["thinking"]?.stringValue ?? block["text"]?.stringValue ?? ""
                guard !text.isEmpty else { break }
                append(status: .thinking, to: &output)
                output.events.append(.blockCompleted(BlockCompleted(
                    turnID: turnID,
                    blockID: BlockID(rawValue: "\(turnID.rawValue)#thinking-\(index)"),
                    kind: .thinking, text: text
                )))

            case "tool_use", "tool_call":
                guard let rawID = block["id"]?.stringValue,
                      let name = block["name"]?.stringValue
                else { break }
                let toolCallID = ToolCallID(rawValue: rawID)
                guard !reportedToolCallIDs.contains(toolCallID) else { break }
                reportedToolCallIDs.insert(toolCallID)
                let input = block["input"] ?? block["arguments"] ?? .object([:])
                output.events.append(.toolCall(ToolCall(
                    turnID: turnID,
                    id: toolCallID,
                    name: name,
                    displayName: ClaudeToolSemantics.displayName(tool: name, input: input),
                    input: input
                )))
                append(status: .runningTool, to: &output)

            default:
                break
            }
        }
    }

    private mutating func applyToolResults(_ message: JSONValue, to output: inout Output) {
        let turnID = ensureTurn(&output)
        let body = message["message"] ?? message
        guard let content = body["content"]?.arrayValue else { return }

        for block in content where block["type"]?.stringValue == "tool_result" {
            guard let rawID = block["tool_use_id"]?.stringValue
                ?? block["toolUseId"]?.stringValue
            else { continue }
            let text = block["content"]?.stringValue
                ?? block["content"]?.arrayValue?
                    .compactMap { $0["text"]?.stringValue }
                    .joined(separator: "\n")
                ?? ""
            output.events.append(.toolResult(ToolResult(
                turnID: turnID,
                toolCallID: ToolCallID(rawValue: rawID),
                isError: block["is_error"]?.boolValue ?? false,
                text: text
            )))
        }
    }

    private mutating func applyResult(_ message: JSONValue, to output: inout Output) {
        let turnID = ensureTurn(&output)
        flushStreamedBlocks(turnID: turnID, to: &output)

        if let usage = message["usage"] {
            output.events.append(.usage(UsageReport(
                turnID: turnID,
                inputTokens: usage["input_tokens"]?.intValue ?? 0,
                outputTokens: usage["output_tokens"]?.intValue ?? 0,
                cacheReadTokens: usage["cache_read_input_tokens"]?.intValue ?? 0
            )))
        }

        let isError = message["is_error"]?.boolValue ?? false
        let summary = message["result"]?.stringValue
        output.events.append(.turnCompleted(TurnResult(
            turnID: turnID,
            outcome: isError ? .failed : .completed,
            summary: summary?.isEmpty == false ? summary : nil,
            duration: message["duration_ms"]?.doubleValue.map { $0 / 1000 },
            errorMessage: isError ? summary : nil
        )))
        append(status: isError ? .failed : .idle, to: &output)
        currentTurnID = nil
    }

    /// Turns text that only ever arrived as deltas into completed blocks.
    ///
    /// Without this a session that streams but never sends a final content
    /// block would persist nothing: the deltas are for live rendering only.
    private mutating func flushStreamedBlocks(turnID: TurnID, to output: inout Output) {
        for (blockID, text) in streamedText.sorted(by: { $0.key.rawValue < $1.key.rawValue })
        where !text.isEmpty {
            output.events.append(.blockCompleted(BlockCompleted(
                turnID: turnID, blockID: blockID, kind: .text, text: text
            )))
        }
        streamedText.removeAll()
    }

    @discardableResult
    private mutating func ensureTurn(_ output: inout Output) -> TurnID {
        if let currentTurnID { return currentTurnID }
        let turnID = TurnID.generate()
        currentTurnID = turnID
        reportedToolCallIDs.removeAll()
        thinkingSegment = 0
        output.events.append(.turnStarted(TurnStarted(turnID: turnID, model: model)))
        return turnID
    }

    private mutating func append(status newStatus: AgentStatus, to output: inout Output) {
        guard newStatus != status else { return }
        status = newStatus
        output.events.append(.statusChanged(newStatus))
    }
}
