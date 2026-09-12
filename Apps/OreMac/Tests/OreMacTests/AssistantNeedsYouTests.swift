import Testing
import OreProtocol

@testable import OreMac

/// How a blocked project tab reads, and how it sounds.
///
/// Two different sentences for one event, on purpose: the row beside the Allow
/// button has to say which tool and which command, and the line the assistant
/// speaks has to sound like every other line it speaks.
struct AssistantNeedsYouRowTests {
    private func permission(
        tool: String = "Bash",
        displayName: String? = "Run command",
        summary: String? = "swift test",
        input: JSONValue = .null
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
                input: input
            )
        ))
    }

    @Test func aPermissionHeadlineNamesTheActionAndWhatItWillDo() {
        #expect(permission().headline == "Run a command — swift test")
    }

    /// The row says what will run, not what the agent said it was up to. It
    /// used to read "Bash — Search arXiv API for PerCo SD paper", which names
    /// neither the command nor the host it talks to.
    @Test func aPermissionHeadlinePrefersTheCommandOverTheDescription() {
        let row = permission(
            summary: "Search arXiv API for PerCo SD paper",
            input: .object(["command": .string("curl -s https://export.arxiv.org/api/query")])
        )
        #expect(row.headline == "Run a command — curl -s https://export.arxiv.org/api/query")
    }

    /// One line beside a button, so a long command stops rather than wrapping.
    @Test func aLongCommandIsClippedToTheRow() {
        let row = permission(input: .object(["command": .string(String(repeating: "x", count: 400))]))
        #expect(row.headline.count < 120)
        #expect(row.headline.hasSuffix("…"))
    }

    @Test func aPermissionWithoutASummaryStillNamesItself() {
        // No trailing separator dangling off the end of the row.
        #expect(permission(summary: nil).headline == "Run a command")
        #expect(permission(summary: "").headline == "Run a command")
    }

    @Test func anUnknownToolFallsBackToTheNameTheHarnessGaveIt() {
        #expect(permission(tool: "Frobnicate", displayName: nil, summary: nil).headline == "Frobnicate")
        #expect(permission(tool: "Frobnicate", displayName: "Frobnicate a thing", summary: nil)
            .headline == "Frobnicate a thing")
    }

    // MARK: - How the ask sounds

    /// The regression this suite exists to hold. The spoken prompt used to be
    /// its own template — "Quick check — A tab wants to run Bash (swift test).
    /// Yes to allow, no to deny, or always to auto-allow this tab." — spoken
    /// through the assistant's own voice, so the user heard the assistant
    /// abruptly start talking like a phone menu whenever a permission landed.
    @Test func aPermissionAskSoundsLikeTheRestOfTheNarration() {
        let spoken = permission().spokenPrompt()
        // Says what is happening, not which tool symbol is being invoked.
        #expect(spoken.contains("swift test"))
        #expect(!spoken.contains("Bash"))
        // None of the phone-tree furniture.
        #expect(!spoken.contains("Quick check"))
        #expect(!spoken.contains("A tab"))
        #expect(!spoken.lowercased().contains("no to deny"))
        #expect(!spoken.lowercased().contains("auto-allow"))
    }

    /// The choices live on the HUD placeholder and the window's buttons. What
    /// the voice owes the listener is an invitation to answer, not the list.
    @Test func aPermissionAskInvitesAnAnswer() {
        #expect(permission().spokenPrompt().hasSuffix("Okay to go ahead?"))
    }

    @Test func anAskFromAnotherWorkspaceNamesIt() {
        let spoken = permission().spokenPrompt(place: "kailash")
        #expect(spoken.hasPrefix("Over in kailash, "))
        #expect(spoken.contains("swift test"))
    }

    /// Nil place means the tab is the one on screen, and naming it would tell
    /// the user something they can already see.
    @Test func anAskFromTheTabOnScreenNamesNoPlace() {
        #expect(!permission().spokenPrompt().contains("Over in"))
        #expect(!permission().spokenPrompt(place: "").contains("Over in"))
    }

    /// A question's options *are* the ask — unlike a permission's yes/no, no
    /// button on screen spells them out while the mic is open.
    @Test func aQuestionAskStillRecitesItsChoices() {
        let item = TabNeedsYou.question(TabNeedsYou.Question(
            workspaceID: WorkspaceID(rawValue: "ws"),
            chatID: ChatID(rawValue: "chat"),
            question: AgentQuestion(
                turnID: TurnID(rawValue: "turn"),
                id: QuestionID(rawValue: "q1"),
                prompt: "Which branch should this target?",
                options: [
                    AgentQuestion.Option(label: "main"),
                    AgentQuestion.Option(label: "develop"),
                ]
            )
        ))
        #expect(item.spokenPrompt().contains("main, or develop"))
        #expect(!item.spokenPrompt().contains("Quick check"))
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

    @Test func aReadyPlanHeadlineIsTheFirstProseLine() {
        let item = TabNeedsYou.plan(TabNeedsYou.Plan(
            workspaceID: WorkspaceID(rawValue: "ws"),
            chatID: ChatID(rawValue: "chat"),
            turnID: TurnID(rawValue: "t1"),
            markdown: "## Split the parser\n1. Extract the lexer",
            permissionRequestID: nil
        ))
        #expect(item.headline == "Split the parser")
        #expect(item.spokenSummary.contains("Split the parser"))
        #expect(item.spokenPrompt().contains("split the parser"))
        #expect(item.id == "plan-chat-t1")
        #expect(item.narrationKind == .planProposal)
    }

    @Test func linkingAPermissionDoesNotChangeThePlanNeedsYouIdentity() {
        let turn = TurnID(rawValue: "t1")
        let draft = TabNeedsYou.plan(TabNeedsYou.Plan(
            workspaceID: WorkspaceID(rawValue: "ws"),
            chatID: ChatID(rawValue: "chat"),
            turnID: turn,
            markdown: "## Steps\n1. Do it",
            permissionRequestID: nil
        ))
        let linked = TabNeedsYou.plan(TabNeedsYou.Plan(
            workspaceID: WorkspaceID(rawValue: "ws"),
            chatID: ChatID(rawValue: "chat"),
            turnID: turn,
            markdown: "## Steps\n1. Do it",
            permissionRequestID: PermissionRequestID(rawValue: "r1")
        ))
        #expect(draft.id == linked.id)
    }
}
