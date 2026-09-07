import Foundation

/// Version arithmetic for agent CLIs.
///
/// Every harness prints its version differently — `2.1.154 (Claude Code)`,
/// `codex-cli 0.148.0`, `2026.09.02-c22c1a3` — and the upstream channel that
/// says what's *available* prints a bare version. Both sides go through
/// `normalize` before they are compared, so the comparison is between two
/// version numbers rather than between two pieces of CLI copy.
public enum HarnessVersion {
    /// Pulls the version out of a `--version` line, or nil when there isn't one.
    ///
    /// Takes the first whitespace-separated token that starts with a digit and
    /// carries a dot: that skips the CLI's own name (`codex-cli`) and stops
    /// before the trailing product name (`(Claude Code)`).
    public static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        for line in raw.split(whereSeparator: \.isNewline) {
            for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "vV()[]{},;:'\"`"))
                guard let first = trimmed.first, first.isNumber, trimmed.contains(".") else { continue }
                return trimmed
            }
        }
        return nil
    }

    /// True when `candidate` is a strictly higher version than `current`.
    ///
    /// Compares dotted components numerically and tolerates differing component
    /// counts (`1.2` vs `1.2.0`). A trailing build identifier — Cursor ships
    /// `2026.09.02-c22c1a3` — contributes only its leading digits, so two builds
    /// stamped the same day never read as an upgrade. That is deliberate: an
    /// unorderable difference is not evidence of a newer release, and guessing
    /// wrong here means a card the user can never dismiss for good.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = components(candidate)
        let rhs = components(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}

/// What ORE knows about one harness CLI's upgrade situation.
///
/// Distinct from `HarnessProbeResult`: the probe asks the local binary what it
/// is, this asks the channel that installed it what it *could* be. Kept
/// separate because the probe is cheap and local while this one costs a network
/// round trip, and a failed network call must never make an installed harness
/// look broken.
public struct HarnessUpdateStatus: Sendable, Codable, Hashable, Identifiable {
    public var kind: HarnessKind
    /// Normalized version of the binary on PATH.
    public var installedVersion: String?
    /// Normalized version the install channel is currently publishing.
    public var latestVersion: String?
    /// The shell command an upgrade would run, so the card can say how it will
    /// upgrade and the user can run it themselves instead.
    public var updateCommand: String?
    public var checkedAt: Date
    /// Set when the check could not complete — offline, an unknown channel, a
    /// registry that moved. Never a reason to hide the harness.
    public var failure: String?

    public var id: HarnessKind { kind }

    public var isUpdateAvailable: Bool {
        guard let installedVersion, let latestVersion else { return false }
        return HarnessVersion.isNewer(latestVersion, than: installedVersion)
    }

    public init(
        kind: HarnessKind,
        installedVersion: String? = nil,
        latestVersion: String? = nil,
        updateCommand: String? = nil,
        checkedAt: Date = Date(),
        failure: String? = nil
    ) {
        self.kind = kind
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.updateCommand = updateCommand
        self.checkedAt = checkedAt
        self.failure = failure
    }
}
