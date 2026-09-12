import Foundation
import OreProtocol

/// A project tab blocked on the user — permission, question, or a ready plan —
/// surfaced on the voice HUD and menu bar when the user is in another app.
///
/// Plans join this enum only when `PlanUpdate.isReady` is true and the markdown
/// survived `PlanProposalPolicy` (a real body, not a CreatePlan `started`
/// title and not streamed JSON debris). Drafts stay on the transcript row.
enum TabNeedsYou: Identifiable, Equatable {
    struct Permission: Equatable {
        var workspaceID: WorkspaceID
        var chatID: ChatID
        var request: PermissionRequest
    }

    struct Question: Equatable {
        var workspaceID: WorkspaceID
        var chatID: ChatID
        var question: AgentQuestion
    }

    /// One ready proposal per turn. `id` is scoped to the turn so a later
    /// permission-link update replaces this row instead of stacking a second.
    struct Plan: Equatable {
        var workspaceID: WorkspaceID
        var chatID: ChatID
        var turnID: TurnID
        var markdown: String
        var permissionRequestID: PermissionRequestID?
    }

    case permission(Permission)
    case question(Question)
    case plan(Plan)

    var id: String {
        switch self {
        case .permission(let item): return "permission-\(item.request.id.rawValue)"
        case .question(let item): return "question-\(item.question.id.rawValue)"
        case .plan(let item): return "plan-\(item.chatID.rawValue)-\(item.turnID.rawValue)"
        }
    }

    var workspaceID: WorkspaceID {
        switch self {
        case .permission(let item): return item.workspaceID
        case .question(let item): return item.workspaceID
        case .plan(let item): return item.workspaceID
        }
    }

    var chatID: ChatID {
        switch self {
        case .permission(let item): return item.chatID
        case .question(let item): return item.chatID
        case .plan(let item): return item.chatID
        }
    }

    /// Queue identity for the spoken prompt. Keeping the permission request ID
    /// here is what lets a click invalidate this exact line without cutting
    /// off unrelated assistant speech.
    var narrationKind: SpokenUtterance.Kind {
        switch self {
        case .permission(let item): return .permission(item.request.id)
        case .question: return .question
        case .plan: return .planProposal
        }
    }

    /// The written form of the ask, for a row the user reads rather than
    /// hears. Deliberately not `spokenSummary`: "It needs your permission for
    /// git push." is the right sentence out loud and the wrong one next to a
    /// button that says Allow, where the tool and its argument are the whole
    /// point.
    var headline: String {
        switch self {
        case .permission(let item):
            // The same reading the card gives, so the row the user clicks and
            // the card it takes them to describe one act in one vocabulary.
            // Clipped: this is a single line beside a button, and a `curl` is
            // longer than the row will ever be.
            let content = PermissionPresentation(request: item.request)
            guard let target = content.target else { return content.action }
            return "\(content.action) — \(PermissionPresentation.clip(target, to: 80))"
        case .question(let item):
            return item.question.prompt
        case .plan(let item):
            return PlanProposalPolicy.headline(from: item.markdown)
        }
    }

    /// "workspace / tab", or the workspace alone when the tab can't be named.
    /// The assistant's own answers name places this way, so a row the user
    /// clicks reads like the sentence they just heard.
    func placeLabel(workspace: String?, tab: String?) -> String {
        let place = workspace ?? "another workspace"
        guard let tab, !tab.isEmpty else { return place }
        return "\(place) / \(tab)"
    }

    /// The ask as one sentence for the ear, in the same vocabulary as the
    /// ambient narration of the very same event — `NarrationPhraser` owns the
    /// wording so there is exactly one spoken form per event. It used to have
    /// two, and the one the voice HUD reached for ("A tab wants to run Bash.")
    /// was the one that broke the house style: an anonymous subject, and a raw
    /// tool identifier read out where every other line says what is happening.
    var spokenSummary: String {
        switch self {
        case .permission(let item):
            return NarrationPhraser.permission(item.request)
        case .question(let item):
            return String(item.question.prompt.prefix(160))
        case .plan(let item):
            let crux = PlanProposalPolicy.headline(from: item.markdown, limit: 120)
            return "There's a plan ready — \(crux)."
        }
    }

    /// One complete spoken prompt, named for where it came from.
    ///
    /// `place` is `NarrationOrigin.spokenLabel`: nil when the tab is the one on
    /// screen, "the auth tab" or "kailash" otherwise. Passing it is what stops
    /// these prompts being the only lines ORE speaks that don't say where they
    /// are — the anonymous "a tab" was half of why they sounded like a machine.
    ///
    /// Questions still recite their choices; unlike a permission's yes/no they
    /// are the content of the ask, and the answer window's placeholder is only
    /// "Say your answer…". Freeform is still spelled out when the harness
    /// allows it, because nothing on screen says so.
    func spokenPrompt(place: String? = nil) -> String {
        let line: String
        switch self {
        case .permission(let item):
            line = NarrationPhraser.permissionAsk(item.request)
        case .question(let item):
            var prompt = NarrationPhraser.question(item.question)
            if !item.question.options.isEmpty {
                let labels = item.question.options.map(\.label)
                prompt += " Your options are \(Self.spokenList(labels))."
            }
            if item.question.allowsFreeform {
                prompt += " Say one of those, or answer in your own words."
            } else if !item.question.options.isEmpty {
                prompt += " Say the one you want."
            }
            line = prompt
        case .plan(let item):
            line = NarrationPhraser.planAsk(
                crux: PlanProposalPolicy.headline(from: item.markdown, limit: 120)
            )
        }
        guard let place, !place.isEmpty else { return line }
        return NarrationPhraser.prefixed(line, place: place)
    }

    private static func spokenList(_ values: [String]) -> String {
        switch values.count {
        case 0: return ""
        case 1: return values[0]
        case 2: return "\(values[0]), or \(values[1])"
        default:
            return values.dropLast().joined(separator: ", ") + ", or " + (values.last ?? "")
        }
    }
}
