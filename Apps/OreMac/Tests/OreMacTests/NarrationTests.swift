import Foundation
import Testing
import OreProtocol
@testable import OreMac

private let chatA = ChatID(rawValue: "chat-a")
private let chatB = ChatID(rawValue: "chat-b")

private func utterance(
    chat: ChatID = chatA,
    priority: NarrationPriority,
    kind: SpokenUtterance.Kind,
    text: String = "something"
) -> SpokenUtterance {
    SpokenUtterance(chatID: chat, priority: priority, kind: kind, text: text)
}

struct SpokenToolClassTests {
    @Test func readToolSpeaksTheBaseFileNameWithoutExtension() {
        let activity = SpokenToolClass.classify(
            name: "Read",
            displayName: nil,
            input: .object(["file_path": .string("/Users/x/repo/Apps/OreMac/ChatPane.swift")])
        )
        #expect(activity == ToolActivity(kind: .read, subject: "ChatPane"))
    }

    @Test func readLintsIsNotAFileRead() {
        // "ReadLints" contains "read"; the lint matcher must win.
        let activity = SpokenToolClass.classify(
            name: "ReadLints",
            displayName: nil,
            input: .object(["path": .string("a.swift")])
        )
        #expect(activity == nil)
    }

    @Test func checklistToolsAreSkipped() {
        for name in ["TaskCreate", "TaskUpdate", "mcp__ore__TaskUpdate", "TodoWrite"] {
            #expect(SpokenToolClass.classify(name: name, displayName: nil, input: nil) == nil)
        }
    }

    @Test func subagentCarriesItsDescription() {
        let activity = SpokenToolClass.classify(
            name: "Task",
            displayName: nil,
            input: .object(["description": .string("Explore voice mode")])
        )
        #expect(activity == ToolActivity(kind: .subagent, subject: "Explore voice mode"))
    }

    @Test func editAndWriteAreDistinguished() {
        let edit = SpokenToolClass.classify(
            name: "Edit",
            displayName: nil,
            input: .object(["file_path": .string("AppModel.swift")])
        )
        #expect(edit == ToolActivity(kind: .edit, subject: "AppModel"))

        let write = SpokenToolClass.classify(
            name: "Write",
            displayName: nil,
            input: .object(["file_path": .string("New.swift")])
        )
        #expect(write == ToolActivity(kind: .write, subject: "New"))
    }

    @Test func patchShapedInputFindsThePath() {
        // Codex-style apply_patch: the path rides in input[0].path.
        let activity = SpokenToolClass.classify(
            name: "apply_patch",
            displayName: nil,
            input: .array([.object(["path": .string("Sources/Thing.swift")])])
        )
        #expect(activity == ToolActivity(kind: .edit, subject: "Thing"))
    }

    @Test func bashSubcommandsClassifyByWhatTheyDo() {
        func bash(_ command: String) -> ToolActivity? {
            SpokenToolClass.classify(
                name: "Bash",
                displayName: nil,
                input: .object(["command": .string(command)])
            )
        }
        #expect(bash("rg -n 'foo' Sources")?.kind == .search)
        #expect(bash("cat Package.swift")?.kind == .read)
        #expect(bash("swift test --filter Narration") == ToolActivity(kind: .run, subject: "the tests"))
        #expect(bash("swift build") == ToolActivity(kind: .run, subject: "a build"))
        #expect(bash("git status") == ToolActivity(kind: .run, subject: "a git command"))
        #expect(bash("./scripts/deploy.sh") == ToolActivity(kind: .run, subject: "a command"))
    }

    @Test func listingsAndGlobsAreSilent() {
        #expect(SpokenToolClass.classify(name: "ls", displayName: nil, input: nil) == nil)
        #expect(SpokenToolClass.classify(name: "Glob", displayName: nil, input: nil) == nil)
    }
}

struct ToolActivityCoalescerTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    @Test func repeatedReadsOfOneFileSpeakOnce() {
        var coalescer = ToolActivityCoalescer()
        let read = ToolActivity(kind: .read, subject: "ChatPane")
        #expect(coalescer.absorb(read, at: t0) == nil)
        #expect(coalescer.absorb(read, at: t0) == nil)
        #expect(coalescer.flushAll() == "Now it's reading ChatPane.")
    }

    @Test func manyReadsGroupIntoACount() {
        var coalescer = ToolActivityCoalescer()
        for name in ["A", "B", "C", "D"] {
            _ = coalescer.absorb(ToolActivity(kind: .read, subject: name), at: t0)
        }
        #expect(coalescer.flushAll() == "Now it's reading four files.")
    }

    @Test func twoFilesAreNamed() {
        var coalescer = ToolActivityCoalescer()
        _ = coalescer.absorb(ToolActivity(kind: .read, subject: "AppModel"), at: t0)
        _ = coalescer.absorb(ToolActivity(kind: .read, subject: "ChatPane"), at: t0)
        #expect(coalescer.flushAll() == "Now it's reading AppModel and ChatPane.")
    }

    @Test func classChangeFlushesThePreviousBatch() {
        var coalescer = ToolActivityCoalescer()
        _ = coalescer.absorb(ToolActivity(kind: .read, subject: "AppModel"), at: t0)
        let flushed = coalescer.absorb(ToolActivity(kind: .edit, subject: "AppModel"), at: t0)
        #expect(flushed == "Now it's reading AppModel.")
        // Second phrase this coalescer has produced, so it takes the next frame.
        #expect(coalescer.flushAll() == "It's making changes to AppModel.")
    }

    @Test func flushIsAgeGated() {
        var coalescer = ToolActivityCoalescer()
        _ = coalescer.absorb(ToolActivity(kind: .read, subject: "AppModel"), at: t0)
        #expect(coalescer.flushIfDue(at: t0.addingTimeInterval(1)) == nil)
        #expect(coalescer.flushIfDue(at: t0.addingTimeInterval(5)) == "Now it's reading AppModel.")
        // Nothing pending after the flush.
        #expect(coalescer.flushIfDue(at: t0.addingTimeInterval(10)) == nil)
    }

    @Test func identicalConsecutivePhrasesDedupe() {
        var coalescer = ToolActivityCoalescer()
        _ = coalescer.absorb(ToolActivity(kind: .read, subject: "AppModel"), at: t0)
        #expect(coalescer.flushAll() == "Now it's reading AppModel.")
        // Same batch again: the rotating frame must not defeat the dedupe.
        _ = coalescer.absorb(ToolActivity(kind: .read, subject: "AppModel"), at: t0)
        #expect(coalescer.flushAll() == nil)
    }

    @Test func consecutiveReadsRotateThroughFrames() {
        var coalescer = ToolActivityCoalescer()
        var spoken: [String] = []
        for name in ["A", "B", "C", "D"] {
            _ = coalescer.absorb(ToolActivity(kind: .read, subject: name), at: t0)
            if let phrase = coalescer.flushAll() { spoken.append(phrase) }
        }
        #expect(spoken.count == 4)
        // The point of the rotation: no two consecutive reads share a frame.
        let frames = spoken.map { $0.replacingOccurrences(
            of: #" [A-D]\.$"#, with: "", options: .regularExpression
        ) }
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0 != $1 })
    }

    @Test func subagentLaunchSpeaksImmediately() {
        var coalescer = ToolActivityCoalescer()
        _ = coalescer.absorb(ToolActivity(kind: .read, subject: "AppModel"), at: t0)
        let phrase = coalescer.absorb(
            ToolActivity(kind: .subagent, subject: "Explore voice mode"),
            at: t0
        )
        #expect(phrase == "Now it's handing off to a subagent to explore voice mode.")
    }
}

struct NarrationPhraserTests {
    @Test func routineActivityHasAWideDeterministicPhraseRotation() {
        let activities = [
            ToolActivity(kind: .read, subject: "AppModel"),
            ToolActivity(kind: .search, subject: nil),
            ToolActivity(kind: .edit, subject: "ChatPane"),
        ]
        for activity in activities {
            let phrases = (0..<6).compactMap {
                NarrationPhraser.phrase(for: [activity], variant: $0)
            }
            #expect(Set(phrases).count >= 6)
        }

        let completions = (0..<6).map {
            NarrationPhraser.completionFallback(duration: nil, variant: $0)
        }
        #expect(Set(completions).count == 6)

        let plans = (0..<5).map { NarrationPhraser.planProposal(variant: $0) }
        #expect(Set(plans).count == 5)
    }

    @Test func neuralCacheCorpusContainsOnlyReusableCacheableLines() {
        let corpus = NarrationPhraser.neuralCacheCorpus
        #expect(corpus.count >= 40)
        #expect(Set(corpus).count == corpus.count)
        #expect(corpus.allSatisfy(NarrationPhraseCache.isCacheable))
        #expect(corpus.allSatisfy { !$0.contains("{}") })
    }

    @Test func permissionPrefersSummaryOverDisplayNameOverToolName() {
        func request(summary: String?, displayName: String?) -> PermissionRequest {
            PermissionRequest(
                turnID: TurnID(rawValue: "t"),
                id: PermissionRequestID(rawValue: "p"),
                toolName: "Bash",
                displayName: displayName,
                summary: summary,
                input: .null
            )
        }
        #expect(NarrationPhraser.permission(request(summary: "git push", displayName: "Bash"))
            == "It needs your permission for git push.")
        #expect(NarrationPhraser.permission(request(summary: nil, displayName: "Run command"))
            == "It needs your permission for Run command.")
        #expect(NarrationPhraser.permission(request(summary: nil, displayName: nil))
            == "It needs your permission for Bash.")
    }

    /// Colons are a visual device — in speech they degrade to a pause the
    /// listener gets no structure from. None of the spoken templates may use
    /// one.
    @Test func noSpokenTemplateUsesAColon() {
        let request = PermissionRequest(
            turnID: TurnID(rawValue: "t"),
            id: PermissionRequestID(rawValue: "p"),
            toolName: "Bash",
            displayName: nil,
            summary: "git push",
            input: .null
        )
        let question = AgentQuestion(
            turnID: TurnID(rawValue: "t"),
            id: QuestionID(rawValue: "q"),
            prompt: "Which one should I use"
        )
        let spoken = [
            NarrationPhraser.permission(request),
            NarrationPhraser.question(question),
            NarrationPhraser.planProposal(),
            NarrationPhraser.todoPhrase(
                items: [TodoItem(text: "Wire the engine", status: .inProgress)],
                previousInProgress: nil
            ).phrase ?? "",
            NarrationPhraser.completionFallback(duration: 42),
            NarrationPhraser.turnFailed("It broke"),
            NarrationPhraser.sessionError(SessionError(kind: .transport, message: "Bad token")),
            NarrationPhraser.contextCompacted(),
            NarrationPhraser.toolFailure(),
            NarrationPhraser.stopped(),
            NarrationPhraser.prefixed("It's finished.", place: "ahmed-zewail"),
            NarrationPhraser.phrase(for: [ToolActivity(kind: .read, subject: "ChatPane")]) ?? "",
        ]
        #expect(spoken.allSatisfy { !$0.contains(":") })
        #expect(spoken.allSatisfy { !$0.isEmpty })
    }

    @Test func questionTruncatesAtASentenceBoundary() {
        let question = AgentQuestion(
            turnID: TurnID(rawValue: "t"),
            id: QuestionID(rawValue: "q"),
            prompt: "Should I use UserDefaults for this. There is also the option of a SQLite column, which would require a migration and touches three more layers of the stack, but survives reinstalls."
        )
        let spoken = NarrationPhraser.question(question)
        #expect(spoken.hasPrefix("It has a question for you. Should I use UserDefaults for this."))
        #expect(!spoken.contains("survives reinstalls"))
    }

    @Test func todoSpeaksOnlyWhenTheInProgressItemChanges() {
        let items = [
            TodoItem(text: "Write tests", status: .completed),
            TodoItem(text: "Wire the engine", status: .inProgress),
        ]
        let first = NarrationPhraser.todoPhrase(items: items, previousInProgress: nil)
        #expect(first.phrase == "Next up, wire the engine.")
        #expect(first.currentInProgress == "Wire the engine")

        let repeated = NarrationPhraser.todoPhrase(
            items: items,
            previousInProgress: "Wire the engine"
        )
        #expect(repeated.phrase == nil)
    }

    @Test func directSummaryRejectsLongText() {
        #expect(NarrationPhraser.directSummary("All done, the tests pass.")
            == "All done, the tests pass.")
        let long = String(repeating: "This sentence pads the summary well past the limit. ", count: 10)
        #expect(NarrationPhraser.directSummary(long) == nil)
        #expect(NarrationPhraser.directSummary(nil) == nil)
    }

    @Test func spokenNarrationIsHygienedButNotSecondGuessed() {
        // The agent wrote the line for the ear; it gets sanitize-and-punctuate
        // only, never the length rejection `directSummary` applies.
        #expect(NarrationPhraser.spokenNarration("I fixed the flaky test")
            == "I fixed the flaky test.")
        #expect(NarrationPhraser.spokenNarration("Renamed `AppModel` to  `ChatModel`.")
            == "Renamed AppModel to ChatModel.")
        #expect(NarrationPhraser.spokenNarration(nil) == nil)
        #expect(NarrationPhraser.spokenNarration("  ") == nil)
    }

    /// A user who asks the assistant to walk them through something is asking
    /// for a long answer. Clipping it at the ambient limit is what made every
    /// spoken reply feel evasive regardless of the question.
    @Test func anAnswerTheUserAskedForIsAllowedToRunLong() throws {
        let answer = String(repeating: "This is a real explanation. ", count: 20)
        let ambient = try #require(NarrationPhraser.spokenNarration(answer))
        let asked = try #require(NarrationPhraser.spokenNarration(
            answer, limit: NarrationPolicy.assistantAnswerLimit
        ))
        #expect(asked.count > ambient.count)
        #expect(asked.count > NarrationPolicy.utteranceLimit)
    }

    /// The clip has to sit above a realistic answer, not just above the
    /// ambient limit: a multi-part question answered part by part is roughly
    /// this long, and if the cap lands under it the listener gets a truncated
    /// answer plus "there's more in the Assistant window" — the deflection the
    /// spoken reply exists to avoid.
    @Test func aMultiPartSpokenAnswerIsNotClippedIntoADeflection() throws {
        // Eight sentences of ~140 characters — the shape of "why is it slow,
        // and what would you do about it" answered properly.
        let answer = String(
            repeating: "The build slowed down because the resource step now runs on every "
                + "incremental compile instead of only on a clean one. ",
            count: 8
        )
        #expect(answer.count > 900, "the fixture must exercise the old 900-character cap")

        let spoken = try #require(NarrationPhraser.spokenNarration(
            answer, limit: NarrationPolicy.assistantAnswerLimit
        ))
        #expect(!spoken.contains("there's more in the Assistant window"))
        #expect(!spoken.hasSuffix("…"))
    }

    /// When an answer really does overrun, it has to stop somewhere the ear
    /// recognises as an ending. Cutting mid-clause and then bolting on "there's
    /// more in the Assistant window" is what made a long reply sound like it
    /// had broken rather than like it had more to give.
    @Test func anOverlongSpokenAnswerIsCutAtASentenceBoundary() throws {
        let sentence = "The resource step reruns on every incremental build."
        let answer = Array(repeating: sentence, count: 30).joined(separator: " ")
        let spoken = try #require(NarrationPhraser.spokenNarration(
            answer, limit: NarrationPolicy.assistantAnswerLimit
        ))

        let pointer = " — there's more in the Assistant window."
        #expect(spoken.hasSuffix(pointer))
        let body = String(spoken.dropLast(pointer.count))

        // Whole sentences only: the body is exactly N copies rejoined, with
        // nothing severed on the end.
        let kept = body.components(separatedBy: sentence).count - 1
        #expect(kept > 1)
        #expect(body == Array(repeating: sentence, count: kept).joined(separator: " "))
        #expect(body.count <= NarrationPolicy.assistantAnswerLimit)
    }

    /// An ellipsis is silent, so a clipped answer simply stops mid-thought and
    /// the listener has no way to know there was more of it.
    @Test func aClippedSpokenAnswerSaysThatItWasClipped() throws {
        let long = String(repeating: "word ", count: 500)
        let spoken = try #require(NarrationPhraser.spokenNarration(long))
        #expect(!spoken.hasSuffix("…"))
        #expect(spoken.hasSuffix("there's more in the Assistant window."))

        // A line that fits is left exactly as the model wrote it.
        #expect(NarrationPhraser.spokenNarration("All set") == "All set.")
    }

    @Test func planProposalWithCruxKeepsTheNudgeToRead() {
        let line = NarrationPhraser.planProposal(crux: "It would split the parser into two passes")
        #expect(line.contains("split the parser"))
        #expect(line.hasSuffix("Have a look when you're ready."))
        // A crux that sanitizes to nothing falls back to the plain line.
        #expect(NarrationPhraser.planProposal(crux: " ") == NarrationPhraser.planProposal())
    }

    @Test func sanitizeStripsWhatReadsFineButSpeaksTerribly() {
        let spoken = NarrationPhraser.sanitize(
            "Edited `ChatPane.swift` — see [the docs](https://example.com/docs) and https://example.com **now**"
        )
        #expect(!spoken.contains("`"))
        #expect(!spoken.contains("http"))
        #expect(!spoken.contains("*"))
        #expect(spoken.contains("the docs"))
    }

    @Test func sanitizeCapsAtAWordBoundary() {
        let long = String(repeating: "word ", count: 100)
        let spoken = NarrationPhraser.sanitize(long)
        #expect(spoken.count <= NarrationPolicy.utteranceLimit + 1)
        #expect(spoken.hasSuffix("…"))
    }

    @Test func spokenDurationsSoundLikeAPerson() {
        #expect(NarrationPhraser.spokenDuration(42) == "42 seconds")
        #expect(NarrationPhraser.spokenDuration(70) == "a minute")
        #expect(NarrationPhraser.spokenDuration(130) == "2 minutes")
        #expect(NarrationPhraser.spokenDuration(3700) == "an hour")
    }

    @Test func backgroundPrefixNamesThePlace() {
        #expect(NarrationPhraser.prefixed("It's finished.", place: "ahmed-zewail")
            == "Over in ahmed-zewail, it's finished.")
        // Identifier-style leads keep their capitalization.
        #expect(NarrationPhraser.prefixed("PR created.", place: "x")
            == "Over in x, PR created.")
    }

    @Test func rateLimitOnlySpeaksWhenItMatters() {
        #expect(NarrationPhraser.rateLimit(RateLimitReport(status: .allowed)) == nil)
        #expect(NarrationPhraser.rateLimit(RateLimitReport(status: .warning))
            == "You're getting close to your usage limit.")
        #expect(NarrationPhraser.rateLimit(RateLimitReport(status: .exhausted))
            == "Usage limit reached.")
    }
}

struct NarrationOriginTests {
    @Test func theTabOnScreenIsNeverAnnounced() {
        #expect(NarrationOrigin.foreground.isBackground == false)
        #expect(NarrationOrigin.foreground.spokenLabel == nil)
        #expect(NarrationOrigin.foreground.displayLabel == nil)
    }

    /// The case the workspace name can't cover: the user is already in this
    /// workspace, so the only useful thing to say is which tab.
    @Test func anotherTabInTheSameWorkspaceIsNamedByItsTab() {
        let origin = NarrationOrigin.otherTab(chatTitle: "Fix the parser")
        #expect(origin.isBackground)
        #expect(origin.spokenLabel == "the Fix the parser tab")
        #expect(origin.displayLabel == "Fix the parser")
    }

    @Test func anUntitledTabStillAnnouncesItself() {
        let origin = NarrationOrigin.otherTab(chatTitle: "   ")
        #expect(origin.spokenLabel == "another tab")
        #expect(origin.displayLabel == "Another tab")
    }

    @Test func anotherWorkspaceLeadsWithTheWorkspace() {
        let bare = NarrationOrigin.otherWorkspace(name: "ahmed-zewail", chatTitle: nil)
        #expect(bare.spokenLabel == "ahmed-zewail")
        #expect(bare.displayLabel == "ahmed-zewail")

        let titled = NarrationOrigin.otherWorkspace(
            name: "ahmed-zewail",
            chatTitle: "Fix the parser"
        )
        #expect(titled.spokenLabel == "ahmed-zewail, Fix the parser")
        #expect(titled.displayLabel == "ahmed-zewail — Fix the parser")
    }

    @Test func aPlaceReadsAsOneSentenceNotALabel() {
        let spoken = NarrationPhraser.prefixed(
            "It needs your permission for git push.",
            place: NarrationOrigin.otherTab(chatTitle: "Chat 2").spokenLabel ?? ""
        )
        #expect(spoken == "Over in the Chat 2 tab, it needs your permission for git push.")
        #expect(!spoken.contains(":"))
    }
}

struct NarrationQueueTests {
    @Test func newerProgressReplacesUnspokenProgress() {
        var queue = NarrationQueue()
        _ = queue.enqueue(utterance(priority: .progress, kind: .toolActivity, text: "Reading A."))
        _ = queue.enqueue(utterance(priority: .progress, kind: .digest, text: "Now editing B."))
        #expect(queue.items.count == 1)
        #expect(queue.items[0].text == "Now editing B.")
    }

    @Test func interruptDropsTheChatsLowerPriorityQueueAndPreempts() {
        var queue = NarrationQueue()
        _ = queue.enqueue(utterance(priority: .progress, kind: .digest))
        _ = queue.enqueue(utterance(priority: .milestone, kind: .contextCompacted))
        let effect = queue.enqueue(utterance(
            priority: .interrupt,
            kind: .permission(PermissionRequestID(rawValue: "p1")),
            text: "Permission needed."
        ))
        #expect(effect == .interruptCurrent)
        #expect(queue.items.count == 1)
        #expect(queue.items[0].priority == .interrupt)
    }

    @Test func interruptLeavesOtherChatsAlone() {
        var queue = NarrationQueue()
        _ = queue.enqueue(utterance(chat: chatB, priority: .progress, kind: .digest))
        _ = queue.enqueue(utterance(
            chat: chatA,
            priority: .interrupt,
            kind: .question,
            text: "Asking."
        ))
        #expect(queue.items.count == 2)
        // But the interrupt goes first.
        #expect(queue.next()?.chatID == chatA)
        #expect(queue.next()?.chatID == chatB)
    }

    @Test func milestoneSupersedesQueuedProgress() {
        var queue = NarrationQueue()
        _ = queue.enqueue(utterance(priority: .progress, kind: .digest, text: "Working on X."))
        _ = queue.enqueue(utterance(priority: .milestone, kind: .turnCompleted, text: "Done."))
        #expect(queue.items.map(\.text) == ["Done."])
    }

    @Test func sameKindMilestoneReplacesInPlace() {
        var queue = NarrationQueue()
        _ = queue.enqueue(utterance(priority: .milestone, kind: .turnCompleted, text: "Done in 1 minute."))
        _ = queue.enqueue(utterance(priority: .milestone, kind: .turnCompleted, text: "Done in 2 minutes."))
        #expect(queue.items.map(\.text) == ["Done in 2 minutes."])
    }

    @Test func resolvedPermissionIsNeverSpoken() {
        var queue = NarrationQueue()
        let id = PermissionRequestID(rawValue: "p1")
        _ = queue.enqueue(utterance(priority: .interrupt, kind: .permission(id), text: "Permission needed."))
        queue.invalidatePermission(id)
        #expect(queue.items.isEmpty)
    }

    @Test func aNewTurnDropsEverythingTheChatHadQueued() {
        var queue = NarrationQueue()
        _ = queue.enqueue(utterance(priority: .progress, kind: .digest))
        _ = queue.enqueue(utterance(priority: .interrupt, kind: .question))
        _ = queue.enqueue(utterance(chat: chatB, priority: .progress, kind: .digest))
        queue.dropAll(for: chatA)
        #expect(queue.items.map(\.chatID) == [chatB])
    }

    @Test func emptyTextIsDropped() {
        var queue = NarrationQueue()
        #expect(queue.enqueue(utterance(priority: .progress, kind: .digest, text: "")) == .dropped)
        #expect(queue.items.isEmpty)
    }
}

struct DigestBufferTests {
    @Test func triggerRequiresEnoughNewText() {
        var buffer = DigestBuffer()
        buffer.append(String(repeating: "a", count: 100))
        #expect(!buffer.isTriggerReady)
        buffer.append(String(repeating: "b", count: 250))
        #expect(buffer.isTriggerReady)
    }

    @Test func snapshotConsumesTheNewCounterButKeepsTheTail() {
        var buffer = DigestBuffer()
        buffer.append(String(repeating: "a", count: 400))
        let (prompt, _) = buffer.snapshot()
        #expect(prompt.contains(String(repeating: "a", count: 400)))
        #expect(!buffer.isTriggerReady)
        #expect(!buffer.text.isEmpty)
    }

    @Test func textIsTailBounded() {
        var buffer = DigestBuffer()
        buffer.append(String(repeating: "x", count: DigestBuffer.tailLimit))
        buffer.append("END")
        #expect(buffer.text.count == DigestBuffer.tailLimit)
        #expect(buffer.text.hasSuffix("END"))
    }

    @Test func clearBumpsTheGenerationSoStaleSummariesDrop() {
        var buffer = DigestBuffer()
        buffer.append(String(repeating: "a", count: 400))
        let (_, generation) = buffer.snapshot()
        buffer.clear()
        #expect(buffer.generation != generation)
        #expect(buffer.text.isEmpty)
    }

    @Test func snapshotIncludesActivityAndLastSpokenForGrounding() {
        var buffer = DigestBuffer()
        buffer.noteActivity("Reading AppModel.")
        buffer.noteSpoken("It is mapping the event flow.")
        buffer.append("thinking about queues")
        let (prompt, _) = buffer.snapshot()
        #expect(prompt.contains("Reading AppModel."))
        #expect(prompt.contains("It is mapping the event flow."))
        #expect(prompt.contains("thinking about queues"))
    }

    @Test func activityListIsBounded() {
        var buffer = DigestBuffer()
        for index in 0..<10 {
            buffer.noteActivity("Phrase \(index)")
        }
        #expect(buffer.recentActivity.count == DigestBuffer.activityLimit)
        #expect(buffer.recentActivity.last == "Phrase 9")
    }
}

struct NarrationVoiceSelectionTests {
    @Test func theSystemVoiceStandsInUntilTheNeuralWeightsAreLoaded() {
        // The download is half a gigabyte; narration during it must still be
        // audible rather than silently dropped.
        #expect(NarrationVoiceKind.neural.resolved(neuralReady: false) == .system)
        #expect(NarrationVoiceKind.neural.resolved(neuralReady: true) == .neural)
    }

    @Test func choosingTheSystemVoiceIsNotOverriddenByAReadyModel() {
        #expect(NarrationVoiceKind.system.resolved(neuralReady: true) == .system)
    }

    @Test func voiceKindSurvivesTheRoundTripThroughDefaults() {
        for kind in NarrationVoiceKind.allCases {
            #expect(NarrationVoiceKind(rawValue: kind.rawValue) == kind)
        }
    }

    @Test func neuralSynthesisUsesOneStableVoiceIdentity() {
        #expect(NeuralNarrationSynthesis.voice == "alba")
        #expect(NeuralNarrationSynthesis.temperature < 0.7)
        #expect(NeuralNarrationSynthesis.seed == 0x4F_52_45_5F_56_4F_49_43)
        #expect(NeuralNarrationSynthesis.cacheVersion.contains("stable"))
    }

    @Test func neuralSynthesisReassertsConditioningAtSentenceBoundaries() {
        let segments = NeuralNarrationSynthesis.segments(
            "It finished the parser. The tests pass! Do you want the report?"
        )
        #expect(segments == [
            "It finished the parser.",
            "The tests pass!",
            "Do you want the report?",
        ])
        #expect(NeuralNarrationSynthesis.segments("  All done.  ") == ["All done."])
        #expect(NeuralNarrationSynthesis.segments("   ").isEmpty)
    }
}

struct NarrationPreRollTests {
    /// One Pocket TTS frame is 1920 samples at 24kHz.
    private static let frameSeconds = 1920.0 / 24_000.0

    private func cushion(_ priority: NarrationPriority) -> Double {
        Double(NeuralNarrationVoice.preRollFrames(for: priority)) * Self.frameSeconds
    }

    @Test func everyPriorityBanksSomeAudioBeforeSpeaking() {
        // Starting on the first frame leaves no slack at all, which is what
        // turns a momentary dip below real time into a gap mid-sentence.
        for priority in [NarrationPriority.progress, .milestone, .interrupt] {
            #expect(cushion(priority) > 0)
        }
    }

    @Test func theCushionShrinksAsUrgencyRises() {
        // Ambient lines can afford to start late; an interjection can't.
        #expect(cushion(.progress) > cushion(.milestone))
        #expect(cushion(.milestone) > cushion(.interrupt))
    }

    @Test func ambientLinesSurviveGenerationFallingBelowRealTime() {
        // A cushion of P seconds covers an utterance of D seconds generated at
        // rate r whenever P >= D * (1 - r). Measured worst case on an M1 with
        // every core busy was 1.08x; this asserts headroom well past that,
        // down to a 0.85x dip on a five-second line.
        let spokenLine = 5.0
        let dip = 0.85
        #expect(cushion(.progress) >= spokenLine * (1 - dip))
    }

    @Test func onlyAmbientLinesTradeLatencyForFullSynthesis() {
        // Progress lines are gap-gated by seconds of enforced quiet, so
        // rendering the whole waveform first costs nothing and cannot
        // stutter; anything more urgent keeps streaming behind its cushion.
        #expect(NeuralNarrationVoice.prefersFullSynthesis(.progress))
        #expect(!NeuralNarrationVoice.prefersFullSynthesis(.milestone))
        #expect(!NeuralNarrationVoice.prefersFullSynthesis(.interrupt))
    }

    @Test func underrunReBankIsSmallerThanEveryStartingCushion() {
        // The recovery pause must read as a breath, not a restart.
        for priority in [NarrationPriority.progress, .milestone, .interrupt] {
            #expect(
                NeuralNarrationVoice.underrunReBankFrames
                    <= NeuralNarrationVoice.preRollFrames(for: priority)
            )
        }
    }

    @Test func interjectionsStayLatencyCheap() {
        // A "needs you" line that takes a second to start is a worse bug than
        // one that stutters.
        #expect(cushion(.interrupt) <= 0.4)
    }
}

/// What the assistant HUD streams while a line is being spoken. The pill used
/// to show the finished sentence with a leading ellipsis, which looked the same
/// whether the voice was on the first word or the last.
struct SpokenPrefixTests {
    private let line = "Kaguya's agent is on it."

    @Test func nothingIsRevealedBeforeTheFirstWordIsVoiced() {
        #expect(NarrationEngine.wholeWords(of: line, upTo: 0).isEmpty)
    }

    @Test func theLineIsRevealedAsItIsSpoken() {
        // Word boundaries, as `AVSpeechSynthesizer` reports them.
        #expect(NarrationEngine.wholeWords(of: line, upTo: 8) == "Kaguya's")
        #expect(NarrationEngine.wholeWords(of: line, upTo: 14) == "Kaguya's agent")
        #expect(NarrationEngine.wholeWords(of: line, upTo: line.utf16.count) == line)
    }

    /// The neural voice estimates its position from the playback clock, so it
    /// lands mid-word constantly. Half a word appearing and then completing
    /// reads as a glitch; the previous whole word is the honest thing to show.
    @Test func aMidWordEstimateFallsBackToTheLastWholeWord() {
        #expect(NarrationEngine.wholeWords(of: line, upTo: 11) == "Kaguya's")
        #expect(NarrationEngine.wholeWords(of: line, upTo: 4) == "")
    }

    /// A count past the end — the estimate rounding up on the final frame —
    /// is the whole line, not a crash.
    @Test func anOverrunIsJustTheWholeLine() {
        #expect(NarrationEngine.wholeWords(of: line, upTo: 500) == line)
        #expect(NarrationEngine.wholeWords(of: "", upTo: 3).isEmpty)
    }

    /// Emoji and accents are more than one UTF-16 unit; slicing at a raw
    /// offset must not split one.
    @Test func multiByteCharactersSurviveTheSlice() {
        let text = "Café ✅ done"
        for cut in 0...text.utf16.count {
            let prefix = NarrationEngine.wholeWords(of: text, upTo: cut)
            #expect(text.hasPrefix(prefix))
        }
    }

    @Test func intraWordProgressDoesNotRevealNewWords() {
        let line = "Kaguya's agent is on it."
        #expect(!NarrationEngine.spokenProgressWouldRevealNewWords(of: line, from: 8, to: 11))
        #expect(NarrationEngine.spokenProgressWouldRevealNewWords(of: line, from: 8, to: 14))
    }
}

/// Unit 20: an interrupted 940 MB fetch left the settings row saying "not
/// installed" with no way back to it.
@MainActor
struct NeuralVoiceInstallActionTests {
    @Test func notInstalledOffersADownloadAction() {
        #expect(NeuralNarrationVoice.Readiness.notInstalled.installActionTitle == "Download")
        #expect(NeuralNarrationVoice.Readiness.failed("no network").installActionTitle == "Try again")
        // Nothing to offer while it is already running, or already done —
        // a second press would either be a no-op or start a needless fetch.
        #expect(NeuralNarrationVoice.Readiness.installing.installActionTitle == nil)
        #expect(NeuralNarrationVoice.Readiness.ready.installActionTitle == nil)
    }
}
