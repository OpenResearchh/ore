import Foundation
import OreProtocol
import Testing

@testable import OreMac

@MainActor
struct ChatStateTests {
    @Test func aRepeatedToolCallUpdatesInputInsteadOfAppending() {
        let state = ChatState()
        let turnID = TurnID(rawValue: "t1")
        state.apply(.turnStarted(TurnStarted(turnID: turnID)))
        state.apply(.toolCall(ToolCall(
            turnID: turnID, id: ToolCallID(rawValue: "c1"), name: "Edit",
            displayName: "x.txt", input: .object(["file_path": .string("x.txt")])
        )))
        state.apply(.toolCall(ToolCall(
            turnID: turnID, id: ToolCallID(rawValue: "c1"), name: "Edit",
            displayName: "x.txt",
            input: .object([
                "file_path": .string("x.txt"),
                "patch": .string("--- a/x.txt\n+++ b/x.txt\n@@ -1 +1 @@\n-old\n+new\n"),
            ])
        )))

        #expect(state.rows.count == 1)
        #expect(state.rows[0].toolInput?["patch"]?.stringValue?.contains("+new") == true)
    }

    @Test func distinctTextBlockIDsAppendRatherThanMutatingTheFirstRow() {
        let state = ChatState()
        let turnID = TurnID(rawValue: "t1")
        state.apply(.turnStarted(TurnStarted(turnID: turnID)))
        state.apply(.textDelta(BlockDelta(
            turnID: turnID, blockID: BlockID(rawValue: "t1#text-0"), text: "I'll read"
        )))
        state.apply(.toolCall(ToolCall(
            turnID: turnID, id: ToolCallID(rawValue: "c1"), name: "Read",
            displayName: "x.txt", input: .object(["file_path": .string("x.txt")])
        )))
        state.apply(.textDelta(BlockDelta(
            turnID: turnID, blockID: BlockID(rawValue: "t1#text-1"), text: "Done"
        )))

        #expect(state.rows.count == 3)
        #expect(state.rows[0].text == "I'll read")
        #expect(state.rows[1].toolName == "Read")
        #expect(state.rows[2].text == "Done")
    }

    @Test func aPlanProposalStaysUntilTheUserAnswers() {
        let state = ChatState()
        let turnID = TurnID(rawValue: "t1")
        state.apply(.turnStarted(TurnStarted(turnID: turnID)))
        state.apply(.planUpdated(PlanUpdate(
            turnID: turnID,
            content: .proposal(markdown: "## Steps\n1. Do the thing", permissionRequestID: nil)
        )))
        state.apply(.statusChanged(.idle))
        state.apply(.turnCompleted(TurnResult(turnID: turnID, outcome: .completed)))

        #expect(state.status == .awaitingInput)
        guard case .proposal(let markdown, let requestID) = state.plan else {
            Issue.record("expected a plan proposal to survive turn end")
            return
        }
        #expect(requestID == nil)
        #expect(markdown.contains("Do the thing"))
        #expect(state.rows.contains { $0.kind == .plan })
        #expect(state.planTurnID == turnID)

        state.dismissPlan()
        #expect(state.plan == nil)
        #expect(state.planTurnID == nil)
        #expect(state.status == .idle)
    }

    @Test func aMutatingToolAfterAProposalDismissesTheCard() {
        let state = ChatState()
        let turnID = TurnID(rawValue: "t1")
        state.apply(.turnStarted(TurnStarted(turnID: turnID)))
        state.apply(.planUpdated(PlanUpdate(
            turnID: turnID,
            content: .proposal(markdown: "## Steps", permissionRequestID: nil)
        )))
        state.apply(.toolCall(ToolCall(
            turnID: turnID, id: ToolCallID(rawValue: "c1"), name: "Edit",
            displayName: "x.txt", input: .object(["file_path": .string("x.txt")])
        )))

        #expect(state.plan == nil)
        #expect(state.planTurnID == nil)
        #expect(state.rows.contains { $0.kind == .plan })
        #expect(state.rows.contains { $0.kind == .toolCall && $0.toolName == "Edit" })
    }

    @Test func readingAfterAProposalKeepsTheCard() {
        let state = ChatState()
        let turnID = TurnID(rawValue: "t1")
        state.apply(.turnStarted(TurnStarted(turnID: turnID)))
        state.apply(.planUpdated(PlanUpdate(
            turnID: turnID,
            content: .proposal(markdown: "## Steps", permissionRequestID: nil)
        )))
        state.apply(.toolCall(ToolCall(
            turnID: turnID, id: ToolCallID(rawValue: "c1"), name: "Read",
            displayName: "x.txt", input: .object(["file_path": .string("x.txt")])
        )))

        guard case .proposal = state.plan else {
            Issue.record("research after a proposal must not dismiss the card")
            return
        }
        #expect(state.planTurnID == turnID)
    }

    @Test func todoWriteAfterAProposalKeepsTheCard() {
        let state = ChatState()
        let turnID = TurnID(rawValue: "t1")
        state.apply(.turnStarted(TurnStarted(turnID: turnID)))
        state.apply(.planUpdated(PlanUpdate(
            turnID: turnID,
            content: .proposal(markdown: "## Steps", permissionRequestID: nil)
        )))
        state.apply(.toolCall(ToolCall(
            turnID: turnID, id: ToolCallID(rawValue: "c1"), name: "TodoWrite",
            displayName: "Updated plan", input: .object([:])
        )))
        state.apply(.planUpdated(PlanUpdate(
            turnID: turnID,
            content: .todos([TodoItem(text: "Do the thing", status: .pending)])
        )))

        guard case .proposal = state.plan else {
            Issue.record("TodoWrite after CreatePlan must not dismiss the card")
            return
        }
    }

    @Test func turnEndDropsAProposalIfTheTurnAlreadyEdited() {
        let state = ChatState()
        let turnID = TurnID(rawValue: "t1")
        state.apply(.turnStarted(TurnStarted(turnID: turnID)))
        state.apply(.toolCall(ToolCall(
            turnID: turnID, id: ToolCallID(rawValue: "c1"), name: "Edit",
            displayName: "x.txt", input: .object(["file_path": .string("x.txt")])
        )))
        // A late planUpdated (replay, coalesced flush) after the Edit would
        // resurrect the card; turnCompleted must still drop it.
        state.apply(.planUpdated(PlanUpdate(
            turnID: turnID,
            content: .proposal(markdown: "## Steps", permissionRequestID: nil)
        )))
        state.apply(.statusChanged(.idle))
        state.apply(.turnCompleted(TurnResult(turnID: turnID, outcome: .completed)))

        #expect(state.plan == nil)
        #expect(state.status == .idle)
        #expect(state.rows.contains { $0.kind == .plan })
    }

    @Test func aLaterPlanUpdateEditsTheSameRow() {
        let state = ChatState()
        let turnID = TurnID(rawValue: "t1")
        state.apply(.turnStarted(TurnStarted(turnID: turnID)))
        state.apply(.planUpdated(PlanUpdate(
            turnID: turnID, content: .proposal(markdown: "draft", permissionRequestID: nil)
        )))
        state.apply(.planUpdated(PlanUpdate(
            turnID: turnID, content: .proposal(markdown: "final", permissionRequestID: nil)
        )))
        let plans = state.rows.filter { $0.kind == .plan }
        #expect(plans.count == 1)
        #expect(plans[0].text == "final")
    }

    @Test func streamingDeltasBumpContentRevisionNotJustText() {
        let state = ChatState()
        let turnID = TurnID(rawValue: "t1")
        state.apply(.turnStarted(TurnStarted(turnID: turnID)))
        state.apply(.textDelta(BlockDelta(
            turnID: turnID, blockID: BlockID(rawValue: "b1"), text: "Hello"
        )))
        #expect(state.rows[0].contentRevision == 0)
        state.apply(.textDelta(BlockDelta(
            turnID: turnID, blockID: BlockID(rawValue: "b1"), text: " world"
        )))
        #expect(state.rows[0].text == "Hello world")
        #expect(state.rows[0].contentRevision == 1)
        #expect(state.hasRows)
        #expect(state.revertableTurns.isEmpty)
    }

    @Test func userMessagesPopulateStoredRevertableTurns() {
        let state = ChatState()
        state.appendUserMessage("go", comments: [])
        #expect(state.revertableTurns.count == 1)
        #expect(state.hasRows)
    }
}

@MainActor
struct TranscriptDisplayTests {
    @Test func derivedSignatureIgnoresGroupedTextBytes() {
        var child = TranscriptRow(
            id: "tool",
            turnID: TurnID(rawValue: "t1"),
            kind: .toolCall,
            text: "Read"
        )
        child.resultText = String(repeating: "a", count: 80_000)
        child.contentRevision = 3
        var footer = TranscriptRow(
            id: "footer",
            turnID: TurnID(rawValue: "t1"),
            kind: .turnFooter,
            text: "",
            groupedRows: [child]
        )
        footer.sealDerivedContent()
        let first = footer.activitySignature
        footer.groupedRows[0].resultText = String(repeating: "b", count: 80_000)
        footer.sealDerivedContent()
        #expect(footer.activitySignature == first)
        footer.groupedRows[0].contentRevision = 4
        footer.sealDerivedContent()
        #expect(footer.activitySignature != first)
    }

    @Test func streamingALaterTurnReusesCompletedTurnOutput() {
        let turn1 = TurnID(rawValue: "t1")
        let turn2 = TurnID(rawValue: "t2")
        var rows = [
            TranscriptRow(id: "u1", turnID: turn1, kind: .userMessage, text: "first"),
            TranscriptRow(
                id: "tool1", turnID: turn1, kind: .toolCall, text: "Read",
                resultText: String(repeating: "x", count: 20_000), isComplete: true
            ),
            TranscriptRow(id: "a1", turnID: turn1, kind: .assistantText, text: "done", isComplete: true),
            TranscriptRow(id: "u2", turnID: turn2, kind: .userMessage, text: "second"),
            TranscriptRow(id: "a2", turnID: turn2, kind: .assistantText, text: "Hi"),
        ]
        let memo = TranscriptDisplay.Memo()
        let first = TranscriptDisplay.rows(
            from: rows, keepLiveTurnExpanded: true, expanded: [], memo: memo)
        #expect(memo.completedTurnCount == 1)
        let completedIDs = first.prefix(while: { $0.turnID == turn1 }).map(\.id)

        rows[4].text += " there"
        rows[4].contentRevision += 1
        let second = TranscriptDisplay.rows(
            from: rows, keepLiveTurnExpanded: true, expanded: [], memo: memo)
        #expect(memo.completedTurnCount == 1)
        #expect(second.prefix(while: { $0.turnID == turn1 }).map(\.id) == completedIDs)
        #expect(second.last?.text == "Hi there")
    }

    /// The revision is the sole authority on `rows`, which is what lets a body
    /// evaluation that changed nothing about the transcript cost nothing. Safe
    /// only because `ChatState.rows` is `private(set)` and bumps the revision on
    /// every mutation path — this pins that contract.
    @Test func anUnchangedRevisionSkipsRederivingTheTranscript() {
        let turn = TurnID(rawValue: "t1")
        var rows = [
            TranscriptRow(id: "u1", turnID: turn, kind: .userMessage, text: "first"),
            TranscriptRow(id: "a1", turnID: turn, kind: .assistantText, text: "Hi"),
        ]
        let memo = TranscriptDisplay.Memo()
        let first = TranscriptDisplay.rows(
            from: rows, keepLiveTurnExpanded: false, expanded: [], memo: memo, revision: 1
        )

        // A mutation the revision does not describe is deliberately not seen.
        rows[1].text = "mutated behind the revision's back"
        rows[1].contentRevision += 1
        let cached = TranscriptDisplay.rows(
            from: rows, keepLiveTurnExpanded: false, expanded: [], memo: memo, revision: 1
        )
        #expect(cached.map(\.text) == first.map(\.text))

        // Bumping it re-derives.
        let fresh = TranscriptDisplay.rows(
            from: rows, keepLiveTurnExpanded: false, expanded: [], memo: memo, revision: 2
        )
        #expect(fresh.last?.text == "mutated behind the revision's back")
    }

    /// `keepLiveTurnExpanded` and `expanded` change the output without touching
    /// the rows, so they belong in the cache key alongside the revision.
    @Test func inputsOtherThanTheRowsStillInvalidateTheCache() {
        let turn = TurnID(rawValue: "t1")
        let rows = [
            TranscriptRow(id: "u1", turnID: turn, kind: .userMessage, text: "go"),
            TranscriptRow(
                id: "tool1", turnID: turn, kind: .toolCall, text: "Read",
                resultText: "out", isComplete: true
            ),
            TranscriptRow(id: "a1", turnID: turn, kind: .assistantText, text: "done", isComplete: true),
        ]
        let memo = TranscriptDisplay.Memo()
        let idle = TranscriptDisplay.rows(
            from: rows, keepLiveTurnExpanded: false, expanded: [], memo: memo, revision: 1
        )
        let busy = TranscriptDisplay.rows(
            from: rows, keepLiveTurnExpanded: true, expanded: [], memo: memo, revision: 1
        )
        #expect(idle.map(\.id) != busy.map(\.id))

        // Expanding the activity group at the same revision must re-derive too.
        let collapsed = TranscriptDisplay.rows(
            from: rows, keepLiveTurnExpanded: false, expanded: [], memo: memo, revision: 1
        )
        let expanded = TranscriptDisplay.rows(
            from: rows, keepLiveTurnExpanded: false, expanded: ["activity-t1"], memo: memo, revision: 1
        )
        #expect(expanded.count > collapsed.count)
    }

    /// A permission prompt used to flip `isBusy` off, which folded the live
    /// turn's thinking into an activity group and jumped the transcript.
    /// Expansion follows `isTurnActive`, so awaiting input keeps the turn open.
    @Test func awaitingPermissionKeepsTheLiveTurnExpanded() {
        let turn = TurnID(rawValue: "t1")
        let rows = [
            TranscriptRow(id: "u1", turnID: turn, kind: .userMessage, text: "run it"),
            TranscriptRow(
                id: "think1", turnID: turn, kind: .thinking,
                text: "I should check the sandbox first.", isComplete: true
            ),
            TranscriptRow(
                id: "tool1", turnID: turn, kind: .toolCall, text: "Bash",
                resultText: nil, isComplete: false
            ),
        ]

        let collapsedWhileWaiting = TranscriptDisplay.rows(
            from: rows, keepLiveTurnExpanded: false, expanded: [], memo: TranscriptDisplay.Memo()
        )
        #expect(collapsedWhileWaiting.contains { $0.kind == .activityGroup })
        #expect(!collapsedWhileWaiting.contains { $0.kind == .thinking })

        let openTurn = TranscriptDisplay.rows(
            from: rows, keepLiveTurnExpanded: true, expanded: [], memo: TranscriptDisplay.Memo()
        )
        #expect(!openTurn.contains { $0.kind == .activityGroup })
        #expect(openTurn.contains { $0.kind == .thinking })
        #expect(openTurn.contains { $0.id == "think1" })
    }

    @Test func sourceSignatureIsIndependentOfPayloadBytes() {
        var row = TranscriptRow(
            id: "t", turnID: TurnID(rawValue: "1"), kind: .toolCall, text: "Edit"
        )
        row.toolInput = .object(["old_string": .string(String(repeating: "a", count: 50_000))])
        row.contentRevision = 1
        let first = TranscriptDisplay.sourceSignature([row])
        row.toolInput = .object(["old_string": .string(String(repeating: "b", count: 50_000))])
        #expect(TranscriptDisplay.sourceSignature([row]) == first)
        row.contentRevision = 2
        #expect(TranscriptDisplay.sourceSignature([row]) != first)
    }

    @Test func pendingProposalIsOmittedFromTheTranscriptUntilAnswered() {
        let turn = TurnID(rawValue: "t1")
        let markdown = "## Steps\n1. Do the thing"
        let rows = [
            TranscriptRow(id: "u1", turnID: turn, kind: .userMessage, text: "plan this"),
            TranscriptRow(id: "plan", turnID: turn, kind: .plan, text: markdown),
        ]
        let hidden = TranscriptDisplay.rows(
            from: rows, keepLiveTurnExpanded: false, expanded: [], memo: TranscriptDisplay.Memo(),
            hidingPlanTurnID: turn
        )
        #expect(!hidden.contains { $0.kind == .plan })
        #expect(hidden.contains { $0.kind == .userMessage })

        let shown = TranscriptDisplay.rows(
            from: rows, keepLiveTurnExpanded: false, expanded: [], memo: TranscriptDisplay.Memo()
        )
        #expect(shown.contains { $0.kind == .plan })
    }

    @Test func aToolCallRemembersARunningLabel() {
        let state = ChatState()
        let turnID = TurnID(rawValue: "t1")
        state.apply(.turnStarted(TurnStarted(turnID: turnID)))
        state.apply(.toolCall(ToolCall(
            turnID: turnID, id: ToolCallID(rawValue: "c1"), name: "Read",
            displayName: "ChatPane.swift", input: .object([:])
        )))
        #expect(state.runningToolLabel == "Reading ChatPane.swift")
        #expect(state.lastEventAt != nil)

        state.apply(.turnCompleted(TurnResult(turnID: turnID, outcome: .completed)))
        #expect(state.runningToolLabel == nil)
        #expect(state.lastEventAt == nil)
    }

    @Test func runningToolPhrasesNameTheFile() {
        #expect(ChatState.runningToolPhrase(name: "Read", displayName: "a.swift") == "Reading a.swift")
        #expect(ChatState.runningToolPhrase(name: "Edit", displayName: "a.swift") == "Editing a.swift")
        #expect(ChatState.runningToolPhrase(name: "Bash", displayName: "git status") == "Running git status")
        #expect(ChatState.runningToolPhrase(name: "Task", displayName: "Explore") == "Running subagent · Explore")
    }

    @Test func aCodexCLIUpgradeErrorOffersAnUpdateNotAUsageLimit() {
        let state = ChatState()
        let turnID = TurnID(rawValue: "t1")
        let json = #"{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The 'gpt-5.6-sol' model requires a newer version of Codex. Please upgrade to the latest app or CLI and try again."}}"#
        state.apply(.turnStarted(TurnStarted(turnID: turnID)))
        state.apply(.turnCompleted(TurnResult(
            turnID: turnID, outcome: .failed, errorMessage: json
        )))
        #expect(state.prominentError?.needsCLIUpgrade == true)
        #expect(state.prominentError?.isUsageLimit == false)
        #expect(state.prominentError?.message.contains("requires a newer version of Codex") == true)
        #expect(state.prominentError?.message.contains("\"status\"") != true)
    }

    @Test func aRateLimitSessionErrorIsAUsageLimit() {
        let state = ChatState()
        state.apply(.rateLimit(RateLimitReport(
            status: .exhausted,
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000)
        )))
        state.apply(.sessionError(SessionError(
            kind: .rateLimited, message: "Rate limit exceeded"
        )))
        #expect(state.prominentError?.isUsageLimit == true)
        #expect(state.prominentError?.needsCLIUpgrade == false)
        #expect(state.prominentError?.resetsAt != nil)
    }
}

struct ComposerBusyCopyTests {
    @Test func requestingWaitsOnTheModel() {
        let text = ComposerBusyCopy.label(
            harness: .claudeCode, status: .requesting, runningToolLabel: nil,
            isStarting: false, lastEventAt: Date(), now: Date()
        )
        #expect(text == "Claude Code is waiting on the model")
    }

    @Test func aRunningToolNamesTheFile() {
        let text = ComposerBusyCopy.label(
            harness: .claudeCode, status: .runningTool,
            runningToolLabel: "Reading WorkspaceEngine.swift",
            isStarting: false, lastEventAt: Date(), now: Date()
        )
        #expect(text == "Reading WorkspaceEngine.swift")
    }

    @Test func silenceAfterNinetySecondsIsCalledOut() {
        let last = Date()
        let now = last.addingTimeInterval(95)
        let text = ComposerBusyCopy.label(
            harness: .claudeCode, status: .runningTool,
            runningToolLabel: "Reading a.swift",
            isStarting: false, lastEventAt: last, now: now
        )
        #expect(text == "No output for 1m 35s")
    }

    @Test func turnElapsedIsLabeledAsTheTurn() {
        let start = Date()
        #expect(ComposerBusyCopy.turnElapsed(from: start, to: start.addingTimeInterval(65)) == "1m 5s this turn")
    }
}

/// A rate-limit report is a snapshot of a rolling window, and harnesses only
/// report while a turn is running — so nothing arrives to retract one. Without
/// an expiry the banner outlived the limit it described.
@MainActor
struct RateLimitExpiryTests {
    @Test func aWarningWhoseWindowHasRolledIsNotShown() {
        let state = ChatState()
        state.apply(.rateLimit(RateLimitReport(
            status: .warning,
            window: "5h",
            resetsAt: Date().addingTimeInterval(-60 * 54)  // 4:30 PM, seen at 5:24
        )))
        #expect(state.rateLimit == nil)
    }

    @Test func aLiveWarningIsKept() {
        let state = ChatState()
        let report = RateLimitReport(
            status: .warning, window: "5h", resetsAt: Date().addingTimeInterval(600)
        )
        state.apply(.rateLimit(report))
        #expect(state.rateLimit == report)
    }

    /// An exhausted window is the one the user most wants gone the moment it
    /// resets — that is when they can work again.
    @Test func anExhaustedReportExpiresTheSameWay() {
        let state = ChatState()
        state.apply(.rateLimit(RateLimitReport(
            status: .exhausted, resetsAt: Date().addingTimeInterval(-1)
        )))
        #expect(state.rateLimit == nil)
    }

    /// `allowed` is the harness saying the limit is off; it must not leave a
    /// stale warning behind it.
    @Test func returningToAllowedClearsAnEarlierWarning() {
        let state = ChatState()
        state.apply(.rateLimit(RateLimitReport(
            status: .warning, resetsAt: Date().addingTimeInterval(600)
        )))
        state.apply(.rateLimit(RateLimitReport(status: .allowed)))
        #expect(state.rateLimit == nil)
    }

    /// Nothing in a report without a reset time says when it stops being true,
    /// so it stands until the harness says otherwise.
    @Test func aReportWithNoResetTimeStands() {
        let state = ChatState()
        let report = RateLimitReport(status: .warning, window: "weekly")
        state.apply(.rateLimit(report))
        #expect(state.rateLimit == report)
    }

    @Test func theBannerTakesItselfDownWhenTheWindowRolls() async throws {
        let state = ChatState()
        state.apply(.rateLimit(RateLimitReport(
            status: .warning, resetsAt: Date().addingTimeInterval(0.2)
        )))
        #expect(state.rateLimit != nil)
        // The expiry timer, not another event, is what clears it: an idle tab
        // never sees another rate-limit event.
        try await Task.sleep(for: .milliseconds(1400))
        #expect(state.rateLimit == nil)
    }
}
