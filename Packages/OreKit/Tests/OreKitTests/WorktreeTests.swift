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

    @Test func copiedFilesNeverLeaveTheRepositoryOrTheWorktree() async throws {
        // The copy list is repository content, and each destination is deleted
        // before the copy — an entry that climbs out by `..`, starts at `/`, or
        // passes through a symlinked directory would delete a real file
        // somewhere else on disk.
        let fixture = try await GitFixture.initialized()
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent("keep.txt")
        try "keep\n".write(to: victim, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: fixture.repository.appendingPathComponent("linked"),
            withDestinationURL: outside
        )
        let climb = String(repeating: "../", count: 24) + victim.path.dropFirst()
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)

        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "hostile config",
            baseRevision: "main",
            baseBranch: "main",
            filesToCopy: [climb, "linked/keep.txt", victim.path]
        ))

        #expect(worktree.missingCopies == [climb, "linked/keep.txt", victim.path])
        #expect((try? String(contentsOf: victim, encoding: .utf8)) == "keep\n")
        #expect(!fixture.exists("linked/keep.txt", in: worktree.path))
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

    /// Deleting a worktree's folder in Finder leaves git's own record of it
    /// behind under `.git/worktrees`. The next attempt at the same slug then
    /// failed with "already exists", naming a directory the user could see was
    /// not there — and `uniquePath` was no help, because the filesystem agreed
    /// the path was free.
    @Test func aWorktreeWhoseFolderWasDeletedCanBeRecreatedAtTheSameSlug() async throws {
        let fixture = try await GitFixture.initialized()
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)

        let first = try await manager.create(WorktreeManager.CreateRequest(
            name: "recycled", baseRevision: "main", baseBranch: "main"
        ))
        let slug = first.path.lastPathComponent

        // What Finder does: the directory goes, the registration stays. git
        // marks it "prunable" and refuses to reuse the path —
        //   fatal: '…' is a missing but already registered worktree
        // — while `uniquePath` sees a free path and hands back the same slug.
        try FileManager.default.removeItem(at: first.path)
        #expect(
            try await fixture.run(["worktree", "list"]).standardOutput.contains(slug),
            "the stale registration is the precondition this test exists for"
        )

        let second = try await manager.create(WorktreeManager.CreateRequest(
            name: "recycled", baseRevision: "main", baseBranch: "main"
        ))
        #expect(second.path.lastPathComponent == slug, "the freed slug is reused")
        #expect(FileManager.default.fileExists(atPath: second.path.path))
        // The branch is not reused: the first one still exists, so
        // `uniqueBranch` moves on. Only the path had to be reclaimed.
        #expect(second.branch != first.branch)
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
