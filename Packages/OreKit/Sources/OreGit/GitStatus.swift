import Foundation
import OreProtocol

/// One changed file in a worktree.
public struct GitFileChange: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Codable {
        case added
        case modified
        case deleted
        case renamed
        case copied
        case untracked
        case conflicted
        case typeChanged
    }

    public var path: String
    /// Set for renames and copies.
    public var originalPath: String?
    public var status: Status
    public var isStaged: Bool
    /// True when the worktree still differs from the index (including untracked
    /// files). A file can be both staged and unstaged — `git add -p`.
    public var isUnstaged: Bool
    /// Nil until a diff is computed — `git status` doesn't count lines.
    public var insertions: Int?
    public var deletions: Int?
    public var isBinary: Bool

    public init(
        path: String,
        originalPath: String? = nil,
        status: Status,
        isStaged: Bool = false,
        isUnstaged: Bool = false,
        insertions: Int? = nil,
        deletions: Int? = nil,
        isBinary: Bool = false
    ) {
        self.path = path
        self.originalPath = originalPath
        self.status = status
        self.isStaged = isStaged
        self.isUnstaged = isUnstaged
        self.insertions = insertions
        self.deletions = deletions
        self.isBinary = isBinary
    }
}

/// A full status reading for a worktree.
public struct GitStatusSnapshot: Sendable, Hashable, Codable {
    public var branch: String?
    public var upstream: String?
    public var aheadOfUpstream: Int
    public var behindUpstream: Int
    public var files: [GitFileChange]
    /// Monotonic per worktree. FSEvents delivers batches out of order under
    /// load, so a consumer applies a snapshot only if its generation is newer
    /// than the one it already has.
    public var generation: UInt64
    public var stagedFileCount: Int = 0
    public var unstagedFileCount: Int = 0
    public var stagedInsertions: Int = 0
    public var stagedDeletions: Int = 0
    public var unstagedInsertions: Int = 0
    public var unstagedDeletions: Int = 0

    public init(
        branch: String? = nil,
        upstream: String? = nil,
        aheadOfUpstream: Int = 0,
        behindUpstream: Int = 0,
        files: [GitFileChange] = [],
        generation: UInt64 = 0
    ) {
        self.branch = branch
        self.upstream = upstream
        self.aheadOfUpstream = aheadOfUpstream
        self.behindUpstream = behindUpstream
        self.files = files
        self.generation = generation
        refreshWorkingTreeTotals()
    }

    public var hasUncommittedChanges: Bool { !files.isEmpty }

    mutating func refreshWorkingTreeTotals() {
        stagedFileCount = files.filter(\.isStaged).count
        unstagedFileCount = files.filter(\.isUnstaged).count
        stagedInsertions = files.filter(\.isStaged).compactMap(\.insertions).reduce(0, +)
        stagedDeletions = files.filter(\.isStaged).compactMap(\.deletions).reduce(0, +)
        unstagedInsertions = files.filter(\.isUnstaged).compactMap(\.insertions).reduce(0, +)
        unstagedDeletions = files.filter(\.isUnstaged).compactMap(\.deletions).reduce(0, +)
    }

    public func summary(aheadOfBase: Int = 0, behindBase: Int = 0) -> GitStatusSummary {
        GitStatusSummary(
            changedFileCount: files.count,
            insertions: files.compactMap(\.insertions).reduce(0, +),
            deletions: files.compactMap(\.deletions).reduce(0, +),
            hasUncommittedChanges: hasUncommittedChanges,
            aheadOfBase: aheadOfBase,
            behindBase: behindBase,
            generation: generation
        )
    }
}

/// Parser for `git status --porcelain=v2 -z --branch`.
///
/// v2 is used over v1 because it reports rename sources, submodule state and
/// branch divergence in one pass, and `-z` because a path can contain a newline
/// or a quote — with the default format git escapes those into a C-quoted form
/// that then has to be unquoted correctly, which is a bug waiting to happen.
public enum GitStatusParser {
    public static func parse(_ output: String, generation: UInt64) -> GitStatusSnapshot {
        var snapshot = GitStatusSnapshot(generation: generation)
        // Records are NUL-separated, except a rename record's second path,
        // which is a *third* NUL-separated field belonging to the record
        // before it.
        var fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        if fields.last?.isEmpty == true { fields.removeLast() }

        var index = 0
        while index < fields.count {
            let record = fields[index]
            index += 1
            guard !record.isEmpty else { continue }

            switch record.first {
            case "#":
                applyHeader(record, to: &snapshot)

            case "1":
                if let change = parseOrdinary(record) { snapshot.files.append(change) }

            case "2":
                // Rename/copy: the original path is the next NUL-separated field.
                let originalPath = index < fields.count ? fields[index] : nil
                index += 1
                if let change = parseRename(record, originalPath: originalPath) {
                    snapshot.files.append(change)
                }

            case "u":
                if let path = record.split(separator: " ", maxSplits: 10).last.map(String.init) {
                    snapshot.files.append(GitFileChange(path: path, status: .conflicted, isUnstaged: true))
                }

            case "?":
                let path = String(record.dropFirst(2))
                if !path.isEmpty {
                    snapshot.files.append(GitFileChange(path: path, status: .untracked, isUnstaged: true))
                }

            default:
                break
            }
        }
        snapshot.refreshWorkingTreeTotals()
        return snapshot
    }

    private static func applyHeader(_ record: String, to snapshot: inout GitStatusSnapshot) {
        let parts = record.split(separator: " ").map(String.init)
        guard parts.count >= 3 else { return }
        switch parts[1] {
        case "branch.head":
            snapshot.branch = parts[2] == "(detached)" ? nil : parts[2]
        case "branch.upstream":
            snapshot.upstream = parts[2]
        case "branch.ab":
            // "+3 -1"
            for token in parts.dropFirst(2) {
                if token.hasPrefix("+") { snapshot.aheadOfUpstream = Int(token.dropFirst()) ?? 0 }
                if token.hasPrefix("-") { snapshot.behindUpstream = Int(token.dropFirst()) ?? 0 }
            }
        default:
            break
        }
    }

    /// `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`
    private static func parseOrdinary(_ record: String) -> GitFileChange? {
        let parts = record.split(separator: " ", maxSplits: 8).map(String.init)
        guard parts.count >= 9 else { return nil }
        let xy = parts[1]
        return GitFileChange(
            path: parts[8],
            status: status(for: xy),
            isStaged: Self.hasStagedChange(xy),
            isUnstaged: Self.hasUnstagedChange(xy)
        )
    }

    /// `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>`
    private static func parseRename(_ record: String, originalPath: String?) -> GitFileChange? {
        let parts = record.split(separator: " ", maxSplits: 9).map(String.init)
        guard parts.count >= 10 else { return nil }
        let xy = parts[1]
        return GitFileChange(
            path: parts[9],
            originalPath: originalPath,
            status: parts[8].hasPrefix("C") ? .copied : .renamed,
            isStaged: Self.hasStagedChange(xy),
            isUnstaged: Self.hasUnstagedChange(xy)
        )
    }

    /// The two-letter code is (staged, unstaged). Whichever side is non-`.`
    /// describes the change; when both are, staged wins, since that's the state
    /// a commit would capture.
    private static func status(for xy: String) -> GitFileChange.Status {
        let characters = Array(xy)
        guard characters.count == 2 else { return .modified }
        let code = characters[0] == "." ? characters[1] : characters[0]
        switch code {
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        case "U": return .conflicted
        default: return .modified
        }
    }

    private static func hasStagedChange(_ xy: String) -> Bool {
        xy.first.map { $0 != "." } ?? false
    }

    private static func hasUnstagedChange(_ xy: String) -> Bool {
        let characters = Array(xy)
        guard characters.count >= 2 else { return false }
        return characters[1] != "."
    }
}
