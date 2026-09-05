import Testing

@testable import OreMac

struct SidebarPullRequestStateTests {
    @Test func openPullRequestKeepsItsNumber() {
        let state = SidebarPullRequestState(number: 42, state: "OPEN")

        #expect(state == .open(number: 42))
        #expect(state?.icon == "arrow.triangle.pull")
        #expect(state?.help == "Pull request #42 is open")
    }

    @Test func mergedPullRequestUsesDistinctPresentation() {
        let state = SidebarPullRequestState(number: 17, state: "merged")

        #expect(state == .merged(number: 17))
        #expect(state?.icon == "arrow.triangle.merge")
        #expect(state?.help == "Pull request #17 was merged")
    }

    @Test func closedUnmergedPullRequestDoesNotGetABadge() {
        #expect(SidebarPullRequestState(number: 9, state: "CLOSED") == nil)
    }
}
