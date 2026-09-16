import AVFoundation
import Foundation
import Speech
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

    @Test func punctuationDriftAfterDiscardDoesNotRestoreDeletedWords() {
        var assembler = VoiceTranscriptAssembler()
        assembler.applyUtterance("hello world extra", isFinal: false)
        assembler.discardCommitted()
        assembler.applyUtterance("Hello world extra.", isFinal: false)
        #expect(assembler.text.isEmpty)
    }

    @Test func aRevisedHypothesisAfterEditOnlyContributesNewWords() {
        var assembler = VoiceTranscriptAssembler()
        assembler.applyUtterance("add a test for the parser", isFinal: false)
        assembler.discardCommitted()
        assembler.applyUtterance("add a test now", isFinal: false)
        #expect(assembler.text == "now")
    }
}

struct VoiceFileMatcherTests {
    private let matcher = VoiceFileMatcher(files: [
        (name: "ChatPane.swift", path: "Apps/OreMac/Sources/OreMac/ChatPane.swift"),
        (name: "VoiceInput.swift", path: "Apps/OreMac/Sources/OreMac/VoiceInput.swift"),
        (name: "AppModel.swift", path: "Apps/OreMac/Sources/OreMac/AppModel.swift"),
        (name: "index.ts", path: "web/src/index.ts"),
        (name: "index.ts", path: "web/src/nested/deeper/index.ts"),
        (name: "Makefile", path: "Makefile"),
        (name: "URLSession2Helper.swift", path: "Sources/URLSession2Helper.swift"),
    ])

    private let catalog = VoiceSettingsCatalog(
        models: [], efforts: Array(ReasoningEffort.allCases), modes: Array(PermissionMode.allCases)
    )

    private func extract(_ spoken: String, excluding: Set<String> = []) -> VoiceIntents {
        VoiceIntentExtractor.extract(
            from: spoken,
            catalog: catalog,
            fileMatcher: matcher,
            excludedFilePaths: excluding
        )
    }

    @Test func subwordsSplitCamelCaseAndDigits() {
        #expect(VoiceFileMatcher.subwords(of: "ChatPane") == ["chat", "pane"])
        #expect(VoiceFileMatcher.subwords(of: "URLSession2Helper") == ["url", "session", "2", "helper"])
        #expect(VoiceFileMatcher.subwords(of: "index") == ["index"])
    }

    @Test func theFileTriggerTagsTheSpokenName() {
        let intents = extract("look at the chat pane file and fix the overflow")
        #expect(intents.files == [
            VoiceFileTag(name: "ChatPane.swift", path: "Apps/OreMac/Sources/OreMac/ChatPane.swift")
        ])
        #expect(intents.rewritten.contains("@ChatPane.swift"))
        #expect(!intents.rewritten.lowercased().contains("chat pane file"))
        #expect(intents.changes.contains { $0.kind == .file && $0.label == "@ChatPane.swift" })
    }

    @Test func aSpokenExtensionTagsWithoutTheWordFile() {
        let intents = extract("open voice input dot swift please")
        #expect(intents.files.map(\.name) == ["VoiceInput.swift"])
        #expect(intents.rewritten.contains("@VoiceInput.swift"))
    }

    @Test func asrMisrecognitionWithinAnExplicitReferenceStillMatches() {
        // "pane" heard as "pan" — one edit, within the tolerance the model
        // matcher already uses for proper nouns.
        let intents = extract("the chat pan file has a bug")
        #expect(intents.files.map(\.name) == ["ChatPane.swift"])
    }

    @Test func anExactMultiWordNameTagsWithoutACue() {
        let intents = extract("I think app model owns that state")
        #expect(intents.files.map(\.name) == ["AppModel.swift"])
        #expect(intents.rewritten.contains("@AppModel.swift"))
    }

    @Test func aSingleCommonWordNeverTagsWithoutATrigger() {
        // "index" alone is prose; only "index file" or "index dot ts" refer.
        let intents = extract("the index needs rebuilding")
        #expect(intents.files.isEmpty)
        #expect(!intents.rewritten.contains("@"))
    }

    @Test func casualProseDoesNotTag() {
        let loose = extract("we should chat about the pane of glass")
        #expect(loose.files.isEmpty)
        let meeting = extract("we have a client meeting about voices")
        #expect(meeting.files.isEmpty)
    }

    @Test func ambiguousNamesPreferTheShallowerPath() {
        let intents = extract("check the index file")
        #expect(intents.files.map(\.path) == ["web/src/index.ts"])
    }

    @Test func glueedDictationOfAFullNameMatches() {
        // Dictation sometimes writes the name verbatim: "ChatPane.swift"
        // normalizes to a single glued token.
        let intents = extract("open ChatPane.swift and look around")
        #expect(intents.files.map(\.name) == ["ChatPane.swift"])
    }

    @Test func excludedPathsAreNeverTagged() {
        let intents = extract(
            "look at the chat pane file",
            excluding: ["Apps/OreMac/Sources/OreMac/ChatPane.swift"]
        )
        #expect(intents.files.isEmpty)
        #expect(intents.rewritten.lowercased().contains("chat pane file"))
    }

    @Test func multipleReferencesAllTag() {
        let intents = extract("compare the chat pane file with voice input dot swift")
        #expect(Set(intents.files.map(\.name)) == ["ChatPane.swift", "VoiceInput.swift"])
    }

    @Test func fileReferencesComposeWithSettingsChanges() {
        let catalog = VoiceSettingsCatalog(
            models: [VoiceModelCandidate(
                harness: .claudeCode, id: "claude-opus-5", displayName: "Opus 5", isDefault: true
            )],
            efforts: Array(ReasoningEffort.allCases),
            modes: Array(PermissionMode.allCases)
        )
        let intents = VoiceIntentExtractor.extract(
            from: "switch to Opus 5 with high reasoning effort and fix the chat pane file",
            catalog: catalog,
            fileMatcher: matcher
        )
        #expect(intents.model?.displayName == "Opus 5")
        #expect(intents.effort == .high)
        #expect(intents.files.map(\.name) == ["ChatPane.swift"])
        #expect(intents.rewritten.contains("@ChatPane.swift"))
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
            VoiceModelCandidate(
                harness: .cursorAgent, id: "cursor-grok-4.6-high", displayName: "Cursor Grok 4.6"
            ),
            VoiceModelCandidate(
                harness: .cursorAgent, id: "cursor-grok-4.5-high", displayName: "Cursor Grok 4.5"
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
    /// a typical utterance and 23ms for a very long one on an M-series Mac — because
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

        // File matching must not change the budget: a real workspace index has
        // thousands of entries, and the matcher runs on every partial too.
        let files = (0..<4000).map { index in
            (name: "SourceFile\(index)Helper.swift", path: "Sources/Deep/Nested/SourceFile\(index)Helper.swift")
        }
        let matcher = VoiceFileMatcher(files: files + [
            (name: "ChatPane.swift", path: "Sources/ChatPane.swift")
        ])
        func perCallWithFiles(_ spoken: String, iterations: Int) -> Duration {
            _ = VoiceIntentExtractor.extract(from: spoken, catalog: catalog, fileMatcher: matcher)
            let started = ContinuousClock.now
            for _ in 0..<iterations {
                _ = VoiceIntentExtractor.extract(from: spoken, catalog: catalog, fileMatcher: matcher)
            }
            return (ContinuousClock.now - started) / iterations
        }
        let withReference = long + " and fix the chat pane file"
        #expect(perCallWithFiles(withReference, iterations: 50) < .milliseconds(90))
    }

    @Test func cursorVersionIsMatchedEvenWhenDictationInsertsAnArticle() {
        let spoken = extract("switch this chat to cursor 4.6 and look at ChatPane")
        #expect(spoken.model?.id == "cursor-grok-4.6-high")
        #expect(spoken.rewritten.lowercased().contains("chatpane"))
        #expect(!spoken.rewritten.lowercased().contains("cursor"))
        #expect(!spoken.rewritten.contains("4.6"))

        let grok = extract("use grok 4.6 model and fix the login bug")
        #expect(grok.model?.id == "cursor-grok-4.6-high")
        #expect(grok.rewritten == "fix the login bug")

        let cursed = extract("switch to curse a 4.6 and look at ChatPane")
        #expect(cursed.model?.id == "cursor-grok-4.6-high")
        #expect(cursed.rewritten.lowercased().contains("chatpane"))
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

    /// The live quote renders the raw transcript, not the rewritten one. These
    /// are real partials from the on-device recognizer hearing "switch to Opus
    /// five": it revises "switch to opus" into "switched to Op. 5", which the
    /// alias matcher no longer recognizes. Rewriting each partial therefore cut
    /// the clause out on one frame and put it back on the next, and the words
    /// visibly shrank and regrew mid-sentence. Formatting the raw text cannot
    /// do that — every partial is a prefix of the one after it.
    @Test func theLiveQuoteOnlyGrowsEvenWhenRecognitionRevisesACommand() {
        let partials = [
            "Hey, I am working on a new feature for the composer right now switch to op",
            "Hey, I am working on a new feature for the composer right now switch to opus",
            "Hey, I am working on a new feature for the composer right now switch to Op. five",
            "Hey, I am working on a new feature for the composer right now switched to Op. 5",
            "Hey, I am working on a new feature for the composer right now switched to Op. five and",
            "Hey, I am working on a new feature for the composer right now switched to Op. five and then",
        ]
        // Recognition genuinely is unstable here — that is the premise.
        let recognized = partials.filter { extract($0).model != nil }
        #expect(recognized.count < partials.count)

        func worstDrop(_ texts: [String]) -> Int {
            zip(texts, texts.dropFirst()).map { max(0, $0.count - $1.count) }.max() ?? 0
        }

        // Rewriting each partial loses a whole clause the moment recognition
        // stops matching; formatting the raw text can only jitter by however
        // much the recognizer itself revised a word.
        let rewritten = partials.map { extract($0).rewritten }
        let quotes = partials.map { VoiceDictationFormatter.format($0) }
        #expect(worstDrop(rewritten) > 10)
        #expect(worstDrop(quotes) <= 2)
        #expect(quotes.last?.hasSuffix("and then") == true)
    }

    /// The command clause still comes out of the text that actually gets sent.
    @Test func theCommittedTextStillDropsTheCommandAndItsDanglingConnective() {
        let intents = extract("review the layout switch to Opus 5 and")
        #expect(intents.model?.displayName == "Opus 5")
        #expect(intents.rewritten == "review the layout")
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

    /// Switching chat tabs tears the composer down, so the set of inline
    /// attachments has to be rebuilt from the restored draft — otherwise every
    /// `@pasted-image.png` pill comes back as a chip above the composer.
    @Test func inlinePathsAreRebuiltFromTheRestoredDraft() {
        let image = Attachment(
            relativePath: ".context/attachments/aa-pasted-image.png",
            displayName: "pasted-image.png",
            mimeType: "image/png"
        )
        let shelf = Attachment(
            relativePath: ".context/attachments/bb-notes.txt",
            displayName: "notes.txt"
        )
        let file = Attachment(relativePath: "Sources/GitClient.swift", displayName: "GitClient.swift")

        let restored = ComposerPasteboard.inlinePaths(
            inDraft: "Look at @GitClient.swift and @pasted-image.png",
            attachments: [image, shelf, file]
        )
        // The pasted image was typed into the draft, so it stays a pill.
        #expect(restored == [image.relativePath])
        // A shelf attachment carries no token and must remain a chip; a
        // workspace file is never a "pasted" path at all.
        #expect(!restored.contains(shelf.relativePath))
        #expect(!restored.contains(file.relativePath))
    }

    /// `uniquePastedName` numbers collisions, so one token must not match the
    /// other attachment by prefix.
    @Test func similarlyNamedPastesDoNotMatchEachOther() {
        let first = Attachment(
            relativePath: ".context/attachments/aa-pasted-image.png",
            displayName: "pasted-image.png"
        )
        let second = Attachment(
            relativePath: ".context/attachments/bb-pasted-image-2.png",
            displayName: "pasted-image-2.png"
        )
        let onlySecond = ComposerPasteboard.inlinePaths(
            inDraft: "see @pasted-image-2.png", attachments: [first, second]
        )
        #expect(onlySecond == [second.relativePath])
    }

    @Test func anEmptyDraftLeavesEverythingOnTheShelf() {
        let image = Attachment(
            relativePath: ".context/attachments/aa-pasted-image.png",
            displayName: "pasted-image.png"
        )
        #expect(ComposerPasteboard.inlinePaths(inDraft: "", attachments: [image]).isEmpty)
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

    @Test func aSpokenListIsAppendedWithoutAnExtraSpace() {
        #expect(
            VoiceDraft.combined(prefix: "Please", transcript: "- look at ChatPane")
                == "Please\n- look at ChatPane"
        )
        #expect(
            VoiceDraft.combined(prefix: "Please\n", transcript: "- look at ChatPane")
                == "Please\n- look at ChatPane"
        )
    }
}

struct VoiceFileCandidatesTests {
    private let files = [
        VoiceFileCandidates.Candidate(name: "ChatPane.swift", path: "Apps/OreMac/Sources/OreMac/ChatPane.swift"),
        VoiceFileCandidates.Candidate(name: "VoiceInput.swift", path: "Apps/OreMac/Sources/OreMac/VoiceInput.swift"),
        VoiceFileCandidates.Candidate(name: "README.md", path: "README.md"),
        VoiceFileCandidates.Candidate(name: "OreTheme.swift", path: "Apps/OreMac/Sources/OreMac/OreTheme.swift"),
    ]

    @Test func spokenWordsMatchCamelCaseFileNames() {
        let ranked = VoiceFileCandidates.rank(
            transcript: "look at the chat pane file and fix the bug",
            files: files
        )
        #expect(ranked.first?.name == "ChatPane.swift")
    }

    @Test func theBestOverlapWinsOverPartialMatches() {
        let ranked = VoiceFileCandidates.rank(
            transcript: "voice input handling in the voice input file",
            files: files
        )
        #expect(ranked.first?.name == "VoiceInput.swift")
    }

    @Test func unrelatedSpeechOffersNoCandidates() {
        let ranked = VoiceFileCandidates.rank(
            transcript: "please refactor everything to be faster",
            files: files
        )
        #expect(ranked.isEmpty)
    }

    @Test func shortNoiseWordsDoNotMatch(){
        // "md" and "at" are too short to count as evidence.
        let ranked = VoiceFileCandidates.rank(transcript: "at md", files: files)
        #expect(ranked.isEmpty)
    }

    @Test func camelCaseSplittingBreaksNamesIntoWords() {
        #expect(VoiceFileCandidates.words(in: "ChatPane.swift") == ["chat", "pane", "swift"])
        #expect(VoiceFileCandidates.words(in: "voice_input2 test") == ["voice", "input2", "test"])
    }
}

struct VoiceTurnCommitTests {
    @Test func endingTheChordSendsThePrefixAndSpokenTextCombined() {
        #expect(
            VoiceTurnCommit.resolve(.send, prefix: "Please", spokenFormatted: "add a test")
                == .send("Please add a test")
        )
        #expect(
            VoiceTurnCommit.resolve(.send, prefix: "", spokenFormatted: "open the diff")
                == .send("open the diff")
        )
    }

    @Test func silenceNeverSendsAndLeavesTheDraftAlone() {
        #expect(VoiceTurnCommit.resolve(.send, prefix: "", spokenFormatted: "  ") == .none)
        #expect(VoiceTurnCommit.resolve(.send, prefix: "keep me", spokenFormatted: "\n ") == .none)
        #expect(VoiceTurnCommit.resolve(.commitToDraft, prefix: "keep me", spokenFormatted: "") == .none)
    }

    @Test func cancellingDiscardsTheSpokenText() {
        #expect(
            VoiceTurnCommit.resolve(.cancel, prefix: "Please", spokenFormatted: "add a test")
                == .none
        )
    }

    @Test func passiveTeardownParksTheSpokenTextInTheDraft() {
        #expect(
            VoiceTurnCommit.resolve(.commitToDraft, prefix: "Please", spokenFormatted: "add a test")
                == .updateDraft("Please add a test")
        )
    }
}

struct VoiceLiveQuoteTests {
    @Test func shortDictationIsShownWhole() {
        #expect(VoiceLiveQuote.tail(of: "add a test for the parser") == "add a test for the parser")
        #expect(VoiceLiveQuote.tail(of: "") == "")
    }

    @Test func onlyTheNewestWordsSurviveALongDictation() {
        let spoken = (1...60).map(String.init).joined(separator: " ")
        let tail = VoiceLiveQuote.tail(of: spoken, maxWords: 4)
        #expect(tail == "57 58 59 60")
    }

    @Test func dictatedBreaksDoNotWrapTheOneLineQuote() {
        #expect(VoiceLiveQuote.tail(of: "first thing\n- second thing") == "first thing - second thing")
        #expect(VoiceLiveQuote.tail(of: "  padded words  ") == "padded words")
    }
}

struct VoiceDictationFormatterTests {
    @Test func spokenNewLinesBecomeRealBreaks() {
        let formatted = VoiceDictationFormatter.format(
            "Look at ChatPane new line then fix the login bug"
        )
        #expect(formatted.contains("\n"))
        #expect(formatted.lowercased().contains("chatpane"))
        #expect(formatted.lowercased().contains("login bug"))
        #expect(!formatted.lowercased().contains("new line"))
    }

    @Test func firstSecondBecomeAMarkdownList() {
        let formatted = VoiceDictationFormatter.format(
            "I need two things. First look at ChatPane. Second fix the login bug."
        )
        #expect(formatted.contains("- look at ChatPane"))
        #expect(formatted.contains("- fix the login bug"))
        #expect(formatted.lowercased().contains("i need two things"))
        #expect(!formatted.lowercased().contains("first look"))
    }

    @Test func aSingleFirstDoesNotBecomeAList() {
        let formatted = VoiceDictationFormatter.format("First look at ChatPane")
        #expect(formatted == "First look at ChatPane")
    }
}

/// Unit 14 / Unit 20: a dictation that cannot start has to say why, and say it
/// in a way the user can act on.
@MainActor
struct VoiceAvailabilityTests {
    @Test func deniedMicrophoneProducesASettingsLink() {
        let denied = VoiceAvailability.microphoneFailure(authorization: .denied)
        #expect(denied?.settingsLink == .microphone)
        #expect(denied?.message.contains("System Settings") == true)
        // macOS never re-prompts, so `.restricted` is just as final.
        #expect(VoiceAvailability.microphoneFailure(authorization: .restricted) == denied)

        // Nothing to escape from yet: these two go on to the real prompt.
        #expect(VoiceAvailability.microphoneFailure(authorization: .notDetermined) == nil)
        #expect(VoiceAvailability.microphoneFailure(authorization: .authorized) == nil)

        let speech = VoiceAvailability.speechFailure(authorization: .denied)
        #expect(speech?.settingsLink == .speechRecognition)
        #expect(VoiceAvailability.speechFailure(authorization: .authorized) == nil)
    }

    @Test func transientUnavailabilityIsNotReportedAsUnsupportedHardware() {
        let offline = VoiceAvailability.recognizerFailure(exists: true, isAvailable: false)
        #expect(offline?.message.contains("temporarily unavailable") == true)
        #expect(offline?.message.contains("this Mac") == false)
        // Nothing in System Settings fixes a dropped connection.
        #expect(offline?.settingsLink == nil)

        let unsupported = VoiceAvailability.recognizerFailure(exists: false, isAvailable: false)
        #expect(unsupported?.message.contains("this Mac") == true)

        #expect(VoiceAvailability.recognizerFailure(exists: true, isAvailable: true) == nil)
    }

    @Test func aFailedLocaleReservationIsRetriedOnTheNextAttempt() async {
        struct Refused: Error {}
        final class Attempts { var count = 0 }

        let locale = Locale(identifier: "en_US")
        let reservation = SpeechAssetReservation()
        let attempts = Attempts()

        await reservation.ensure(locale) {
            attempts.count += 1
            throw Refused()
        }
        // The attempt is not the outcome: recording it regardless is what
        // pinned a failed reservation for the whole process.
        #expect(!reservation.isReserved)
        #expect(attempts.count == 1)

        await reservation.ensure(locale) { attempts.count += 1 }
        #expect(attempts.count == 2)
        #expect(reservation.reserved == locale)

        // Once it has actually succeeded, later presses cost nothing.
        await reservation.ensure(locale) { attempts.count += 1 }
        #expect(attempts.count == 2)
    }
}
