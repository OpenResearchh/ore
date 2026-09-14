import Foundation
import Testing
@testable import OreGit

struct ConflictMarkerTests {
    @Test func parsesOursAndTheirsBodies() {
        let text = """
        keep
        <<<<<<< HEAD
        ours line
        =======
        theirs line
        >>>>>>> incoming
        after
        """
        let hunks = ConflictMarkers.hunks(in: text)
        #expect(hunks.count == 1)
        #expect(hunks[0].ours == "ours line")
        #expect(hunks[0].theirs == "theirs line")
        #expect(hunks[0].oursLabel == "HEAD")
        #expect(hunks[0].theirsLabel == "incoming")
        #expect(hunks[0].startLine == 2)
    }

    @Test func resolvingAHunkLeavesTheRestOfTheFile() {
        let text = """
        a
        <<<<<<< HEAD
        ours
        =======
        theirs
        >>>>>>> branch
        b
        """
        let ours = ConflictMarkers.resolving(text, hunkStartingAt: 2, side: .ours)
        #expect(ours?.trimmingCharacters(in: .newlines) == "a\nours\nb")
        let theirs = ConflictMarkers.resolving(text, hunkStartingAt: 2, side: .theirs)
        #expect(theirs?.trimmingCharacters(in: .newlines) == "a\ntheirs\nb")
    }
}
