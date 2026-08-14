import Testing

@testable import OreProtocol

struct ResearchIdentityTests {
    @Test func catalogIsGloballyVariedAndHasCompleteDisplayContent() {
        #expect(ResearchIdentity.catalog.count >= 30)
        #expect(Set(ResearchIdentity.catalog.map(\.region)).count >= 20)
        #expect(ResearchIdentity.catalog.allSatisfy { !$0.fact.isEmpty && !$0.researchTitles.isEmpty })
        #expect(Set(ResearchIdentity.catalog.map(\.slug)).count == ResearchIdentity.catalog.count)
    }

    @Test func nextIdentityAvoidsNamesAndWorktreeSlugs() {
        let first = ResearchIdentity.catalog[0]
        let second = ResearchIdentity.catalog[1]
        let selected = ResearchIdentity.next(excluding: [first.name, second.slug])
        #expect(selected != first)
        #expect(selected != second)
    }

    @Test func researchAndTaskTitlesStayCollisionSafe() {
        let identity = ResearchIdentity.catalog[0]
        let firstTitle = identity.researchTitles[0]
        #expect(ResearchIdentity.nextResearchTitle(
            excluding: [firstTitle], preferred: identity
        ) == identity.researchTitles[1])
        #expect(ResearchIdentity.unique("Optics", excluding: ["optics"]) == "Optics · 2")
        #expect(ResearchIdentity.taskTitle(from: "Please help me implement an elegant file picker") == "Implement an elegant file picker")
    }

    @Test func aResearchTitleResolvesToItsOwnScientist() {
        let identity = ResearchIdentity.matching(researchTitle: "Moduli Spaces")
        #expect(identity?.name == "Maryam Mirzakhani")
    }
}
