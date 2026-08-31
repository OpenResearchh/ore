import Foundation
import Testing
import OreProtocol

@testable import OreCore

/// Eval fixtures for the Assistant routing decision table: utterance + snapshot
/// → destination. The model still writes the brief; these pin that RouteTask
/// does not guess when two places still fit.
struct AssistantTaskRouterTests {
    private let assistant = WorkspaceID(rawValue: "assistant")
    private let kailash = WorkspaceID(rawValue: "kailash")
    private let parser = WorkspaceID(rawValue: "parser")
    private let authTab = ChatID(rawValue: "auth")
    private let testsTab = ChatID(rawValue: "tests")
    private let failedTab = ChatID(rawValue: "failed")

    @Test func continuingANamedHealthyTabSendsThere() {
        let decision = AssistantTaskRouter.route(
            utterance: "Keep going on the auth tab on kailash",
            snapshot: fleet()
        )
        #expect(decision.action == .sendExistingTab)
        #expect(decision.workspaceID == kailash)
        #expect(decision.chatID == authTab)
        #expect(decision.confidence == .high)
        #expect(decision.question == nil)
    }

    @Test func startOverOpensANewTabOnTheSameWorktree() {
        let decision = AssistantTaskRouter.route(
            utterance: "Start over on kailash",
            snapshot: fleet()
        )
        #expect(decision.action == .createChat)
        #expect(decision.workspaceID == kailash)
        #expect(decision.chatID == nil)
    }

    @Test func aNewWorktreeRequestCreatesAWorkspace() {
        let decision = AssistantTaskRouter.route(
            utterance: "Give the parser its own worktree",
            snapshot: fleet()
        )
        #expect(decision.action == .createWorkspace)
        #expect(decision.workspaceID == parser)
    }

    @Test func isolationOnADirtyTreeCreatesAWorkspace() {
        let decision = AssistantTaskRouter.route(
            utterance: "Do this in isolation so we don't mix it with the uncommitted files",
            snapshot: fleet(kailashDirty: 4, focused: true)
        )
        #expect(decision.action == .createWorkspace)
        #expect(decision.workspaceID == kailash)
    }

    @Test func assistantOnlyRequestsStayInTheAssistantChat() {
        let decision = AssistantTaskRouter.route(
            utterance: "Remember I prefer Opus for reviews",
            snapshot: fleet()
        )
        #expect(decision.action == .assistantChat)
        #expect(decision.workspaceID == assistant)
        #expect(decision.question == nil)
    }

    @Test func twoMatchingTabsAskOnceInsteadOfGuessing() {
        let decision = AssistantTaskRouter.route(
            utterance: "the auth thing",
            snapshot: AssistantTaskRouter.Snapshot(
                assistantWorkspaceID: assistant,
                focusedWorkspaceID: kailash,
                focusedChatID: testsTab,
                workspaces: [
                    workspace(
                        kailash, "kailash", "kailash",
                        tabs: [
                            tab(authTab, "Auth API", focused: false),
                            tab(testsTab, "Auth UI", focused: true),
                        ]
                    ),
                ]
            )
        )
        #expect(decision.action == .clarify)
        #expect(decision.question != nil)
        #expect(decision.chatID == nil)
    }

    @Test func aFailedTabIsNotWhereNewWorkLands() {
        let decision = AssistantTaskRouter.route(
            utterance: "Retry the tests tab on kailash",
            snapshot: AssistantTaskRouter.Snapshot(
                assistantWorkspaceID: assistant,
                focusedWorkspaceID: kailash,
                focusedChatID: failedTab,
                workspaces: [
                    workspace(
                        kailash, "kailash", "kailash",
                        tabs: [tab(failedTab, "Tests", status: .failed, focused: true)]
                    ),
                ]
            )
        )
        #expect(decision.action == .createChat)
        #expect(decision.workspaceID == kailash)
        #expect(decision.chatID == nil)
    }

    @Test func repoWorkWithNoPlaceNamedAsksWhichProject() {
        let decision = AssistantTaskRouter.route(
            utterance: "Fix the flaky test",
            snapshot: AssistantTaskRouter.Snapshot(
                assistantWorkspaceID: assistant,
                workspaces: [
                    workspace(kailash, "kailash", "kailash", tabs: [tab(authTab, "Auth")]),
                    workspace(parser, "parser", "parser", tabs: [tab(testsTab, "Tests")]),
                ]
            )
        )
        #expect(decision.action == .clarify)
        #expect(decision.question?.contains("project") == true)
    }

    @Test func renderExposesActionIdsAndAClarificationQuestion() {
        let text = AssistantTaskRouter.render(
            AssistantTaskRouter.route(
                utterance: "the auth thing",
                snapshot: AssistantTaskRouter.Snapshot(
                    assistantWorkspaceID: assistant,
                    workspaces: [
                        workspace(
                            kailash, "kailash", "kailash",
                            tabs: [
                                tab(authTab, "Auth API"),
                                tab(testsTab, "Auth UI"),
                            ]
                        ),
                    ]
                )
            )
        )
        #expect(text.contains("action: clarify"))
        #expect(text.contains("question:"))
        #expect(text.contains("confidence: low"))
    }

    // MARK: - Fixtures

    private func fleet(kailashDirty: Int = 0, focused: Bool = true) -> AssistantTaskRouter.Snapshot {
        AssistantTaskRouter.Snapshot(
            assistantWorkspaceID: assistant,
            focusedWorkspaceID: focused ? kailash : nil,
            focusedChatID: focused ? authTab : nil,
            workspaces: [
                workspace(
                    kailash, "kailash", "kailash",
                    dirty: kailashDirty,
                    tabs: [tab(authTab, "Auth", focused: focused)]
                ),
                workspace(
                    parser, "parser", "parser",
                    tabs: [tab(testsTab, "Tests")]
                ),
            ]
        )
    }

    private func workspace(
        _ id: WorkspaceID,
        _ name: String,
        _ repo: String,
        dirty: Int = 0,
        tabs: [AssistantTaskRouter.Tab]
    ) -> AssistantTaskRouter.Workspace {
        AssistantTaskRouter.Workspace(
            id: id, name: name, repo: repo, dirtyFileCount: dirty, tabs: tabs
        )
    }

    private func tab(
        _ id: ChatID,
        _ title: String,
        status: AgentStatus = .idle,
        isClosed: Bool = false,
        focused: Bool = false,
        pendingInput: Bool = false
    ) -> AssistantTaskRouter.Tab {
        AssistantTaskRouter.Tab(
            id: id,
            title: title,
            status: status,
            isClosed: isClosed,
            isFocused: focused,
            pendingInput: pendingInput
        )
    }
}
