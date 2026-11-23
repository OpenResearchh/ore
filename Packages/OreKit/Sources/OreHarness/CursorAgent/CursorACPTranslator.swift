import Foundation
import OreProtocol
import OreSupport

/// Converts Cursor ACP (`agent acp`) JSON-RPC into `AgentEvent`s.
///
/// Print stream-json suppresses thinking and has no permission callback.
/// ACP is the documented client protocol: `session/update` for text, thoughts,
/// and tools; `session/request_permission` for approvals; Cursor extensions
/// for plans, questions, subagent tasks, and generated images.
struct CursorACPTranslator {
    struct Output {
        var events: [AgentEvent] = []
        var isEmpty: Bool { events.isEmpty }
    }

    let sessionID: SessionID

    private(set) var providerSessionID: String?
    private(set) var currentTurnID: TurnID?
    private var status: AgentStatus = .idle
    private var model: String?
    private var workingDirectory = ""
    private var textSegment = 0
    private var thinkingSegment = 0
    private var streamedAssistant = ""
    private var toolNames: [ToolCallID: String] = [:]
    private var toolInputs: [ToolCallID: JSONValue] = [:]
    private var lastUsage: UsageReport?

    init(sessionID: SessionID) {
        self.sessionID = sessionID
    }

    mutating func noteSession(
        id providerID: String,
        workingDirectory: String,
        model: String?,
        permissionMode: PermissionMode
    ) -> Output {
        providerSessionID = providerID
        self.workingDirectory = workingDirectory
        self.model = model
        var output = Output()
        output.events.append(.sessionStarted(SessionStarted(
            sessionID: sessionID,
            providerSessionID: providerID,
            harness: .cursorAgent,
            model: model,
            workingDirectory: workingDirectory,
            permissionMode: permissionMode
        )))
        return output
    }

    mutating func beginTurn() -> Output {
        var output = Output()
        let turnID = TurnID.generate()
        currentTurnID = turnID
        textSegment = 0
        thinkingSegment = 0
        streamedAssistant = ""
        lastUsage = nil
        output.events.append(.turnStarted(TurnStarted(turnID: turnID, model: model)))
        append(status: .requesting, to: &output)
        return output
    }

    mutating func finishTurn(stopReason: String?) -> Output {
        var output = Output()
        guard let turnID = currentTurnID else { return output }
        flushText(to: &output)
        let outcome: TurnResult.Outcome
        switch stopReason {
        case "cancelled": outcome = .interrupted
        case "refusal", "max_tokens", "max_turn_requests": outcome = .failed
        default: outcome = .completed
        }
        let (summary, narration) = NarrationTag.extract(
            from: String(streamedAssistant.suffix(4000))
        )
        output.events.append(.turnCompleted(TurnResult(
            turnID: turnID,
            outcome: outcome,
            summary: summary.isEmpty ? nil : summary,
            narration: narration,
            usage: lastUsage,
            errorMessage: outcome == .failed ? stopReason : nil
        )))
        append(status: outcome == .interrupted ? .interrupted : .idle, to: &output)
        currentTurnID = nil
        return output
    }

    // MARK: - Notifications and extension methods

    mutating func translate(method: String, params: JSONValue?) -> Output {
        var output = Output()
        let params = params ?? .object([:])
        switch method {
        case "session/update":
            applyUpdate(params["update"] ?? params, to: &output)
        case "cursor/update_todos":
            emitTodos(params["todos"], merge: params["merge"]?.boolValue == true, to: &output)
        case "cursor/task":
            applyTask(params, to: &output)
        case "cursor/generate_image":
            applyGeneratedImage(params, to: &output)
        default:
            break
        }
        return output
    }

    mutating func permissionRequest(
        params: JSONValue?,
        requestID: String
    ) -> PermissionRequest? {
        let params = params ?? .object([:])
        let tool = params["toolCall"] ?? params
        let toolCallID = (tool["toolCallId"] ?? tool["toolCallID"] ?? params["toolCallId"])
            .flatMap(\.stringValue)
            .map(ToolCallID.init(rawValue:))
        let kind = tool["kind"]?.stringValue
        let rawInput = tool["rawInput"] ?? tool["input"] ?? .object([:])
        let name = toolName(kind: kind, title: tool["title"]?.stringValue, input: rawInput)
        let input = normalizedInput(rawInput, name: name)
        let options = params["options"]?.arrayValue ?? []
        let suggestions = options.compactMap { option -> PermissionSuggestion? in
            let optionID = option["optionId"]?.stringValue ?? option["option_id"]?.stringValue
            let kindName = option["kind"]?.stringValue ?? ""
            guard kindName.contains("always") || optionID == "allow-always" else { return nil }
            let title = option["name"]?.stringValue ?? "Allow always"
            return PermissionSuggestion(
                kind: .addRule,
                title: title,
                raw: .object(["optionId": .string(optionID ?? "allow-always")])
            )
        }
        return PermissionRequest(
            turnID: currentTurnID ?? TurnID.generate(),
            id: PermissionRequestID(rawValue: requestID),
            toolCallID: toolCallID,
            toolName: name,
            displayName: tool["title"]?.stringValue
                ?? ClaudeToolSemantics.displayName(tool: name, input: input),
            summary: tool["title"]?.stringValue
                ?? ClaudeToolSemantics.displayName(tool: name, input: input),
            input: input,
            suggestions: suggestions
        )
    }

    mutating func question(params: JSONValue?, requestID: String) -> AgentQuestion? {
        let params = params ?? .object([:])
        let questions = params["questions"]?.arrayValue ?? []
        let first = questions.first
        let prompt: String
        if questions.count > 1 {
            prompt = questions.compactMap { item in
                item["prompt"]?.stringValue
            }.joined(separator: "\n\n")
        } else {
            prompt = first?["prompt"]?.stringValue
                ?? params["title"]?.stringValue
                ?? "Cursor needs a decision"
        }
        let options = questions.flatMap { item in
            item["options"]?.arrayValue ?? []
        }.compactMap { option -> AgentQuestion.Option? in
            guard let label = option["label"]?.stringValue, !label.isEmpty else { return nil }
            return AgentQuestion.Option(label: label)
        }
        let allowMultiple = questions.contains { $0["allowMultiple"]?.boolValue == true }
        return AgentQuestion(
            turnID: currentTurnID ?? TurnID.generate(),
            id: QuestionID(rawValue: requestID),
            toolCallID: params["toolCallId"]?.stringValue.map(ToolCallID.init(rawValue:)),
            prompt: prompt,
            options: options,
            allowsFreeform: !allowMultiple && options.isEmpty
        )
    }

    mutating func planProposal(params: JSONValue?, requestID: String) -> (PlanUpdate, PermissionRequest)? {
        let params = params ?? .object([:])
        var sections: [String] = []
        if let name = params["name"]?.stringValue, !name.isEmpty {
            sections.append("# \(name)")
        }
        if let overview = params["overview"]?.stringValue, !overview.isEmpty {
            sections.append(overview)
        }
        if let plan = params["plan"]?.stringValue, !plan.isEmpty {
            sections.append(plan)
        }
        let todos = params["todos"]?.arrayValue ?? []
        let items = todos.compactMap { item -> String? in
            let text = item["content"]?.stringValue ?? item["text"]?.stringValue
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return "- [ ] \(text)"
        }
        if !items.isEmpty { sections.append(items.joined(separator: "\n")) }
        let markdown = sections.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard PlanProposalPolicy.isReadyMarkdown(markdown) else { return nil }
        let turnID = currentTurnID ?? TurnID.generate()
        let permissionID = PermissionRequestID(rawValue: requestID)
        let update = PlanUpdate(
            turnID: turnID,
            content: .proposal(markdown: markdown, permissionRequestID: permissionID),
            isReady: true
        )
        let request = PermissionRequest(
            turnID: turnID,
            id: permissionID,
            toolCallID: params["toolCallId"]?.stringValue.map(ToolCallID.init(rawValue:)),
            toolName: "CreatePlan",
            displayName: params["name"]?.stringValue ?? "Plan",
            summary: params["overview"]?.stringValue ?? params["name"]?.stringValue,
            input: params
        )
        return (update, request)
    }

    static func permissionOutcome(for decision: PermissionDecision, params: JSONValue?) -> JSONValue {
        let options = params?["options"]?.arrayValue ?? []
        func optionID(matching needles: [String]) -> String? {
            for option in options {
                let id = option["optionId"]?.stringValue ?? option["option_id"]?.stringValue
                let kind = option["kind"]?.stringValue ?? ""
                let haystack = (id ?? "") + " " + kind
                if needles.contains(where: { haystack.localizedCaseInsensitiveContains($0) }) {
                    return id
                }
            }
            return nil
        }
        switch decision {
        case .allow:
            let id = optionID(matching: ["allow-once", "allow_once"]) ?? "allow-once"
            return .object(["outcome": .object([
                "outcome": .string("selected"),
                "optionId": .string(id),
            ])])
        case .allowWithSuggestion(let raw):
            let id = raw["optionId"]?.stringValue
                ?? optionID(matching: ["allow-always", "allow_always"])
                ?? "allow-always"
            return .object(["outcome": .object([
                "outcome": .string("selected"),
                "optionId": .string(id),
            ])])
        case .deny:
            let id = optionID(matching: ["reject-once", "reject_once", "reject"]) ?? "reject-once"
            return .object(["outcome": .object([
                "outcome": .string("selected"),
                "optionId": .string(id),
            ])])
        }
    }

    static func cancelledPermissionOutcome() -> JSONValue {
        .object(["outcome": .object(["outcome": .string("cancelled")])])
    }

    static func planOutcome(accepted: Bool, reason: String? = nil) -> JSONValue {
        if accepted {
            return .object(["outcome": .object(["outcome": .string("accepted")])])
        }
        var body: [String: JSONValue] = ["outcome": .string("rejected")]
        if let reason, !reason.isEmpty { body["reason"] = .string(reason) }
        return .object(["outcome": .object(body)])
    }

    static func questionOutcome(
        params: JSONValue?,
        answer: String
    ) -> JSONValue {
        let questions = params?["questions"]?.arrayValue ?? []
        var answers: [JSONValue] = []
        for question in questions {
            guard let questionID = question["id"]?.stringValue else { continue }
            let options = question["options"]?.arrayValue ?? []
            let matched = options.compactMap { option -> String? in
                let label = option["label"]?.stringValue ?? ""
                guard label.caseInsensitiveCompare(answer) == .orderedSame
                    || answer.localizedCaseInsensitiveContains(label)
                else { return nil }
                return option["id"]?.stringValue
            }
            if matched.isEmpty { continue }
            answers.append(.object([
                "questionId": .string(questionID),
                "selectedOptionIds": .array(matched.map(JSONValue.string)),
            ]))
        }
        if answers.isEmpty {
            return .object(["outcome": .object([
                "outcome": .string("skipped"),
                "reason": .string(answer),
            ])])
        }
        return .object(["outcome": .object([
            "outcome": .string("answered"),
            "answers": .array(answers),
        ])])
    }

    static func acpMode(for permission: PermissionMode) -> String {
        switch permission {
        case .plan: return "plan"
        case .default, .acceptEdits, .bypassPermissions: return "agent"
        }
    }

    // MARK: - session/update

    private mutating func applyUpdate(_ update: JSONValue, to output: inout Output) {
        switch update["sessionUpdate"]?.stringValue {
        case "agent_message_chunk":
            applyMessageChunk(update, thinking: false, to: &output)
        case "agent_thought_chunk":
            applyMessageChunk(update, thinking: true, to: &output)
        case "tool_call":
            applyToolCall(update, to: &output)
        case "tool_call_update":
            applyToolCallUpdate(update, to: &output)
        case "plan", "plan_update":
            emitTodos(update["entries"] ?? update["todos"], merge: false, to: &output)
        case "usage_update":
            applyUsage(update, to: &output)
        case "compaction_update":
            if update["status"]?.stringValue == "completed" || update["status"] == nil {
                output.events.append(.contextCompacted(ContextCompaction(
                    turnID: currentTurnID,
                    trigger: "auto",
                    preTokens: update["used"]?.intValue ?? update["preTokens"]?.intValue
                )))
            }
        default:
            break
        }
    }

    private mutating func applyMessageChunk(
        _ update: JSONValue,
        thinking: Bool,
        to output: inout Output
    ) {
        let text = contentText(update["content"])
        guard !text.isEmpty else { return }
        let turnID = ensureTurn(&output)
        if thinking {
            append(status: .thinking, to: &output)
            let blockID = BlockID(rawValue: "\(turnID.rawValue)#thinking-\(thinkingSegment)")
            output.events.append(.thinkingDelta(BlockDelta(
                turnID: turnID, blockID: blockID, text: text
            )))
        } else {
            append(status: .requesting, to: &output)
            streamedAssistant += text
            let blockID = BlockID(rawValue: "\(turnID.rawValue)#text-\(textSegment)")
            output.events.append(.textDelta(BlockDelta(
                turnID: turnID, blockID: blockID, text: text
            )))
        }
    }

    private mutating func applyToolCall(_ update: JSONValue, to output: inout Output) {
        guard let rawID = update["toolCallId"]?.stringValue ?? update["toolCallID"]?.stringValue
        else { return }
        let turnID = ensureTurn(&output)
        flushText(to: &output)
        let toolCallID = ToolCallID(rawValue: rawID)
        let input = normalizedInput(update["rawInput"] ?? update["input"] ?? .object([:]), name: "")
        let name = toolName(
            kind: update["kind"]?.stringValue,
            title: update["title"]?.stringValue,
            input: input
        )
        let resolvedInput = normalizedInput(input, name: name)
        toolNames[toolCallID] = name
        toolInputs[toolCallID] = resolvedInput
        output.events.append(.toolCall(ToolCall(
            turnID: turnID,
            id: toolCallID,
            name: name,
            displayName: update["title"]?.stringValue
                ?? ClaudeToolSemantics.displayName(tool: name, input: resolvedInput),
            input: resolvedInput
        )))
        append(status: .runningTool, to: &output)
    }

    private mutating func applyToolCallUpdate(_ update: JSONValue, to output: inout Output) {
        guard let rawID = update["toolCallId"]?.stringValue ?? update["toolCallID"]?.stringValue
        else { return }
        let turnID = currentTurnID ?? ensureTurn(&output)
        let toolCallID = ToolCallID(rawValue: rawID)
        if let input = update["rawInput"] ?? update["input"] {
            let name = toolNames[toolCallID] ?? "Tool"
            toolInputs[toolCallID] = normalizedInput(input, name: name)
        }
        let statusName = update["status"]?.stringValue
        if statusName == "in_progress" {
            append(status: .runningTool, to: &output)
            return
        }
        guard statusName == "completed" || statusName == "failed"
            || update["content"] != nil
        else { return }
        let text = toolResultText(update["content"])
        output.events.append(.toolResult(ToolResult(
            turnID: turnID,
            toolCallID: toolCallID,
            isError: statusName == "failed",
            text: text
        )))
        append(status: .requesting, to: &output)
    }

    private mutating func applyTask(_ params: JSONValue, to output: inout Output) {
        let turnID = ensureTurn(&output)
        let rawID = params["toolCallId"]?.stringValue ?? params["agentId"]?.stringValue
            ?? UUID().uuidString.lowercased()
        let toolCallID = ToolCallID(rawValue: rawID)
        var input: [String: JSONValue] = [:]
        if let description = params["description"]?.stringValue {
            input["description"] = .string(description)
        }
        if let prompt = params["prompt"]?.stringValue {
            input["prompt"] = .string(prompt)
        }
        if let type = params["subagentType"]?.stringValue {
            input["subagent_type"] = .string(type)
        }
        let payload = SubagentBrief.normalized(.object(input))
        output.events.append(.toolCall(ToolCall(
            turnID: turnID,
            id: toolCallID,
            name: "Task",
            displayName: params["description"]?.stringValue ?? "Subagent",
            input: payload
        )))
        output.events.append(.toolResult(ToolResult(
            turnID: turnID,
            toolCallID: toolCallID,
            isError: false,
            text: params["prompt"]?.stringValue ?? ""
        )))
    }

    private mutating func applyGeneratedImage(_ params: JSONValue, to output: inout Output) {
        let turnID = ensureTurn(&output)
        let rawID = params["toolCallId"]?.stringValue ?? UUID().uuidString.lowercased()
        let toolCallID = ToolCallID(rawValue: rawID)
        let path = params["filePath"]?.stringValue ?? params["file_path"]?.stringValue
        var input: [String: JSONValue] = [:]
        if let path { input["file_path"] = .string(path) }
        if let description = params["description"]?.stringValue {
            input["prompt"] = .string(description)
        }
        output.events.append(.toolCall(ToolCall(
            turnID: turnID,
            id: toolCallID,
            name: "GenerateImage",
            displayName: path.map { FilePath.lastComponent($0) } ?? "image",
            input: .object(input)
        )))
        output.events.append(.toolResult(ToolResult(
            turnID: turnID,
            toolCallID: toolCallID,
            isError: false,
            text: path ?? params["description"]?.stringValue ?? ""
        )))
    }

    private mutating func emitTodos(_ value: JSONValue?, merge: Bool, to output: inout Output) {
        guard let items = value?.arrayValue, !items.isEmpty else { return }
        let todos = items.compactMap { item -> TodoItem? in
            let text = item["content"]?.stringValue ?? item["text"]?.stringValue
            guard let text, !text.isEmpty else { return nil }
            let status: TodoItem.Status
            switch item["status"]?.stringValue {
            case "in_progress", "in-progress": status = .inProgress
            case "completed", "complete": status = .completed
            default: status = .pending
            }
            return TodoItem(text: text, status: status)
        }
        guard !todos.isEmpty else { return }
        _ = merge
        output.events.append(.planUpdated(PlanUpdate(
            turnID: currentTurnID ?? TurnID.generate(),
            content: .todos(todos)
        )))
    }

    private mutating func applyUsage(_ update: JSONValue, to output: inout Output) {
        let used = update["used"]?.intValue ?? update["inputTokens"]?.intValue ?? 0
        let size = update["size"]?.intValue ?? update["contextWindow"]?.intValue
        let outputTokens = update["outputTokens"]?.intValue ?? 0
        let report = UsageReport(
            turnID: currentTurnID,
            inputTokens: used,
            outputTokens: outputTokens,
            contextWindow: size
        )
        lastUsage = report
        output.events.append(.usage(report))
    }

    // MARK: - Helpers

    private mutating func ensureTurn(_ output: inout Output) -> TurnID {
        if let currentTurnID { return currentTurnID }
        let started = beginTurn()
        output.events.append(contentsOf: started.events)
        return currentTurnID!
    }

    private mutating func flushText(to output: inout Output) {
        guard let turnID = currentTurnID else { return }
        textSegment += 1
        thinkingSegment += 1
        _ = output
        _ = turnID
    }

    private mutating func append(status: AgentStatus, to output: inout Output) {
        guard status != self.status else { return }
        self.status = status
        output.events.append(.statusChanged(status))
    }

    private func contentText(_ value: JSONValue?) -> String {
        if let text = value?.stringValue, !text.isEmpty { return text }
        if let text = value?["text"]?.stringValue, !text.isEmpty { return text }
        if let items = value?.arrayValue {
            return items.map(contentText).joined()
        }
        return ""
    }

    private func toolResultText(_ value: JSONValue?) -> String {
        guard let items = value?.arrayValue else {
            return contentText(value)
        }
        var parts: [String] = []
        for item in items {
            switch item["type"]?.stringValue {
            case "diff":
                let path = item["path"]?.stringValue ?? ""
                let old = item["oldText"]?.stringValue ?? item["old_text"]?.stringValue ?? ""
                let new = item["newText"]?.stringValue ?? item["new_text"]?.stringValue ?? ""
                if !path.isEmpty {
                    parts.append("--- a/\(path)\n+++ b/\(path)")
                }
                if !old.isEmpty || !new.isEmpty {
                    parts.append(contentsOf: old.split(separator: "\n", omittingEmptySubsequences: false).map { "-\($0)" })
                    parts.append(contentsOf: new.split(separator: "\n", omittingEmptySubsequences: false).map { "+\($0)" })
                }
            case "content":
                parts.append(contentText(item["content"]))
            default:
                let text = contentText(item)
                if !text.isEmpty { parts.append(text) }
            }
        }
        return parts.joined(separator: "\n")
    }

    private func toolName(kind: String?, title: String?, input: JSONValue) -> String {
        switch kind?.lowercased() {
        case "read": return "Read"
        case "edit": return "Edit"
        case "delete": return "Delete"
        case "move": return "Edit"
        case "search": return "Grep"
        case "execute": return "Bash"
        case "fetch": return "WebFetch"
        case "think": return "Think"
        default: break
        }
        if let title {
            let lower = title.lowercased()
            if lower.contains("edit") || lower.contains("write") { return "Edit" }
            if lower.contains("read") { return "Read" }
            if lower.contains("search") || lower.contains("grep") { return "Grep" }
            if lower.contains("shell") || lower.contains("bash") || lower.contains("command") {
                return "Bash"
            }
        }
        if input["command"] != nil { return "Bash" }
        if input["file_path"] != nil || input["path"] != nil { return "Read" }
        return "Tool"
    }

    private func normalizedInput(_ raw: JSONValue, name: String) -> JSONValue {
        guard var dict = raw.objectValue else { return raw }
        if let path = dict["path"]?.stringValue { dict["file_path"] = .string(path) }
        if dict["file_path"] == nil, let path = dict["filePath"]?.stringValue {
            dict["file_path"] = .string(path)
        }
        if name == "Bash", dict["command"] == nil, let command = dict["cmd"]?.stringValue {
            dict["command"] = .string(command)
        }
        let input = JSONValue.object(dict)
        guard SubagentBrief.isSubagentTool(name) else { return input }
        return SubagentBrief.normalized(input)
    }
}
