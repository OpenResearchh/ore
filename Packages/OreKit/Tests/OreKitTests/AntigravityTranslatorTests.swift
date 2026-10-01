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
        #expect(toolCall?.name == "run_command")
        #expect(toolCall?.input["CommandLine"]?.stringValue == "echo hello_headless_demo")
        #expect(toolCall?.displayName == "echo hello_headless_demo")
        #expect(all.contains { if case .toolResult(let r) = $0 { return !r.isError && r.text.contains("hello_headless_demo") }; return false })
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
