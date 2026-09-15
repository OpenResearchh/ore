import Foundation
import OreProtocol
import Testing

@testable import OreMac

/// The Dreams inbox used to group itself inside the `List` builder, which
/// re-ran for every progress update of a running dream. The grouping now lives
/// in `DreamInboxSections` with a memo in front of it — so what the list draws
/// is worth pinning down, and so is the memo's promise to hand back the very
/// same value when nothing changed.
@MainActor
struct DreamInboxSectionsTests {
    private static let base = Date(timeIntervalSince1970: 1_750_000_000)

    private static func finding(
        _ id: String,
        repository: String = "ore",
        confidence: Double = 0.9,
        status: DreamFindingStatus = .new,
        createdAt: Date = base
    ) -> DreamFindingSummary {
        DreamFindingSummary(
            id: DreamFindingID(rawValue: id),
            runID: DreamRunID(rawValue: "run"),
            taskID: DreamTaskID(rawValue: "task"),
            repositoryPath: "/tmp/\(repository)",
            repositoryName: repository,
            kind: .bug,
            title: id,
            summary: "",
            confidence: confidence,
            severity: .warning,
            status: status,
            why: "",
            createdAt: createdAt
        )
    }

    @Test("Low-confidence findings are hidden only while they are new")
    func filtersOnlyNewLowConfidence() {
        let findings = [
            Self.finding("kept-high", confidence: 0.8),
            Self.finding("hidden-low", confidence: 0.2),
            // Already acted on: a decision the user made is not re-hidden
            // because ORE was unsure when it found it.
            Self.finding("kept-low-accepted", confidence: 0.2, status: .accepted),
        ]
        let hiding = DreamInboxSections(findings: findings, hideLowConfidence: true)
        #expect(hiding.visible.map(\.id.rawValue) == ["kept-high", "kept-low-accepted"])

        let showing = DreamInboxSections(findings: findings, hideLowConfidence: false)
        #expect(showing.visible.count == 3)
    }

    @Test("Days run newest first, projects A to Z, findings in inbox order")
    func ordersSections() {
        let older = Self.base.addingTimeInterval(-86_400)
        let findings = [
            Self.finding("today-zeta-1", repository: "zeta"),
            Self.finding("yesterday-ore", repository: "ore", createdAt: older),
            Self.finding("today-ore", repository: "ore"),
            Self.finding("today-zeta-2", repository: "zeta"),
        ]
        let sections = DreamInboxSections(findings: findings, hideLowConfidence: true)

        #expect(sections.days.count == 2)
        #expect(sections.days[0].start > sections.days[1].start)
        #expect(sections.days[0].projects.map(\.name) == ["ore", "zeta"])
        #expect(
            sections.days[0].projects[1].findings.map(\.id.rawValue)
                == ["today-zeta-1", "today-zeta-2"]
        )
        #expect(sections.days[1].projects.map(\.name) == ["ore"])
    }

    @Test("A finding at midnight stays on its own day")
    func groupsByStartOfDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let midnight = Date(timeIntervalSince1970: 1_750_032_000) // 2025-06-16 00:00 UTC
        let sections = DreamInboxSections(
            findings: [Self.finding("midnight", createdAt: midnight)],
            hideLowConfidence: true,
            calendar: calendar
        )
        #expect(sections.days.count == 1)
        #expect(sections.days[0].start == midnight)
    }

    @Test("The memo rebuilds only when the findings or the filter change")
    func memoSkipsUnchangedInput() {
        let memo = DreamInboxSections.Memo()
        let findings = [Self.finding("a"), Self.finding("b", repository: "zeta")]

        let first = memo.resolve(findings, hideLowConfidence: true)
        let again = memo.resolve(findings, hideLowConfidence: true)
        #expect(first == again)
        #expect(again.days.count == 1)

        // The filter is an input too, not just the findings.
        let unfiltered = memo.resolve(
            findings + [Self.finding("low", confidence: 0.1)],
            hideLowConfidence: false
        )
        #expect(unfiltered.visible.count == 3)
        #expect(unfiltered != first)
    }

    @Test("An empty inbox has no sections")
    func emptyInbox() {
        let sections = DreamInboxSections(findings: [], hideLowConfidence: true)
        #expect(sections.visible.isEmpty)
        #expect(sections.days.isEmpty)
        #expect(DreamInboxSections() == sections)
    }
}
