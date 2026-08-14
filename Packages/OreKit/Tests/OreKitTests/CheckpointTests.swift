import Foundation
import Testing

@testable import OreGit
@testable import OreProtocol

struct CheckpointTests {
    private func makeWorkspace() async throws -> (GitFixture, URL) {
        let fixture = try await GitFixture.initialized()
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)
        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "checkpoints", baseRevision: "main", baseBranch: "main"
        ))
        return (fixture, worktree.path)
    }

    @Test func revertRestoresEditedFilesAndRemovesFilesCreatedAfterwards() async throws {
        let (fixture, worktree) = try await makeWorkspace()
        let store = CheckpointStore(git: fixture.git)

        try fixture.write("app.swift", "let version = 1\n", in: worktree)
        let checkpoint = try await store.capture(
            worktree: worktree,
            workspaceID: WorkspaceID(rawValue: "ws1"),
            turnID: TurnID(rawValue: "turn1")
        )

        // A turn that edits one file and creates another.
        try fixture.write("app.swift", "let version = 2\nlet broken = true\n", in: worktree)
        try fixture.write("extra.swift", "// added by the agent\n", in: worktree)

        let result = try await store.restore(worktree: worktree, to: checkpoint)

        #expect(fixture.read("app.swift", in: worktree) == "let version = 1\n")
        // The half that's easy to miss: a file created after the checkpoint
        // isn't in the snapshot, so restoring alone would leave it behind and
        // the revert silently wouldn't be one.
        #expect(!fixture.exists("extra.swift", in: worktree))
        #expect(result.deletedPaths == ["extra.swift"])
    }

    @Test func revertNeverTouchesIgnoredFiles() async throws {
        // Deleting someone's .env or build cache in the name of a revert is
        // not a trade worth making.
        let (fixture, worktree) = try await makeWorkspace()
        let store = CheckpointStore(git: fixture.git)

        try fixture.write(".env", "SECRET=keepme\n", in: worktree)
        try fixture.write("build/artifact.o", "binary\n", in: worktree)

        let checkpoint = try await store.capture(
            worktree: worktree,
            workspaceID: WorkspaceID(rawValue: "ws1"),
            turnID: TurnID(rawValue: "turn1")
        )
        try fixture.write("app.swift", "new file\n", in: worktree)
        try await store.restore(worktree: worktree, to: checkpoint)

        #expect(fixture.read(".env", in: worktree) == "SECRET=keepme\n")
        #expect(fixture.exists("build/artifact.o", in: worktree))
        #expect(!fixture.exists("app.swift", in: worktree))
    }

    @Test func capturingDoesNotDisturbTheUsersIndexOrHead() async throws {
        // The user may be mid-commit. Finding their index rewritten by the app
        // would be worse than having no checkpoints at all.
        let (fixture, worktree) = try await makeWorkspace()
        let store = CheckpointStore(git: fixture.git)

        try fixture.write("staged.txt", "staged content\n", in: worktree)
        try fixture.write("unstaged.txt", "unstaged content\n", in: worktree)
        try await fixture.run(["add", "staged.txt"], in: worktree)

        let headBefore = try await fixture.git.resolve("HEAD", in: worktree)
        let statusBefore = try await fixture.run(
            ["status", "--porcelain"], in: worktree
        ).standardOutput

        _ = try await store.capture(
            worktree: worktree,
            workspaceID: WorkspaceID(rawValue: "ws1"),
            turnID: TurnID(rawValue: "turn1")
        )

        let headAfter = try await fixture.git.resolve("HEAD", in: worktree)
        let statusAfter = try await fixture.run(
            ["status", "--porcelain"], in: worktree
        ).standardOutput

        #expect(headBefore == headAfter)
        #expect(statusBefore == statusAfter)
    }

    @Test func checkpointsLiveOnPrivateRefsAndStayOffTheBranch() async throws {
        let (fixture, worktree) = try await makeWorkspace()
        let store = CheckpointStore(git: fixture.git)
        let workspaceID = WorkspaceID(rawValue: "ws-refs")

        try fixture.write("a.txt", "a\n", in: worktree)
        let checkpoint = try await store.capture(
            worktree: worktree, workspaceID: workspaceID, turnID: TurnID(rawValue: "t1")
        )

        #expect(checkpoint.ref == "refs/ore/ckpt/ws-refs/t1")

        // Invisible in the branch's history: a checkpoint is bookkeeping, and
        // it must not pollute what the user is about to push.
        let log = try await fixture.run(["log", "--oneline"], in: worktree).standardOutput
        #expect(!log.contains("checkpoint"))

        let refs = try await store.list(workspaceID: workspaceID)
        #expect(refs == ["refs/ore/ckpt/ws-refs/t1"])

        try await store.removeAll(workspaceID: workspaceID)
        #expect(try await store.list(workspaceID: workspaceID).isEmpty)
    }

    @Test func checkpointsAreAttributedToOreRatherThanTheUser() async throws {
        let (fixture, worktree) = try await makeWorkspace()
        let store = CheckpointStore(git: fixture.git)

        try fixture.write("a.txt", "a\n", in: worktree)
        let checkpoint = try await store.capture(
            worktree: worktree,
            workspaceID: WorkspaceID(rawValue: "ws1"),
            turnID: TurnID(rawValue: "t1")
        )

        let author = try await fixture.run(
            ["show", "-s", "--format=%an <%ae>", checkpoint.commit]
        ).trimmedStandardOutput
        #expect(author == "ORE <ore@localhost>")
    }

    @Test func revertRoundTripsThroughSeveralTurns() async throws {
        // Reverting two turns back must produce the state at that turn, not
        // some merge of the turns in between.
        let (fixture, worktree) = try await makeWorkspace()
        let store = CheckpointStore(git: fixture.git)
        let workspaceID = WorkspaceID(rawValue: "ws-multi")

        try fixture.write("file.txt", "turn 1\n", in: worktree)
        let first = try await store.capture(
            worktree: worktree, workspaceID: workspaceID, turnID: TurnID(rawValue: "t1")
        )

        try fixture.write("file.txt", "turn 2\n", in: worktree)
        try fixture.write("second.txt", "from turn 2\n", in: worktree)
        _ = try await store.capture(
            worktree: worktree, workspaceID: workspaceID, turnID: TurnID(rawValue: "t2")
        )

        try fixture.write("file.txt", "turn 3\n", in: worktree)
        try fixture.write("third.txt", "from turn 3\n", in: worktree)

        try await store.restore(worktree: worktree, to: first)

        #expect(fixture.read("file.txt", in: worktree) == "turn 1\n")
        #expect(!fixture.exists("second.txt", in: worktree))
        #expect(!fixture.exists("third.txt", in: worktree))
    }

    @Test func emptyDirectoriesLeftByARevertAreCleanedUp() async throws {
        // Git doesn't track directories, but the user does see them.
        let (fixture, worktree) = try await makeWorkspace()
        let store = CheckpointStore(git: fixture.git)

        let checkpoint = try await store.capture(
            worktree: worktree,
            workspaceID: WorkspaceID(rawValue: "ws1"),
            turnID: TurnID(rawValue: "t1")
        )
        try fixture.write("Sources/New/Thing.swift", "code\n", in: worktree)

        try await store.restore(worktree: worktree, to: checkpoint)

        #expect(!fixture.exists("Sources/New/Thing.swift", in: worktree))
        #expect(!fixture.exists("Sources/New", in: worktree))
    }
}
