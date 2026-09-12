import Foundation
import OreProtocol

/// Everything "start work on this sentence" resolves to, worked out once.
///
/// The composer and the sheet used to each read the instruction their own
/// way, in their own order, and disagree: the composer's chip said Codex
/// while the sheet submitted a Claude model, because one resolved the agent
/// before parsing the model and the other did not. This is the single
/// resolution both of them read, so what is on screen is what gets sent.
///
/// Order matters and is the point of the type. The agent is settled first,
/// because a model name only means something inside one agent's catalogue.
/// Then the model, then the project, then the branch — each against what the
/// step before it decided.
struct WorkspaceLaunchPlan {
    /// What could not be resolved from the sentence alone, in the order the
    /// user should be asked. `nil` means Start is a real button.
    enum Blocker: Equatable {
        /// A sentence that configures things but asks for no work.
        case noGoal
        /// Which project, because ORE cannot tell. Carries the name the user
        /// used when they named one ORE does not have.
        case chooseProject(unmatched: String?)
        /// An explicitly requested branch that does not exist in the project
        /// that was chosen.
        case unknownBranch(String)
    }

    var intent: WorkspaceIntent
    /// The agent that will actually run.
    var harness: HarnessKind
    /// The model, already checked against `harness`'s catalogue.
    var model: String?
    /// A model the user asked for that `harness` cannot run. Worth saying out
    /// loud: silently falling back to the default is how "use codex with
    /// sonnet" quietly became something else.
    var unavailableModel: String?
    /// The project, or `nil` when ORE will create one.
    var repository: WorkspaceInference.Choice?
    /// The validated starting branch, in the repository's own casing.
    var baseBranch: String?
    /// A branch the user named that the chosen project does not have.
    var unknownBranch: String?
    var blocker: Blocker?

    var canStart: Bool { blocker == nil }

    struct Inputs {
        var instruction: String
        var readyHarnesses: [HarnessKind]
        /// The model catalogue for an agent. Called after the agent is known.
        var models: (HarnessKind) -> [(id: String, displayName: String)]
        var repositories: [String]
        var recents: [String] = []
        var current: String?
        /// Branches of the project that ends up chosen, when they have been
        /// loaded. Empty means "not known yet", which is not the same as "the
        /// branch does not exist" — an unloaded list never blocks Start.
        var localBranches: [String] = []
        var harnessOverride: HarnessKind?
        var modelOverride: String?
        var repositoryOverride: String?
        var wantsNewProject: Bool = false
        /// Whether a branch typed into Advanced should be honoured as-is.
        var explicitBranch: String?
    }

    static func resolve(_ inputs: Inputs) -> WorkspaceLaunchPlan {
        let repositoryNames = inputs.repositories.map(WorkspaceInference.name(of:))

        // Pass one settles the agent. No model catalogue is offered yet,
        // because offering the wrong agent's catalogue is exactly the bug:
        // "use codex with gpt-5" parsed against Claude's models found
        // nothing, and the chip and the request then disagreed.
        let firstReading = WorkspaceIntent.read(
            inputs.instruction,
            harnesses: inputs.readyHarnesses,
            models: [],
            repositoryNames: repositoryNames
        )
        // An override is a click the user made after typing, so it wins over
        // what the sentence said — including over an alias read out of prose.
        let harness = inputs.harnessOverride
            ?? firstReading.harness
            ?? inputs.readyHarnesses.first
            ?? .claudeCode

        let catalogue = inputs.models(harness)
        let intent = WorkspaceIntent.read(
            inputs.instruction,
            harnesses: inputs.readyHarnesses,
            models: catalogue,
            repositoryNames: repositoryNames
        )

        let requested = inputs.modelOverride ?? intent.model
        let ids = Set(catalogue.map(\.id))
        let model = requested.flatMap { ids.contains($0) ? $0 : nil }
        // "Use codex with sonnet" names a real model that this agent cannot
        // run. Quietly starting Codex on its default is the surprise worth
        // avoiding, so the mix-up is looked for and reported.
        let unavailable = model == nil
            ? requested ?? borrowedModel(instruction: inputs.instruction, running: harness, inputs: inputs)
            : nil

        let repository = resolveRepository(intent: intent, inputs: inputs)
        let branch = resolveBranch(intent: intent, inputs: inputs)

        var plan = WorkspaceLaunchPlan(
            intent: intent,
            harness: harness,
            model: model,
            unavailableModel: unavailable,
            repository: repository,
            baseBranch: branch.accepted,
            unknownBranch: branch.unknown,
            blocker: nil
        )
        plan.blocker = blocker(for: plan, inputs: inputs)
        return plan
    }

    /// A model named in the sentence that belongs to one of the other
    /// installed agents. Reported by display name, because "Claude Sonnet
    /// 4.6" is what the user thinks they asked for.
    private static func borrowedModel(
        instruction: String,
        running: HarnessKind,
        inputs: Inputs
    ) -> String? {
        for other in inputs.readyHarnesses where other != running {
            let catalogue = inputs.models(other)
            let reading = WorkspaceIntent.read(
                instruction,
                harnesses: inputs.readyHarnesses,
                models: catalogue
            )
            if let found = reading.model {
                return catalogue.first { $0.id == found }?.displayName ?? found
            }
        }
        return nil
    }

    private static func resolveRepository(
        intent: WorkspaceIntent,
        inputs: Inputs
    ) -> WorkspaceInference.Choice? {
        if inputs.wantsNewProject { return nil }
        if let override = inputs.repositoryOverride {
            return WorkspaceInference.Choice(
                path: override,
                confidence: .certain,
                reason: WorkspaceInference.name(of: override)
            )
        }
        return WorkspaceInference.repository(for: intent, in: .init(
            repositories: inputs.repositories,
            recents: inputs.recents,
            current: inputs.current
        ))
    }

    /// A branch is only a branch if the chosen project has it.
    ///
    /// Inferring one out of prose and handing it to `git worktree add` is how
    /// "start from the release notes" tried to branch from `release`. The
    /// name is checked against the repository's real branches, case-sensitively
    /// first and then case-insensitively so the user does not have to match
    /// `Release/2.0` exactly — but the repository's own spelling is what gets
    /// used.
    private static func resolveBranch(
        intent: WorkspaceIntent,
        inputs: Inputs
    ) -> (accepted: String?, unknown: String?) {
        guard let wanted = inputs.explicitBranch ?? intent.baseBranch else {
            return (nil, nil)
        }
        // Not loaded yet. Say nothing rather than reject a real branch.
        guard !inputs.localBranches.isEmpty else { return (wanted, nil) }
        if let exact = inputs.localBranches.first(where: { $0 == wanted }) {
            return (exact, nil)
        }
        if let insensitive = inputs.localBranches.first(where: {
            $0.caseInsensitiveCompare(wanted) == .orderedSame
        }) {
            return (insensitive, nil)
        }
        // An inferred branch that does not exist is a misreading of prose and
        // is simply dropped. One the user typed into Advanced is a request,
        // and a request ORE cannot honour has to be said out loud.
        return inputs.explicitBranch == nil ? (nil, nil) : (nil, wanted)
    }

    private static func blocker(for plan: WorkspaceLaunchPlan, inputs: Inputs) -> Blocker? {
        guard plan.intent.hasGoal else { return .noGoal }
        if let unknownBranch = plan.unknownBranch { return .unknownBranch(unknownBranch) }
        // No project at all is fine — Start creates one. A project ORE is
        // unsure about is not: it would branch somebody else's repository.
        guard let repository = plan.repository else { return nil }
        guard repository.isSettled else {
            return .chooseProject(unmatched: repository.unmatchedName)
        }
        return nil
    }

    /// What to put under the composer when Start is disabled.
    var blockerMessage: String? {
        switch blocker {
        case .noGoal, nil:
            return nil
        case .chooseProject(let unmatched?):
            return "No project called “\(unmatched)” on this Mac — choose one, or start a new project."
        case .chooseProject(nil):
            return "More than one project fits — choose which one."
        case .unknownBranch(let branch):
            return "“\(branch)” isn't a branch in this project."
        }
    }
}
