import Foundation
import OreProtocol
import Testing

@testable import OreMac

struct ComposerPlacementTests {
    @Test func prefersTheActiveIdleEmptyChat() {
        let active = chat("active")
        let newer = chat("newer")
        let chosen = ComposerPlacement.target(
            active: active,
            open: [active, newer],
            isOccupied: { _ in false }
        )
        #expect(chosen?.id == active.id)
    }

    @Test func skipsABusyOrDraftedActiveChatForTheNewestIdleEmptyOne() {
        let busy = chat("busy", status: .thinking)
        let idleOld = chat("old")
        let idleNew = chat("new")
        let chosen = ComposerPlacement.target(
            active: busy,
            open: [busy, idleOld, idleNew],
            isOccupied: { $0.status.occupiesComposer }
        )
        #expect(chosen?.id == idleNew.id)
    }

    @Test func skipsAChatTheUserIsAlreadyWritingIn() {
        let drafting = chat("drafting", draft: "half a thought")
        let idle = chat("idle")
        let chosen = ComposerPlacement.target(
            active: drafting,
            open: [drafting, idle],
            isOccupied: { _ in false }
        )
        #expect(chosen?.id == idle.id)
    }

    @Test func whitespaceOnlyDraftsStillCountAsEmpty() {
        let active = chat("active", draft: "  \n")
        let chosen = ComposerPlacement.target(
            active: active,
            open: [active],
            isOccupied: { _ in false }
        )
        #expect(chosen?.id == active.id)
    }

    @Test func opensANewTabWhenEveryChatIsBusyOrHasADraft() {
        let busy = chat("busy", status: .awaitingInput)
        let drafting = chat("drafting", draft: "notes")
        let chosen = ComposerPlacement.target(
            active: busy,
            open: [busy, drafting],
            isOccupied: { $0.status.occupiesComposer || $0.queuedMessageCount > 0 }
        )
        #expect(chosen == nil)
    }
}

private func chat(
    _ id: String,
    status: AgentStatus = .idle,
    draft: String = "",
    queued: Int = 0
) -> ChatSummary {
    ChatSummary(
        id: ChatID(rawValue: id),
        workspaceID: WorkspaceID(rawValue: "ws"),
        title: id,
        harness: .claudeCode,
        status: status,
        draftText: draft,
        queuedMessageCount: queued
    )
}
