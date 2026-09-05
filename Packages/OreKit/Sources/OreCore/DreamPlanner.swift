import Foundation
import OreProtocol

/// Deterministic agenda: pick the single best (repo × kind) pair the night's
/// budget can afford. No model call — "why this dream ran" is these terms.
public enum DreamPlanner {
    public struct Candidate: Sendable, Equatable {
        public var repositoryPath: String
        public var repositoryName: String
        public var kind: DreamKind
        public var score: Double
        public var why: String
    }

    public static func plan(
        activity: [DreamRepositoryActivity],
        excludedRepoPaths: [String],
        now: Date = Date(),
        kinds: [DreamKind] = DreamKind.allCases.filter(\.isMVP),
        acceptance: [DreamKindAcceptance] = []
    ) -> Candidate? {
        let excluded = Set(excludedRepoPaths)
        let rates = Dictionary(
            uniqueKeysWithValues: acceptance.map {
                ("\($0.repositoryPath)|\($0.kind.rawValue)", $0.rate)
            }
        )
        let scored = activity.compactMap { row -> Candidate? in
            guard !excluded.contains(row.repositoryPath) else { return nil }
            let kind = preferredKind(
                for: row,
                now: now,
                kinds: kinds,
                acceptanceRate: { rates["\(row.repositoryPath)|\($0.rawValue)"] ?? 0.5 }
            )
            let rate = rates["\(row.repositoryPath)|\(kind.rawValue)"] ?? 0.5
            let (score, why) = score(row, kind: kind, now: now, acceptanceRate: rate)
            guard score > 0 else { return nil }
            return Candidate(
                repositoryPath: row.repositoryPath,
                repositoryName: row.repositoryName,
                kind: kind,
                score: score,
                why: why
            )
        }
        return scored.max(by: { $0.score < $1.score })
    }

    /// Stale pinned repos get an audit; recently active ones get a review or
    /// bug hunt. Quiet unpinned repos still get a periodic look so neglected
    /// projects are not invisible. Kinds the user keeps rejecting fall through.
    public static func preferredKind(
        for activity: DreamRepositoryActivity,
        now: Date,
        kinds: [DreamKind],
        acceptanceRate: (DreamKind) -> Double = { _ in 0.5 }
    ) -> DreamKind {
        let idleDays = activity.lastTurnAt.map { now.timeIntervalSince($0) / 86_400 } ?? 30
        func usable(_ kind: DreamKind) -> Bool {
            kinds.contains(kind) && acceptanceRate(kind) >= DreamRetention.noisyKindRate
        }
        if activity.isPinned, idleDays >= 7, usable(.dependencyAudit) {
            return .dependencyAudit
        }
        if activity.turnCount >= 8, usable(.bugHunt) {
            return .bugHunt
        }
        if activity.turnCount >= 2, idleDays >= 3, activity.turnCount < 8, usable(.featureIdeas) {
            return .featureIdeas
        }
        if usable(.review) { return .review }
        return kinds.first { usable($0) } ?? kinds.first ?? .review
    }

    public static func score(
        _ activity: DreamRepositoryActivity,
        kind: DreamKind,
        now: Date,
        acceptanceRate: Double = 0.5
    ) -> (Double, String) {
        let idleDays = activity.lastTurnAt.map { now.timeIntervalSince($0) / 86_400 } ?? 30
        let recency = 1.0 / (1.0 + idleDays / 7.0)
        let activityScore = min(1.0, Double(activity.turnCount) / 20.0) * recency
        let staleness = activity.isPinned ? min(1.0, idleDays / 14.0) * 0.6 : min(0.3, idleDays / 30.0)
        let kindWeight: Double = switch kind {
        case .review: 1.0
        case .bugHunt: 0.9
        case .dependencyAudit: 0.8
        case .featureIdeas: 0.7
        default: 0.5
        }
        let rate = min(1, max(0, acceptanceRate))
        let score = max(0.05, (activityScore + staleness) * kindWeight * (0.35 + 0.65 * rate))
        var terms: [String] = []
        if activity.turnCount > 0 {
            terms.append("\(activity.turnCount) turns in 14 days")
        } else {
            terms.append("no recent turns")
        }
        if idleDays >= 7 {
            terms.append(String(format: "idle %.0f days", idleDays))
        }
        if activity.isPinned { terms.append("pinned") }
        if rate < 0.45 {
            terms.append(String(format: "low acceptance %.0f%%", rate * 100))
        }
        terms.append(kind.displayName.lowercased())
        return (score, terms.joined(separator: " · "))
    }

    /// Start of the current dream-day: `quietHoursStart` today, or yesterday
    /// if we have not reached that clock time yet. Ledger spend since this
    /// instant is the night cap, including a daytime "Dream now".
    public static func nightWindowStart(
        now: Date,
        quietHoursStartMinutes: Int,
        calendar: Calendar = .current
    ) -> Date {
        let minutes = max(0, min(24 * 60 - 1, quietHoursStartMinutes))
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = minutes / 60
        components.minute = minutes % 60
        components.second = 0
        let startToday = calendar.date(from: components) ?? now
        if now >= startToday { return startToday }
        return calendar.date(byAdding: .day, value: -1, to: startToday) ?? startToday
    }

    public static func remainingTokenBudget(effectiveCap: Int, spent: Int) -> Int {
        max(0, effectiveCap - max(0, spent))
    }

    public static func isInQuietHours(
        _ date: Date,
        startMinutes: Int,
        endMinutes: Int,
        calendar: Calendar = .current
    ) -> Bool {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let minutes = hour * 60 + minute
        if startMinutes == endMinutes { return true }
        if startMinutes < endMinutes {
            return minutes >= startMinutes && minutes < endMinutes
        }
        return minutes >= startMinutes || minutes < endMinutes
    }

    public static func isIdle(
        environment: DreamEnvironmentSnapshot,
        idleMinutes: Int
    ) -> Bool {
        let threshold = TimeInterval(max(1, idleMinutes) * 60)
        let inputIdle = environment.secondsSinceInput >= threshold
        let oreIdle = environment.lastSeenAt.map {
            environment.now.timeIntervalSince($0) >= threshold
        } ?? true
        return inputIdle && oreIdle
    }

    public static func isExcludedRepository(_ path: String, excludedRepoPaths: [String]) -> Bool {
        excludedRepoPaths.contains(path)
    }
}
