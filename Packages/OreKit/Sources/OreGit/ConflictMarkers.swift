import Foundation

/// One `<<<<<<<` / `=======` / `>>>>>>>` region inside a conflicted file.
public struct ConflictHunk: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(startLine)-\(endLine)" }
    /// 1-based line of the `<<<<<<<` marker in the working-tree file.
    public var startLine: Int
    /// 1-based line of the `>>>>>>>` marker, inclusive.
    public var endLine: Int
    public var ours: String
    public var theirs: String
    /// The marker labels git wrote (`HEAD`, the incoming branch, …).
    public var oursLabel: String
    public var theirsLabel: String

    public init(
        startLine: Int,
        endLine: Int,
        ours: String,
        theirs: String,
        oursLabel: String = "HEAD",
        theirsLabel: String = "incoming"
    ) {
        self.startLine = startLine
        self.endLine = endLine
        self.ours = ours
        self.theirs = theirs
        self.oursLabel = oursLabel
        self.theirsLabel = theirsLabel
    }
}

public enum ConflictSide: String, Sendable, Codable, Hashable {
    case ours
    case theirs
}

/// Parses and rewrites git merge conflict markers.
public enum ConflictMarkers {
    /// Finds every conflict region in `text`. Nested or malformed markers are
    /// skipped rather than producing a half-resolved file.
    public static func hunks(in text: String) -> [ConflictHunk] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        var result: [ConflictHunk] = []
        var index = 0
        while index < lines.count {
            guard lines[index].hasPrefix("<<<<<<<") else {
                index += 1
                continue
            }
            let start = index
            let oursLabel = String(lines[index].dropFirst(7)).trimmingCharacters(in: .whitespaces)
            index += 1
            var ours: [String] = []
            while index < lines.count, !lines[index].hasPrefix("=======") {
                if lines[index].hasPrefix("<<<<<<<") { break }
                ours.append(lines[index])
                index += 1
            }
            guard index < lines.count, lines[index].hasPrefix("=======") else { break }
            index += 1
            var theirs: [String] = []
            while index < lines.count, !lines[index].hasPrefix(">>>>>>>") {
                if lines[index].hasPrefix("<<<<<<<") { break }
                theirs.append(lines[index])
                index += 1
            }
            guard index < lines.count, lines[index].hasPrefix(">>>>>>>") else { break }
            let theirsLabel = String(lines[index].dropFirst(7)).trimmingCharacters(in: .whitespaces)
            result.append(ConflictHunk(
                startLine: start + 1,
                endLine: index + 1,
                ours: ours.joined(separator: "\n"),
                theirs: theirs.joined(separator: "\n"),
                oursLabel: oursLabel.isEmpty ? "HEAD" : oursLabel,
                theirsLabel: theirsLabel.isEmpty ? "incoming" : theirsLabel
            ))
            index += 1
        }
        return result
    }

    /// Replaces the hunk covering `startLine` with `side`'s body. Returns nil
    /// when that hunk is no longer in the text (already resolved, or the file
    /// moved).
    public static func resolving(
        _ text: String,
        hunkStartingAt startLine: Int,
        side: ConflictSide
    ) -> String? {
        let regions = hunks(in: text)
        guard let hunk = regions.first(where: { $0.startLine == startLine }) else {
            return nil
        }
        return replacing(hunk, in: text, with: side == .ours ? hunk.ours : hunk.theirs)
    }

    public static func resolvingAll(_ text: String, side: ConflictSide) -> String {
        var current = text
        while let hunk = hunks(in: current).first {
            current = replacing(hunk, in: current, with: side == .ours ? hunk.ours : hunk.theirs)
        }
        return current
    }

    private static func replacing(_ hunk: ConflictHunk, in text: String, with body: String) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        let start = max(0, hunk.startLine - 1)
        let end = min(lines.count, hunk.endLine)
        guard start < end else { return text }
        var next = Array(lines.prefix(start))
        if !body.isEmpty {
            next.append(contentsOf: body.split(
                omittingEmptySubsequences: false, whereSeparator: \.isNewline
            ).map(String.init))
        }
        next.append(contentsOf: lines.dropFirst(end))
        let joined = next.joined(separator: "\n")
        if text.hasSuffix("\n"), !joined.hasSuffix("\n") { return joined + "\n" }
        return joined
    }
}
