import Foundation
import Testing

@testable import OreHarness
@testable import OreProtocol

@Suite struct CursorExecutableDetectionTests {
    @Test func supportsCurrentAndLegacyCommandNames() {
        #expect(HarnessKind.cursorAgent.defaultExecutableName == "agent")
        #expect(CursorAgentHarness.executableNames == ["cursor-agent", "agent"])
    }
}

/// cursor-agent's `stream-json` streams a *full* assistant message per chunk,
/// puts reasoning and tools in top-level `thinking`/`tool_call` records, and
/// ends with one non-timestamped assistant message plus a `result`. These tests
/// pin the driver to that real shape.
struct CursorTranslatorTests {
    private func events(_ lines: [String]) -> [AgentEvent] {
        var translator = CursorAgentTranslator(sessionID: SessionID.generate())
        return lines.flatMap { translator.translate(line: $0).events }
    }

    @Test func streamedPartialsBecomeOneTextRowNotOnePerWord() {
        let all = events([
            #"{"type":"system","subtype":"init","cwd":"/tmp","session_id":"s","model":"Auto"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]},"timestamp_ms":1}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":" there"}]},"timestamp_ms":2}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello there"}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"Hello there"}"#,
        ])
        // Two deltas share one block id, then a single completed block.
        let deltas = all.compactMap { if case .textDelta(let d) = $0 { return d.blockID } else { return nil } }
        #expect(Set(deltas).count == 1)
        let completed = all.compactMap { event -> String? in
            if case .blockCompleted(let b) = event, b.kind == .text { return b.text }
            return nil
        }
        #expect(completed == ["Hello there"])
        #expect(all.contains { if case .turnCompleted = $0 { return true }; return false })
    }

    @Test func topLevelToolCallsBecomeToolCallAndResult() {
        let all = events([
            #"{"type":"tool_call","subtype":"started","call_id":"c1","tool_call":{"editToolCall":{"args":{"path":"/tmp/x.txt","streamContent":"hi\n"}}},"timestamp_ms":1}"#,
            #"{"type":"tool_call","subtype":"completed","call_id":"c1","tool_call":{"editToolCall":{"args":{"path":"/tmp/x.txt"},"result":{"success":{"path":"/tmp/x.txt"}}}},"timestamp_ms":2}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"done"}"#,
        ])
        let toolCall = all.compactMap { if case .toolCall(let c) = $0 { return c } else { return nil } }.first
        #expect(toolCall?.name == "Edit")
        #expect(toolCall?.input["file_path"]?.stringValue == "/tmp/x.txt")
        #expect(all.contains { if case .toolResult(let r) = $0 { return !r.isError }; return false })
    }

    @Test func metadataKeysAreNotEmittedAsToolCalls() {
        let all = events([
            #"{"type":"tool_call","subtype":"started","call_id":"c1","tool_call":{"toolCallId":"c1","startedAtMs":1,"hookAdditionalContexts":[{"type":"hook"}],"readToolCall":{"args":{"path":"/tmp/App.swift"}}},"timestamp_ms":1}"#,
            #"{"type":"tool_call","subtype":"completed","call_id":"c1","tool_call":{"toolCallId":"c1","readToolCall":{"args":{"path":"/tmp/App.swift"},"result":{"success":{"content":"hi"}}}},"timestamp_ms":2}"#,
        ])
        let calls = all.compactMap { if case .toolCall(let c) = $0 { return c } else { return nil } }
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.name == "Read" })
        #expect(calls.first?.input["file_path"]?.stringValue == "/tmp/App.swift")
        #expect(calls.first?.displayName == "App.swift")
        let names = calls.map(\.name)
        #expect(!names.contains("Toolcallid"))
        #expect(!names.contains("Startedatms"))
        #expect(!names.contains("Hookadditionalcontexts"))
    }

    @Test func hookOnlyToolCallRecordsAreDropped() {
        let all = events([
            #"{"type":"tool_call","subtype":"started","call_id":"c2","tool_call":{"toolCallId":"c2","startedAtMs":1,"hookAdditionalContexts":[{"foo":1}]},"timestamp_ms":1}"#,
        ])
        #expect(all.allSatisfy { if case .toolCall = $0 { return false }; return true })
    }

    @Test func cursorSpecificToolsMapOntoKnownNames() {
        let all = events([
            #"{"type":"tool_call","subtype":"started","call_id":"lints","tool_call":{"readLintsToolCall":{"args":{"path":"/tmp/App.swift"}}}}"#,
            #"{"type":"tool_call","subtype":"started","call_id":"ls","tool_call":{"lsToolCall":{"args":{"targetDirectory":"/tmp/Sources"}}}}"#,
            #"{"type":"tool_call","subtype":"started","call_id":"del","tool_call":{"deleteToolCall":{"args":{"path":"/tmp/gone.swift"}}}}"#,
            #"{"type":"tool_call","subtype":"started","call_id":"sem","tool_call":{"semSearchToolCall":{"args":{"query":"hover preview"}}}}"#,
        ])
        let calls = all.compactMap { if case .toolCall(let c) = $0 { return c } else { return nil } }
        let byID = Dictionary(uniqueKeysWithValues: calls.map { ($0.id.rawValue, $0) })
        #expect(byID["lints"]?.name == "ReadLints")
        #expect(byID["lints"]?.displayName == "App.swift")
        #expect(byID["ls"]?.name == "LS")
        #expect(byID["ls"]?.input["file_path"]?.stringValue == "/tmp/Sources")
        #expect(byID["del"]?.name == "Delete")
        #expect(byID["sem"]?.name == "Grep")
        #expect(byID["sem"]?.input["pattern"]?.stringValue == "hover preview")
    }

    @Test func createPlanBecomesAPlanProposal() {
        // Cursor writes a plan with CreatePlan and then exits the turn. If that
        // stays a generic tool chip, the user never sees a plan to approve and
        // has to type "continue" to get the agent moving again.
        let all = events([
            #"{"type":"tool_call","subtype":"started","call_id":"p1","tool_call":{"createPlanToolCall":{"args":{"name":"Fix freeze","overview":"Main-thread saturation.","plan":"Cause: the update loop.\nFix: profile, then batch."}}}}"#,
            #"{"type":"tool_call","subtype":"completed","call_id":"p1","tool_call":{"createPlanToolCall":{"args":{"name":"Fix freeze","plan":"Cause: the update loop.\nFix: profile, then batch."},"result":{"success":{}}}}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"done"}"#,
        ])
        let calls = all.compactMap { if case .toolCall(let c) = $0 { return c } else { return nil } }
        #expect(calls.contains { $0.name == "CreatePlan" })
        let plans = all.compactMap { event -> String? in
            if case .planUpdated(let update) = event,
               case .proposal(let markdown, let requestID) = update.content {
                #expect(requestID == nil)
                return markdown
            }
            return nil
        }
        #expect(plans.count == 1, "started then completed must not double the card")
        #expect(plans[0].contains("update loop"))
        #expect(plans[0].contains("profile"))
    }

    @Test func createPlanComposesMarkdownFromNameOverviewAndTodos() {
        let markdown = CursorAgentTranslator.planMarkdown(from: .object([
            "name": .string("Fix freeze"),
            "overview": .string("Main-thread saturation."),
            "todos": .array([
                .object(["content": .string("Profile the update loop")]),
                .object(["content": .string("Batch invalidations")]),
            ]),
        ]))
        #expect(markdown?.contains("Fix freeze") == true)
        #expect(markdown?.contains("Main-thread saturation.") == true)
        #expect(markdown?.contains("Profile the update loop") == true)
        #expect(markdown?.contains("Batch invalidations") == true)
    }

    @Test func payloadLevelStreamContentBecomesNewString() {
        let all = events([
            #"{"type":"tool_call","subtype":"started","call_id":"c1","tool_call":{"editToolCall":{"args":{"path":"/tmp/x.txt"},"streamContent":"hello\nworld\n"}}}"#,
        ])
        let call = all.compactMap { if case .toolCall(let c) = $0 { return c } else { return nil } }.first
        #expect(call?.input["file_path"]?.stringValue == "/tmp/x.txt")
        #expect(call?.input["new_string"]?.stringValue == "hello\nworld\n")
    }

    @Test func completedResultDiffIsMergedOntoTheEdit() {
        let all = events([
            #"{"type":"tool_call","subtype":"started","call_id":"c1","tool_call":{"editToolCall":{"args":{"path":"/tmp/x.txt"}}}}"#,
            #"{"type":"tool_call","subtype":"completed","call_id":"c1","tool_call":{"editToolCall":{"args":{"path":"/tmp/x.txt"},"result":{"success":{"path":"/tmp/x.txt","diff":"--- a/x.txt\n+++ b/x.txt\n@@ -1 +1 @@\n-old\n+new\n"}}}}}"#,
        ])
        let calls = all.compactMap { if case .toolCall(let c) = $0 { return c } else { return nil } }
        #expect(calls.count == 2)
        #expect(calls.last?.input["patch"]?.stringValue?.contains("+new") == true)
        #expect(calls.last?.input["file_path"]?.stringValue == "/tmp/x.txt")
        let result = all.compactMap { if case .toolResult(let r) = $0 { return r } else { return nil } }.first
        #expect(result?.text.contains("+new") == true)
    }

    @Test func applyPatchStreamContentBecomesPatch() {
        let patch = "*** Begin Patch\\n*** Update File: /tmp/x.txt\\n@@\\n-old\\n+new\\n*** End Patch\\n"
        let all = events([
            #"{"type":"tool_call","subtype":"started","call_id":"c1","tool_call":{"applyPatchToolCall":{"args":{"path":"/tmp/x.txt"},"streamContent":""# + patch + #""}}}"#,
        ])
        let call = all.compactMap { if case .toolCall(let c) = $0 { return c } else { return nil } }.first
        #expect(call?.name == "Edit")
        #expect(call?.input["patch"]?.stringValue?.contains("*** Update File:") == true)
        #expect(call?.input["new_string"] == nil)
    }

    @Test func streamingEditChunksUpdateTheSameCall() {
        let all = events([
            #"{"type":"tool_call","subtype":"started","call_id":"c1","tool_call":{"editToolCall":{"args":{"path":"/tmp/x.txt"},"streamContent":"hel"}}}"#,
            #"{"type":"tool_call","subtype":"started","call_id":"c1","tool_call":{"editToolCall":{"args":{"path":"/tmp/x.txt"},"streamContent":"hello\n"}}}"#,
        ])
        let calls = all.compactMap { if case .toolCall(let c) = $0 { return c } else { return nil } }
        #expect(calls.map(\.id.rawValue) == ["c1", "c1"])
        #expect(calls.last?.input["new_string"]?.stringValue == "hello\n")
    }

    @Test func assistantTextIsSegmentedAroundToolCalls() {
        let all = events([
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"I'll read"}]},"timestamp_ms":1}"#,
            #"{"type":"tool_call","subtype":"started","call_id":"c1","tool_call":{"readToolCall":{"args":{"path":"/tmp/x.txt"}}}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Now edit"}]},"timestamp_ms":2}"#,
            #"{"type":"tool_call","subtype":"started","call_id":"c2","tool_call":{"editToolCall":{"args":{"path":"/tmp/x.txt"},"streamContent":"new\n"}}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]},"timestamp_ms":3}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"I'll readNow editDone"}]}}"#,
        ])
        let textIDs = all.compactMap { event -> BlockID? in
            switch event {
            case .textDelta(let delta): return delta.blockID
            case .blockCompleted(let block) where block.kind == .text: return block.blockID
            default: return nil
            }
        }
        #expect(Set(textIDs).count == 3)

        let completed = all.compactMap { event -> String? in
            if case .blockCompleted(let block) = event, block.kind == .text { return block.text }
            return nil
        }
        #expect(completed == ["I'll read", "Now edit", "Done"])

        // Tools land between the text segments they follow, not after a single
        // growing row.
        let kinds: [String] = all.compactMap { event in
            switch event {
            case .textDelta: return "text"
            case .blockCompleted(let block) where block.kind == .text: return "textDone"
            case .toolCall(let call): return call.id.rawValue
            default: return nil
            }
        }
        #expect(kinds.contains("c1"))
        #expect(kinds.contains("c2"))
        let firstTool = kinds.firstIndex(of: "c1")!
        let secondTool = kinds.firstIndex(of: "c2")!
        let firstText = kinds.firstIndex(of: "text")!
        #expect(firstText < firstTool)
        #expect(firstTool < secondTool)
    }

    @Test func snapshotPartialsDoNotDuplicateAccumulatedText() {
        let all = events([
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]},"timestamp_ms":1}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello there"}]},"timestamp_ms":2}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello there"}]}}"#,
        ])
        let deltaText = all.compactMap { if case .textDelta(let d) = $0 { return d.text } else { return nil } }
        #expect(deltaText == ["Hello", " there"])
        let completed = all.compactMap { event -> String? in
            if case .blockCompleted(let b) = event, b.kind == .text { return b.text }
            return nil
        }
        #expect(completed == ["Hello there"])
    }

    @Test func anAgentToolCarriesItsBriefOnTheSharedKeys() {
        let all = events([
            #"{"type":"tool_call","subtype":"started","call_id":"c9","tool_call":{"agentToolCall":{"args":{"instructions":"Audit the router for dead routes.","title":"Route audit","agentType":"reviewer"}}},"timestamp_ms":1}"#,
        ])
        let call = all.compactMap { event -> ToolCall? in
            if case .toolCall(let call) = event { return call }
            return nil
        }.first
        #expect(call?.name == "Task")
        #expect(call?.input["prompt"]?.stringValue == "Audit the router for dead routes.")
        #expect(call?.input["description"]?.stringValue == "Route audit")
        #expect(call?.input["subagent_type"]?.stringValue == "reviewer")
    }

    @Test func planArgumentsAreLeftAloneByTheSubagentAliases() {
        // CreatePlan's `name` is a plan title, not a subagent label — aliasing
        // it would leak a bogus overview into the rendered plan markdown.
        let all = events([
            ##"{"type":"tool_call","subtype":"started","call_id":"c8","tool_call":{"createPlanToolCall":{"args":{"name":"Ship the fix","plan":"# Ship\n\nDo the thing."}}},"timestamp_ms":1}"##,
        ])
        let call = all.compactMap { event -> ToolCall? in
            if case .toolCall(let call) = event { return call }
            return nil
        }.first
        #expect(call?.name == "CreatePlan")
        #expect(call?.input["description"] == nil)
    }
}

/// cursor-agent explains a failure only on stderr, and exits with an empty
/// stdout when it rejects a model, a login or a quota. The stderr strings here
/// are copied verbatim from the real CLI (2026.08.11 build).
struct CursorAgentFailureTests {
    @Test func unavailableModelIsNamedWithoutDumpingTheCatalog() {
        let stderr = "Cannot use this model: cursor-grok-4. Available models: auto, "
            + Array(repeating: "some-model-id", count: 150).joined(separator: ", ")
        let error = CursorAgentFailure.classify(exitCode: 1, stderr: stderr)

        #expect(error.message.contains("cursor-grok-4"))
        #expect(error.message.contains("model picker"))
        // The 150-id catalog belongs in `detail`, not in a banner.
        #expect(!error.message.contains("some-model-id"))
        #expect(error.detail?.contains("some-model-id") == true)
    }

    @Test func invalidAPIKeyReportsHowToAuthenticate() {
        // The real CLI colours this line even when stdout is not a TTY.
        let stderr = "\u{1B}[33m⚠ Warning: The provided API key is invalid.\u{1B}[0m\n"
            + "Please check you have the right key, create a new one, or authenticate without it."
        let error = CursorAgentFailure.classify(exitCode: 1, stderr: stderr)

        #expect(error.kind == .notAuthenticated)
        #expect(error.message.contains("API key"))
        #expect(error.isRecoverable == false)
        // ANSI escapes must not reach the UI as literal `[33m` garbage.
        #expect(!error.message.contains("\u{1B}"))
        #expect(!error.message.contains("[33m"))
    }

    @Test func quotaExhaustionIsClassifiedAsARateLimit() {
        for stderr in [
            "You've hit your usage limit. Upgrade to Pro for more requests.",
            "Error: 429 Too Many Requests",
            "Insufficient credits remaining on your plan.",
            "Rate limit exceeded, please try again later.",
        ] {
            let error = CursorAgentFailure.classify(exitCode: 1, stderr: stderr)
            // The banner switches to its "wait for the reset" variant on this
            // kind, so misclassifying here costs the user the Continue button.
            #expect(error.kind == .rateLimited, "not rate limited: \(stderr)")
        }
    }

    @Test func unrecognizedStderrIsReportedVerbatimRatherThanSwallowed() {
        let error = CursorAgentFailure.classify(
            exitCode: 3, stderr: "Something entirely new went wrong"
        )
        #expect(error.message.contains("Something entirely new went wrong"))
        #expect(error.message.contains("status 3"))
    }

    @Test func silentFailureStillSaysWhatToDo() {
        let error = CursorAgentFailure.classify(exitCode: 1, stderr: "")
        #expect(error.message.contains("status 1"))
        #expect(error.message.contains("terminal"))
    }

    @Test func ansiStrippingLeavesOrdinaryTextAlone() {
        #expect(CursorAgentFailure.stripANSI("plain text") == "plain text")
        #expect(CursorAgentFailure.stripANSI("\u{1B}[1;31mred\u{1B}[0m") == "red")
        #expect(CursorAgentFailure.stripANSI("a\u{1B}[Kb") == "ab")
    }

    /// The bug in the screenshot: a turn that had already started produced only
    /// "cursor-agent exited with status 1", with the real reason discarded.
    @Test func failedTurnCarriesTheReasonNotJustTheExitCode() {
        var translator = CursorAgentTranslator(sessionID: SessionID.generate())
        _ = translator.translate(
            line: #"{"type":"system","subtype":"init","cwd":"/tmp","session_id":"s"}"#
        )
        _ = translator.translate(
            line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]},"timestamp_ms":1}"#
        )
        let events = translator.closeTurn(
            exitCode: 1, stderr: "You've hit your usage limit."
        ).events

        let failures = events.compactMap { event -> String? in
            if case .turnCompleted(let result) = event, result.outcome == .failed {
                return result.errorMessage
            }
            return nil
        }
        #expect(failures.count == 1)
        #expect(failures[0].contains("usage limit"))
        #expect(!failures[0].contains("exited with status"))
    }

    /// A bad model kills the CLI before it writes a single stdout record, so
    /// there is no turn to fail — this used to end in total silence.
    @Test func failureBeforeAnyTurnStartsBecomesASessionError() {
        var translator = CursorAgentTranslator(sessionID: SessionID.generate())
        let events = translator.closeTurn(
            exitCode: 1, stderr: "Cannot use this model: nope. Available models: auto"
        ).events

        let errors = events.compactMap { event -> SessionError? in
            if case .sessionError(let error) = event { return error }
            return nil
        }
        #expect(errors.count == 1)
        #expect(errors[0].message.contains("nope"))
        #expect(events.contains { if case .statusChanged(.failed) = $0 { return true }; return false })
    }

    /// A CLI that reports a failure in-band *and* exits non-zero must not raise
    /// the same problem twice — once as a failed turn, again as a session error.
    @Test func inBandResultFailureIsNotAlsoReportedOnExit() {
        var translator = CursorAgentTranslator(sessionID: SessionID.generate())
        _ = translator.translate(
            line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]},"timestamp_ms":1}"#
        )
        let reported = translator.translate(
            line: #"{"type":"result","subtype":"error","is_error":true,"result":"usage limit reached"}"#
        ).events
        #expect(reported.contains { if case .turnCompleted = $0 { return true }; return false })

        let onExit = translator.closeTurn(exitCode: 1, stderr: "usage limit reached").events
        #expect(!onExit.contains { if case .sessionError = $0 { return true }; return false })
    }

    @Test func cleanExitStillCompletesTheTurn() {
        var translator = CursorAgentTranslator(sessionID: SessionID.generate())
        _ = translator.translate(
            line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]},"timestamp_ms":1}"#
        )
        let events = translator.closeTurn(exitCode: 0, stderr: "some harmless warning").events
        let outcomes = events.compactMap { event -> TurnResult.Outcome? in
            if case .turnCompleted(let result) = event { return result.outcome }
            return nil
        }
        #expect(outcomes == [.completed])
    }

    private func exitSummary(of events: [AgentEvent]) -> String? {
        events.compactMap { event -> TurnResult? in
            if case .turnCompleted(let result) = event { return result }
            return nil
        }.first?.summary
    }

    @Test func exitPathSummaryComesFromClosedTextSegments() {
        // This CLI may exit without a `result` record; the text it streamed is
        // the turn's final report and must reach `TurnResult.summary` — it's
        // what the narration engine summarizes when the process just ends.
        var translator = CursorAgentTranslator(sessionID: SessionID.generate())
        _ = translator.translate(
            line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"I renamed the module."}]},"timestamp_ms":1}"#
        )
        _ = translator.translate(
            line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"I renamed the module."}]}}"#
        )
        let events = translator.closeTurn(exitCode: 0).events
        #expect(exitSummary(of: events) == "I renamed the module.")
    }

    @Test func exitPathSummaryIncludesTextThatOnlyStreamed() {
        // Text that only ever arrived as deltas is flushed at exit; the
        // summary must see it too, not just segments that closed in-band.
        var translator = CursorAgentTranslator(sessionID: SessionID.generate())
        _ = translator.translate(
            line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Halfway done"}]},"timestamp_ms":1}"#
        )
        let events = translator.closeTurn(exitCode: 0).events
        #expect(exitSummary(of: events) == "Halfway done")
    }
}
