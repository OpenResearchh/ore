import Testing
import OreProtocol

@testable import OreMac

/// Reading one sentence of ordinary speech into a workspace configuration.
///
/// The bar throughout: a false negative costs the user one click in Advanced,
/// a false positive silently starts the wrong agent on the wrong branch in the
/// wrong project. When in doubt, read nothing.
struct WorkspaceIntentTests {
    private let catalogue = [
        (id: "claude-opus-4-8", displayName: "Claude Opus 4.8"),
        (id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
        (id: "gpt-5", displayName: "GPT-5"),
    ]

    private func read(_ text: String) -> WorkspaceIntent {
        WorkspaceIntent.read(text, models: catalogue, repositoryNames: ["ore", "website"])
    }

    // MARK: - The ordinary case

    /// The brief's own example. Nothing in it is configuration; all of it is
    /// the goal, and none of it may be lost.
    @Test func aPlainInstructionIsAllGoal() {
        let spoken = """
            Take the ORE repo and figure out why workspace startup is slow. \
            Try improving it without changing existing behavior.
            """
        let intent = read(spoken)
        #expect(intent.goal == spoken)
        #expect(intent.hasGoal)
        #expect(intent.harness == nil)
        #expect(intent.model == nil)
        #expect(intent.baseBranch == nil)
    }

    @Test func theGoalSurvivesVerbatimEvenWhenItCarriesConfiguration() {
        // The agent reads this to learn what it is for. Stripping "use Claude
        // Code" out of it would leave a worse brief than leaving it in.
        let spoken = "Use Claude Code and fix the flaky permission test."
        #expect(read(spoken).goal == spoken)
    }

    @Test func whitespaceIsTidiedButWordsAreNot() {
        #expect(read("  fix   the\n  tests  ").goal == "fix the tests")
    }

    // MARK: - Agent

    @Test func theAgentCanBeNamedInPassing() {
        #expect(read("Use Claude Code and add the pricing page.").harness == .claudeCode)
        #expect(read("with codex, refactor the parser").harness == .codex)
        #expect(read("using cursor agent, tidy the imports").harness == .cursorAgent)
    }

    /// "claude" inside a longer word is not a request for Claude Code.
    @Test func anAgentNameInsideAnotherWordIsNotAnOverride() {
        #expect(read("update claude-code-config.json").harness == nil)
        #expect(read("rename codexample.swift").harness == nil)
    }

    @Test func onlyAvailableAgentsAreOffered() {
        let intent = WorkspaceIntent.read("use codex to fix it", harnesses: [.claudeCode])
        #expect(intent.harness == nil)
    }

    /// The words "cursor", "claude" and "codex" are ordinary English in a
    /// sentence about code. A bare one is part of the task, not a choice of
    /// agent, and reading it as a choice silently moved the user's work onto
    /// a different provider.
    @Test func abareAgentNameInOrdinaryProseIsNotAChoice() {
        #expect(read("fix the text cursor jumping to the end").harness == nil)
        #expect(read("the cursor disappears while typing").harness == nil)
        #expect(read("document the claude integration").harness == nil)
        #expect(read("port the codex parser to Swift").harness == nil)
    }

    /// It becomes a choice when a word in front of it says so.
    @Test func aBareAgentNameAfterAnIntentPhraseIsAChoice() {
        #expect(read("use cursor to fix the tests").harness == .cursorAgent)
        #expect(read("with claude, add the pricing page").harness == .claudeCode)
        #expect(read("switch to codex and refactor the parser").harness == .codex)
        #expect(read("run the suite with cursor").harness == .cursorAgent)
        #expect(read("use the claude agent for this").harness == .claudeCode)
    }

    /// The product's full name is never ordinary prose, so it stands alone.
    @Test func theProductsFullNameNeedsNoIntentPhrase() {
        #expect(read("claude code should handle this one").harness == .claudeCode)
        #expect(read("cursor-agent is fine here").harness == .cursorAgent)
    }

    // MARK: - Model

    @Test func theModelIsMatchedAgainstTheLiveCatalogue() {
        #expect(read("with Opus, rewrite the docs").model == "claude-opus-4-8")
        #expect(read("on sonnet, do the small fixes").model == "claude-sonnet-4-6")
    }

    @Test func theLongerModelNameWins() {
        // "Claude Opus 4.8" must not be read as bare "opus" if both match.
        #expect(read("use claude opus 4.8 for this").model == "claude-opus-4-8")
    }

    @Test func anUnknownModelIsNotInvented() {
        #expect(read("use gemini for this").model == nil)
    }

    // MARK: - Branch

    @Test func theBaseBranchCanBeSaidOutLoud() {
        #expect(read("branch from release and cut the hotfix").baseBranch == "release")
        #expect(read("based on develop, add the endpoint").baseBranch == "develop")
        #expect(read("start from main and refactor").baseBranch == "main")
    }

    /// "branch from the release branch" — the trailing noun is not a name.
    @Test func theWordBranchIsNotABranchName() {
        #expect(read("branch from the release branch").baseBranch == "release")
        #expect(read("branch from the branch").baseBranch == nil)
    }

    @Test func punctuationEndsTheBranchName() {
        #expect(read("branch from release, then run the tests").baseBranch == "release")
    }

    /// Git branch names are case-sensitive. Lowercasing `Release/2.0` names
    /// a branch that does not exist, and the worktree fails to create.
    @Test func aBranchKeepsTheCasingItWasWrittenIn() {
        #expect(read("branch from Release/2.0 and cut the hotfix").baseBranch == "Release/2.0")
        #expect(read("based on Feature-Flags, add the toggle").baseBranch == "Feature-Flags")
    }

    /// "Start from scratch" is the opposite of starting from a branch. A
    /// repository that happens to have a `scratch` branch must not make it
    /// come true.
    @Test func figuresOfSpeechAreNotBranchNames() {
        #expect(read("start from scratch and rewrite the parser").baseBranch == nil)
        #expect(read("start from zero on the importer").baseBranch == nil)
        #expect(read("branch from the branch").baseBranch == nil)
    }

    // MARK: - Repository

    @Test func aNamedRepositoryIsPickedUp() {
        #expect(read("take the ore repo and fix startup").repositoryHint == "ore")
        #expect(read("work on the website repository").repositoryHint == "website")
        #expect(read("in project ore, run the suite").repositoryHint == "ore")
    }

    /// "the ore repo" and "the checkout repo" are the same sentence shape,
    /// but only one of them names something that exists. Reading the word
    /// after "repo" as gospel sent the user to a project called "checkout".
    @Test func aKnownNameElsewhereBeatsTheWordAfterRepo() {
        let intent = read("in the checkout repo of ore, fix the flow")
        #expect(intent.repositoryHint == "ore")
    }

    /// When nothing in the sentence is a known project, the phrase is still
    /// reported rather than dropped, so the caller can ask about it instead
    /// of silently working somewhere else.
    @Test func anUnknownNamedProjectIsKeptRatherThanDropped() {
        #expect(read("in the checkout repo, fix the flow").repositoryHint == "checkout")
    }

    /// The trap: treating any proper noun as a repository would send
    /// "investigate the Sparkle updater" hunting for a Sparkle project.
    @Test func aProperNounIsNotARepositoryUnlessSaidSo() {
        #expect(read("investigate the Sparkle updater").repositoryHint == nil)
        #expect(read("fix the permission card").repositoryHint == nil)
    }

    @Test func fillerBeforeTheWordRepoIsNotTheName() {
        #expect(read("open the repo and look around").repositoryHint != "the")
    }

    // MARK: - Everything at once

    @Test func aFullyLoadedInstructionReadsEveryPart() {
        let intent = read("Take ore, use Claude Code with Opus, and branch from release.")
        #expect(intent.repositoryHint == "ore")
        #expect(intent.harness == .claudeCode)
        #expect(intent.model == "claude-opus-4-8")
        #expect(intent.baseBranch == "release")
    }

    // MARK: - Nothing to do

    @Test func anInstructionThatIsOnlyConfigurationHasNoGoal() {
        #expect(!read("Use Claude Code with Opus and branch from release.").hasGoal)
        #expect(!read("use codex").hasGoal)
    }

    @Test func anythingWithRealWordsInItHasAGoal() {
        #expect(read("fix startup").hasGoal)
        #expect(read("Use Claude Code and fix startup.").hasGoal)
    }
}
