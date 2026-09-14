import Testing
import OreProtocol

@testable import OreMac

/// AskUserQuestion arrives as a question *and* a permission gate on one tool
/// call. These are the two halves of treating that as one ask.
struct NeedsYouPairingTests {
    private let workspace = WorkspaceID(rawValue: "ws")
    private let chat = ChatID(rawValue: "chat")
    private let turn = TurnID(rawValue: "turn")
    private let call = ToolCallID(rawValue: "call-1")

    private func question(
        _ id: String = "q1",
        toolCallID: ToolCallID? = nil
    ) -> AgentQuestion {
        AgentQuestion(
            turnID: turn,
            id: QuestionID(rawValue: id),
            toolCallID: toolCallID,
            prompt: "How much of the launch surface should this plan cover?",
            options: [.init(label: "Auth + analytics + signing"), .init(label: "Add the install script")]
        )
    }

    private func permission(
        _ id: String = "p1",
        tool: String = "AskUserQuestion",
        toolCallID: ToolCallID? = nil
    ) -> PermissionRequest {
        PermissionRequest(
            turnID: turn,
            id: PermissionRequestID(rawValue: id),
            toolCallID: toolCallID,
            toolName: tool,
            input: .object([:])
        )
    }

    private func needsQuestion(_ q: AgentQuestion) -> TabNeedsYou {
        .question(TabNeedsYou.Question(workspaceID: workspace, chatID: chat, question: q))
    }

    private func needsPermission(_ p: PermissionRequest) -> TabNeedsYou {
        .permission(TabNeedsYou.Permission(workspaceID: workspace, chatID: chat, request: p))
    }

    // MARK: - Which way the answer travels

    @Test func anAnswerToAGatedQuestionGoesBackThroughThePermission() {
        let gate = NeedsYouPairing.gate(
            forToolCall: call,
            pendingPermissions: [permission(toolCallID: call)]
        )
        #expect(gate == PermissionRequestID(rawValue: "p1"))
    }

    @Test func anUngatedQuestionIsAnsweredAsAnOrdinaryMessage() {
        #expect(NeedsYouPairing.gate(forToolCall: call, pendingPermissions: []) == nil)
    }

    /// A question and a permission can be open at once without being a pair —
    /// answering the question must not deny an unrelated Bash call.
    @Test func aQuestionIsNotPairedWithWhateverElseHappensToBePending() {
        let gate = NeedsYouPairing.gate(
            forToolCall: call,
            pendingPermissions: [permission(tool: "Bash", toolCallID: ToolCallID(rawValue: "call-2"))]
        )
        #expect(gate == nil)
    }

    /// The heart of it: a stale answer — a notification tapped long after the
    /// fact, a second click — names a tool call that is no longer the one
    /// waiting. It must not be allowed to answer the question that is.
    @Test func anAnswerToOneQuestionNeverResolvesAnothersGate() {
        #expect(NeedsYouPairing.gate(
            forToolCall: ToolCallID(rawValue: "call-old"),
            pendingPermissions: [permission(toolCallID: ToolCallID(rawValue: "call-new"))]
        ) == nil)
    }

    /// Harnesses that publish the gate without a tool call id still have to be
    /// answered through it, or the turn stays blocked forever.
    @Test func aGateWithoutAToolCallIDIsMatchedByName() {
        #expect(NeedsYouPairing.gate(
            forToolCall: call,
            pendingPermissions: [permission()]
        ) == PermissionRequestID(rawValue: "p1"))

        #expect(NeedsYouPairing.gate(
            forToolCall: call,
            pendingPermissions: [permission(tool: "Bash")]
        ) == nil)
    }

    // MARK: - What goes back through the gate

    @Test func oneQuestionRepliesInTheAgentsOwnTerms() {
        let reply = NeedsYouPairing.reply(for: [(question("q1"), "Add the install script")])
        #expect(reply.contains("Add the install script"))
        #expect(!reply.contains("\n"))
    }

    @Test func everyAnswerInAToolCallTravelsInOneReply() {
        let reply = NeedsYouPairing.reply(for: [
            (question("q1"), "Auth + analytics + signing"),
            (question("q2"), "Yes, notarize"),
        ])
        #expect(reply.contains("Auth + analytics + signing"))
        #expect(reply.contains("Yes, notarize"))
    }

    /// A dismissal ends the group, and the agent is told not to re-ask the
    /// parts the user skipped rather than being left to guess.
    @Test func skippedQuestionsAreNamedRatherThanSilentlyDropped() {
        let skipped = question("q2")
        let reply = NeedsYouPairing.reply(for: [
            (question("q1"), "Auth + analytics + signing"),
            (skipped, ""),
        ])
        #expect(reply.contains("They skipped: \(skipped.prompt)"))
        #expect(reply.contains("Do not re-ask"))
    }

    @Test func dismissingEverythingSaysSoPlainly() {
        let reply = NeedsYouPairing.reply(for: [(question("q1"), "   ")])
        #expect(reply == "The user dismissed the question without choosing; continue.")
    }

    // MARK: - What stops being pending

    /// The regression this file exists for. Answering in the ORE window
    /// resolved the gate but left the question in the needs-you list, so the
    /// floating HUD re-asked it the moment ORE lost focus.
    @Test func answeringTheGateAlsoRetiresTheQuestionItGated() {
        let items = [
            needsPermission(permission(toolCallID: call)),
            needsQuestion(question(toolCallID: call)),
        ]
        let left = NeedsYouPairing.remaining(items, resolving: PermissionRequestID(rawValue: "p1"))
        #expect(left.isEmpty)
    }

    @Test func anUnrelatedQuestionSurvives() {
        let items = [
            needsPermission(permission(toolCallID: call)),
            needsQuestion(question("q2", toolCallID: ToolCallID(rawValue: "call-2"))),
        ]
        let left = NeedsYouPairing.remaining(items, resolving: PermissionRequestID(rawValue: "p1"))
        #expect(left.map(\.id) == ["question-q2"])
    }

    /// Without tool call ids on both sides there is nothing to pair on, and
    /// guessing would silently swallow a real ask.
    @Test func anUnpairableQuestionIsLeftPending() {
        let items = [needsPermission(permission()), needsQuestion(question())]
        let left = NeedsYouPairing.remaining(items, resolving: PermissionRequestID(rawValue: "p1"))
        #expect(left.map(\.id) == ["question-q1"])
    }

    @Test func aPlanGatedByThePermissionStillGoesToo() {
        let items: [TabNeedsYou] = [
            needsPermission(permission("p1", tool: "ExitPlanMode", toolCallID: call)),
            .plan(TabNeedsYou.Plan(
                workspaceID: workspace, chatID: chat, turnID: turn,
                markdown: "# Plan", permissionRequestID: PermissionRequestID(rawValue: "p1")
            )),
        ]
        #expect(NeedsYouPairing.remaining(items, resolving: PermissionRequestID(rawValue: "p1")).isEmpty)
    }

    @Test func resolvingSomethingElseLeavesTheListAlone() {
        let items = [
            needsPermission(permission(toolCallID: call)),
            needsQuestion(question(toolCallID: call)),
        ]
        let left = NeedsYouPairing.remaining(items, resolving: PermissionRequestID(rawValue: "other"))
        #expect(left.count == 2)
    }
}
