import Foundation
import OreGit

/// A throwaway git repository on disk.
///
/// The git layer is tested against real repositories rather than against a
/// mocked `git`. The entire reason ORE shells out to the system binary is
/// fidelity with the user's actual git — a mock would test our idea of git and
/// prove nothing about the thing that ships.
final class GitFixture {
    let root: URL
    let repository: URL
    let git: GitClient

    init(name: String = "repo") throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-tests-\(UUID().uuidString)", isDirectory: true)
        repository = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

        git = try GitClient(repositoryURL: repository)
    }

    /// A repository with one commit on `main`, ready to branch from.
    static func initialized(name: String = "repo") async throws -> GitFixture {
        let fixture = try GitFixture(name: name)
        try await fixture.run(["init", "-q", "-b", "main"])
        try await fixture.configureIdentity()
        try fixture.write("README.md", "# repo\n")
        try fixture.write(".gitignore", ".env\nbuild/\n")
        try await fixture.run(["add", "-A"])
        try await fixture.commit("initial commit")
        return fixture
    }

    func configureIdentity() async throws {
        // A CI machine has no git identity, and `commit` fails without one.
        try await run(["config", "user.email", "tests@ore.local"])
        try await run(["config", "user.name", "ORE Tests"])
        try await run(["config", "commit.gpgsign", "false"])
    }

    @discardableResult
    func run(_ arguments: [String], in directory: URL? = nil) async throws -> GitOutput {
        try await git.run(arguments, in: directory ?? repository)
    }

    func commit(_ message: String, in directory: URL? = nil) async throws {
        try await run(["commit", "-q", "-m", message], in: directory)
    }

    func write(_ relativePath: String, _ contents: String, in directory: URL? = nil) throws {
        let url = (directory ?? repository).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ relativePath: String, in directory: URL? = nil) -> String? {
        try? String(
            contentsOf: (directory ?? repository).appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func exists(_ relativePath: String, in directory: URL? = nil) -> Bool {
        FileManager.default.fileExists(
            atPath: (directory ?? repository).appendingPathComponent(relativePath).path
        )
    }

    func remove(_ relativePath: String, in directory: URL? = nil) throws {
        try FileManager.default.removeItem(
            at: (directory ?? repository).appendingPathComponent(relativePath)
        )
    }

    /// Worktrees are created under the fixture's own root so a failing test
    /// can't leave anything in the user's real `~/ore`.
    var worktreeRoot: URL {
        root.appendingPathComponent("worktrees", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
