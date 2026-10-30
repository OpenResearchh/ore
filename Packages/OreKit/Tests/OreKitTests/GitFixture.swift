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

    /// A bare `origin` remote with `HEAD` pushed, so fetch tests have a
    /// network that is still entirely on disk.
    @discardableResult
    func attachOrigin() async throws -> URL {
        let origin = root.appendingPathComponent("origin.git", isDirectory: true)
        // `-b main` so the bare repo's HEAD matches the fixture. Without it
        // HEAD points at a nonexistent `master`, a clone can't check out, and
        // the next push lands on `master` instead of updating `main`.
        try await run(["init", "-q", "--bare", "-b", "main", origin.path])
        try await run(["remote", "add", "origin", origin.path])
        try await run(["push", "-q", "-u", "origin", "HEAD"])
        return origin
    }

    /// Commit on a throwaway clone of origin and push, leaving this checkout
    /// stale — the shape of a machine that has not pulled since GitHub moved.
    @discardableResult
    func advanceOrigin(
        file: String = "from-origin.txt",
        contents: String = "landed remotely\n",
        message: String = "landed on origin"
    ) async throws -> String {
        let origin = root.appendingPathComponent("origin.git")
        let checkout = root.appendingPathComponent("origin-advance", isDirectory: true)
        if FileManager.default.fileExists(atPath: checkout.path) {
            try FileManager.default.removeItem(at: checkout)
        }
        try await git.run(["clone", "-q", origin.path, checkout.path], in: root)
        let other = try GitClient(repositoryURL: checkout)
        try await other.run(["config", "user.email", "tests@ore.local"])
        try await other.run(["config", "user.name", "ORE Tests"])
        try await other.run(["config", "commit.gpgsign", "false"])
        let url = checkout.appendingPathComponent(file)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try await other.run(["add", "-A"])
        try await other.run(["commit", "-q", "-m", message])
        try await other.run(["push", "-q", "origin", "HEAD"])
        return try await other.run(["rev-parse", "HEAD"]).trimmedStandardOutput
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
