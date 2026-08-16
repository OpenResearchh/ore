import Testing

@testable import OreMac

struct TabCloseSelectionTests {
    @Test func closingAMiddleTabSelectsTheRightNeighbor() {
        let next = TabCloseSelection.replacement(
            closing: "b", active: "b", open: ["a", "b", "c"]
        )
        #expect(next == "c")
    }

    @Test func closingTheLastTabSelectsTheLeftNeighbor() {
        let next = TabCloseSelection.replacement(
            closing: "c", active: "c", open: ["a", "b", "c"]
        )
        #expect(next == "b")
    }

    @Test func closingABackgroundTabLeavesTheActiveTabAlone() {
        let next = TabCloseSelection.replacement(
            closing: "b", active: "a", open: ["a", "b", "c"]
        )
        #expect(next == nil)
    }

    @Test func closingTheOnlyTabHasNothingToSelect() {
        let next = TabCloseSelection.replacement(
            closing: "a", active: "a", open: ["a"]
        )
        #expect(next == nil)
    }

    @Test func closingTheFirstOfTwoSelectsTheRemainingTab() {
        let next = TabCloseSelection.replacement(
            closing: "a", active: "a", open: ["a", "b"]
        )
        #expect(next == "b")
    }
}
