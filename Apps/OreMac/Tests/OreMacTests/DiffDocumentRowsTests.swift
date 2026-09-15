import AppKit
import Foundation
import OreGit
import Testing

@testable import OreMac

/// The diff document's row model.
///
/// These cover the pieces that used to live inside SwiftUI's `body`: the row
/// list, its measurements, the drag-to-row mapping and the "viewed"
/// fingerprint. All four ran per row per body pass; the point of pulling them
/// out is that they now run once per load — and can be checked here.
struct DiffDocumentRowsTests {
    // MARK: - Flattening

    @Test func everyHunkContributesOneHeaderAndOneRowPerLine() {
        let rows = DiffRowBuilder.build(sample()).rows

        // A header plus three lines, then a header plus one.
        #expect(rows.count == (1 + 3) + (1 + 1))
        #expect(rows[0].isHeader)
        #expect(rows[0].ref == nil)
        #expect(!rows[1].isHeader)
        #expect(rows[4].isHeader)
        // Ids are the flat offsets, in order, with no gaps.
        #expect(rows.map(\.id) == Array(0..<rows.count))
    }

    @Test func aLineRowCarriesItsHunkItsNumbersAndItsAnchor() {
        let rows = DiffRowBuilder.build(sample()).rows

        #expect(rows[1].ref == DiffLineRef(hunk: 0, line: 0))
        #expect(rows[1].oldNumber == "10")
        #expect(rows[1].newNumber == "10")
        #expect(rows[1].kind == .context)

        // An addition exists only on the new side, so the old gutter is blank
        // and the comment anchors to the new line number.
        #expect(rows[2].oldNumber == "")
        #expect(rows[2].newNumber == "11")
        #expect(rows[2].commentLine == 11)

        // A deletion is the mirror image.
        #expect(rows[3].newNumber == "")
        #expect(rows[3].commentLine == 11)
    }

    /// The gutter's "+" is disabled on rows with nothing to anchor to.
    @Test func aNoNewlineMarkerHasNoLineToCommentOn() {
        let file = FileDiff(
            path: "a.txt",
            status: .modified,
            hunks: [DiffHunk(
                oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
                lines: [DiffLine(kind: .noNewline, text: " No newline at end of file")]
            )]
        )

        let rows = DiffRowBuilder.build(file).rows
        #expect(rows[1].commentLine == nil)
        #expect(rows[1].kind == .noNewline)
    }

    @Test func anEmptyDiffIsAnEmptyRowSet() {
        let set = DiffRowBuilder.build(FileDiff(path: "new.png", status: .added))
        #expect(set.rows.isEmpty)
        #expect(set.height == 0)
        #expect(set.row(atY: 0) == nil)
    }

    // MARK: - Measurement

    @Test func everyRowHasAFixedHeightAndTheOffsetsAreItsPrefixSums() {
        let set = DiffRowBuilder.build(sample())

        #expect(set.offsets.count == set.rows.count + 1)
        #expect(set.offsets[0] == 0)
        for (index, row) in set.rows.enumerated() {
            let expected = row.isHeader ? DiffRowBuilder.headerHeight : DiffRowBuilder.lineHeight
            #expect(row.height == expected)
            #expect(set.offsets[index + 1] - set.offsets[index] == expected)
        }
        #expect(set.height == set.offsets.last)
    }

    /// Wrapping is what made heights unpredictable, so the document is sized
    /// off the longest line in the whole diff, not the longest one on screen.
    @Test func theDocumentIsAsWideAsItsLongestLine() {
        let set = DiffRowBuilder.build(sample())
        #expect(set.columns >= DiffRowBuilder.columns(in: "    print(\"hello\")") + 1)

        let narrow = DiffRowBuilder.documentWidth(columns: set.columns, viewport: 100)
        let wide = DiffRowBuilder.documentWidth(columns: set.columns, viewport: 5_000)
        // Never narrower than its content, never narrower than the viewport.
        #expect(narrow > 100)
        #expect(wide == 5_000)
    }

    @Test func aTabMeasuresToItsNextStopNotToOneCell() {
        #expect(DiffRowBuilder.columns(in: "abcd") == 4)
        #expect(DiffRowBuilder.columns(in: "\t") == DiffRowBuilder.tabStop)
        #expect(DiffRowBuilder.columns(in: "\t\t") == DiffRowBuilder.tabStop * 2)
        // A tab after one character fills out the first stop only.
        #expect(DiffRowBuilder.columns(in: "a\t") == DiffRowBuilder.tabStop)
    }

    // MARK: - Drag to row

    @Test func aDragOverTheGutterFindsTheRowUnderIt() {
        let set = DiffRowBuilder.build(sample())

        for (index, row) in set.rows.enumerated() {
            let top = set.offsets[index]
            #expect(set.row(atY: top)?.id == row.id)
            #expect(set.row(atY: top + row.height - 0.5)?.id == row.id)
        }
    }

    @Test func aDragOutsideTheDocumentSelectsNothing() {
        let set = DiffRowBuilder.build(sample())
        #expect(set.row(atY: -1) == nil)
        #expect(set.row(atY: set.height) == nil)
        #expect(set.row(atY: set.height + 500) == nil)
    }

    // MARK: - Viewed fingerprint

    /// The tick is stored against this hash, so changing how it is computed
    /// would silently un-tick every file a user has already reviewed. This
    /// pins it to the formula the old main-actor version produced.
    @Test func theFingerprintMatchesTheStringItReplaced() {
        let file = sample()
        let joined = file.hunks
            .flatMap(\.lines)
            .map { "\($0.kind):\($0.text)" }
            .joined(separator: "\n")
        var expected: UInt64 = 14_695_981_039_346_656_037
        for byte in joined.utf8 { expected = (expected ^ UInt64(byte)) &* 1_099_511_628_211 }

        #expect(DiffContentHash.of(file) == String(expected, radix: 16))
    }

    @Test func aChangedLineChangesTheFingerprint() {
        var edited = sample()
        edited.hunks[0].lines[1].text = "    print(\"goodbye\")"
        #expect(DiffContentHash.of(edited) != DiffContentHash.of(sample()))
    }

    // MARK: - Helpers

    private func sample() -> FileDiff {
        FileDiff(
            path: "Sources/App/Main.swift",
            status: .modified,
            hunks: [
                DiffHunk(
                    oldStart: 10, oldCount: 2, newStart: 10, newCount: 2, header: "func main()",
                    lines: [
                        DiffLine(kind: .context, text: "func main() {", oldLineNumber: 10, newLineNumber: 10),
                        DiffLine(kind: .added, text: "    print(\"hello\")", newLineNumber: 11),
                        DiffLine(kind: .removed, text: "    print(\"hi\")", oldLineNumber: 11),
                    ]
                ),
                DiffHunk(
                    oldStart: 40, oldCount: 1, newStart: 41, newCount: 1,
                    lines: [
                        DiffLine(kind: .context, text: "}", oldLineNumber: 40, newLineNumber: 41),
                    ]
                ),
            ]
        )
    }
}

/// How the Changes list splits a diff into sections.
///
/// Worth its own tests because the split used to be three computed properties
/// that rebuilt `Set<String>`s once per file tested, six times per body pass.
struct ReviewChangeBucketsTests {
    @Test func conflictsComeOutOfTheStagingSplitEntirely() {
        let buckets = ReviewChangeBuckets(
            diffs: [diff("a.swift"), diff("b.swift"), diff("c.swift")],
            workingTreeFiles: [
                change("a.swift", status: .conflicted, unstaged: true),
                change("b.swift", unstaged: true),
            ]
        )

        #expect(buckets.conflicted.map(\.path) == ["a.swift"])
        #expect(buckets.unconflicted.map(\.path) == ["b.swift", "c.swift"])
        #expect(buckets.sections.flatMap { $0.files.map(\.path) } == ["b.swift", "c.swift"])
    }

    /// `git add -p` leaves a file in both; the half still needing a decision wins.
    @Test func aPartlyStagedFileIsFiledUnderUnstaged() {
        let buckets = ReviewChangeBuckets(
            diffs: [diff("a.swift")],
            workingTreeFiles: [change("a.swift", staged: true, unstaged: true)]
        )

        #expect(buckets.sections.map(\.bucket) == [.unstaged])
    }

    @Test func aFileGitStatusDoesNotMentionIsAlreadyCommitted() {
        let buckets = ReviewChangeBuckets(diffs: [diff("a.swift")], workingTreeFiles: [])
        #expect(buckets.sections.map(\.bucket) == [.committed])
    }

    /// A lone header just repeats the tab count and the +/- totals.
    @Test func theListOnlySplitsWhenMoreThanOneBucketHasFiles() {
        let single = ReviewChangeBuckets(
            diffs: [diff("a.swift"), diff("b.swift")],
            workingTreeFiles: [change("a.swift", unstaged: true), change("b.swift", unstaged: true)]
        )
        #expect(!single.showsSections)

        let split = ReviewChangeBuckets(
            diffs: [diff("a.swift"), diff("b.swift")],
            workingTreeFiles: [change("a.swift", unstaged: true), change("b.swift", staged: true)]
        )
        #expect(split.showsSections)
        // Unstaged, staged, committed — in that order, empty buckets dropped.
        #expect(split.sections.map(\.bucket) == [.unstaged, .staged])
    }

    @Test func sectionsKeepTheDiffsOwnOrder() {
        let buckets = ReviewChangeBuckets(
            diffs: [diff("c.swift"), diff("a.swift"), diff("b.swift")],
            workingTreeFiles: []
        )
        #expect(buckets.sections.first?.files.map(\.path) == ["c.swift", "a.swift", "b.swift"])
    }

    private func diff(_ path: String) -> FileDiff {
        FileDiff(path: path, status: .modified)
    }

    private func change(
        _ path: String,
        status: GitFileChange.Status = .modified,
        staged: Bool = false,
        unstaged: Bool = false
    ) -> GitFileChange {
        GitFileChange(path: path, status: status, isStaged: staged, isUnstaged: unstaged)
    }
}
