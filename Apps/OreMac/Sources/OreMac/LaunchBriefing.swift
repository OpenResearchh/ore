import OreProtocol
import SwiftUI

/// The launch greeting: what happened while the user was away, composed from
/// workspace summaries alone — no model call, so it is on screen (and speaking)
/// the moment the fleet snapshot lands.
///
/// Pure by design: `compose` is a function of (workspaces, lastSeenAt, now),
/// which is what makes the greeting testable and the spoken line identical to
/// the card.
struct LaunchBriefing: Equatable {
    struct Line: Equatable, Identifiable {
        var id: String
        var icon: String
        var text: String
        /// Attention lines tint warm; the rest stay quiet.
        var isAttention = false
    }

    var greeting: String
    var lines: [Line]
    /// The full sentence(s) the narration engine speaks — greeting included.
    var spoken: String

    /// How long the user must have been gone before the app speaks. The card
    /// always shows; a voice greeting after a 30-second relaunch is clingy.
    static let spokenAwayThreshold: TimeInterval = 10 * 60

    static func compose(
        workspaces: [WorkspaceSummary],
        lastSeenAt: Date?,
        now: Date = Date(),
        userName: String? = nil,
        dreamFindingCount: Int = 0
    ) -> LaunchBriefing {
        let greeting = greetingLine(now: now, userName: userName)
        let active = workspaces.filter { !$0.isArchived }

        // "Since you left" is the interesting cut when we know when that was;
        // otherwise the current state is the whole story.
        let sinceAway: (WorkspaceSummary) -> Bool = { workspace in
            guard let lastSeenAt else { return true }
            guard let activity = workspace.lastActivity else { return false }
            return activity > lastSeenAt
        }

        let needsYou = active.filter { $0.status == .awaitingInput || $0.status == .failed }
        let finished = active.filter {
            $0.hasUnread && $0.status == .idle && sinceAway($0)
        }
        let working = active.filter {
            switch $0.status {
            case .thinking, .requesting, .runningTool: true
            default: false
            }
        }
        let uncommitted = active.filter {
            $0.status == .idle && !$0.hasUnread && $0.gitStatus.hasUncommittedChanges
        }
        // Standing conflicts are exactly what an interjection can't tell you:
        // `FleetWatcher` only speaks a conflict that *appeared* while you were
        // watching, so one that was already there at launch has this line or
        // nothing. Attention, not alarm — the branch still needs a rebase.
        let conflicted = active.filter { $0.baseSync?.wouldConflict == true }

        var lines: [Line] = []
        if !needsYou.isEmpty {
            lines.append(Line(
                id: "needs-you",
                icon: "exclamationmark.circle",
                text: "\(names(of: needsYou)) \(needsYou.count == 1 ? "needs" : "need") your attention",
                isAttention: true
            ))
        }
        if !finished.isEmpty {
            lines.append(Line(
                id: "finished",
                icon: "checkmark.circle",
                text: "\(names(of: finished)) finished while you were away"
            ))
        }
        if !working.isEmpty {
            lines.append(Line(
                id: "working",
                icon: "circle.dotted",
                text: working.count == 1
                    ? "\(names(of: working)) is still working"
                    : "\(working.count) agents are still working"
            ))
        }
        if !uncommitted.isEmpty {
            lines.append(Line(
                id: "uncommitted",
                icon: "tray.and.arrow.down",
                text: uncommitted.count == 1
                    ? "\(names(of: uncommitted)) has changes ready to commit"
                    : "\(uncommitted.count) workspaces have changes ready to commit"
            ))
        }
        if !conflicted.isEmpty {
            lines.append(Line(
                id: "conflicted",
                icon: "arrow.triangle.branch",
                text: conflicted.count == 1
                    ? "\(names(of: conflicted)) conflicts with its base branch"
                    : "\(conflicted.count) workspaces conflict with their base branch",
                isAttention: true
            ))
        }
        if dreamFindingCount > 0 {
            lines.insert(Line(
                id: "dreams",
                icon: "moon.stars",
                text: dreamFindingCount == 1
                    ? "ORE dreamed last night — 1 finding to review"
                    : "ORE dreamed last night — \(dreamFindingCount) findings to review"
            ), at: 0)
        }
        if lines.isEmpty {
            lines.append(Line(
                id: "quiet",
                icon: "moon.zzz",
                text: active.isEmpty
                    ? "Ready when you are"
                    : "All quiet — \(active.count) workspace\(active.count == 1 ? "" : "s") ready"
            ))
        }

        let spoken = ([greeting] + lines.map { $0.text + "." }).joined(separator: " ")
        return LaunchBriefing(greeting: greeting, lines: lines, spoken: spoken)
    }

    /// Up to three names read naturally; beyond that the count carries it.
    private static func names(of workspaces: [WorkspaceSummary]) -> String {
        let names = workspaces.map(\.name)
        switch names.count {
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]), and \(names[2])"
        default: return "\(names[0]), \(names[1]), and \(names.count - 2) others"
        }
    }

    private static func greetingLine(now: Date, userName: String?) -> String {
        let hour = Calendar.current.component(.hour, from: now)
        let daypart = switch hour {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Working late"
        }
        guard let userName, !userName.isEmpty else { return "\(daypart)." }
        return "\(daypart), \(userName)."
    }

    /// First name only — "Good morning, Tushar", not a passport check.
    static func firstName(from fullName: String) -> String? {
        let first = fullName.split(separator: " ").first.map(String.init)
        return first?.isEmpty == false ? first : nil
    }
}

/// The greeting card: a quiet glass panel over the window that says hello,
/// lists what moved, and gets out of the way — any click or a few breaths
/// dismisses it.
struct LaunchBriefingOverlay: View {
    let briefing: LaunchBriefing
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // A whisper of a scrim so the card reads as "over" the app; any
            // click lands here and dismisses.
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: OreTheme.Space.md) {
                Text(briefing.greeting)
                    .font(.system(size: OreTheme.Font.display, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: OreTheme.Space.sm) {
                    ForEach(briefing.lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: OreTheme.Space.sm) {
                            Image(systemName: line.icon)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(
                                    line.isAttention ? OreTheme.Status.needsYou : Color.secondary
                                )
                                .frame(width: 18)
                            Text(line.text)
                                .font(.system(size: OreTheme.Font.prose))
                                .foregroundStyle(.primary)
                                // Wrap, never clip: "2 workspaces have chan…"
                                // was the line being cut instead of breaking.
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text("Click anywhere to continue")
                    .font(.system(size: OreTheme.Font.caption))
                    .foregroundStyle(.secondary)
            }
            .padding(OreTheme.Space.lg)
            .frame(minWidth: 340, maxWidth: 460, alignment: .leading)
            // A solid panel, not translucent material: the briefing sits over
            // an arbitrary transcript, and material let that noise bleed
            // through until the text itself went murky.
            .background(
                OreTheme.Surface.content,
                in: RoundedRectangle(cornerRadius: OreTheme.cardRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: OreTheme.cardRadius, style: .continuous)
                    .stroke(OreTheme.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            .onTapGesture(perform: onDismiss)
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
        .task {
            // Linger long enough to read, never long enough to nag.
            try? await Task.sleep(for: .seconds(12))
            onDismiss()
        }
    }
}
