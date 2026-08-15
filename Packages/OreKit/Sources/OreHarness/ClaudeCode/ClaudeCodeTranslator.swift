import Foundation
import OreProtocol

/// Converts Claude Code's stream-json wire messages into `AgentEvent`s.
///
/// Deliberately pure and synchronous: it owns no process, no tasks and no I/O,
/// only the small amount of state needed to stitch a stream together (which
/// block an index refers to, which tool calls we've already reported). That is
/// what makes golden-transcript tests possible — record a real session's stdout
/// once, replay it in CI on every CLI version, and diff the events.
struct ClaudeCodeTranslator {
    /// Output of one wire line: events for the app, plus control-channel
    /// business the session must act on.
    struct Output {
        var events: [AgentEvent] = []
        /// Acknowledgements of control requests *we* sent (interrupt, mode
        /// change), keyed by our request id.
        var controlAcknowledgements: [ControlAcknowledgement] = []

        var isEmpty: Bool { events.isEmpty && controlAcknowledgements.isEmpty }
    }

    struct ControlAcknowledgement {
        var requestID: String
        var isSuccess: Bool
        var error: String?
    }

    private struct StreamingBlock {
        var id: BlockID
        var kind: BlockCompleted.Kind
        var text: String = ""
    }

    let sessionID: SessionID

    private(set) var providerSessionID: String?
    private(set) var currentTurnID: TurnID?

    private var decoder = JSONDecoder()
    private var status: AgentStatus = .idle
    private var currentMessageID: String?
    private var currentModel: String?
    private var harnessVersion: String?
    /// Index → block, for the duration of one streamed message.
    private var streamingBlocks: [Int: StreamingBlock] = [:]
    /// Block ids already reported complete, so the streamed and the batched
    /// path can't both emit one.
    private var completedBlockIDs: Set<BlockID> = []
    private var reportedToolCallIDs: Set<ToolCallID> = []
    /// Tool name by id, so a permission request and a tool result can both be
    /// labelled even though only the `tool_use` block carries the name.
    private var toolNames: [ToolCallID: String] = [:]
    private var sawInterruptMarker = false
    /// Plan text by tool call id, awaiting the permission request that gates it.
    private var pendingPlanProposals: [ToolCallID: String] = [:]

    static let interruptMarker = "[Request interrupted"
    /// Observed values of `terminal_reason` on a cancelled turn. Treated as a
    /// hint rather than the primary signal, since the set grows with the CLI.
    static let interruptedTerminalReasons: Set<String> = [
        "interrupted", "aborted_streaming", "aborted", "cancelled",
    ]

    init(sessionID: SessionID) {
        self.sessionID = sessionID
    }

    // MARK: - Entry point

    mutating func translate(line: String) -> Output {
        guard let data = line.data(using: .utf8) else { return Output() }
        guard let envelope = try? decoder.decode(ClaudeWire.Envelope.self, from: data) else {
            // Not our protocol: a CLI that printed a warning to stdout, or a
            // version emitting something we can't parse. Never fatal.
            return Output()
        }

        if let providerSessionID = envelope.sessionID, self.providerSessionID == nil {
            self.providerSessionID = providerSessionID
        }

        switch envelope.type {
        case "system":
            return handleSystem(subtype: envelope.subtype, data: data)
        case "stream_event":
            return handleStreamEvent(data: data)
        case "assistant":
            return handleAssistant(data: data)
        case "user":
            return handleUser(data: data)
        case "result":
            return handleResult(data: data)
        case "rate_limit_event":
            return handleRateLimit(data: data)
        case "control_request":
            return handleControlRequest(data: data)
        case "control_response":
            return handleControlResponse(data: data)
        default:
            return Output()
        }
    }

    // MARK: - system

    private mutating func handleSystem(subtype: String?, data: Data) -> Output {
        var output = Output()
        switch subtype {
        case "init":
            guard let payload = try? decoder.decode(ClaudeWire.SystemInit.self, from: data) else {
                return output
            }
            providerSessionID = payload.sessionID
            currentModel = payload.model
            harnessVersion = payload.claudeCodeVersion
            output.events.append(.sessionStarted(SessionStarted(
                sessionID: sessionID,
                providerSessionID: payload.sessionID,
                harness: .claudeCode,
                model: payload.model,
                workingDirectory: payload.cwd,
                permissionMode: payload.permissionMode
                    .flatMap(PermissionMode.init(rawValue:)) ?? .default,
                availableTools: payload.tools ?? [],
                harnessVersion: payload.claudeCodeVersion
            )))

        case "status":
            guard let payload = try? decoder.decode(ClaudeWire.SystemStatus.self, from: data) else {
                return output
            }
            if payload.status == "requesting" {
                append(status: .requesting, to: &output)
            }

        case "session_state_changed":
            guard let payload = try? decoder.decode(ClaudeWire.SystemStatus.self, from: data) else {
                return output
            }
            // Only `idle` is authoritative here; `running` says nothing about
            // *what* is running, and the finer status comes from other events.
            if payload.state == "idle" {
                append(status: .idle, to: &output)
            }

        case "compact_boundary":
            // Claude Code compacted its own context. Surface it so the meter's
            // drop has a visible cause and the transcript isn't silently stitched.
            let meta = try? decoder.decode(ClaudeWire.CompactBoundary.self, from: data)
            output.events.append(.contextCompacted(ContextCompaction(
                turnID: currentTurnID,
                trigger: meta?.compactMetadata?.trigger,
                preTokens: meta?.compactMetadata?.preTokens
            )))

        default:
            // hook_started / hook_response and friends: diagnostics, not chat.
            break
        }
        return output
    }

    // MARK: - stream_event

    private mutating func handleStreamEvent(data: Data) -> Output {
        var output = Output()
        guard let payload = try? decoder.decode(ClaudeWire.StreamEvent.self, from: data) else {
            return output
        }
        let parent = payload.parentToolUseID.map(ToolCallID.init(rawValue:))
        let event = payload.event

        switch event.type {
        case "message_start":
            currentMessageID = event.message?.id
            if let model = event.message?.model { currentModel = model }
            streamingBlocks.removeAll(keepingCapacity: true)
            ensureTurn(&output)

        case "content_block_start":
            guard let index = event.index else { break }
            let kind: BlockCompleted.Kind =
                event.contentBlock?.type == "thinking" ? .thinking : .text
            guard event.contentBlock?.type == "text" || event.contentBlock?.type == "thinking"
            else {
                // tool_use blocks stream as partial JSON; we report them once
                // they arrive complete on the `assistant` message instead.
                break
            }
            streamingBlocks[index] = StreamingBlock(id: blockID(forIndex: index), kind: kind)

        case "content_block_delta":
            guard let index = event.index, let delta = event.delta else { break }
            let turnID = ensureTurn(&output)
            let id = blockID(forIndex: index)
            if let text = delta.text, !text.isEmpty {
                streamingBlocks[index, default: StreamingBlock(id: id, kind: .text)].text += text
                output.events.append(.textDelta(BlockDelta(
                    turnID: turnID, blockID: id, text: text, parentToolCallID: parent
                )))
            } else if let thinking = delta.thinking, !thinking.isEmpty {
                streamingBlocks[index, default: StreamingBlock(id: id, kind: .thinking)]
                    .text += thinking
                append(status: .thinking, to: &output)
                output.events.append(.thinkingDelta(BlockDelta(
                    turnID: turnID, blockID: id, text: thinking, parentToolCallID: parent
                )))
            }

        case "content_block_stop":
            guard let index = event.index, let block = streamingBlocks.removeValue(forKey: index)
            else { break }
            // The batched `assistant` message is authoritative and usually
            // arrives first; this only fires when it didn't.
            guard !completedBlockIDs.contains(block.id) else { break }
            completedBlockIDs.insert(block.id)
            let turnID = ensureTurn(&output)
            output.events.append(.blockCompleted(BlockCompleted(
                turnID: turnID,
                blockID: block.id,
                kind: block.kind,
                text: block.text,
                parentToolCallID: parent
            )))

        default:
            break
        }
        return output
    }

    // MARK: - assistant

    private mutating func handleAssistant(data: Data) -> Output {
        var output = Output()
        guard let payload = try? decoder.decode(ClaudeWire.AssistantMessage.self, from: data) else {
            return output
        }
        let turnID = ensureTurn(&output)
        let parent = payload.parentToolUseID.map(ToolCallID.init(rawValue:))
        if let model = payload.message.model { currentModel = model }
        let messageID = payload.message.id ?? currentMessageID

        for (index, block) in payload.message.content.enumerated() {
            let id = blockID(forIndex: index, messageID: messageID)
            switch block.type {
            case "text":
                guard let text = block.text, !completedBlockIDs.contains(id) else { break }
                completedBlockIDs.insert(id)
                output.events.append(.blockCompleted(BlockCompleted(
                    turnID: turnID, blockID: id, kind: .text, text: text, parentToolCallID: parent
                )))

            case "thinking":
                guard let text = block.thinking, !completedBlockIDs.contains(id) else { break }
                completedBlockIDs.insert(id)
                output.events.append(.blockCompleted(BlockCompleted(
                    turnID: turnID, blockID: id, kind: .thinking, text: text,
                    parentToolCallID: parent
                )))

            case "tool_use":
                guard let rawID = block.id, let name = block.name else { break }
                let toolCallID = ToolCallID(rawValue: rawID)
                guard !reportedToolCallIDs.contains(toolCallID) else { break }
                reportedToolCallIDs.insert(toolCallID)
                toolNames[toolCallID] = name
                let input = block.input ?? .object([:])
                output.events.append(.toolCall(ToolCall(
                    turnID: turnID,
                    id: toolCallID,
                    name: name,
                    displayName: ClaudeToolSemantics.displayName(tool: name, input: input),
                    input: input,
                    parentToolCallID: parent
                )))
                appendSemanticEvents(
                    tool: name, toolCallID: toolCallID, input: input,
                    turnID: turnID, to: &output
                )
                append(status: .runningTool, to: &output)

            default:
                break
            }
        }

        if let usage = payload.message.usage {
            output.events.append(.usage(usageReport(usage, turnID: turnID)))
        }
        return output
    }

    /// Some tools *are* product surfaces rather than opaque calls: a plan to
    /// approve, a checklist, a question for the user. Those get a normalized
    /// event alongside the raw tool call, so the UI doesn't special-case tool
    /// names per harness.
    private mutating func appendSemanticEvents(
        tool: String,
        toolCallID: ToolCallID,
        input: JSONValue,
        turnID: TurnID,
        to output: inout Output
    ) {
        switch tool {
        case "ExitPlanMode":
            let plan = input["plan"]?.stringValue ?? ""
            // Held so the permission request that gates this plan can be
            // republished with the plan attached — see `handleControlRequest`.
            pendingPlanProposals[toolCallID] = plan
            output.events.append(.planUpdated(PlanUpdate(
                turnID: turnID,
                content: .proposal(markdown: plan, permissionRequestID: nil)
            )))

        case "TodoWrite":
            guard let todos = input["todos"]?.arrayValue else { break }
            let items = todos.compactMap { entry -> TodoItem? in
                guard let text = entry["content"]?.stringValue else { return nil }
                let status: TodoItem.Status
                switch entry["status"]?.stringValue {
                case "completed": status = .completed
                case "in_progress": status = .inProgress
                default: status = .pending
                }
                return TodoItem(text: text, status: status)
            }
            guard !items.isEmpty else { break }
            output.events.append(.planUpdated(PlanUpdate(turnID: turnID, content: .todos(items))))

        case "AskUserQuestion":
            guard let questions = input["questions"]?.arrayValue else { break }
            for (offset, question) in questions.enumerated() {
                guard let prompt = question["question"]?.stringValue else { continue }
                let options = (question["options"]?.arrayValue ?? []).compactMap { option in
                    option["label"]?.stringValue.map {
                        AgentQuestion.Option(
                            label: $0, detail: option["description"]?.stringValue
                        )
                    }
                }
                output.events.append(.question(AgentQuestion(
                    turnID: turnID,
                    id: QuestionID(rawValue: "\(toolCallID.rawValue)#\(offset)"),
                    toolCallID: toolCallID,
                    prompt: prompt,
                    options: options,
                    allowsFreeform: true
                )))
            }
            append(status: .awaitingInput, to: &output)

        default:
            break
        }
    }

    // MARK: - user (tool results)

    private mutating func handleUser(data: Data) -> Output {
        var output = Output()
        guard let payload = try? decoder.decode(ClaudeWire.UserMessageEnvelope.self, from: data)
        else { return output }
        let turnID = ensureTurn(&output)

        for block in payload.message.content {
            switch block.type {
            case "tool_result":
                guard let rawID = block.toolUseID else { continue }
                output.events.append(.toolResult(ToolResult(
                    turnID: turnID,
                    toolCallID: ToolCallID(rawValue: rawID),
                    isError: block.isError ?? false,
                    text: block.flattenedResultText,
                    metadata: payload.toolUseResult
                )))

            case "text":
                // The CLI injects this marker when an interrupt lands. It's the
                // only unambiguous signal: the `result` that follows is an
                // ordinary execution error otherwise indistinguishable from a
                // crash.
                if block.text?.contains(Self.interruptMarker) == true {
                    sawInterruptMarker = true
                }

            default:
                break
            }
        }
        return output
    }

    // MARK: - result

    private mutating func handleResult(data: Data) -> Output {
        var output = Output()
        guard let payload = try? decoder.decode(ClaudeWire.Result.self, from: data) else {
            return output
        }
        let turnID = ensureTurn(&output)

        var usage: UsageReport?
        if let wireUsage = payload.usage {
            var report = usageReport(wireUsage, turnID: turnID)
            report.contextWindow = payload.modelUsage?.values.compactMap(\.contextWindow).max()
            // A subscription session isn't billed per token; showing the
            // API-equivalent price would be a lie. Only surface cost when the
            // session actually runs on an API key.
            report.costUSD = nil
            usage = report
            output.events.append(.usage(report))
        }

        let outcome: TurnResult.Outcome
        if sawInterruptMarker || Self.interruptedTerminalReasons.contains(payload.terminalReason ?? "") {
            outcome = .interrupted
        } else if payload.subtype == "success" {
            outcome = .completed
        } else {
            outcome = (payload.isError ?? false) ? .failed : .completed
        }

        output.events.append(.turnCompleted(TurnResult(
            turnID: turnID,
            outcome: outcome,
            summary: payload.result?.isEmpty == false ? payload.result : nil,
            usage: usage,
            duration: payload.durationMS.map { Double($0) / 1000 },
            errorMessage: outcome == .failed ? (payload.result ?? payload.subtype) : nil
        )))
        switch outcome {
        case .failed: append(status: .failed, to: &output)
        case .interrupted: append(status: .interrupted, to: &output)
        default: append(status: .idle, to: &output)
        }

        sawInterruptMarker = false
        currentTurnID = nil
        currentMessageID = nil
        streamingBlocks.removeAll(keepingCapacity: true)
        return output
    }

    private mutating func handleRateLimit(data: Data) -> Output {
        var output = Output()
        guard let payload = try? decoder.decode(ClaudeWire.RateLimitEvent.self, from: data),
              let info = payload.rateLimitInfo
        else { return output }

        let status: RateLimitReport.Status
        switch info.status {
        case "allowed": status = .allowed
        case "allowed_warning", "warning": status = .warning
        case "rejected", "exhausted": status = .exhausted
        default: status = .unknown
        }
        output.events.append(.rateLimit(RateLimitReport(
            status: status,
            window: info.rateLimitType,
            resetsAt: info.resetsAt.map { Date(timeIntervalSince1970: $0) }
        )))
        return output
    }

    // MARK: - Control channel

    private mutating func handleControlRequest(data: Data) -> Output {
        var output = Output()
        guard let payload = try? decoder.decode(ClaudeWire.ControlRequest.self, from: data) else {
            return output
        }
        guard payload.request.subtype == "can_use_tool" else {
            // Other inbound control requests (hook callbacks, MCP messages)
            // are answered by the session, not modelled as chat events.
            return output
        }
        let turnID = ensureTurn(&output)
        let toolCallID = payload.request.toolUseID.map(ToolCallID.init(rawValue:))
        let toolName = payload.request.toolName
            ?? toolCallID.flatMap { toolNames[$0] }
            ?? "unknown"

        output.events.append(.permissionRequest(PermissionRequest(
            turnID: turnID,
            id: PermissionRequestID(rawValue: payload.requestID),
            toolCallID: toolCallID,
            toolName: toolName,
            displayName: payload.request.displayName,
            summary: payload.request.description,
            input: payload.request.input ?? .object([:]),
            suggestions: (payload.request.permissionSuggestions ?? [])
                .compactMap(PermissionSuggestion.init(raw:))
        )))
        // Approving a plan means allowing this exact request and dropping out
        // of plan mode. Republish the proposal with the request attached so the
        // approve button has something to answer — the plan itself arrived
        // earlier, as a tool call, before any request existed to link to.
        if let toolCallID, let plan = pendingPlanProposals.removeValue(forKey: toolCallID) {
            output.events.append(.planUpdated(PlanUpdate(
                turnID: turnID,
                content: .proposal(
                    markdown: plan,
                    permissionRequestID: PermissionRequestID(rawValue: payload.requestID)
                )
            )))
        }

        append(status: .awaitingInput, to: &output)
        return output
    }

    private mutating func handleControlResponse(data: Data) -> Output {
        var output = Output()
        guard let payload = try? decoder.decode(ClaudeWire.ControlResponseInbound.self, from: data)
        else { return output }
        output.controlAcknowledgements.append(ControlAcknowledgement(
            requestID: payload.response.requestID,
            isSuccess: payload.response.subtype == "success",
            error: payload.response.error
        ))
        return output
    }

    // MARK: - Helpers

    /// Opens a turn if one isn't already open, emitting `.turnStarted` exactly
    /// once. Turns are closed by `result`.
    @discardableResult
    private mutating func ensureTurn(_ output: inout Output) -> TurnID {
        if let currentTurnID { return currentTurnID }
        let turnID = TurnID.generate()
        currentTurnID = turnID
        output.events.append(.turnStarted(TurnStarted(turnID: turnID, model: currentModel)))
        return turnID
    }

    /// Emits `.statusChanged` only on an actual transition — the CLI reports
    /// status far more often than it changes.
    private mutating func append(status newStatus: AgentStatus, to output: inout Output) {
        guard newStatus != status else { return }
        status = newStatus
        output.events.append(.statusChanged(newStatus))
    }

    private func blockID(forIndex index: Int, messageID: String? = nil) -> BlockID {
        let message = messageID ?? currentMessageID ?? currentTurnID?.rawValue ?? "msg"
        return BlockID(rawValue: "\(message)#\(index)")
    }

    private func usageReport(_ usage: ClaudeWire.Usage, turnID: TurnID?) -> UsageReport {
        UsageReport(
            turnID: turnID,
            inputTokens: usage.inputTokens ?? 0,
            outputTokens: usage.outputTokens ?? 0,
            cacheReadTokens: usage.cacheReadInputTokens ?? 0,
            cacheCreationTokens: usage.cacheCreationInputTokens ?? 0
        )
    }
}

// MARK: - Tool presentation

enum ClaudeToolSemantics {
    /// A short label for a tool call, so the transcript can show "Edit
    /// TranscriptView.swift" instead of a JSON blob.
    static func displayName(tool: String, input: JSONValue) -> String? {
        switch tool {
        case "Bash":
            return input["description"]?.stringValue ?? input["command"]?.stringValue
        case "Read", "Write", "Edit", "NotebookEdit", "LS", "Delete", "ReadLints":
            return input["file_path"]?.stringValue.map {
                URL(fileURLWithPath: $0).lastPathComponent
            }
        case "Glob", "Grep":
            return input["pattern"]?.stringValue
        case "Task":
            return input["description"]?.stringValue
        case "WebFetch":
            return input["url"]?.stringValue
        case "WebSearch":
            return input["query"]?.stringValue
        default:
            return nil
        }
    }
}

extension PermissionSuggestion {
    /// Normalizes a CLI permission suggestion, keeping the raw payload so the
    /// session can hand it back verbatim when the user accepts.
    init?(raw: JSONValue) {
        guard let type = raw["type"]?.stringValue else { return nil }
        switch type {
        case "setMode":
            let mode = raw["mode"]?.stringValue ?? "acceptEdits"
            let title = PermissionMode(rawValue: mode)?.displayName ?? mode
            self.init(kind: .setMode, title: "Switch to \(title)", raw: raw)
        case "addRules", "addRule":
            let rules = raw["rules"]?.arrayValue ?? []
            let described = rules.compactMap { rule -> String? in
                guard let tool = rule["toolName"]?.stringValue else { return nil }
                if let content = rule["ruleContent"]?.stringValue { return "\(tool)(\(content))" }
                return tool
            }
            let subject = described.isEmpty ? "this tool" : described.joined(separator: ", ")
            self.init(kind: .addRule, title: "Always allow \(subject)", raw: raw)
        default:
            self.init(kind: .other, title: type, raw: raw)
        }
    }
}
