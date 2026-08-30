import Testing
import OreProtocol

@testable import OreMac

/// How a blocked project tab reads when it is offered for action on the
/// Assistant surface rather than spoken. The assistant narrates "[ORE needs
/// you] a tab wants to run Bash"; the row beside the Allow button has to say
/// which tab, and which command.
struct AssistantNeedsYouRowTests {
    private func permission(
        tool: String = "Bash",
        displayName: String? = "Run command",
        summary: String? = "swift test"
    ) -> TabNeedsYou {
        .permission(TabNeedsYou.Permission(
            workspaceID: WorkspaceID(rawValue: "ws"),
            chatID: ChatID(rawValue: "chat"),
            request: PermissionRequest(
                turnID: TurnID(rawValue: "turn"),
                id: PermissionRequestID(rawValue: "p1"),
                toolName: tool,
                displayName: displayName,
                summary: summary,
                input: .null
            )
        ))
    }

    @Test func aPermissionHeadlineNamesTheToolAndWhatItWillDo() {
        #expect(permission().headline == "Run command — swift test")
    }

    @Test func aPermissionWithoutASummaryStillNamesItself() {
        // No trailing separator dangling off the end of the row.
        #expect(permission(summary: nil).headline == "Run command")
        #expect(permission(summary: "").headline == "Run command")
    }

    @Test func aPermissionWithoutADisplayNameFallsBackToTheToolName() {
        #expect(permission(displayName: nil, summary: nil).headline == "Bash")
    }

    @Test func aQuestionHeadlineIsTheWholePromptUnclipped() {
        // The spoken form clips at 160 characters because a long question read
        // aloud is unlistenable. On screen it wraps, and clipping it there
        // would hide the choice the buttons are asking about.
        let long = String(repeating: "Which branch should this target? ", count: 8)
        let item = TabNeedsYou.question(TabNeedsYou.Question(
            workspaceID: WorkspaceID(rawValue: "ws"),
            chatID: ChatID(rawValue: "chat"),
            question: AgentQuestion(
                turnID: TurnID(rawValue: "turn"),
                id: QuestionID(rawValue: "q1"),
                prompt: long,
                options: [AgentQuestion.Option(label: "main")]
            )
        ))
        #expect(item.headline == long)
        #expect(item.spokenSummary.count < long.count)
    }

    @Test func thePlaceLabelNamesTheWorkspaceAndTheTab() {
        #expect(
            permission().placeLabel(workspace: "kailash", tab: "Token refresh")
                == "kailash / Token refresh"
        )
    }

    @Test func anUnnamedTabDegradesToTheWorkspaceAlone() {
        // The summaries lag behind an event by a frame or two, and a row that
        // says "kailash / " reads as a bug rather than a loading state.
        #expect(permission().placeLabel(workspace: "kailash", tab: nil) == "kailash")
        #expect(permission().placeLabel(workspace: "kailash", tab: "") == "kailash")
        #expect(
            permission().placeLabel(workspace: nil, tab: nil) == "another workspace"
        )
    }
}
