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
}
