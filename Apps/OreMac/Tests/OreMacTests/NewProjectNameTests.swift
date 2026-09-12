import Foundation
import Testing

@testable import OreMac

/// Naming a project the user never named. It becomes a directory they will see
/// in Finder and type in a shell, so short, lowercase and unsurprising.
struct NewProjectNameTests {
    /// An empty creation root, so a name is only "taken" when a test says so
    /// rather than because of what happens to be in the developer's `~/ore`.
    private func emptyRoot() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ore-names-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func from(_ goal: String, avoiding existing: [String] = [], root: URL? = nil) -> String {
        NewProjectName.from(goal, avoiding: existing, root: root ?? emptyRoot())
    }

    @Test func theNameComesOutOfWhatTheThingIs() {
        #expect(NewProjectName.slug(from: "Build a pricing page for the marketing site")
            == "pricing-page-marketing-site")
    }

    /// "Build a" describes the act, not the thing.
    @Test func leadInWordsAreDropped() {
        #expect(NewProjectName.slug(from: "Create a new todo app") == "todo")
        #expect(NewProjectName.slug(from: "I want to build a habit tracker") == "habit-tracker")
    }

    @Test func punctuationAndCaseAreFlattened() {
        let slug = NewProjectName.slug(from: "Ship the CLI — fast!")
        #expect(slug == slug.lowercased())
        #expect(!slug.contains(" "))
        #expect(!slug.contains("—"))
        #expect(!slug.contains("!"))
    }

    @Test func theNameStaysShort() {
        let slug = NewProjectName.slug(from: (0..<40).map { "word\($0)" }.joined(separator: " "))
        #expect(slug.split(separator: "-").count <= NewProjectName.maxWords)
    }

    /// An instruction with nothing nameable in it still has to produce a
    /// directory name.
    @Test func anUnnameableGoalFallsBack() {
        #expect(NewProjectName.slug(from: "build me a new app") == NewProjectName.fallback)
        #expect(NewProjectName.slug(from: "!!!") == NewProjectName.fallback)
        #expect(NewProjectName.slug(from: "") == NewProjectName.fallback)
    }

    // MARK: - Not writing into somebody else's project

    @Test func aNameAlreadyTakenIsNumbered() {
        #expect(from("build a pricing page", avoiding: ["/Users/x/code/pricing-page"])
            == "pricing-page-2")
    }

    @Test func numberingContinuesPastTheSecond() {
        let taken = ["/Users/x/code/pricing-page", "/Users/x/code/pricing-page-2"]
        #expect(from("build a pricing page", avoiding: taken) == "pricing-page-3")
    }

    @Test func aFreeNameIsLeftAlone() {
        #expect(from("build a pricing page", avoiding: ["/Users/x/code/ore"]) == "pricing-page")
    }

    /// Directory names differing only in case would still collide on a
    /// case-insensitive volume, which is the macOS default.
    @Test func collisionIsCaseInsensitive() {
        #expect(from("build a Pricing Page", avoiding: ["/Users/x/PRICING-PAGE"])
            == "pricing-page-2")
    }

    /// A folder somebody made by hand is not registered with ORE, and the
    /// core refuses to create into a non-empty directory. Checking only the
    /// registered projects turned that into a failed Start.
    @Test func aFolderNobodyRegisteredStillCounts() throws {
        let root = emptyRoot()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("pricing-page"), withIntermediateDirectories: true
        )
        #expect(from("build a pricing page", root: root) == "pricing-page-2")
    }

    /// The comparison has to be on the directory the core will make, not on
    /// the name as typed: `Pricing Page` and `pricing-page` are one folder.
    @Test func collisionIsCheckedOnTheDirectoryTheCoreWillCreate() throws {
        let root = emptyRoot()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("pricing-page"), withIntermediateDirectories: true
        )
        #expect(from("Pricing Page!", root: root) == "pricing-page-2")
    }

    // MARK: - Goals that are not in English

    /// The core's slugger keeps ASCII and nothing else, so every Chinese
    /// goal used to become a directory called `workspace` — and the second
    /// one failed to create at all.
    @Test func aGoalWithNoASCIIInItGetsANameItCanKeep() {
        #expect(NewProjectName.slug(from: "构建一个定价页面") == NewProjectName.fallback)
        #expect(NewProjectName.slug(from: "сделать страницу цен") == NewProjectName.fallback)
        #expect(NewProjectName.slug(from: "أنشئ صفحة التسعير") == NewProjectName.fallback)
    }

    @Test func twoGoalsInTheSameScriptGetDifferentDirectories() {
        let root = emptyRoot()
        let first = from("构建一个定价页面", root: root)
        let second = from("构建一个定价页面", avoiding: ["/Users/x/code/\(first)"], root: root)
        #expect(first == NewProjectName.fallback)
        #expect(second != first)
    }

    /// Handing back a name already known to be taken makes the core refuse
    /// the whole creation. Anything unique beats that.
    @Test func exhaustingTheNumbersStillYieldsAFreeName() {
        let taken = (["pricing-page"] + (2...99).map { "pricing-page-\($0)" })
            .map { "/Users/x/code/\($0)" }
        let name = from("build a pricing page", avoiding: taken)
        #expect(!taken.contains { ($0 as NSString).lastPathComponent == name })
        #expect(name.hasPrefix("pricing-page-"))
    }
}
