import Foundation
import Testing

@testable import OreGit

/// Continuing after a merge cuts a fresh branch under a worktree the user may
/// still be typing in. These cover what happens to that half-finished work.
struct BranchSwitchTests {
    /// `main` moves ahead by editing line 1; the user is editing line 4 on an
    /// older branch. Plain `git switch -c` refuses this outright — the file
    /// differs between the two branches and is locally modified.
    private func divergedFixture() async throws -> GitFixture {
        let fixture = try await GitFixture.initialized()
        try fixture.write("notes.txt", "alpha\nbeta\ngamma\ndelta\n")
        try await fixture.run(["add", "-A"])
        try await fixture.commit("add notes")

        try await fixture.run(["switch", "-q", "-c", "old"])
        try await fixture.run(["switch", "-q", "main"])
        try fixture.write("notes.txt", "ALPHA\nbeta\ngamma\ndelta\n")
        try await fixture.run(["add", "-A"])
        try await fixture.commit("main moves on")
        try await fixture.run(["switch", "-q", "old"])
        return fixture
    }

    private func stashDepth(_ fixture: GitFixture) async throws -> Int {
        let output = try await fixture.run(["stash", "list"])
        return output.standardOutput.split(separator: "\n").count
    }

    private func currentBranch(_ fixture: GitFixture) async throws -> String {
        try await fixture.run(["rev-parse", "--abbrev-ref", "HEAD"]).trimmedStandardOutput
    }

    @Test func uncommittedWorkArrivesOnTheNewBranch() async throws {
        let fixture = try await GitFixture.initialized()
        try fixture.write("README.md", "# repo\nhalf a thought\n")

        let carried = try await BranchSwitch(git: fixture.git, worktree: fixture.repository)
            .create("ore/next", from: "main")

        #expect(carried)
        #expect(try await currentBranch(fixture) == "ore/next")
        #expect(fixture.read("README.md") == "# repo\nhalf a thought\n")
        // Carried, not committed: the work is still the user's to finish.
        let status = try await fixture.run(["status", "--porcelain"])
        #expect(status.standardOutput.contains("README.md"))
        #expect(try await stashDepth(fixture) == 0)
    }

    /// The case that used to be a hard error rather than a merge.
    @Test func workOnAFileTheNewBaseAlsoChangedStillComesAcross() async throws {
        let fixture = try await divergedFixture()
        try fixture.write("notes.txt", "alpha\nbeta\ngamma\ndelta edited\n")

        let carried = try await BranchSwitch(git: fixture.git, worktree: fixture.repository)
            .create("ore/next", from: "main")

        #expect(carried)
        // Both sides survive: main's line 1, the user's line 4.
        #expect(fixture.read("notes.txt") == "ALPHA\nbeta\ngamma\ndelta edited\n")
        #expect(try await stashDepth(fixture) == 0)
    }

    @Test func anUntrackedFileIsNotLeftBehind() async throws {
        let fixture = try await GitFixture.initialized()
        try fixture.write("scratch.txt", "notes to self\n")

        let carried = try await BranchSwitch(git: fixture.git, worktree: fixture.repository)
            .create("ore/next", from: "main")

        #expect(carried)
        #expect(fixture.read("scratch.txt") == "notes to self\n")
    }

    /// The bug a blind `git stash pop` would introduce: with nothing of our own
    /// stashed, popping restores whatever the user had parked earlier — work
    /// from another day appearing unbidden on a brand new branch.
    @Test func aCleanTreeLeavesAnEarlierStashAlone() async throws {
        let fixture = try await GitFixture.initialized()
        try fixture.write("README.md", "# repo\nparked for later\n")
        try await fixture.run(["stash", "push", "--message", "yesterday"])

        let carried = try await BranchSwitch(git: fixture.git, worktree: fixture.repository)
            .create("ore/next", from: "main")

        #expect(carried == false)
        #expect(try await currentBranch(fixture) == "ore/next")
        #expect(fixture.read("README.md") == "# repo\n")
        #expect(try await stashDepth(fixture) == 1)
    }

    @Test func overlappingWorkConflictsLoudlyAndKeepsTheStash() async throws {
        let fixture = try await divergedFixture()
        // Editing the very line main rewrote.
        try fixture.write("notes.txt", "alpha local\nbeta\ngamma\ndelta\n")
        let branchSwitch = BranchSwitch(git: fixture.git, worktree: fixture.repository)

        await #expect(throws: BranchSwitch.Failure.self) {
            try await branchSwitch.create("ore/next", from: "main")
        }

        // Nothing is lost: the markers are in the tree and the entry survives,
        // so the original edit is still recoverable in full.
        #expect(fixture.read("notes.txt")?.contains("<<<<<<<") == true)
        #expect(try await stashDepth(fixture) == 1)
    }

    /// If the switch itself fails there is no new branch to be on, so the work
    /// belongs exactly where the user left it.
    @Test func aFailedSwitchPutsTheWorkBack() async throws {
        let fixture = try await GitFixture.initialized()
        try await fixture.run(["branch", "ore/next"])
        try fixture.write("README.md", "# repo\nhalf a thought\n")
        let branchSwitch = BranchSwitch(git: fixture.git, worktree: fixture.repository)

        await #expect(throws: (any Error).self) {
            try await branchSwitch.create("ore/next", from: "main")
        }

        #expect(try await currentBranch(fixture) == "main")
        #expect(fixture.read("README.md") == "# repo\nhalf a thought\n")
        #expect(try await stashDepth(fixture) == 0)
    }
}
