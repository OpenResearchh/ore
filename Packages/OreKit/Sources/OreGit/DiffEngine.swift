import Foundation
import OreProtocol

/// A parsed unified diff for one file.
public struct FileDiff: Sendable, Hashable, Codable {
    public var path: String
    public var originalPath: String?
    public var status: GitFileChange.Status
    public var hunks: [DiffHunk]
    public var isBinary: Bool
    /// True when the file was too large to diff. The UI offers to open it
    /// rather than pretending there's nothing to see.
    public var isTruncated: Bool

    public var insertions: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count }
    }

    public var deletions: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count }
    }

    public init(
        path: String,
        originalPath: String? = nil,
        status: GitFileChange.Status,
        hunks: [DiffHunk] = [],
        isBinary: Bool = false,
        isTruncated: Bool = false
    ) {
        self.path = path
        self.originalPath = originalPath
        self.status = status
        self.hunks = hunks
        self.isBinary = isBinary
        self.isTruncated = isTruncated
    }
}

/// A turn that captured a worktree snapshot, so the review pane can show
/// "what this turn changed" without the user tracking refs themselves.
public struct TurnCheckpoint: Sendable, Hashable, Codable, Identifiable {
    public var id: String { turnID.rawValue }
    public var turnID: TurnID
    public var ordinal: Int
    public var commit: String
    public var summary: String?
    public var prompt: String?

    public init(
        turnID: TurnID,
        ordinal: Int,
        commit: String,
        summary: String? = nil,
        prompt: String? = nil
    ) {
        self.turnID = turnID
        self.ordinal = ordinal
        self.commit = commit
        self.summary = summary
        self.prompt = prompt
    }
}

public struct DiffHunk: Sendable, Hashable, Codable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// The text after the `@@` marker — usually the enclosing function.
    public var header: String
    public var lines: [DiffLine]

    public init(
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        header: String = "",
        lines: [DiffLine] = []
    ) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.header = header
        self.lines = lines
    }
}

public struct DiffLine: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        case context
        case added
        case removed
        /// "\ No newline at end of file"
        case noNewline
    }

    public var kind: Kind
    public var text: String
    /// Line numbers on each side; nil on the side where the line doesn't exist.
    /// Comments anchor to these, which is why they're carried per line rather
    /// than recomputed at render time.
    public var oldLineNumber: Int?
    public var newLineNumber: Int?

    public init(kind: Kind, text: String, oldLineNumber: Int? = nil, newLineNumber: Int? = nil) {
        self.kind = kind
        self.text = text
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

/// Produces the diffs the review UI renders.
public actor DiffEngine {
    private let git: GitClient
    /// Beyond this, a single file's diff is not something a human reviews, and
    /// rendering it costs more than it's worth.
    private let maximumDiffBytes: Int

    public init(git: GitClient, maximumDiffBytes: Int = 2_000_000) {
        self.git = git
        self.maximumDiffBytes = maximumDiffBytes
    }

    /// Everything this workspace changed relative to its base branch, including
    /// uncommitted work — which is what the reviewer actually wants to see, not
    /// just what happens to be committed.
    public func diffAgainstBase(
        worktree: URL,
        baseBranch: String,
        includeUntracked: Bool = true
    ) async throws -> [FileDiff] {
        let mergeBase = await git.mergeBase(with: baseBranch, in: worktree) ?? baseBranch

        var diffs = try await diff(
            arguments: ["diff", "--no-color", "--no-ext-diff", "-M", mergeBase, "--"],
            worktree: worktree
        )
        if includeUntracked {
            diffs += try await untrackedDiffs(worktree: worktree)
        }
        return diffs.sorted { $0.path < $1.path }
    }

    /// Uncommitted changes only.
    public func workingTreeDiff(
        worktree: URL,
        includeUntracked: Bool = true
    ) async throws -> [FileDiff] {
        var diffs = try await diff(
            arguments: ["diff", "--no-color", "--no-ext-diff", "-M", "HEAD", "--"],
            worktree: worktree
        )
        if includeUntracked {
            diffs += try await untrackedDiffs(worktree: worktree)
        }
        return diffs.sorted { $0.path < $1.path }
    }

    /// Working tree plus untracked files, relative to an arbitrary commit —
    /// used for "what changed since this turn's checkpoint".
    public func diffFromCommit(
        worktree: URL,
        commit: String,
        includeUntracked: Bool = true
    ) async throws -> [FileDiff] {
        var diffs = try await diff(
            arguments: ["diff", "--no-color", "--no-ext-diff", "-M", commit, "--"],
            worktree: worktree
        )
        if includeUntracked {
            diffs += try await untrackedDiffs(worktree: worktree)
        }
        return diffs.sorted { $0.path < $1.path }
    }

    /// What changed during one agent turn, from two checkpoint refs.
    ///
    /// This is what makes "show me what this turn did" answerable without
    /// asking the user to keep track themselves.
    public func diffBetweenCheckpoints(
        worktree: URL,
        from: String,
        to: String
    ) async throws -> [FileDiff] {
        try await diff(
            arguments: ["diff", "--no-color", "--no-ext-diff", "-M", from, to, "--"],
            worktree: worktree
        ).sorted { $0.path < $1.path }
    }

    private func diff(arguments: [String], worktree: URL) async throws -> [FileDiff] {
        let output = try await git.run(arguments, in: worktree)
        guard output.standardOutput.utf8.count <= maximumDiffBytes else {
            // Fall back to the file list so the UI can still show what changed.
            let names = try await git.run(
                arguments.filter { $0 != "--" } + ["--name-status", "-z"],
                in: worktree
            )
            return names.nulSeparatedFields.chunked(into: 2).compactMap { pair in
                guard pair.count == 2 else { return nil }
                return FileDiff(path: pair[1], status: .modified, isTruncated: true)
            }
        }
        return UnifiedDiffParser.parse(output.standardOutput)
    }

    /// Untracked files don't appear in `git diff` at all, but from the user's
    /// point of view a file the agent just created is the most important thing
    /// in the review.
    private func untrackedDiffs(worktree: URL) async throws -> [FileDiff] {
        let output = try await git.run(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            in: worktree
        )
        var results: [FileDiff] = []
        for path in output.nulSeparatedFields {
            // `--no-index` diffs an untracked file against nothing, giving the
            // same unified format as everything else. It exits 1 on difference,
            // which is success here.
            let arguments = [
                "diff", "--no-color", "--no-ext-diff", "--no-index", "--", "/dev/null", path,
            ]
            guard let text = try? await git.run(
                arguments, in: worktree, allowedExitCodes: [0, 1]
            ).standardOutput else {
                if let fallback = try? failedUntrackedDiff(path: path, worktree: worktree) {
                    results.append(fallback)
                }
                continue
            }
            results += UnifiedDiffParser.parse(text).map { diff in
                var diff = diff
                diff.path = path
                diff.status = .untracked
                return diff
            }
        }
        return results
    }

    private func failedUntrackedDiff(path: String, worktree: URL) throws -> FileDiff {
        // `git diff --no-index` exits non-zero when files differ, which
        // GitClient reports as a failure. Read the file directly instead.
        let url = worktree.appendingPathComponent(path)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return FileDiff(path: path, status: .untracked, isBinary: true)
        }
        var rawLines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        // A trailing newline produces an empty final component that isn't a line.
        if rawLines.last?.isEmpty == true { rawLines.removeLast() }
        let lines = rawLines.enumerated()
            .map { DiffLine(kind: .added, text: String($0.element), newLineNumber: $0.offset + 1) }
        return FileDiff(
            path: path,
            status: .untracked,
            hunks: [DiffHunk(
                oldStart: 0, oldCount: 0,
                newStart: 1, newCount: lines.count,
                lines: lines
            )]
        )
    }
}

public enum UnifiedDiffParser {
    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        var currentHunk: DiffHunk?
        var oldLine = 0
        var newLine = 0

        func closeHunk() {
            if let hunk = currentHunk { current?.hunks.append(hunk) }
            currentHunk = nil
        }
        func closeFile() {
            closeHunk()
            if let file = current { files.append(file) }
            current = nil
        }

        var textLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // Diff output ends with a newline, which splitting turns into a
        // trailing empty component. Left in, it becomes a blank context line
        // appended to every hunk — a line the file doesn't have.
        if textLines.last?.isEmpty == true { textLines.removeLast() }

        for line in textLines {
            if line.hasPrefix("diff --git ") {
                closeFile()
                current = FileDiff(path: parsePath(from: String(line)), status: .modified)
                continue
            }
            guard current != nil else { continue }

            if line.hasPrefix("new file mode") {
                current?.status = .added
            } else if line.hasPrefix("deleted file mode") {
                current?.status = .deleted
            } else if line.hasPrefix("rename from ") {
                current?.originalPath = String(line.dropFirst("rename from ".count))
                current?.status = .renamed
            } else if line.hasPrefix("rename to ") {
                current?.path = String(line.dropFirst("rename to ".count))
                current?.status = .renamed
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                current?.isBinary = true
            } else if line.hasPrefix("+++ b/") {
                // Authoritative destination path, and correct even when the
                // `diff --git` header was ambiguous because of spaces.
                current?.path = String(line.dropFirst("+++ b/".count))
            } else if line.hasPrefix("@@") {
                closeHunk()
                guard let header = parseHunkHeader(String(line)) else { continue }
                currentHunk = header
                oldLine = header.oldStart
                newLine = header.newStart
            } else if currentHunk != nil {
                appendLine(
                    String(line),
                    to: &currentHunk,
                    oldLine: &oldLine,
                    newLine: &newLine
                )
            }
        }
        closeFile()
        return files
    }

    private static func appendLine(
        _ line: String,
        to hunk: inout DiffHunk?,
        oldLine: inout Int,
        newLine: inout Int
    ) {
        guard let marker = line.first else {
            // An empty line inside a hunk is a context line whose content is
            // empty — git omits the leading space on a bare newline.
            hunk?.lines.append(DiffLine(
                kind: .context, text: "", oldLineNumber: oldLine, newLineNumber: newLine
            ))
            oldLine += 1
            newLine += 1
            return
        }

        let text = String(line.dropFirst())
        switch marker {
        case "+":
            hunk?.lines.append(DiffLine(kind: .added, text: text, newLineNumber: newLine))
            newLine += 1
        case "-":
            hunk?.lines.append(DiffLine(kind: .removed, text: text, oldLineNumber: oldLine))
            oldLine += 1
        case " ":
            hunk?.lines.append(DiffLine(
                kind: .context, text: text, oldLineNumber: oldLine, newLineNumber: newLine
            ))
            oldLine += 1
            newLine += 1
        case "\\":
            hunk?.lines.append(DiffLine(kind: .noNewline, text: text))
        default:
            break
        }
    }

    /// `@@ -12,7 +12,9 @@ func example() {`
    private static func parseHunkHeader(_ line: String) -> DiffHunk? {
        guard let range = line.range(of: "@@", range: line.index(line.startIndex, offsetBy: 2)..<line.endIndex)
        else { return nil }
        let spec = line[line.index(line.startIndex, offsetBy: 2)..<range.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let header = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)

        let sides = spec.split(separator: " ").map(String.init)
        guard sides.count >= 2 else { return nil }
        let old = parseSide(sides[0].dropFirst())   // -12,7
        let new = parseSide(sides[1].dropFirst())   // +12,9

        return DiffHunk(
            oldStart: old.start, oldCount: old.count,
            newStart: new.start, newCount: new.count,
            header: header
        )
    }

    private static func parseSide(_ text: Substring) -> (start: Int, count: Int) {
        let parts = text.split(separator: ",").map(String.init)
        let start = Int(parts.first ?? "") ?? 0
        // A missing count means exactly one line.
        let count = parts.count > 1 ? (Int(parts[1]) ?? 0) : 1
        return (start, count)
    }

    /// `diff --git a/path b/path`. Paths with spaces make this ambiguous, which
    /// is why the `+++ b/` line overrides it when present.
    private static func parsePath(from line: String) -> String {
        let body = line.dropFirst("diff --git ".count)
        guard let bIndex = body.range(of: " b/") else {
            return String(body.dropFirst(2))
        }
        return String(body[bIndex.upperBound...])
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
