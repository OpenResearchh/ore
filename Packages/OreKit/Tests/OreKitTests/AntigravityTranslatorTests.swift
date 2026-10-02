import Foundation
import Testing

@testable import OreHarness
@testable import OreProtocol

struct AntigravityTranslatorTests {
    private func events(_ lines: [String]) -> [AgentEvent] {
        var translator = AntigravityTranslator(sessionID: SessionID.generate())
        return lines.flatMap { translator.translate(line: $0).events }
    }

    @Test func initThenTextDeltasBecomeOneCompletedBlock() {
        let all = events([
            #"{"event":"init","conversation_id":"c1","init":{"cwd":"/tmp","tools":["run_command","write_to_file"],"permission_mode":"request-review","model":"gemini-3.8-flash-high"}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":0,"state":"DONE","step_type":"user_input"}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":2,"state":"ACTIVE","step_type":"agent_response","text_delta":"Hello"}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":2,"state":"DONE","step_type":"agent_response","text_delta":" there\n","usage":{"input_tokens":10,"output_tokens":4,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":14}}}"#,
            #"{"event":"result","result":{"conversation_id":"c1","status":"SUCCESS","response":"Hello there\n","duration_seconds":1.4,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":4,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":14}}}"#,
        ])
        #expect(all.contains { if case .sessionStarted(let s) = $0 { return s.providerSessionID == "c1" && s.model == "gemini-3.8-flash-high" }; return false })
        let deltas = all.compactMap { if case .textDelta(let d) = $0 { return d.text } else { return nil } }
        #expect(deltas == ["Hello", " there\n"])
        let completed = all.compactMap { event -> String? in
            if case .blockCompleted(let b) = event, b.kind == .text { return b.text }
            return nil
        }
        #expect(completed == ["Hello there\n"])
        #expect(all.contains { if case .turnCompleted(let r) = $0 { return r.outcome == .completed && r.summary == "Hello there\n" }; return false })
        #expect(all.contains { if case .usage(let u) = $0 { return u.inputTokens == 10 && u.outputTokens == 4 }; return false })
    }

    @Test func toolStepsBecomeToolCallAndResult() {
        let all = events([
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":4,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"echo hello_headless_demo"}}}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":4,"state":"DONE","step_type":"tool","tool_name":"run_command","duration_seconds":0.07,"tool_info":{"name":"run_command","parameters":{"CommandLine":"echo hello_headless_demo"},"output":"hello_headless_demo\r\n"}}}"#,
            #"{"event":"result","result":{"conversation_id":"c1","status":"SUCCESS","response":"done","usage":{"input_tokens":1,"output_tokens":1,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":2}}}"#,
        ])
        let toolCall = all.compactMap { if case .toolCall(let c) = $0 { return c } else { return nil } }.first
        #expect(toolCall?.name == "Bash")
        #expect(toolCall?.input["CommandLine"]?.stringValue == "echo hello_headless_demo")
        #expect(toolCall?.input["command"]?.stringValue == "echo hello_headless_demo")
        #expect(toolCall?.displayName == "echo hello_headless_demo")
        #expect(all.contains { if case .toolResult(let r) = $0 { return !r.isError && r.text.contains("hello_headless_demo") }; return false })
    }

    @Test func viewFileMapsOntoReadAndCopiesAbsolutePath() {
        let all = events([
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"view_file","tool_info":{"name":"view_file","parameters":{"AbsolutePath":"/tmp/sample.txt"}}}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":2,"state":"DONE","step_type":"tool","tool_name":"view_file","tool_info":{"name":"view_file","parameters":{"AbsolutePath":"/tmp/sample.txt"},"output":"3 lines, 32 bytes"}}}"#,
        ])
        let toolCall = all.compactMap { if case .toolCall(let c) = $0 { return c } else { return nil } }.first
        #expect(toolCall?.name == "Read")
        #expect(toolCall?.input["file_path"]?.stringValue == "/tmp/sample.txt")
        #expect(toolCall?.displayName == "sample.txt")
        #expect(all.contains { if case .toolResult(let r) = $0 { return r.text == "3 lines, 32 bytes" }; return false })
    }

    @Test func grepSearchAndListDirMapOntoGrepAndLS() {
        let all = events([
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":1,"state":"ACTIVE","step_type":"tool","tool_name":"grep_search","tool_info":{"parameters":{"Query":"hello","AbsolutePath":"/tmp/src"}}}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":3,"state":"ACTIVE","step_type":"tool","tool_name":"list_dir","tool_info":{"parameters":{"AbsolutePath":"/tmp/src"}}}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":5,"state":"ACTIVE","step_type":"tool","tool_name":"find_by_name","tool_info":{"parameters":{"Pattern":"*.swift"}}}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":6,"state":"ACTIVE","step_type":"tool","tool_name":"replace_file_content","tool_info":{"parameters":{"AbsolutePath":"/tmp/src/app.swift","Replacement":"func hello() {}"}}}}"#,
        ])
        let byIndex = Dictionary(
            uniqueKeysWithValues: all.compactMap { event -> (String, AgentEvent)? in
                if case .toolCall(let call) = event { return (call.id.rawValue, event) }
                return nil
            }
        )
        func call(_ index: String) -> ToolCall? {
            if case .toolCall(let call) = byIndex["agy-tool-\(index)"] { return call }
            return nil
        }
        #expect(call("1")?.name == "Grep")
        #expect(call("1")?.input["pattern"]?.stringValue == "hello")
        #expect(call("1")?.displayName == "hello")
        #expect(call("3")?.name == "LS")
        #expect(call("3")?.displayName == "src")
        #expect(call("5")?.name == "Glob")
        #expect(call("5")?.displayName == "*.swift")
        #expect(call("6")?.name == "Edit")
        #expect(call("6")?.displayName == "app.swift")
    }

    @Test func browserAndMCPCallsCarryPayloadOnTheChip() {
        let all = events([
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"browser_click_element","tool_info":{"parameters":{"Selector":"button.submit"}}}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":3,"state":"ACTIVE","step_type":"tool","tool_name":"call_mcp_tool","tool_info":{"parameters":{"ServerName":"github","ToolName":"get_issue","Arguments":{"issue_number":1}}}}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":4,"state":"ACTIVE","step_type":"tool","tool_name":"wait","tool_info":{"parameters":{"WaitMs":1500}}}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":5,"state":"ACTIVE","step_type":"tool","tool_name":"generate_image","tool_info":{"parameters":{"Prompt":"a red cube"}}}}"#,
        ])
        let byIndex = Dictionary(
            uniqueKeysWithValues: all.compactMap { event -> (String, AgentEvent)? in
                if case .toolCall(let call) = event { return (call.id.rawValue, event) }
                return nil
            }
        )
        func call(_ index: String) -> ToolCall? {
            if case .toolCall(let call) = byIndex["agy-tool-\(index)"] { return call }
            return nil
        }
        #expect(call("2")?.name == "browser_click_element")
        #expect(call("2")?.displayName == "button.submit")
        #expect(call("3")?.name == "mcp__github__get_issue")
        #expect(call("4")?.name == "Wait")
        #expect(call("4")?.displayName == "1s")
        #expect(call("5")?.name == "GenerateImage")
        #expect(call("5")?.displayName == "a red cube")
    }

    @Test func anErroredToolClosesAsAnErrorResult() {
        let all = events([
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":4,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"parameters":{"CommandLine":"false"}}}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":4,"state":"ERROR","step_type":"tool","tool_name":"run_command","tool_info":{"parameters":{"CommandLine":"false"},"error":{"message":"exit 1"}}}}"#,
        ])
        #expect(all.contains { if case .toolResult(let r) = $0 { return r.isError && r.text.contains("exit 1") }; return false })
    }

    @Test func finishIsNotEmittedAsAToolChip() {
        let all = events([
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":9,"state":"DONE","step_type":"tool","tool_name":"finish","tool_info":{"name":"finish","parameters":{}}}}"#,
        ])
        #expect(all.allSatisfy { if case .toolCall = $0 { return false }; return true })
    }

    @Test func interruptedResultClosesTheTurnAsInterrupted() {
        let all = events([
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":2,"state":"DONE","step_type":"agent_response","text_delta":"partial"}}"#,
            #"{"event":"result","result":{"conversation_id":"c1","status":"INTERRUPTED","response":"partial","error":"interrupted","usage":{"input_tokens":1,"output_tokens":1,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":2}}}"#,
        ])
        #expect(all.contains { if case .turnCompleted(let r) = $0 { return r.outcome == .interrupted }; return false })
        #expect(all.contains { if case .statusChanged(.interrupted) = $0 { return true }; return false })
    }

    @Test func authenticationErrorBecomesASessionError() {
        let all = events([
            #"{"event":"result","result":{"conversation_id":"","status":"ERROR","response":"","error":"authentication required"}}"#,
        ])
        #expect(all.contains { if case .sessionError(let e) = $0 { return e.kind == .notAuthenticated }; return false })
        #expect(all.contains { if case .turnCompleted(let r) = $0 { return r.outcome == .failed }; return false })
    }

    @Test func subagentInfoOnAToolStepBecomesTheBackgroundSet() {
        let all = events([
            #"{"event":"init","conversation_id":"c1","init":{"cwd":"/tmp","tools":["invoke_subagent"]}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"invoke_subagent","tool_info":{"parameters":{"Description":"Explore the repo"}},"subagent_info":{"subagents":[{"conversation_id":"child-1","type_name":"explore","role":"Explore the repo"}]}}}"#,
        ])
        let sets = all.compactMap { event -> [AgentBackgroundTask]? in
            if case .backgroundTasksChanged(let tasks) = event { return tasks }
            return nil
        }
        #expect(sets.last?.map(\.id) == ["child-1"])
        #expect(sets.last?.first?.description == "Explore the repo")
        let task = all.compactMap { if case .toolCall(let c) = $0 { return c } else { return nil } }.first
        #expect(task?.name == "Task")
        #expect(task?.parentToolCallID == nil)
    }

    @Test func childConversationStepsNestUnderTheSubagentCall() {
        let all = events([
            #"{"event":"init","conversation_id":"c1","init":{"cwd":"/tmp","tools":["invoke_subagent","view_file"]}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"invoke_subagent","tool_info":{"parameters":{"Description":"Find the chips"}}}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"child-1","step_index":1,"state":"ACTIVE","step_type":"tool","tool_name":"view_file","tool_info":{"parameters":{"AbsolutePath":"/tmp/a.swift"}}}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"child-1","step_index":2,"state":"ACTIVE","step_type":"agent_response","text_delta":"Child report"}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":4,"state":"ACTIVE","step_type":"tool","tool_name":"view_file","tool_info":{"parameters":{"AbsolutePath":"/tmp/b.swift"}}}}"#,
        ])
        let calls = all.compactMap { if case .toolCall(let c) = $0 { return c } else { return nil } }
        let parent = calls.first { $0.name == "Task" }
        #expect(parent?.id.rawValue == "agy-tool-2")
        let child = calls.first { $0.name == "Read" && $0.displayName == "a.swift" }
        #expect(child?.parentToolCallID == parent?.id)
        let sibling = calls.first { $0.name == "Read" && $0.displayName == "b.swift" }
        #expect(sibling?.parentToolCallID == nil)
        #expect(all.contains {
            if case .textDelta(let d) = $0 {
                return d.text == "Child report" && d.parentToolCallID == parent?.id
            }
            return false
        })
    }

    @Test func emptySubagentInfoClearsTheBackgroundSet() {
        let all = events([
            #"{"event":"init","conversation_id":"c1","init":{"cwd":"/tmp"}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":1,"state":"ACTIVE","step_type":"tool","tool_name":"invoke_subagent","subagent_info":{"subagents":[{"conversation_id":"child-1","role":"Explore"}]}}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c1","step_index":1,"state":"DONE","step_type":"tool","tool_name":"invoke_subagent","subagent_info":{"subagents":[]}}}"#,
        ])
        let sets = all.compactMap { event -> [AgentBackgroundTask]? in
            if case .backgroundTasksChanged(let tasks) = event { return tasks }
            return nil
        }
        #expect(sets.contains { $0.map(\.id) == ["child-1"] })
        #expect(sets.last?.isEmpty == true)
    }
}

struct AntigravityCatalogTests {
    @Test func textListingParsesSlugAndDisplayName() {
        let text = """
        gemini-3.8-flash-high     Gemini 3.8 Flash (High)
        gemini-3.8-flash-medium   Gemini 3.8 Flash (Medium)
        claude-sonnet-4-6         Claude Sonnet 4.6 (Thinking)
        """
        let models = AntigravityHarness.parseModels(text) ?? []
        #expect(models.map(\.id) == [
            "gemini-3.8-flash-high",
            "gemini-3.8-flash-medium",
            "claude-sonnet-4-6",
        ])
        #expect(models.first?.displayName == "Gemini 3.8 Flash (High)")
        #expect(models.first?.supportedReasoningEfforts == ["low", "medium", "high"])
    }

    @Test func jsonArrayOfObjectsParses() throws {
        let json = """
        [
          {"id":"gemini-3.8-flash-high","display_name":"Gemini 3.8 Flash (High)","is_default":true},
          {"slug":"claude-sonnet-4-6","name":"Claude Sonnet 4.6"}
        ]
        """
        let models = try #require(AntigravityHarness.parseModels(json))
        #expect(models.map(\.id) == ["gemini-3.8-flash-high", "claude-sonnet-4-6"])
        #expect(models.first?.isDefault == true)
        #expect(models.last?.displayName == "Claude Sonnet 4.6")
    }

    @Test func liveJSONWrapperParsesNestedLabelledModels() throws {
        let json = """
        {"conversation_id":"","status":"SUCCESS","response":"gemini-3.8-flash-high\\tGemini 3.8 Flash (High)\\nclaude-opus-4-6-thinking\\tClaude Opus 4.6 (Thinking)\\n","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},"command":{"name":"models","data":{"models":[{"id":"gemini-3.8-flash-high","label":"Gemini 3.8 Flash (High)"},{"id":"gemini-3.7-flash-low","label":"Gemini 3.7 Flash (Low)"},{"id":"claude-opus-4-6-thinking","label":"Claude Opus 4.6 (Thinking)"},{"id":"gpt-oss-120b-medium","label":"GPT-OSS 120B (Medium)"}]}}}
        """
        let models = try #require(AntigravityHarness.parseModels(json))
        #expect(models.map(\.id) == [
            "gemini-3.8-flash-high",
            "gemini-3.7-flash-low",
            "claude-opus-4-6-thinking",
            "gpt-oss-120b-medium",
        ])
        #expect(models.first?.displayName == "Gemini 3.8 Flash (High)")
        #expect(models.last?.displayName == "GPT-OSS 120B (Medium)")
    }

    @Test func tabSeparatedListingParsesFullCatalogue() {
        let text = """
        Fetching available models...
        gemini-3.8-flash-high	Gemini 3.8 Flash (High)
        gemini-3.8-flash-low	Gemini 3.8 Flash (Low)
        claude-opus-4-6-thinking	Claude Opus 4.6 (Thinking)
        gpt-oss-120b-medium	GPT-OSS 120B (Medium)
        """
        let models = AntigravityHarness.parseModels(text) ?? []
        #expect(models.map(\.id) == [
            "gemini-3.8-flash-high",
            "gemini-3.8-flash-low",
            "claude-opus-4-6-thinking",
            "gpt-oss-120b-medium",
        ])
        #expect(models.first?.displayName == "Gemini 3.8 Flash (High)")
    }

    @Test func printModeUsesEqualsFormSoFlagsAreNotEatenAsThePrompt() {
        #expect(AntigravityHarness.printModeArguments == [
            "-p=",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
        ])
        #expect(!AntigravityHarness.printModeArguments.contains("-p"))
    }

    @Test func permissionArgumentsDefaultToAcceptEditsBecauseThereIsNoTTY() {
        #expect(
            AntigravityHarness.permissionArguments(mode: .default, allowUnprompted: false)
                == ["--mode", "accept-edits"]
        )
        #expect(
            AntigravityHarness.permissionArguments(mode: .acceptEdits, allowUnprompted: false)
                == ["--mode", "accept-edits"]
        )
        #expect(
            AntigravityHarness.permissionArguments(mode: .plan, allowUnprompted: false)
                == ["--mode", "plan"]
        )
        #expect(
            AntigravityHarness.permissionArguments(mode: .bypassPermissions, allowUnprompted: false)
                == ["--mode", "accept-edits"]
        )
        #expect(
            AntigravityHarness.permissionArguments(mode: .bypassPermissions, allowUnprompted: true)
                == ["--dangerously-skip-permissions"]
        )
    }

    @Test func effortMapsOntoTheThreeCLIValues() {
        #expect(AntigravityHarness.cliEffort(.low) == "low")
        #expect(AntigravityHarness.cliEffort(.none) == "low")
        #expect(AntigravityHarness.cliEffort(.medium) == "medium")
        #expect(AntigravityHarness.cliEffort(.high) == "high")
        #expect(AntigravityHarness.cliEffort(.xhigh) == "high")
        #expect(AntigravityHarness.cliEffort(.max) == "high")
    }

    @Test func authStatusRecognizesHeadlessRefusal() {
        #expect(AntigravityAuthStatus.interpret("authentication required") == .notAuthenticated)
        #expect(AntigravityAuthStatus.interpret("{\"status\":\"SUCCESS\",\"usage\":{\"input_tokens\":1}}") == .authenticated)
        #expect(AntigravityAuthStatus.interpret(nil) == .unknown)
    }
}

struct AntigravityKindTests {
    @Test func antigravityIsExperimentalAndHasANativeInstaller() {
        #expect(HarnessKind.antigravity.defaultExecutableName == "agy")
        #expect(HarnessKind.antigravity.isExperimental)
        #expect(HarnessKind.antigravity.supportsReasoningEffort)
        #expect(HarnessKind.antigravity.requiresInteractiveSignIn)
        #expect(HarnessKind.antigravity.nativeInstallerURL.contains("antigravity.google/cli"))
        #expect(HarnessKind.antigravity.npmPackage == nil)
        #expect(HarnessKind.antigravity.brewFormula == nil)
    }
}
