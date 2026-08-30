import OreProtocol
import SwiftUI

/// The presence strip's hover card: per-harness limits and spend, in the
/// spirit of CodexBar — limit windows with reset countdowns where the CLI
/// reported them, session tokens and estimated cost from what ORE itself has
/// metered. Honest about its sources: harnesses only report limits while a
/// turn runs, so a quiet harness simply shows what's known.
struct HarnessUsagePopover: View {
    let snapshots: [AppModel.HarnessUsageSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.md) {
            if snapshots.isEmpty {
                Label(
                    "No usage yet — this fills in once an agent runs.",
                    systemImage: "gauge.with.dots.needle.bottom.50percent"
                )
                .font(.system(size: OreTheme.Font.body))
                .foregroundStyle(.secondary)
            }

            ForEach(snapshots) { snapshot in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        HarnessMark(harness: snapshot.harness, size: 16)
                        Text(snapshot.harness.displayName)
                            .font(.system(size: OreTheme.Font.body, weight: .semibold))
                        Spacer()
                        limitBadge(snapshot.rateLimit)
                    }

                    if let limit = snapshot.rateLimit, let line = Self.limitLine(limit) {
                        row("Limit", line)
                    }
                    row("Session tokens", Self.tokenText(snapshot.totalTokens))
                    if let cost = snapshot.costUSD {
                        row("Est. cost", String(format: "$%.2f", cost))
                    }
                    if let title = snapshot.topContextTitle,
                       let fraction = snapshot.topContextFraction {
                        row("Context", "\(Int(fraction * 100))% · \(title)")
                    }
                }
            }

            Text("Windows and resets come from the agent CLIs, reported while turns run. Costs appear for API-key sessions only.")
                .font(.system(size: OreTheme.Font.caption))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(OreTheme.Space.md)
        .frame(width: 300, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: OreTheme.Font.caption))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: OreTheme.Font.caption).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func limitBadge(_ limit: RateLimitReport?) -> some View {
        let (text, color): (String, Color) = switch limit?.status {
        case .exhausted: ("Exhausted", OreTheme.Status.failed)
        case .warning: ("Near limit", OreTheme.Status.needsYou)
        case .allowed: ("OK", OreTheme.Presence.active)
        case .unknown, nil: ("No limits reported", Color.secondary)
        }
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    /// "weekly window · resets in 2h 53m" — the CodexBar sentence, from what
    /// the harness actually said.
    static func limitLine(_ limit: RateLimitReport, now: Date = Date()) -> String? {
        var parts: [String] = []
        if let window = limit.window, !window.isEmpty {
            parts.append("\(window) window")
        }
        if let resetsAt = limit.resetsAt, resetsAt > now {
            parts.append("resets in \(Self.compactETA(to: resetsAt, from: now))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "2h 53m", "5d 4h", "40m" — countdowns readable at a glance.
    static func compactETA(to date: Date, from now: Date = Date()) -> String {
        let minutes = max(1, Int(date.timeIntervalSince(now) / 60))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest > 0 ? "\(hours)h \(rest)m" : "\(hours)h"
        }
        let days = hours / 24
        let restHours = hours % 24
        return restHours > 0 ? "\(days)d \(restHours)h" : "\(days)d"
    }

    /// 85_400_000 → "85.4M"; 1_234 → "1.2K"; 861 → "861".
    static func tokenText(_ tokens: Int) -> String {
        let value = Double(tokens)
        switch tokens {
        case 1_000_000...:
            return String(format: "%.1fM", value / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", value / 1_000)
        default:
            return "\(tokens)"
        }
    }
}
