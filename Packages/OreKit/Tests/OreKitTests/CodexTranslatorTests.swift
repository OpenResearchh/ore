import Foundation
import Testing

@testable import OreHarness
@testable import OreProtocol

/// The point of the normalized event stream is that the app can't tell which
/// CLI produced a transcript. These tests assert the Codex driver lands on the
/// same shapes the Claude Code driver does, from bytes a real CLI emitted.
struct CodexTranslatorTests {
    @Test func threadStartProducesSessionStartedExactlyOnce() {
        // Codex announces the thread twice — as the reply to `thread/start`
        // and again as a notification. Two events would read as two sessions.
        let events = CodexTranscriptReplay.events(
            transcript: Fixtures.load("codex-simple-text")
        )
        let started = events.compactMap { event -> SessionStarted? in
            if case .sessionStarted(let started) = event { return started }
            return nil
        }

        #expect(started.count == 1)
        #expect(started.first?.harness == .codex)
        #expect(started.first?.providerSessionID.isEmpty == false)
        #expect(started.first?.harnessVersion != nil)
    }

    @Test func streamedTextIsDeliveredAsDeltasThenOneCompletedBlock() {
        let events = CodexTranscriptReplay.events(
            transcript: Fixtures.load("codex-simple-text")
        )
        let deltas = events.compactMap { event -> BlockDelta? in
            if case .textDelta(let delta) = event { return delta }
            return nil
        }
        let completed = events.compactMap { event -> BlockCompleted? in
            if case .blockCompleted(let block) = event, block.kind == .text { return block }
            return nil
        }

        #expect(!deltas.isEmpty)
        #expect(completed.count == 1)
        // Deltas are increments and must reassemble into the final block.
        let assembled = deltas.filter { $0.blockID == completed[0].blockID }
            .map(\.text).joined()
        #expect(assembled == completed[0].text)
        #expect(completed[0].text.contains("hello ore"))
    }

    @Test func turnsOpenOnceAndCloseWithAnOutcome() {
        let events = CodexTranscriptReplay.events(
            transcript: Fixtures.load("codex-simple-text")
        )
        let started = events.filter { if case .turnStarted = $0 { return true }; return false }
        let completed = events.compactMap { event -> TurnResult? in
            if case .turnCompleted(let result) = event { return result }
            return nil
        }

        #expect(started.count == 1)
        #expect(completed.count == 1)
        #expect(completed[0].outcome == .completed)
        #expect(completed[0].duration ?? 0 > 0)
    }

    @Test func shellCommandsBecomeToolCallsWithResults() {
        // Codex calls it a `commandExecution` item; the transcript shows the
        // same thing Claude's `Bash` tool shows.
        let events = CodexTranscriptReplay.events(transcript: Fixtures.load("codex-tool-use"))

        let calls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let call) = event { return call }
            return nil
        }
        let results = events.compactMap { event -> ToolResult? in
            if case .toolResult(let result) = event { return result }
            return nil
        }

        #expect(calls.contains { $0.name == "Bash" })
        #expect(calls.first?.displayName?.isEmpty == false)
        #expect(!results.isEmpty)
        // Every result must belong to a call we announced.
        let callIDs = Set(calls.map(\.id))
        #expect(results.allSatisfy { callIDs.contains($0.toolCallID) })
    }

    @Test func toolCallsAreAnnouncedOnlyOnceAcrossTheItemLifecycle() {
        // `item/started` and `item/completed` both carry the whole item.
        let events = CodexTranscriptReplay.events(transcript: Fixtures.load("codex-tool-use"))
        let ids = events.compactMap { event -> ToolCallID? in
            if case .toolCall(let call) = event { return call.id }
            return nil
        }
        #expect(ids.count == Set(ids).count)
    }

    @Test func fileEditsBecomeToolCallsNamedForWhatTheyTouch() {
        let events = CodexTranscriptReplay.events(transcript: Fixtures.load("codex-file-change"))
        let edits = events.compactMap { event -> ToolCall? in
            if case .toolCall(let call) = event, call.name == "Edit" { return call }
            return nil
        }

        #expect(!edits.isEmpty)
        #expect(edits.contains { $0.displayName == "ore.txt" })
    }

    @Test func usageReportsTheCurrentContextAndItsWindow() {
        // On the first request Codex's total and last buckets are identical.
        let events = CodexTranscriptReplay.events(
            transcript: Fixtures.load("codex-simple-text")
        )
        let usage = events.compactMap { event -> UsageReport? in
            if case .usage(let usage) = event { return usage }
            return nil
        }

        #expect(!usage.isEmpty)
        // Codex's cachedInputTokens is a subset of inputTokens. The normalized
        // buckets must be exclusive or the UI double-counts 5,504 tokens here.
        #expect(usage.last?.inputTokens == 11_955)
        #expect(usage.last?.cacheReadTokens == 5_504)
        #expect(usage.last?.totalContextTokens == 17_465)
        #expect(usage.last?.contextWindow ?? 0 > 0)
        if let last = usage.last {
            #expect(last.totalContextTokens <= (last.contextWindow ?? .max))
        }
        // Subscription sessions are not billed per token.
        #expect(usage.allSatisfy { $0.costUSD == nil })
    }

    @Test func cumulativeBillingDoesNotInflateContextMeter() {
        var translator = CodexTranslator(sessionID: SessionID.generate())
        let params: JSONValue = .object([
            "tokenUsage": .object([
                "total": .object([
                    "inputTokens": .integer(180_000),
                    "cachedInputTokens": .integer(120_000),
                    "outputTokens": .integer(20_000),
                ]),
                "last": .object([
                    "inputTokens": .integer(42_000),
                    "cachedInputTokens": .integer(30_000),
                    "outputTokens": .integer(1_800),
                ]),
                "modelContextWindow": .integer(258_400),
            ]),
        ])
        let reports = translator.translate(
            method: "thread/tokenUsage/updated",
            params: params
        ).events.compactMap { event -> UsageReport? in
            if case .usage(let report) = event { return report }
            return nil
        }
        #expect(reports.last?.totalContextTokens == 43_800)
        #expect(reports.last?.cacheReadTokens == 30_000)
    }

    @Test func rateLimitsAreSurfaced() {
        let events = CodexTranscriptReplay.events(
            transcript: Fixtures.load("codex-simple-text")
        )
        let limits = events.compactMap { event -> RateLimitReport? in
            if case .rateLimit(let report) = event { return report }
            return nil
        }
        #expect(!limits.isEmpty)
        #expect(limits.last?.status == .allowed)
    }

    @Test func statusOnlyChangesOnTransitions() {
        let events = CodexTranscriptReplay.events(transcript: Fixtures.load("codex-tool-use"))
        let statuses = events.compactMap { event -> AgentStatus? in
            if case .statusChanged(let status) = event { return status }
            return nil
        }
        #expect(!statuses.isEmpty)
        #expect(zip(statuses, statuses.dropFirst()).allSatisfy { $0 != $1 })
    }

    @Test func turnCompletionCarriesSummaryAndStrippedNarration() {
        // Codex's `turn/completed` carries no text of its own, so the last
        // completed agent message must become the summary — with the narration
        // tag stripped from every surface and carried on the result instead.
        var translator = CodexTranslator(sessionID: SessionID(rawValue: "test"))
        _ = translator.translate(
            method: "turn/started", params: .object(["turn": .object(["id": .string("t1")])])
        )
        let deltas = [
            translator.translate(method: "item/agentMessage/delta", params: .object([
                "itemId": .string("i1"), "delta": .string("Done.\n<narr"),
            ])),
            translator.translate(method: "item/agentMessage/delta", params: .object([
                "itemId": .string("i1"), "delta": .string("ation>I fixed the test.</narration>"),
            ])),
        ].flatMap(\.events).compactMap { event -> String? in
            if case .textDelta(let delta) = event { return delta.text }
            return nil
        }
        #expect(!deltas.joined().contains("<"), "no tag fragment may flash in live text")

        let completion = translator.translate(method: "item/completed", params: .object([
            "item": .object([
                "id": .string("i1"),
                "type": .string("agentMessage"),
                "text": .string("Done.\n<narration>I fixed the test.</narration>"),
            ]),
        ]))
        let blocks = completion.events.compactMap { event -> String? in
            if case .blockCompleted(let block) = event, block.kind == .text { return block.text }
            return nil
        }
        #expect(blocks == ["Done."])

        let output = translator.translate(method: "turn/completed", params: .object([
            "turn": .object(["status": .string("completed")]),
        ]))
        guard case .turnCompleted(let result)? = output.events.first(where: {
            if case .turnCompleted = $0 { return true }
            return false
        }) else {
            Issue.record("no turnCompleted event")
            return
        }
        #expect(result.summary == "Done.")
        #expect(result.narration == "I fixed the test.")
    }

    @Test func unknownNotificationsAreIgnoredRatherThanFatal() {
        // Codex emits a large and growing set of notifications; a CLI upgrade
        // must not be able to break the transcript.
        var translator = CodexTranslator(sessionID: SessionID(rawValue: "test"))
        #expect(translator.translate(method: "thread/realtime/started", params: nil).isEmpty)
        #expect(translator.translate(method: "brand/new/thing", params: .object([:])).isEmpty)
        #expect(translator.translate(method: "item/completed", params: nil).isEmpty)
    }

    @Test func approvalRequestsBecomeTheSamePermissionEventClaudeProduces() {
        // The permission UI is written once; it must not learn two vocabularies.
        var translator = CodexTranslator(sessionID: SessionID(rawValue: "test"))

        let command = translator.permissionRequest(
            method: "item/commandExecution/requestApproval",
            params: .object([
                "itemId": .string("item-1"),
                "command": .string("rm -rf build"),
                "cwd": .string("/tmp/ws"),
            ]),
            requestID: "req-1"
        )
        #expect(command?.toolName == "Bash")
        #expect(command?.summary == "rm -rf build")
        #expect(command?.id == PermissionRequestID(rawValue: "req-1"))
        #expect(command?.toolCallID == ToolCallID(rawValue: "item-1"))
        #expect(command?.suggestions.contains { $0.kind == .setMode } == true)

        let edit = translator.permissionRequest(
            method: "item/fileChange/requestApproval",
            params: .object([
                "itemId": .string("item-2"),
                "changes": .object(["/tmp/ws/App.swift": .object([:])]),
            ]),
            requestID: "req-2"
        )
        #expect(edit?.toolName == "Edit")
        #expect(edit?.summary == "App.swift")
    }

    @Test func approvalDecisionsUseEachMethodsOwnVocabulary() {
        // The item-scoped methods want accept/decline; the legacy ones want
        // approved/denied. Sending the wrong word is silently rejected.
        #expect(CodexApprovalDecision.value(
            for: .allow, method: "item/commandExecution/requestApproval"
        ) == "accept")
        #expect(CodexApprovalDecision.value(
            for: .deny(reason: "no"), method: "item/fileChange/requestApproval"
        ) == "decline")
        #expect(CodexApprovalDecision.value(
            for: .allow, method: "execCommandApproval"
        ) == "approved")
        #expect(CodexApprovalDecision.value(
            for: .deny(reason: "no"), method: "applyPatchApproval"
        ) == "denied")
    }

    @Test func questionsKeepTheirIDsSoAnswersCanBeRoutedBack() {
        // The answer payload is a map keyed by question id; a generated id
        // would be silently dropped by the agent.
        var translator = CodexTranslator(sessionID: SessionID(rawValue: "test"))
        let questions = translator.question(
            params: .object([
                "itemId": .string("item-9"),
                "questions": .array([.object([
                    "id": .string("q-branch"),
                    "question": .string("Which base branch?"),
                    "options": .array([
                        .object(["label": .string("main"), "description": .string("default")]),
                        .object(["label": .string("develop")]),
                    ]),
                ])]),
            ]),
            requestID: "req-3"
        )

        #expect(questions.count == 1)
        #expect(questions[0].id == QuestionID(rawValue: "q-branch"))
        #expect(questions[0].prompt == "Which base branch?")
        #expect(questions[0].options.map(\.label) == ["main", "develop"])
    }

    @Test func capabilitiesDeclareWhatCodexActuallySupports() {
        // The UI degrades per harness by reading this, so it has to be honest.
        let capabilities = CodexHarness().capabilities
        #expect(capabilities.supportsSteering)
        #expect(capabilities.supportsSessionFork)
        #expect(capabilities.permissionModel == .interactiveCallback)
        // Codex has no plan-approval surface, and its sandbox posture is set
        // per turn rather than by a live control message.
        #expect(!capabilities.supportsPlanMode)
        #expect(!capabilities.supportsRuntimePermissionModeChange)
    }

    @Test func aDelegationToolLandsOnTheSubagentRow() {
        // codex app-server has no subagent item type, so a handoff can only
        // arrive as an MCP tool. Naming it `Task` and aliasing its arguments is
        // what lets the transcript say what the child was created for.
        var translator = CodexTranslator(sessionID: SessionID(rawValue: "test"))
        _ = translator.translate(
            method: "turn/started", params: .object(["turn": .object(["id": .string("t1")])])
        )
        let events = translator.translate(
            method: "item/started",
            params: .object(["item": .object([
                "id": .string("i1"),
                "type": .string("mcpToolCall"),
                "tool": .string("spawn_agent"),
                "server": .string("agents"),
                "arguments": .object([
                    "instructions": .string("Audit the migration for missing indexes."),
                    "title": .string("Index audit"),
                    "agentType": .string("reviewer"),
                ]),
            ])])
        ).events
        let call = events.compactMap { event -> ToolCall? in
            if case .toolCall(let call) = event { return call }
            return nil
        }.first
        #expect(call?.name == "Task")
        #expect(call?.displayName == "Index audit")
        #expect(call?.input["prompt"]?.stringValue == "Audit the migration for missing indexes.")
        #expect(call?.input["subagent_type"]?.stringValue == "reviewer")
        // Codex sends no parent link, so the row stays flat.
        #expect(call?.parentToolCallID == nil)
    }

    @Test func anOrdinaryMCPToolKeepsItsOwnNameAndArguments() {
        var translator = CodexTranslator(sessionID: SessionID(rawValue: "test"))
        _ = translator.translate(
            method: "turn/started", params: .object(["turn": .object(["id": .string("t1")])])
        )
        let events = translator.translate(
            method: "item/started",
            params: .object(["item": .object([
                "id": .string("i2"),
                "type": .string("mcpToolCall"),
                "tool": .string("search_docs"),
                "server": .string("docs"),
                "arguments": .object(["title": .string("Indexes")]),
            ])])
        ).events
        let call = events.compactMap { event -> ToolCall? in
            if case .toolCall(let call) = event { return call }
            return nil
        }.first
        #expect(call?.name == "search_docs")
        #expect(call?.displayName == "docs")
        #expect(call?.input["description"] == nil)
    }

    @Test func nestedJSONTurnErrorsUnwrapToTheHumanMessage() {
        var translator = CodexTranslator(sessionID: SessionID(rawValue: "test"))
        _ = translator.translate(
            method: "turn/started", params: .object(["turn": .object(["id": .string("t1")])])
        )
        let json = #"{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The 'gpt-5.6-sol' model requires a newer version of Codex. Please upgrade to the latest app or CLI and try again."}}"#
        let output = translator.translate(method: "turn/completed", params: .object([
            "turn": .object([
                "status": .string("failed"),
                "error": .object(["message": .string(json)]),
            ]),
        ]))
        guard case .turnCompleted(let result)? = output.events.first(where: {
            if case .turnCompleted = $0 { return true }
            return false
        }) else {
            Issue.record("no turnCompleted event")
            return
        }
        #expect(result.outcome == .failed)
        #expect(result.errorMessage?.contains("requires a newer version of Codex") == true)
        #expect(result.errorMessage?.contains("\"status\"") != true)
    }

    @Test func errorNotificationsClassifyACLIUpgrade() {
        var translator = CodexTranslator(sessionID: SessionID(rawValue: "test"))
        let json = #"{"type":"error","status":400,"error":{"message":"Please upgrade to the latest app or CLI and try again."}}"#
        let output = translator.translate(
            method: "error",
            params: .object(["message": .string(json)])
        )
        guard case .sessionError(let error)? = output.events.first(where: {
            if case .sessionError = $0 { return true }
            return false
        }) else {
            Issue.record("no sessionError event")
            return
        }
        #expect(error.kind == .protocolMismatch)
        #expect(error.message.contains("upgrade to the latest"))
        #expect(!error.message.contains("\"status\""))
    }
}
