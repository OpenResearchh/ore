import Foundation
import OreProtocol

/// The diff an AI review agent should see — the same scope the Review pane
/// shows by default: this branch versus its merge-base, plus untracked files.
///
/// `git diff HEAD` is the wrong answer. It hides brand-new files and anything
/// already committed on the workspace branch.
public enum ReviewDiff {
    public static func unifiedText(in worktree: URL) async -> String {
        do {
            let git = try GitClient(repositoryURL: worktree)
            let base = await inferredBaseBranch(git: git, worktree: worktree)
            let mergeBase = await git.mergeBase(with: base, in: worktree) ?? "HEAD"

            let tracked = try await git.run(
                ["diff", "--no-color", "--no-ext-diff", "-M", mergeBase, "--"],
                in: worktree
            ).standardOutput

            let untrackedNames = try await git.run(
                ["ls-files", "--others", "--exclude-standard", "-z"],
                in: worktree
            )
            var parts: [String] = []
            if !tracked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(tracked)
            }
            for path in untrackedNames.nulSeparatedFields {
                let output = try await git.run(
                    [
                        "diff", "--no-color", "--no-ext-diff", "--no-index", "--",
                        "/dev/null", path,
                    ],
                    in: worktree,
                    allowedExitCodes: [0, 1]
                ).standardOutput
                if !output.isEmpty { parts.append(output) }
            }
            return parts.joined(separator: parts.isEmpty ? "" : "\n")
        } catch {
            return "Unable to read workspace diff: \(error)"
        }
    }

    /// `main` / `master` / the origin default, so a committed feature branch
    /// still has something to review. Falls back to `HEAD` (working tree only)
    /// when this repo has no recognizable base.
    static func inferredBaseBranch(git: GitClient, worktree: URL) async -> String {
        if let pointer = try? await git.run(
            ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"],
            in: worktree
        ).trimmedStandardOutput, !pointer.isEmpty {
            return String(pointer.split(separator: "/").last ?? Substring(pointer))
        }
        for name in ["main", "master"] {
            if (try? await git.run(["rev-parse", "--verify", name], in: worktree)) != nil {
                return name
            }
        }
        return "HEAD"
    }
}

/// On-disk review comments. The MCP server and the app share this file so an
/// agent's `PostDiffComment` is the same object the Review pane anchors.
public enum DiffCommentFile {
    public static let fileName = "ore-diff-comments.json"

    public static func url(in worktree: URL) -> URL {
        worktree
            .appendingPathComponent(".context", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public static func load(in worktree: URL) -> [DiffCommentReference] {
        let url = url(in: worktree)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([DiffCommentReference].self, from: data)) ?? []
    }

    public static func save(_ comments: [DiffCommentReference], in worktree: URL) throws {
        let url = url(in: worktree)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(comments)
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    public static func append(
        _ comment: DiffCommentReference, in worktree: URL
    ) throws -> Int {
        var comments = load(in: worktree)
        comments.append(comment)
        try save(comments, in: worktree)
        return comments.count
    }
}
