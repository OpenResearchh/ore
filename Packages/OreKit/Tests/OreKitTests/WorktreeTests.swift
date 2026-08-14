import Foundation
import Testing

@testable import OreGit
@testable import OreProtocol

struct WorktreeTests {
    @Test func worktreeIsCreatedOutsideTheRepositoryOnItsOwnBranch() async throws {
        let fixture = try await GitFixture.initialized()
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)

        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "Fix the login bug",
            baseRevision: "main",
            baseBranch: "main"
        ))

        #expect(worktree.branch == "ore/fix-the-login-bug")
        #expect(worktree.path.lastPathComponent == "fix-the-login-bug")
        // Outside the repo: otherwise it shows up in the parent's watchers,
        // searches and .gitignore.
        #expect(!worktree.path.path.hasPrefix(fixture.repository.path))
        #expect(fixture.exists("README.md", in: worktree.path))

        let branch = try await fixture.git.currentBranch(in: worktree.path)
        #expect(branch == "ore/fix-the-login-bug")
    }

    @Test func twoWorkspacesWithTheSameNameGetDistinctPathsAndBranches() async throws {
        // Naming two workspaces "fix the bug" is ordinary user behaviour, not
        // an error to report.
        let fixture = try await GitFixture.initialized()
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)

        let first = try await manager.create(WorktreeManager.CreateRequest(
            name: "same name", baseRevision: "main", baseBranch: "main"
        ))
        let second = try await manager.create(WorktreeManager.CreateRequest(
            name: "same name", baseRevision: "main", baseBranch: "main"
        ))

        #expect(first.path != second.path)
        #expect(first.branch != second.branch)
        #expect(second.path.lastPathComponent == "same-name-2")
    }

    @Test func gitignoredFilesAreCopiedIntoTheWorktree() async throws {
        // The #1 worktree papercut: a fresh checkout can't build because the
        // gitignored `.env` it needs was never carried over.
        let fixture = try await GitFixture.initialized()
        try fixture.write(".env", "API_URL=http://localhost\n")
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)

        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "needs env",
            baseRevision: "main",
            baseBranch: "main",
            filesToCopy: [".env", "config/missing.json"]
        ))

        #expect(fixture.read(".env", in: worktree.path) == "API_URL=http://localhost\n")
        // A file that wasn't there is reported, not swallowed — otherwise it
        // resurfaces as a mysterious build failure later.
        #expect(worktree.missingCopies == ["config/missing.json"])
    }

    @Test func contextDirectoryExistsAndIsHiddenFromTheUsersDiff() async throws {
        let fixture = try await GitFixture.initialized()
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)

        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "with context", baseRevision: "main", baseBranch: "main"
        ))
        try fixture.write(".context/notes.md", "a note", in: worktree.path)

        #expect(fixture.exists(".context/attachments", in: worktree.path))

        // ORE's scratch space must never turn up in the review.
        let status = try await fixture.run(
            ["status", "--porcelain"], in: worktree.path
        ).trimmedStandardOutput
        #expect(!status.contains(".context"))
    }

    @Test func removingAWorktreeRefusesToDiscardUncommittedWork() async throws {
        let fixture = try await GitFixture.initialized()
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)
        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "dirty", baseRevision: "main", baseBranch: "main"
        ))
        try fixture.write("README.md", "# edited\n", in: worktree.path)

        await #expect(throws: GitError.self) {
            try await manager.remove(at: worktree.path)
        }
        #expect(fixture.exists("README.md", in: worktree.path))

        try await manager.remove(at: worktree.path, deleteBranch: worktree.branch, force: true)
        #expect(!FileManager.default.fileExists(atPath: worktree.path.path))
        #expect(await !fixture.git.branchExists(worktree.branch))
    }

    @Test func archivingPreservesUncommittedWorkOnARef() async throws {
        // Archiving reclaims the checkout but must not destroy work in
        // progress — the user expects to come back to exactly what they left.
        let fixture = try await GitFixture.initialized()
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)
        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "archive me", baseRevision: "main", baseBranch: "main"
        ))
        try fixture.write("draft.txt", "half-finished\n", in: worktree.path)

        let workspaceID = WorkspaceID(rawValue: "ws-archive")
        let commit = try await manager.archive(at: worktree.path, workspaceID: workspaceID)

        let saved = try #require(commit)
        #expect(!FileManager.default.fileExists(atPath: worktree.path.path))

        let contents = try await fixture.run(["show", "\(saved):draft.txt"]).standardOutput
        #expect(contents.contains("half-finished"))
    }

    @Test func slugsProduceNamesGitWillAccept() {
        // Git rejects a surprising number of names, and the failure surfaces
        // long after the user typed one.
        #expect(Slug.make("Fix the login bug") == "fix-the-login-bug")
        #expect(Slug.make("  leading and trailing  ") == "leading-and-trailing")
        #expect(Slug.make("feature/nested~name^with:junk") == "feature-nested-name-with-junk")
        #expect(Slug.make("emoji 🎉 name") == "emoji-name")
        #expect(Slug.make("...") == "workspace")
        #expect(Slug.make("") == "workspace")
        #expect(!Slug.make(String(repeating: "long", count: 40)).hasSuffix("-"))
        #expect(Slug.make(String(repeating: "long", count: 40)).count <= 48)
    }

    @Test func worktreeListIsParsedFromPorcelainOutput() async throws {
        let fixture = try await GitFixture.initialized()
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)
        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "listed", baseRevision: "main", baseBranch: "main"
        ))

        let all = try await manager.list()
        #expect(all.count == 2)  // the main checkout plus ours
        #expect(all.contains { $0.branch == worktree.branch })
    }
}
