import Testing
import OreProtocol

@testable import OreMac

/// The ✕ on the floating card. It is "not now, on this surface" — the ask
/// stays pending in the app — so the only thing it has to do is get out of the
/// way and let the next ask through.
struct HUDCardChoiceTests {
    private func ask(_ id: String) -> TabNeedsYou {
        .permission(TabNeedsYou.Permission(
            workspaceID: WorkspaceID(rawValue: "ws"),
            chatID: ChatID(rawValue: "chat"),
            request: PermissionRequest(
                turnID: TurnID(rawValue: "turn"),
                id: PermissionRequestID(rawValue: id),
                toolName: "Bash",
                input: .object([:])
            )
        ))
    }

    @Test func theNewestAskIsTheOneOnScreen() {
        let choice = HUDCardChoice.next(from: [ask("a"), ask("b")], dismissed: [])
        #expect(choice?.id == "permission-b")
    }

    /// The regression. With a second ask pending behind it, dismissing the
    /// card left the panel up — and it kept drawing the ask that had just been
    /// waved away, so ✕ looked like a dead button.
    @Test func dismissingTheCardAdvancesToTheNextAsk() {
        let items = [ask("a"), ask("b")]
        let choice = HUDCardChoice.next(from: items, dismissed: ["permission-b"])
        #expect(choice?.id == "permission-a")
    }

    @Test func dismissingTheLastAskLeavesNothingToShow() {
        let items = [ask("a")]
        #expect(HUDCardChoice.next(from: items, dismissed: ["permission-a"]) == nil)
    }

    @Test func dismissingEveryAskLeavesNothingToShow() {
        let items = [ask("a"), ask("b")]
        let dismissed: Set<String> = ["permission-a", "permission-b"]
        #expect(HUDCardChoice.next(from: items, dismissed: dismissed) == nil)
    }

    // MARK: - How long a dismissal lasts

    @Test func aDismissalIsForgottenOnceItsAskIsAnswered() {
        let pruned = HUDCardChoice.pruned(["permission-a", "permission-b"], against: [ask("b")])
        #expect(pruned == ["permission-b"])
    }

    @Test func aDismissalSurvivesWhileItsAskIsStillPending() {
        let pruned = HUDCardChoice.pruned(["permission-b"], against: [ask("a"), ask("b")])
        #expect(pruned == ["permission-b"])
        // And it still keeps that card off the HUD.
        #expect(HUDCardChoice.next(from: [ask("a"), ask("b")], dismissed: pruned)?.id == "permission-a")
    }

    @Test func nothingPendingMeansNothingRemembered() {
        #expect(HUDCardChoice.pruned(["permission-a"], against: []).isEmpty)
    }
}
