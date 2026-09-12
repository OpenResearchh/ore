import Foundation
import OreProtocol
import OreSupport

/// Converts `codex app-server` notifications into `AgentEvent`s.
///
/// Same shape as the Claude Code translator, and for the same reason: a pure,
/// synchronous mapping that a recorded session can be replayed through, so a
/// protocol change surfaces as a failing diff in CI instead of as a broken
/// transcript in front of a user.
struct CodexTranslator {
    struct Output {
        var events: [AgentEvent] = []
        var isEmpty: Bool { events.isEmpty }
    }

    let sessionID: SessionID

    private(set) var threadID: String?
    private(set) var currentTurnID: TurnID?
    /// Codex's own turn id, needed to interrupt or steer the right turn.
    private(set) var providerTurnID: String?

    private var status: AgentStatus = .idle
    private var reportedItemIDs: Set<String> = []
    private var toolNames: [ToolCallID: String] = [:]
    private var model: String?
    private var cliVersion: String?
    private var workingDirectory: String = ""
    /// Per-item suppressors keeping the narration tag out of live deltas.
    private var narrationFilters: [String: NarrationTagStreamFilter] = [:]
    /// The last completed assistant message, tag already stripped. Codex's
    /// `turn/completed` carries no text of its own, so this is what fills
    /// `TurnResult.summary` — Claude gets the same for free from `result`.
    private var lastAssistantText: String?
    /// Narration stripped from a completed message, held for `turn/completed`.
    private var pendingNarration: String?

    init(sessionID: SessionID) {
        self.sessionID = sessionID
    }

    // MARK: - Entry point

    mutating func translate(method: String, params: JSONValue?) -> Output {
        var output = Output()
        let params = params ?? .object([:])

        switch method {
        case "thread/started":
            applyThread(params["thread"], to: &output)

        case "thread/status/changed":
            switch params["status"]?["type"]?.stringValue {
            case "idle": append(status: .idle, to: &output)
            case "active": append(status: .requesting, to: &output)
            default: break
            }

        case "turn/started":
            guard let turn = params["turn"] else { break }
            providerTurnID = turn["id"]?.stringValue
            let turnID = TurnID.generate()
            currentTurnID = turnID
            output.events.append(.turnStarted(TurnStarted(turnID: turnID, model: model)))
            append(status: .requesting, to: &output)

        case "item/agentMessage/delta":
            guard let delta = params["delta"]?.stringValue, !delta.isEmpty,
                  let itemID = params["itemId"]?.stringValue
            else { break }
            // Assistant text may end in a narration tag; keep it from flashing
            // in the live transcript. The completed item is the authoritative
            // strip.
            let visible = narrationFilters[itemID, default: NarrationTagStreamFilter()]
                .filter(delta)
            guard !visible.isEmpty else { break }
            output.events.append(.textDelta(BlockDelta(
                turnID: ensureTurn(&output), blockID: BlockID(rawValue: itemID), text: visible
            )))

        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            guard let delta = params["delta"]?.stringValue, !delta.isEmpty,
                  let itemID = params["itemId"]?.stringValue
            else { break }
            append(status: .thinking, to: &output)
            output.events.append(.thinkingDelta(BlockDelta(
                turnID: ensureTurn(&output), blockID: BlockID(rawValue: itemID), text: delta
            )))

        case "item/started":
            applyItem(params["item"], completed: false, to: &output)

        case "item/completed":
            applyItem(params["item"], completed: true, to: &output)

        case "turn/plan/updated", "item/plan/delta":
            applyPlan(params, ready: false, to: &output)

        case "thread/tokenUsage/updated":
            applyUsage(params["tokenUsage"], to: &output)

        case "account/rateLimits/updated":
            applyRateLimits(params["rateLimits"], to: &output)

        case "turn/completed":
            applyTurnCompleted(params["turn"], to: &output)

        case "error":
            let message = ProviderErrorCopy.unwrap(
                params["message"]?.stringValue ?? params["error"]?.description ?? "The agent reported an error."
            )
            output.events.append(.sessionError(SessionError(
                kind: ProviderErrorCopy.sessionKind(for: message),
                message: message,
                isRecoverable: true
            )))

        default:
            // Codex emits a large and growing set of notifications (MCP
            // startup, remote control, realtime audio). Ignoring what we don't
            // model is what lets a CLI upgrade land without breaking us.
            break
        }
        return output
    }

    // MARK: - Thread

    private mutating func applyThread(_ thread: JSONValue?, to output: inout Output) {
        guard let thread, let id = thread["id"]?.stringValue else { return }
        // The thread is announced twice — once as the reply to `thread/start`
        // and again as a `thread/started` notification. Reporting both would
        // read as two sessions and reset the transcript.
        guard threadID != id else { return }
        threadID = id
        cliVersion = thread["cliVersion"]?.stringValue
        workingDirectory = thread["cwd"]?.stringValue ?? workingDirectory
        model = thread["model"]?.stringValue ?? model

        output.events.append(.sessionStarted(SessionStarted(
            sessionID: sessionID,
            providerSessionID: id,
            harness: .codex,
            model: model,
            workingDirectory: workingDirectory,
            harnessVersion: cliVersion
        )))
    }

    // MARK: - Items

    /// Codex models everything the agent does as a "thread item" with a
    /// lifecycle. Text and reasoning become blocks; anything that acts on the
    /// world becomes a tool call, so the transcript reads the same regardless
    /// of which harness produced it.
    private mutating func applyItem(
        _ item: JSONValue?,
        completed: Bool,
        to output: inout Output
    ) {
        guard let item,
              let type = item["type"]?.stringValue,
              let itemID = item["id"]?.stringValue
        else { return }
        let turnID = ensureTurn(&output)

        switch type {
        case "userMessage", "hookPrompt":
            // Our own message echoed back.
            break

        case "agentMessage":
            guard completed else { break }
            let (body, narration) = NarrationTag.extract(from: item["text"]?.stringValue ?? "")
            if let narration { pendingNarration = narration }
            if !body.isEmpty { lastAssistantText = body }
            narrationFilters.removeValue(forKey: itemID)
            output.events.append(.blockCompleted(BlockCompleted(
                turnID: turnID,
                blockID: BlockID(rawValue: itemID),
                kind: .text,
                text: body
            )))

        case "reasoning":
            guard completed else { break }
            let text = item["summary"]?.arrayValue?.compactMap(\.stringValue).joined(separator: "\n")
                ?? item["content"]?.arrayValue?.compactMap(\.stringValue).joined(separator: "\n")
                ?? ""
            guard !text.isEmpty else { break }
            output.events.append(.blockCompleted(BlockCompleted(
                turnID: turnID, blockID: BlockID(rawValue: itemID), kind: .thinking, text: text
            )))

        case "plan":
            // Readable body only — whitespace or JSON debris is not a plan.
            guard completed, let text = item["text"]?.stringValue,
                  PlanProposalPolicy.isReadyMarkdown(text)
            else { break }
            output.events.append(.planUpdated(PlanUpdate(
                turnID: turnID,
                content: .proposal(markdown: text, permissionRequestID: nil),
                isReady: true
            )))

        case "commandExecution":
            applyToolItem(
                item,
                itemID: itemID,
                turnID: turnID,
                completed: completed,
                name: "Bash",
                displayName: item["command"]?.stringValue,
                input: .object([
                    "command": item["command"] ?? .null,
                    "cwd": item["cwd"] ?? .null,
                ]),
                resultText: item["aggregatedOutput"]?.stringValue ?? "",
                isError: (item["exitCode"]?.intValue ?? 0) != 0,
                to: &output
            )

        case "fileChange":
            let paths = item["changes"]?.arrayValue?
                .compactMap { $0["path"]?.stringValue ?? $0["file"]?.stringValue } ?? []
            applyToolItem(
                item,
                itemID: itemID,
                turnID: turnID,
                completed: completed,
                name: "Edit",
                displayName: paths.first.map { FilePath.lastComponent($0) },
                input: item["changes"] ?? .object([:]),
                resultText: paths.isEmpty ? "" : paths.joined(separator: "\n"),
                isError: item["status"]?.stringValue == "failed",
                to: &output
            )

        case "mcpToolCall", "dynamicToolCall":
            // The item types above are the whole of codex app-server's
            // vocabulary: there is no subagent item, so a handoff can only
            // reach us as an MCP or dynamic tool. Naming it `Task` puts it on
            // the transcript's subagent row, which says what the child was
            // created for. It stays flat — Codex never sends a parent link, so
            // there are no child rows to nest under it.
            let rawName = item["tool"]?.stringValue ?? type
            let isSubagent = SubagentBrief.isSubagentTool(rawName)
            let arguments = item["arguments"] ?? .object([:])
            let input = isSubagent ? SubagentBrief.normalized(arguments) : arguments
            applyToolItem(
                item,
                itemID: itemID,
                turnID: turnID,
                completed: completed,
                name: isSubagent ? "Task" : rawName,
                displayName: isSubagent
                    ? SubagentBrief.label(from: input)
                    : (item["server"]?.stringValue ?? item["namespace"]?.stringValue),
                input: input,
                resultText: toolResultText(item),
                isError: item["error"] != nil && item["error"]?.isNull == false,
                to: &output
            )

        case "webSearch":
            applyToolItem(
                item,
                itemID: itemID,
                turnID: turnID,
                completed: completed,
                name: "WebSearch",
                displayName: item["query"]?.stringValue,
                input: .object(["query": item["query"] ?? .null]),
                resultText: "",
                isError: false,
                to: &output
            )

        default:
            break
        }
    }

    private mutating func applyToolItem(
        _ item: JSONValue,
        itemID: String,
        turnID: TurnID,
        completed: Bool,
        name: String,
        displayName: String?,
        input: JSONValue,
        resultText: String,
        isError: Bool,
        to output: inout Output
    ) {
        let toolCallID = ToolCallID(rawValue: itemID)

        // `item/started` and `item/completed` both carry the whole item, so the
        // call is announced once and only its result is added on completion.
        if !reportedItemIDs.contains(itemID) {
            reportedItemIDs.insert(itemID)
            toolNames[toolCallID] = name
            output.events.append(.toolCall(ToolCall(
                turnID: turnID,
                id: toolCallID,
                name: name,
                displayName: displayName,
                input: input
            )))
            append(status: .runningTool, to: &output)
        }

        guard completed else { return }
        output.events.append(.toolResult(ToolResult(
            turnID: turnID,
            toolCallID: toolCallID,
            isError: isError,
            text: resultText
        )))
        append(status: .requesting, to: &output)
    }

    // MARK: - Plans, usage, completion

    private mutating func applyPlan(_ params: JSONValue, ready: Bool, to output: inout Output) {
        let turnID = ensureTurn(&output)
        if let steps = params["plan"]?.arrayValue ?? params["steps"]?.arrayValue {
            let items = steps.compactMap { entry -> TodoItem? in
                guard let text = entry["step"]?.stringValue ?? entry["text"]?.stringValue
                else { return nil }
                let status: TodoItem.Status
                switch entry["status"]?.stringValue {
                case "completed": status = .completed
                case "in_progress", "inProgress": status = .inProgress
                default: status = .pending
                }
                return TodoItem(text: text, status: status)
            }
            guard !items.isEmpty else { return }
            output.events.append(.planUpdated(PlanUpdate(turnID: turnID, content: .todos(items))))
        } else if let text = params["delta"]?.stringValue ?? params["text"]?.stringValue,
                  !text.isEmpty {
            output.events.append(.planUpdated(PlanUpdate(
                turnID: turnID,
                content: .proposal(markdown: text, permissionRequestID: nil),
                isReady: ready && PlanProposalPolicy.isReadyMarkdown(text)
            )))
        }
    }

    private mutating func applyUsage(_ usage: JSONValue?, to output: inout Output) {
        guard let usage else { return }
        // Codex's `total` bucket is cumulative billing usage across requests,
        // not the number of tokens currently occupying the model's context.
        // The latest request's input (plus its output) is the useful context
        // estimate; accumulating every prior request makes the meter fill much
        // faster than the actual model window.
        let current = usage["last"] ?? usage["total"] ?? usage
        let providerInput = current["inputTokens"]?.intValue ?? 0
        let cachedInput = current["cachedInputTokens"]?.intValue ?? 0
        output.events.append(.usage(UsageReport(
            turnID: currentTurnID,
            // Codex reports cached input as a subset of input. UsageReport's
            // buckets are exclusive, so subtract it here; otherwise the context
            // meter counts a large cached prompt twice and can jump to ~90% on
            // the first turn.
            inputTokens: max(0, providerInput - cachedInput),
            outputTokens: current["outputTokens"]?.intValue ?? 0,
            cacheReadTokens: cachedInput,
            contextWindow: usage["modelContextWindow"]?.intValue
        )))
    }

    /// A failed MCP call commonly carries `result: null` beside a structured
    /// `error` object. Rendering the null first hid the useful error as the
    /// literal string "null"; prefer a non-null result, then unwrap the same
    /// provider error shapes used for turn failures.
    private func toolResultText(_ item: JSONValue) -> String {
        if let result = item["result"], !result.isNull {
            return result.stringValue ?? result.description
        }
        guard let error = item["error"], !error.isNull else { return "" }
        if let message = error["message"]?.stringValue, !message.isEmpty {
            return ProviderErrorCopy.unwrap(message)
        }
        if let nested = error["error"]?["message"]?.stringValue, !nested.isEmpty {
            return ProviderErrorCopy.unwrap(nested)
        }
        if let message = error.stringValue, !message.isEmpty {
            return ProviderErrorCopy.unwrap(message)
        }
        return ProviderErrorCopy.unwrap(error.description)
    }

    private mutating func applyRateLimits(_ limits: JSONValue?, to output: inout Output) {
        guard let limits else { return }
        let used = limits["primary"]?["usedPercent"]?.doubleValue ?? 0
        let status: RateLimitReport.Status
        if limits["rateLimitReachedType"]?.isNull == false {
            status = .exhausted
        } else if used >= 90 {
            status = .warning
        } else {
            status = .allowed
        }
        output.events.append(.rateLimit(RateLimitReport(
            status: status,
            window: limits["limitId"]?.stringValue,
            resetsAt: limits["primary"]?["resetsAt"]?.doubleValue
                .map { Date(timeIntervalSince1970: $0) }
        )))
    }

    private mutating func applyTurnCompleted(_ turn: JSONValue?, to output: inout Output) {
        let turnID = currentTurnID ?? TurnID.generate()
        let outcome: TurnResult.Outcome
        switch turn?["status"]?.stringValue {
        case "completed": outcome = .completed
        case "interrupted", "aborted", "cancelled": outcome = .interrupted
        case "failed": outcome = .failed
        default: outcome = .completed
        }

        output.events.append(.turnCompleted(TurnResult(
            turnID: turnID,
            outcome: outcome,
            summary: lastAssistantText,
            narration: pendingNarration,
            usage: nil,
            duration: turn?["durationMs"]?.doubleValue.map { $0 / 1000 },
            errorMessage: turnErrorMessage(turn?["error"])
        )))
        switch outcome {
        case .failed: append(status: .failed, to: &output)
        case .interrupted: append(status: .interrupted, to: &output)
        default: append(status: .idle, to: &output)
        }

        currentTurnID = nil
        providerTurnID = nil
        reportedItemIDs.removeAll(keepingCapacity: true)
        narrationFilters.removeAll(keepingCapacity: true)
        lastAssistantText = nil
        pendingNarration = nil
    }

    /// Codex sometimes puts OpenAI's JSON body in `error.message`, and
    /// sometimes the whole object. Either way the UI wants the inner sentence.
    private func turnErrorMessage(_ error: JSONValue?) -> String? {
        guard let error, !error.isNull else { return nil }
        if let message = error["message"]?.stringValue, !message.isEmpty {
            return ProviderErrorCopy.unwrap(message)
        }
        if let nested = error["error"]?["message"]?.stringValue, !nested.isEmpty {
            return ProviderErrorCopy.unwrap(nested)
        }
        if let message = error.stringValue, !message.isEmpty {
            return ProviderErrorCopy.unwrap(message)
        }
        let rendered = error.description
        return rendered.isEmpty ? nil : ProviderErrorCopy.unwrap(rendered)
    }

    // MARK: - Server requests

    /// Maps an approval request into a normalized permission request.
    ///
    /// Codex has several approval methods with different payloads; folding them
    /// into one event is what lets the permission UI be written once rather
    /// than per harness.
    mutating func permissionRequest(
        method: String,
        params: JSONValue?,
        requestID: String
    ) -> PermissionRequest? {
        let params = params ?? .object([:])
        var output = Output()
        let turnID = ensureTurn(&output)

        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            let argv = params["command"]?.arrayValue?.compactMap(\.stringValue)
            let command = params["command"]?.stringValue
                ?? argv?.joined(separator: " ")
                ?? ""
            var input: [String: JSONValue] = [
                "command": .string(command),
                "cwd": params["cwd"] ?? .null,
            ]
            // The joined string is for reading, and it loses the quoting that
            // marks `bash -lc 'a && b'` as one script argument. Keeping argv
            // lets the shell approval policy judge what will actually run
            // rather than a flattened guess at it.
            if let argv { input["argv"] = .array(argv.map { .string($0) }) }
            return PermissionRequest(
                turnID: turnID,
                id: PermissionRequestID(rawValue: requestID),
                toolCallID: params["itemId"]?.stringValue.map(ToolCallID.init(rawValue:)),
                toolName: "Bash",
                displayName: "Run command",
                summary: command,
                input: .object(input),
                suggestions: [PermissionSuggestion(
                    kind: .setMode,
                    title: "Allow for this session",
                    raw: .object(["decision": .string("acceptForSession")])
                )]
            )

        case "item/fileChange/requestApproval", "applyPatchApproval":
            let paths = params["changes"]?.objectValue?.keys.sorted()
                ?? params["changes"]?.arrayValue?.compactMap { $0["path"]?.stringValue }
                ?? []
            return PermissionRequest(
                turnID: turnID,
                id: PermissionRequestID(rawValue: requestID),
                toolCallID: params["itemId"]?.stringValue.map(ToolCallID.init(rawValue:)),
                toolName: "Edit",
                displayName: "Apply changes",
                summary: paths.isEmpty
                    ? params["reason"]?.stringValue
                    : paths.map { FilePath.lastComponent($0) }.joined(separator: ", "),
                input: params["changes"] ?? .object([:]),
                suggestions: [PermissionSuggestion(
                    kind: .setMode,
                    title: "Allow edits for this session",
                    raw: .object(["decision": .string("acceptForSession")])
                )]
            )

        case "item/permissions/requestApproval":
            return PermissionRequest(
                turnID: turnID,
                id: PermissionRequestID(rawValue: requestID),
                toolName: params["tool"]?.stringValue ?? "Permission",
                summary: params["reason"]?.stringValue,
                input: params
            )

        default:
            return nil
        }
    }

    mutating func question(params: JSONValue?, requestID: String) -> [AgentQuestion] {
        guard let questions = params?["questions"]?.arrayValue else { return [] }
        var output = Output()
        let turnID = ensureTurn(&output)

        return questions.enumerated().compactMap { offset, entry in
            guard let prompt = entry["question"]?.stringValue ?? entry["prompt"]?.stringValue
            else { return nil }
            let options = (entry["options"]?.arrayValue ?? []).compactMap { option in
                (option["label"]?.stringValue ?? option["text"]?.stringValue).map {
                    AgentQuestion.Option(label: $0, detail: option["description"]?.stringValue)
                }
            }
            // The answer map is keyed by the question's own id, so it has to
            // survive the round trip.
            let id = entry["id"]?.stringValue ?? "\(requestID)#\(offset)"
            return AgentQuestion(
                turnID: turnID,
                id: QuestionID(rawValue: id),
                toolCallID: params?["itemId"]?.stringValue.map(ToolCallID.init(rawValue:)),
                prompt: prompt,
                options: options
            )
        }
    }

    // MARK: - Helpers

    @discardableResult
    private mutating func ensureTurn(_ output: inout Output) -> TurnID {
        if let currentTurnID { return currentTurnID }
        let turnID = TurnID.generate()
        currentTurnID = turnID
        output.events.append(.turnStarted(TurnStarted(turnID: turnID, model: model)))
        return turnID
    }

    private mutating func append(status newStatus: AgentStatus, to output: inout Output) {
        guard newStatus != status else { return }
        status = newStatus
        output.events.append(.statusChanged(newStatus))
    }
}
