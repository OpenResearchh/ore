import Foundation
import OreProtocol
import Testing

@testable import OreMac

struct WorkspacePermissionPolicyTests {
    private let workspace = WorkspaceID(rawValue: "workspace-a")
    private let deadline = Date(timeIntervalSince1970: 1_000)

    private func request(_ tool: String = "Bash") -> PermissionRequest {
        PermissionRequest(
            turnID: TurnID(rawValue: "turn"), id: PermissionRequestID(rawValue: "request"),
            toolName: tool, input: .object(["command": .string("git status"), "timeout": .integer(5)])
        )
    }

    @Test func timedApprovalExpiresAtTheDeadline() {
        let grant = WorkspaceAutoApproval(workspaceID: workspace, expiresAt: deadline)
        #expect(grant.allows(request(), in: workspace, now: deadline.addingTimeInterval(-0.001)))
        #expect(!grant.allows(request(), in: workspace, now: deadline))
        #expect(!grant.allows(request(), in: workspace, now: deadline.addingTimeInterval(60)))
    }

    @Test func timedApprovalNeverCrossesWorkspaceBoundaries() {
        let grant = WorkspaceAutoApproval(workspaceID: workspace, expiresAt: deadline)
        #expect(!grant.allows(request(), in: WorkspaceID(rawValue: "workspace-b"), now: deadline.addingTimeInterval(-1)))
    }

    @Test func questionsAndPlansStayOutOfBulkAndTimedApprovals() {
        let grant = WorkspaceAutoApproval(workspaceID: workspace, expiresAt: deadline)
        for tool in ["AskUserQuestion", "ExitPlanMode"] {
            #expect(!WorkspacePermissionPolicy.isToolRequest(request(tool)))
            #expect(!grant.allows(request(tool), in: workspace, now: deadline.addingTimeInterval(-1)))
        }
        #expect(WorkspacePermissionPolicy.isToolRequest(request("Write")))
    }

    @Test func editsAreOnlyOfferedWhenTheHarnessAcceptsReplacementInput() {
        #expect(WorkspacePermissionPolicy.canEdit(request(), harness: .claudeCode))
        #expect(!WorkspacePermissionPolicy.canEdit(request(), harness: .codex))
        #expect(!WorkspacePermissionPolicy.canEdit(request(), harness: .cursorAgent))
        #expect(!WorkspacePermissionPolicy.canEdit(request("ExitPlanMode"), harness: .claudeCode))
    }

    @Test func editingPreservesTheExactJSONTypesAndRejectsInvalidPayloads() {
        let original = request().input
        let roundTrip = WorkspacePermissionPolicy.editedInput(WorkspacePermissionPolicy.inputText(original))
        #expect(roundTrip == original)
        #expect(roundTrip?["timeout"] == .integer(5))
        #expect(WorkspacePermissionPolicy.editedInput("[]") == nil)
        #expect(WorkspacePermissionPolicy.editedInput("null") == nil)
        #expect(WorkspacePermissionPolicy.editedInput("{broken") == nil)
    }
}
