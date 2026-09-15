import Foundation
import Testing

@testable import OreMac

/// The @-mention index is what the composer consults on every ChatPane pass
/// while a mention is open, so its ordering rules and its memo both matter.
@MainActor
struct MentionSuggestionIndexTests {
    private func file(_ path: String) -> WorkspaceFileNode {
        WorkspaceFileNode(
            path: path,
            name: String(path.split(separator: "/").last ?? ""),
            isDirectory: false,
            children: nil
        )
    }

    private func directory(_ path: String) -> WorkspaceFileNode {
        WorkspaceFileNode(
            path: path,
            name: String(path.split(separator: "/").last ?? ""),
            isDirectory: true,
            children: []
        )
    }

    @Test func directoriesNeverSuggest() {
        let index = MentionSuggestionIndex(files: [directory("Sources"), file("Sources/App.swift")])
        #expect(index.suggestions(query: "", excluding: []).map(\.path) == ["Sources/App.swift"])
    }

    @Test func nameMatchesLeadPathMatches() {
        let index = MentionSuggestionIndex(files: [
            file("model/notes.txt"),
            file("Model.swift"),
        ])
        // "model" prefixes the second file's *name*; the first only matches on
        // its directory.
        #expect(index.suggestions(query: "model", excluding: []).first?.path == "Model.swift")
    }

    @Test func queryIsCaseInsensitive() {
        let index = MentionSuggestionIndex(files: [file("Sources/Readme.md")])
        #expect(index.suggestions(query: "READ", excluding: []).count == 1)
    }

    @Test func bareMentionBuriesDotfiles() {
        let index = MentionSuggestionIndex(files: [
            file(".git/config"),
            file("a.swift"),
        ])
        #expect(index.suggestions(query: "", excluding: []).map(\.path) == ["a.swift", ".git/config"])
    }

    @Test func explicitQueryStillFindsDotfiles() {
        let index = MentionSuggestionIndex(files: [file(".git/config"), file("a.swift")])
        #expect(index.suggestions(query: "config", excluding: []).map(\.path) == [".git/config"])
    }

    @Test func shorterPathsFirstThenAlphabetical() {
        let index = MentionSuggestionIndex(files: [
            file("deep/nested/x.swift"),
            file("b/x.swift"),
            file("a/x.swift"),
        ])
        #expect(index.suggestions(query: "x", excluding: []).map(\.path) == [
            "a/x.swift", "b/x.swift", "deep/nested/x.swift",
        ])
    }

    @Test func alreadyAttachedFilesDropOut() {
        let index = MentionSuggestionIndex(files: [file("a.swift"), file("b.swift")])
        let results = index.suggestions(query: "", excluding: ["a.swift"])
        #expect(results.map(\.path) == ["b.swift"])
    }

    @Test func excludingIsPartOfTheMemoKey() {
        let index = MentionSuggestionIndex(files: [file("a.swift"), file("b.swift")])
        _ = index.suggestions(query: "", excluding: [])
        // Same query, new attachment: the memo must not serve the stale answer.
        #expect(index.suggestions(query: "", excluding: ["a.swift"]).map(\.path) == ["b.swift"])
    }

    @Test func memoRepeatsTheSameAnswer() {
        let index = MentionSuggestionIndex(files: [file("a.swift"), file("b.swift")])
        let first = index.suggestions(query: "s", excluding: [])
        let second = index.suggestions(query: "s", excluding: [])
        #expect(first.map(\.path) == second.map(\.path))
    }

    @Test func longIndexesAreTruncated() {
        let index = MentionSuggestionIndex(files: (0..<400).map { file("f\($0).swift") })
        #expect(index.suggestions(query: "", excluding: []).count == MentionSuggestionIndex.resultLimit)
    }
}

/// The composer's frame rules, which `noteComposerTextHeight` now uses to move
/// the dock's height in the same pass as the editor's.
@MainActor
struct ComposerEditorHeightTests {
    @Test func shortDraftsRestOnTheFloor() {
        #expect(ChatPane.composerEditorHeight(10) == ChatPane.composerEditorFloor)
    }

    @Test func longDraftsStopAtTheCap() {
        #expect(ChatPane.composerEditorHeight(4_000) == ChatPane.composerEditorCap)
    }

    @Test func betweenTheTwoTheMeasurementWins() {
        #expect(ChatPane.composerEditorHeight(120) == 120)
    }
}
