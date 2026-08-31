import Foundation
import Testing

@testable import OreHarness
@testable import OreProtocol

/// The translator is the part of the driver most exposed to CLI protocol churn,
/// so it's tested against bytes a real CLI actually produced rather than against
/// hand-written ideals.
struct ClaudeCodeTranslatorTests {
    @Test func sessionInitProducesSessionStarted() {
        let events = ClaudeCodeTranscriptReplay.events(transcript: Fixtures.load("simple-text"))

        guard case .sessionStarted(let started)? = events.first(where: {
            if case .sessionStarted = $0 { return true }
            return false
        }) else {
            Issue.record("no sessionStarted event")
            return
        }

        #expect(started.harness == .claudeCode)
        #expect(!started.providerSessionID.isEmpty)
        #expect(started.workingDirectory.hasSuffix("ore-probe"))
        #expect(started.availableTools.contains("Bash"))
        #expect(started.harnessVersion != nil)
    }

    @Test func streamedTextIsDeliveredAsDeltasThenOneCompletedBlock() {
        let events = ClaudeCodeTranscriptReplay.events(transcript: Fixtures.load("simple-text"))

        let deltas = events.compactMap { event -> BlockDelta? in
            if case .textDelta(let delta) = event { return delta }
            return nil
        }
        let completed = events.compactMap { event -> BlockCompleted? in
            if case .blockCompleted(let block) = event, block.kind == .text { return block }
            return nil
        }

        #expect(deltas.count > 1, "expected streamed text deltas")
        #expect(completed.count == 1, "a block must be reported complete exactly once")
        // Deltas are increments; concatenating them must reproduce the block.
        let assembled = deltas.filter { $0.blockID == completed[0].blockID }
            .map(\.text).joined()
        #expect(assembled == completed[0].text)
        #expect(completed[0].text.contains("hello ore"))
    }

    @Test func turnIsOpenedOnceAndClosedByResult() {
        let events = ClaudeCodeTranscriptReplay.events(transcript: Fixtures.load("simple-text"))

        let started = events.filter { if case .turnStarted = $0 { return true }; return false }
        let completed = events.compactMap { event -> TurnResult? in
            if case .turnCompleted(let result) = event { return result }
            return nil
        }

        #expect(started.count == 1)
        #expect(completed.count == 1)
        #expect(completed[0].outcome == .completed)
        #expect(completed[0].summary?.contains("hello ore") == true)
        // Every event that carries a turn must carry *this* turn.
        #expect(completed[0].usage?.outputTokens ?? 0 > 0)
    }

    @Test func autoCompactionSurfacesAsAContextCompactedEvent() {
        // Claude Code compacts its own context and announces it with a
        // `compact_boundary` system line; ORE surfaces that so the transcript —
        // and the context meter's drop — isn't left unexplained.
        let transcript = """
        {"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto","pre_tokens":152000}}
        """
        let events = ClaudeCodeTranscriptReplay.events(transcript: transcript)
        guard case .contextCompacted(let compaction)? = events.first(where: {
            if case .contextCompacted = $0 { return true }
            return false
        }) else {
            Issue.record("no contextCompacted event")
            return
        }
        #expect(compaction.trigger == "auto")
        #expect(compaction.preTokens == 152_000)
        #expect(compaction.summary.contains("152000"))
    }

    @Test func subscriptionSessionsNeverReportADollarCost() {
        // The fixture's `result` carries `total_cost_usd`, but the user is on a
        // subscription and is not billed per token. Surfacing that number would
        // be telling them they spent money they didn't spend.
        let events = ClaudeCodeTranscriptReplay.events(transcript: Fixtures.load("simple-text"))
        let costs = events.compactMap { event -> Double? in
            if case .usage(let usage) = event { return usage.costUSD }
            return nil
        }
        #expect(costs.isEmpty)
    }

    @Test func toolCallsAndResultsArePairedByID() {
        let events = ClaudeCodeTranscriptReplay.events(transcript: Fixtures.load("tool-use"))

        let calls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let call) = event { return call }
            return nil
        }
        let results = events.compactMap { event -> ToolResult? in
            if case .toolResult(let result) = event { return result }
            return nil
        }

        #expect(calls.count == 1)
        #expect(calls[0].name == "Bash")
        #expect(calls[0].displayName != nil, "a tool call needs a human-readable label")
        #expect(results.count == 1)
        #expect(results[0].toolCallID == calls[0].id)
        #expect(results[0].isError == false)
        #expect(results[0].text.contains("ore-permission-probe"))
    }

    @Test func toolCallsAreReportedOnlyOnce() {
        // tool_use blocks arrive twice — as streamed partial JSON and again in
        // the batched assistant message. The transcript must not double up.
        let events = ClaudeCodeTranscriptReplay.events(transcript: Fixtures.load("tool-use"))
        let ids = events.compactMap { event -> ToolCallID? in
            if case .toolCall(let call) = event { return call.id }
            return nil
        }
        #expect(ids.count == Set(ids).count)
    }

    @Test func permissionRequestCarriesEnoughToRenderAPrompt() {
        let events = ClaudeCodeTranscriptReplay.events(transcript: Fixtures.load("permission-deny"))

        guard let request = events.compactMap({ event -> PermissionRequest? in
            if case .permissionRequest(let request) = event { return request }
            return nil
        }).first else {
            Issue.record("no permission request in fixture")
            return
        }

        #expect(request.toolName == "Write")
        #expect(request.toolCallID != nil, "must link to the tool call it gates")
        #expect(request.input["file_path"]?.stringValue?.hasSuffix("probe.txt") == true)
        #expect(request.suggestions.contains { $0.kind == .setMode })

        // The id must be the CLI's own control request id, verbatim: the CLI
        // matches our reply on it and stays blocked forever on a mismatch.
        let controlRequestIDs = Fixtures.load("permission-deny")
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.contains("\"control_request\""),
                      let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return json["request_id"] as? String
            }
        #expect(controlRequestIDs.contains(request.id.rawValue))
    }

    @Test func anApprovedToolRunsAndReportsSuccess() {
        // The mirror of the deny fixture: after an allow the gated tool
        // actually executes, and its result comes back clean.
        let events = ClaudeCodeTranscriptReplay.events(transcript: Fixtures.load("permission-allow"))

        let request = events.compactMap { event -> PermissionRequest? in
            if case .permissionRequest(let request) = event { return request }
            return nil
        }.first
        let result = events.compactMap { event -> ToolResult? in
            if case .toolResult(let result) = event { return result }
            return nil
        }.first

        #expect(request?.toolName == "Write")
        #expect(result?.toolCallID == request?.toolCallID)
        #expect(result?.isError == false)
    }

    @Test func aProposedPlanIsLinkedToThePermissionThatApprovesIt() {
        // The plan arrives as a tool call, before any permission request
        // exists to link it to. Without the second, linked proposal an
        // "Approve plan" button has nothing to answer.
        let events = ClaudeCodeTranscriptReplay.events(transcript: Fixtures.load("plan-mode"))

        let proposals = events.compactMap { event -> (String, PermissionRequestID?)? in
            guard case .planUpdated(let update) = event,
                  case .proposal(let markdown, let requestID) = update.content
            else { return nil }
            return (markdown, requestID)
        }
        let request = events.compactMap { event -> PermissionRequest? in
            if case .permissionRequest(let request) = event { return request }
            return nil
        }.first

        #expect(proposals.count == 2, "the plan is published, then republished linked")
        #expect(proposals.first?.1 == nil)
        #expect(!(proposals.first?.0.isEmpty ?? true))
        // Both carry the same plan; only the link differs.
        #expect(proposals.first?.0 == proposals.last?.0)
        #expect(request?.toolName == "ExitPlanMode")
        #expect(proposals.last?.1 == request?.id)
    }

    @Test func planModeReachesTheAgentAsAReadOnlySession() {
        let events = ClaudeCodeTranscriptReplay.events(transcript: Fixtures.load("plan-mode"))
        guard case .sessionStarted(let started)? = events.first(where: {
            if case .sessionStarted = $0 { return true }
            return false
        }) else {
            Issue.record("no sessionStarted event")
            return
        }
        #expect(started.permissionMode == .plan)
    }

    @Test func statusOnlyChangesOnTransitions() {
        let events = ClaudeCodeTranscriptReplay.events(transcript: Fixtures.load("tool-use"))
        let statuses = events.compactMap { event -> AgentStatus? in
            if case .statusChanged(let status) = event { return status }
            return nil
        }
        #expect(!statuses.isEmpty)
        #expect(zip(statuses, statuses.dropFirst()).allSatisfy { $0 != $1 })
        #expect(statuses.last == .idle)
    }

    @Test func interruptedTurnIsNotReportedAsFailure() {
        let events = ClaudeCodeTranscriptReplay.events(transcript: Fixtures.load("interrupt"))
        let outcomes = events.compactMap { event -> TurnResult.Outcome? in
            if case .turnCompleted(let result) = event { return result.outcome }
            return nil
        }
        #expect(outcomes == [.interrupted])
    }

    @Test func unknownAndMalformedLinesAreIgnored() {
        // A CLI update that adds a message type, or a stray log line on stdout,
        // must not take the session down.
        var translator = ClaudeCodeTranslator(sessionID: SessionID(rawValue: "test"))
        #expect(translator.translate(line: "not json at all").isEmpty)
        #expect(translator.translate(line: #"{"type":"brand_new_thing","x":1}"#).isEmpty)
        #expect(translator.translate(line: #"{"type":"assistant"}"#).isEmpty)
        #expect(translator.translate(line: "").isEmpty)
    }

    @Test func planProposalIsSurfacedSeparatelyFromItsToolCall() {
        let transcript = """
        {"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"ExitPlanMode","input":{"plan":"## Steps\\n1. Do the thing"}}]},"session_id":"s1"}
        """
        let events = ClaudeCodeTranscriptReplay.events(transcript: transcript)

        let plans = events.compactMap { event -> PlanUpdate? in
            if case .planUpdated(let update) = event { return update }
            return nil
        }
        #expect(plans.count == 1)
        guard case .proposal(let markdown, _)? = plans.first?.content else {
            Issue.record("expected a plan proposal")
            return
        }
        #expect(markdown.contains("Do the thing"))
    }

    @Test func anEmptyExitPlanModeIsNotAProposal() {
        let transcript = """
        {"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"ExitPlanMode","input":{"plan":""}}]},"session_id":"s1"}
        """
        let events = ClaudeCodeTranscriptReplay.events(transcript: transcript)
        #expect(!events.contains { if case .planUpdated = $0 { return true }; return false })
    }

    @Test func todoWriteBecomesAChecklist() {
        let transcript = """
        {"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"TodoWrite","input":{"todos":[{"content":"Write the driver","status":"completed"},{"content":"Record fixtures","status":"in_progress"},{"content":"Ship","status":"pending"}]}}]},"session_id":"s1"}
        """
        let events = ClaudeCodeTranscriptReplay.events(transcript: transcript)

        guard case .todos(let items)? = events.compactMap({ event -> PlanUpdate.Content? in
            if case .planUpdated(let update) = event { return update.content }
            return nil
        }).first else {
            Issue.record("expected a todo list")
            return
        }
        #expect(items.map(\.status) == [.completed, .inProgress, .pending])
        #expect(items[0].text == "Write the driver")
    }

    @Test func narrationTagIsStrippedEverywhereAndCarriedOnTheTurnResult() {
        // The agent ends its final message with the narration tag ORE's system
        // prompt teaches. The tag must never surface — not in live deltas, not
        // in the completed block, not in the summary — and its content must
        // ride the turn result for the narration engine.
        let transcript = """
        {"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1"}},"session_id":"s1"}
        {"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text"}},"session_id":"s1"}
        {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Done."}},"session_id":"s1"}
        {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\\n<narr"}},"session_id":"s1"}
        {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ation>I fixed the flaky test.</narration>"}},"session_id":"s1"}
        {"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Done.\\n<narration>I fixed the flaky test.</narration>"}]},"session_id":"s1"}
        {"type":"result","subtype":"success","result":"Done.\\n<narration>I fixed the flaky test.</narration>","session_id":"s1"}
        """
        let events = ClaudeCodeTranscriptReplay.events(transcript: transcript)

        let streamedText = events.compactMap { event -> String? in
            if case .textDelta(let delta) = event { return delta.text }
            return nil
        }.joined()
        #expect(!streamedText.contains("<"), "no tag fragment may flash in live text")
        #expect(streamedText.contains("Done."))

        let completed = events.compactMap { event -> BlockCompleted? in
            if case .blockCompleted(let block) = event, block.kind == .text { return block }
            return nil
        }
        #expect(completed.map(\.text) == ["Done."])

        guard case .turnCompleted(let result)? = events.last(where: {
            if case .turnCompleted = $0 { return true }
            return false
        }) else {
            Issue.record("no turnCompleted event")
            return
        }
        #expect(result.summary == "Done.")
        #expect(result.narration == "I fixed the flaky test.")
    }

    @Test func askUserQuestionBecomesAQuestionEvent() {
        let transcript = """
        {"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"AskUserQuestion","input":{"questions":[{"question":"Which base branch?","options":[{"label":"master","description":"the default"},{"label":"develop"}]}]}}]},"session_id":"s1"}
        """
        let events = ClaudeCodeTranscriptReplay.events(transcript: transcript)

        guard let question = events.compactMap({ event -> AgentQuestion? in
            if case .question(let question) = event { return question }
            return nil
        }).first else {
            Issue.record("expected a question")
            return
        }
        #expect(question.prompt == "Which base branch?")
        #expect(question.options.map(\.label) == ["master", "develop"])
        #expect(question.toolCallID == ToolCallID(rawValue: "toolu_1"))
    }

    @Test func aFinishedToolMovesStatusToRequesting() {
        // The composer used to keep "running a tool" after the Read returned,
        // so a long model wait looked like a hung tool.
        var translator = ClaudeCodeTranslator(sessionID: SessionID(rawValue: "test"))
        let call = translator.translate(line: """
        {"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/tmp/a.swift"}}]},"session_id":"s1"}
        """)
        #expect(call.events.contains { if case .statusChanged(.runningTool) = $0 { return true }; return false })

        let result = translator.translate(line: """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok","is_error":false}]},"session_id":"s1"}
        """)
        let statuses = result.events.compactMap { event -> AgentStatus? in
            if case .statusChanged(let status) = event { return status }
            return nil
        }
        #expect(statuses == [.requesting])
    }

    @Test func parallelToolsStayRunningUntilTheLastResult() {
        var translator = ClaudeCodeTranslator(sessionID: SessionID(rawValue: "test"))
        _ = translator.translate(line: """
        {"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/tmp/a.swift"}},{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"/tmp/b.swift"}}]},"session_id":"s1"}
        """)
        let first = translator.translate(line: """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"a","is_error":false}]},"session_id":"s1"}
        """)
        #expect(!first.events.contains { if case .statusChanged = $0 { return true }; return false })

        let second = translator.translate(line: """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"b","is_error":false}]},"session_id":"s1"}
        """)
        #expect(second.events.contains { if case .statusChanged(.requesting) = $0 { return true }; return false })
    }

    @Test func askUserQuestionDoesNotClaimARunningTool() {
        var translator = ClaudeCodeTranslator(sessionID: SessionID(rawValue: "test"))
        let events = translator.translate(line: """
        {"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"AskUserQuestion","input":{"questions":[{"question":"Which base?"}]}}]},"session_id":"s1"}
        """).events
        let statuses = events.compactMap { event -> AgentStatus? in
            if case .statusChanged(let status) = event { return status }
            return nil
        }
        #expect(statuses == [.awaitingInput])
    }
}

enum Fixtures {
    /// Golden transcripts recorded from a live CLI with `ore-cli record`.
    static func load(_ name: String) -> String {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"
        ) ?? Bundle.module.url(forResource: name, withExtension: "jsonl") else {
            Issue.record("missing fixture: \(name).jsonl")
            return ""
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
