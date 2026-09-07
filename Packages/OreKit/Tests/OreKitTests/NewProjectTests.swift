import Foundation
import Testing

@testable import OreCore
@testable import OreGit
@testable import OreHarness
@testable import OrePersistence
@testable import OreProtocol

/// Starting a project that exists nowhere yet.
///
/// Exercised against real git for the same reason the rest of the git layer is:
/// the whole question here is whether a repository ORE just made is one git
/// will accept a worktree on, and a mock would only prove our idea of that.
struct NewProjectTests {
    // MARK: - Naming

    @Test func aNameThatIsAlreadyASafeComponentIsKeptVerbatim() {
        // The user typed LACE; they get LACE. Slugging it to `lace` would make
        // them explain the difference to every import path afterwards.
        #expect(RepositoryInitializer.directoryName(for: "LACE") == "LACE")
        #expect(RepositoryInitializer.directoryName(for: "my_project.v2") == "my_project.v2")
        #expect(RepositoryInitializer.directoryName(for: "  LACE  ") == "LACE")
    }

    @Test func anUnsafeNameIsSluggedIntoAUsableDirectory() {
        #expect(RepositoryInitializer.directoryName(for: "My Cool Project") == "my-cool-project")
        // A leading dot would hide the project from every file listing, and a
        // slash would silently create a nested directory the user never asked
        // for — both have to stop being a path component.
        #expect(RepositoryInitializer.directoryName(for: ".hidden") == "hidden")
        #expect(RepositoryInitializer.directoryName(for: "a/b") == "a-b")
        #expect(RepositoryInitializer.directoryName(for: "🙂") == "workspace")
    }

    // MARK: - Creating the repository

    @Test func createsARepositoryWithAnInitialCommitOnMain() async throws {
        let parent = try TemporaryDirectory()

        let created = try await RepositoryInitializer.create(name: "LACE", in: parent.url)

        #expect(created.path.lastPathComponent == "LACE")
        #expect(created.defaultBranch == "main")
        #expect(!created.initialCommit.isEmpty)

        // The initial commit is the point: without a HEAD, `git worktree add`
        // has nothing to branch from and the project could never be opened.
        let git = try GitClient(repositoryURL: created.path)
        #expect(try await git.resolve("HEAD") == created.initialCommit)
        #expect(await git.defaultBranch() == "main")
        #expect(FileManager.default.fileExists(
            atPath: created.path.appendingPathComponent("README.md").path
        ))
        let readme = try String(
            contentsOf: created.path.appendingPathComponent("README.md"), encoding: .utf8
        )
        #expect(readme.contains("# LACE"))
    }

    @Test func anExistingEmptyDirectoryIsAdopted() async throws {
        // A user who made the folder in Finder first and then asked ORE to
        // start the project there means one project, not an error.
        let parent = try TemporaryDirectory()
        let existing = parent.url.appendingPathComponent("LACE", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)

        let created = try await RepositoryInitializer.create(name: "LACE", in: parent.url)
        #expect(created.path.standardizedFileURL == existing.standardizedFileURL)
    }

    @Test func anExistingRepositoryIsRefusedRatherThanWrittenInto() async throws {
        let fixture = try await GitFixture.initialized(name: "LACE")

        await #expect(throws: NewRepositoryError.self) {
            try await RepositoryInitializer.create(
                name: "LACE", in: fixture.repository.deletingLastPathComponent()
            )
        }
    }

    @Test func aNonEmptyDirectoryIsRefused() async throws {
        let parent = try TemporaryDirectory()
        let existing = parent.url.appendingPathComponent("LACE", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try "someone's work".write(
            to: existing.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8
        )

        await #expect(throws: NewRepositoryError.self) {
            try await RepositoryInitializer.create(name: "LACE", in: parent.url)
        }
    }

    @Test func anEmptyNameIsRefused() async throws {
        let parent = try TemporaryDirectory()
        await #expect(throws: NewRepositoryError.self) {
            try await RepositoryInitializer.create(name: "   ", in: parent.url)
        }
    }

    @Test func theInitialCommitNeverSignsAndOnlyLendsAnIdentityWhenThereIsNone() {
        // Signing is disabled unconditionally: the app runs git with
        // GIT_TERMINAL_PROMPT=0, so a user who signs every commit would get a
        // hang with no passphrase prompt to answer.
        #expect(RepositoryInitializer.commitArguments(identity: false)
            .contains("commit.gpgsign=false"))
        #expect(!RepositoryInitializer.commitArguments(identity: false)
            .contains("user.name=ORE"))
        #expect(RepositoryInitializer.commitArguments(identity: true)
            .contains("user.name=ORE"))
    }

    // MARK: - Through the command boundary

    @Test func createProjectRegistersTheRepositoryAndOpensItsFirstWorkspace() async throws {
        let fixture = try await GitFixture.initialized()
        let client = InProcessCoreClient(
            store: try OreStore(),
            harnessRegistry: HarnessRegistry(harnesses: []),
            worktreeRoot: fixture.worktreeRoot
        )
        let recorder = CoreEventRecorder(client)
        let projects = fixture.root.appendingPathComponent("projects", isDirectory: true)

        await client.send(.createProject(CreateProjectRequest(
            name: "LACE",
            parentDirectory: projects.path,
            workspaceName: "Curie"
        )))

        let added = await recorder.waitFor {
            if case .workspaceAdded = $0 { return true }
            return false
        }
        guard case .workspaceAdded(let summary)? = added else {
            Issue.record("no workspaceAdded event")
            await client.shutdown()
            return
        }

        // Registered, so the picker and every later CreateWorkspace can find it.
        let repositories = try await client.repositories()
        #expect(repositories.count == 1)
        #expect(repositories.first?.name == "LACE")
        #expect(repositories.first?.defaultBranch == "main")

        // And actually openable: a real worktree, on a branch cut from the
        // initial commit.
        #expect(summary.name == "Curie")
        #expect(summary.baseBranch == "main")
        #expect(summary.branch == "ore/curie")
        #expect(FileManager.default.fileExists(atPath: summary.worktreePath))

        await client.shutdown()
    }

    @Test func createProjectCanStopAtTheRepository() async throws {
        let fixture = try await GitFixture.initialized()
        let store = try OreStore()
        let client = InProcessCoreClient(
            store: store,
            harnessRegistry: HarnessRegistry(harnesses: []),
            worktreeRoot: fixture.worktreeRoot
        )
        let projects = fixture.root.appendingPathComponent("projects", isDirectory: true)

        await client.send(.createProject(CreateProjectRequest(
            name: "LACE", parentDirectory: projects.path, createWorkspace: false
        )))

        #expect(try await client.repositories().count == 1)
        #expect(try await store.workspaces().isEmpty)

        await client.shutdown()
    }

    @Test func aSecondProjectOfTheSameNameFailsWithoutDisturbingTheFirst() async throws {
        let fixture = try await GitFixture.initialized()
        let client = InProcessCoreClient(
            store: try OreStore(),
            harnessRegistry: HarnessRegistry(harnesses: []),
            worktreeRoot: fixture.worktreeRoot
        )
        let recorder = CoreEventRecorder(client)
        let projects = fixture.root.appendingPathComponent("projects", isDirectory: true)
        let request = CreateProjectRequest(
            name: "LACE", parentDirectory: projects.path, createWorkspace: false
        )

        await client.send(.createProject(request))
        let checkpoint = await recorder.checkpoint()
        await client.send(.createProject(request))

        // Reported as a failure the user can read, not thrown across the
        // boundary — and the first project is left exactly as it was.
        let failure = await recorder.waitFor(after: checkpoint, timeout: .seconds(10)) {
            if case .commandFailed = $0 { return true }
            return false
        }
        #expect(failure != nil)
        #expect(try await client.repositories().count == 1)

        await client.shutdown()
    }
}

/// A scratch directory that removes itself, for the cases that need a parent
/// folder but no repository in it.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
