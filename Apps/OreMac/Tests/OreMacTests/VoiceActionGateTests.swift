import Foundation
import Testing
import OreProtocol

@testable import OreMac

/// Chrome commands peeled out of dictation. The bar throughout: a false
/// positive clicks something the user did not ask for; a false negative costs
/// them a shortcut. When in doubt, leave the words for the agent.
struct VoiceActionGateTests {
    private func consume(_ spoken: String) -> VoiceChromeIntents {
        VoiceActionGate.consume(spoken, usingAliases: true)
    }

    // MARK: - Ordinary speech is untouched

    @Test func aCodingRequestIsLeftWhole() {
        let spoken = "Add tests for VoiceInput and figure out why startup is slow."
        let intents = consume(spoken)
        #expect(intents.actions.isEmpty)
        #expect(intents.rewritten == spoken)
    }

    @Test func aBareNounIsNotAPaneCommand() {
        #expect(consume("I wrote a sidebar component").actions.isEmpty)
        #expect(consume("the review comments are noisy").actions.isEmpty)
        #expect(consume("open the terminal pane file").actions.isEmpty)
    }

    @Test func anIncompletePrefixDoesNotFire() {
        #expect(consume("open the").actions.isEmpty)
        #expect(consume("hide the").actions.isEmpty)
        #expect(consume("new").actions.isEmpty)
    }

    @Test func newTableIsNotANewTab() {
        #expect(consume("add a new table for users").actions.isEmpty)
    }

    // MARK: - Chrome-only speech

    @Test func collapsingTheSidebarConsumesTheUtterance() {
        let intents = consume("collapse the sidebar")
        #expect(intents.actions == [.sidebarHide])
        #expect(intents.rewritten.isEmpty)
        #expect(intents.changes.contains { $0.kind == .chrome && $0.label == "Hide Sidebar" })
    }

    @Test func pleaseAloneIsNotATurn() {
        let intents = consume("please hide the sidebar")
        #expect(intents.actions == [.sidebarHide])
        #expect(intents.rewritten.isEmpty)
    }

    @Test func showAndHideAreDirected() {
        #expect(consume("show the sidebar").actions == [.sidebarShow])
        #expect(consume("hide the review pane").actions == [.reviewHide])
        #expect(consume("open the terminal").actions == [.terminalOpen])
        #expect(consume("collapse the terminal").actions == [.terminalCollapse])
    }

    @Test func newTabAndCycle() {
        #expect(consume("open a new tab").actions == [.chatTabCreate])
        #expect(consume("next tab").actions == [.chatTabNext])
        #expect(consume("previous chat tab").actions == [.chatTabPrevious])
    }

    @Test func muteNeedsTheCue() {
        #expect(consume("mute the assistant").actions == [.assistantMute])
        #expect(consume("ask the assistant to fix the tests").actions.isEmpty)
    }

    // MARK: - Mixed utterances

    @Test func chromeClipsAndTheWorkRemains() {
        let intents = consume("collapse the sidebar and then add tests for VoiceInput")
        #expect(intents.actions == [.sidebarHide])
        #expect(intents.rewritten == "add tests for VoiceInput")
    }

    @Test func twoChromeCommandsCanFireInOneBreath() {
        let intents = consume("hide the sidebar and open the terminal")
        #expect(intents.actions == [.sidebarHide, .terminalOpen])
        #expect(intents.rewritten.isEmpty)
    }

    @Test func settingsClausesSurviveForTheExtractor() {
        let intents = consume("collapse the sidebar and switch to Codex")
        #expect(intents.actions == [.sidebarHide])
        let settings = VoiceIntentExtractor.extract(
            from: intents.rewritten,
            catalog: VoiceSettingsCatalog(
                models: [
                    VoiceModelCandidate(
                        harness: .codex, id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol",
                        isDefault: true
                    )
                ],
                efforts: [],
                modes: []
            )
        )
        #expect(settings.model?.harness == .codex)
        #expect(settings.rewritten.isEmpty)
    }

    @Test func aFileReferenceAfterOpenTerminalIsNotChrome() {
        let spoken = "open the terminal pane file and add a test"
        let intents = consume(spoken)
        #expect(intents.actions.isEmpty)
        #expect(intents.rewritten == spoken)
    }

    @Test func spokenParaphrasesHideTheLeftPane() {
        #expect(consume("hide the left sidebar").actions == [.sidebarHide])
        #expect(consume("shut the left panel").actions == [.sidebarHide])
        #expect(consume("close the left side bar").actions == [.sidebarHide])
        #expect(consume("hide the left pane").actions == [.sidebarHide])
        #expect(consume("hide that sidebar").actions == [.sidebarHide])
        #expect(consume("show the left panel").actions == [.sidebarShow])
        #expect(consume("bring up the terminal").actions == [.terminalOpen])
        #expect(consume("hide the right panel").actions == [.reviewHide])
        #expect(consume("close the right one").actions == [.reviewHide])
        #expect(consume("I don't want to see the terminal").actions == [.terminalCollapse])
        #expect(consume("shut the terminal").actions == [.terminalCollapse])
    }

    @Test func wrappersDoNotBecomeAnAssistantTurn() {
        #expect(consume("could you hide the sidebar").rewritten.isEmpty)
        #expect(consume("can you open the terminal").rewritten.isEmpty)
        #expect(consume("please hide that sidebar").rewritten.isEmpty)
        #expect(consume("could you hide the sidebar").actions == [.sidebarHide])
    }

    @Test func mixedSpeechKeepsWorkAndDropsChromeWords() {
        let intents = consume("could you hide the sidebar and add tests for VoiceInput")
        #expect(intents.actions == [.sidebarHide])
        #expect(intents.rewritten == "add tests for VoiceInput")
        #expect(!intents.rewritten.lowercased().contains("sidebar"))
        #expect(!intents.rewritten.lowercased().contains("hide"))
    }

    /// Spoken chrome people actually try. A miss here is a pane that does
    /// not move; a hit on ordinary coding talk is a pane that moves by accident.
    @Test func phraseMatrix() {
        let fires: [(String, ChromeCommand)] = [
            ("hide the sidebar", .sidebarHide),
            ("hide sidebar", .sidebarHide),
            ("collapse the sidebar", .sidebarHide),
            ("close the sidebar", .sidebarHide),
            ("shut the left panel", .sidebarHide),
            ("hide the left pane", .sidebarHide),
            ("hide that sidebar", .sidebarHide),
            ("show the sidebar", .sidebarShow),
            ("open the left panel", .sidebarShow),
            ("open the terminal", .terminalOpen),
            ("open terminal", .terminalOpen),
            ("show the terminal", .terminalOpen),
            ("bring up the terminal", .terminalOpen),
            ("hide the terminal", .terminalCollapse),
            ("hide the review", .reviewHide),
            ("hide the right pane", .reviewHide),
            ("open a new tab", .chatTabCreate),
            ("mute the assistant", .assistantMute),
        ]
        for (spoken, command) in fires {
            let intents = consume(spoken)
            #expect(intents.actions == [command], "expected \(command) for \(spoken)")
            #expect(intents.rewritten.isEmpty, "chrome-only \(spoken) leaked \(intents.rewritten)")
        }

        let silent = [
            "Add tests for VoiceInput and figure out why startup is slow.",
            "I wrote a sidebar component",
            "the review comments are noisy",
            "open the terminal pane file",
            "add a new table for users",
            "hide the",
            "open the",
            "ask the assistant to fix the tests",
        ]
        for spoken in silent {
            #expect(consume(spoken).actions.isEmpty, "false positive for \(spoken)")
            #expect(consume(spoken).rewritten == spoken)
        }
    }
}

/// Hold-to-talk never waits for a finish phrase: aliases must fire as the
/// live transcript grows, including when confirmed is still empty.
struct LiveChromeReducerTests {
    @Test func holdToTalkUsesTheVolatileTranscriptUntilConfirmedExists() {
        #expect(
            LiveChromeSpeech.source(confirmed: "", transcript: "hide the sidebar")
                == "hide the sidebar"
        )
        #expect(
            LiveChromeSpeech.source(
                confirmed: "hide the sidebar. ",
                transcript: "hide the sidebar. then run tests"
            ) == "hide the sidebar."
        )
    }

    @Test func growingHoldToTalkSpeechHidesTheSidebarThenOpensTheTerminal() {
        var session = LiveChromeReducer()
        #expect(session.consumeAliases("hide", usingAliases: true).actions.isEmpty)
        #expect(session.consumeAliases("hide the", usingAliases: true).actions.isEmpty)
        let hide = session.consumeAliases("hide the sidebar", usingAliases: true)
        #expect(hide.actions == [.sidebarHide])
        #expect(session.consumeAliases("hide the sidebar", usingAliases: true).actions.isEmpty)
        let terminal = session.consumeAliases("hide the sidebar and open the terminal", usingAliases: true)
        #expect(terminal.actions == [.terminalOpen])
    }

    @Test func shutTheLeftPanelIsALiveSidebarHide() {
        var session = LiveChromeReducer()
        #expect(session.consumeAliases("shut the left panel", usingAliases: true).actions == [.sidebarHide])
    }

    @Test func livePathLeavesTheCatalogIdle() {
        #expect(!VoiceActionGate.aliasesEnabled)
        #expect(VoiceActionGate.consume("hide the sidebar").actions.isEmpty)
        #expect(VoiceActionGate.consume("hide the sidebar").rewritten == "hide the sidebar")
        var session = LiveChromeReducer()
        #expect(session.consumeAliases("hide the sidebar").actions.isEmpty)
    }

    @Test func layaSeesOnlyWordsAfterTheLastChromeAction() {
        #expect(LiveChromeAsk.residual(in: "hide the sidebar", usingAliases: true).isEmpty)
        #expect(
            LiveChromeAsk.residual(
                in: "hide the sidebar and tuck the file list away",
                usingAliases: true
            ) == "tuck the file list away"
        )
        #expect(
            LiveChromeAsk.question(
                spoken: "hide the sidebar",
                lastResidual: ""
            ) == "hide the sidebar"
        )
        #expect(
            LiveChromeAsk.question(
                spoken: "hide the sidebar and tuck the file list away",
                lastResidual: "hide the sidebar"
            ) == "hide the sidebar and tuck the file list away"
        )
        let chrome = VoiceChromeIntents(
            actions: [.sidebarHide], rewritten: "shut the left sidebar", changes: []
        )
        #expect(
            LiveChromeAsk.question(
                spoken: "close the right sidebar and then shut the left sidebar",
                lastResidual: "close the right sidebar and then shut the left sidebar",
                chrome: chrome,
                actedOn: "close the right sidebar and then shut the left sidebar"
            ) == "shut the left sidebar"
        )
        #expect(
            LiveChromeAsk.question(
                spoken: "close the right sidebar and then shut the left sidebar",
                lastResidual: "shut the left sidebar",
                chrome: chrome,
                actedOn: "close the right sidebar and then shut the left sidebar"
            ) == nil
        )
    }

    @Test func aParaphraseWithNoAliasIsTheWholeLayaQuestion() {
        #expect(
            LiveChromeAsk.question(
                spoken: "tuck the file list away",
                lastResidual: ""
            ) == "tuck the file list away"
        )
    }
}

@MainActor
struct ChromeLayoutTests {
    @Test func writersUseTheSameKeysTheWindowObserves() {
        let defaults = UserDefaults.standard
        let sidebar = defaults.object(forKey: ChromeLayout.sidebarKey)
        let review = defaults.object(forKey: ChromeLayout.reviewKey)
        let pane = defaults.object(forKey: ChromeLayout.bottomPaneKey)
        defer {
            defaults.set(sidebar, forKey: ChromeLayout.sidebarKey)
            defaults.set(review, forKey: ChromeLayout.reviewKey)
            defaults.set(pane, forKey: ChromeLayout.bottomPaneKey)
            ChromeLayoutStore.shared.reloadFromDefaults()
        }

        ChromeLayout.showsSidebar = false
        #expect(!ChromeLayout.showsSidebar)
        #expect(!ChromeLayoutStore.shared.showsSidebar)
        ChromeLayout.showsSidebar = true
        #expect(ChromeLayout.showsSidebar)
        #expect(ChromeLayoutStore.shared.showsSidebar)

        ChromeLayout.showsReview = false
        #expect(!ChromeLayout.showsReview)
        ChromeLayout.showsReview = true
        #expect(ChromeLayout.showsReview)

        ChromeLayout.showsTerminal = true
        #expect(ChromeLayout.showsTerminal)
        #expect(ChromeLayoutStore.shared.showsTerminal)
        #expect(defaults.string(forKey: ChromeLayout.bottomPaneKey) == "terminal")
        ChromeLayout.showsTerminal = false
        #expect(!ChromeLayout.showsTerminal)
        #expect(defaults.string(forKey: ChromeLayout.bottomPaneKey) == "none")
    }

    @Test func performWritesTheStoreTheWindowReads() {
        let defaults = UserDefaults.standard
        let sidebar = defaults.object(forKey: ChromeLayout.sidebarKey)
        defer {
            defaults.set(sidebar, forKey: ChromeLayout.sidebarKey)
            ChromeLayoutStore.shared.reloadFromDefaults()
        }
        ChromeLayout.showsSidebar = true
        ChromeLayout.showsSidebar = false
        #expect(ChromeLayoutStore.shared.showsSidebar == false)
        ChromeLayout.showsSidebar = true
        #expect(ChromeLayoutStore.shared.showsSidebar == true)
    }

    @Test func aComposerClickIsAPaneRequest() {
        let store = ChromeLayoutStore.shared
        store.reloadFromDefaults()
        ChromeLayout.request(.find)
        #expect(store.paneRequest == .find)
        #expect(store.paneRequestID > 0)
        #expect(store.consumePaneRequest() == .find)
        #expect(store.paneRequest == nil)
    }

    @Test func aReviewTabRequestIsNotAComposerClick() {
        let store = ChromeLayoutStore.shared
        store.reloadFromDefaults()
        ChromeLayout.request(.reviewTabAllFiles)
        #expect(store.consumePaneRequest(where: { $0.isComposerControl }) == nil)
        #expect(store.paneRequest == .reviewTabAllFiles)
        #expect(store.consumePaneRequest(where: { $0.isReviewTab }) == .reviewTabAllFiles)
        #expect(store.paneRequest == nil)
    }
}

/// Send-time scrub: the coding agent must not receive window commands, even
/// when Laya left the original sentence as the "remainder".
struct AssistantChromePromptTests {
    @Test func chromeOnlySpeechIsNotAnAssistantCall() {
        #expect(
            VoiceAssistantController.assistantPrompt(
                "", spoken: "hide the sidebar", chromeRan: true
            ).isEmpty
        )
        #expect(
            VoiceAssistantController.assistantPrompt(
                "could you hide the sidebar",
                spoken: "could you hide the sidebar",
                chromeRan: true
            ).isEmpty
        )
        #expect(
            VoiceAssistantController.assistantPrompt(
                "tuck the file list away",
                spoken: "tuck the file list away",
                chromeRan: true
            ).isEmpty
        )
    }

    @Test func mixedSpeechKeepsOnlyTheWork() {
        #expect(
            VoiceAssistantController.assistantPrompt(
                "add tests for VoiceInput",
                spoken: "hide the sidebar and add tests for VoiceInput",
                chromeRan: true
            ) == "add tests for VoiceInput"
        )
        #expect(
            VoiceAssistantController.assistantPrompt(
                "close the terminal close the terminal shut the terminal",
                spoken: "close the right sidebar and then shut the left sidebar close the terminal",
                chromeRan: true
            ).isEmpty
        )
    }

    @Test func ordinaryRequestsStayIntactWhenNoChromeRan() {
        let spoken = "Add tests for VoiceInput and figure out why startup is slow."
        #expect(
            VoiceAssistantController.assistantPrompt(
                spoken, spoken: spoken, chromeRan: false
            ) == spoken
        )
    }
}
