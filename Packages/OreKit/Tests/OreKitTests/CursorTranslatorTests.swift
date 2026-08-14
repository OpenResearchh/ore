import Foundation
import Testing

@testable import OreHarness
@testable import OreProtocol

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
}
