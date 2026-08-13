import Foundation
import OreProtocol
import OreSupport

/// A snapshot of a worktree at a turn boundary.
public struct Checkpoint: Sendable, Hashable, Codable {
    public var workspaceID: WorkspaceID
    public var turnID: TurnID
    /// The commit object holding the tree. Not on any branch — it lives under
    /// `refs/ore/ckpt/`, so it's invisible to `git log` and to the user's
    /// branch list, and `gc` won't collect it.
    public var commit: String
    public var ref: String
    /// The provider session id at this point, so reverting the code and
    /// reverting the conversation stay in step.
    public var providerSessionID: String?
    public var createdAt: Date

    public init(
        workspaceID: WorkspaceID,
        turnID: TurnID,
        commit: String,
        ref: String,
        providerSessionID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.workspaceID = workspaceID
        self.turnID = turnID
        self.commit = commit
        self.ref = ref
        self.providerSessionID = providerSessionID
        self.createdAt = createdAt
    }
}

/// Captures and restores worktree checkpoints.
///
/// The hard constraint: a checkpoint must not disturb the user's own git state.
/// It cannot stage anything, move HEAD, or add a commit to the branch — the user
/// may be in the middle of composing a commit, and finding their index rewritten
/// by the app would be worse than not having checkpoints. So the snapshot is
/// built against a **temporary index file**: `git add -A` writes into that index
/// instead of `.git/index`, `write-tree` turns it into a tree, and `commit-tree`
/// wraps it in a commit parked on a private ref.
public actor CheckpointStore {
    private let git: GitClient

    public init(git: GitClient) {
        self.git = git
    }

    // MARK: - Capturing

    /// Snapshots the worktree. Call only at a turn boundary with the agent
    /// quiesced — a snapshot taken mid-edit captures a half-written file and
    /// restores to a state that never existed.
    public func capture(
        worktree: URL,
        workspaceID: WorkspaceID,
        turnID: TurnID,
        providerSessionID: String? = nil
    ) async throws -> Checkpoint {
        let ref = Self.ref(workspaceID: workspaceID, turnID: turnID)
        let commit = try await captureTree(
            worktree: worktree,
            ref: ref,
            message: "ore: checkpoint \(turnID.rawValue)"
        )
        return Checkpoint(
            workspaceID: workspaceID,
            turnID: turnID,
            commit: commit,
            ref: ref,
            providerSessionID: providerSessionID
        )
    }

    /// Writes the worktree's current contents to `ref` and returns the commit.
    func captureTree(worktree: URL, ref: String, message: String) async throws -> String {
        let indexFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: indexFile) }

        // GIT_INDEX_FILE redirects staging to a scratch file, leaving the
        // user's own index untouched.
        let environment = ["GIT_INDEX_FILE": indexFile.path]

        // Seed from HEAD so unchanged files aren't re-hashed on every turn.
        if (try? await git.run(["rev-parse", "--verify", "HEAD"], in: worktree)) != nil {
            try await runWithIndex(["read-tree", "HEAD"], worktree: worktree, environment: environment)
        }

        // `-A` includes untracked files and honours .gitignore, so ignored
        // build output and `node_modules` stay out of the snapshot.
        try await runWithIndex(["add", "-A", "."], worktree: worktree, environment: environment)

        let tree = try await runWithIndex(
            ["write-tree"], worktree: worktree, environment: environment
        ).trimmedStandardOutput

        let parent = try? await git.run(
            ["rev-parse", "--verify", "HEAD"], in: worktree
        ).trimmedStandardOutput

        var commitArguments = ["commit-tree", tree, "-m", message]
        if let parent, !parent.isEmpty {
            commitArguments += ["-p", parent]
        }
        let commit = try await runWithIndex(
            commitArguments,
            worktree: worktree,
            environment: environment.merging(Self.identityEnvironment) { _, new in new }
        ).trimmedStandardOutput

        try await git.runSerialized(["update-ref", ref, commit], in: worktree)
        return commit
    }

    // MARK: - Restoring

    public struct RestoreResult: Sendable {
        /// Files put back to their checkpointed contents.
        public var restoredPaths: [String]
        /// Files created after the checkpoint and therefore removed.
        public var deletedPaths: [String]
    }

    /// Restores the worktree to a checkpoint.
    ///
    /// Two halves, and the second is the one that's easy to forget: files the
    /// agent *created* after the checkpoint aren't in the snapshot, so restoring
    /// the snapshot alone leaves them behind and the revert silently isn't one.
    /// Ignored files are never touched — deleting someone's `.env` or their
    /// build cache in the name of a revert is not a trade worth making.
    @discardableResult
    public func restore(
        worktree: URL,
        to checkpoint: Checkpoint
    ) async throws -> RestoreResult {
        let before = try await trackedAndUntrackedPaths(worktree: worktree)

        // Contents first: everything present in the checkpoint goes back to
        // its snapshotted state, without touching HEAD or the index.
        try await git.runSerialized(
            ["restore", "--worktree", "--source", checkpoint.commit, "--", "."],
            in: worktree
        )

        let checkpointPaths = try await paths(in: checkpoint.commit, worktree: worktree)
        let extras = before.subtracting(checkpointPaths)

        var deleted: [String] = []
        for path in extras.sorted() {
            let url = worktree.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.removeItem(at: url)
            deleted.append(path)
        }
        removeEmptyDirectories(under: worktree)

        return RestoreResult(
            restoredPaths: checkpointPaths.sorted(),
            deletedPaths: deleted
        )
    }

    // MARK: - Listing and pruning

    public func list(workspaceID: WorkspaceID) async throws -> [String] {
        let prefix = "refs/ore/ckpt/\(workspaceID.rawValue)/"
        let output = try await git.run(["for-each-ref", "--format=%(refname)", prefix])
        return output.lines
    }

    /// Drops all checkpoints for a workspace. Called when a workspace is
    /// deleted, so ORE's refs don't outlive the thing they describe.
    public func removeAll(workspaceID: WorkspaceID) async throws {
        for ref in try await list(workspaceID: workspaceID) {
            try? await git.runSerialized(["update-ref", "-d", ref])
        }
    }

    public static func ref(workspaceID: WorkspaceID, turnID: TurnID) -> String {
        "refs/ore/ckpt/\(workspaceID.rawValue)/\(turnID.rawValue)"
    }

    // MARK: - Helpers

    /// Commits are authored by ORE, not by the user: a checkpoint is
    /// bookkeeping, and attributing it to the user would put their name on
    /// something they didn't write.
    private static let identityEnvironment = [
        "GIT_AUTHOR_NAME": "ORE",
        "GIT_AUTHOR_EMAIL": "ore@localhost",
        "GIT_COMMITTER_NAME": "ORE",
        "GIT_COMMITTER_EMAIL": "ore@localhost",
    ]

    @discardableResult
    private func runWithIndex(
        _ arguments: [String],
        worktree: URL,
        environment: [String: String]
    ) async throws -> GitOutput {
        try await git.runSerialized(arguments, in: worktree, environmentOverrides: environment)
    }

    private func paths(in commit: String, worktree: URL) async throws -> Set<String> {
        let output = try await git.run(
            ["ls-tree", "-r", "--name-only", "-z", commit],
            in: worktree
        )
        return Set(output.nulSeparatedFields)
    }

    /// Tracked files plus untracked-but-not-ignored ones. Ignored files are
    /// deliberately excluded: they are never ours to delete.
    private func trackedAndUntrackedPaths(worktree: URL) async throws -> Set<String> {
        let output = try await git.run(
            ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            in: worktree
        )
        return Set(output.nulSeparatedFields)
    }

    /// Removing files can leave empty directories behind, which git doesn't
    /// track but the user does see.
    private func removeEmptyDirectories(under root: URL) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var directories: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            directories.append(url)
        }
        // Deepest first, so a directory emptied by its children's removal is
        // itself removable.
        for url in directories.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            let contents = try? fileManager.contentsOfDirectory(atPath: url.path)
            if contents?.isEmpty == true {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
