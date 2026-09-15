import Foundation
import Testing

@testable import OreMac

struct TerminalSplitLayoutTests {
    @Test func requestIsHeldToThePaneBounds() {
        #expect(TerminalSplitLayout.clamped(40) == 150)
        #expect(TerminalSplitLayout.clamped(240) == 240)
        #expect(TerminalSplitLayout.clamped(900) == 420)
    }

    @Test func unmeasuredColumnUsesTheRequestAlone() {
        #expect(TerminalSplitLayout.resolvedHeight(requested: 300, containerHeight: 0) == 300)
    }

    @Test func tallColumnHonoursTheRequest() {
        #expect(TerminalSplitLayout.resolvedHeight(requested: 300, containerHeight: 1000) == 300)
    }

    @Test func shortColumnKeepsTheWorkspaceReserve() {
        // 700 − 365 leaves 335 for the terminal.
        #expect(TerminalSplitLayout.resolvedHeight(requested: 420, containerHeight: 700) == 335)
    }

    @Test func tinyColumnNeverDropsBelowTheMinimum() {
        #expect(TerminalSplitLayout.resolvedHeight(requested: 300, containerHeight: 400) == 150)
    }
}
