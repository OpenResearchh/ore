import Foundation
import OreProtocol

/// Ambient awareness of the fleet itself — the workspace-level changes worth a
/// sentence, and the order in which what's waiting should be visited.
///
/// Narration's fleet path (`NarrationEngine.observeFleet`) covers what *agents*
/// do in tabs the user isn't looking at. Nothing covered what happens to the
/// *workspaces*: a branch that starts conflicting with its base, a base that
/// ran away while an agent worked, a tab left blocked for ten minutes. Those
/// arrive as `workspaceUpdated` snapshots and as the passage of time, not as
/// `AgentEvent`s, so they had no voice at all.
///
/// Pure and value-typed for the same reason the rest of `Narration.swift` is:
/// the rules about what is worth saying — and how rarely — are the part worth
/// testing, and exercising them must not need a live core.

// MARK: - Milestones

/// One workspace-level thing that changed. Deliberately a short list: ambient
/// awareness earns its place by being rare, and every kind here is either
/// actionable or the retraction of something that was.
struct FleetMilestone: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Merging the base into this branch would now conflict.
        case conflicted(base: String)
        /// …and no longer would. Only ever emitted after a `conflicted`.
        case conflictCleared(base: String)
        /// The base moved far enough ahead that this branch is working against
        /// history it doesn't have.
        case fellBehind(commits: Int, base: String)
        /// A tab has been blocked on the user long enough that the interrupt
        /// which announced it has been forgotten.
        case stillBlocked(minutes: Int)
    }

    var workspaceID: WorkspaceID
    var name: String
    var kind: Kind

    /// The clause this contributes to a spoken line, already lowercased at the
    /// lead so it reads as part of a sentence rather than a headline.
    var spokenClause: String {
        switch kind {
        case .conflicted(let base):
            return "\(name) now conflicts with \(base)"
        case .conflictCleared(let base):
            return "\(name) no longer conflicts with \(base)"
        case .fellBehind(let commits, let base):
            return "\(name) is \(NarrationPhraser.spokenCount(commits)) commits behind \(base)"
        case .stillBlocked(let minutes):
            return "\(name) has been waiting on you for "
                + "\(NarrationPhraser.spokenCount(minutes)) minutes"
        }
    }

    /// The same fact written for the assistant's watch digest, where it is one
    /// line of evidence rather than something spoken.
    var writtenLine: String {
        switch kind {
        case .conflicted(let base):
            return "\(name): the branch now conflicts with \(base)"
        case .conflictCleared(let base):
            return "\(name): the conflict with \(base) is resolved"
        case .fellBehind(let commits, let base):
            return "\(name): fell \(commits) commits behind \(base)"
        case .stillBlocked(let minutes):
            return "\(name): still blocked on the user after \(minutes) minutes"
        }
    }
}

/// Pacing for the fleet's own voice, kept beside `NarrationPolicy` in spirit.
enum FleetAwarenessPolicy {
    /// A base this far ahead is worth mentioning. Below it, every push to the
    /// default branch would be an interjection.
    static let behindBaseThreshold = 10
    /// …and it isn't mentioned again until the workspace has caught back up to
    /// here, so a branch hovering at the threshold announces once, not nightly.
    static let behindBaseRearm = 2
    /// How long a tab sits blocked before ORE mentions it a second time. The
    /// arrival already spoke as an interrupt; this is for the user who walked
    /// away between the two.
    static let blockedReminder: TimeInterval = 10 * 60
    /// Milestones buffer this long so a burst — a fetch landing across eight
    /// worktrees at once — becomes one sentence instead of eight.
    static let digestWindow: TimeInterval = 20
    /// …and the fleet never speaks milestones more often than this, whatever
    /// is happening. Anything that backs up rides the next line.
    static let digestGap: TimeInterval = 150
    /// The most clauses one spoken line carries; beyond it the count carries.
    static let maxSpokenClauses = 3
    /// How many milestones can wait behind the gap before the oldest are
    /// dropped. A fleet churning for an hour should not deliver an hour's
    /// backlog the moment the gap opens.
    static let pendingLimit = 8
}

// MARK: - Watcher

/// Diffs workspace snapshots into milestones and rations them into one spoken
/// line at a time.
///
/// The first snapshot of a workspace only records state. At launch every
/// workspace is new, and announcing the standing conflicts of a fleet that sat
/// there all night is the launch briefing's job — an interjection is for what
/// changed while the user was watching.
struct FleetWatcher: Sendable, Equatable {
    /// A tab currently blocked on the user, as the watcher needs to see it.
    struct BlockedTab: Equatable, Sendable {
        var id: String
        var workspaceID: WorkspaceID
        var name: String
    }

    private struct Signal: Equatable {
        var conflicts = false
        /// Whether `fellBehind` has already been spoken for the current drift.
        var behindAnnounced = false
    }

    private struct Blocked: Equatable {
        var workspaceID: WorkspaceID
        var name: String
        var since: Date
        var reminded = false
    }

    private var signals: [WorkspaceID: Signal] = [:]
    private var blocked: [String: Blocked] = [:]
    private var pending: [FleetMilestone] = []
    /// How many milestones fell off the back of `pending`. Kept rather than
    /// forgotten so the spoken line's "and four others" stays true: a cap that
    /// silently shrinks the count reports a calm fleet during the one hour it
    /// was busiest.
    private var overflow = 0
    private var firstPendingAt: Date?
    private var lastSpokeAt = Date.distantPast

    var hasPendingMilestones: Bool { !pending.isEmpty }

    // MARK: Intake

    /// Records a workspace's state and returns whatever changed meaningfully
    /// since the last time it was seen. Archived workspaces and the assistant's
    /// own workspace are not part of the fleet the user is watching.
    @discardableResult
    mutating func observe(_ workspace: WorkspaceSummary, now: Date = Date()) -> [FleetMilestone] {
        guard !workspace.isArchived, !workspace.isAssistant else {
            signals.removeValue(forKey: workspace.id)
            return []
        }
        let conflicts = workspace.baseSync?.wouldConflict ?? false
        let behind = workspace.baseSync?.workspaceBehindOrigin ?? 0
        let base = workspace.baseSync?.defaultBranch ?? workspace.baseBranch

        guard var signal = signals[workspace.id] else {
            // First sight: record, say nothing.
            signals[workspace.id] = Signal(
                conflicts: conflicts,
                behindAnnounced: behind >= FleetAwarenessPolicy.behindBaseThreshold
            )
            return []
        }

        var milestones: [FleetMilestone] = []
        if conflicts != signal.conflicts {
            signal.conflicts = conflicts
            milestones.append(FleetMilestone(
                workspaceID: workspace.id,
                name: workspace.name,
                kind: conflicts ? .conflicted(base: base) : .conflictCleared(base: base)
            ))
        }
        if !signal.behindAnnounced, behind >= FleetAwarenessPolicy.behindBaseThreshold {
            signal.behindAnnounced = true
            milestones.append(FleetMilestone(
                workspaceID: workspace.id,
                name: workspace.name,
                kind: .fellBehind(commits: behind, base: base)
            ))
        } else if signal.behindAnnounced, behind <= FleetAwarenessPolicy.behindBaseRearm {
            // Rebased or merged: arm the next announcement, quietly.
            signal.behindAnnounced = false
        }
        signals[workspace.id] = signal
        buffer(milestones, now: now)
        return milestones
    }

    /// Brings the blocked-tab set in line with what is actually waiting, and
    /// reminds about anything that has been waiting too long.
    ///
    /// One call for both halves on purpose: a tab that was resolved while the
    /// user was in another app must be forgotten before it can earn a reminder,
    /// and splitting that into two entry points is how it would drift.
    @discardableResult
    mutating func reconcileBlocked(_ tabs: [BlockedTab], now: Date) -> [FleetMilestone] {
        let live = Set(tabs.map(\.id))
        blocked = blocked.filter { live.contains($0.key) }
        for tab in tabs where blocked[tab.id] == nil {
            blocked[tab.id] = Blocked(workspaceID: tab.workspaceID, name: tab.name, since: now)
        }

        var milestones: [FleetMilestone] = []
        // One reminder per workspace, not per request: an agent blocked on three
        // permissions in a row is one thing waiting, said once.
        var reminded = Set<WorkspaceID>()
        for id in blocked.keys.sorted() {
            guard var item = blocked[id], !item.reminded,
                  now.timeIntervalSince(item.since) >= FleetAwarenessPolicy.blockedReminder
            else { continue }
            item.reminded = true
            blocked[id] = item
            guard reminded.insert(item.workspaceID).inserted else { continue }
            milestones.append(FleetMilestone(
                workspaceID: item.workspaceID,
                name: item.name,
                kind: .stillBlocked(
                    minutes: Int(now.timeIntervalSince(item.since) / 60)
                )
            ))
        }
        buffer(milestones, now: now)
        return milestones
    }

    /// The chat is gone; so is anything the watcher remembered about it.
    mutating func forget(_ workspaceID: WorkspaceID) {
        signals.removeValue(forKey: workspaceID)
        blocked = blocked.filter { $0.value.workspaceID != workspaceID }
        pending.removeAll { $0.workspaceID == workspaceID }
        if pending.isEmpty { firstPendingAt = nil }
    }

    // MARK: Output

    /// The one sentence the fleet has earned, or nil.
    ///
    /// Two gates, both deliberate: a burst is allowed to settle before it is
    /// phrased (`digestWindow`), and the fleet never speaks more often than
    /// `digestGap` however much is happening. What waits is not lost — it rides
    /// the next line, up to `pendingLimit`.
    mutating func flush(now: Date) -> String? {
        guard let firstPendingAt, !pending.isEmpty else { return nil }
        guard now.timeIntervalSince(firstPendingAt) >= FleetAwarenessPolicy.digestWindow,
              now.timeIntervalSince(lastSpokeAt) >= FleetAwarenessPolicy.digestGap
        else { return nil }
        let batch = pending
        let dropped = overflow
        pending = []
        overflow = 0
        self.firstPendingAt = nil
        lastSpokeAt = now
        return FleetMilestonePhraser.line(for: batch, plus: dropped)
    }

    /// Throws away what is queued without speaking it — for when fleet
    /// awareness is switched off while a batch is waiting on the gap.
    mutating func discardPending() {
        pending = []
        overflow = 0
        firstPendingAt = nil
    }

    private mutating func buffer(_ milestones: [FleetMilestone], now: Date) {
        guard !milestones.isEmpty else { return }
        if pending.isEmpty { firstPendingAt = now }
        for milestone in milestones {
            // A workspace's newest state is the only one worth saying: a branch
            // that conflicted and then didn't, while the gap was closed, has
            // nothing to report.
            pending.removeAll { $0.workspaceID == milestone.workspaceID }
            pending.append(milestone)
        }
        if pending.count > FleetAwarenessPolicy.pendingLimit {
            let excess = pending.count - FleetAwarenessPolicy.pendingLimit
            pending.removeFirst(excess)
            overflow += excess
        }
        if pending.isEmpty { firstPendingAt = nil }
    }
}

// MARK: - Phrasing

enum FleetMilestonePhraser {
    /// Reads a batch as one sentence. Past the clause cap the count carries the
    /// rest: "and two other workspaces moved" is information; a list of six
    /// workspace names spoken aloud is not. `plus` is what the watcher already
    /// dropped, so the count covers everything that happened rather than
    /// everything still in hand.
    static func line(for milestones: [FleetMilestone], plus dropped: Int = 0) -> String? {
        guard !milestones.isEmpty else { return nil }
        let clauses = milestones.map(\.spokenClause)
        let shown = clauses.prefix(FleetAwarenessPolicy.maxSpokenClauses)
        let hidden = clauses.count - shown.count + dropped

        var sentence: String
        switch shown.count {
        case 1:
            sentence = shown[0]
        default:
            sentence = shown.dropLast().joined(separator: ", ") + ", and " + (shown.last ?? "")
        }
        if hidden > 0 {
            sentence += ", and \(NarrationPhraser.spokenCount(hidden)) other "
                + (hidden == 1 ? "workspace" : "workspaces") + " moved"
        }
        return NarrationPhraser.sanitize(
            "Heads up — " + sentence + "."
        )
    }
}

// MARK: - Needs-you navigation

/// The order ⌘⇧U walks: everything in the fleet that is actually waiting on
/// the user, so answering the next one never requires finding it first.
///
/// Blocked tabs come before failed turns because they are holding an agent
/// still, and within them the oldest ask leads — it is the one that has been
/// waiting. Pure so the cycle, including its wrap-around, is testable without
/// a window.
enum NeedsYouCycle {
    struct Stop: Equatable, Sendable {
        var workspaceID: WorkspaceID
        /// nil when the workspace needs attention but no particular tab does —
        /// a failed turn selects the workspace and leaves the tab alone.
        var chatID: ChatID?
    }

    /// `needsYou` is expected in arrival order, oldest first — which is how
    /// `AppModel.tabNeedsYou` maintains it.
    static func stops(
        needsYou: [TabNeedsYou],
        workspaces: [WorkspaceSummary]
    ) -> [Stop] {
        var stops: [Stop] = []
        var seen = Set<String>()
        for item in needsYou {
            let stop = Stop(workspaceID: item.workspaceID, chatID: item.chatID)
            guard seen.insert(item.chatID.rawValue).inserted else { continue }
            stops.append(stop)
        }
        let blockedWorkspaces = Set(needsYou.map(\.workspaceID))
        for workspace in workspaces
        where !workspace.isArchived
            && !blockedWorkspaces.contains(workspace.id)
            && (workspace.status == .failed || workspace.status == .awaitingInput) {
            stops.append(Stop(workspaceID: workspace.id, chatID: nil))
        }
        return stops
    }

    /// The stop after `current`, wrapping around. A `current` that is no longer
    /// waiting — answered, or archived — starts the walk from the top rather
    /// than ending it.
    static func next(after current: Stop?, in stops: [Stop]) -> Stop? {
        guard !stops.isEmpty else { return nil }
        guard let current, let index = stops.firstIndex(of: current) else { return stops[0] }
        return stops[(index + 1) % stops.count]
    }
}
