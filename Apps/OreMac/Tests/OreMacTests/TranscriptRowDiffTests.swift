import AppKit
import Testing

@testable import OreMac

private typealias Coordinator = TranscriptView.Coordinator
private typealias RowChanges = TranscriptView.Coordinator.RowChanges

/// The transcript applies a turn folding, an activity group opening or a queued
/// row leaving as removals and insertions, so the heights it already measured
/// survive and the reader's place can be anchored. Getting the index math wrong
/// means an `NSTableView` exception or text drawn into the wrong row's height,
/// so the diff is checked here rather than in a window.
@MainActor
struct TranscriptRowDiffTests {
    @Test func identicalTranscriptsChangeNothing() {
        let ids = ["a", "b", "c"]
        #expect(Coordinator.rowChanges(from: ids, to: ids) == RowChanges(removed: [], inserted: []))
    }

    @Test func aTurnFoldingRemovesItsRowsAndInsertsTheGroup() {
        // What the end of a turn looks like: three activity rows collapse into
        // one fold, with the prose either side untouched.
        let before = ["user", "think", "tool", "tool2", "answer"]
        let after = ["user", "group", "answer"]
        let changes = Coordinator.rowChanges(from: before, to: after)
        #expect(changes == RowChanges(removed: IndexSet(1...3), inserted: IndexSet(integer: 1)))
    }

    @Test func aGroupOpeningInsertsOnlyItsChildren() {
        let before = ["user", "group", "answer"]
        let after = ["user", "group", "child1", "child2", "answer"]
        let changes = Coordinator.rowChanges(from: before, to: after)
        #expect(changes == RowChanges(removed: [], inserted: IndexSet(2...3)))
    }

    @Test func aQueuedRowLeavingIsOneRemoval() {
        let changes = Coordinator.rowChanges(from: ["a", "queued", "b"], to: ["a", "b"])
        #expect(changes == RowChanges(removed: IndexSet(integer: 1), inserted: []))
    }

    @Test func anAppendIsJustAnInsertionAtTheFoot() {
        let changes = Coordinator.rowChanges(from: ["a", "b"], to: ["a", "b", "c"])
        #expect(changes == RowChanges(removed: [], inserted: IndexSet(integer: 2)))
    }

    @Test func aWholesaleReplacementIsRefused() {
        // Nothing in common: a different chat, not an edit of this one. The
        // caller reloads, which is the honest answer.
        #expect(Coordinator.rowChanges(from: ["a", "b"], to: ["x", "y"]) == nil)
        #expect(Coordinator.rowChanges(from: [], to: ["a"]) == nil)
        #expect(Coordinator.rowChanges(from: ["a"], to: []) == nil)
    }

    @Test func aRepeatedIdIsRefusedOnlyWhenItIsActuallyAmbiguous() {
        // Matching from both ends first pins one of the repeats positionally,
        // so dropping the second of two is an unambiguous single removal.
        #expect(
            Coordinator.rowChanges(from: ["a", "dup", "dup", "b"], to: ["a", "dup", "b"])
                == RowChanges(removed: IndexSet(integer: 2), inserted: [])
        )
        // With the ends differing the repeats stay in the middle, where "the
        // same row" stops meaning anything and a reload is the honest answer.
        #expect(Coordinator.rowChanges(from: ["x", "dup", "dup", "y"], to: ["z", "dup", "dup", "w"]) == nil)
    }

    @Test func aReorderIsRefused() {
        // Nothing in ORE reorders rows, and applying a reorder as removals plus
        // insertions would scramble the table.
        #expect(Coordinator.rowChanges(from: ["a", "b", "c"], to: ["a", "c", "b"]) == nil)
    }

    @Test func removalsAndInsertionsAreReportedInTheirOwnIndexing() {
        // Removals index the old rows, insertions the new ones — the order
        // NSTableView applies them in inside beginUpdates/endUpdates.
        let changes = Coordinator.rowChanges(from: ["a", "x", "y", "b"], to: ["a", "n", "b"])
        #expect(changes?.removed == IndexSet(1...2))
        #expect(changes?.inserted == IndexSet(integer: 1))
    }

    @Test func pendingWorkFollowsItsRowsThroughAChange() {
        // Rows 1 and 2 go, one row arrives in their place: work queued against
        // old row 3 has to land on new row 2.
        let changes = RowChanges(removed: IndexSet(1...2), inserted: IndexSet(integer: 1))
        #expect(Coordinator.remap(IndexSet(integer: 3), through: changes) == IndexSet(integer: 2))
        // Work queued against a row that no longer exists is dropped.
        #expect(Coordinator.remap(IndexSet(integer: 1), through: changes) == [])
        // A row above everything that moved stays where it was.
        #expect(Coordinator.remap(IndexSet(integer: 0), through: changes) == IndexSet(integer: 0))
    }

    @Test func remappingPushesRowsPastInsertionsAboveThem() {
        let changes = RowChanges(removed: [], inserted: IndexSet([1, 2]))
        #expect(Coordinator.remap(IndexSet([0, 1]), through: changes) == IndexSet([0, 3]))
    }
}

/// The find bar re-tests only the streaming row on each delta, so the match
/// list and the "3 of 7" ordinal are maintained incrementally.
@MainActor
struct TranscriptSearchMatchTests {
    @Test func aRowThatStartsMatchingIsInsertedInOrder() {
        let updated = Coordinator.applyingMatch([1, 5], cursor: 0, row: 3, matches: true)
        #expect(updated.matches == [1, 3, 5])
        // The cursor was on row 1, which is still the first match.
        #expect(updated.cursor == 0)
    }

    @Test func insertingBeforeTheCursorMovesTheOrdinalAlong() {
        let updated = Coordinator.applyingMatch([1, 5], cursor: 1, row: 3, matches: true)
        #expect(updated.matches == [1, 3, 5])
        // Still standing on row 5, now the third match rather than the second.
        #expect(updated.cursor == 2)
    }

    @Test func aRowThatStopsMatchingLeavesTheList() {
        let updated = Coordinator.applyingMatch([1, 3, 5], cursor: 2, row: 3, matches: false)
        #expect(updated.matches == [1, 5])
        #expect(updated.cursor == 1)
    }

    @Test func losingTheRowUnderTheCursorClearsTheOrdinal() {
        let updated = Coordinator.applyingMatch([1, 3, 5], cursor: 1, row: 3, matches: false)
        #expect(updated.matches == [1, 5])
        #expect(updated.cursor == nil)
    }

    @Test func aRowThatKeepsMatchingChangesNothing() {
        let updated = Coordinator.applyingMatch([1, 3], cursor: 1, row: 3, matches: true)
        #expect(updated.matches == [1, 3])
        #expect(updated.cursor == 1)
        let missing = Coordinator.applyingMatch([1, 3], cursor: 1, row: 4, matches: false)
        #expect(missing.matches == [1, 3])
        #expect(missing.cursor == 1)
    }
}

/// Heights outlive the coordinator that measured them, so a tab switch doesn't
/// re-measure a whole history. A height found under a key is trusted without
/// re-measuring, which makes the key the whole safety argument.
@MainActor
struct TranscriptHeightStoreTests {
    @Test func aRowKeyChangesWithEverythingThatMovesItsHeight() {
        let base = TranscriptHeightStore.rowKey(
            id: "row", contentRevision: 3, isCollapsed: false, hasTurnHeader: false
        )
        #expect(base == TranscriptHeightStore.rowKey(
            id: "row", contentRevision: 3, isCollapsed: false, hasTurnHeader: false
        ))
        #expect(base != TranscriptHeightStore.rowKey(
            id: "row", contentRevision: 4, isCollapsed: false, hasTurnHeader: false
        ))
        #expect(base != TranscriptHeightStore.rowKey(
            id: "row", contentRevision: 3, isCollapsed: true, hasTurnHeader: false
        ))
        #expect(base != TranscriptHeightStore.rowKey(
            id: "row", contentRevision: 3, isCollapsed: false, hasTurnHeader: true
        ))
        // The separator keeps an id ending in digits from colliding with the
        // revision of a shorter one.
        #expect(TranscriptHeightStore.rowKey(
            id: "a", contentRevision: 12, isCollapsed: false, hasTurnHeader: false
        ) != TranscriptHeightStore.rowKey(
            id: "a1", contentRevision: 2, isCollapsed: false, hasTurnHeader: false
        ))
    }

    @Test func widthAndAppearanceAreBothPartOfTheChatKey() {
        let key = TranscriptHeightStore.Key(
            chat: "chat", width: 720.4, appearance: "dark", variant: ""
        )
        // Rounded to whole points: the table's width is not stable to the
        // fraction, and a fraction is not a different wrap.
        #expect(key == TranscriptHeightStore.Key(
            chat: "chat", width: 720.2, appearance: "dark", variant: ""
        ))
        #expect(key != TranscriptHeightStore.Key(
            chat: "chat", width: 719, appearance: "dark", variant: ""
        ))
        #expect(key != TranscriptHeightStore.Key(
            chat: "chat", width: 720.4, appearance: "light", variant: ""
        ))
        #expect(key != TranscriptHeightStore.Key(
            chat: "other", width: 720.4, appearance: "dark", variant: ""
        ))
        #expect(key != TranscriptHeightStore.Key(
            chat: "chat", width: 720.4, appearance: "dark", variant: "codex"
        ))
    }

    @Test func storedHeightsComeBackForTheSameKeyOnly() {
        TranscriptHeightStore.removeAll()
        defer { TranscriptHeightStore.removeAll() }
        let key = TranscriptHeightStore.Key(
            chat: "chat", width: 600, appearance: "dark", variant: ""
        )
        TranscriptHeightStore.store(["row": 42], for: key)
        #expect(TranscriptHeightStore.heights(for: key)["row"] == 42)
        let narrower = TranscriptHeightStore.Key(
            chat: "chat", width: 500, appearance: "dark", variant: ""
        )
        #expect(TranscriptHeightStore.heights(for: narrower).isEmpty)
    }

    @Test func theColdestChatIsEvictedFirst() {
        TranscriptHeightStore.removeAll()
        defer { TranscriptHeightStore.removeAll() }
        func key(_ chat: String) -> TranscriptHeightStore.Key {
            TranscriptHeightStore.Key(chat: chat, width: 600, appearance: "dark", variant: "")
        }
        for index in 0..<TranscriptHeightStore.chatLimit {
            TranscriptHeightStore.store(["row": CGFloat(index)], for: key("chat\(index)"))
        }
        // Touching the oldest makes it the newest, so the next store drops the
        // one after it instead.
        #expect(!TranscriptHeightStore.heights(for: key("chat0")).isEmpty)
        TranscriptHeightStore.store(["row": 99], for: key("extra"))
        #expect(!TranscriptHeightStore.heights(for: key("chat0")).isEmpty)
        #expect(TranscriptHeightStore.heights(for: key("chat1")).isEmpty)
    }
}
