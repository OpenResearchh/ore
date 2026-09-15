import Foundation
import SwiftUI
import Testing

@testable import OreMac

/// The composer status rows' clock used to restart from "now" on every parent
/// render and tick behind unfocused windows. It is anchored and pausable now.
@MainActor
struct StatusClockScheduleTests {
    private let anchor = Date(timeIntervalSinceReferenceDate: 1_000)

    private func firstEntries(
        _ schedule: StatusClockSchedule, from start: Date, count: Int = 3
    ) -> [Date] {
        Array(schedule.entries(from: start, mode: .normal).prefix(count))
    }

    /// Two renders a fraction of a second apart land on the same whole-second
    /// grid, so a redraw never shifts when the label next ticks.
    @Test func ticksOnWholeSecondsFromTheAnchor() {
        let schedule = StatusClockSchedule(anchor: anchor, paused: false)
        let start = anchor.addingTimeInterval(12.7)
        #expect(firstEntries(schedule, from: start) == [
            anchor.addingTimeInterval(12),
            anchor.addingTimeInterval(13),
            anchor.addingTimeInterval(14),
        ])
        let later = firstEntries(schedule, from: anchor.addingTimeInterval(12.2))
        #expect(later.first == anchor.addingTimeInterval(12))
    }

    /// The first entry is never after the start date, even before the anchor.
    @Test func firstEntryIsNotInTheFuture() {
        let schedule = StatusClockSchedule(anchor: anchor, paused: false)
        let start = anchor.addingTimeInterval(-3.5)
        let first = firstEntries(schedule, from: start, count: 1).first
        #expect(first.map { $0 <= start } == true)
    }

    /// An absent anchor still yields a usable clock.
    @Test func distantPastAnchorStillTicks() {
        let schedule = StatusClockSchedule(anchor: .distantPast, paused: false)
        let start = Date(timeIntervalSinceReferenceDate: 5_000.4)
        let entries = firstEntries(schedule, from: start)
        #expect(entries.count == 3)
        #expect(entries[0] <= start)
        #expect(entries[1].timeIntervalSince(entries[0]) == 1)
    }

    /// Paused, the timeline draws once and then has nothing left to schedule.
    @Test func pausedEmitsASingleEntry() {
        let schedule = StatusClockSchedule(anchor: anchor, paused: true)
        let start = anchor.addingTimeInterval(42.5)
        #expect(firstEntries(schedule, from: start, count: 5) == [start])
    }
}
