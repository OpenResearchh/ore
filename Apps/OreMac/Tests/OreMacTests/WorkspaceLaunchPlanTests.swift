import Testing
import OreProtocol

@testable import OreMac

/// One sentence in, one configuration out — the same one the composer shows
/// and the sheet submits.
///
/// The failures this guards against are all quiet ones: an agent started on a
/// model it cannot run, a worktree cut from a branch nobody named, work begun
/// in a project the user explicitly said was not the one.
struct WorkspaceLaunchPlanTests {
    private let ore = "/Users/x/code/ore"
    private let website = "/Users/x/code/website"

    private let claudeModels = [
        (id: "claude-opus-4-8", displayName: "Claude Opus 4.8"),
        (id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
    ]
    private let codexModels = [
        (id: "gpt-5", displayName: "GPT-5"),
        (id: "gpt-5-codex", displayName: "GPT-5 Codex"),
    ]

    private func inputs(
        _ instruction: String,
        ready: [HarnessKind] = [.claudeCode, .codex, .cursorAgent],
        repositories: [String]? = nil,
        current: String? = nil,
        localBranches: [String] = [],
        harnessOverride: HarnessKind? = nil,
        modelOverride: String? = nil,
        repositoryOverride: String? = nil,
        wantsNewProject: Bool = false,
        explicitBranch: String? = nil,
        repositoryDefaultHarness: @escaping (String) -> HarnessKind? = { _ in nil }
    ) -> WorkspaceLaunchPlan.Inputs {
        let catalogue = claudeModels
        let codex = codexModels
        return WorkspaceLaunchPlan.Inputs(
            instruction: instruction,
            readyHarnesses: ready,
            models: { harness in
                switch harness {
                case .codex: return codex
                case .claudeCode: return catalogue
                default: return []
                }
            },
            repositories: repositories ?? [ore, website],
            recents: [ore],
            current: current,
            localBranches: localBranches,
            harnessOverride: harnessOverride,
            modelOverride: modelOverride,
            repositoryOverride: repositoryOverride,
            wantsNewProject: wantsNewProject,
            explicitBranch: explicitBranch,
            repositoryDefaultHarness: repositoryDefaultHarness
        )
    }

    // MARK: - ore.toml's [agent] harness

    /// `ore.toml`'s `[agent] harness` was written by Settings, parsed by the
    /// loader, and applied nowhere. Where it belongs is the one place an
    /// explicit pick is still distinguishable from a default: by the time a
    /// `CreateWorkspaceRequest` exists its `harness` is non-optional, so
    /// resolving the config there would silently overrule the user.
    @Test func repoDefaultHarnessLosesToAnExplicitRequest() {
        let repoWantsCodex: (String) -> HarnessKind? = { _ in .codex }

        // Nobody said otherwise: the repository's preference wins over
        // "whatever is installed first".
        let unopinionated = WorkspaceLaunchPlan.resolve(inputs(
            "fix the importer",
            current: ore,
            repositoryDefaultHarness: repoWantsCodex
        ))
        #expect(unopinionated.harness == .codex)

        // A click in the sheet.
        let picked = WorkspaceLaunchPlan.resolve(inputs(
            "fix the importer",
            current: ore,
            harnessOverride: .claudeCode,
            repositoryDefaultHarness: repoWantsCodex
        ))
        #expect(picked.harness == .claudeCode)

        // And an agent named in the sentence itself.
        let spoken = WorkspaceLaunchPlan.resolve(inputs(
            "use claude code to fix the importer",
            current: ore,
            repositoryDefaultHarness: repoWantsCodex
        ))
        #expect(spoken.harness == .claudeCode)
    }

    /// A repository with no `[agent] harness` resolves exactly as it did
    /// before the config existed.
    @Test func noRepoDefaultLeavesTheReadyOrderInCharge() {
        let plan = WorkspaceLaunchPlan.resolve(inputs("fix the importer", current: ore))
        #expect(plan.harness == .claudeCode)
    }

    // MARK: - Agent before model

    /// The bug this type exists for. Claude is first in `readyHarnesses`, so
    /// reading the model first checked "gpt-5" against Claude's catalogue,
    /// found nothing, and started Codex on its default while the chip
    /// claimed otherwise.
    @Test func theModelIsReadAgainstTheAgentThatWasAskedFor() {
        let plan = WorkspaceLaunchPlan.resolve(
            inputs("use codex with gpt-5 to fix the importer", current: ore)
        )
        #expect(plan.harness == .codex)
        #expect(plan.model == "gpt-5")
        #expect(plan.unavailableModel == nil)
        #expect(plan.canStart)
    }

    /// Asking for one agent's model on another is a mix-up, not a
    /// configuration. It must not be sent, and it must not be silent.
    @Test func aModelTheAgentCannotRunIsReportedNotSubstituted() {
        let plan = WorkspaceLaunchPlan.resolve(
            inputs("use codex with opus and fix the importer", current: ore)
        )
        #expect(plan.harness == .codex)
        #expect(plan.model == nil)
        #expect(plan.unavailableModel != nil)
    }

    /// A picker the user clicked outranks a word ORE read out of prose.
    @Test func anExplicitPickBeatsTheSentence() {
        let plan = WorkspaceLaunchPlan.resolve(inputs(
            "use codex and fix the importer",
            current: ore,
            harnessOverride: .claudeCode,
            modelOverride: "claude-opus-4-8"
        ))
        #expect(plan.harness == .claudeCode)
        #expect(plan.model == "claude-opus-4-8")
    }

    @Test func withNothingSaidTheFirstReadyAgentRuns() {
        let plan = WorkspaceLaunchPlan.resolve(
            inputs("fix the importer", ready: [.codex, .claudeCode], current: ore)
        )
        #expect(plan.harness == .codex)
    }

    // MARK: - Branch

    /// `git worktree add` fails on a branch that does not exist, after the
    /// user has already been told work started.
    @Test func aBranchIsCheckedAgainstTheProject() {
        let plan = WorkspaceLaunchPlan.resolve(inputs(
            "branch from release and cut the hotfix",
            current: ore,
            localBranches: ["main", "release"]
        ))
        #expect(plan.baseBranch == "release")
        #expect(plan.canStart)
    }

    /// The repository's spelling wins, so the user does not have to say
    /// "Release/2.0" with the capital.
    @Test func theProjectsOwnCasingIsUsed() {
        let plan = WorkspaceLaunchPlan.resolve(inputs(
            "branch from release/2.0 and cut the hotfix",
            current: ore,
            localBranches: ["main", "Release/2.0"]
        ))
        #expect(plan.baseBranch == "Release/2.0")
    }

    /// A branch ORE guessed at out of prose is dropped when it turns out not
    /// to exist. The user never asked for it, so there is nothing to report.
    @Test func aMisreadBranchIsDroppedQuietly() {
        let plan = WorkspaceLaunchPlan.resolve(inputs(
            "branch from release and cut the hotfix",
            current: ore,
            localBranches: ["main", "develop"]
        ))
        #expect(plan.baseBranch == nil)
        #expect(plan.unknownBranch == nil)
        #expect(plan.canStart)
    }

    /// One typed into Advanced is a request, and an unhonourable request has
    /// to stop Start rather than quietly become the default branch.
    @Test func aTypedBranchThatDoesNotExistBlocksStart() {
        let plan = WorkspaceLaunchPlan.resolve(inputs(
            "cut the hotfix",
            current: ore,
            localBranches: ["main", "develop"],
            explicitBranch: "releaes"
        ))
        #expect(plan.unknownBranch == "releaes")
        #expect(!plan.canStart)
        #expect(plan.blockerMessage?.contains("releaes") == true)
    }

    /// Branches load asynchronously. An empty list is "not known yet", and
    /// treating it as "no such branch" would reject every real one.
    @Test func anUnloadedBranchListNeverRejects() {
        let plan = WorkspaceLaunchPlan.resolve(inputs(
            "branch from release and cut the hotfix",
            current: ore
        ))
        #expect(plan.baseBranch == "release")
        #expect(plan.canStart)
    }

    // MARK: - Project

    @Test func aProjectNamedInTheSentenceIsUsed() {
        let plan = WorkspaceLaunchPlan.resolve(
            inputs("take the website repo and add pricing", current: ore)
        )
        #expect(plan.repository?.path == website)
        #expect(plan.canStart)
    }

    /// Naming a project ORE does not have must stop and ask. Falling through
    /// to whatever is on screen starts work in the one project the user just
    /// said it was not.
    @Test func anUnknownNamedProjectBlocksStart() {
        let plan = WorkspaceLaunchPlan.resolve(
            inputs("in the payments repo, fix billing", current: ore)
        )
        #expect(!plan.canStart)
        #expect(plan.blocker == .chooseProject(unmatched: "payments"))
        #expect(plan.blockerMessage?.contains("payments") == true)
    }

    @Test func noProjectsAtAllIsNotABlockerBecauseStartMakesOne() {
        let plan = WorkspaceLaunchPlan.resolve(
            inputs("fix the importer", repositories: [])
        )
        #expect(plan.repository == nil)
        #expect(plan.canStart)
    }

    @Test func askingForANewProjectSkipsInferenceEntirely() {
        let plan = WorkspaceLaunchPlan.resolve(
            inputs("take the ore repo and fix startup", current: ore, wantsNewProject: true)
        )
        #expect(plan.repository == nil)
        #expect(plan.canStart)
    }

    // MARK: - Nothing to do

    @Test func aSentenceWithNoWorkInItCannotStart() {
        let plan = WorkspaceLaunchPlan.resolve(inputs("use codex with gpt-5", current: ore))
        #expect(!plan.canStart)
        #expect(plan.blocker == .noGoal)
        // Nothing to explain: the Start button's own tooltip says it.
        #expect(plan.blockerMessage == nil)
    }
}
