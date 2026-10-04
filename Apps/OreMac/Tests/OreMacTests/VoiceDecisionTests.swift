import Foundation
import Testing
import OreProtocol

@testable import OreMac

struct LayaChromePolicyTests {
    private func response(
        isChrome: Double,
        action: String,
        confidence: Double,
        hasWork: Double
    ) -> SystemOneResponse {
        SystemOneResponse(answers: [
            LayaChromeQuestions.isChrome: SystemOneAnswer(choice: nil, noul: isChrome, score: nil, confidence: nil),
            LayaChromeQuestions.action: SystemOneAnswer(choice: action, noul: nil, score: nil, confidence: confidence),
            LayaChromeQuestions.hasWork: SystemOneAnswer(choice: nil, noul: hasWork, score: nil, confidence: nil),
        ])
    }

    private var available: [ChromeCommand] {
        ChromeAvailability(
            showsSidebar: true, showsReview: true, showsTerminal: false,
            chatTabCount: 2, isMuted: false
        ).availableCommands
    }

    @Test func belowThresholdDoesNotExecute() {
        let verdict = LayaChromePolicy.verdict(
            from: response(isChrome: 0.91, action: "sidebarHide", confidence: 0.40, hasWork: 0.1),
            available: available
        )
        #expect(verdict.command == nil)
    }

    @Test func chromeNoulBelowThresholdDoesNotExecute() {
        let verdict = LayaChromePolicy.verdict(
            from: response(isChrome: 0.4, action: "sidebarHide", confidence: 0.55, hasWork: 0.1),
            available: available
        )
        #expect(verdict.command == nil)
    }

    @Test func aConfidentParaphraseFiresWithoutTheNamedControlNoul() {
        let verdict = LayaChromePolicy.verdict(
            from: response(isChrome: 0.32, action: "sidebarHide", confidence: 0.84, hasWork: 0.08),
            available: available
        )
        #expect(verdict.command == .sidebarHide)
    }

    @Test func optionMassBeatsCalibratedConfidence() {
        let response = SystemOneResponse(answers: [
            LayaChromeQuestions.isChrome: SystemOneAnswer(noul: 0.51),
            LayaChromeQuestions.action: SystemOneAnswer(
                choice: "sidebarHide",
                confidence: 0.21,
                probabilities: ["none": 0.19, "sidebarHide": 0.60, "sidebarShow": 0.12]
            ),
            LayaChromeQuestions.hasWork: SystemOneAnswer(noul: 0.37),
        ])
        let verdict = LayaChromePolicy.verdict(from: response, available: available)
        #expect(verdict.command == .sidebarHide)
    }

    @Test func aClearParaphraseHidesTheSidebar() {
        let verdict = LayaChromePolicy.verdict(
            from: response(isChrome: 0.93, action: "sidebarHide", confidence: 0.88, hasWork: 0.05),
            available: available
        )
        #expect(verdict.command == .sidebarHide)
        #expect(!verdict.hasWork)
    }

    @Test func noneIsNotAClick() {
        let verdict = LayaChromePolicy.verdict(
            from: response(isChrome: 0.2, action: "none", confidence: 0.95, hasWork: 0.9),
            available: available
        )
        #expect(verdict.command == nil)
        #expect(verdict.hasWork)
    }

    @Test func anUnavailableOptionIsIgnored() {
        let verdict = LayaChromePolicy.verdict(
            from: response(isChrome: 0.9, action: "chatTabNext", confidence: 0.9, hasWork: 0.1),
            available: ChromeAvailability(
                showsSidebar: true, showsReview: true, showsTerminal: false,
                chatTabCount: 1, isMuted: false
            ).availableCommands
        )
        #expect(verdict.command == nil)
    }
}

struct VoiceDecisionTests {
    private let layout = ChromeAvailability(
        showsSidebar: true, showsReview: true, showsTerminal: false,
        chatTabCount: 2, isMuted: false
    )

    private func hideSidebarEngine() -> ScriptedTreeEngine {
        ScriptedTreeEngine([
            ("fileGate", "other"),
            ("target", "left_sidebar"),
            ("leftControl", "sidebarHide"),
        ])
    }

    @Test func aliasesWinWithoutCallingLaya() async {
        let intents = await VoiceDecision.refine(
            spoken: "collapse the sidebar and then add tests for VoiceInput",
            available: layout,
            engine: hideSidebarEngine(),
            usingAliases: true
        )
        #expect(intents.actions == [.sidebarHide])
        #expect(intents.rewritten == "add tests for VoiceInput")
    }

    @Test func aParaphraseHidesTheSidebarAndDoesNotSend() async {
        let intents = await VoiceDecision.refine(
            spoken: "tuck the file list away",
            available: layout,
            engine: hideSidebarEngine()
        )
        #expect(intents.actions == [.sidebarHide])
        #expect(intents.rewritten.isEmpty)
    }

    @Test func mixedParaphraseKeepsTheWork() async {
        let intents = await VoiceDecision.refine(
            spoken: "tuck the file list away and add tests",
            available: layout,
            engine: ScriptedTreeEngine([
                ("fileGate", "other"),
                ("target", "left_sidebar"),
                ("leftControl", "sidebarHide"),
                ("fileGate", "other"),
                ("target", "assistant"),
            ])
        )
        #expect(intents.actions == [.sidebarHide])
        #expect(intents.rewritten == "add tests")
    }

    @Test func aFileReferenceStaysNone() async {
        let spoken = "open the terminal pane file and add a test"
        let intents = await VoiceDecision.refine(
            spoken: spoken,
            available: layout,
            engine: ScriptedTreeEngine([
                ("fileGate", "other"),
                ("target", "assistant"),
                ("fileGate", "other"),
                ("target", "assistant"),
            ])
        )
        #expect(intents.actions.isEmpty)
        #expect(intents.rewritten == "open the terminal pane file add a test")
    }

    @Test func missingEngineLeavesUnknownSpeechAlone() async {
        let spoken = "tuck the file list away"
        let intents = await VoiceDecision.refine(
            spoken: spoken,
            available: layout,
            engine: nil
        )
        #expect(intents.actions.isEmpty)
        #expect(intents.rewritten == spoken)
    }

    @Test func chromeOnlyRemainderIsEmpty() {
        #expect(VoiceDecision.remainder(spoken: "shut the left panel", hasWork: false).isEmpty)
    }

    @Test func aParaphraseWithoutAWorkClauseIsNotSent() {
        #expect(
            VoiceDecision.remainder(spoken: "tuck the file list away", hasWork: true).isEmpty
        )
    }

    @Test func mixedRemainderKeepsTheWorkClause() {
        #expect(
            VoiceDecision.remainder(
                spoken: "shut the left panel and add tests",
                hasWork: true
            ) == "add tests"
        )
    }

    @Test func theNextPaneClauseSurvivesEvenWhenItIsNotCoding() {
        #expect(
            VoiceDecision.remainder(
                spoken: "close the right sidebar and then shut the left sidebar",
                hasWork: false
            ) == "shut the left sidebar"
        )
    }

    @Test func aLaterSentenceStaysAfterAPeriod() {
        #expect(
            VoiceDecision.remainder(
                spoken: "I don't want to see the terminal. close the terminal",
                hasWork: false
            ) == "close the terminal"
        )
    }

    @Test func sequentialPaneClicksPeelOneClauseAtATime() {
        let spoken = "close the right sidebar and then shut the left sidebar"
        let first = VoiceDecision.apply(
            LayaChromePolicy.Verdict(command: .reviewHide, hasWork: false, isChrome: true),
            to: spoken
        )
        #expect(first.actions == [.reviewHide])
        #expect(first.rewritten == "shut the left sidebar")

        let second = VoiceDecision.apply(
            LayaChromePolicy.Verdict(command: .sidebarHide, hasWork: false, isChrome: true),
            to: first.rewritten
        )
        #expect(second.actions == [.sidebarHide])
        #expect(second.rewritten.isEmpty)
    }

    @Test func leftoverChromeWithoutWorkIsNotAnAssistantPrompt() async {
        let intents = await VoiceDecision.refine(
            spoken: "I don't want to see the terminal",
            available: ChromeAvailability(
                showsSidebar: true, showsReview: true, showsTerminal: true,
                chatTabCount: 2, isMuted: false
            ),
            engine: ScriptedTreeEngine([
                ("fileGate", "other"),
                ("target", "terminal"),
                ("terminalScope", "dock"),
                ("dockControl", "terminalCollapse"),
            ])
        )
        #expect(intents.actions == [.terminalCollapse])
        #expect(intents.rewritten.isEmpty)
        #expect(
            VoiceAssistantController.assistantPrompt(
                intents.rewritten,
                spoken: "close the right sidebar and I don't want to see the terminal",
                chromeRan: true
            ).isEmpty
        )
    }

    @Test func aCompletedDecideIsMarkedFromTheModel() async {
        let intents = await VoiceDecision.refine(
            spoken: "tuck the file list away",
            available: layout,
            engine: hideSidebarEngine()
        )
        #expect(intents.fromModel)
        #expect(intents.actions == [.sidebarHide])
    }

    @Test func aLiveTimeoutIsNotAModelNone() async {
        let intents = await VoiceDecision.refine(
            spoken: "hide the sidebar",
            available: layout,
            engine: SlowDecisionEngine(delay: .milliseconds(250)),
            budget: .milliseconds(10)
        )
        #expect(!intents.fromModel)
        #expect(intents.actions.isEmpty)
    }

    @Test func residualAfterAnAliasWalksTheFileGateFirst() async throws {
        let leftover = LiveChromeAsk.residual(
            in: "hide the sidebar and tuck the file list away",
            usingAliases: true
        )
        #expect(leftover == "tuck the file list away")

        let engine = ScriptedTreeEngine([
            ("fileGate", "other"),
            ("target", "left_sidebar"),
            ("leftControl", "sidebarHide"),
        ])
        let intents = await VoiceDecision.refine(
            spoken: leftover,
            available: layout,
            engine: engine
        )
        #expect(intents.actions == [.sidebarHide])
        #expect(intents.rewritten.isEmpty)
        #expect(intents.fromModel)
        let request = try #require(engine.requests.first)
        #expect(request.state["message"] == leftover)
        let fileGate = try #require(request.questions["fileGate"])
        #expect(fileGate.kind == .choice)
        #expect(fileGate.criteria["named_file"] != nil)
        #expect(fileGate.criteria["other"] != nil)
        #expect(request.questions[LayaChromeQuestions.action] == nil)
        #expect(request.questions[LayaChromeQuestions.isChrome] == nil)
    }

    @Test func aNamedFileWalksThePaletteLeaf() async {
        let intents = await VoiceDecision.refine(
            spoken: "open CONTRIBUTING.md",
            available: layout,
            engine: ScriptedTreeEngine([
                ("fileGate", "named_file"),
                ("paletteControl", "openNamedFile"),
            ])
        )
        #expect(intents.actions == [.openNamedFile])
        #expect(intents.spokenFile == "CONTRIBUTING.md")
        #expect(intents.rewritten.isEmpty)
    }

    @Test func aFilenameDotDoesNotSplitAClause() {
        let parts = VoiceDecision.clauses(in: "open CONTRIBUTING.md and then hide the sidebar")
        #expect(parts.first == "open CONTRIBUTING.md")
        #expect(parts.last == "hide the sidebar")
    }

    @Test func turnOffGlassCarriesToggleSense() async {
        let intents = await VoiceDecision.refine(
            spoken: "turn off Liquid Glass",
            available: layout,
            engine: ScriptedTreeEngine([
                ("fileGate", "other"),
                ("target", "settings"),
                ("settingsIntent", "appearance"),
                ("appearanceControl", "settingsLiquidGlass"),
            ])
        )
        #expect(intents.actions == [.settingsLiquidGlass])
        #expect(intents.toggleOn == false)
    }

    @Test func twoPaneClausesWalkIndependently() async {
        let intents = await VoiceDecision.refine(
            spoken: "close the right sidebar and then shut the left sidebar",
            available: layout,
            engine: ScriptedTreeEngine([
                ("fileGate", "other"),
                ("target", "right_review"),
                ("reviewScope", "visibility"),
                ("reviewVisibility", "reviewHide"),
                ("fileGate", "other"),
                ("target", "left_sidebar"),
                ("leftControl", "sidebarHide"),
            ])
        )
        #expect(intents.actions == [.reviewHide, .sidebarHide])
        #expect(intents.rewritten.isEmpty)
    }
}

struct LayaChromeTreeTests {
    @Test func theLiveRootIsTheFileGate() {
        #expect(LayaChromeTree.root.id == "fileGate")
        let ids = Set(LayaChromeTree.root.options.map(\.id))
        #expect(ids.contains("named_file"))
        #expect(ids.contains("other"))
        #expect(!ids.contains("left_sidebar"))
    }

    @Test func namedFilesDoNotShareAHopWithTheReviewFileList() {
        let targetIDs = Set(LayaChromeTree.target.options.map(\.id))
        #expect(targetIDs.contains("right_review"))
        #expect(!targetIDs.contains("named_file"))
        #expect(targetIDs.contains("settings"))
        #expect(targetIDs.contains("finder"))
        #expect(targetIDs.contains("assistant"))
    }

    @Test func settingsGroupsStaySmall() {
        #expect(LayaChromeTree.settingsIntent.options.count <= 11)
        #expect(LayaChromeTree.appearanceControl.options.count <= 3)
        #expect(LayaChromeTree.composerControl.options.contains { $0.id == "assistantMute" })
        #expect(LayaChromeTree.terminalScope.options.contains { $0.id == "terminalRun" })
    }

    @Test func walkDescendsUntilAClick() async {
        let step = await VoiceDecision.walk(
            hop: LayaChromeTree.root,
            leftover: "hide the left sidebar",
            engine: ScriptedTreeEngine([
                ("fileGate", "other"),
                ("target", "left_sidebar"),
                ("leftControl", "sidebarHide"),
            ]),
            budget: .seconds(1)
        )
        #expect(step.answered)
        #expect(step.command == .sidebarHide)
        #expect(!step.hasWork)
    }

    @Test func anAssistantLeafIsWorkNotAClick() async {
        let step = await VoiceDecision.walk(
            hop: LayaChromeTree.root,
            leftover: "add a settings test",
            engine: ScriptedTreeEngine([
                ("fileGate", "other"),
                ("target", "assistant"),
            ]),
            budget: .seconds(1)
        )
        #expect(step.command == nil)
        #expect(step.hasWork)
    }
}

private struct SlowDecisionEngine: DecisionEngine {
    var delay: Duration

    func decide(_ request: SystemOneRequest) async -> SystemOneResponse? {
        _ = request
        try? await Task.sleep(for: delay)
        return SystemOneResponse(answers: [
            LayaChromeQuestions.isChrome: SystemOneAnswer(noul: 0.99),
            LayaChromeQuestions.action: SystemOneAnswer(
                choice: "sidebarHide", confidence: 0.99
            ),
            LayaChromeQuestions.hasWork: SystemOneAnswer(noul: 0.05),
        ])
    }
}

struct ChromeAvailabilityTests {
    @Test func aSingleTabCannotCycle() {
        let commands = ChromeAvailability(
            showsSidebar: true, showsReview: true, showsTerminal: false,
            chatTabCount: 1, isMuted: false
        ).availableCommands
        #expect(!commands.contains(.chatTabNext))
        #expect(commands.contains(.chatTabCreate))
        #expect(commands.contains(.sidebarHide))
        #expect(commands.contains(.terminalOpen))
    }

    @Test func aHiddenSidebarOffersShow() {
        let commands = ChromeAvailability(
            showsSidebar: false, showsReview: false, showsTerminal: true,
            chatTabCount: 3, isMuted: true
        ).availableCommands
        #expect(commands.contains(.sidebarShow))
        #expect(commands.contains(.reviewShow))
        #expect(commands.contains(.terminalCollapse))
        #expect(commands.contains(.assistantUnmute))
        #expect(commands.contains(.chatTabPrevious))
    }

    @Test func livePaneOptionsKeepHideAfterThePaneIsAlreadyGone() {
        let commands = ChromeAvailability(
            showsSidebar: false, showsReview: false, showsTerminal: false,
            chatTabCount: 1, isMuted: false
        ).paneCommands
        #expect(commands.contains(.sidebarHide))
        #expect(commands.contains(.reviewHide))
        #expect(commands.contains(.terminalCollapse))
        #expect(commands.contains(.sidebarShow))
        #expect(commands.contains(.reviewShow))
        #expect(commands.contains(.terminalOpen))
    }

    @Test func screenshotButtonsAreLayaOptions() {
        let commands = ChromeAvailability(
            showsSidebar: true, showsReview: true, showsTerminal: false,
            chatTabCount: 1, isMuted: true,
            permissionMode: .default, effort: .high,
            fastMode: false, supportsFast: true
        ).availableCommands
        let expected: [ChromeCommand] = [
            .workspaceReview, .gitCommit, .gitShip, .findInTranscript,
            .chatHistory, .attachFiles, .openModelChooser, .openEffortChooser,
            .composerSend, .composerFast, .permissionPlan, .permissionBypass,
            .permissionAcceptEdits, .effortLow, .effortMedium, .effortXhigh,
        ]
        for command in expected {
            #expect(commands.contains(command), "missing \(command)")
        }
        #expect(!commands.contains(.permissionAsk))
        #expect(!commands.contains(.effortHigh))
        #expect(!commands.contains(.composerStandard))
    }
}

struct SystemOneWireTests {
    @Test func aChoiceQuestionEncodesCriteriaAsAMap() throws {
        let request = LayaChromeQuestions.request(
            transcript: "shut the left panel",
            available: [.sidebarHide, .terminalOpen]
        )
        let object = request.jsonObject()
        let questions = try #require(object["questions"] as? [String: Any])
        let action = try #require(questions[LayaChromeQuestions.action] as? [String: Any])
        #expect(action["type"] as? String == "choice")
        let criteria = try #require(action["criteria"] as? [String: String])
        #expect(criteria["sidebarHide"] != nil)
        #expect(criteria["none"] != nil)
        #expect(criteria["terminalOpen"] != nil)
        #expect(!(criteria["none"]?.contains("cannot tell") ?? true))
        #expect(action["instructions"] as? String != nil)
        #expect((action["instructions"] as? String)?.contains("meaning") == true)
    }

    @Test func aResponseDecodesNoulAndChoice() throws {
        let json = """
            {"answers":{"is_chrome":{"noul":0.91},"action":{"choice":"sidebarHide","confidence":0.8,"probabilities":{"sidebarHide":0.6}},"has_work":{"noul":0.1}}}
            """.data(using: .utf8)!
        let parsed = try SystemOneResponse(json: json)
        #expect(parsed.answers[LayaChromeQuestions.isChrome]?.noul == 0.91)
        #expect(parsed.answers[LayaChromeQuestions.action]?.choice == "sidebarHide")
        #expect(parsed.answers[LayaChromeQuestions.action]?.confidence == 0.8)
        #expect(parsed.answers[LayaChromeQuestions.action]?.probabilities?["sidebarHide"] == 0.6)
    }
}

struct LiveChromeDebounceTests {
    @Test func aPeriodAsksImmediately() {
        #expect(LiveChromeDebounce.isPunctuated("hide the sidebar."))
        #expect(LiveChromeDebounce.delay(for: "hide the sidebar.") == .zero)
    }

    @Test func aCommaAsksImmediately() {
        #expect(LiveChromeDebounce.isPunctuated("tuck the file list away,"))
        #expect(LiveChromeDebounce.delay(for: "open the terminal,") == .zero)
    }

    @Test func andThenAsksImmediately() {
        #expect(LiveChromeDebounce.isPunctuated("hide the sidebar and"))
        #expect(LiveChromeDebounce.delay(for: "collapse that pane then") == .zero)
    }

    @Test func aMidPhraseWaits() {
        #expect(!LiveChromeDebounce.isPunctuated("hide the"))
        #expect(LiveChromeDebounce.delay(for: "hide the sidebar") == VoiceDecision.liveDebounce)
    }
}
