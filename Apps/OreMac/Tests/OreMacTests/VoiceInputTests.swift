import Testing
import OreProtocol
@testable import OreMac

struct VoiceTranscriptAssemblerTests {
    @Test func segmentsAccumulateFinalsAndReplaceTheVolatileHypothesis() {
        var assembler = VoiceTranscriptAssembler()
        assembler.applySegment("Add a ", isFinal: false)
        #expect(assembler.text == "Add a ")

        assembler.applySegment("Add a test ", isFinal: false)
        #expect(assembler.text == "Add a test ")

        assembler.applySegment("Add a test for the parser. ", isFinal: true)
        #expect(assembler.text == "Add a test for the parser. ")

        assembler.applySegment("Then run it.", isFinal: false)
        #expect(assembler.text == "Add a test for the parser. Then run it.")
    }

    @Test func utterancesReplaceTheWholeInFlightPhrase() {
        var assembler = VoiceTranscriptAssembler()
        assembler.applyUtterance("fix the", isFinal: false)
        assembler.applyUtterance("fix the login bug", isFinal: false)
        #expect(assembler.text == "fix the login bug")
        assembler.applyUtterance("fix the login bug", isFinal: true)
        #expect(assembler.text == "fix the login bug")
    }

    @Test func discardingCommittedTextDropsAlreadyRecognizedWords() {
        var assembler = VoiceTranscriptAssembler()
        assembler.applySegment("add a test for the parser", isFinal: true)
        assembler.discardCommitted()
        #expect(assembler.text.isEmpty)

        assembler.applySegment(" and then run it", isFinal: false)
        #expect(assembler.text == "and then run it")
    }

    @Test func aNewHypothesisAfterDiscardDoesNotRestoreDeletedWords() {
        var assembler = VoiceTranscriptAssembler()
        assembler.applyUtterance("hello world", isFinal: false)
        assembler.discardCommitted()
        assembler.applyUtterance("foo", isFinal: false)
        #expect(assembler.text == "foo")
    }
}

struct VoiceIntentExtractorTests {
    private let catalog = VoiceSettingsCatalog(
        models: [
            VoiceModelCandidate(
                harness: .claudeCode, id: "claude-sonnet-5[1m]", displayName: "Sonnet 5 · 1M",
                isDefault: true
            ),
            VoiceModelCandidate(
                harness: .claudeCode, id: "claude-opus-5", displayName: "Opus 5"
            ),
            VoiceModelCandidate(
                harness: .codex, id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", isDefault: true
            ),
            VoiceModelCandidate(
                harness: .codex, id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna"
            ),
            VoiceModelCandidate(
                harness: .cursorAgent, id: "composer-2.5", displayName: "Composer 2.5"
            ),
        ],
        efforts: Array(ReasoningEffort.allCases),
        modes: Array(PermissionMode.allCases)
    )

    private func extract(_ spoken: String) -> VoiceIntents {
        VoiceIntentExtractor.extract(from: spoken, catalog: catalog)
    }

    @Test func clipboardPhrasesAreDetectedAndFilenamesStaySpoken() {
        let spoken = "Hi, so I'm trying to build something for this project. I have a screenshot attached. Maybe you can take that look that screenshot is in my clipboard use that and something more that I want is there is another file in this project which is get Klein.Swift so we want to use that file as well"
        let intents = extract(spoken)
        #expect(intents.attachClipboard)
        #expect(intents.rewritten.lowercased().contains("get klein"))
        #expect(!intents.rewritten.contains("@GitClient.swift"))
    }

    @Test func spokenFilenamesAreLeftForTheAgent() {
        let intents = extract("look at chat pane and voice input")
        #expect(intents.rewritten.lowercased().contains("chat pane"))
        #expect(intents.rewritten.lowercased().contains("voice input"))
        #expect(!intents.rewritten.contains("@"))
    }

    @Test func aClientMeetingDoesNotInventAFileChip() {
        let intents = extract("we have a client meeting about the login bug")
        #expect(!intents.rewritten.contains("@"))
        #expect(intents.rewritten.lowercased().contains("client meeting"))
    }

    @Test func incidentalSonnetAndEffortAreIgnored() {
        let poem = extract("I wrote a sonnet about the login bug")
        #expect(poem.model == nil)
        #expect(!poem.rewritten.lowercased().contains("sonnet") || poem.model == nil)
        #expect(poem.rewritten.lowercased().contains("sonnet"))

        let wasted = extract("the effort was wasted on that refactor")
        #expect(wasted.effort == nil)
        #expect(wasted.rewritten.lowercased().contains("effort"))

        let vacation = extract("I want to plan a vacation after this ships")
        #expect(vacation.permissionMode == nil)

        let hopes = extract("I have high hopes for this patch")
        #expect(hopes.effort == nil)

        let song = extract("the composer of this soundtrack wrote a theme")
        #expect(song.model == nil)

        let bypass = extract("bypass the flaky test and just look at ChatPane")
        #expect(bypass.permissionMode == nil)

        let accept = extract("please accept the meeting invite after this ships")
        #expect(accept.permissionMode == nil)
    }

    @Test func catalogModelAndEffortAreAppliedAndStripped() {
        let intents = extract("look at chat pane and switch this chat to Sonnet 5 with maximum reasoning effort")
        #expect(intents.model?.displayName == "Sonnet 5 · 1M")
        #expect(intents.effort == .max)
        #expect(intents.rewritten.lowercased().contains("chat pane"))
        #expect(!intents.rewritten.contains("@"))
        #expect(!intents.rewritten.lowercased().contains("sonnet"))
        #expect(!intents.rewritten.lowercased().contains("maximum"))
        #expect(!intents.rewritten.lowercased().contains("reasoning effort"))
        #expect(intents.rewritten.lowercased().contains("look at"))
    }

    @Test func switchingHarnessUsesTheListedCatalog() {
        let intents = extract("change the agent harness to Codex for this")
        #expect(intents.model?.harness == .codex)
        #expect(!intents.rewritten.lowercased().contains("codex"))
    }

    @Test func opusAndHighEffortAreAppliedFromTheCatalog() {
        let intents = extract("switch this chat to Opus 5 with high reasoning effort and look at ChatPane")
        #expect(intents.model?.displayName == "Opus 5")
        #expect(intents.effort == .high)
        #expect(!intents.rewritten.lowercased().contains("opus"))
        #expect(!intents.rewritten.lowercased().contains("high reasoning"))
        #expect(intents.rewritten.lowercased().contains("chatpane"))
    }

    @Test func planModeIsStrippedWhenItIsASetting() {
        let intents = extract("switch this agent to plan mode and look at ChatPane")
        #expect(intents.permissionMode == .plan)
        #expect(!intents.rewritten.lowercased().contains("plan mode"))
        #expect(intents.rewritten.lowercased().contains("chatpane"))
    }

    /// The case that sent us here: dictation hears "GPT-5.6 Sol" as "GPT sole",
    /// and the old embedding matcher scored that 0.483 against a 0.62 floor.
    @Test func misheardModelNamesStillSwitch() {
        let sole = extract("use GPT sole model")
        #expect(sole.model?.id == "gpt-5.6-sol")
        #expect(sole.rewritten.isEmpty)

        let spelled = extract("switch this chat to GPT five point six sol and fix the login bug")
        #expect(spelled.model?.id == "gpt-5.6-sol")
        #expect(spelled.rewritten == "fix the login bug")

        let spaced = extract("run this on GPT 5.6 Luna instead")
        #expect(spaced.model?.id == "gpt-5.6-luna")
    }

    /// Naming only the harness picks that harness's default model, and does not
    /// depend on dictionary iteration order.
    @Test func harnessNamesResolveToTheirDefaultModel() {
        for _ in 0..<25 {
            #expect(extract("switch to Codex").model?.id == "gpt-5.6-sol")
            #expect(extract("use the Claude Code harness").model?.harness == .claudeCode)
        }
    }

    /// "high reasoning effort" is self-qualifying; it should not need a cue verb
    /// in front of it, while "high hopes" must still stay prose.
    @Test func effortAppliesWithoutASwitchVerb() {
        let trailing = extract("fix the login bug, high reasoning effort")
        #expect(trailing.effort == .high)
        #expect(trailing.rewritten.lowercased().contains("login bug"))
        #expect(!trailing.rewritten.lowercased().contains("reasoning"))

        #expect(extract("I have high hopes for this patch").effort == nil)
        #expect(extract("the effort was wasted on that refactor").effort == nil)
    }

    @Test func changesAreReportedInSpokenOrderForTheTrail() {
        let intents = extract("switch this chat to Opus 5 with high reasoning effort in plan mode")
        #expect(intents.changes.map(\.kind) == [.model, .effort, .mode])
        #expect(intents.changes.map(\.label) == ["Opus 5", "High", "Plan"])
        #expect(intents.changes[0].consumed.lowercased().contains("opus"))
    }

    /// Extraction runs on every partial transcript (~10×/second while the mic is
    /// open), so it must not stall.
    ///
    /// The bounds are deliberately far above the measured cost — roughly 3ms for
    /// a typical utterance and 23ms for a very long one on this machine — because
    /// a timing test that sits near the real number only ever reports CI load.
    /// What they genuinely catch is a return to something with a startup cost:
    /// the previous sentence-embedding matcher paid a multi-hundred-millisecond
    /// model load on the very first call, which is why the mic used to hitch.
    @Test func extractionDoesNotStallOnPartialTranscripts() {
        let typical = "look at the chat pane and fix the login bug, "
            + "then switch this chat to Opus 5 with high reasoning effort"

        // Cold path: no lazily-loaded model may hide behind the first call.
        let coldStarted = ContinuousClock.now
        _ = extract(typical)
        #expect(ContinuousClock.now - coldStarted < .milliseconds(60))

        func perCall(_ spoken: String, iterations: Int) -> Duration {
            _ = extract(spoken)
            let started = ContinuousClock.now
            for _ in 0..<iterations { _ = extract(spoken) }
            return (ContinuousClock.now - started) / iterations
        }

        #expect(perCall(typical, iterations: 200) < .milliseconds(15))

        // A long dictated prompt is the worst case; cost is linear in words.
        let long = String(repeating: "look at the parser and fix the login bug there ", count: 20)
            + "then switch this chat to Opus 5 with high reasoning effort"
        #expect(perCall(long, iterations: 50) < .milliseconds(90))
    }

    @Test func unlistedCatalogNamesStillSwitchWithoutAWordList() {
        let custom = VoiceSettingsCatalog(
            models: [
                VoiceModelCandidate(
                    harness: .claudeCode, id: "made-up-zephyr", displayName: "Zephyr Quilt"
                )
            ],
            efforts: [.max],
            modes: [.plan]
        )
        let intents = VoiceIntentExtractor.extract(
            from: "switch this chat to Zephyr Quilt and look at ChatPane", catalog: custom
        )
        #expect(intents.model?.displayName == "Zephyr Quilt")
        #expect(!intents.rewritten.lowercased().contains("zephyr"))
        #expect(intents.rewritten.lowercased().contains("chatpane"))
    }
}

struct ComposerPasteboardTests {
    @Test func copyKeepsMentionedChipsAndWholeDraftShelf() {
        let image = Attachment(
            relativePath: ".context/attachments/aa-pasted-image.png",
            displayName: "pasted-image.png",
            mimeType: "image/png"
        )
        let file = Attachment(relativePath: "Sources/GitClient.swift", displayName: "GitClient.swift")
        let shelf = Attachment(
            relativePath: ".context/attachments/bb-notes.txt",
            displayName: "notes.txt"
        )
        let draft = "Look at @GitClient.swift and @pasted-image.png"
        let whole = ComposerPasteboard.payload(
            forCopiedText: draft,
            fullDraft: draft,
            attachments: [image, file, shelf],
            inlinePaths: [image.relativePath]
        )
        #expect(Set(whole.attachments.map(\.displayName)) == ["GitClient.swift", "pasted-image.png", "notes.txt"])
        #expect(whole.inlinePaths == [image.relativePath])

        let partial = ComposerPasteboard.payload(
            forCopiedText: "@GitClient.swift",
            fullDraft: draft,
            attachments: [image, file, shelf],
            inlinePaths: [image.relativePath]
        )
        #expect(partial.attachments.map(\.displayName) == ["GitClient.swift"])
        #expect(partial.inlinePaths.isEmpty)
    }
}

struct VoiceDraftTests {
    @Test func spokenTextStandsAloneWhenTheComposerIsEmpty() {
        #expect(VoiceDraft.combined(prefix: "", transcript: "  open the diff  ") == "open the diff")
    }

    @Test func spokenTextIsAppendedToAnExistingDraft() {
        #expect(
            VoiceDraft.combined(prefix: "Please", transcript: "add a test")
                == "Please add a test"
        )
        #expect(
            VoiceDraft.combined(prefix: "Please ", transcript: "add a test")
                == "Please add a test"
        )
    }

    @Test func anEmptyTranscriptLeavesTheDraftUntouched() {
        #expect(VoiceDraft.combined(prefix: "keep me", transcript: "   ") == "keep me")
    }
}
