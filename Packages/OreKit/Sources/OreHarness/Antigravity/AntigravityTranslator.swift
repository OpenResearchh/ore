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
    private var childText: [ToolCallID: (blockID: BlockID, text: String)] = [:]
    private var reportedToolCallIDs: Set<ToolCallID> = []
    private var inFlightToolCalls = 0
    private var didReportResult = false
    private var backgroundTasks: [AgentBackgroundTask] = []
    /// Child conversation id → the `invoke_subagent` (Task) call that launched it.
    private var subagentByConversation: [String: ToolCallID] = [:]
    /// Most recent Task call, used when a child conversation appears before
    /// `subagent_info` names it.
    private var lastSubagentCallID: ToolCallID?
    /// Task calls we advertised as background work before `subagent_info`
    /// arrived. Cleared once the payload takes over, or when the call ends
    /// without ever naming a child.
    private var placeholderSubagentCalls: Set<ToolCallID> = []
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
        flushAllText(turnID: turnID, to: &output)
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
        let parent = parentToolCallID(for: step)
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
            applyText(
                step["text_delta"]?.stringValue, turnID: turnID, parent: parent, to: &output
            )
            if state == "DONE" { flushText(turnID: turnID, parent: parent, to: &output) }
        case "tool":
            applyTool(step, turnID: turnID, parent: parent, to: &output)
        default:
            if let text = step["text_delta"]?.stringValue {
                applyText(text, turnID: turnID, parent: parent, to: &output)
            }
        }
        // After the tool so `invoke_subagent` is already the last Task and
        // child conversation ids bind to it.
        if let subagents = step["subagent_info"]?["subagents"]?.arrayValue {
            applySubagents(subagents, to: &output)
        }
    }

    private mutating func applyResult(_ result: JSONValue, to output: inout Output) {
        if let conversationID = result["conversation_id"]?.stringValue {
            providerSessionID = conversationID
        }
        let turnID = currentTurnID ?? ensureTurn(&output)
        flushAllText(turnID: turnID, to: &output)
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
        lastSubagentCallID = nil
        placeholderSubagentCalls.removeAll()
        childText.removeAll()
    }

    private mutating func applyText(
        _ delta: String?,
        turnID: TurnID,
        parent: ToolCallID?,
        to output: inout Output
    ) {
        guard let delta, !delta.isEmpty else { return }
        append(status: .requesting, to: &output)
        if let parent {
            var stream = childText[parent] ?? (
                blockID: BlockID(rawValue: "agy-text-\(parent.rawValue)"),
                text: ""
            )
            stream.text += delta
            childText[parent] = stream
            output.events.append(.textDelta(BlockDelta(
                turnID: turnID, blockID: stream.blockID, text: delta, parentToolCallID: parent
            )))
            return
        }
        if textBlockID == nil {
            textBlockID = BlockID(rawValue: "agy-text-\(turnID.rawValue.prefix(8))")
        }
        guard let blockID = textBlockID else { return }
        streamedText += delta
        output.events.append(.textDelta(BlockDelta(turnID: turnID, blockID: blockID, text: delta)))
    }

    private mutating func flushText(
        turnID: TurnID,
        parent: ToolCallID?,
        to output: inout Output
    ) {
        if let parent {
            guard let stream = childText.removeValue(forKey: parent) else { return }
            output.events.append(.blockCompleted(BlockCompleted(
                turnID: turnID, blockID: stream.blockID, kind: .text, text: stream.text,
                parentToolCallID: parent
            )))
            return
        }
        guard let blockID = textBlockID else { return }
        output.events.append(.blockCompleted(BlockCompleted(
            turnID: turnID, blockID: blockID, kind: .text, text: streamedText
        )))
        textBlockID = nil
    }

    private mutating func flushAllText(turnID: TurnID, to output: inout Output) {
        flushText(turnID: turnID, parent: nil, to: &output)
        for parent in Array(childText.keys) {
            flushText(turnID: turnID, parent: parent, to: &output)
        }
    }

    private mutating func applyTool(
        _ step: JSONValue,
        turnID: TurnID,
        parent: ToolCallID?,
        to output: inout Output
    ) {
        let info = step["tool_info"] ?? .object([:])
        let rawName = step["tool_name"]?.stringValue
            ?? info["name"]?.stringValue
            ?? "tool"
        if ToolCallShape.isHidden(rawName) { return }
        let input = ToolCallShape.normalized(
            info["parameters"] ?? .object([:]),
            tool: rawName
        )
        let name = ToolCallShape.resolvedName(rawName, input: input)
        let toolCallID = Self.toolCallID(step: step, session: providerSessionID)
        let state = step["state"]?.stringValue
        let isNew = reportedToolCallIDs.insert(toolCallID).inserted
        if isNew {
            flushText(turnID: turnID, parent: parent, to: &output)
            inFlightToolCalls += 1
            append(status: .runningTool, to: &output)
        }
        let isSubagent = SubagentBrief.isSubagentTool(name)
        if isSubagent {
            lastSubagentCallID = toolCallID
            if let childID = Self.conversationID(in: input) {
                subagentByConversation[childID] = toolCallID
            }
            if isNew, step["subagent_info"]?["subagents"] == nil {
                advertisePlaceholderSubagent(
                    id: toolCallID, input: input, to: &output
                )
            }
        }
        output.events.append(.toolCall(ToolCall(
            turnID: turnID,
            id: toolCallID,
            name: name,
            displayName: Self.displayName(tool: name, input: input),
            input: input,
            parentToolCallID: parent
        )))
        let isTerminal = state == "DONE" || state == "ERROR" || state == "FAILED"
        if isTerminal {
            let error = info["error"]?["message"]?.stringValue ?? info["error"]?.stringValue
            let text = info["output"]?.stringValue ?? error ?? ""
            output.events.append(.toolResult(ToolResult(
                turnID: turnID,
                toolCallID: toolCallID,
                isError: error != nil || state == "ERROR" || state == "FAILED",
                text: text,
                metadata: info["error"]
            )))
            inFlightToolCalls = max(0, inFlightToolCalls - 1)
            if inFlightToolCalls == 0 {
                append(status: .requesting, to: &output)
            }
            if isSubagent { dropPlaceholderSubagent(id: toolCallID, to: &output) }
        }
    }

    private mutating func applySubagents(_ subagents: [JSONValue], to output: inout Output) {
        placeholderSubagentCalls.removeAll()
        let tasks: [AgentBackgroundTask] = subagents.compactMap { item in
            let id = Self.conversationID(in: item)
                ?? item["type_name"]?.stringValue
                ?? item["typeName"]?.stringValue
            guard let id else { return nil }
            if let parent = lastSubagentCallID {
                subagentByConversation[id] = parent
            }
            let description = item["role"]?.stringValue
                ?? item["Role"]?.stringValue
                ?? item["description"]?.stringValue
                ?? item["Description"]?.stringValue
                ?? item["task"]?.stringValue
                ?? "Subagent"
            return AgentBackgroundTask(
                id: id,
                kind: item["type_name"]?.stringValue ?? item["typeName"]?.stringValue,
                description: description
            )
        }
        guard tasks != backgroundTasks else { return }
        backgroundTasks = tasks
        output.events.append(.backgroundTasksChanged(backgroundTasks))
    }

    private mutating func advertisePlaceholderSubagent(
        id: ToolCallID,
        input: JSONValue,
        to output: inout Output
    ) {
        placeholderSubagentCalls.insert(id)
        let description = SubagentBrief.label(from: input)
            ?? SubagentBrief.purpose(from: input)
            ?? "Subagent"
        let taskID = Self.conversationID(in: input) ?? id.rawValue
        let task = AgentBackgroundTask(id: taskID, kind: "subagent", description: description)
        if backgroundTasks.contains(where: { $0.id == task.id }) { return }
        backgroundTasks.append(task)
        output.events.append(.backgroundTasksChanged(backgroundTasks))
    }

    private mutating func dropPlaceholderSubagent(id: ToolCallID, to output: inout Output) {
        guard placeholderSubagentCalls.remove(id) != nil else { return }
        let before = backgroundTasks
        backgroundTasks.removeAll { $0.id == id.rawValue }
        if backgroundTasks != before {
            output.events.append(.backgroundTasksChanged(backgroundTasks))
        }
    }

    /// Child steps carry their own `conversation_id` (and sometimes
    /// `parent_conversation_id`) so they can nest under the Task that launched
    /// them. Main-session steps stay top-level.
    private mutating func parentToolCallID(for step: JSONValue) -> ToolCallID? {
        let conversation = Self.conversationID(in: step)
        if let conversation, conversation != providerSessionID {
            if let known = subagentByConversation[conversation] { return known }
            if let lastSubagentCallID {
                subagentByConversation[conversation] = lastSubagentCallID
                return lastSubagentCallID
            }
        }
        if let parentConversation = step["parent_conversation_id"]?.stringValue
            ?? step["parentConversationId"]?.stringValue,
           parentConversation == providerSessionID {
            return lastSubagentCallID
        }
        return nil
    }

    private static func conversationID(in value: JSONValue) -> String? {
        value["conversation_id"]?.stringValue
            ?? value["conversationId"]?.stringValue
            ?? value["ConversationId"]?.stringValue
            ?? value["ConversationID"]?.stringValue
    }

    private static func toolCallID(step: JSONValue, session: String?) -> ToolCallID {
        let index = step["step_index"]?.intValue.map(String.init) ?? UUID().uuidString
        let conversation = conversationID(in: step)
        if let conversation, conversation != session, !conversation.isEmpty {
            let prefix = conversation.prefix(8)
            return ToolCallID(rawValue: "agy-tool-\(prefix)-\(index)")
        }
        return ToolCallID(rawValue: "agy-tool-\(index)")
    }

    // MARK: - Helpers

    private mutating func ensureTurn(_ output: inout Output) -> TurnID {
        if let currentTurnID { return currentTurnID }
        let turnID = TurnID.generate()
        currentTurnID = turnID
        didReportResult = false
        streamedText = ""
        textBlockID = nil
        childText.removeAll()
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
        let name = ToolCallShape.canonicalName(tool)
        let payload = ToolCallShape.normalized(input, tool: tool)
        if let label = ClaudeToolSemantics.displayName(tool: name, input: payload) {
            return label
        }
        return ToolCallShape.chipSubject(tool: tool, input: payload)
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
