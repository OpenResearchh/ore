import Foundation
import OreProtocol
import Testing

@testable import OreMac

/// Parallel tool calls — two subagents each running Bash — ask for permission
/// at the same time. The chat used to keep one request, so the second
/// overwrote the first: answering the card on screen left the harness blocked
/// on a prompt the tab no longer showed.
@MainActor
struct ConcurrentPermissionTests {
    private let turn = TurnID(rawValue: "t1")

    private func started() -> ChatState {
        let state = ChatState()
        state.apply(.turnStarted(TurnStarted(turnID: turn)))
        return state
    }

    private func request(_ id: String, tool: String = "Bash", toolCallID: String? = nil) -> PermissionRequest {
        PermissionRequest(
            turnID: turn,
            id: PermissionRequestID(rawValue: id),
            toolCallID: toolCallID.map(ToolCallID.init(rawValue:)),
            toolName: tool,
            input: .object([:])
        )
    }

    @Test func aSecondRequestQueuesBehindTheFirstInsteadOfReplacingIt() {
        let state = started()
        state.apply(.permissionRequest(request("p1")))
        state.apply(.permissionRequest(request("p2")))

        #expect(state.pendingPermissions.map(\.id.rawValue) == ["p1", "p2"])
        #expect(state.pendingPermission?.id.rawValue == "p1", "the tab answers the oldest first")
    }

    @Test func answeringOneLeavesTheOtherOnScreenAndTheAgentStillWaiting() {
        let state = started()
        state.apply(.permissionRequest(request("p1")))
        state.apply(.permissionRequest(request("p2")))

        // Answered from the HUD, which shows the newest.
        state.resolvePermission(PermissionRequestID(rawValue: "p2"))
        #expect(state.pendingPermission?.id.rawValue == "p1")
        #expect(state.status == .awaitingInput)
        #expect(!state.isBusy, "no \"working\" row while an ask is still open")

        state.resolvePermission(PermissionRequestID(rawValue: "p1"))
        #expect(state.pendingPermissions.isEmpty)
        #expect(state.status == .requesting)
    }

    @Test func aSiblingToolCallStreamingDoesNotBuryAnOpenRequest() {
        let state = started()
        state.apply(.permissionRequest(request("p1")))
        state.apply(.statusChanged(.runningTool))
        state.apply(.statusChanged(.idle))

        #expect(state.status == .awaitingInput)
        #expect(state.pendingPermission?.id.rawValue == "p1")
    }

    @Test func theSameRequestAnnouncedTwiceIsOneCard() {
        let state = started()
        state.apply(.permissionRequest(request("p1")))
        state.apply(.permissionRequest(request("p1")))

        #expect(state.pendingPermissions.count == 1)
    }

    @Test func aQuestionsGateIsFoundBehindAnUnrelatedRequest() {
        let gate = NeedsYouPairing.gate(
            forToolCall: ToolCallID(rawValue: "call-q"),
            pendingPermissions: [
                request("bash"),
                request("gate", tool: "AskUserQuestion", toolCallID: "call-q"),
            ]
        )
        #expect(gate == PermissionRequestID(rawValue: "gate"))
    }
}
