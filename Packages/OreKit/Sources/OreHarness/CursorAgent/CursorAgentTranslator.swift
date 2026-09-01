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
    private var toolInputs: [ToolCallID: JSONValue] = [:]
    private var thinkingSegment = 0
    private var textSegment = 0
    /// Concatenation of assistant text already completed this turn, so a final
    /// snapshot of the whole turn is not rewritten into the first row.
    private var emittedAssistantText = ""
    private var model: String?
    /// Whether a `result` record already closed the current turn, so the
    /// process exit has nothing left to report.
    private var didReportResult = false
    /// Last plan markdown emitted this turn, so a `started` then `completed`
    /// CreatePlan with the same body is one card, not two.
    private var lastPlanMarkdown: String?
    /// Whether this turn already advertised a *ready* proposal. Cursor often
    /// CreatePlan-then-exits without a `completed` record; `closeTurn` promotes
    /// a draft only if this is still false.
    private var didAdvertisePlanReady = false
    /// Last ready-flag emitted with `lastPlanMarkdown`, so a duplicate
    /// completed record does not republish.
    private var lastPlanReady = false

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
    ///
    /// `stderr` carries the *only* explanation of a failure this CLI gives —
    /// stdout is empty when it rejects a model, a login or a quota — so a
    /// non-zero exit is classified from it rather than reported as a bare
    /// status code.
    mutating func closeTurn(exitCode: Int32, stderr: String = "") -> Output {
        var output = Output()
        let failure = exitCode == 0
            ? nil
            : CursorAgentFailure.classify(exitCode: exitCode, stderr: stderr)

        guard let turnID = currentTurnID else {
            // Config-level failures (bad model, expired login) kill the process
            // before it emits a single stdout record, so there is no turn to
            // fail — and the turn used to end here in silence, leaving the user
            // with a spinner that simply stopped. Report it as a session error.
            //
            // Unless a `result` record already closed the turn: a CLI that
            // reports an in-band failure *and* exits non-zero would otherwise
            // raise the same problem twice, as a failed turn and again as a
            // session error.
            if let failure, !didReportResult {
                output.events.append(.sessionError(failure))
                append(status: .failed, to: &output)
            } else {
                append(status: .idle, to: &output)
            }
            return output
        }
        flushStreamedBlocks(turnID: turnID, to: &output)
        // Cursor sometimes CreatePlan-then-exits with only a `started` record.
        // Promote a draft that never saw `completed` so approval is not lost,
        // but never advertise readiness without a body in the transcript.
        promotePendingPlanIfNeeded(turnID: turnID, to: &output)
        // The process-exit path used to end the turn with no summary at all,
        // which is why Cursor completions could only ever narrate "All done."
        // The text streamed this turn *is* the final report; hand it over.
        // The tag extraction is defensive — this harness is never taught the
        // narration tag, but the user's own rules files might teach it one day.
        let (summaryBody, narration) = NarrationTag.extract(
            from: String(emittedAssistantText.suffix(4000))
        )
        output.events.append(.turnCompleted(TurnResult(
            turnID: turnID,
            outcome: exitCode == 0 ? .completed : .failed,
            summary: summaryBody.isEmpty ? nil : summaryBody,
            narration: narration,
            errorMessage: failure?.message
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
        guard let rawID = message["call_id"]?.stringValue,
              let call = message["tool_call"]?.objectValue,
              let (rawKey, payload) = Self.cursorToolEntry(in: call)
        else { return }
        let turnID = ensureTurn(&output)
        let toolCallID = ToolCallID(rawValue: rawID)
        let name = Self.cursorToolName(rawKey)

        func emitCall(result: JSONValue? = nil) {
            let input = mergedToolInput(id: toolCallID, tool: name, from: payload, result: result)
            let isNew = reportedToolCallIDs.insert(toolCallID).inserted
            if isNew {
                closeCurrentTextSegment(turnID: turnID, to: &output)
            }
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
            // Draft only: Cursor sends name/overview on start while still
            // writing. Advertising ready here is what flashed approval before
            // any plan body existed in the transcript.
            emitPlanProposal(
                from: toolInputs[toolCallID], turnID: turnID, ready: false, to: &output
            )
        case "completed":
            let result = payload["result"]
            emitCall(result: result)
            output.events.append(.toolResult(ToolResult(
                turnID: turnID,
                toolCallID: toolCallID,
                isError: result?["error"] != nil || result?["failure"] != nil
                    || result?["rejected"] != nil,
                text: Self.cursorResultText(result)
            )))
            emitPlanProposal(
                from: toolInputs[toolCallID], turnID: turnID, ready: true, to: &output
            )
            if didAdvertisePlanReady {
                append(status: .awaitingInput, to: &output)
            } else {
                append(status: .requesting, to: &output)
            }
        default:
            break
        }
    }

    private mutating func emitPlanProposal(
        from input: JSONValue?,
        turnID: TurnID,
        ready: Bool,
        to output: inout Output
    ) {
        guard let input, let markdown = Self.planMarkdown(from: input) else { return }
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Title/overview with no body is Cursor's CreatePlan-started placeholder.
        guard PlanProposalPolicy.isReadyInput(input) else { return }

        let isReady = ready
        if markdown == lastPlanMarkdown, isReady == lastPlanReady { return }
        lastPlanMarkdown = markdown
        lastPlanReady = isReady
        if isReady { didAdvertisePlanReady = true }
        output.events.append(.planUpdated(PlanUpdate(
            turnID: turnID,
            content: .proposal(markdown: markdown, permissionRequestID: nil),
            isReady: isReady
        )))
    }

    private mutating func promotePendingPlanIfNeeded(turnID: TurnID, to output: inout Output) {
        guard !didAdvertisePlanReady,
              let markdown = lastPlanMarkdown,
              PlanProposalPolicy.isReadyMarkdown(markdown)
        else { return }
        didAdvertisePlanReady = true
        lastPlanReady = true
        output.events.append(.planUpdated(PlanUpdate(
            turnID: turnID,
            content: .proposal(markdown: markdown, permissionRequestID: nil),
            isReady: true
        )))
        append(status: .awaitingInput, to: &output)
    }

    /// Cursor's `tool_call` object mixes the real payload (`readToolCall`,
    /// `editToolCall`, …) with metadata (`toolCallId`, `startedAtMs`,
    /// `hookAdditionalContexts`). Taking `.first` on that dictionary produced
    /// transcript rows named `Toolcallid` / `Startedatms`. Prefer the `*ToolCall`
    /// entry; skip hook-only records entirely.
    private static func cursorToolEntry(
        in call: [String: JSONValue]
    ) -> (key: String, payload: JSONValue)? {
        let tools = call.filter { key, value in
            value.objectValue != nil
                && (key.hasSuffix("ToolCall") || key.hasSuffix("toolCall"))
        }
        if let match = tools.sorted(by: { $0.key < $1.key }).first {
            return (match.key, match.value)
        }
        let remaining = call.filter { key, value in
            value.objectValue != nil && !isCursorMetadataKey(key)
        }
        if remaining.count == 1, let match = remaining.first {
            return (match.key, match.value)
        }
        return nil
    }

    private static func isCursorMetadataKey(_ key: String) -> Bool {
        switch key {
        case "toolCallId", "tool_call_id", "callId", "call_id",
             "startedAtMs", "started_at_ms", "completedAtMs", "completed_at_ms",
             "timestampMs", "timestamp_ms",
             "hookAdditionalContexts", "hook_additional_contexts":
            return true
        default:
            return false
        }
    }

    private static func cursorToolName(_ rawKey: String) -> String {
        var base = rawKey
        if base.hasSuffix("ToolCall") {
            base = String(base.dropLast("ToolCall".count))
        } else if base.hasSuffix("toolCall") {
            base = String(base.dropLast("toolCall".count))
        }
        switch base.lowercased() {
        case "edit", "applypatch", "apply_patch": return "Edit"
        case "write", "create": return "Write"
        case "read": return "Read"
        case "glob": return "Glob"
        case "grep", "search": return "Grep"
        case "semsearch", "semanticsearch", "codesearch": return "Grep"
        case "shell", "bash", "terminal", "run", "command": return "Bash"
        case "ls", "list", "listdir": return "LS"
        case "delete", "remove": return "Delete"
        case "webfetch", "fetch", "web": return "WebFetch"
        case "websearch": return "WebSearch"
        case "readlints", "lints", "read_lints": return "ReadLints"
        case "task", "agent": return "Task"
        case "todowrite", "todoread", "todo": return "TodoWrite"
        case "createplan", "create_plan": return "CreatePlan"
        case "exitplanmode", "exit_plan_mode": return "ExitPlanMode"
        default:
            return base.isEmpty ? "Tool" : base.prefix(1).uppercased() + base.dropFirst()
        }
    }

    static func isPlanTool(_ name: String) -> Bool {
        switch name {
        case "CreatePlan", "ExitPlanMode": return true
        default: return false
        }
    }

    /// Cursor's CreatePlan args are `name` / `overview` / `plan` / `todos`,
    /// sometimes with the body on `streamContent` while it is still writing.
    static func planMarkdown(from input: JSONValue) -> String? {
        let body = input["plan"]?.stringValue
            ?? input["markdown"]?.stringValue
            ?? input["content"]?.stringValue
            ?? input["streamContent"]?.stringValue
            ?? input["stream_content"]?.stringValue
        if let body, body.contains("\n") || body.hasPrefix("#") {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        var sections: [String] = []
        if let name = input["name"]?.stringValue ?? input["title"]?.stringValue,
           !name.isEmpty {
            sections.append("# \(name)")
        }
        if let overview = input["overview"]?.stringValue ?? input["description"]?.stringValue,
           !overview.isEmpty {
            sections.append(overview)
        }
        if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(body)
        }
        let todos = input["todos"]?.arrayValue ?? input["steps"]?.arrayValue ?? []
        let items = todos.compactMap { item -> String? in
            let text = item["content"]?.stringValue
                ?? item["text"]?.stringValue
                ?? item.stringValue
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return "- [ ] \(text)"
        }
        if !items.isEmpty { sections.append(items.joined(separator: "\n")) }
        let markdown = sections.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return markdown.isEmpty ? nil : markdown
    }

    /// Maps Cursor's per-tool arg names onto the keys the UI's presentation
    /// layer already understands (`file_path`, `command`, `pattern`, …).
    private static func cursorToolInput(
        tool: String,
        from payload: JSONValue,
        result: JSONValue? = nil
    ) -> JSONValue {
        let args = payload["args"] ?? payload["arguments"]
        var dict = args?.objectValue ?? [:]
        if let object = payload.objectValue {
            for (key, value) in object {
                if key == "result" || key == "error" || key == "args" || key == "arguments" {
                    continue
                }
                if dict[key] == nil { dict[key] = value }
            }
        }
        // Streaming edits put the growing body on the payload, not in `args`.
        if let stream = payload["streamContent"]?.stringValue
            ?? payload["stream_content"]?.stringValue,
           !stream.isEmpty {
            dict["streamContent"] = .string(stream)
        }
        mergeDiffFields(from: result?["success"] ?? result, into: &dict)
        mergePlanFields(from: result?["success"] ?? result, into: &dict)

        if let path = dict["path"]?.stringValue { dict["file_path"] = .string(path) }
        if let target = dict["targetDirectory"]?.stringValue ?? dict["target_directory"]?.stringValue {
            dict["path"] = .string(target)
            dict["file_path"] = .string(target)
        }
        if dict["file_path"] == nil,
           let paths = dict["paths"]?.arrayValue,
           let first = paths.first?.stringValue {
            dict["file_path"] = .string(first)
        }
        if let glob = dict["globPattern"]?.stringValue ?? dict["glob_pattern"]?.stringValue {
            dict["pattern"] = .string(glob)
        }
        if dict["pattern"] == nil, let query = dict["query"]?.stringValue {
            dict["pattern"] = .string(query)
        }
        applyEditContent(to: &dict)
        let input = JSONValue.object(dict)
        // Cursor's agent tool names the child's brief its own way. Only
        // subagent calls go through this — `name` and `title` mean something
        // else to CreatePlan, and aliasing them there would leak a bogus
        // overview into the plan markdown.
        guard SubagentBrief.isSubagentTool(tool) else { return input }
        return SubagentBrief.normalized(input)
    }

    private static func mergeDiffFields(from source: JSONValue?, into dict: inout [String: JSONValue]) {
        guard let object = source?.objectValue else { return }
        for key in [
            "diff", "patch", "before", "after",
            "old_string", "oldString", "new_string", "newString",
            "oldContent", "newContent", "content", "contents", "path",
        ] {
            if let value = object[key], dict[key] == nil {
                dict[key] = value
            }
        }
        if let path = object["path"]?.stringValue, dict["file_path"] == nil {
            dict["file_path"] = .string(path)
        }
    }

    private static func mergePlanFields(from source: JSONValue?, into dict: inout [String: JSONValue]) {
        guard let object = source?.objectValue else { return }
        for key in [
            "plan", "markdown", "content", "overview", "name", "title",
            "todos", "steps", "streamContent", "stream_content",
        ] {
            guard let value = object[key] else { continue }
            if dict[key] == nil {
                dict[key] = value
                continue
            }
            if let current = dict[key]?.stringValue, current.isEmpty,
               let incoming = value.stringValue, !incoming.isEmpty {
                dict[key] = value
            }
        }
    }

    /// Turns Cursor's `streamContent` / before-after / diff fields into the
    /// `patch` / `old_string` / `new_string` keys the transcript already renders.
    private static func applyEditContent(to dict: inout [String: JSONValue]) {
        if let stream = dict["streamContent"]?.stringValue ?? dict["stream_content"]?.stringValue,
           !stream.isEmpty {
            if looksLikePatch(stream) {
                dict["patch"] = .string(stream)
            } else if dict["new_string"] == nil {
                dict["new_string"] = .string(stream)
            }
        }
        if dict["patch"] == nil, let diff = dict["diff"]?.stringValue, looksLikePatch(diff) {
            dict["patch"] = .string(diff)
        }
        if dict["old_string"] == nil {
            if let before = dict["before"]?.stringValue ?? dict["oldContent"]?.stringValue {
                dict["old_string"] = .string(before)
            }
        }
        if dict["new_string"] == nil {
            if let after = dict["after"]?.stringValue ?? dict["newContent"]?.stringValue {
                dict["new_string"] = .string(after)
            }
        }
    }

    static func looksLikePatch(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("diff --git") { return true }
        if trimmed.contains("*** Begin Patch") { return true }
        if trimmed.contains("*** Update File:")
            || trimmed.contains("*** Add File:")
            || trimmed.contains("*** Delete File:") {
            return true
        }
        if trimmed.hasPrefix("@@ ") || trimmed.contains("\n@@ ") { return true }
        let hasMinusHeader = trimmed.hasPrefix("--- ") || trimmed.contains("\n--- ")
        let hasPlusHeader = trimmed.contains("\n+++ ") || trimmed.hasPrefix("+++ ")
        return hasMinusHeader && hasPlusHeader
    }

    private mutating func mergedToolInput(
        id: ToolCallID,
        tool: String,
        from payload: JSONValue,
        result: JSONValue?
    ) -> JSONValue {
        let incoming = Self.cursorToolInput(tool: tool, from: payload, result: result)
        let merged = Self.mergePreferringNonEmpty(toolInputs[id], incoming)
        toolInputs[id] = merged
        return merged
    }

    /// Keeps the first non-empty string for each key so a `completed` record
    /// that dropped `streamContent` does not wipe the patch collected on start.
    private static func mergePreferringNonEmpty(_ old: JSONValue?, _ new: JSONValue) -> JSONValue {
        guard var dict = new.objectValue else { return new }
        guard let previous = old?.objectValue else { return new }
        for (key, value) in previous {
            if dict[key] == nil {
                dict[key] = value
                continue
            }
            if let current = dict[key]?.stringValue, current.isEmpty,
               let kept = value.stringValue, !kept.isEmpty {
                dict[key] = value
            }
        }
        return .object(dict)
    }

    private static func cursorResultText(_ result: JSONValue?) -> String {
        guard let result else { return "" }
        if let text = result.stringValue { return text }
        guard let object = result.objectValue else { return "" }
        if let error = object["error"]?.stringValue { return error }
        // A refused call carries no error string — just the arguments it would
        // have used. Reported verbatim it looks like an empty success, which is
        // how "Cursor blocked every command" showed up as a blank row.
        if let rejected = object["rejected"] {
            let subject = rejected["command"]?.stringValue
                ?? rejected["path"]?.stringValue
                ?? ""
            let reason = rejected["reason"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                ?? "no approval channel is available in this CLI"
            return subject.isEmpty
                ? "Blocked by Cursor: \(reason)."
                : "Blocked by Cursor: `\(subject)` (\(reason))."
        }
        if let success = object["success"] {
            if let text = success.stringValue { return text }
            for key in ["content", "output", "stdout", "text", "diff", "patch"] {
                if let value = success[key]?.stringValue, !value.isEmpty { return value }
            }
            // A shell call reports its streams separately; an exit code with no
            // output at all is still worth showing as the result.
            let streams = ["stdout", "stderr"]
                .compactMap { success[$0]?.stringValue }
                .filter { !$0.isEmpty }
            if !streams.isEmpty { return streams.joined(separator: "\n") }
            if let code = success["exitCode"]?.intValue { return "exited \(code)" }
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
            closeCurrentTextSegment(turnID: turnID, to: &output)
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
        // that has no `timestamp_ms` and the whole concatenated text. Partials
        // accumulate as deltas into the *current* text segment; a tool call
        // closes that segment so later narration is a new row after the tools.
        // Treating every partial as a completed block (the previous behaviour)
        // appended one row per word — the "each word on its own line" bug.
        let isPartial = message["timestamp_ms"] != nil
        if isPartial { append(status: .requesting, to: &output) }

        // A bare `delta` field is an alternate shape; keep handling it.
        if let delta = message["delta"]?.stringValue ?? body["delta"]?.stringValue,
           !delta.isEmpty {
            appendTextDelta(turnID: turnID, text: delta, to: &output)
            return
        }

        guard let content = body["content"]?.arrayValue else {
            if let text = body["content"]?.stringValue, !text.isEmpty {
                if isPartial {
                    appendTextDelta(turnID: turnID, text: text, to: &output)
                } else {
                    completeAssistantText(turnID: turnID, text: text, to: &output)
                }
            }
            return
        }

        for (index, block) in content.enumerated() {
            switch block["type"]?.stringValue {
            case "text":
                guard let text = block["text"]?.stringValue, !text.isEmpty else { break }
                if isPartial {
                    appendTextDelta(turnID: turnID, text: text, to: &output)
                } else {
                    completeAssistantText(turnID: turnID, text: text, to: &output)
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
                let isNew = reportedToolCallIDs.insert(toolCallID).inserted
                if isNew {
                    closeCurrentTextSegment(turnID: turnID, to: &output)
                } else {
                    break
                }
                let raw = block["input"] ?? block["arguments"] ?? .object([:])
                let input = SubagentBrief.isSubagentTool(name)
                    ? SubagentBrief.normalized(raw)
                    : raw
                toolInputs[toolCallID] = input
                output.events.append(.toolCall(ToolCall(
                    turnID: turnID,
                    id: toolCallID,
                    name: name,
                    displayName: ClaudeToolSemantics.displayName(tool: name, input: input),
                    input: input
                )))
                append(status: .runningTool, to: &output)
                if Self.isPlanTool(name) {
                    // One-shot tool_use inside an assistant message has no
                    // started/completed pair; advertise ready if the body is here.
                    emitPlanProposal(from: input, turnID: turnID, ready: true, to: &output)
                }

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
        promotePendingPlanIfNeeded(turnID: turnID, to: &output)

        if let usage = message["usage"] {
            output.events.append(.usage(UsageReport(
                turnID: turnID,
                inputTokens: usage["input_tokens"]?.intValue ?? 0,
                outputTokens: usage["output_tokens"]?.intValue ?? 0,
                cacheReadTokens: usage["cache_read_input_tokens"]?.intValue ?? 0
            )))
        }

        let isError = message["is_error"]?.boolValue ?? false
        // Defensive tag strip; see `closeTurn`.
        let (summary, narration) = NarrationTag.extract(from: message["result"]?.stringValue ?? "")
        output.events.append(.turnCompleted(TurnResult(
            turnID: turnID,
            outcome: isError ? .failed : .completed,
            summary: summary.isEmpty ? nil : summary,
            narration: narration,
            duration: message["duration_ms"]?.doubleValue.map { $0 / 1000 },
            errorMessage: isError && !summary.isEmpty ? summary : nil
        )))
        append(status: isError ? .failed : .idle, to: &output)
        currentTurnID = nil
        didReportResult = true
    }

    // MARK: - Assistant text segments

    private func currentTextBlockID(turnID: TurnID) -> BlockID {
        BlockID(rawValue: "\(turnID.rawValue)#text-\(textSegment)")
    }

    /// Cursor sometimes sends a fragment (`" there"`) and sometimes a snapshot
    /// of the block so far (`"Hello there"`). If the new text already has the
    /// accumulated prefix, emit only the suffix so the row does not duplicate.
    private mutating func appendTextDelta(
        turnID: TurnID,
        text: String,
        to output: inout Output
    ) {
        let blockID = currentTextBlockID(turnID: turnID)
        let previous = streamedText[blockID] ?? ""
        let delta: String
        if !previous.isEmpty, text.hasPrefix(previous), text.count >= previous.count {
            delta = String(text.dropFirst(previous.count))
            streamedText[blockID] = text
        } else {
            delta = text
            streamedText[blockID, default: ""] += text
        }
        guard !delta.isEmpty else { return }
        output.events.append(.textDelta(BlockDelta(
            turnID: turnID, blockID: blockID, text: delta
        )))
    }

    private mutating func closeCurrentTextSegment(turnID: TurnID, to output: inout Output) {
        let blockID = currentTextBlockID(turnID: turnID)
        let text = streamedText.removeValue(forKey: blockID) ?? ""
        guard !text.isEmpty else { return }
        emittedAssistantText += text
        output.events.append(.blockCompleted(BlockCompleted(
            turnID: turnID, blockID: blockID, kind: .text, text: text
        )))
        textSegment += 1
    }

    /// Completes the current segment without treating a final whole-turn
    /// snapshot as a rewrite of the first row.
    private mutating func completeAssistantText(
        turnID: TurnID,
        text: String,
        to output: inout Output
    ) {
        let blockID = currentTextBlockID(turnID: turnID)
        let accumulated = streamedText[blockID] ?? ""
        let combinedPrior = emittedAssistantText + accumulated

        if text == accumulated {
            streamedText.removeValue(forKey: blockID)
            emittedAssistantText += text
            output.events.append(.blockCompleted(BlockCompleted(
                turnID: turnID, blockID: blockID, kind: .text, text: text
            )))
            return
        }

        if text == combinedPrior || text == emittedAssistantText {
            closeCurrentTextSegment(turnID: turnID, to: &output)
            return
        }

        if text.hasPrefix(combinedPrior) {
            let tail = String(text.dropFirst(combinedPrior.count))
            closeCurrentTextSegment(turnID: turnID, to: &output)
            let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let answerID = currentTextBlockID(turnID: turnID)
            emittedAssistantText += tail
            output.events.append(.blockCompleted(BlockCompleted(
                turnID: turnID, blockID: answerID, kind: .text, text: tail
            )))
            return
        }

        if !accumulated.isEmpty, text.hasPrefix(accumulated) {
            streamedText.removeValue(forKey: blockID)
            emittedAssistantText += text
            output.events.append(.blockCompleted(BlockCompleted(
                turnID: turnID, blockID: blockID, kind: .text, text: text
            )))
            return
        }

        closeCurrentTextSegment(turnID: turnID, to: &output)
        let answerID = currentTextBlockID(turnID: turnID)
        emittedAssistantText += text
        output.events.append(.blockCompleted(BlockCompleted(
            turnID: turnID, blockID: answerID, kind: .text, text: text
        )))
    }

    /// Turns text that only ever arrived as deltas into completed blocks.
    ///
    /// Without this a session that streams but never sends a final content
    /// block would persist nothing: the deltas are for live rendering only.
    private mutating func flushStreamedBlocks(turnID: TurnID, to output: inout Output) {
        for (blockID, text) in streamedText.sorted(by: { $0.key.rawValue < $1.key.rawValue })
        where !text.isEmpty {
            let kind: BlockCompleted.Kind =
                blockID.rawValue.contains("#thinking-") ? .thinking : .text
            // Flushed prose is part of the turn's final report just as much as
            // a closed segment; without this the exit-path summary misses any
            // text that only ever arrived as deltas.
            if kind == .text { emittedAssistantText += text }
            output.events.append(.blockCompleted(BlockCompleted(
                turnID: turnID, blockID: blockID, kind: kind, text: text
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
        toolInputs.removeAll()
        thinkingSegment = 0
        textSegment = 0
        emittedAssistantText = ""
        didReportResult = false
        lastPlanMarkdown = nil
        lastPlanReady = false
        didAdvertisePlanReady = false
        output.events.append(.turnStarted(TurnStarted(turnID: turnID, model: model)))
        return turnID
    }

    private mutating func append(status newStatus: AgentStatus, to output: inout Output) {
        guard newStatus != status else { return }
        status = newStatus
        output.events.append(.statusChanged(newStatus))
    }
}
