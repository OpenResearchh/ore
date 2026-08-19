import Foundation
import Testing

@testable import OreGit
@testable import OreProtocol

struct GitStatusParserTests {
    @Test func porcelainV2IsParsedIncludingBranchDivergence() throws {
        let output = [
            "# branch.oid abc123",
            "# branch.head feature/login",
            "# branch.upstream origin/feature/login",
            "# branch.ab +3 -1",
            "1 .M N... 100644 100644 100644 aaa bbb Sources/App.swift",
            "1 A. N... 000000 100644 100644 000000 ccc Sources/New.swift",
            "? untracked.txt",
        ].joined(separator: "\0") + "\0"

        let snapshot = GitStatusParser.parse(output, generation: 7)

        #expect(snapshot.branch == "feature/login")
        #expect(snapshot.upstream == "origin/feature/login")
        #expect(snapshot.aheadOfUpstream == 3)
        #expect(snapshot.behindUpstream == 1)
        #expect(snapshot.generation == 7)
        #expect(snapshot.files.count == 3)

        let modified = try #require(snapshot.files.first { $0.path == "Sources/App.swift" })
        #expect(modified.status == .modified)
        #expect(modified.isStaged == false)
        #expect(modified.isUnstaged == true)

        let added = try #require(snapshot.files.first { $0.path == "Sources/New.swift" })
        #expect(added.status == .added)
        #expect(added.isStaged == true)
        #expect(added.isUnstaged == false)

        #expect(snapshot.files.first { $0.path == "untracked.txt" }?.status == .untracked)
        #expect(snapshot.files.first { $0.path == "untracked.txt" }?.isUnstaged == true)
        #expect(snapshot.unstagedFileCount == 2)
        #expect(snapshot.stagedFileCount == 1)
    }

    @Test func partiallyStagedFilesAreBothStagedAndUnstaged() {
        let output = [
            "# branch.head main",
            "1 MM N... 100644 100644 100644 aaa bbb Sources/App.swift",
        ].joined(separator: "\0") + "\0"
        let snapshot = GitStatusParser.parse(output, generation: 1)
        #expect(snapshot.files[0].isStaged == true)
        #expect(snapshot.files[0].isUnstaged == true)
        #expect(snapshot.stagedFileCount == 1)
        #expect(snapshot.unstagedFileCount == 1)
    }

    @Test func renamesCarryTheirOriginalPath() {
        // A rename's source path is a separate NUL field belonging to the
        // record before it — read it as its own record and every field after
        // shifts by one.
        let output = [
            "# branch.head main",
            "2 R. N... 100644 100644 100644 aaa bbb R100 Sources/New.swift",
            "Sources/Old.swift",
            "1 .M N... 100644 100644 100644 ccc ddd After.swift",
        ].joined(separator: "\0") + "\0"

        let snapshot = GitStatusParser.parse(output, generation: 1)

        #expect(snapshot.files.count == 2)
        #expect(snapshot.files[0].status == .renamed)
        #expect(snapshot.files[0].path == "Sources/New.swift")
        #expect(snapshot.files[0].originalPath == "Sources/Old.swift")
        // The record after a rename must still parse correctly.
        #expect(snapshot.files[1].path == "After.swift")
    }

    @Test func pathsContainingSpacesSurviveIntact() {
        // The reason for `-z`: with the default format git C-quotes these, and
        // unquoting correctly is a bug waiting to happen.
        let output = [
            "# branch.head main",
            "1 .M N... 100644 100644 100644 aaa bbb My Documents/a file.txt",
            "? another file.txt",
        ].joined(separator: "\0") + "\0"

        let snapshot = GitStatusParser.parse(output, generation: 1)
        #expect(snapshot.files[0].path == "My Documents/a file.txt")
        #expect(snapshot.files[1].path == "another file.txt")
    }

    @Test func detachedHeadHasNoBranch() {
        let output = ["# branch.head (detached)"].joined() + "\0"
        #expect(GitStatusParser.parse(output, generation: 1).branch == nil)
    }

    @Test func numstatAssociatesCountsWithTheDestinationPath() {
        let output = "3\t1\tSources/App.swift\0-\t-\timage.png\0" + "5\t0\t\0old.txt\0new.txt\0"
        let counts = NumstatParser.parse(output)

        #expect(counts["Sources/App.swift"]?.insertions == 3)
        #expect(counts["Sources/App.swift"]?.deletions == 1)
        #expect(counts["image.png"]?.isBinary == true)
        // For a rename the user cares about where the file ended up.
        #expect(counts["new.txt"]?.insertions == 5)
    }
}

struct UnifiedDiffParserTests {
    @Test func hunksCarryLineNumbersOnBothSides() {
        // Comments anchor to these, so they have to be right.
        let diff = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index abc..def 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -10,6 +10,7 @@ func example() {
             let a = 1
        -    let b = 2
        +    let b = 3
        +    let c = 4
             let d = 5
        """

        let files = UnifiedDiffParser.parse(diff)
        #expect(files.count == 1)
        let hunk = files[0].hunks[0]

        #expect(hunk.oldStart == 10)
        #expect(hunk.newStart == 10)
        #expect(hunk.header == "func example() {")

        let removed = hunk.lines.filter { $0.kind == .removed }
        #expect(removed.count == 1)
        #expect(removed[0].oldLineNumber == 11)
        #expect(removed[0].newLineNumber == nil)

        let added = hunk.lines.filter { $0.kind == .added }
        #expect(added.map(\.newLineNumber) == [11, 12])
        #expect(added.allSatisfy { $0.oldLineNumber == nil })

        // The trailing context line continues from the added lines.
        #expect(hunk.lines.last?.kind == .context)
        #expect(hunk.lines.last?.newLineNumber == 13)
        #expect(hunk.lines.last?.oldLineNumber == 12)
    }

    @Test func blankContextLinesArePreserved() {
        // Git emits a bare newline for a blank context line. Dropping it
        // shifts every line number after it.
        let diff = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,4 +1,4 @@
         first

        -third
        +THIRD
        """

        let hunk = UnifiedDiffParser.parse(diff)[0].hunks[0]
        #expect(hunk.lines.count == 4)
        #expect(hunk.lines[1].kind == .context)
        #expect(hunk.lines[1].text.isEmpty)
        #expect(hunk.lines[2].oldLineNumber == 3)
    }

    @Test func addedDeletedAndRenamedFilesAreClassified() {
        let diff = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +hello
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -goodbye
        diff --git a/old.txt b/renamed.txt
        similarity index 95%
        rename from old.txt
        rename to renamed.txt
        diff --git a/logo.png b/logo.png
        index aaa..bbb 100644
        Binary files a/logo.png and b/logo.png differ
        """

        let files = UnifiedDiffParser.parse(diff)
        #expect(files.count == 4)
        #expect(files[0].status == .added)
        #expect(files[0].insertions == 1)
        #expect(files[1].status == .deleted)
        #expect(files[1].deletions == 1)
        #expect(files[2].status == .renamed)
        #expect(files[2].originalPath == "old.txt")
        #expect(files[2].path == "renamed.txt")
        #expect(files[3].isBinary)
    }

    @Test func aTrailingNewlineDoesNotAddAPhantomLine() {
        // Diff output ends with a newline. Treating that as a final empty
        // context line appends a blank line to every hunk that isn't in the
        // file — and shifts nothing else, so it reads as real.
        let diff = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n"

        let hunk = UnifiedDiffParser.parse(diff)[0].hunks[0]
        #expect(hunk.lines.count == 2)
        #expect(hunk.lines.map(\.kind) == [.removed, .added])
    }

    @Test func singleLineHunksWithoutACountAreHandled() {
        // `@@ -1 +1 @@` — an omitted count means exactly one line.
        let diff = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -old
        +new
        """
        let hunk = UnifiedDiffParser.parse(diff)[0].hunks[0]
        #expect(hunk.oldCount == 1)
        #expect(hunk.newCount == 1)
    }
}

struct DiffEngineTests {
    @Test func untrackedFilesAppearInTheReviewDiff() async throws {
        // A file the agent just created is usually the most important thing in
        // the review, and `git diff` doesn't mention it at all.
        let fixture = try await GitFixture.initialized()
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)
        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "diffs", baseRevision: "main", baseBranch: "main"
        )).path

        try fixture.write("README.md", "# repo\nedited\n", in: worktree)
        try fixture.write("brand-new.swift", "let x = 1\n", in: worktree)

        let engine = DiffEngine(git: fixture.git)
        let diffs = try await engine.workingTreeDiff(worktree: worktree)

        #expect(diffs.map(\.path).sorted() == ["README.md", "brand-new.swift"])
        let created = try #require(diffs.first { $0.path == "brand-new.swift" })
        #expect(created.status == .untracked)
        #expect(created.insertions == 1)
    }

    @Test func reviewDiffTextIncludesUntrackedAndCommittedBranchWork() async throws {
        let fixture = try await GitFixture.initialized()
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)
        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "review-diff", baseRevision: "main", baseBranch: "main"
        )).path

        try fixture.write("on-branch.swift", "let committed = true\n", in: worktree)
        try await fixture.run(["add", "-A"], in: worktree)
        try await fixture.commit("branch work", in: worktree)
        try fixture.write("brand-new.swift", "let untracked = true\n", in: worktree)

        let text = await ReviewDiff.unifiedText(in: worktree)
        #expect(text.contains("on-branch.swift"))
        #expect(text.contains("brand-new.swift"))
        #expect(text.contains("let committed"))
        #expect(text.contains("let untracked"))
    }

    @Test func reviewCommentsRoundTripThroughTheSharedFile() async throws {
        let fixture = try await GitFixture.initialized()
        let comment = DiffCommentReference(
            filePath: "A.swift", startLine: 3, endLine: 5, body: "check this"
        )
        let count = try DiffCommentFile.append(comment, in: fixture.repository)
        #expect(count == 1)
        #expect(DiffCommentFile.load(in: fixture.repository) == [comment])
    }

    @Test func diffAgainstBaseIgnoresCommitsThatLandedOnTheBaseBranch() async throws {
        // Using the merge base means work merged into main while the agent was
        // running doesn't show up as this workspace's changes.
        let fixture = try await GitFixture.initialized()
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)
        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "base", baseRevision: "main", baseBranch: "main"
        )).path

        // Someone else lands a change on main.
        try fixture.write("other.txt", "not mine\n")
        try await fixture.run(["add", "-A"])
        try await fixture.commit("someone else's work")

        // Our workspace changes one file.
        try fixture.write("mine.txt", "mine\n", in: worktree)
        try await fixture.run(["add", "-A"], in: worktree)
        try await fixture.commit("my work", in: worktree)

        let engine = DiffEngine(git: fixture.git)
        let diffs = try await engine.diffAgainstBase(worktree: worktree, baseBranch: "main")

        #expect(diffs.map(\.path) == ["mine.txt"])
    }

    @Test func aStaleLocalBaseBranchDoesNotInflateTheDiff() async throws {
        // The local base branch is only as fresh as the last checkout, and
        // nothing in ORE updates it. Once the real base moved ahead and the
        // workspace merged it in, every commit the base itself had gained was
        // reported as this workspace's work — the review pane showed 53 changed
        // files where the pull request showed 39.
        let fixture = try await GitFixture.initialized()
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)
        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "stale", baseRevision: "main", baseBranch: "main"
        )).path

        // The base moves ahead and `origin/main` follows it, but the local
        // `main` ref stays put — exactly the state of a machine that hasn't
        // pulled since.
        let staleLocalBase = try await fixture.git
            .run(["rev-parse", "main"]).trimmedStandardOutput
        try fixture.write("theirs.txt", "landed on the base\n")
        try await fixture.run(["add", "-A"])
        try await fixture.commit("someone else's merged work")
        let movedBase = try await fixture.git
            .run(["rev-parse", "main"]).trimmedStandardOutput
        try await fixture.run(["update-ref", "refs/remotes/origin/main", movedBase])
        try await fixture.run(["update-ref", "refs/heads/main", staleLocalBase])

        // The workspace merges the real base in, then makes its own change.
        try await fixture.run(["merge", "--no-edit", "origin/main"], in: worktree)
        try fixture.write("mine.txt", "mine\n", in: worktree)
        try await fixture.run(["add", "-A"], in: worktree)
        try await fixture.commit("my work", in: worktree)

        let engine = DiffEngine(git: fixture.git)
        let diffs = try await engine.diffAgainstBase(worktree: worktree, baseBranch: "main")

        // Only our file: `theirs.txt` belongs to the base, however stale the
        // local ref pointing at it happens to be.
        #expect(diffs.map(\.path) == ["mine.txt"])
    }

    @Test func aStaleLocalBaseBranchDoesNotInventCommitsToOpenAPullRequestFrom() async throws {
        // Same stale-ref trap, on the count that gates the toolbar: a fresh
        // workspace that has committed nothing was reported as 24 commits ahead
        // — the whole distance the local `main` ref had fallen behind — so
        // "Create pull request" sat there permanently with nothing to ship.
        let fixture = try await GitFixture.initialized()
        let staleLocalBase = try await fixture.git
            .run(["rev-parse", "main"]).trimmedStandardOutput
        try fixture.write("theirs.txt", "landed on the base\n")
        try await fixture.run(["add", "-A"])
        try await fixture.commit("someone else's merged work")
        let movedBase = try await fixture.git
            .run(["rev-parse", "main"]).trimmedStandardOutput
        try await fixture.run(["update-ref", "refs/remotes/origin/main", movedBase])
        try await fixture.run(["update-ref", "refs/heads/main", staleLocalBase])

        // Branched from where the base *actually* is, with no work of its own.
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)
        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "fresh", baseRevision: "origin/main", baseBranch: "main"
        )).path

        #expect(await fixture.git.commitsAheadOfBase("main", in: worktree) == 0)

        // And it still counts real work once there is some.
        try fixture.write("mine.txt", "mine\n", in: worktree)
        try await fixture.run(["add", "-A"], in: worktree)
        try await fixture.commit("my work", in: worktree)

        #expect(await fixture.git.commitsAheadOfBase("main", in: worktree) == 1)
    }

    @Test func turnDiffsComeFromCheckpointRefs() async throws {
        let fixture = try await GitFixture.initialized()
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)
        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "turns", baseRevision: "main", baseBranch: "main"
        )).path
        let store = CheckpointStore(git: fixture.git)

        try fixture.write("file.txt", "before\n", in: worktree)
        let before = try await store.capture(
            worktree: worktree,
            workspaceID: WorkspaceID(rawValue: "w"),
            turnID: TurnID(rawValue: "t1")
        )
        try fixture.write("file.txt", "after\n", in: worktree)
        let after = try await store.capture(
            worktree: worktree,
            workspaceID: WorkspaceID(rawValue: "w"),
            turnID: TurnID(rawValue: "t2")
        )

        let engine = DiffEngine(git: fixture.git)
        let diffs = try await engine.diffBetweenCheckpoints(
            worktree: worktree, from: before.commit, to: after.commit
        )

        #expect(diffs.count == 1)
        #expect(diffs[0].path == "file.txt")
        #expect(diffs[0].insertions == 1)
        #expect(diffs[0].deletions == 1)
    }
}

struct StatusWatcherTests {
    @Test func statusIsPublishedAndAnnotatedWithLineCounts() async throws {
        let fixture = try await GitFixture.initialized()
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)
        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "watch", baseRevision: "main", baseBranch: "main"
        )).path

        let watcher = StatusWatcher(
            git: fixture.git, worktreeURL: worktree, debounce: .milliseconds(50)
        )
        var iterator = watcher.updates.makeAsyncIterator()

        try fixture.write("README.md", "# repo\nline two\nline three\n", in: worktree)
        await watcher.start()

        let snapshot = try #require(await iterator.next())
        #expect(snapshot.branch == "ore/watch")
        #expect(snapshot.files.contains { $0.path == "README.md" })
        #expect(snapshot.files.first { $0.path == "README.md" }?.insertions == 2)
        #expect(snapshot.generation >= 1)

        await watcher.stop()
    }

    @Test func generationCountsUpSoStaleSnapshotsCanBeDiscarded() async throws {
        // FSEvents batches arrive out of order under load; a consumer needs a
        // way to tell which reading is newer.
        let fixture = try await GitFixture.initialized()
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)
        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "gen", baseRevision: "main", baseBranch: "main"
        )).path

        let watcher = StatusWatcher(git: fixture.git, worktreeURL: worktree)
        var iterator = watcher.updates.makeAsyncIterator()

        try fixture.write("a.txt", "a\n", in: worktree)
        await watcher.start()
        let first = try #require(await iterator.next())

        try fixture.write("b.txt", "b\n", in: worktree)
        await watcher.refreshNow()
        let second = try #require(await iterator.next())

        #expect(second.generation > first.generation)
        #expect(second.files.count > first.files.count)

        await watcher.stop()
    }

    @Test func fastForwardMovesALocalBranchThatIsNotCheckedOut() async throws {
        let fixture = try await GitFixture.initialized()
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)
        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "ff", baseRevision: "main", baseBranch: "main"
        )).path

        let stale = try await fixture.git.run(["rev-parse", "main"]).trimmedStandardOutput
        try fixture.write("landed.txt", "on default\n")
        try await fixture.run(["add", "-A"])
        try await fixture.commit("landed on default")
        let moved = try await fixture.git.run(["rev-parse", "main"]).trimmedStandardOutput
        try await fixture.run(["update-ref", "refs/remotes/origin/main", moved])
        try await fixture.run(["update-ref", "refs/heads/main", stale])

        #expect(await fixture.git.commitCount(from: "main", to: "origin/main") == 1)

        try await fixture.git.fastForwardLocalBranch("main", to: "origin/main")
        let now = try await fixture.git.run(["rev-parse", "main"]).trimmedStandardOutput
        #expect(now == moved)
        // The worktree stayed on its own branch.
        #expect(try await fixture.git.currentBranch(in: worktree) != "main")
    }

    @Test func mergeWouldConflictDetectsDivergentEditsToTheSameFile() async throws {
        let fixture = try await GitFixture.initialized()
        let manager = WorktreeManager(git: fixture.git, root: fixture.worktreeRoot)
        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: "conflict", baseRevision: "main", baseBranch: "main"
        )).path

        try fixture.write("README.md", "# theirs\n")
        try await fixture.run(["add", "-A"])
        try await fixture.commit("theirs")
        try await fixture.run(["update-ref", "refs/remotes/origin/main", "HEAD"])

        try fixture.write("README.md", "# ours\n", in: worktree)
        try await fixture.run(["add", "-A"], in: worktree)
        try await fixture.commit("ours", in: worktree)

        #expect(await fixture.git.mergeWouldConflict(with: "origin/main", in: worktree))
        #expect(await fixture.git.commitCount(from: "HEAD", to: "origin/main", in: worktree) == 1)
    }

    @Test func unusedBranchNameSkipsNamesThatAlreadyExist() async throws {
        let fixture = try await GitFixture.initialized()
        try await fixture.run(["branch", "ore/topic"])
        try await fixture.run(["branch", "ore/topic-2"])
        #expect(try await fixture.git.unusedBranchName(stem: "ore/topic") == "ore/topic-3")
    }
}
