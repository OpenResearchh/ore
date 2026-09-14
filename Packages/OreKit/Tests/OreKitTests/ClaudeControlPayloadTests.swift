import Foundation
import Testing

@testable import OreHarness
@testable import OreProtocol

/// Outbound payloads get their own tests because a recorded transcript can't
/// cover them: a fixture proves we *read* the CLI correctly, and says nothing
/// about what we write back.
struct ClaudeControlPayloadTests {
    private func encoded(_ value: JSONValue) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func allowAlwaysCarriesUpdatedInput() throws {
        // The CLI rejects an allow without `updatedInput` and reports the tool
        // call as failed rather than as a protocol error, so the mistake is
        // invisible until a user watches an approved edit not happen.
        let original: JSONValue = ["file_path": "/tmp/a.txt", "content": "ore"]
        let payload = ClaudeControlPayload.permissionReply(
            decision: .allow, originalInput: original
        )

        let json = try encoded(payload)
        #expect(json["behavior"] as? String == "allow")
        let updated = try #require(json["updatedInput"] as? [String: Any])
        #expect(updated["file_path"] as? String == "/tmp/a.txt")
        #expect(updated["content"] as? String == "ore")
    }

    @Test func allowWithAnEditedInputSendsTheEdit() throws {
        // The user tweaking a command before approving it is the whole reason
        // the field exists.
        let payload = ClaudeControlPayload.permissionReply(
            decision: .allow(updatedInput: ["command": "git status --short"]),
            originalInput: ["command": "git status"]
        )

        let json = try encoded(payload)
        let updated = try #require(json["updatedInput"] as? [String: Any])
        #expect(updated["command"] as? String == "git status --short")
    }

    @Test func acceptingASuggestionReturnsItVerbatim() throws {
        let suggestion: JSONValue = [
            "type": "addRules",
            "rules": [["toolName": "Bash", "ruleContent": "git status"]],
        ]
        let payload = ClaudeControlPayload.permissionReply(
            decision: .allowWithSuggestion(suggestion),
            originalInput: ["command": "git status"]
        )
        let json = try encoded(payload)
        let permissions = try #require(json["updatedPermissions"] as? [[String: Any]])
        #expect(permissions.first?["type"] as? String == "addRules")
    }

    @Test func denyCarriesAReasonTheAgentCanRead() throws {
        let payload = ClaudeControlPayload.permissionReply(
            decision: .deny(reason: "Not on the release branch"),
            originalInput: ["command": "git push"]
        )

        let json = try encoded(payload)
        #expect(json["behavior"] as? String == "deny")
        #expect(json["message"] as? String == "Not on the release branch")
        #expect(json["updatedInput"] == nil)
    }

    @Test func controlRequestSubtypesMatchTheCLIVocabulary() throws {
        #expect(try encoded(ClaudeControlPayload.interrupt())["subtype"] as? String == "interrupt")
        #expect(try encoded(ClaudeControlPayload.initialize())["subtype"] as? String == "initialize")

        let mode = try encoded(ClaudeControlPayload.setPermissionMode(.acceptEdits))
        #expect(mode["subtype"] as? String == "set_permission_mode")
        #expect(mode["mode"] as? String == "acceptEdits")

        let model = try encoded(ClaudeControlPayload.setModel("opus"))
        #expect(model["subtype"] as? String == "set_model")
        #expect(model["model"] as? String == "opus")
    }

    @Test func permissionModeNamesAreTheOnesTheCLIAccepts() {
        // These strings go straight onto the command line as
        // `--permission-mode <value>`; a rename here is a launch failure.
        #expect(PermissionMode.allCases.map(\.rawValue).sorted()
            == ["acceptEdits", "bypassPermissions", "default", "plan"])
    }

    @Test func userMessagesAreEncodedInTheShapeTheCLIExpects() throws {
        let line = try #require(String(
            data: try JSONEncoder().encode(ClaudeWire.UserInputMessage(text: "hello")),
            encoding: .utf8
        ))
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        #expect(json["type"] as? String == "user")

        let message = try #require(json["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "text")
        #expect(content.first?["text"] as? String == "hello")
    }

    @Test func attachmentsAreReferencedByPathRatherThanInlined() {
        // Attachments live in the workspace's `.context` directory so the agent
        // can read them with its own tools and they survive a restart.
        let message = UserMessage(
            text: "Follow this plan.",
            attachmentPaths: [".context/attachments/plan.md"]
        )
        #expect(message.renderedText.contains(".context/attachments/plan.md"))
        #expect(message.renderedText.hasPrefix("Follow this plan."))
    }

    @Test func aWellFormedCanUseToolIsAPermissionPrompt() {
        let line = #"{"type":"control_request","request_id":"req_1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}"#
        #expect(ClaudeWire.inboundControl(in: line) == .permissionPrompt)
    }

    @Test func anUnsupportedControlRequestCarriesItsIDForAnErrorReply() {
        let line = #"{"type":"control_request","request_id":"req_hook","request":{"subtype":"hook_callback"}}"#
        #expect(ClaudeWire.inboundControl(in: line) == .unsupported(requestID: "req_hook", subtype: "hook_callback"))
    }

    @Test func aMalformedControlRequestStillYieldsARequestID() {
        // Missing fields used to fail the typed decode and leave the CLI blocked.
        let line = #"{"type":"control_request","request_id":"req_broken","request":{}}"#
        #expect(ClaudeWire.inboundControl(in: line) == .unsupported(requestID: "req_broken", subtype: nil))
    }

    @Test func ordinaryStdoutIsNotTreatedAsAControlRequest() {
        #expect(ClaudeWire.inboundControl(in: #"{"type":"assistant","message":{}}"#) == .none)
        #expect(ClaudeWire.inboundControl(in: "not json") == .none)
    }

    @Test func theMessageTypeIsPeekedOnlyFromTheCompactLeadingKey() {
        #expect(ClaudeWire.peekType(in: #"{"type":"stream_event","event":{"type":"x"}}"#) == "stream_event")
        // Anything else is left to a real decode rather than guessed at.
        #expect(ClaudeWire.peekType(in: #"{ "type": "assistant"}"#) == nil)
        #expect(ClaudeWire.peekType(in: #"{"session_id":"s","type":"assistant"}"#) == nil)
        #expect(ClaudeWire.peekType(in: #"{"type":"a\"b"}"#) == nil)
        #expect(ClaudeWire.peekType(in: #"{"type":"unterminated"#) == nil)
        #expect(ClaudeWire.peekType(in: "not json") == nil)
    }

    @Test func aControlRequestWithoutTheCompactLeadingKeyIsStillAnswered() {
        let line = #"{"request_id":"req_2","type":"control_request","request":{"subtype":"hook_callback"}}"#
        #expect(ClaudeWire.inboundControl(in: line) == .unsupported(requestID: "req_2", subtype: "hook_callback"))
    }
}
