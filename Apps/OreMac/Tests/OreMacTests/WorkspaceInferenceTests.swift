import Testing

@testable import OreMac

/// Infer → verify → ask. The ladder decides whether the composer opens on a
/// Start button or on a repository picker, so the line between "likely" and
/// "ambiguous" is the whole feature.
struct WorkspaceInferenceTests {
    private let ore = "/Users/x/code/ore"
    private let website = "/Users/x/code/website"
    private let other = "/Users/x/code/scratch"

    private func intent(_ text: String, names: [String] = ["ore", "website", "scratch"]) -> WorkspaceIntent {
        WorkspaceIntent.read(text, repositoryNames: names)
    }

    // MARK: - Being told

    @Test func namingTheProjectSettlesIt() {
        let choice = WorkspaceInference.repository(
            for: intent("take the ore repo and fix startup"),
            in: .init(repositories: [ore, website, other], recents: [website], current: website)
        )
        #expect(choice?.path == ore)
        #expect(choice?.confidence == .certain)
    }

    /// Being named beats being on screen. The user said which one.
    @Test func theNamedProjectBeatsTheOneOnScreen() {
        let choice = WorkspaceInference.repository(
            for: intent("work on website and add pricing"),
            in: .init(repositories: [ore, website], recents: [ore], current: ore)
        )
        #expect(choice?.path == website)
    }

    // MARK: - Working it out

    @Test func oneProjectIsNeverAQuestion() {
        let choice = WorkspaceInference.repository(
            for: intent("fix the thing", names: []),
            in: .init(repositories: [ore])
        )
        #expect(choice?.path == ore)
        #expect(choice?.confidence == .certain)
    }

    @Test func theProjectOnScreenIsTheDefault() {
        let choice = WorkspaceInference.repository(
            for: intent("fix the failing test", names: []),
            in: .init(repositories: [ore, website], recents: [website], current: ore)
        )
        #expect(choice?.path == ore)
        #expect(choice?.confidence == .certain)
        #expect(choice?.reason == "The project you're in")
    }

    /// Not in a workspace: the last one worked in is a good guess, but only a
    /// guess — shown, and easy to change.
    @Test func theMostRecentProjectIsLikelyNotCertain() {
        let choice = WorkspaceInference.repository(
            for: intent("fix the failing test", names: []),
            in: .init(repositories: [ore, website], recents: [website, ore])
        )
        #expect(choice?.path == website)
        #expect(choice?.confidence == .likely)
    }

    // MARK: - Asking

    @Test func nothingToGoOnIsAQuestion() {
        let choice = WorkspaceInference.repository(
            for: intent("fix the failing test", names: []),
            in: .init(repositories: [ore, website])
        )
        #expect(choice?.confidence == .ambiguous)
    }

    /// Naming something ORE has never heard of must not silently start work
    /// in a different project as though it were certain.
    @Test func anUnknownNameNeverProducesCertainty() {
        let choice = WorkspaceInference.repository(
            for: intent("take the payments repo and fix billing"),
            in: .init(repositories: [ore, website], recents: [ore], current: ore)
        )
        #expect(choice?.confidence != .certain)
    }

    /// Falling back to the project on screen after the user named a
    /// different one is the worst outcome available: work starts somewhere
    /// they explicitly said not to. It has to become a question.
    @Test func anUnknownNamedProjectIsAQuestionNotAFallback() {
        let choice = WorkspaceInference.repository(
            for: intent("take the payments repo and fix billing"),
            in: .init(repositories: [ore, website], recents: [ore], current: ore)
        )
        #expect(choice?.confidence == .ambiguous)
        #expect(choice?.unmatchedName == "payments")
        #expect(choice?.isSettled == false)
        #expect(choice?.reason.contains("payments") == true)
    }

    /// A hint ORE merely inferred is allowed to lose to the project on
    /// screen — nobody asked for it by name.
    @Test func anInferredMissStillFallsBack() {
        let choice = WorkspaceInference.repository(
            for: intent("fix billing in payments"),
            in: .init(repositories: [ore, website], recents: [ore], current: ore)
        )
        #expect(choice?.path == ore)
        #expect(choice?.unmatchedName == nil)
        #expect(choice?.isSettled == true)
    }

    @Test func twoProjectsOfTheSameNameIsAQuestion() {
        let forked = "/Users/x/forks/ore"
        let choice = WorkspaceInference.repository(
            for: intent("take the ore repo and fix startup"),
            in: .init(repositories: [ore, forked])
        )
        #expect(choice?.confidence == .ambiguous)
    }

    @Test func noProjectsAtAllMeansThereIsNothingToInfer() {
        #expect(WorkspaceInference.repository(
            for: intent("fix it", names: []), in: .init(repositories: [])
        ) == nil)
    }

    // MARK: - Matching

    @Test func aProjectIsMatchedByFolderName() {
        #expect(WorkspaceInference.matches("ore", path: ore))
        #expect(!WorkspaceInference.matches("or", path: ore))
    }

    @Test func anOwnerQualifiedNameMatchesTheTail() {
        #expect(WorkspaceInference.matches("openresearchh/ore", path: "/Users/x/openresearchh/ore"))
    }

    /// Quietly resolving "web" to `website` is worse than asking: the user
    /// gets a worktree in a project they never named.
    @Test func aPartialNameIsNotAMatch() {
        #expect(!WorkspaceInference.matches("web", path: website))
    }
}
