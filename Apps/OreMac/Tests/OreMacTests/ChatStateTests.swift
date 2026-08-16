import Foundation
import OreProtocol
import Testing

@testable import OreMac

@MainActor
struct ChatStateTests {
    @Test func aRepeatedToolCallUpdatesInputInsteadOfAppending() {
        let state = ChatState()
        let turnID = TurnID(rawValue: "t1")
        state.apply(.turnStarted(TurnStarted(turnID: turnID)))
        state.apply(.toolCall(ToolCall(
            turnID: turnID, id: ToolCallID(rawValue: "c1"), name: "Edit",
            displayName: "x.txt", input: .object(["file_path": .string("x.txt")])
        )))
        state.apply(.toolCall(ToolCall(
            turnID: turnID, id: ToolCallID(rawValue: "c1"), name: "Edit",
            displayName: "x.txt",
            input: .object([
                "file_path": .string("x.txt"),
                "patch": .string("--- a/x.txt\n+++ b/x.txt\n@@ -1 +1 @@\n-old\n+new\n"),
            ])
        )))

        #expect(state.rows.count == 1)
        #expect(state.rows[0].toolInput?["patch"]?.stringValue?.contains("+new") == true)
    }

    @Test func distinctTextBlockIDsAppendRatherThanMutatingTheFirstRow() {
        let state = ChatState()
        let turnID = TurnID(rawValue: "t1")
        state.apply(.turnStarted(TurnStarted(turnID: turnID)))
        state.apply(.textDelta(BlockDelta(
            turnID: turnID, blockID: BlockID(rawValue: "t1#text-0"), text: "I'll read"
        )))
        state.apply(.toolCall(ToolCall(
            turnID: turnID, id: ToolCallID(rawValue: "c1"), name: "Read",
            displayName: "x.txt", input: .object(["file_path": .string("x.txt")])
        )))
        state.apply(.textDelta(BlockDelta(
            turnID: turnID, blockID: BlockID(rawValue: "t1#text-1"), text: "Done"
        )))

        #expect(state.rows.count == 3)
        #expect(state.rows[0].text == "I'll read")
        #expect(state.rows[1].toolName == "Read")
        #expect(state.rows[2].text == "Done")
    }
}
