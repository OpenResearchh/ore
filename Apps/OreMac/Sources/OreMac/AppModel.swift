import AppKit
import Foundation
import LocalAuthentication
import Observation
import OreCore
import OreGit
import OrePersistence
import OreProtocol
import OreSupport
import OreTelemetry
import UserNotifications

/// Turns the review annotations collected beside a diff into plan-decision
/// feedback. A plan replaces the ordinary composer while it awaits a decision,
/// so these comments have to travel with Approve or Reject rather than waiting
/// for a later message that may never be sent.
enum PlanDecisionFeedback {
    static func combining(
        _ feedback: String,
        comments: [DiffCommentReference]
    ) -> String {
        var sections: [String] = []
        let note = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { sections.append(note) }
        guard !comments.isEmpty else { return sections.joined(separator: "\n\n") }

        sections.append("Review comments on the current diff:")
        for comment in comments {
            let location = comment.startLine == comment.endLine
                ? "\(comment.filePath):\(comment.startLine)"
                : "\(comment.filePath):\(comment.startLine)-\(comment.endLine)"
            var section = "**\(location)**\n\(comment.body)"
            if let context = comment.context, !context.isEmpty {
                section += "\n\n```\n\(context)\n```"
            }
            sections.append(section)
        }
        return sections.joined(separator: "\n\n")
    }
}

/// The app's view state.
///
/// One `@Observable` object holding what every surface reads. It is the only
/// thing in the app that talks to the core: views send commands through it and
/// read state from it, so there is exactly one place where the boundary is
/// crossed and exactly one ordering of updates.
@MainActor
@Observable
final class AppModel {
    static let automaticRoutinePermissionsKey = "ore.permissions.autoRoutine"
    /// Whether ORE answers routine shell and read requests on the user's
    /// behalf before they have said anything about it.
    ///
    /// Off. Reading the key with `object(forKey:) as? Bool != false` used to
    /// make it on for everyone who had never chosen, which is not a default —
    /// it's an unnoticed one. Running commands without asking is the kind of
    /// thing a person opts into, so a fresh install asks, and Settings →
    /// Agents explains what turning it on covers. `registerDefaults()` makes
    /// this the registered value so every read can be a plain typed `bool`,
    /// including a stored value of the wrong type.
    static let automaticRoutinePermissionsDefault = false

    /// Registered before any surface reads a preference, so "never chosen"
    /// and "chosen false" resolve to the same behaviour everywhere.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            automaticRoutinePermissionsKey: automaticRoutinePermissionsDefault,
        ])
    }
    private(set) var workspaces: [WorkspaceSummary] = [] {
        didSet { recomputeSortedWorkspaces() }
    }
    /// Sidebar order, stored rather than computed: views read it many times a
    /// render, and it only moves when `workspaces` does. See
    /// `recomputeSortedWorkspaces` for the ordering.
    private(set) var sortedWorkspaces: [WorkspaceSummary] = []

    // Fleet-wide answers, stored and reassigned only when they actually move.
    // As computed properties each read subscribed a view to the whole
    // `workspaces` array (or every workspace's chat list), so any agent's
    // status flip re-ran the sidebar, the app's menu commands, and RootView
    // mid-scroll even when the answer they showed was the same.

    /// The workspace on screen. A lookup into `workspaces` from a view made
    /// that view depend on every workspace; this changes only with the
    /// selection or the selected workspace's own summary.
    private(set) var selectedWorkspace: WorkspaceSummary?
    private(set) var archivedWorkspaces: [WorkspaceSummary] = []
    /// Workspaces needing attention plus new dream findings — the dock badge.
    private(set) var attentionCount = 0
    private(set) var hasNeedsYouStops = false
    /// Unarchived workspaces doing something or waiting on the person — the
    /// sidebar's Active tab. See `SidebarFleetActivity`.
    private(set) var activeWorkspaceIDs: Set<WorkspaceID> = []
    /// How many unarchived workspaces have an agent working right now.
    private(set) var workingCount = 0
    /// The first nine workspaces in the order the sidebar is *showing*, while
    /// it holds its order still under the pointer; nil when it shows the live
    /// order. ⌘1–9 reads this so a shortcut always lands on the row whose
    /// badge it matches. Only read by actions, so not observed.
    @ObservationIgnored
    var sidebarShortcutOrder: [WorkspaceID]?
    /// The product-owned assistant workspace, routed out of `workspaces` at
    /// event intake. This is the single point that keeps it off the sidebar,
    /// out of ⌘1–9, and away from every picker — the Assistant window is the
    /// only surface that reads it.
    private(set) var assistantWorkspace: WorkspaceSummary?
    /// Hidden overnight-research worktrees. The Dreams window is the only
    /// surface that should mention them.
    private(set) var dreamWorkspaces: [WorkspaceSummary] = []
    private(set) var dreamInbox = DreamInboxSnapshot() {
        didSet { recomputeAttentionCount() }
    }
    private(set) var dreamSleepStatus: DreamSleepStatus = .disabled
    @ObservationIgnored
    private var dreamMonitor: DreamEnvironmentMonitor?
    /// Pending "may the assistant do this?" questions, newest last. Rendered
    /// as cards in the Assistant window; the core times them out (denying)
    /// after two minutes.
    private(set) var assistantConfirmations: [AssistantConfirmation] = []
    /// Project tabs blocked on a permission or question, for the HUD / menu bar
    /// when the user is in another app.
    private(set) var tabNeedsYou: [TabNeedsYou] = [] {
        didSet { recomputeNeedsYouStops() }
    }
    private(set) var harnesses: [HarnessProbeResult] = []
    /// Whether the probe has reported at least once. Distinct from
    /// `harnesses.isEmpty`: "we have not looked yet" and "we looked and found
    /// nothing" call for opposite behaviour in onboarding, and conflating
    /// them makes the welcome screen tell people to install an agent they
    /// already have for the first half-second of every launch.
    private(set) var hasProbedHarnesses = false
    /// What each installed agent CLI's install channel is publishing, from the
    /// last check. Drives the update card and the Agents settings pane.
    private(set) var harnessUpdates: [HarnessUpdateStatus] = []
    private(set) var modelCatalog: [HarnessKind: [AgentModel]] = [:]
    private(set) var repositories: [String] = []
    private(set) var isLoaded = false

    /// Repository paths in most-recently-worked order, for inferring which
    /// project a new instruction is about. The sidebar already sorts projects
    /// this way; this is the same reading, as data rather than layout.
    var recentRepositories: [String] {
        var seen = Set<String>()
        return workspaces
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            .compactMap { seen.insert($0.repositoryPath).inserted ? $0.repositoryPath : nil }
    }

    /// The project the user is looking at. The strongest signal there is:
    /// people ask for work in the thing already on screen.
    var currentRepositoryPath: String? {
        workspaces.first { $0.id == selectedWorkspaceID }?.repositoryPath
    }

    var selectedWorkspaceID: WorkspaceID? {
        didSet {
            recomputeSelectedWorkspace()
            guard selectedWorkspaceID != oldValue else { return }
            focusChanged(from: oldValue, to: selectedWorkspaceID)
        }
    }

    private(set) var chatSummaries: [ChatSummary] = []
    /// `chatSummaries` grouped by workspace and kept sorted, so `chats(for:)`
    /// is a lookup. Updated alongside every write to `chatSummaries`.
    @ObservationIgnored
    let chatIndex = ChatIndex()
    /// Live transcript state is keyed by durable chat identity, never by
    /// workspace: several tabs in one worktree can stream concurrently.
    private(set) var chatStates: [ChatID: ChatState] = [:]
    private(set) var workspaceAutoApprovals: [WorkspaceID: WorkspaceAutoApproval] = [:]
    /// Git dirt lives off the `workspaces` array so a file write does not
    /// invalidate every chrome view that read the fleet list.
    @ObservationIgnored
    let workspaceLive = WorkspaceLiveRegistry()
    private(set) var activeChatIDs: [WorkspaceID: ChatID] = [:]
    /// Files opened as diff tabs in the centre column, per workspace, and which
    /// one is showing. When `activeFilePath[workspace]` is nil the centre shows
    /// the active chat; when it's set, it shows that file's diff instead. This
    /// is what lets the review list (on the right) open a diff as a centre tab.
    private(set) var openFilePaths: [WorkspaceID: [String]] = [:]
    private(set) var activeFilePath: [WorkspaceID: String] = [:]
    private(set) var filePresentationModes: [WorkspaceID: [String: FilePresentationMode]] = [:]
    private(set) var banners: [Banner] = []

    /// Cached workspace diffs so switching back to a worktree — or opening the
    /// review pane right after selecting one — paints instantly instead of
    /// waiting on a cold `git diff`. Keyed by workspace and stamped with the
    /// git-status generation it was computed against, so a stale entry is shown
    /// immediately while a fresh one loads in the background.
    struct DiffSnapshot: Equatable {
        var generation: UInt64
        var diffs: [FileDiff]
        var gitAction: SuggestedGitAction
        var pullRequest: GitHubClient.PullRequest?
    }
    /// One observable per workspace, like `workspaceLive`: a refresh in one
    /// worktree used to rewrite a shared dictionary and invalidate every
    /// reader of every workspace's diff.
    @ObservationIgnored
    let diffCache = WorkspaceDiffRegistry()
    @ObservationIgnored
    private var diffPrefetches = RefreshGate<WorkspaceID>()
    /// A trailing refresh waits this long, so a burst of file writes costs one
    /// more `git diff` rather than one per write.
    private static let diffPrefetchDebounce: Duration = .milliseconds(1500)
    @ObservationIgnored
    private var didWarmWorkspaces = false
    @ObservationIgnored
    private var historyLoadsInFlight: Set<ChatID> = []

    /// Speaks agent activity aloud for tabs whose speaker toggle is on.
    let narration = NarrationEngine()
    /// Hold-⇧⌥-anywhere voice mode: speech in, narrated assistant replies out.
    let voiceAssistant = VoiceAssistantController()

    private let client: InProcessCoreClient
    private var eventTask: Task<Void, Never>?
    // Pure bookkeeping below is `@ObservationIgnored`: no view reads it, and
    // several are written on every agent event, which would otherwise count
    // as a change to the whole model.
    /// Batches streaming deltas so a fast model can't drive the transcript's
    /// layout at the rate the tokens arrive.
    @ObservationIgnored
    private var coalescers: [ChatID: TextDeltaCoalescer] = [:]
    @ObservationIgnored
    private var chatOwners: [ChatID: WorkspaceID] = [:]
    @ObservationIgnored
    private var pendingNewChatMessages: [WorkspaceID: [String]] = [:]
    /// Draft text to drop into a chat that hasn't been published yet, so Commit
    /// / Create PR can open a tab without sending until the user hits return.
    @ObservationIgnored
    private var pendingNewChatDrafts: [WorkspaceID: [String]] = [:]
    /// The Review button's next chat claims incoming PostDiffComment findings.
    @ObservationIgnored
    private var pendingReviewCommentInbox: Set<WorkspaceID> = []
    /// Workspace → the tab whose composer owns Review-posted comments. Observed,
    /// because tab strips label the Review tab from it; only written when the
    /// inbox actually moves.
    private var reviewCommentInbox: [WorkspaceID: ChatID] = [:]
    /// The same mapping as read back from `UserDefaults`, cached apart from the
    /// observed one so the getter that views call never writes observed state.
    @ObservationIgnored
    private var storedReviewInbox: [WorkspaceID: ChatID?] = [:]
    /// Comments the user dismissed from a tab. Kept so the Review poll cannot
    /// put them back while the store delete is still in flight.
    @ObservationIgnored
    private var dismissedCommentKeys: [ChatID: Set<String>] = [:]
    /// Signals the visible composer to pick up a draft written from outside
    /// (toolbar Commit / Create PR) without waiting for a tab switch.
    private(set) var composerInjection: ComposerInjection?

    struct ComposerInjection: Equatable {
        let chatID: ChatID
        let text: String
        let generation: UInt64
    }
    private var composerInjectionGeneration: UInt64 = 0
    private var identityRenamesInFlight: Set<WorkspaceID> = []
    private var chatRenamesInFlight: Set<ChatID> = []
    private(set) var chatCreationsInFlight: Set<WorkspaceID> = []
    /// Continue / Create PR / Merge while a git command is in flight, so the
    /// toolbar can show a spinner instead of looking idle.
    enum GitOperation: Hashable {
        case continueAfterMerge
        case createPullRequest
        case merge
        case pullDefaultBranch
    }
    private(set) var gitOpsInFlight: [WorkspaceID: GitOperation] = [:]
    private var flushTask: Task<Void, Never>?
    /// Composer text waiting to be written back, keyed by chat. See `setDraft`.
    @ObservationIgnored
    private var pendingDrafts: [ChatID: (workspaceID: WorkspaceID, text: String)] = [:]
    private var draftFlushTask: Task<Void, Never>?

    struct Banner: Identifiable, Sendable {
        let id = UUID()
        var message: String
        var detail: String?
    }

    /// Anonymous usage analytics. Defaults to the no-op so every existing
    /// test construction keeps compiling untouched, and so any code path that
    /// forgets to pass one stays silent rather than reporting by accident.
    let telemetry: any TelemetryRecorder
    private var translator = TelemetryTranslator()

    init(client: InProcessCoreClient, telemetry: any TelemetryRecorder = NoopTelemetry()) {
        self.client = client
        self.telemetry = telemetry
    }

    // MARK: - Lifecycle

    /// The one live model, for entry points that exist outside the SwiftUI
    /// scene tree — App Intents (Siri, Shortcuts, Spotlight) chief among them.
    private(set) static weak var shared: AppModel?

    static func running() -> AppModel? { shared }

    private var started = false
    private(set) var isBackgroundPollingEnabled = true

    func start() {
        // Idempotent: called from app init (so intents and the menu bar work
        // before any window exists) and again from the window's task.
        guard !started else { return }
        started = true
        updateBackgroundPolling()
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateBackgroundPolling() }
            }
        }
        AppModel.shared = self
        voiceAssistant.model = self
        // The pill follows tabNeedsYou + the voice phase from here on, so a
        // blocked tab is answerable from any app, not only from ORE's window.
        AssistantVoiceHUD.shared.bind(model: self)
        // Direct callback, not a SwiftUI onChange: hold-to-talk must survive
        // every window being closed — the menu bar presence is enough.
        VoiceHotkeyMonitor.shared.onCommand = { [weak self] command in
            self?.voiceAssistant.handle(command)
        }
        VoiceHotkeyMonitor.shared.isAssistantEngaged = { [weak self] in
            self?.voiceAssistant.phase != .idle
        }
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in await self.client.events {
                await self.apply(event)
            }
        }
        Task {
            do {
                try await client.start()
            } catch {
                // Swallowed by `try?` before this. A core that never started
                // spawns no harness probe, so the welcome screen sat on an
                // `.unknown` ladder forever with nothing on it — the failure
                // that caused it was the one thing not on screen.
                banners.append(Banner(
                    message: "ORE couldn't finish starting up: \(error.localizedDescription)",
                    detail: nil
                ))
            }
            await refreshRepositories()
            isLoaded = true
            // A beat for the fleet snapshot to land, then say hello.
            try? await Task.sleep(for: .milliseconds(800))
            prepareLaunchBriefing()
        }
        restoreScheduledContinuations()
        startFleetAwareness()
        startDreamMode()
        NotificationCenter.default.addObserver(
            forName: .oreOpenFromNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let workspace = notification.userInfo?["workspaceID"] as? String
            let chat = notification.userInfo?["chatID"] as? String
            let openDreams = notification.userInfo?["openDreams"] as? String == "1"
            Task { @MainActor in
                self?.openFromNotification(
                    workspaceID: workspace,
                    chatID: chat,
                    openDreams: openDreams
                )
            }
        }
        NotificationCenter.default.addObserver(
            forName: .oreNotificationAction,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Everything we post is string-valued; narrowing here makes the
            // payload Sendable for the actor hop.
            let info = (notification.userInfo as? [String: String]) ?? [:]
            Task { @MainActor in
                self?.handleNotificationAction(info)
            }
        }
    }

    private func updateBackgroundPolling() {
        // `start()` runs from the App's init, before NSApplication exists; a
        // launching app isn't hidden, and the hide/unhide observers take over.
        let enabled = !(NSApp?.isHidden ?? false)
        isBackgroundPollingEnabled = enabled
        Task { [weak self] in
            guard let self else { return }
            await client.setBackgroundPollingEnabled(enabled)
            guard enabled, isBackgroundPollingEnabled, let workspace = selectedWorkspace else { return }
            prefetchDiff(for: workspace)
            await refreshGitAction(for: workspace.id)
        }
    }

    /// Flushes coalesced deltas at ~40Hz, but only while something is pending.
    ///
    /// The transcript is the app's hottest surface, and every delta that
    /// reaches it costs a layout pass. Batching at a fixed cadence decouples
    /// rendering cost from token rate. A timer that ran forever still woke the
    /// main actor 40 times a second while the app sat idle.
    @ObservationIgnored
    private var lastBackgroundFlush: [ChatID: ContinuousClock.Instant] = [:]

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(25))
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flushCoalescedDeltas()
            if self.coalescers.values.contains(where: \.hasPendingDeltas) {
                self.scheduleFlush()
            }
        }
    }

    private func flushCoalescedDeltas() {
        let now = ContinuousClock.now
        for chatID in Array(coalescers.keys) {
            guard var coalescer = coalescers[chatID], coalescer.hasPendingDeltas else { continue }
            guard let workspaceID = chatOwners[chatID] else { continue }
            if !isVisibleTranscript(workspaceID: workspaceID, chatID: chatID) {
                if let last = lastBackgroundFlush[chatID], now - last < .milliseconds(250) {
                    continue
                }
                lastBackgroundFlush[chatID] = now
            }
            for event in coalescer.flush() {
                applyToChat(workspaceID: workspaceID, chatID: chatID, event: event)
            }
            coalescers[chatID] = coalescer
        }
    }

    private func isVisibleTranscript(workspaceID: WorkspaceID, chatID: ChatID) -> Bool {
        selectedWorkspaceID == workspaceID
            && activeChatIDs[workspaceID] == chatID
            && activeFilePath[workspaceID] == nil
    }

    func shutdown() async {
        // Where "while you were away" starts counting from next launch.
        UserDefaults.standard.set(
            Date().timeIntervalSince1970, forKey: Self.lastSeenKey
        )
        // Last chance to get an unsent draft to disk, and it has to complete
        // before the core below us shuts down.
        await flushPendingDraftsAwaitingWrites()
        await flushTelemetryBriefly()
        eventTask?.cancel()
        flushTask?.cancel()
        fleetTickTask?.cancel()
        dreamMonitor?.stop()
        dreamMonitor = nil
        for task in continuationTasks.values { task.cancel() }
        continuationTasks.removeAll()
        await client.shutdown()
    }

    /// One attempt to send this session's events on the way out, capped so
    /// a slow network never holds up the quit. Whatever misses it stays
    /// queued on disk and goes with the next launch's first delivery.
    ///
    /// Raced rather than grouped: a task group waits for every child, and a
    /// URL request does not stop for cancellation, so a group would wait out
    /// the full request timeout anyway.
    private func flushTelemetryBriefly() async {
        let telemetry = telemetry
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let gate = TerminationGate { done.resume() }
            Task { @MainActor in
                await telemetry.flush()
                gate.reply()
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                gate.reply()
            }
        }
    }

    // MARK: - Harness usage

    /// What one harness is costing right now, aggregated across a workspace's
    /// open chats — the presence strip's hover card: limit windows with reset
    /// countdowns where the harness reported them, tokens and estimated
    /// spend where it didn't.
    struct HarnessUsageSnapshot: Identifiable {
        var harness: HarnessKind
        var rateLimit: RateLimitReport?
        var totalTokens: Int
        var costUSD: Double?
        /// The fullest context among this harness's chats: (tab title, 0…1).
        var topContextTitle: String?
        var topContextFraction: Double?
        var id: String { harness.rawValue }
    }

    func harnessUsage(in workspaceID: WorkspaceID) -> [HarnessUsageSnapshot] {
        let open = chats(for: workspaceID).filter { !isEphemeralChat($0.id) }
        var snapshots: [HarnessUsageSnapshot] = []
        for harness in HarnessKind.allCases {
            let members = open.filter { $0.harness == harness }
            guard !members.isEmpty else { continue }
            var tokens = 0
            var cost: Double?
            var topTitle: String?
            var topFraction = 0.0
            var limit: RateLimitReport?
            for chat in members {
                if let usage = chat.contextUsage {
                    tokens += usage.totalContextTokens
                    if let chatCost = usage.costUSD { cost = (cost ?? 0) + chatCost }
                    if let window = usage.contextWindow, window > 0 {
                        let fraction = Double(usage.totalContextTokens) / Double(window)
                        if fraction > topFraction {
                            topFraction = fraction
                            topTitle = chat.title
                        }
                    }
                }
                // Loaded states only: forcing a ChatState into existence for a
                // hover would drag full history loads behind a tooltip.
                if let report = chatStates[chat.id]?.rateLimit {
                    if report.applies() {
                        limit = report
                    } else if limit == nil {
                        limit = report
                    }
                }
            }
            snapshots.append(HarnessUsageSnapshot(
                harness: harness,
                rateLimit: limit,
                totalTokens: tokens,
                costUSD: cost,
                topContextTitle: topTitle,
                topContextFraction: topTitle == nil ? nil : topFraction
            ))
        }
        return snapshots
    }

    // MARK: - Launch briefing

    static let lastSeenKey = "ore.lastSeenAt"
    static let greetingEnabledKey = "ore.greeting.enabled"
    static let greetingVoiceKey = "ore.greeting.voice"

    /// The greeting card waiting to be shown, if this launch earned one.
    private(set) var launchBriefing: LaunchBriefing?

    /// Composes the "while you were away" card from the fleet snapshot and,
    /// when the user has actually been gone a while, speaks it through the
    /// narration engine. Called once per launch after the snapshot lands.
    func prepareLaunchBriefing() {
        guard launchBriefing == nil else { return }
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.greetingEnabledKey) as? Bool ?? true else { return }
        // Nothing to brief on, and a brand-new user is the worst audience for
        // one: ORE spoke a greeting aloud and dimmed the next-step card behind
        // the briefing overlay seconds into a first launch, on top of the
        // notification permission dialog. Returning *before* the `lastSeenKey`
        // write below is deliberate — stamping "seen" now would make the first
        // real briefing measure its absence from a moment there was nothing to
        // be absent from.
        guard !sortedWorkspaces.isEmpty else { return }

        let lastSeen = defaults.double(forKey: Self.lastSeenKey)
        let lastSeenAt = lastSeen > 0 ? Date(timeIntervalSince1970: lastSeen) : nil
        let briefing = LaunchBriefing.compose(
            workspaces: sortedWorkspaces,
            lastSeenAt: lastSeenAt,
            userName: LaunchBriefing.firstName(from: NSFullUserName()),
            dreamFindingCount: dreamInbox.newFindingCount
        )
        launchBriefing = briefing

        // Speak only when there was a real absence: a voice greeting on every
        // quick relaunch is clingy, and the master narration switch always
        // wins. Milestone priority — it defers to anything urgent.
        let awayLongEnough = Self.isLongAbsence(lastSeenAt: lastSeenAt)
        let voiceWanted = defaults.object(forKey: Self.greetingVoiceKey) as? Bool ?? true
        if awayLongEnough, voiceWanted, narration.isMasterEnabled {
            narration.speakAssistant(
                briefing.spoken,
                chatID: ChatID(rawValue: "launch-briefing"),
                priority: .milestone,
                // The greeting is a composed reply, not an ambient interjection
                // — the 280-character ambient cap would clip it mid-sentence.
                limit: NarrationPolicy.assistantAnswerLimit,
                kind: .turnCompleted
            )
        }

        // The delta is delivered; a relaunch five minutes from now should not
        // replay it.
        defaults.set(Date().timeIntervalSince1970, forKey: Self.lastSeenKey)
    }

    /// Whether the gap since the last launch is long enough to be worth
    /// speaking aloud.
    ///
    /// A machine that has never recorded a `lastSeenAt` used to answer `true`
    /// here, so "we have no idea" was treated as the longest absence there is —
    /// the one case that always speaks. That is exactly backwards on the launch
    /// where it matters: a restored `~/ore` gives a first run a non-empty fleet
    /// and no timestamp, and ORE talks to somebody who has never used it.
    nonisolated static func isLongAbsence(lastSeenAt: Date?, now: Date = Date()) -> Bool {
        guard let lastSeenAt else { return false }
        return now.timeIntervalSince(lastSeenAt) > LaunchBriefing.spokenAwayThreshold
    }

    func dismissLaunchBriefing() {
        launchBriefing = nil
    }

    // MARK: - Reading

    /// The assistant's current conversation, once the snapshot has arrived.
    var assistantChatID: ChatID? {
        guard let assistant = assistantWorkspace else { return nil }
        return activeChat(for: assistant.id)?.id
            ?? chatSummaries.last { $0.workspaceID == assistant.id }?.id
    }

    func resolveAssistantConfirmation(
        _ id: String,
        decision: AssistantConfirmationDecision
    ) {
        // "Always" is the one answer that outlives this moment — a standing
        // permission deserves the user's fingerprint, from every surface
        // (window, menu bar, voice). Failing or cancelling authentication
        // degrades to allowing once: the user plainly wanted the action, only
        // the permanence went unproven.
        if case .allow(.always) = decision {
            assistantConfirmations.removeAll { $0.id == id }
            Task { @MainActor in
                let proven = await Self.authenticateStandingGrant()
                await client.send(.resolveAssistantConfirmation(
                    id, .allow(proven ? .always : .once)
                ))
                if !proven, let chatID = assistantChatID {
                    narration.speakAssistant(
                        "I allowed it once — the standing permission needs Touch ID.",
                        chatID: chatID
                    )
                }
            }
            return
        }
        assistantConfirmations.removeAll { $0.id == id }
        Task { await client.send(.resolveAssistantConfirmation(id, decision)) }
    }

    /// Biometrics or the login password — whichever the Mac has. A machine
    /// with neither (or a denied prompt) simply doesn't mint standing grants.
    private static func authenticateStandingGrant(
        reason: String = "let the ORE assistant always perform this kind of action"
    ) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        return (try? await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason
        )) ?? false
    }

    /// The assistant's action audit, newest first, for the Actions tab.
    func assistantAuditActions() async -> [AssistantActionRecord] {
        (try? await client.assistantActions()) ?? []
    }

    func assistantAlwaysGrantNames() async throws -> [String] {
        try await client.assistantAlwaysGrants()
    }

    func assistantTabGrantIDs() async throws -> [ChatID] {
        try await client.assistantTabGrantIDs()
    }

    // MARK: - Ask (App Intents / Siri / Spotlight)

    private var assistantReplyWaiters: [UUID: CheckedContinuation<String, Never>] = [:]
    /// Which conversation the question went to, captured at send time. The
    /// active one can change while the answer is being written — a compaction,
    /// or the user switching conversations — and the reply belongs to the
    /// conversation that was asked.
    private var askAssistantChatID: ChatID?

    /// Sends a request to the assistant and waits for its answer — the
    /// synchronous shape Siri, Shortcuts, and Spotlight need. The reply is
    /// the turn's narration line, which for the assistant is the answer itself.
    func askAssistant(_ text: String, timeout: Duration = .seconds(90)) async -> String {
        guard assistantWorkspace != nil else {
            return "ORE is still starting up — try again in a moment."
        }
        guard let assistant = assistantWorkspace else {
            return "The assistant isn't available."
        }
        askAssistantChatID = send(text, to: assistant.id)
        let token = UUID()
        return await withCheckedContinuation { continuation in
            assistantReplyWaiters[token] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.assistantReplyWaiters.removeValue(forKey: token)?.resume(
                    returning: "Still working on it — the full answer will be in ORE's Assistant window."
                )
            }
        }
    }

    private func flushAssistantReplyWaiters(with reply: String) {
        let waiters = assistantReplyWaiters
        assistantReplyWaiters = [:]
        for continuation in waiters.values { continuation.resume(returning: reply) }
    }

    // MARK: - Proactive watch

    /// Events across the fleet, buffered for the assistant's judgment. The
    /// assistant — not a rule engine — decides what deserves the user's
    /// attention, judging against `memory/watch.md`, which it updates the
    /// moment the user says what to surface or mute.
    private var watchBuffer: [String] = []
    private var watchFlushTask: Task<Void, Never>?
    private var lastWatchDigestAt: Date = .distantPast
    /// The conversation the outstanding digest is being judged in, or nil when
    /// none is. Doubles as the "one at a time" gate the bool used to be.
    private var watchDigestChatID: ChatID?
    var assistantRateLimitHandled = false

    /// Coalesce a burst of activity into one digest…
    private static let watchDebounce: Duration = .seconds(30)
    /// …and never brief more often than this, whatever is happening.
    private static let watchMinimumGap: TimeInterval = 150

    private var proactiveWatchEnabled: Bool {
        UserDefaults.standard.object(forKey: "ore.assistant.proactive") as? Bool ?? true
    }

    private func collectWatchEvent(
        _ event: AgentEvent,
        workspaceID: WorkspaceID,
        chatID: ChatID
    ) {
        // Most events are deltas and tool calls that never make a line; decide
        // that before paying for any lookups.
        switch event {
        case .turnCompleted, .question, .sessionError: break
        default: return
        }
        guard proactiveWatchEnabled, assistantWorkspace != nil else { return }
        if dreamWorkspaces.contains(where: { $0.id == workspaceID }) { return }
        let place = "\(workspaceName(workspaceID))"
            + (chatIndex.summary(for: chatID).map { " / \($0.title)" } ?? "")

        let line: String?
        switch event {
        case .turnCompleted(let result):
            switch result.outcome {
            case .completed:
                let note = NarrationPhraser.spokenNarration(result.narration)
                    ?? result.summary.map { String($0.prefix(160)) }
                line = "\(place): finished a turn" + (note.map { " — \($0)" } ?? "")
            case .failed:
                line = "\(place): the turn FAILED"
                    + (result.summary.map { " — \(String($0.prefix(160)))" } ?? "")
            case .awaitingInput:
                line = "\(place): stopped, waiting for the user's input"
            case .interrupted:
                line = nil
            }
        case .question(let question):
            line = "\(place): asks the user — \(String(question.prompt.prefix(160)))"
        case .sessionError(let error):
            line = "\(place): session error — \(String(error.message.prefix(160)))"
        default:
            line = nil
        }
        guard let line else { return }
        watchBuffer.append(line)
        scheduleWatchFlush()
    }

    private func scheduleWatchFlush() {
        guard watchFlushTask == nil else { return }
        watchFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.watchDebounce)
            guard let self, !Task.isCancelled else { return }
            self.watchFlushTask = nil
            self.flushWatchDigest()
        }
    }

    private func flushWatchDigest() {
        guard proactiveWatchEnabled,
              let assistant = assistantWorkspace,
              !watchBuffer.isEmpty
        else {
            watchBuffer.removeAll()
            return
        }
        // One digest at a time, and never at a chattier cadence than the gap —
        // whatever backed up simply rides the next digest.
        guard watchDigestChatID == nil,
              Date().timeIntervalSince(lastWatchDigestAt) >= Self.watchMinimumGap
        else {
            scheduleWatchFlush()
            return
        }
        let lines = watchBuffer.suffix(12)
        watchBuffer.removeAll()
        lastWatchDigestAt = Date()
        watchDigestChatID = send(
            """
            [ORE watch] Cross-workspace events since the last digest:
            \(lines.map { "- \($0)" }.joined(separator: "\n"))

            Judge these against memory/watch.md. Reply with exactly SKIP if \
            none of it deserves interrupting the user; otherwise reply with \
            one or two spoken-style sentences (they will be spoken aloud and \
            shown as a notification). Take no actions.
            """,
            // Not `.user`: a digest is ORE talking to the assistant on a timer,
            // and counting it as conversation would have the assistant
            // compacting itself overnight with nobody at the keyboard.
            origin: .watch,
            to: assistant.id
        )
    }

    /// The assistant judged a digest. SKIP means the fleet's activity wasn't
    /// worth the user's attention; anything else is worth a voice and a banner.
    /// SKIP is detected in the reply body — the narration tag is a separate
    /// line the model appends to every turn, and would mask the verdict.
    private func deliverWatchVerdict(_ result: TurnResult) {
        guard result.outcome == .completed else { return }
        let body = (result.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if body.uppercased().hasPrefix("SKIP") { return }
        guard let verdict = NarrationPhraser.spokenNarration(result.narration)
            ?? (body.isEmpty ? nil : String(body.prefix(200)))
        else { return }

        postNotification(title: "ORE Assistant", body: verdict)
        // Proactive speech honors the master narration switch — unlike voice
        // replies, the user didn't just ask for this out loud.
        if narration.isMasterEnabled, let chatID = assistantChatID {
            narration.speakAssistant(verdict, chatID: chatID)
        }
    }

    // MARK: - Fleet awareness

    /// What the fleet's workspaces — not their agents — have been doing. See
    /// `FleetAwareness.swift`; everything interesting lives there, and this
    /// side is only the wiring that feeds it snapshots and a clock.
    private var fleetWatcher = FleetWatcher()
    private var fleetTickTask: Task<Void, Never>?
    /// The pseudo-chat the fleet's own line is spoken under, so its queue slot
    /// replaces the previous fleet line rather than any real tab's narration.
    private static let fleetMilestoneChatID = ChatID(rawValue: "fleet-milestones")

    /// A coarse cadence on purpose: the two things this drives — a burst
    /// settling, and a tab having waited ten minutes — are both measured in
    /// minutes, and neither is worth a per-second wake-up.
    private static let fleetTick: Duration = .seconds(30)

    private func startFleetAwareness() {
        guard fleetTickTask == nil else { return }
        fleetTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Nothing here is second-accurate, so let the system batch this
                // wake-up with others instead of waking the CPU just for it.
                try? await Task.sleep(for: Self.fleetTick, tolerance: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                self.tickFleetAwareness()
            }
        }
    }

    private func tickFleetAwareness() {
        let now = Date()
        let waiting = tabNeedsYou.map {
            FleetWatcher.BlockedTab(
                id: $0.id,
                workspaceID: $0.workspaceID,
                name: workspaceName($0.workspaceID)
            )
        }
        record(fleetMilestones: fleetWatcher.reconcileBlocked(waiting, now: now))
        // Switched off mid-batch: drop what was waiting on the gap rather than
        // hold it until the toggle comes back on and it speaks as history.
        guard isFleetAwarenessEnabled else {
            fleetWatcher.discardPending()
            return
        }
        guard let line = fleetWatcher.flush(now: now) else { return }
        narration.speakAssistant(
            line,
            chatID: Self.fleetMilestoneChatID,
            priority: .milestone,
            kind: .fleetMilestone
        )
    }

    /// The fleet's voice rides the same switches its agent-event half does:
    /// there is one "tell me about the rest of the fleet" idea, and one toggle.
    private var isFleetAwarenessEnabled: Bool {
        narration.isMasterEnabled && narration.isFleetEnabled
    }

    private func noteFleetChange(_ summary: WorkspaceSummary) {
        record(fleetMilestones: fleetWatcher.observe(summary))
    }

    /// Milestones reach the assistant's watch buffer whether or not they will
    /// ever be spoken: judging what the fleet is doing is the assistant's job,
    /// and the narration toggle governs ORE's voice, not the assistant's eyes.
    ///
    /// The proactive guard comes first, as it does in `collectWatchEvent` —
    /// buffering for a digest that will never be scheduled is how the buffer
    /// grows for the whole session.
    private func record(fleetMilestones: [FleetMilestone]) {
        guard proactiveWatchEnabled, assistantWorkspace != nil else { return }
        guard !fleetMilestones.isEmpty else { return }
        for milestone in fleetMilestones { watchBuffer.append(milestone.writtenLine) }
        scheduleWatchFlush()
    }

    // MARK: - Next needs you

    /// Where ⌘⇧U left off, so repeated presses walk the fleet instead of
    /// bouncing between the same two.
    private var lastNeedsYouStop: NeedsYouCycle.Stop?

    private var needsYouStops: [NeedsYouCycle.Stop] {
        NeedsYouCycle.stops(needsYou: tabNeedsYou, workspaces: sortedWorkspaces)
    }

    /// Kept current from `tabNeedsYou` and `sortedWorkspaces`, the two inputs
    /// to `needsYouStops`; the ⇧⌘U menu item reads it.
    private func recomputeNeedsYouStops() {
        let next = !needsYouStops.isEmpty
        if next != hasNeedsYouStops { hasNeedsYouStops = next }
    }

    /// Jumps to the next thing waiting on the user, anywhere in the fleet.
    /// Returns false when nothing is — the caller keeps the menu item disabled,
    /// but a stale disabled state must not silently move the window.
    @discardableResult
    func focusNextNeedsYou() -> Bool {
        guard let stop = NeedsYouCycle.next(after: lastNeedsYouStop, in: needsYouStops) else {
            return false
        }
        lastNeedsYouStop = stop
        selectedWorkspaceID = stop.workspaceID
        if let chatID = stop.chatID { selectChat(chatID, in: stop.workspaceID) }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    var selectedChat: ChatState? {
        selectedChatSummary.map { chat(for: $0.id) }
    }

    var selectedChatSummary: ChatSummary? {
        guard let workspaceID = selectedWorkspaceID else { return nil }
        return activeChat(for: workspaceID)
    }

    func gitChrome(for id: WorkspaceID) -> GitStatusSummary {
        workspaceLive.state(for: id).gitStatus
    }

    func gitGeneration(for id: WorkspaceID) -> UInt64 {
        workspaceLive.state(for: id).gitGeneration
    }

    func chats(for workspaceID: WorkspaceID, includeClosed: Bool = false) -> [ChatSummary] {
        chatIndex.chats(for: workspaceID, includeClosed: includeClosed)
    }

    func activeChat(for workspaceID: WorkspaceID) -> ChatSummary? {
        let open = chats(for: workspaceID)
        if let id = activeChatIDs[workspaceID], let chat = open.first(where: { $0.id == id }) {
            return chat
        }
        return defaultChat(among: open, in: workspaceID)
    }

    /// Where a workspace lands with no remembered choice. Tabs open on their
    /// first; the assistant opens on its newest, because its conversations are
    /// a succession rather than parallel tabs — the oldest is the one most
    /// likely retired, and landing there routed every fleet digest into it.
    private func defaultChat(among open: [ChatSummary], in workspaceID: WorkspaceID) -> ChatSummary? {
        workspaceID == assistantWorkspace?.id ? open.last : open.first
    }

    func chat(for id: ChatID) -> ChatState {
        if let existing = chatStates[id] { return existing }
        let state = makeChatState(for: id)
        Task { await loadHistory(for: id) }
        return state
    }

    /// Creates a chat's state without starting its history load, for callers
    /// that await the load themselves. State is released when a chat closes,
    /// so this is also the path a reopened chat comes back through.
    private func makeChatState(for id: ChatID) -> ChatState {
        let state = ChatState()
        state.draftAttachments = Self.loadDraftAttachments(for: id)
        state.replaceDraftComments(Self.loadDraftComments(for: id))
        // `upsertChat` only reconciles states that already exist.
        if let summary = chatIndex.summary(for: id) {
            state.reconcileTurnActive(summary.isTurnActive)
        }
        chatStates[id] = state
        return state
    }

    func chat(for workspaceID: WorkspaceID) -> ChatState {
        guard let id = activeChat(for: workspaceID)?.id else { return ChatState() }
        return chat(for: id)
    }

    /// Rebuilds a workspace's transcript from storage.
    ///
    /// The persisted form is turns and blocks; the UI wants a flat list of
    /// rows. Doing the conversion here — rather than storing rows — keeps the
    /// database shaped like the domain rather than like this particular view.
    private func loadHistory(for id: ChatID) async {
        guard historyLoadsInFlight.insert(id).inserted else { return }
        defer { historyLoadsInFlight.remove(id) }
        let state = chatStates[id] ?? makeChatState(for: id)
        guard !state.hasLoadedHistory else { return }
        guard let turns = try? await client.transcript(chatID: id) else { return }
        // One query for the whole chat; a long chat used to cost one round
        // trip per turn, each resuming on the main actor.
        let grouped = (try? await client.blocks(chatID: id)) ?? []
        let transitions = (try? await client.chatTransitions(chatID: id)) ?? []
        // Folding results into calls and sorting is linear in the transcript's
        // length; a long chat is not a reason to hold the main thread.
        let rows = await Task.detached(priority: .userInitiated) { () -> [TranscriptRow] in
            let blocks = Dictionary(
                grouped.map { ($0.turnID, $0.blocks) },
                uniquingKeysWith: { first, _ in first }
            )
            return Self.historyRows(turns: turns, blocks: blocks, transitions: transitions)
        }.value
        // The chat may have closed (state released) or closed and reopened
        // (a new state) while this read ran. Load into whatever is current, and
        // never resurrect state for a chat nobody holds any more.
        // `ChatState.loadHistory` ignores a second load.
        guard let current = chatStates[id] else { return }
        current.loadHistory(rows)
    }

    /// A chat's state only if something already loaded it. For polls and
    /// passive reads that must not start a full history load as a side effect.
    func existingChat(for id: ChatID) -> ChatState? {
        chatStates[id]
    }

    private nonisolated static func historyRows(
        turns: [TurnRecord],
        blocks: [TurnID: [BlockRecord]],
        transitions: [ChatTransition]
    ) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        for turn in turns {
            let turnID = turn.turnID
            if let prompt = turn.prompt, !prompt.isEmpty {
                rows.append(TranscriptRow(
                    id: "prompt-\(turn.id)",
                    turnID: turnID,
                    kind: .userMessage,
                    text: prompt,
                    origin: turn.origin,
                    isComplete: true,
                    attachments: turn.attachments,
                    createdAt: turn.startedAt
                ))
            }

            for block in blocks[turnID] ?? [] {
                if block.blockKind == .toolResult,
                   let rawID = block.toolCallID,
                   let index = rows.lastIndex(where: { $0.toolCallID?.rawValue == rawID }) {
                    rows[index].resultText = block.text
                    rows[index].isError = block.isError
                    rows[index].isComplete = true
                    continue
                }
                guard let row = Self.row(from: block, turnID: turnID) else { continue }
                rows.append(row)
            }
        }
        for transition in transitions {
            rows.append(TranscriptRow(
                id: "transition-\(transition.id)",
                turnID: TurnID(rawValue: "transition"),
                kind: .divider,
                text: transition.displayText,
                isComplete: true,
                createdAt: transition.createdAt
            ))
        }
        rows.sort { $0.createdAt < $1.createdAt }
        return rows
    }

    /// Merge newly posted review comments onto the Review tab that produced
    /// them — never onto every chat, and never onto whichever tab is selected.
    ///
    /// Polled, so it reads loaded state where it exists and stored drafts where
    /// it doesn't: creating a `ChatState` here loaded the full history of every
    /// open tab once a second.
    func pullDraftComments(for workspaceID: WorkspaceID) async {
        guard let comments = try? await client.pendingDiffComments(workspaceID: workspaceID) else {
            return
        }
        guard !comments.isEmpty else { return }
        let open = chats(for: workspaceID)
        guard let ownerID = ReviewCommentInbox.owner(
            reviewInbox: reviewInboxChatID(for: workspaceID),
            busyChats: open.filter { chatStates[$0.id]?.isBusy == true }.map(\.id)
        ) else { return }
        let others = open.compactMap { summary -> [DiffCommentReference]? in
            guard summary.id != ownerID else { return nil }
            return draftComments(for: summary.id)
        }
        let dismissed = dismissedKeys(for: ownerID)
        var ownerComments = draftComments(for: ownerID)
        var attaching: [DiffCommentReference] = []
        for comment in comments
        where ReviewCommentInbox.shouldAttach(
            comment,
            ownerComments: ownerComments,
            otherChatsComments: others
        ) && !dismissed.contains(comment.identityKey) {
            ownerComments.append(comment)
            attaching.append(comment)
        }
        guard !attaching.isEmpty else { return }
        let owner = chat(for: ownerID)
        for comment in attaching { owner.addDraftComment(comment) }
        persistDraftComments(owner.draftComments, for: ownerID)
    }

    /// A chat's draft comments without creating its state.
    private func draftComments(for chatID: ChatID) -> [DiffCommentReference] {
        chatStates[chatID]?.draftComments ?? Self.loadDraftComments(for: chatID)
    }

    private nonisolated static func row(
        from block: BlockRecord,
        turnID: TurnID
    ) -> TranscriptRow? {
        switch block.blockKind {
        case .text:
            return TranscriptRow(
                id: block.id, turnID: turnID, kind: .assistantText,
                text: block.text,
                parentToolCallID: block.parentToolCallID.map(ToolCallID.init(rawValue:)),
                isComplete: true, createdAt: block.createdAt
            )
        case .thinking:
            return TranscriptRow(
                id: block.id, turnID: turnID, kind: .thinking,
                text: block.text,
                parentToolCallID: block.parentToolCallID.map(ToolCallID.init(rawValue:)),
                isComplete: true, createdAt: block.createdAt
            )
        case .toolCall:
            // Restore the subagent link so a reloaded transcript nests each
            // Task's tool uses under it, exactly as a live one does.
            return TranscriptRow(
                id: block.id, turnID: turnID, kind: .toolCall,
                text: block.text, toolName: block.toolName,
                toolCallID: block.toolCallID.map(ToolCallID.init(rawValue:)),
                parentToolCallID: block.parentToolCallID.map(ToolCallID.init(rawValue:)),
                toolInput: block.decodedPayload,
                isComplete: true, createdAt: block.createdAt
            )
        case .toolResult:
            // Results are folded into the call they belong to, the same way a
            // live session shows them.
            return nil
        case .plan:
            guard let body = PlanProposalPolicy.normalizedMarkdown(block.text),
                  PlanProposalPolicy.isReadyMarkdown(body)
            else { return nil }
            return TranscriptRow(
                id: block.id, turnID: turnID, kind: .plan,
                text: body, isComplete: true, createdAt: block.createdAt
            )
        case .permission, .question:
            // Both are resolved by the time history is read; replaying them
            // would show a prompt nobody can answer.
            return nil
        case .notice:
            return TranscriptRow(
                id: block.id, turnID: turnID, kind: .divider,
                text: block.text, isComplete: true, createdAt: block.createdAt
            )
        }
    }

    /// Sidebar order: pinned first, then anything that needs attention, then
    /// by recency. "Needs me" outranks "was recent" because that is the
    /// question the sidebar exists to answer.
    private func recomputeSortedWorkspaces() {
        let sorted = workspaces
            .filter { !$0.isArchived }
            .sorted { first, second in
                if first.isPinned != second.isPinned { return first.isPinned }
                if first.needsAttention != second.needsAttention { return first.needsAttention }
                return (first.lastActivity ?? .distantPast) > (second.lastActivity ?? .distantPast)
            }
        if sorted != sortedWorkspaces { sortedWorkspaces = sorted }

        let archived = workspaces.filter(\.isArchived)
        if archived != archivedWorkspaces { archivedWorkspaces = archived }
        recomputeSelectedWorkspace()
        recomputeAttentionCount()
        recomputeNeedsYouStops()
        recomputeFleetActivity()
    }

    private func recomputeSelectedWorkspace() {
        let next = selectedWorkspaceID.flatMap { id in workspaces.first { $0.id == id } }
        if next != selectedWorkspace { selectedWorkspace = next }
    }

    private func recomputeAttentionCount() {
        let next = sortedWorkspaces.lazy.filter(\.needsAttention).count
            + dreamInbox.newFindingCount
        if next != attentionCount { attentionCount = next }
    }

    /// Chat statuses feed the Active tab and the working count, so this runs
    /// after every write to `chatIndex` as well as every fleet change. It is a
    /// pass over each workspace's open tabs — cheap at write time, and far
    /// cheaper than the sidebar doing it on every render.
    private func recomputeFleetActivity() {
        let next = SidebarFleetActivity.resolve(sortedWorkspaces) { chats(for: $0) }
        if next.activeIDs != activeWorkspaceIDs { activeWorkspaceIDs = next.activeIDs }
        if next.workingCount != workingCount { workingCount = next.workingCount }
    }

    /// ⌘1–9's target: the sidebar's displayed order while it is holding still,
    /// the live order otherwise. See `sidebarShortcutOrder`.
    func shortcutWorkspaceID(at index: Int) -> WorkspaceID? {
        SidebarOrderHold.shortcutTarget(
            at: index,
            held: sidebarShortcutOrder,
            live: sortedWorkspaces.map(\.id)
        )
    }

    // MARK: - Commands

    func addRepository(path: String) {
        Task { await client.send(.addRepository(path: path)) }
    }

    /// Start a project ORE has never seen: the core creates the repository,
    /// registers it, and opens its first workspace. The repository list is
    /// refreshed afterwards so a sheet left open ("Create another") can pick
    /// the new project without reopening.
    func createProject(_ request: CreateProjectRequest) {
        Task {
            await client.send(.createProject(request))
            await refreshRepositories()
        }
    }

    func createWorkspace(_ request: CreateWorkspaceRequest) {
        var request = request
        if request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.name = suggestedResearchIdentity().name
        }
        // Reported here rather than from `.workspaceAdded`, because the
        // request is the only place the chosen harness exists, and because
        // `.workspaceAdded` cannot tell creating a workspace apart from one
        // arriving in the snapshot at launch. Note `request.name` is never
        // passed along — the user names these after what they are working on.
        telemetry.record(translator.workspaceCreated(harness: request.harness))
        Task { await client.send(.createWorkspace(request)) }
    }

    /// The same create, awaited.
    ///
    /// `createWorkspace` fires and forgets, which is right for ⌘N and for the
    /// intents — nobody is watching a spinner there. The New Workspace sheet is
    /// the opposite case: it dismissed the moment the command was *queued*, so
    /// the click that makes somebody's first workspace closed the window onto
    /// an empty sidebar and several seconds of nothing while the worktree was
    /// cut. Awaiting the core keeps the sheet's existing `isCreating` spinner up
    /// until there is a workspace to switch to. No new state and no placeholder
    /// row: a placeholder has to be torn down on `.commandFailed` as well as on
    /// `.workspaceAdded`, and one that outlives a failed create is worse than
    /// the delay it was covering.
    func createWorkspaceAndWait(_ request: CreateWorkspaceRequest) async {
        var request = request
        if request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.name = suggestedResearchIdentity().name
        }
        telemetry.record(translator.workspaceCreated(harness: request.harness))
        await client.send(.createWorkspace(request))
    }

    /// The ⌘N action: spin up a fresh worktree in the same repository as the
    /// active tab, seeded from the default branch and inheriting its harness and
    /// model, without stopping to fill out the picker. Falls back to the picker
    /// (via `nil` return) when there's no active workspace to borrow a project
    /// from. ⇧⌘N still opens the full `NewWorkspaceSheet`.
    @discardableResult
    func createWorktreeInCurrentProject() -> Bool {
        guard let source = selectedWorkspace else { return false }
        createWorkspace(CreateWorkspaceRequest(
            repositoryPath: source.repositoryPath,
            name: suggestedResearchIdentity().name,
            seed: .defaultBranch,
            harness: source.harness,
            model: source.model,
            initialPrompt: nil,
            branchPrefix: UserDefaults.standard.string(forKey: "ore.branchPrefix")
        ))
        return true
    }

    // MARK: - Dream Mode

    private(set) var pendingDreamsOpen = false

    func consumePendingDreamsOpen() {
        pendingDreamsOpen = false
    }

    func startDreamNow(repositoryPath: String? = nil) {
        let path = repositoryPath ?? selectedWorkspace?.repositoryPath
        Task { await client.send(.startDreamRun(manual: true, repositoryPath: path)) }
        pendingDreamsOpen = true
    }

    func abortDreamRun() {
        Task { await client.send(.abortDreamRun) }
    }

    func resolveDreamFinding(_ id: DreamFindingID, _ resolution: DreamFindingResolution) {
        Task { await client.send(.resolveDreamFinding(id, resolution)) }
    }

    func revealDreamEvidence(_ evidence: DreamEvidence, for finding: DreamFindingSummary) {
        guard let relative = evidence.path, !relative.isEmpty else { return }
        let worktreePath = dreamWorkspaces.first { $0.id == finding.workspaceID }?.worktreePath
            ?? workspaces.first { $0.id == finding.workspaceID }?.worktreePath
        if let worktreePath {
            let url = URL(fileURLWithPath: worktreePath).appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.open(url)
                return
            }
        }
        let repoRoot = URL(fileURLWithPath: finding.repositoryPath).appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: repoRoot.path) {
            NSWorkspace.shared.open(repoRoot)
        }
    }

    func pushDreamSettings() {
        let settings = DreamSettingsStore.load()
        Task { await client.send(.updateDreamSettings(settings)) }
        syncDreamMonitor()
    }

    private func syncDreamMonitor() {
        let isDreaming = dreamInbox.run?.state == .dreaming
        // The monitor polls idle time and power every 30 seconds. That is only
        // worth doing while Dream Mode can act on it: when it is switched on,
        // or while a run (a manual one included) is going.
        if DreamSettingsStore.load().enabled || isDreaming {
            if dreamMonitor == nil {
                let monitor = DreamEnvironmentMonitor(client: client)
                dreamMonitor = monitor
                monitor.start()
            }
        } else if let monitor = dreamMonitor {
            monitor.stop()
            dreamMonitor = nil
        }
        dreamMonitor?.isDreaming = isDreaming
        dreamMonitor?.refreshAssertion()
        refreshDreamSleepStatus()
    }

    private func startDreamMode() {
        pushDreamSettings()
        Task { await client.send(.listDreamFindings) }
    }

    private func upsertDream(_ summary: WorkspaceSummary) {
        if let index = dreamWorkspaces.firstIndex(where: { $0.id == summary.id }) {
            guard dreamWorkspaces[index] != summary else { return }
            dreamWorkspaces[index] = summary
        } else {
            dreamWorkspaces.append(summary)
        }
    }

    private func upsertDreamFinding(_ finding: DreamFindingSummary) {
        var findings = dreamInbox.findings
        if let index = findings.firstIndex(where: { $0.id == finding.id }) {
            guard findings[index] != finding else { return }
            findings[index] = finding
        } else {
            findings.insert(finding, at: 0)
        }
        dreamInbox.findings = findings
    }

    func refreshDreamSleepStatus() {
        let status = dreamMonitor?.currentSleepStatus
            ?? DreamScheduler.sleepStatus(
                settings: DreamSettingsStore.load(),
                environment: DreamEnvironmentSnapshot(
                    secondsSinceInput: DreamEnvironmentMonitor.secondsSinceInput(),
                    isOnACPower: DreamEnvironmentMonitor.isOnACPower()
                ),
                isDreaming: dreamInbox.run?.state == .dreaming
            )
        if status != dreamSleepStatus { dreamSleepStatus = status }
    }

    private var notifiedDreamRunIDs: Set<String> = []

    private func maybeNotifyDreamFinished(_ run: DreamRunSummary) {
        guard run.state == .completed || run.state == .interrupted else { return }
        guard notifiedDreamRunIDs.insert(run.id.rawValue).inserted else { return }
        let count = dreamInbox.newFindingCount
        let projects = Set(dreamInbox.findings.filter { $0.status == .new }.map(\.repositoryName)).count
        let body: String
        if count == 0 {
            body = "ORE dreamed last night and found nothing worth waking you for."
        } else {
            body = "ORE dreamed about \(projects) project\(projects == 1 ? "" : "s") — \(count) finding\(count == 1 ? "" : "s")"
        }
        postNotification(
            title: "Dreams",
            body: body,
            category: NotificationCategory.dreams,
            extraInfo: ["openDreams": "1"]
        )
    }

    /// Returns the chat the message actually went to, which the assistant's
    /// callers need: with several assistant conversations, "the active one"
    /// can change between asking and being answered, and a reply spoken into
    /// the wrong conversation is worse than one not spoken at all.
    @discardableResult
    func send(
        _ text: String,
        attachments: [Attachment] = [],
        effort: ReasoningEffort? = nil,
        serviceTier: String? = nil,
        origin: MessageOrigin = .user,
        to id: WorkspaceID
    ) -> ChatID? {
        guard let chatID = activeChat(for: id)?.id else { return nil }
        send(
            text,
            attachments: attachments,
            effort: effort,
            serviceTier: serviceTier,
            origin: origin,
            to: id,
            chatID: chatID
        )
        return chatID
    }

    // Internal, not private: the split column sends to its own conversation
    // by ID — it cannot go through the active-chat convenience above.
    func send(
        _ text: String,
        attachments: [Attachment] = [],
        effort: ReasoningEffort? = nil,
        serviceTier: String? = nil,
        origin: MessageOrigin = .user,
        to id: WorkspaceID,
        chatID: ChatID,
        fromComposer: Bool = true
    ) {
        let state = chat(for: chatID)
        cancelScheduledContinuation(for: chatID)
        // A button's prompt isn't the composer's text: whatever the user has
        // half-typed, attached or commented stays put for their own send.
        let comments = fromComposer ? state.takeDraftComments() : []
        if fromComposer {
            persistDraftComments([], for: chatID)
            persistDraftAttachments([], for: chatID)
            // The text just left the composer, so any buffered copy of it is stale.
            // Clearing the summary here rather than waiting out the debounce is what
            // keeps the tab bar's unsent-draft pencil from lingering after a send.
            discardPendingDraft(for: chatID)
            if composerInjection?.chatID == chatID { composerInjection = nil }
            if var summary = chatSummaries.first(where: { $0.id == chatID }), !summary.draftText.isEmpty {
                summary.draftText = ""
                upsertChat(summary)
            }
        }
        // One id for the row drawn now and the engine's echo of the same send,
        // so this message is not drawn a second time when the echo arrives.
        let submissionID = UUID().uuidString
        state.appendUserMessage(
            text,
            attachments: attachments,
            comments: comments,
            // Forwarded, not defaulted. The engine's echo carries the true
            // origin but is dropped as a duplicate of this row, so whatever is
            // set here is what the transcript believes forever — and a `.watch`
            // digest drawn as `.user` is ORE putting words in the user's mouth.
            origin: origin,
            submissionID: submissionID
        )
        let isAssistant = assistantWorkspace?.id == id
        Task {
            let hidden = isAssistant ? await client.assistantAppStateText() : nil
            await client.send(.sendMessage(SendMessageRequest(
                workspaceID: id,
                chatID: chatID,
                text: text,
                attachments: attachments,
                diffComments: comments,
                reasoningEffort: effort,
                serviceTier: serviceTier,
                origin: origin,
                submissionID: submissionID,
                hiddenContext: hidden
            )))
        }
    }

    func interrupt(_ id: WorkspaceID) {
        guard let chatID = activeChat(for: id)?.id else { return }
        Task { await client.send(.interruptChatTurn(id, chatID)) }
    }

    /// Interrupt a specific conversation — the split column's stop button,
    /// which must not assume its chat is the active one.
    func interrupt(_ id: WorkspaceID, chatID: ChatID) {
        Task { await client.send(.interruptChatTurn(id, chatID)) }
    }

    /// A second conversation opened beside the active one, per workspace —
    /// the reference design's split layout. Transient by design: a split is a
    /// working arrangement for right now, not a document worth persisting.
    var splitChat: [WorkspaceID: ChatID] = [:]

    func openSplitChat(_ chatID: ChatID, in workspaceID: WorkspaceID) {
        splitChat[workspaceID] = chatID
    }

    func closeSplitChat(in workspaceID: WorkspaceID) {
        splitChat[workspaceID] = nil
    }

    /// Stops the assistant's own turn — the Escape key in voice mode. Goes
    /// through `assistantChatID` rather than `interrupt(_:)`: the assistant's
    /// workspace is routed off `workspaces`, so it has no "active chat" in the
    /// sense the sidebar means.
    /// `chatID` names the conversation to stop. It defaults to the visible one,
    /// but a caller waiting on a specific answer passes the conversation it
    /// asked — the user can switch conversations while a turn is running, and
    /// stopping the one they happen to be looking at is not what they meant.
    func interruptAssistant(chatID: ChatID? = nil) {
        guard let assistant = assistantWorkspace,
              let chatID = chatID ?? assistantChatID else { return }
        Task { await client.send(.interruptChatTurn(assistant.id, chatID)) }
    }

    func setPermissionMode(_ mode: PermissionMode, for id: WorkspaceID) {
        guard let chatID = activeChat(for: id)?.id else { return }
        Task { await client.send(.setChatPermissionMode(id, chatID, mode)) }
    }

    func setEffort(_ effort: ReasoningEffort?, for chat: ChatSummary) {
        Task { await client.send(.setChatEffort(chat.workspaceID, chat.id, effort)) }
    }

    /// `automatic` is set only by the routine-approval path below, never by a
    /// click: a request the user actually saw must not be recorded as one ORE
    /// waved through.
    func resolvePermission(
        _ requestID: PermissionRequestID,
        decision: PermissionDecision,
        for id: WorkspaceID,
        chatID: ChatID? = nil,
        automatic: AutomaticApproval? = nil
    ) {
        let resolvedChatID = chatID ?? activeChat(for: id)?.id
        guard let resolvedChatID else { return }
        // Optimistic and exact: the click is authoritative locally, so do not
        // wait for the provider's round trip while a now-obsolete prompt keeps
        // talking or opens its hands-free answer microphone.
        voiceAssistant.permissionResolved(requestID)
        narration.cancelPermissionPrompt(requestID)
        chat(for: resolvedChatID).resolvePermission(requestID)
        retireNeedsYou(resolving: requestID)
        Task {
            await client.send(.resolveChatPermission(
                id, resolvedChatID, requestID, decision, automatic: automatic
            ))
        }
    }

    struct WorkspacePermissionGroup: Identifiable {
        let chat: ChatSummary
        let requests: [PermissionRequest]
        let questions: [AgentQuestion]
        let hasPlan: Bool
        var id: ChatID { chat.id }
        var pendingCount: Int { requests.count + questions.count + (hasPlan ? 1 : 0) }
    }

    func workspacePermissionGroups(for workspaceID: WorkspaceID) -> [WorkspacePermissionGroup] {
        chats(for: workspaceID, includeClosed: true).compactMap { summary in
            guard let state = chatStates[summary.id] else { return nil }
            let hasPlan: Bool
            if case .proposal = state.plan { hasPlan = true } else { hasPlan = false }
            let questions = state.pendingQuestions
            let requests = state.pendingPermissions.filter { permission in
                // A dedicated question or plan owns its backing permission;
                // show one item rather than two ways to answer the same gate.
                if permission.toolName == "AskUserQuestion",
                   questions.contains(where: { $0.toolCallID == permission.toolCallID }) { return false }
                if permission.toolName == "ExitPlanMode", hasPlan { return false }
                return true
            }
            guard !requests.isEmpty || !questions.isEmpty || hasPlan else { return nil }
            return WorkspacePermissionGroup(chat: summary, requests: requests, questions: questions, hasPlan: hasPlan)
        }
    }

    func approveWorkspaceRequests(for workspaceID: WorkspaceID) {
        // Snapshot the set the user approved. Requests arriving later need a
        // separate click or an explicitly enabled timed grant.
        let groups = workspacePermissionGroups(for: workspaceID)
        for group in groups {
            for request in group.requests where WorkspacePermissionPolicy.isToolRequest(request) {
                resolvePermission(request.id, decision: .allow, for: workspaceID, chatID: group.chat.id)
            }
        }
    }

    func enableWorkspaceAutoApproval(for workspaceID: WorkspaceID, minutes: Int) async -> Bool {
        guard [5, 15, 30, 60].contains(minutes) else { return false }
        guard await Self.authenticateStandingGrant(
            reason: "automatically approve tool requests in this ORE workspace for \(minutes) minutes"
        ) else { return false }
        let grant = WorkspaceAutoApproval(
            workspaceID: workspaceID,
            expiresAt: Date().addingTimeInterval(Double(minutes) * 60)
        )
        workspaceAutoApprovals[workspaceID] = grant
        for group in workspacePermissionGroups(for: workspaceID) {
            for request in group.requests where grant.allows(request, in: workspaceID) {
                approveTimedWorkspaceRequest(request, workspaceID: workspaceID, chatID: group.chat.id, grant: grant)
            }
        }
        return true
    }

    func disableWorkspaceAutoApproval(for workspaceID: WorkspaceID) {
        workspaceAutoApprovals.removeValue(forKey: workspaceID)
    }

    private func approveTimedWorkspaceRequest(
        _ request: PermissionRequest, workspaceID: WorkspaceID, chatID: ChatID,
        grant: WorkspaceAutoApproval
    ) {
        let content = PermissionPresentation(request: request)
        resolvePermission(
            request.id, decision: .allow, for: workspaceID, chatID: chatID,
            automatic: AutomaticApproval(
                toolCallID: request.toolCallID,
                command: content.target ?? WorkspacePermissionPolicy.inputText(request.input),
                reason: "is covered by your workspace auto-approval until \(grant.expiresAt.formatted(date: .omitted, time: .shortened))"
            )
        )
    }

    /// Drop every ask this permission was the gate for — see `NeedsYouPairing`.
    private func retireNeedsYou(resolving requestID: PermissionRequestID) {
        let remaining = NeedsYouPairing.remaining(tabNeedsYou, resolving: requestID)
        if remaining != tabNeedsYou { tabNeedsYou = remaining }
    }

    /// The Allow/Deny card currently on screen, if the generic buttons own it.
    /// AskUserQuestion and ExitPlanMode keep their dedicated cards instead.
    var actionablePermission: PermissionRequest? {
        guard let chat = selectedChat else { return nil }
        // The same request the card shows: the oldest one the generic
        // buttons own.
        return chat.pendingPermissions.first { permission in
            if permission.toolName == "AskUserQuestion" { return false }
            if permission.toolName == "ExitPlanMode", case .proposal = chat.plan { return false }
            return true
        }
    }

    /// ⇧⌘A from the composer, which approves without the card being focused.
    ///
    /// Refuses when the command runs past what the card shows collapsed: the
    /// chord is a reflex, and there is no version of this shortcut that also
    /// makes the user read the tail. They can expand the card and press ↩.
    func allowPendingPermission() {
        guard let workspaceID = selectedWorkspaceID,
              let permission = actionablePermission,
              !PermissionPresentation(request: permission).isAbbreviated
        else { return }
        resolvePermission(permission.id, decision: .allow, for: workspaceID)
    }

    func denyPendingPermission() {
        guard let workspaceID = selectedWorkspaceID,
              let permission = actionablePermission else { return }
        resolvePermission(
            permission.id,
            decision: .deny(reason: "The user denied this in ORE."),
            for: workspaceID
        )
    }

    /// Answer a question from whichever surface the user reached for — the
    /// transcript card, the floating HUD, the menu bar, the assistant window,
    /// a notification reply or voice.
    ///
    /// Claude's AskUserQuestion is a permission-gated tool: its result is
    /// whatever comes back through the `can_use_tool` reply. Allowing it echoed
    /// the untouched input, so the agent read an empty "answered:" while the
    /// real answer — sent separately as a user message — raced the still-open
    /// control request and was dropped. The answer has to travel *through* the
    /// permission reply. Every caller used to be on its own to know that, and
    /// only two of six did; the routing lives here now so a question answered
    /// from the HUD reaches the agent exactly as one answered in the window.
    func answerQuestion(
        _ questionID: QuestionID,
        answer: String,
        for id: WorkspaceID,
        chatID: ChatID? = nil
    ) {
        let resolvedChatID = chatID ?? activeChat(for: id)?.id
        guard let resolvedChatID else { return }
        let state = chat(for: resolvedChatID)
        // The question as the agent asked it, which is what carries the tool
        // call identity. An answer arriving for a question that is no longer
        // pending — a stale notification, a second click — has no identity to
        // pair on, and must not be allowed to resolve someone else's gate.
        guard let question = state.pendingQuestions.first(where: { $0.id == questionID }) else {
            return
        }
        let gate = NeedsYouPairing.gate(
            forToolCall: question.toolCallID,
            pendingPermissions: state.pendingPermissions
        )
        // Captured in ask order before the answer retires this one, so the
        // reply reads back in the order the agent asked.
        let siblings = state.questions(inToolCall: question.toolCallID)
        let group = siblings.isEmpty ? [question] : siblings
        state.recordAnswer(answer, for: questionID)
        tabNeedsYou.removeAll {
            if case .question(let item) = $0, item.question.id == questionID { return true }
            return false
        }
        guard let gate else {
            Task { await client.send(.answerChatQuestion(id, resolvedChatID, questionID, answer: answer)) }
            return
        }

        // One tool call, one reply. Siblings the user has not reached yet
        // keep the gate open rather than being discarded — the agent asked
        // three things and is entitled to three answers.
        let waiting = state.unansweredSiblings(of: question)
        let isDismissal = answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !waiting.isEmpty && !isDismissal { return }

        // A dismissal ends the whole group. The user closing one card of a
        // set is not going to answer the rest, and leaving the gate open
        // would hang the turn with nothing on screen to unblock it.
        let answered = group.map {
            (question: $0, answer: state.questionAnswers[$0.id] ?? "")
        }
        let answeredIDs = group.map(\.id)
        state.clearQuestions(answeredIDs)
        let dropped = Set(answeredIDs)
        tabNeedsYou.removeAll {
            if case .question(let item) = $0 { return dropped.contains(item.question.id) }
            return false
        }
        resolvePermission(
            gate,
            decision: .deny(reason: NeedsYouPairing.reply(for: answered)),
            for: id,
            chatID: resolvedChatID
        )
    }

    func revert(to turnID: TurnID, in id: WorkspaceID) {
        guard let chatID = activeChat(for: id)?.id else { return }
        Task { await client.send(.revertChatToCheckpoint(id, chatID, turnID)) }
    }

    func createChat(
        in workspaceID: WorkspaceID,
        initialMessage: String? = nil,
        draft: String? = nil,
        defaults: ChatDefaults? = nil,
        model: String? = nil,
        isReview: Bool = false
    ) {
        if isReview { pendingReviewCommentInbox.insert(workspaceID) }
        if let initialMessage {
            pendingNewChatMessages[workspaceID, default: []].append(initialMessage)
        }
        if let draft {
            // Latest click wins if a tab is already spinning up.
            pendingNewChatDrafts[workspaceID] = [draft]
        }
        guard chatCreationsInFlight.insert(workspaceID).inserted else { return }
        // A new conversation is a chat destination even when it was invoked
        // while reading a source tab. Keep the existing chat visible until the
        // core publishes the new one, then switch in one atomic event.
        showChatInCenter(workspaceID)
        let workspace = workspaces.first { $0.id == workspaceID }
        let usedTitles = Set(chats(for: workspaceID, includeClosed: true).map(\.title))
        let title = ResearchIdentity.nextResearchTitle(
            excluding: usedTitles,
            preferred: workspace.flatMap(researchIdentity(for:))
        )
        let resolved = defaults ?? newChatDefaults(for: workspaceID)
        Task { await client.send(.createChat(CreateChatRequest(
            workspaceID: workspaceID,
            title: title,
            harness: resolved.harness,
            model: model ?? resolved.model,
            permissionMode: workspace?.permissionMode ?? .default
        ))) }
    }

    /// Opens a new tab with the plan already in the composer, unsent.
    ///
    /// The source tab is left alone — this is a copy, not a transfer — so the
    /// user can still approve or reject there. The new tab uses workspace
    /// defaults so they can pick a different harness and model before sending.
    func handoffPlan(_ markdown: String, in workspaceID: WorkspaceID) {
        guard let draft = PlanHandoff.composerDraft(from: markdown) else { return }
        createChat(in: workspaceID, draft: draft)
    }

    /// Branches the active chat into a new tab.
    ///
    /// The new tab resumes the same provider session with a fork, so the agent
    /// still remembers the conversation while the original tab keeps its own
    /// copy — two directions from one point, rather than a choice between them.
    func forkChat(into workspaceID: WorkspaceID) {
        guard let source = activeChat(for: workspaceID),
              chatCreationsInFlight.insert(workspaceID).inserted else { return }
        showChatInCenter(workspaceID)
        let used = Set(chats(for: workspaceID, includeClosed: true).map(\.title))
        Task { await client.send(.createChat(CreateChatRequest(
            workspaceID: workspaceID,
            title: ResearchIdentity.unique("\(source.title) (fork)", excluding: used),
            harness: source.harness,
            model: source.model,
            permissionMode: source.permissionMode,
            forkFrom: source.id
        ))) }
    }

    /// Asks the tab the user is in to stage and commit everything. That tab's
    /// agent already knows what the work was about, so it writes honest
    /// messages, and the result lands where the user is looking rather than
    /// in a tab spun up beside it. A busy turn queues it like any message.
    func commitWithAgent(in workspaceID: WorkspaceID) {
        sendToCurrentTab(Self.commitAgentPrompt, in: workspaceID)
    }

    static let commitAgentPrompt = """
        Commit all outstanding work in this worktree. Review everything staged \
        and unstaged, group related changes into one or more coherent commits, \
        and write clear, conventional commit messages that explain the why. \
        Include untracked files that belong to the work; leave anything that \
        looks accidental uncommitted and call it out. Do not push. Proceed \
        without asking for confirmation.
        """

    /// The "ship it" sibling of `commitWithAgent`: the current tab commits
    /// whatever is outstanding, pushes, and opens the pull request — the
    /// whole default flow, no sheets, no questions.
    func shipWithAgent(in workspaceID: WorkspaceID, base: String? = nil) {
        let baseBranch = base
            ?? workspaces.first { $0.id == workspaceID }?.baseBranch
            ?? "main"
        sendToCurrentTab(Self.shipAgentPrompt(base: baseBranch), in: workspaceID)
    }

    static func shipAgentPrompt(base: String) -> String {
        """
        Ship this branch. Commit any outstanding staged and unstaged work \
        with clear, conventional commit messages, push the branch, and \
        open a pull request against \(base) with a concise title \
        and a description that covers what changed and why. Never force \
        push. Proceed without asking for confirmation, and finish by \
        reporting the pull request URL.
        """
    }

    /// A button's prompt goes to the tab on screen, leaving its composer
    /// alone. Only a workspace with no tab open gets a new one.
    private func sendToCurrentTab(_ prompt: String, in workspaceID: WorkspaceID) {
        showChatInCenter(workspaceID)
        guard let chatID = activeChat(for: workspaceID)?.id else {
            createChat(in: workspaceID, initialMessage: prompt)
            return
        }
        send(prompt, to: workspaceID, chatID: chatID, fromComposer: false)
    }

    /// Marks a chat as ephemeral: hidden from the tab strip, never focused,
    /// rendered only by the surface that created it (the find bar's answers
    /// panel). A zero-width space keeps the marker invisible anywhere the
    /// title does leak.
    static let ephemeralChatPrefix = "\u{200B}"

    /// Ephemeral chats tracked by id — the durable marker. Titles round-trip
    /// through the core and can come back normalized, which is how an
    /// "invisible" chat once leaked into the tab strip as a visible tab.
    private var pendingEphemeralWorkspaces: Set<WorkspaceID> = []
    private(set) var ephemeralChatIDs: Set<ChatID> = []

    func isEphemeralChat(_ id: ChatID) -> Bool {
        ephemeralChatIDs.contains(id)
    }

    /// The workspace's ephemeral answers chat, if one is open.
    func answersChat(in workspaceID: WorkspaceID) -> ChatSummary? {
        chats(for: workspaceID).first {
            ephemeralChatIDs.contains($0.id)
                || $0.title.hasPrefix(Self.ephemeralChatPrefix)
        }
    }

    /// Answers a question with the recent context of *every* tab in the
    /// workspace: each chat's last turns are digested into one prompt and an
    /// *ephemeral* chat takes the question — no tab appears and focus never
    /// moves; the find bar streams the reply in place.
    func askAcrossTabs(_ question: String, in workspaceID: WorkspaceID) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            // One at a time: a re-ask replaces the previous answers chat.
            if let previous = answersChat(in: workspaceID) {
                closeChat(previous.id, in: workspaceID)
            }
            let prompt = await crossTabPrompt(question: trimmed, workspaceID: workspaceID)
            guard chatCreationsInFlight.insert(workspaceID).inserted else { return }
            // The id isn't known until `chatAdded`; this flag is how that
            // handler knows the next chat here is ephemeral.
            pendingEphemeralWorkspaces.insert(workspaceID)
            pendingNewChatMessages[workspaceID, default: []].append(prompt)
            let defaults = newChatDefaults(for: workspaceID)
            let used = Set(chats(for: workspaceID, includeClosed: true).map(\.title))
            await client.send(.createChat(CreateChatRequest(
                workspaceID: workspaceID,
                title: Self.ephemeralChatPrefix
                    + ResearchIdentity.unique("Answers", excluding: used),
                harness: defaults.harness,
                model: defaults.model,
                permissionMode: workspaces.first { $0.id == workspaceID }?.permissionMode ?? .default
            )))
        }
    }

    /// One digest per tab: the user prompt and the final reply of the last
    /// few turns, clipped hard — context for a question, not a transcript
    /// dump into the new tab's window.
    private func crossTabPrompt(question: String, workspaceID: WorkspaceID) async -> String {
        var sections: [String] = []
        // Real conversations only: a previous answers chat digesting itself
        // would echo back into every follow-up question.
        let real = chats(for: workspaceID).filter {
            !ephemeralChatIDs.contains($0.id)
                && !$0.title.hasPrefix(Self.ephemeralChatPrefix)
        }
        for summary in real {
            guard let turns = try? await client.transcript(chatID: summary.id),
                  !turns.isEmpty else { continue }
            var lines: [String] = []
            for turn in turns.suffix(5) {
                if let prompt = turn.prompt, !prompt.isEmpty {
                    lines.append("User: \(Self.clipped(prompt, to: 400))")
                }
                if let blocks = try? await client.blocks(turnID: turn.turnID),
                   let reply = blocks.last(where: {
                       $0.blockKind == .text && !$0.text.isEmpty
                   }) {
                    lines.append("Agent: \(Self.clipped(reply.text, to: 700))")
                }
            }
            guard !lines.isEmpty else { continue }
            sections.append(
                "## Tab \u{201C}\(summary.title)\u{201D}\n" + lines.joined(separator: "\n")
            )
        }
        let context = sections.isEmpty
            ? "(No prior conversations in this workspace.)"
            : sections.joined(separator: "\n\n")
        return """
            You have the recent context of every conversation tab in this \
            workspace, digested below. Answer the user's question using this \
            context first; read files in the worktree only when the digests \
            don't hold the answer.

            \(context)

            ---
            The user's question: \(question)
            """
    }

    private static func clipped(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return trimmed.prefix(limit) + "…"
    }

    /// Assistant workspaces whose next new conversation the user asked for and
    /// should therefore be moved to. See the `chatAdded` handler.
    private var assistantConversationsAwaitingFocus: Set<WorkspaceID> = []

    /// A fresh assistant conversation, keeping the current one intact and
    /// readable.
    ///
    /// Not `createChat(in:)`: that one names tabs after scientists and reads
    /// its defaults out of `workspaces`, which the assistant is deliberately
    /// routed out of. And not the workspace record's harness either — that is
    /// never updated when the assistant is moved off a rate-limited or missing
    /// CLI, so on a machine without Claude Code it would name one that cannot
    /// start. The live conversation is the only honest source for what runs
    /// here.
    func createAssistantConversation() {
        guard let assistant = assistantWorkspace,
              let current = activeChat(for: assistant.id)
                  ?? chats(for: assistant.id, includeClosed: true).last,
              chatCreationsInFlight.insert(assistant.id).inserted
        else { return }
        assistantConversationsAwaitingFocus.insert(assistant.id)
        let used = Set(chats(for: assistant.id, includeClosed: true).map(\.title))
        Task { await client.send(.createChat(CreateChatRequest(
            workspaceID: assistant.id,
            title: ResearchIdentity.unique("Conversation", excluding: used),
            harness: current.harness,
            model: current.model,
            permissionMode: current.permissionMode
        ))) }
    }

    func selectChat(_ chatID: ChatID, in workspaceID: WorkspaceID) {
        // Before the switch: the pane restores its composer from the summary's
        // `draftText`, so the outgoing tab's buffered text has to be in there
        // first or it would be restored as the text from one debounce ago.
        flushPendingDrafts()
        let previous = activeChatIDs[workspaceID]
        activeChatIDs[workspaceID] = chatID
        UserDefaults.standard.set(chatID.rawValue, forKey: "ore.activeChat.\(workspaceID.rawValue)")
        _ = chat(for: chatID)
        if workspaceID == selectedWorkspaceID {
            narration.activeChatChanged(chatID)
        }
        Task {
            if let previous {
                try? await client.setFocused(workspaceID: workspaceID, chatID: previous, focused: false)
            }
            try? await client.setFocused(workspaceID: workspaceID, chatID: chatID, focused: true)
        }
    }

    /// Put a workspace — optionally one of its tabs — in front of the user.
    ///
    /// Shared by the assistant's `OpenWorkspace` tool and the Assistant
    /// window's "Open tab" affordance: both mean the same thing, and a user
    /// who is looking at the Assistant window is by definition not looking at
    /// the tab, so selecting it without activating would be a silent no-op.
    /// The caller still opens the `main` window — that needs a SwiftUI
    /// environment this model does not have.
    func reveal(workspaceID: WorkspaceID, chatID: ChatID? = nil) {
        selectedWorkspaceID = workspaceID
        if let chatID { selectChat(chatID, in: workspaceID) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeChat(_ chatID: ChatID, in workspaceID: WorkspaceID) {
        // A closed chat can be reopened, so its draft is written rather than
        // dropped.
        flushPendingDrafts()
        // Pick the neighbor before the close lands, so the UI never flashes
        // the first remaining tab via `activeChat`'s fallback.
        if let replacement = TabCloseSelection.replacement(
            closing: chatID,
            active: activeChat(for: workspaceID)?.id,
            open: chats(for: workspaceID).map(\.id)
        ) {
            selectChat(replacement, in: workspaceID)
        }
        Task { await client.send(.closeChat(workspaceID, chatID)) }
    }

    /// A tab whose agent is still working, staged for a confirmation prompt
    /// before it is actually closed. Presented by the visible `ChatPane`.
    struct PendingChatClose: Identifiable {
        let workspaceID: WorkspaceID
        let chatID: ChatID
        let title: String
        var id: ChatID { chatID }
    }

    var pendingChatClose: PendingChatClose?

    /// Close a chat, but if its agent is mid-turn, stage a confirmation instead
    /// of tearing the conversation down from under a running turn.
    func requestCloseChat(_ chatID: ChatID, in workspaceID: WorkspaceID, title: String) {
        if chat(for: chatID).isBusy {
            pendingChatClose = PendingChatClose(
                workspaceID: workspaceID, chatID: chatID, title: title
            )
        } else {
            closeChat(chatID, in: workspaceID)
        }
    }

    func renameChat(
        _ chatID: ChatID,
        in workspaceID: WorkspaceID,
        to title: String,
        userInitiated: Bool = true
    ) {
        Task {
            await client.send(.renameChat(
                workspaceID, chatID, title: title, userInitiated: userInitiated
            ))
        }
    }

    // MARK: - Centre diff tabs

    /// Opens (or re-focuses) a file's diff as a tab in the centre column.
    func openDiffFile(_ path: String, in workspaceID: WorkspaceID) {
        openFile(path, in: workspaceID, mode: .diff)
    }

    /// A line to reveal when a file opens, from a `file.py:711`-style reference.
    /// The token forces a re-scroll even when the same line is requested twice.
    struct FileFocus: Equatable {
        var line: Int
        var token: Int
    }
    private(set) var fileFocus: [WorkspaceID: [String: FileFocus]] = [:]
    private var fileFocusToken = 0

    func openSourceFile(_ path: String, in workspaceID: WorkspaceID, line: Int? = nil) {
        if let line {
            fileFocusToken += 1
            fileFocus[workspaceID, default: [:]][path] = FileFocus(line: line, token: fileFocusToken)
            // A line reveal needs the editor — a rendered document has no
            // line 42 to scroll to.
            openFile(path, in: workspaceID, mode: .source)
            return
        }
        openFile(path, in: workspaceID, mode: .preferred(forPath: path))
    }

    private func openFile(_ path: String, in workspaceID: WorkspaceID, mode: FilePresentationMode) {
        var files = openFilePaths[workspaceID] ?? []
        if !files.contains(path) {
            files.append(path)
            openFilePaths[workspaceID] = files
        }
        filePresentationModes[workspaceID, default: [:]][path] = mode
        activeFilePath[workspaceID] = path
    }

    func setFilePresentationMode(_ mode: FilePresentationMode, path: String, in workspaceID: WorkspaceID) {
        filePresentationModes[workspaceID, default: [:]][path] = mode
    }

    func selectDiffFile(_ path: String, in workspaceID: WorkspaceID) {
        // A file tab replaces the composer, so its text has to be written back
        // before the pane goes away.
        flushPendingDrafts()
        activeFilePath[workspaceID] = path
    }

    func closeDiffFile(_ path: String, in workspaceID: WorkspaceID) {
        var files = openFilePaths[workspaceID] ?? []
        files.removeAll { $0 == path }
        openFilePaths[workspaceID] = files
        filePresentationModes[workspaceID]?[path] = nil
        if activeFilePath[workspaceID] == path {
            // Fall back to the last remaining file tab, else the chat.
            activeFilePath[workspaceID] = files.last
        }
    }

    /// Switches the centre back to the chat transcript (a chat tab was picked).
    func showChatInCenter(_ workspaceID: WorkspaceID) {
        flushPendingDrafts()
        activeFilePath[workspaceID] = nil
    }

    func reopenChat(_ chatID: ChatID, in workspaceID: WorkspaceID) {
        Task { await client.send(.reopenChat(workspaceID, chatID)) }
    }

    func switchHarness(_ harness: HarnessKind, model selectedModel: String?, for chat: ChatSummary) {
        Task { await client.send(.switchChatHarness(
            chat.workspaceID, chat.id, harness: harness, model: selectedModel
        )) }
    }

    func setModel(_ selectedModel: String?, for chat: ChatSummary) {
        Task { await client.send(.setChatModel(chat.workspaceID, chat.id, model: selectedModel)) }
    }

    /// Records the composer's text, coalescing keystrokes.
    ///
    /// Writing on every character meant every character mutated `chatSummaries`
    /// — invalidating every view that reads `AppModel` — and queued an IPC send.
    /// Drafts only have to survive leaving the composer, not each keystroke, so
    /// they are buffered and flushed on a delay, plus explicitly at every exit
    /// path (`flushPendingDrafts`'s callers).
    func setDraft(_ text: String, for chat: ChatSummary) {
        pendingDrafts[chat.id] = (chat.workspaceID, text)
        scheduleDraftFlush()
    }

    private func scheduleDraftFlush() {
        guard draftFlushTask == nil else { return }
        draftFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.draftFlushTask = nil
            self.flushPendingDrafts()
        }
    }

    /// Writes buffered drafts through. Safe to call when nothing is pending.
    func flushPendingDrafts() {
        for command in takePendingDraftCommands() {
            Task { await client.send(command) }
        }
    }

    /// `flushPendingDrafts` for callers that must not outrun the writes — the
    /// only one being `shutdown`, where a fire-and-forget send would race the
    /// core going away and silently drop the draft.
    func flushPendingDraftsAwaitingWrites() async {
        for command in takePendingDraftCommands() {
            await client.send(command)
        }
    }

    /// Applies buffered drafts to the local summaries and returns the commands
    /// the core still needs, so the caller decides whether to await them.
    private func takePendingDraftCommands() -> [CoreCommand] {
        draftFlushTask?.cancel()
        draftFlushTask = nil
        guard !pendingDrafts.isEmpty else { return [] }
        let pending = pendingDrafts
        pendingDrafts.removeAll()
        return pending.compactMap { chatID, entry in
            // Re-read the current summary rather than reusing the one the view
            // captured: over the debounce window the engine may have updated the
            // title or unread flag, and writing back a stale copy would clobber
            // them.
            guard var current = chatSummaries.first(where: { $0.id == chatID }),
                  current.draftText != entry.text else { return nil }
            current.draftText = entry.text
            upsertChat(current)
            return .setChatDraft(entry.workspaceID, chatID, text: entry.text)
        }
    }

    /// Drops a buffered draft without writing it — for when the text has already
    /// left the composer by another route (it was sent, or the chat closed).
    private func discardPendingDraft(for chatID: ChatID) {
        pendingDrafts.removeValue(forKey: chatID)
    }

    func persistDraftAttachments(_ attachments: [Attachment], for chatID: ChatID) {
        chat(for: chatID).draftAttachments = attachments
        let key = Self.draftAttachmentsKey(for: chatID)
        if attachments.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(attachments) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func loadDraftAttachments(for chatID: ChatID) -> [Attachment] {
        let key = draftAttachmentsKey(for: chatID)
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Attachment].self, from: data)) ?? []
    }

    private static func draftAttachmentsKey(for chatID: ChatID) -> String {
        "ore.draftAttachments.\(chatID.rawValue)"
    }

    func persistDraftComments(_ comments: [DiffCommentReference], for chatID: ChatID) {
        chat(for: chatID).replaceDraftComments(comments)
        let key = Self.draftCommentsKey(for: chatID)
        if comments.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(comments) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func loadDraftComments(for chatID: ChatID) -> [DiffCommentReference] {
        let key = draftCommentsKey(for: chatID)
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([DiffCommentReference].self, from: data)) ?? []
    }

    private static func draftCommentsKey(for chatID: ChatID) -> String {
        "ore.draftComments.\(chatID.rawValue)"
    }

    func reviewInboxChatID(for workspaceID: WorkspaceID) -> ChatID? {
        if let remembered = reviewCommentInbox[workspaceID] { return remembered }
        if let stored = storedReviewInbox[workspaceID] { return stored }
        let id = UserDefaults.standard.string(forKey: Self.reviewInboxKey(for: workspaceID))
            .map(ChatID.init(rawValue:))
        storedReviewInbox[workspaceID] = .some(id)
        return id
    }

    func isReviewCommentInbox(_ chatID: ChatID, in workspaceID: WorkspaceID) -> Bool {
        reviewInboxChatID(for: workspaceID) == chatID
    }

    private func rememberReviewInbox(_ chatID: ChatID, for workspaceID: WorkspaceID) {
        if reviewCommentInbox[workspaceID] != chatID { reviewCommentInbox[workspaceID] = chatID }
        storedReviewInbox[workspaceID] = .some(chatID)
        UserDefaults.standard.set(chatID.rawValue, forKey: Self.reviewInboxKey(for: workspaceID))
    }

    private static func reviewInboxKey(for workspaceID: WorkspaceID) -> String {
        "ore.reviewCommentInbox.\(workspaceID.rawValue)"
    }

    /// Clear one chip. The store and JSON file must lose it too, or the
    /// Review pane's one-second poll puts it right back.
    func removeDraftComment(at index: Int, from chatID: ChatID, in workspaceID: WorkspaceID) {
        let state = chat(for: chatID)
        guard state.draftComments.indices.contains(index) else { return }
        let removed = state.draftComments[index]
        state.removeDraftComment(at: index)
        rememberDismissed([removed], on: chatID)
        persistDraftComments(state.draftComments, for: chatID)
        Task { await client.send(.clearDiffComments(workspaceID, [removed])) }
    }

    func clearDraftComments(from chatID: ChatID, in workspaceID: WorkspaceID) {
        let state = chat(for: chatID)
        let removed = state.draftComments
        guard !removed.isEmpty else { return }
        state.clearDraftComments()
        rememberDismissed(removed, on: chatID)
        persistDraftComments([], for: chatID)
        Task { await client.send(.clearDiffComments(workspaceID, removed)) }
    }

    private func dismissedKeys(for chatID: ChatID) -> Set<String> {
        if let cached = dismissedCommentKeys[chatID] { return cached }
        let stored = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedCommentsKey(for: chatID)) ?? [])
        dismissedCommentKeys[chatID] = stored
        return stored
    }

    private func rememberDismissed(_ comments: [DiffCommentReference], on chatID: ChatID) {
        var keys = dismissedKeys(for: chatID)
        for comment in comments { keys.insert(comment.identityKey) }
        dismissedCommentKeys[chatID] = keys
        UserDefaults.standard.set(Array(keys), forKey: Self.dismissedCommentsKey(for: chatID))
    }

    private static func dismissedCommentsKey(for chatID: ChatID) -> String {
        "ore.dismissedDiffComments.\(chatID.rawValue)"
    }

    // MARK: - Scheduled continuation after usage limits

    private(set) var scheduledContinuations: [ChatID: ScheduledContinuation] = [:]
    private var continuationTasks: [ChatID: Task<Void, Never>] = [:]

    func scheduledContinuation(for chatID: ChatID?) -> ScheduledContinuation? {
        guard let chatID else { return nil }
        return scheduledContinuations[chatID]
    }

    func scheduleContinuation(
        workspaceID: WorkspaceID,
        chatID: ChatID,
        resumeAt: Date,
        prompt: String = ScheduledContinuation.defaultPrompt,
        retriesLastTurn: Bool = false
    ) {
        let item = ScheduledContinuation(
            workspaceID: workspaceID,
            chatID: chatID,
            resumeAt: resumeAt,
            prompt: prompt,
            retriesLastTurn: retriesLastTurn
        )
        scheduledContinuations[chatID] = item
        persistScheduledContinuations()
        arm(item)
        scheduleContinuationNotification(item)
    }

    func cancelScheduledContinuation(for chatID: ChatID) {
        continuationTasks[chatID]?.cancel()
        continuationTasks[chatID] = nil
        scheduledContinuations[chatID] = nil
        persistScheduledContinuations()
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.continuationNotificationID(for: chatID)])
    }

    private func restoreScheduledContinuations() {
        guard let data = UserDefaults.standard.data(forKey: "ore.scheduledContinuations"),
              let items = try? JSONDecoder().decode([ScheduledContinuation].self, from: data)
        else { return }
        for item in items {
            scheduledContinuations[item.chatID] = item
            arm(item)
        }
    }

    private func persistScheduledContinuations() {
        let items = Array(scheduledContinuations.values)
        if items.isEmpty {
            UserDefaults.standard.removeObject(forKey: "ore.scheduledContinuations")
        } else if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: "ore.scheduledContinuations")
        }
    }

    private func arm(_ item: ScheduledContinuation) {
        continuationTasks[item.chatID]?.cancel()
        continuationTasks[item.chatID] = Task { [weak self] in
            let delay = item.resumeAt.timeIntervalSinceNow
            if delay > 0 {
                // A short buffer so the provider has actually opened the window
                // before we send, rather than racing the reset second.
                try? await Task.sleep(for: .seconds(delay + 15))
            }
            guard !Task.isCancelled else { return }
            await self?.fireScheduledContinuation(item)
        }
    }

    private func fireScheduledContinuation(_ item: ScheduledContinuation) async {
        guard scheduledContinuations[item.chatID]?.resumeAt == item.resumeAt else { return }
        scheduledContinuations[item.chatID] = nil
        continuationTasks[item.chatID] = nil
        persistScheduledContinuations()
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.continuationNotificationID(for: item.chatID)])

        selectedWorkspaceID = item.workspaceID
        selectChat(item.chatID, in: item.workspaceID)
        showChatInCenter(item.workspaceID)
        NSApp.activate(ignoringOtherApps: true)
        if item.retriesLastTurn {
            retryLastTurn(in: item.workspaceID, chatID: item.chatID)
        } else {
            send(item.prompt, to: item.workspaceID, chatID: item.chatID)
        }
        postNotification(
            title: item.retriesLastTurn ? "Rate limit reset" : "Continuing \(workspaceName(item.workspaceID))",
            body: item.retriesLastTurn
                ? "Retrying your last message in \(workspaceName(item.workspaceID))."
                : "Session limit reset. Picking up where you left off.",
            workspaceID: item.workspaceID,
            chatID: item.chatID
        )
    }

    private func scheduleContinuationNotification(_ item: ScheduledContinuation) {
        let content = UNMutableNotificationContent()
        content.title = item.retriesLastTurn ? "Rate limit reset" : "Session limit reset"
        content.body = item.retriesLastTurn
            ? "Retrying \(workspaceName(item.workspaceID))."
            : "Continuing \(workspaceName(item.workspaceID)) where you left off."
        if UserDefaults.standard.object(forKey: "ore.notifications.sound") as? Bool ?? true {
            content.sound = .default
        }
        content.userInfo = [
            "workspaceID": item.workspaceID.rawValue,
            "chatID": item.chatID.rawValue,
        ]
        let interval = max(item.resumeAt.timeIntervalSinceNow + 15, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: Self.continuationNotificationID(for: item.chatID),
            content: content,
            trigger: trigger
        ))
    }

    private static func continuationNotificationID(for chatID: ChatID) -> String {
        "ore.continue.\(chatID.rawValue)"
    }

    func cycleChat(in workspaceID: WorkspaceID, offset: Int) {
        let tabs = chats(for: workspaceID)
        guard tabs.count > 1 else { return }
        let current = activeChat(for: workspaceID)?.id
        let index = tabs.firstIndex { $0.id == current } ?? 0
        let next = (index + offset + tabs.count) % tabs.count
        selectChat(tabs[next].id, in: workspaceID)
    }

    func archive(_ id: WorkspaceID) {
        Task { await client.send(.archiveWorkspace(id)) }
    }

    /// `ore.toml` scripts waiting for the user to read and allow them, oldest
    /// first. The main window asks about the first one.
    var pendingScriptApprovals: [RepositoryScriptsApproval] = []

    /// Ask about a workspace's scripts, replacing any older question about the
    /// same workspace.
    func requestScriptApproval(_ approval: RepositoryScriptsApproval) {
        pendingScriptApprovals.removeAll { $0.workspaceID == approval.workspaceID }
        pendingScriptApprovals.append(approval)
    }

    func approveRepositoryScripts(_ approval: RepositoryScriptsApproval) {
        pendingScriptApprovals.removeAll { $0 == approval }
        Task { await client.send(.approveRepositoryScripts(approval)) }
    }

    /// Declining is not purely local: the core may be holding this workspace's
    /// first message for the setup script that is now never going to run, and
    /// only the core can hand it back. Dismissing the dialog without telling it
    /// dropped that text silently.
    func declineRepositoryScripts(_ approval: RepositoryScriptsApproval) {
        pendingScriptApprovals.removeAll { $0 == approval }
        Task { await client.send(.declineRepositoryScripts(approval)) }
    }

    /// A workspace staged for the archive confirmation dialog. Confirming
    /// calls `archive(_:)`; the dialog explains what archiving preserves.
    struct PendingArchive: Identifiable {
        let workspace: WorkspaceSummary
        var id: WorkspaceID { workspace.id }
    }

    var pendingArchive: PendingArchive?

    /// Archive is reversible but disruptive (it stops the agent and removes
    /// the checkout), so it always goes through a confirmation.
    func requestArchive(_ id: WorkspaceID) {
        guard let workspace = workspaces.first(where: { $0.id == id }), !workspace.isArchived
        else { return }
        pendingArchive = PendingArchive(workspace: workspace)
    }

    /// An archived workspace staged for permanent deletion — the one archive
    /// action that cannot be undone.
    struct PendingArchivedDelete: Identifiable {
        let workspace: WorkspaceSummary
        var id: WorkspaceID { workspace.id }
    }

    var pendingArchivedDelete: PendingArchivedDelete?

    func requestPermanentDelete(_ workspace: WorkspaceSummary) {
        pendingArchivedDelete = PendingArchivedDelete(workspace: workspace)
    }

    /// A project staged for the delete confirmation dialog.
    struct PendingProjectDelete: Identifiable, Equatable {
        let repositoryPath: String
        /// Every workspace in it, archived ones included — all of them go.
        let workspaceCount: Int
        var id: String { repositoryPath }
        var name: String { URL(fileURLWithPath: repositoryPath).lastPathComponent }

        var confirmationMessage: String {
            let stopped = switch workspaceCount {
            case 0: "This removes the project from ORE."
            case 1: "This stops its workspace and removes it and its chats from ORE."
            default: "This stops all \(workspaceCount) of its workspaces and removes "
                + "them and their chats from ORE."
            }
            return stopped + " Move to Trash also sends the project folder and its "
                + "worktrees to the Trash, which frees the name for a new project "
                + "and keeps the files restorable."
        }
    }

    var pendingProjectDelete: PendingProjectDelete?

    func requestProjectDelete(_ repositoryPath: String) {
        pendingProjectDelete = PendingProjectDelete(
            repositoryPath: repositoryPath,
            workspaceCount: workspaces.filter { $0.repositoryPath == repositoryPath }.count
        )
    }

    /// Stops and removes every workspace in the project and forgets it. With
    /// `moveToTrash` its worktrees and folder go to the Trash, which frees the
    /// name for a new project and is still one drag away from undone.
    func deleteProject(_ repositoryPath: String, moveToTrash: Bool) {
        Task {
            await client.send(.deleteProject(
                repositoryPath: repositoryPath, moveToTrash: moveToTrash
            ))
            await refreshRepositories()
        }
    }

    func unarchive(_ id: WorkspaceID) {
        Task { await client.send(.unarchiveWorkspace(id)) }
    }

    func delete(_ id: WorkspaceID, deleteBranch: Bool) {
        Task { await client.send(.deleteWorkspace(id, deleteBranch: deleteBranch)) }
    }

    func rename(_ id: WorkspaceID, to name: String, userInitiated: Bool = true) {
        Task {
            await client.send(.renameWorkspace(id, name: name, userInitiated: userInitiated))
        }
    }

    func setPinned(_ pinned: Bool, for id: WorkspaceID) {
        Task { await client.send(.setWorkspacePinned(id, pinned: pinned)) }
    }

    /// After the PR merged: pull the default branch locally and restart this
    /// worktree on a fresh branch cut from it.
    func continueAfterMerge(_ id: WorkspaceID) {
        runGitOp(.continueAfterMerge, for: id) {
            await self.client.send(.continueAfterMerge(id))
        }
    }

    func pullDefaultBranch(_ id: WorkspaceID) {
        runGitOp(.pullDefaultBranch, for: id) {
            await self.client.send(.pullDefaultBranch(id))
        }
    }

    func gitOp(for id: WorkspaceID) -> GitOperation? {
        gitOpsInFlight[id]
    }

    func isGitOpInFlight(_ id: WorkspaceID) -> Bool {
        gitOpsInFlight[id] != nil
    }

    private func runGitOp(_ op: GitOperation, for id: WorkspaceID, _ work: @escaping () async -> Void) {
        guard gitOpsInFlight[id] == nil else { return }
        gitOpsInFlight[id] = op
        Task {
            await work()
            gitOpsInFlight[id] = nil
        }
    }

    /// The coloured toolbar button — Commit, Push, Create PR, Merge, and so on.
    /// `baseOverride` is the review pane's "into …" picker; the ⌥⌘G shortcut
    /// uses the suggested base.
    func performSuggestedGitAction(
        for workspace: WorkspaceSummary? = nil,
        baseOverride: String? = nil
    ) {
        guard let workspace = workspace ?? selectedWorkspace else { return }
        let action = cachedDiff(for: workspace.id)?.gitAction ?? .none
        switch action {
        case .merged:
            continueAfterMerge(workspace.id)
        case .createPullRequest(let defaultBase, let isStacked):
            createPullRequest(
                base: baseOverride ?? defaultBase,
                isStacked: isStacked,
                for: workspace
            )
        default:
            guard action.isActionable else { return }
            performGitAction(action, for: workspace)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            _ = try? await refreshDiff(for: workspace)
        }
    }

    /// The next step for a workspace, as last computed.
    func gitAction(for id: WorkspaceID) -> SuggestedGitAction {
        cachedDiff(for: id)?.gitAction ?? .none
    }

    /// The PR observed during the same state gather as `gitAction(for:)`.
    /// It remains available when local edits make Commit the immediate action.
    func pullRequest(for id: WorkspaceID) -> GitHubClient.PullRequest? {
        cachedDiff(for: id)?.pullRequest
    }

    var selectedGitAction: SuggestedGitAction {
        guard let id = selectedWorkspaceID else { return .none }
        return gitAction(for: id)
    }

    /// Whether ⌥⌘G has something to run. The actionable steps, plus the
    /// post-merge "start a fresh branch" state — `.merged` reports as
    /// non-actionable (it's a status, not a git command) but still has a
    /// keyboard path through `performSuggestedGitAction`.
    var canPerformSuggestedGitAction: Bool {
        if let id = selectedWorkspaceID, gitOpsInFlight[id] != nil { return false }
        if case .merged = selectedGitAction { return true }
        return selectedGitAction.isActionable
    }

    func performGitAction(_ action: SuggestedGitAction, for workspace: WorkspaceSummary) {
        if let prompt = action.agentDraftPrompt {
            placePromptInComposer(prompt, in: workspace.id)
            return
        }
        Task {
            switch action {
            case .commit, .createPullRequest:
                break
            case .createGitHubRepo:
                await client.send(.createGitHubRepo(workspace.id))
            case .push:
                await client.send(.push(workspace.id))
            case .retargetAfterParentMerged(let number, let base):
                guard let number else { return }
                await client.send(.retargetPullRequest(workspace.id, number: number, base: base))
            case .merge:
                let method = UserDefaults.standard.string(forKey: "ore.mergeMethod") ?? "squash"
                runGitOp(.merge, for: workspace.id) {
                    await self.client.send(.mergePullRequest(workspace.id, method: method))
                }
            case .fixFailingChecks:
                forwardFailingChecks(workspace.id)
            case .resolveConflicts(_, let base):
                send("Rebase onto `\(base)`, resolve all conflicts, and explain the resolution.", to: workspace.id)
            default:
                break
            }
        }
    }

    func submitCommit(message: String, for workspace: WorkspaceSummary) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await client.send(.commit(workspace.id, message: trimmed)) }
    }

    func submitPullRequest(
        title: String,
        body: String,
        base: String,
        draft: Bool,
        for workspace: WorkspaceSummary
    ) {
        runGitOp(.createPullRequest, for: workspace.id) {
            await self.client.send(.createPullRequest(
                workspace.id,
                title: title,
                body: body,
                base: base,
                draft: draft
            ))
        }
    }

    func submitMerge(method: String, for workspace: WorkspaceSummary) {
        UserDefaults.standard.set(method, forKey: "ore.mergeMethod")
        runGitOp(.merge, for: workspace.id) {
            await self.client.send(.mergePullRequest(workspace.id, method: method))
        }
    }

    func resolveConflict(path: String, side: ConflictSide, in workspaceID: WorkspaceID) {
        Task { await client.send(.resolveConflict(workspaceID, path: path, side: side.rawValue)) }
    }

    func resolveConflictHunk(
        path: String,
        startLine: Int,
        side: ConflictSide,
        in workspaceID: WorkspaceID
    ) {
        Task {
            await client.send(.resolveConflictHunk(
                workspaceID, path: path, startLine: startLine, side: side.rawValue
            ))
        }
    }

    func rerunFailedChecks(_ id: WorkspaceID) {
        Task { await client.send(.rerunFailedChecks(id)) }
    }

    func retryLastTurn(in workspaceID: WorkspaceID, chatID: ChatID? = nil) {
        guard let chatID = chatID ?? activeChat(for: workspaceID)?.id else { return }
        let state = chat(for: chatID)
        guard let row = state.rows.last(where: { $0.kind == .userMessage }) else { return }
        state.dismissProminentError()
        send(row.text, attachments: row.attachments, to: workspaceID, chatID: chatID)
    }

    func openFromNotification(workspaceID: String?, chatID: String?, openDreams: Bool = false) {
        if openDreams {
            pendingDreamsOpen = true
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if let workspaceID {
            selectedWorkspaceID = WorkspaceID(rawValue: workspaceID)
            showChatInCenter(WorkspaceID(rawValue: workspaceID))
        }
        if let workspaceID, let chatID {
            selectChat(ChatID(rawValue: chatID), in: WorkspaceID(rawValue: workspaceID))
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func markAllNotificationsRead() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().setBadgeCount(0)
    }

    /// Open a PR against a user-chosen base branch (the review pane's picker),
    /// rather than the workspace's default base.
    func createPullRequest(base: String, isStacked: Bool = false, for workspace: WorkspaceSummary) {
        placePromptInComposer(
            GitShipPrompt.pullRequest(base: base, isStacked: isStacked),
            in: workspace.id
        )
    }

    /// Drops a shipping prompt into an idle composer so the user can edit and send.
    ///
    /// Tab choice: the selected chat if it's idle and empty; otherwise any idle
    /// empty tab (newest first); otherwise a new tab. Never interrupts a running
    /// turn or overwrites a draft the user is still writing.
    func placePromptInComposer(_ text: String, in workspaceID: WorkspaceID) {
        showChatInCenter(workspaceID)
        if let chat = ComposerPlacement.target(
            active: activeChat(for: workspaceID),
            open: chats(for: workspaceID),
            isOccupied: composerIsOccupied
        ) {
            selectChat(chat.id, in: workspaceID)
            injectComposerText(text, into: chat)
            return
        }
        createChat(in: workspaceID, draft: text)
    }

    private func composerIsOccupied(_ chat: ChatSummary) -> Bool {
        chat.status.occupiesComposer
            || chat.queuedMessageCount > 0
            // Loaded state only: a tab with none has no local turn running, and
            // creating one here loaded every open tab's history.
            || chatStates[chat.id]?.isBusy == true
    }

    /// Marks an injection as taken by the composer it was meant for.
    ///
    /// An injection exists to reach a composer that may not be on screen yet.
    /// Once one has applied it, the text lives in that chat's draft like
    /// anything typed — and leaving the injection set made every later visit to
    /// the tab put the same text back: the Rebase button's prompt reappearing
    /// in the composer long after the rebase was done.
    func consumeComposerInjection(_ generation: UInt64) {
        guard composerInjection?.generation == generation else { return }
        composerInjection = nil
    }

    private func injectComposerText(_ text: String, into chat: ChatSummary) {
        setDraft(text, for: chat)
        composerInjectionGeneration += 1
        composerInjection = ComposerInjection(
            chatID: chat.id,
            text: text,
            generation: composerInjectionGeneration
        )
    }

    // MARK: - Assistant composer actions
    //
    // The assistant drives the composer the way the user does — staging text and
    // file tags for review, never sending on its own. Each reveals the tab first
    // so the change happens in front of the user, then reuses the same injection
    // and attachment persistence the composer's own gestures use.

    /// Stage (or extend) a tab's draft text on the assistant's behalf.
    private func applyAssistantComposerDraft(
        _ workspaceID: WorkspaceID, _ chatID: ChatID, text: String, append: Bool
    ) {
        guard let summary = chatSummaries.first(where: { $0.id == chatID }) else { return }
        reveal(workspaceID: workspaceID, chatID: chatID)
        let next: String
        if append {
            let existing = pendingDrafts[chatID]?.1 ?? summary.draftText
            next = existing.isEmpty
                ? text
                : existing + (existing.hasSuffix("\n") ? "" : "\n") + text
        } else {
            next = text
        }
        injectComposerText(next, into: summary)
    }

    /// Tag a workspace file onto a tab's composer, deduped by path.
    private func applyAssistantComposerTag(
        _ workspaceID: WorkspaceID, _ chatID: ChatID, relativePath: String, displayName: String
    ) {
        reveal(workspaceID: workspaceID, chatID: chatID)
        let current = chat(for: chatID).draftAttachments
        guard !current.contains(where: { $0.relativePath == relativePath }) else { return }
        persistDraftAttachments(
            current + [Attachment(relativePath: relativePath, displayName: displayName)],
            for: chatID
        )
    }

    /// Drop one tagged file, matched by exact path, trailing path, or name.
    private func applyAssistantComposerUntag(
        _ workspaceID: WorkspaceID, _ chatID: ChatID, reference: String
    ) {
        reveal(workspaceID: workspaceID, chatID: chatID)
        let current = chat(for: chatID).draftAttachments
        let next = current.filter { attachment in
            let matches = attachment.relativePath == reference
                || attachment.displayName == reference
                || attachment.relativePath.hasSuffix("/" + reference)
            if matches { deleteCopiedAttachment(attachment, in: workspaceID) }
            return !matches
        }
        guard next.count != current.count else { return }
        persistDraftAttachments(next, for: chatID)
    }

    /// Clear every tagged file — and optionally the draft — from a tab.
    private func applyAssistantComposerClear(
        _ workspaceID: WorkspaceID, _ chatID: ChatID, clearDraft: Bool
    ) {
        reveal(workspaceID: workspaceID, chatID: chatID)
        for attachment in chat(for: chatID).draftAttachments {
            deleteCopiedAttachment(attachment, in: workspaceID)
        }
        persistDraftAttachments([], for: chatID)
        if clearDraft, let summary = chatSummaries.first(where: { $0.id == chatID }) {
            injectComposerText("", into: summary)
        }
    }

    /// Open a file tab the way the Review pane does: reveal the workspace, then
    /// honour `mode` (or the path's usual view), and a line jump always uses source.
    private func applyAssistantOpenFile(
        _ workspaceID: WorkspaceID, path: String, mode: String?, line: Int?
    ) {
        reveal(workspaceID: workspaceID)
        if let line {
            openSourceFile(path, in: workspaceID, line: line)
            return
        }
        let presentation = mode.flatMap(FilePresentationMode.init(rawValue:))
            ?? FilePresentationMode.preferred(forPath: path)
        openFile(path, in: workspaceID, mode: presentation)
    }

    /// Delete only ORE's own copies (pasted images, dropped files under
    /// `.context/attachments/`) — a chip pointing at a file that already lived in
    /// the workspace is just a reference, and removing the tag must not delete it.
    /// Mirrors `ChatPane.deleteCopiedFile`.
    private func deleteCopiedAttachment(_ attachment: Attachment, in workspaceID: WorkspaceID) {
        guard attachment.relativePath.hasPrefix(".context/attachments/"),
              !attachment.relativePath.contains(".."),
              let worktreePath = workspaces.first(where: { $0.id == workspaceID })?.worktreePath
        else { return }
        try? FileManager.default.removeItem(
            at: attachment.fileURL(worktreePath: worktreePath)
        )
    }

    func remoteBranches(for id: WorkspaceID) async -> [String] {
        await client.remoteBranches(workspaceID: id)
    }

    func pullRequestURL(for id: WorkspaceID) async -> String? {
        await client.pullRequestURL(workspaceID: id)
    }

    func forwardFailingChecks(_ id: WorkspaceID) {
        Task {
            do { try await client.forwardFailingChecks(workspaceID: id) }
            catch { show(error) }
        }
    }

    // MARK: - Direct reads

    // These throw rather than swallowing into `[]` / `.none`: a failed git read
    // is not "no changes", and reporting it as such is how a real diff ended up
    // labelled "No changes". The caller decides how to surface the failure.
    func loadDiff(for id: WorkspaceID) async throws -> [FileDiff] {
        try await client.diff(workspaceID: id, againstBase: true)
    }

    func loadGitStatus(for id: WorkspaceID) async throws -> SuggestedGitStatus {
        try await client.suggestedGitStatus(workspaceID: id)
    }

    func loadUnpushedCommits(for id: WorkspaceID) async -> [CommitInfo] {
        (try? await client.unpushedCommits(workspaceID: id)) ?? []
    }

    func loadWorkingTreeStatus(for id: WorkspaceID) async -> GitStatusSnapshot? {
        await client.workingTreeStatus(workspaceID: id)
    }

    func loadPullRequestStatus(for id: WorkspaceID) async -> GitHubClient.PullRequest? {
        try? await client.pullRequestStatus(workspaceID: id)
    }

    func loadConflictHunks(path: String, for id: WorkspaceID) async -> [ConflictHunk] {
        (try? await client.conflictHunks(workspaceID: id, path: path)) ?? []
    }

    func loadTurnCheckpoints(for id: WorkspaceID) async -> [TurnCheckpoint] {
        guard let chatID = activeChat(for: id)?.id else { return [] }
        return (try? await client.turnCheckpoints(workspaceID: id, chatID: chatID)) ?? []
    }

    /// Sidebar snippets by workspace, stamped with the `lastActivity` they were
    /// read at. A List row that scrolls out and back in is a fresh view with
    /// empty state; without this every return restarted the IPC read, and the
    /// row grew its second line a beat after it appeared.
    private struct TurnDigestEntry {
        var lastActivity: Date?
        var digest: String?
    }
    @ObservationIgnored
    private var turnDigests: [WorkspaceID: TurnDigestEntry] = [:]

    /// The snippet already read for this activity stamp, if there is one.
    /// `.some(nil)` means "read, and there was nothing to show".
    func cachedTurnDigest(for id: WorkspaceID, lastActivity: Date?) -> String?? {
        guard let entry = turnDigests[id], entry.lastActivity == lastActivity else { return nil }
        return .some(entry.digest)
    }

    /// The sidebar row's snippet: the last thing said in the workspace's most
    /// recently active conversation, flattened to one line. Nil when nothing
    /// has been said yet, so a fresh workspace's row stays one line tall.
    ///
    /// Only goes to the core when `lastActivity` moved since the last read —
    /// i.e. once per completed turn, not once per appearance.
    func lastTurnDigest(for id: WorkspaceID, lastActivity: Date?) async -> String? {
        if let cached = cachedTurnDigest(for: id, lastActivity: lastActivity) { return cached }
        let recent = chats(for: id).max {
            ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast)
        }
        guard let chatID = recent?.id else { return nil }
        guard let digest = try? await client.lastTurnDigest(workspaceID: id, chatID: chatID) else {
            // A failed read is not cached: the next appearance tries again.
            return nil
        }
        let flattened = digest
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let result = flattened.isEmpty ? nil : String(flattened.prefix(160))
        // A workspace removed while the read was in flight stays forgotten.
        if workspaces.contains(where: { $0.id == id }) {
            turnDigests[id] = TurnDigestEntry(lastActivity: lastActivity, digest: result)
        }
        return result
    }

    func loadDiffFromCheckpoint(_ commit: String, for id: WorkspaceID) async throws -> [FileDiff] {
        try await client.diffFromCheckpoint(workspaceID: id, commit: commit)
    }

    func loadDiffBetweenCheckpoints(
        from: String,
        to: String,
        for id: WorkspaceID
    ) async throws -> [FileDiff] {
        try await client.diffBetweenCheckpoints(workspaceID: id, from: from, to: to)
    }

    func loadCheckLog(named name: String, for id: WorkspaceID) async -> String? {
        await client.checkLog(workspaceID: id, named: name)
    }

    func loadStackNeighbors(for id: WorkspaceID) async -> (parent: WorkspaceSummary?, children: [WorkspaceSummary]) {
        (try? await client.stackNeighbors(workspaceID: id)) ?? (nil, [])
    }

    func localBranches(for id: WorkspaceID) async -> [String] {
        await client.localBranches(workspaceID: id)
    }

    func localBranches(repositoryPath: String) async -> [String] {
        await client.localBranches(repositoryPath: repositoryPath)
    }

    func githubIssues(repositoryPath: String) async -> [GitHubClient.IssueListItem] {
        (try? await client.githubIssues(repositoryPath: repositoryPath)) ?? []
    }

    func githubPullRequests(repositoryPath: String) async -> [GitHubClient.IssueListItem] {
        (try? await client.githubPullRequests(repositoryPath: repositoryPath)) ?? []
    }

    /// The last cached diff for a workspace, if any — used to paint the review
    /// pane instantly on switch before a fresh read completes.
    func cachedDiff(for id: WorkspaceID) -> DiffSnapshot? { diffCache.state(for: id).snapshot }

    /// Loads a workspace's diff and suggested git action together, caches the
    /// result, and returns it. The concurrent reads mean the review pane waits
    /// on the slower of the two rather than their sum.
    @discardableResult
    func refreshDiff(for workspace: WorkspaceSummary) async throws -> DiffSnapshot {
        // A write during either read belongs to the next refresh, not this
        // one. Otherwise the trailing prefetch mistakes old data for current.
        let generation = gitGeneration(for: workspace.id)
        let state = diffCache.state(for: workspace.id)
        async let diffs = loadDiff(for: workspace.id)
        async let gitStatus = loadGitStatus(for: workspace.id)
        let status = try await gitStatus
        let snapshot = DiffSnapshot(
            generation: generation,
            diffs: try await diffs,
            gitAction: status.action,
            pullRequest: status.pullRequest
        )
        // Reads race: the review pane refreshes on both workspace switch and
        // every git-status bump, and `prefetchDiff` runs more in the
        // background. They finish out of order, so an older read landing last
        // used to overwrite fresh changes with the empty diff from before the
        // agent wrote anything — the "Changes 0 even though files are
        // modified" that only showed up sometimes. The newest generation wins,
        // and a stale caller is handed the newer snapshot rather than its own.
        // Archive/removal may have released the cache during the reads. Do
        // not recreate it (or fill a state still held by an outgoing pane).
        guard diffCache.contains(state, for: workspace.id) else { return snapshot }
        state.store(snapshot)
        return state.snapshot ?? snapshot
    }

    /// Recomputes just the suggested git action, leaving the cached diff alone.
    ///
    /// Everything else here refreshes on the git-status generation, which only
    /// moves when the *worktree* does. Half of what the action depends on lives
    /// on GitHub: opening a PR, a review landing, CI going red, someone merging
    /// in a browser tab — none of which touch a local file, so none of which
    /// bump the generation. Without a trigger of its own the toolbar kept
    /// offering "Create pull request" for a PR that was already open, and the
    /// button did the one thing that could not work.
    ///
    /// Cheap enough to call on turn boundaries and workspace switches: it is one
    /// `gh pr view` and a `git status`, and it never refetches the diff.
    func refreshGitAction(for workspaceID: WorkspaceID) async {
        guard isBackgroundPollingEnabled else { return }
        guard let status = try? await loadGitStatus(for: workspaceID) else { return }
        guard var snapshot = cachedDiff(for: workspaceID) else { return }
        guard snapshot.gitAction != status.action
            || snapshot.pullRequest != status.pullRequest else { return }

        // A pull request appearing where there wasn't one is the value moment
        // ORE exists to produce, so it is worth counting accurately.
        //
        // Counted on the nil → non-nil transition rather than when the user
        // presses "Create pull request": a request that fails is not a pull
        // request, and counting the intent would inflate the single number
        // that says the product works. Reading it here also means a PR that
        // already existed when the workspace was first loaded is not counted,
        // because that path fills the snapshot in `refreshDiff` instead.
        if snapshot.pullRequest == nil, status.pullRequest != nil {
            telemetry.record(translator.pullRequestCreated())
        }

        snapshot.gitAction = status.action
        snapshot.pullRequest = status.pullRequest
        diffCache.state(for: workspaceID).store(snapshot)
    }

    /// Best-effort background warm-up of a workspace's diff so a later switch is
    /// instant. Skips work when the cache already matches the current git-status
    /// generation; failures are swallowed since the real refresh reports them.
    ///
    /// At most one read per workspace runs at a time. Requests landing while it
    /// does collapse into a single trailing read after a short debounce, so an
    /// agent writing files does not queue a `git diff` per write.
    func prefetchDiff(for workspace: WorkspaceSummary) {
        guard isBackgroundPollingEnabled, !workspace.isArchived else { return }
        if cachedDiff(for: workspace.id)?.generation == gitGeneration(for: workspace.id) { return }
        guard diffPrefetches.request(workspace.id) else { return }
        Task(priority: .utility) { [weak self] in
            await self?.runDiffPrefetch(for: workspace.id)
        }
    }

    /// Only call after `diffPrefetches.request` returned true.
    private func runDiffPrefetch(for id: WorkspaceID) async {
        repeat {
            guard isBackgroundPollingEnabled else {
                diffPrefetches.cancel(id)
                return
            }
            let generation = gitGeneration(for: id)
            if cachedDiff(for: id)?.generation != generation,
               var stamped = workspaces.first(where: { $0.id == id })
                ?? (assistantWorkspace?.id == id ? assistantWorkspace : nil),
               !stamped.isArchived {
                stamped.gitStatus.generation = generation
                _ = try? await refreshDiff(for: stamped)
            }
        } while await shouldRunTrailingDiffPrefetch(for: id)
    }

    private func shouldRunTrailingDiffPrefetch(for id: WorkspaceID) async -> Bool {
        guard diffPrefetches.finish(id) else { return false }
        try? await Task.sleep(for: Self.diffPrefetchDebounce)
        return true
    }

    /// Warms the transcript for a workspace's active chat so its centre column
    /// shows history immediately on switch instead of the empty state. Reading
    /// the `ChatState` is enough — it kicks off `loadHistory` on first access.
    func prefetchHistory(for workspaceID: WorkspaceID) {
        guard let chatID = activeChatIDs[workspaceID] else { return }
        if let state = chatStates[chatID], state.hasLoadedHistory { return }
        _ = chat(for: chatID)
    }

    /// Warms diffs and transcripts shortly after the fleet loads, so navigating
    /// between worktrees feels instant rather than cold.
    ///
    /// Once per launch, the selected workspace first, then the rest one at a
    /// time: warming everything at once put a `git diff`, a PR lookup and a
    /// full history load per workspace on the machine in the same second, and
    /// did it again on every snapshot.
    private func warmWorkspaces() {
        // A snapshot with no workspaces yet does not use up the one warm-up.
        guard !didWarmWorkspaces, !workspaces.isEmpty else { return }
        didWarmWorkspaces = true
        if let selected = selectedWorkspace {
            prefetchDiff(for: selected)
            prefetchHistory(for: selected.id)
        }
        let others = sortedWorkspaces.map(\.id).filter { $0 != selectedWorkspaceID }
        guard !others.isEmpty else { return }
        Task(priority: .utility) { [weak self] in
            for id in others {
                guard let self else { return }
                await self.warmHistory(for: id)
                guard self.diffPrefetches.request(id) else { continue }
                await self.runDiffPrefetch(for: id)
            }
        }
    }

    private func warmHistory(for workspaceID: WorkspaceID) async {
        guard let chatID = activeChatIDs[workspaceID] else { return }
        if let state = chatStates[chatID], state.hasLoadedHistory { return }
        await loadHistory(for: chatID)
    }

    func addDiffComment(_ reference: DiffCommentReference, for id: WorkspaceID) {
        let state = chat(for: id)
        state.addDraftComment(reference)
        if let chatID = activeChat(for: id)?.id {
            var keys = dismissedKeys(for: chatID)
            if keys.remove(reference.identityKey) != nil {
                dismissedCommentKeys[chatID] = keys
                UserDefaults.standard.set(Array(keys), forKey: Self.dismissedCommentsKey(for: chatID))
            }
            persistDraftComments(state.draftComments, for: chatID)
        }
        Task { await client.send(.addDiffComment(id, reference)) }
    }

    func loadViewedFiles(for id: WorkspaceID) async -> [String: String] {
        (try? await client.viewedFiles(workspaceID: id)) ?? [:]
    }

    func markViewed(_ path: String, hash: String?, for id: WorkspaceID) {
        Task { await client.send(.markFileViewed(id, path: path, contentHash: hash)) }
    }

    func queuedMessages(for chatID: ChatID) async -> [QueuedMessageRecord] {
        (try? await client.queuedMessages(chatID: chatID)) ?? []
    }

    /// Edits a queued message, and the transcript row that is showing it.
    ///
    /// The row is the same message — it was drawn the moment the user pressed
    /// send — so leaving it on the original text means the transcript shows
    /// one thing and the agent is handed another.
    func updateQueuedMessage(_ record: QueuedMessageRecord, text: String) async throws {
        guard let id = record.id else { return }
        try await client.updateQueuedMessage(id: id, text: text)
        guard !record.submissionID.isEmpty, let chatID = record.chatID else { return }
        chat(for: ChatID(rawValue: chatID))
            .updateQueuedRow(submissionID: record.submissionID, text: text)
    }

    func deleteQueuedMessage(_ record: QueuedMessageRecord) async throws {
        guard let id = record.id else { return }
        try await client.deleteQueuedMessage(id: id)
        // Retire the row too. A deleted message that stays in the transcript
        // marked "queued" is not just cosmetic: it is what the next turn to
        // start would otherwise claim as the message that was sent.
        if !record.submissionID.isEmpty, let chatID = record.chatID {
            chat(for: ChatID(rawValue: chatID)).removeQueuedRow(submissionID: record.submissionID)
        }
        if let chat = chats(for: WorkspaceID(rawValue: record.workspaceID), includeClosed: true)
            .first(where: { $0.id.rawValue == record.chatID }) {
            var updated = chat
            updated.queuedMessageCount = max(0, updated.queuedMessageCount - 1)
            upsertChat(updated)
        }
    }

    func moveQueuedMessage(_ record: QueuedMessageRecord, direction: Int) async throws {
        guard let id = record.id else { return }
        try await client.moveQueuedMessage(id: id, direction: direction)
    }

    func search(_ query: String) async -> [SearchResult] {
        guard let hits = try? await client.search(query) else { return [] }
        return hits.map {
            SearchResult(
                workspaceID: $0.workspaceID,
                workspaceName: $0.workspaceName,
                snippet: $0.snippet
            )
        }
    }

    func workspaceEnvironment(
        for id: WorkspaceID
    ) async -> InProcessCoreClient.WorkspaceEnvironment? {
        try? await client.workspaceEnvironment(workspaceID: id)
    }

    func refreshRepositories() async {
        repositories = ((try? await client.repositories()) ?? []).map(\.path)
    }

    func githubStatus() async -> GitHubClient.Status {
        await GitHubClient(repositoryURL: OreHome.directory).status()
    }

    func githubRepositories() async throws -> [GitHubClient.Repository] {
        try await GitHubClient(repositoryURL: OreHome.directory).repositories()
    }

    func authenticateGitHub() async throws {
        try await GitHubClient(repositoryURL: OreHome.directory).authenticate()
    }

    /// Clones into ORE's repository library using owner/name folders, which
    /// avoids collisions between identically named projects from two owners.
    /// The canonical clone is registered with core before this returns, so the
    /// caller can immediately create its first worktree.
    func cloneGitHubRepository(_ reference: String) async throws -> String {
        let value = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let identity = Self.githubIdentity(from: value) else {
            throw GitHubRepositoryInputError.invalidReference
        }
        let destination = OreHome.directory
            .appendingPathComponent("repositories", isDirectory: true)
            .appendingPathComponent(identity.owner, isDirectory: true)
            .appendingPathComponent(identity.name, isDirectory: true)

        if FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(".git").path
        ) {
            await client.send(.addRepository(path: destination.path))
            await refreshRepositories()
            return destination.path
        }

        try await GitHubClient(repositoryURL: OreHome.directory)
            .clone(repository: value, to: destination)
        await client.send(.addRepository(path: destination.path))
        await refreshRepositories()
        return destination.path
    }

    private nonisolated static func githubIdentity(from reference: String) -> (owner: String, name: String)? {
        var value = reference
        if let url = URL(string: value), url.host?.contains("github.com") == true {
            value = url.path
        } else if value.hasPrefix("git@github.com:") {
            value.removeFirst("git@github.com:".count)
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if value.hasSuffix(".git") { value.removeLast(4) }
        let parts = value.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        return (parts[0], parts[1])
    }

    /// Whether a refresh is in flight.
    ///
    /// A probe spawns a login shell per harness and the update check goes to
    /// the network, so the whole thing can take half a minute. There was no
    /// sign of that anywhere: Refresh looked inert and people pressed it
    /// repeatedly, queueing the work they were waiting on.
    private(set) var isRefreshingHarnesses = false

    /// Re-detect the installed CLIs and re-ask their channels what's published.
    /// Both, because a user pressing Refresh is asking about right now — and
    /// the check runs second so it compares against the versions just probed.
    func refreshHarnesses() {
        guard !isRefreshingHarnesses else { return }
        isRefreshingHarnesses = true
        Task {
            defer { isRefreshingHarnesses = false }
            await client.send(.probeHarnesses)
            await client.send(.checkHarnessUpdates(force: true))
        }
    }

    /// How long an activation re-probe stays suppressed after the last one.
    nonisolated static let activationProbeInterval: TimeInterval = 20

    /// Whether coming back to ORE should cost another probe.
    ///
    /// Activation fires on every window focus — click away to read the docs,
    /// click back, and that is two more — while a probe is a login shell per
    /// harness. `nil` means we have never probed on an activation, which is the
    /// one case that must always go through: it is the first cmd-tab back from
    /// the Terminal the user was told to install the CLI in.
    nonisolated static func shouldReprobe(now: Date, last: Date?) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= activationProbeInterval
    }

    /// Seeded at construction rather than left nil, because the first
    /// activation of a process is the app launching — and `start()` is already
    /// probing at that moment. Left nil, the launch itself tripped
    /// `shouldReprobe`'s "never probed" branch and bought a second probe, plus
    /// a PATH cache invalidation, while the first one was still in flight.
    @ObservationIgnored
    private var lastActivationProbe: Date? = Date()

    /// The other half of "copy the install command, run it in Terminal, cmd-tab
    /// back": until this, nothing on screen changed when they came back, because
    /// the harness probe only ran at launch and on an explicit Refresh — and the
    /// login-shell PATH behind it was snapshotted once per process.
    func refreshHarnessesOnActivation(now: Date = Date()) {
        // Nothing to find once an agent works. This exists to notice a CLI that
        // was installed or signed into while ORE was in the background, and a
        // user who already has a ready harness did not go and do that. It
        // matters because the probe is not cheap: an explicit Refresh discards
        // the login-shell PATH and re-probes every harness, so charging every
        // window focus for it would tax the steady-state user — who is most
        // users, nearly all the time — to serve the first ten minutes.
        guard !harnesses.contains(where: \.isReady) else { return }
        guard Self.shouldReprobe(now: now, last: lastActivationProbe) else { return }
        lastActivationProbe = now
        // Deliberately not `refreshHarnesses()`: that also forces a harness
        // update check, which is a network request. Coming back to a window is
        // not a reason to make one.
        Task { await client.send(.probeHarnesses) }
    }

    struct HarnessCLIUpdate: Equatable {
        var kind: HarnessKind
        var isRunning: Bool
        var error: String?
        /// Filled in for a failure the user can actually fix — a root-owned
        /// install — with commands matching how that CLI was installed.
        var repair: HarnessRepair?
    }
    private(set) var harnessCLIUpdate: HarnessCLIUpdate?

    /// Upgrade the chat's agent CLI, restart its session so the new binary
    /// is the one we spawn, then resend the last prompt.
    func updateHarnessCLI(for chat: ChatSummary) {
        Task {
            guard await runHarnessCLIUpdate(chat.harness) else { return }
            await client.send(.stopChatSession(chat.workspaceID, chat.id))
            retryLastTurn(in: chat.workspaceID, chatID: chat.id)
        }
    }

    /// Upgrade one agent CLI on its own — the update card's button, and the
    /// same path the assistant takes. Running sessions keep the binary they
    /// launched with; the next one they start picks up the new version.
    func updateHarnessCLI(_ kind: HarnessKind) {
        Task { _ = await runHarnessCLIUpdate(kind) }
    }

    /// Why an upgrade that exited zero did not actually change anything.
    ///
    /// For a self-updating CLI, ORE asks one oracle what is published (npm, a
    /// vendor endpoint) and a different one to install it (the CLI's own
    /// `update` subcommand). When those two disagree — the registry has moved
    /// and the CLI's updater has not caught up — the update reports success,
    /// the version does not move, and the card came back on the next check
    /// looking exactly as it did before. Pressing the button again was the only
    /// thing to do, and it did the same nothing.
    ///
    /// Returns nil when the version genuinely moved, when the channel no longer
    /// advertises a newer one, or when there was no version to compare.
    nonisolated static func noOpUpdateExplanation(
        kind: HarnessKind,
        before: String?,
        after: HarnessUpdateStatus?
    ) -> String? {
        guard let after, after.isUpdateAvailable else { return nil }
        guard let before, after.installedVersion == before else { return nil }
        return "\(kind.displayName) reported success but is still on \(before). "
            + "Its self-updater may be lagging the published version."
    }

    /// True when the upgrade landed. A failure is left on `harnessCLIUpdate`
    /// for whichever surface is showing it, rather than thrown away into a log.
    @discardableResult
    private func runHarnessCLIUpdate(_ kind: HarnessKind) async -> Bool {
        // What the card was offering before the upgrade ran, so the version can
        // be the oracle rather than the exit code. See `noOpUpdateExplanation`.
        let before = harnessUpdate(for: kind)?.installedVersion
        harnessCLIUpdate = HarnessCLIUpdate(kind: kind, isRunning: true, error: nil)
        do {
            try await client.updateHarnessCLI(kind)
            // The core's own post-update status, not `harnessUpdates`: the
            // event carrying it is still in flight on the app's stream.
            let after = await client.harnessUpdateStatus(kind)
            if let explanation = Self.noOpUpdateExplanation(
                kind: kind, before: before, after: after
            ) {
                harnessCLIUpdate = HarnessCLIUpdate(
                    kind: kind, isRunning: false, error: explanation
                )
                return false
            }
            harnessCLIUpdate = nil
            return true
        } catch {
            let message = error.localizedDescription
            harnessCLIUpdate = HarnessCLIUpdate(
                kind: kind, isRunning: false, error: message
            )
            // Only for the failure a command can fix, and only after it has
            // happened: working out the repair asks the shell where npm and
            // Homebrew keep their prefixes.
            if HarnessUpdateFailure.isPermissionProblem(message) {
                let repair = await client.harnessPermissionRepair(kind)
                // Still the same failure, and not superseded by a retry.
                if harnessCLIUpdate?.kind == kind, harnessCLIUpdate?.error == message {
                    harnessCLIUpdate?.repair = repair
                }
            }
            return false
        }
    }

    /// Harnesses with a published version newer than the installed one, minus
    /// the ones the user has already waved off at that exact version.
    var pendingHarnessUpdates: [HarnessUpdateStatus] {
        HarnessUpdatePrompting.pending(
            statuses: harnessUpdates,
            dismissed: dismissedHarnessUpdates
        )
    }

    /// The version of each harness the user has waved off, mirrored into
    /// `UserDefaults` so it survives a relaunch. Held here as well because a
    /// dismissal has to move the card out of the way immediately.
    private var dismissedHarnessUpdates: [HarnessKind: String] = AppModel.loadDismissedHarnessUpdates()

    func dismissHarnessUpdate(_ status: HarnessUpdateStatus) {
        guard let latest = status.latestVersion else { return }
        dismissedHarnessUpdates[status.kind] = latest
        UserDefaults.standard.set(latest, forKey: Self.dismissedHarnessUpdateKey(status.kind))
    }

    func harnessUpdate(for kind: HarnessKind) -> HarnessUpdateStatus? {
        harnessUpdates.first { $0.kind == kind }
    }

    private static func dismissedHarnessUpdateKey(_ kind: HarnessKind) -> String {
        "ore.harnessUpdate.dismissed.\(kind.rawValue)"
    }

    private static func loadDismissedHarnessUpdates() -> [HarnessKind: String] {
        var dismissed: [HarnessKind: String] = [:]
        for kind in HarnessKind.allCases {
            guard let version = UserDefaults.standard.string(
                forKey: dismissedHarnessUpdateKey(kind)
            ) else { continue }
            dismissed[kind] = version
        }
        return dismissed
    }

    /// How long a browser sign-in gets before ORE stops waiting on it.
    nonisolated static let harnessSignInTimeout: Duration = .seconds(180)

    /// The live sign-in child, so Cancel has something to kill. One at a time:
    /// Settings disables the button for every harness while one is running.
    @ObservationIgnored
    private var harnessSignIn: Process?
    @ObservationIgnored
    private var harnessSignInWasCancelled = false

    /// The verification URL the CLI printed, once it has printed one. Observed,
    /// because it arrives seconds after the button was pressed.
    private(set) var harnessAuthenticationURL: String?

    /// Starts the provider's own browser-based login. Credentials remain in
    /// the CLI's credential store; ORE only observes the process exit and then
    /// re-runs its readiness probe.
    ///
    /// Three things used to make this a trap. The child's output went to
    /// `/dev/null`, so the verification URL every one of these CLIs prints —
    /// the whole point, when the browser does not open by itself — was thrown
    /// away. Nothing bounded the wait, so a login the user abandoned left
    /// Settings on "Waiting for browser…" for the rest of the session. And
    /// nothing held the process, so there was nothing to cancel.
    func authenticateHarness(_ kind: HarnessKind) async throws {
        guard kind != .claudeCode else { throw HarnessAuthenticationError.interactiveOnly }
        guard let executable = harnesses.first(where: { $0.kind == kind })?.executablePath
        else { throw HarnessAuthenticationError.notInstalled(kind.displayName) }

        harnessAuthenticationURL = nil
        harnessSignInWasCancelled = false

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["login"]
        process.currentDirectoryURL = OreHome.directory
        // The login-shell environment, not ORE's own: a CLI launched from the
        // Dock inherits a PATH with none of nvm/mise/asdf on it, and several of
        // these logins shell out to node. The probes have always used this.
        process.environment = ShellEnvironment.childEnvironment()
        process.standardInput = FileHandle.nullDevice
        // One pipe for both: this is read for a URL to show the user, not
        // parsed, and which stream a CLI prints its login link on is its own
        // business.
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty,
                  let url = AppModel.firstURL(in: String(decoding: chunk, as: UTF8.self))
            else { return }
            Task { @MainActor in self?.harnessAuthenticationURL = url }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        harnessSignIn = process

        // Polled rather than a termination handler, because the deadline and
        // Cancel both have to be able to end the wait, not just the child.
        let deadline = ContinuousClock.now.advanced(by: Self.harnessSignInTimeout)
        while process.isRunning, !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        let abandoned = Task.isCancelled
        let timedOut = process.isRunning && !abandoned
        if process.isRunning { process.terminate() }

        harnessSignIn = nil
        output.fileHandleForReading.readabilityHandler = nil
        let cancelled = harnessSignInWasCancelled
        harnessSignInWasCancelled = false

        if timedOut {
            throw HarnessAuthenticationError.timedOut(HarnessSetup.signInCommand(for: kind))
        }
        if cancelled || abandoned { throw HarnessAuthenticationError.cancelled }
        let exitCode = process.terminationStatus
        guard exitCode == 0 else { throw HarnessAuthenticationError.failed(exitCode) }
        // Kept on a timeout — a link the user can still open is the best thing
        // left to offer — but a finished login has no use for it.
        harnessAuthenticationURL = nil
        await client.send(.probeHarnesses)
    }

    /// Stops a sign-in that is going nowhere.
    func cancelHarnessAuthentication() {
        guard let process = harnessSignIn else { return }
        harnessSignInWasCancelled = true
        harnessAuthenticationURL = nil
        process.terminate()
    }

    /// The first `https://` link in a chunk of CLI output.
    ///
    /// Deliberately crude: these CLIs print one line with one link on it, and
    /// anything cleverer would be guessing at three vendors' output formats.
    /// The surrounding punctuation is trimmed because a link in prose is as
    /// often as not wrapped in quotes or brackets.
    nonisolated static func firstURL(in output: String) -> String? {
        let punctuation = CharacterSet(charactersIn: "\"'<>()[]{},.;")
        for token in output.split(whereSeparator: { $0.isWhitespace }) {
            let trimmed = token.trimmingCharacters(in: punctuation)
            guard trimmed.hasPrefix("https://"), trimmed.count > "https://".count
            else { continue }
            return trimmed
        }
        return nil
    }

    func suggestedResearchIdentity() -> ResearchIdentity {
        let used = Set(workspaces.flatMap { workspace in
            [workspace.name, (workspace.worktreePath as NSString).lastPathComponent]
        })
        return ResearchIdentity.next(excluding: used)
    }

    /// Resolved identities, keyed by the inputs that decide them. The sidebar
    /// asks once per row per pass, and each answer was a defaults read plus a
    /// scan of the catalog. Entries are dropped wherever the saved slug is
    /// written, and a rename or moved worktree misses on its own.
    private struct ResolvedResearchIdentity {
        var name: String
        var worktreePath: String
        var identity: ResearchIdentity?
    }
    @ObservationIgnored
    private var researchIdentityCache: [WorkspaceID: ResolvedResearchIdentity] = [:]

    func researchIdentity(for workspace: WorkspaceSummary) -> ResearchIdentity? {
        if let cached = researchIdentityCache[workspace.id],
           cached.name == workspace.name,
           cached.worktreePath == workspace.worktreePath {
            return cached.identity
        }
        let identity = resolveResearchIdentity(for: workspace)
        researchIdentityCache[workspace.id] = ResolvedResearchIdentity(
            name: workspace.name,
            worktreePath: workspace.worktreePath,
            identity: identity
        )
        return identity
    }

    private func resolveResearchIdentity(for workspace: WorkspaceSummary) -> ResearchIdentity? {
        let key = "ore.researchIdentity.\(workspace.id.rawValue)"
        if let saved = UserDefaults.standard.string(forKey: key),
           let identity = ResearchIdentity.matching(nameOrSlug: saved) {
            return identity
        }
        let folder = (workspace.worktreePath as NSString).lastPathComponent
        return ResearchIdentity.matching(nameOrSlug: workspace.name)
            ?? ResearchIdentity.matching(nameOrSlug: folder)
    }

    // MARK: - Workspace files

    func workspaceFiles(for workspace: WorkspaceSummary) async -> [WorkspaceFileNode] {
        let root = workspace.worktreePath
        return await Task.detached(priority: .userInitiated) {
            Self.scanWorkspace(at: root)
        }.value
    }

    func fileContents(path: String, in workspace: WorkspaceSummary) async throws -> String {
        let root = workspace.worktreePath
        return try await Task.detached(priority: .userInitiated) {
            let url = try Self.safeFileURL(root: root, relativePath: path)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            guard values.isDirectory != true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            guard (values.fileSize ?? 0) <= 2_000_000 else {
                throw CocoaError(.fileReadTooLarge)
            }
            let data = try Data(contentsOf: url)
            guard !data.prefix(8_192).contains(0), let value = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            return value
        }.value
    }

    /// A file as it was at the workspace's merge base: how the review pane
    /// shows a deleted image, or the "before" of a replaced one.
    func baseFileData(path: String, in workspaceID: WorkspaceID) async -> Data? {
        try? await client.baseFileData(workspaceID: workspaceID, path: path)
    }

    func saveFileContents(_ contents: String, path: String, in workspace: WorkspaceSummary) async throws {
        let root = workspace.worktreePath
        try await Task.detached(priority: .userInitiated) {
            let url = try Self.safeFileURL(root: root, relativePath: path)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }

    /// Internal rather than private: the binary-file preview needs the same
    /// path-escape check before it reads an image off disk, and duplicating
    /// a traversal guard is how one of the copies ends up wrong.
    nonisolated static func safeFileURL(root: String, relativePath: String) throws -> URL {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
        let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard url.path == rootURL.path || url.path.hasPrefix(prefix) else {
            throw CocoaError(.fileReadNoPermission)
        }
        return url
    }

    private nonisolated static func scanWorkspace(at root: String) -> [WorkspaceFileNode] {
        let manager = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        let skipped = Set(["node_modules", ".build", "DerivedData", "Pods", ".swiftpm"])
        var visited = 0

        func children(of directory: URL, relativeBase: String) -> [WorkspaceFileNode] {
            guard visited < 6_000,
                  let urls = try? manager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: []
                  ) else { return [] }
            return urls.sorted { first, second in
                let firstDirectory = (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let secondDirectory = (try? second.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if firstDirectory != secondDirectory { return firstDirectory }
                return first.lastPathComponent.localizedStandardCompare(second.lastPathComponent) == .orderedAscending
            }.compactMap { url in
                guard visited < 6_000 else { return nil }
                visited += 1
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let isDirectory = values?.isDirectory == true
                let relative = relativeBase.isEmpty ? url.lastPathComponent : relativeBase + "/" + url.lastPathComponent
                if url.lastPathComponent == ".git", isDirectory { return nil }
                let nested = isDirectory && values?.isSymbolicLink != true && !skipped.contains(url.lastPathComponent)
                    ? children(of: url, relativeBase: relative)
                    : nil
                return WorkspaceFileNode(
                    path: relative,
                    name: url.lastPathComponent,
                    isDirectory: isDirectory,
                    children: nested
                )
            }
        }
        return children(of: rootURL, relativeBase: "")
    }

    struct SearchResult: Identifiable, Sendable {
        var id: String { workspaceID.rawValue + snippet }
        var workspaceID: WorkspaceID
        var workspaceName: String
        var snippet: String
    }

    // MARK: - Events

    private func apply(_ event: CoreEvent) {
        // One funnel for analytics: every core event passes through here exactly
        // once, so nothing has to be instrumented twice or kept in sync with
        // a second dispatch path. The translator decides what, if anything,
        // is worth reporting; most events produce nothing.
        for reportable in translator.observe(event) {
            telemetry.record(reportable)
        }
        switch event {
        case .snapshot(let snapshot):
            assistantWorkspace = snapshot.workspaces.first(where: \.isAssistant)
            dreamWorkspaces = snapshot.workspaces.filter(\.isDream)
            workspaces = snapshot.workspaces.filter(\.isStandard)
            for workspace in snapshot.workspaces {
                workspaceLive.seed(workspace)
            }
            chatSummaries = snapshot.chats
            chatIndex.replaceAll(snapshot.chats)
            // `workspaces` was assigned above, against the old chat lists.
            recomputeFleetActivity()
            chatOwners = Dictionary(
                snapshot.chats.map { ($0.id, $0.workspaceID) },
                uniquingKeysWith: { _, last in last }
            )
            harnesses = snapshot.harnesses
            if !snapshot.harnessUpdates.isEmpty { harnessUpdates = snapshot.harnessUpdates }
            // Priming, not observing: the fleet's state at launch is the
            // briefing's story, and the watcher must not narrate a night's
            // worth of drift as though it just happened.
            for workspace in workspaces { fleetWatcher.observe(workspace) }
            restoreActiveChats()
            adoptResearchIdentities()
            if selectedWorkspaceID == nil {
                if let saved = UserDefaults.standard.string(forKey: "ore.selectedWorkspace"),
                   sortedWorkspaces.contains(where: { $0.id.rawValue == saved }) {
                    selectedWorkspaceID = WorkspaceID(rawValue: saved)
                } else {
                    selectedWorkspaceID = sortedWorkspaces.first?.id
                }
            } else {
                repairWorkspaceSelection()
            }
            warmWorkspaces()

        case .workspaceAdded(let summary):
            workspaceLive.seed(summary)
            if summary.isAssistant {
                assistantWorkspace = summary
                break
            }
            if summary.isDream {
                upsertDream(summary)
                break
            }
            upsert(summary)
            rememberIdentityIfPresent(for: summary)
            selectedWorkspaceID = summary.id
            prefetchDiff(for: summary)

        case .workspaceUpdated(let summary):
            if summary.isAssistant {
                assistantWorkspace = summary
                break
            }
            if summary.isDream {
                upsertDream(summary)
                break
            }
            let wasArchived = workspaces.first { $0.id == summary.id }?.isArchived ?? false
            upsert(summary)
            identityRenamesInFlight.remove(summary.id)
            rememberIdentityIfPresent(for: summary)
            if summary.isArchived {
                if !wasArchived { releaseArchived(summary.id) }
                repairWorkspaceSelection()
            }

        case .workspaceRemoved(let id):
            workspaces.removeAll { $0.id == id }
            workspaceLive.remove(id)
            diffCache.remove(id)
            diffPrefetches.cancel(id)
            fleetWatcher.forget(id)
            let removed = Set(chatIndex.removeWorkspace(id))
                .union(chatSummaries.filter { $0.workspaceID == id }.map(\.id))
            chatSummaries.removeAll { $0.workspaceID == id }
            for chatID in removed { forget(chatID) }
            activeChatIDs.removeValue(forKey: id)
            openFilePaths.removeValue(forKey: id)
            activeFilePath.removeValue(forKey: id)
            filePresentationModes.removeValue(forKey: id)
            fileFocus.removeValue(forKey: id)
            pendingNewChatMessages.removeValue(forKey: id)
            pendingNewChatDrafts.removeValue(forKey: id)
            identityRenamesInFlight.remove(id)
            chatCreationsInFlight.remove(id)
            gitOpsInFlight[id] = nil
            // The workspace's terminals keep their PTYs and scrollback alive
            // for as long as the registry holds them, which outlived the
            // worktree they were running in.
            TerminalRegistry.shared.closeTerminal(for: id)
            for key in ["ore.activeChat", "ore.researchIdentity"] {
                UserDefaults.standard.removeObject(forKey: "\(key).\(id.rawValue)")
            }
            researchIdentityCache.removeValue(forKey: id)
            turnDigests.removeValue(forKey: id)
            if selectedWorkspaceID == id { selectedWorkspaceID = sortedWorkspaces.first?.id }
            dreamWorkspaces.removeAll { $0.id == id }

        case .dreamRunStateChanged(let run):
            if dreamInbox.run != run {
                var inbox = dreamInbox
                inbox.run = run
                dreamInbox = inbox
            }
            syncDreamMonitor()
            maybeNotifyDreamFinished(run)

        case .dreamTaskUpdated:
            break

        case .dreamFindingAdded(let finding):
            upsertDreamFinding(finding)

        case .dreamFindingUpdated(let finding):
            upsertDreamFinding(finding)

        case .dreamInboxUpdated(let inbox):
            if dreamInbox != inbox { dreamInbox = inbox }
            syncDreamMonitor()

        case .assistantConfirmationRequested(let confirmation):
            assistantConfirmations.append(confirmation)
            // Mid-voice-exchange the question is narrated so it can be
            // answered by voice; the notification covers the window being
            // closed and the user being elsewhere.
            voiceAssistant.confirmationArrived(confirmation)
            postNotification(
                title: "Assistant needs approval",
                body: confirmation.summary,
                workspaceID: confirmation.workspaceID,
                category: NotificationCategory.assistantConfirmation,
                extraInfo: ["confirmationID": confirmation.id]
            )

        case .assistantConfirmationResolved(let id):
            assistantConfirmations.removeAll { $0.id == id }

        case .assistantUIAction(let action):
            switch action {
            case .revealWorkspace(let id):
                reveal(workspaceID: id)
            case .revealChat(let id, let chatID):
                reveal(workspaceID: id, chatID: chatID)
            case .setComposerDraft(let id, let chatID, let text, let append):
                applyAssistantComposerDraft(id, chatID, text: text, append: append)
            case .tagComposerFile(let id, let chatID, let relativePath, let displayName):
                applyAssistantComposerTag(
                    id, chatID, relativePath: relativePath, displayName: displayName
                )
            case .untagComposerFile(let id, let chatID, let reference):
                applyAssistantComposerUntag(id, chatID, reference: reference)
            case .clearComposerTags(let id, let chatID, let clearDraft):
                applyAssistantComposerClear(id, chatID, clearDraft: clearDraft)
            case .openFile(let id, let path, let mode, let line):
                applyAssistantOpenFile(id, path: path, mode: mode, line: line)
            case .closeFile(let id, let path):
                reveal(workspaceID: id)
                closeDiffFile(path, in: id)
            case .respondToPlan(let id, let chatID, let approve, let feedback):
                respondToPlan(
                    chatID: chatID, workspaceID: id, approve: approve, feedback: feedback
                )
            case .handoffPlan(let id, let chatID):
                if case .proposal(let markdown, _) = chat(for: chatID).plan {
                    handoffPlan(markdown, in: id)
                }
            }

        case .promptSubmitted(let id, let chatID, let submission):
            noteOwner(id, of: chatID)
            chat(for: chatID).applyPromptSubmission(submission)

        case .agent(let id, let chatID, let agentEvent):
            noteOwner(id, of: chatID)
            // Deltas are buffered; everything else flushes them first so a
            // tool call can never appear above the text that introduced it.
            var coalescer = coalescers[chatID] ?? TextDeltaCoalescer()
            for flushed in coalescer.absorb(agentEvent) {
                applyToChat(workspaceID: id, chatID: chatID, event: flushed)
            }
            coalescers[chatID] = coalescer
            if coalescer.hasPendingDeltas { scheduleFlush() }
            // An agent that ends its turn by pushing and opening a PR leaves the
            // worktree byte-for-byte identical to how it started it, so nothing
            // else asks whether the next step changed.
            if case .turnCompleted = agentEvent {
                Task { [weak self] in await self?.refreshGitAction(for: id) }
            }

        case .chatAdded(let chat):
            chatCreationsInFlight.remove(chat.workspaceID)
            noteOwner(chat.workspaceID, of: chat.id)
            upsertChat(chat)
            if pendingReviewCommentInbox.remove(chat.workspaceID) != nil {
                rememberReviewInbox(chat.id, for: chat.workspaceID)
            }
            // Claim the ephemeral flag *by id* before anything else can react:
            // the title alone proved unreliable (the core may normalize it).
            let isEphemeral = pendingEphemeralWorkspaces.remove(chat.workspaceID) != nil
                || chat.title.hasPrefix(Self.ephemeralChatPrefix)
            if isEphemeral { ephemeralChatIDs.insert(chat.id) }
            adoptResearchChatTitles(in: chat.workspaceID)
            // The assistant opens side chats for itself mid-answer (see its
            // prompt), and following one would move the window — and the voice
            // — off the conversation the user is being answered in. It is moved
            // deliberately instead: by New Conversation, or by a compaction.
            // Ephemeral chats (the find bar's answers) are never focused: the
            // whole point is that no tab appears and the user stays put.
            if !isEphemeral {
                let isAssistantChat = chat.workspaceID == assistantWorkspace?.id
                let isDreamChat = dreamWorkspaces.contains { $0.id == chat.workspaceID }
                let shouldFocus: Bool
                if isDreamChat {
                    shouldFocus = false
                } else if isAssistantChat {
                    shouldFocus = assistantConversationsAwaitingFocus.remove(chat.workspaceID) != nil
                } else {
                    shouldFocus = true
                }
                if shouldFocus {
                    selectChat(chat.id, in: chat.workspaceID)
                }
            }
            if var pending = pendingNewChatMessages[chat.workspaceID], !pending.isEmpty {
                let message = pending.removeFirst()
                pendingNewChatMessages[chat.workspaceID] = pending.isEmpty ? nil : pending
                send(message, to: chat.workspaceID, chatID: chat.id)
            } else if var drafts = pendingNewChatDrafts[chat.workspaceID], !drafts.isEmpty {
                let text = drafts.removeFirst()
                pendingNewChatDrafts[chat.workspaceID] = drafts.isEmpty ? nil : drafts
                injectComposerText(text, into: chat)
            }

        case .chatUpdated(let chat):
            noteOwner(chat.workspaceID, of: chat.id)
            chatRenamesInFlight.remove(chat.id)
            let wasOpen = chatIndex.summary(for: chat.id).map { !$0.isClosed } ?? false
            // Neighbor is computed while the closed chat is still in the open
            // list. After `upsertChat` it is filtered out, and `.first` would
            // jump to the oldest remaining tab.
            let replacement: ChatID? = {
                guard chat.isClosed else { return nil }
                return TabCloseSelection.replacement(
                    closing: chat.id,
                    active: activeChat(for: chat.workspaceID)?.id,
                    open: chats(for: chat.workspaceID).map(\.id)
                )
            }()
            upsertChat(chat)
            if let replacement {
                selectChat(replacement, in: chat.workspaceID)
            }
            // A closed tab's transcript, buffers and asks are held until it is
            // reopened, which may be never; `chat(for:)` reloads them if it is.
            if chat.isClosed, wasOpen { release(chat.id) }

        case .assistantConversationCompacted(let id, _, let successor):
            // ORE retired the conversation the user was in, so following it is
            // the whole point — unlike `chatAdded`, this event only ever fires
            // for a seam ORE made itself.
            selectChat(successor, in: id)

        case .gitStatusChanged(let id, let status):
            let live = workspaceLive.state(for: id)
            guard status.generation >= live.gitGeneration else { return }
            live.apply(status)
            // The tree changed, so the cached diff is now stale. Only the
            // workspace on screen warms a fresh one here: every other worktree
            // an agent is writing to would otherwise run `git diff` on every
            // write, for a pane nobody is looking at. The rest refresh when
            // they are selected (`focusChanged`). `prefetchDiff` stamps the
            // generation on a copy, never on `workspaces[i].gitStatus`.
            if id == selectedWorkspaceID, let workspace = selectedWorkspace {
                prefetchDiff(for: workspace)
            }

        case .harnessProbeCompleted(let probes):
            harnesses = probes
            hasProbedHarnesses = true

        case .harnessUpdatesChecked(let statuses):
            harnessUpdates = statuses

        case .modelCatalogUpdated(let harness, let models):
            modelCatalog[harness] = models
            // A retired model leaves its pin behind: the id keeps going to the
            // CLI, which rejects it, while Settings shows "Agent default"
            // because it cannot find the id to display. A freshly answered
            // catalogue is the only place that verdict can be reached — see
            // `StaleModelPin`, which is why this is not in `defaultModelID`.
            let key = Self.defaultModelKey(for: harness)
            if StaleModelPin.isStale(UserDefaults.standard.string(forKey: key), in: models) {
                UserDefaults.standard.removeObject(forKey: key)
            }

        case .commandFailed(let failure):
            if let workspaceID = failure.workspaceID {
                chatCreationsInFlight.remove(workspaceID)
                pendingEphemeralWorkspaces.remove(workspaceID)
                gitOpsInFlight[workspaceID] = nil
            }
            banners.append(Banner(message: failure.message, detail: failure.detail))

        case .repositoryScriptsNeedApproval(let approval):
            requestScriptApproval(approval)
        }
    }

    func knownModels(for harness: HarnessKind) -> [AgentModel] {
        // Hoisted out of the `.codex` branch below: this is a switch
        // *expression*, and a branch of one may only be an expression.
        let codexEfforts = ["none", "low", "medium", "high", "xhigh"]
        let curated: [AgentModel] = switch harness {
        case .claudeCode:
            [
                AgentModel(id: "claude-fable-5", displayName: "Fable 5", description: "Highest capability for long-running agents", supportedReasoningEfforts: ["adaptive"]),
                AgentModel(id: "claude-opus-5", displayName: "Opus 5", description: "Complex agentic coding and enterprise work", supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
                AgentModel(id: "claude-opus-4-8[1m]", displayName: "Opus 4.8 · 1M", description: "Deep reasoning with long context", supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
                AgentModel(id: "claude-opus-4-7[1m]", displayName: "Opus 4.7 · 1M", description: "Previous Opus generation", supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
                AgentModel(id: "claude-opus-4-6[1m]", displayName: "Opus 4.6 · 1M", description: "Long-context Opus model", supportedReasoningEfforts: ["low", "medium", "high", "max"]),
                AgentModel(id: "claude-sonnet-5[1m]", displayName: "Sonnet 5 · 1M", description: "Fast frontier model for coding and agents", isDefault: true, supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
                AgentModel(id: "claude-sonnet-4-6[1m]", displayName: "Sonnet 4.6 · 1M", description: "Balanced long-context model", supportedReasoningEfforts: ["low", "medium", "high", "max"]),
                AgentModel(id: "claude-sonnet-4-6", displayName: "Sonnet 4.6", description: "Balanced speed and capability", supportedReasoningEfforts: ["low", "medium", "high", "max"]),
                AgentModel(id: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5", description: "Fastest Claude model"),
            ]
        case .codex:
            // Codex rejects `max` for current ChatGPT models — supported values
            // are none/low/medium/high/xhigh. Keep this ladder aligned with
            // `codex app-server` `model/list` so a stale fallback cannot ship an
            // effort the provider will 400 on.
            [
                AgentModel(id: "gpt-5.5", displayName: "GPT-5.5", description: "Frontier coding model", isDefault: true, supportedReasoningEfforts: codexEfforts, supportedServiceTiers: ["priority", "fast"]),
                AgentModel(id: "gpt-5.4", displayName: "GPT-5.4", description: "Previous frontier generation", supportedReasoningEfforts: codexEfforts, supportedServiceTiers: ["priority", "fast"]),
                AgentModel(id: "gpt-5.4-mini", displayName: "GPT-5.4-Mini", description: "Faster, lighter coding", supportedReasoningEfforts: codexEfforts),
                AgentModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", description: "Frontier capability for complex coding", supportedReasoningEfforts: codexEfforts, supportedServiceTiers: ["fast", "priority"]),
                AgentModel(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", description: "Balanced intelligence, speed, and cost", supportedReasoningEfforts: codexEfforts, supportedServiceTiers: ["fast", "priority"]),
                AgentModel(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna", description: "Fast, efficient agent work", supportedReasoningEfforts: codexEfforts, supportedServiceTiers: ["fast", "priority"]),
            ]
        case .cursorAgent:
            // Fallback only — the full catalogue comes from the CLI via
            // `CursorAgentHarness.discoverModels()` and merges in below. These
            // real ids keep the picker useful if discovery hasn't run yet.
            [
                AgentModel(id: "auto", displayName: "Auto", isDefault: true),
                AgentModel(id: "composer-2.5", displayName: "Composer 2.5"),
                AgentModel(id: "cursor-grok-4.6-high", displayName: "Cursor Grok 4.6"),
                AgentModel(id: "cursor-grok-4.5-high", displayName: "Cursor Grok 4.5"),
            ]
        }
        return AgentModelCatalog.merge(
            curated: curated,
            discovered: modelCatalog[harness] ?? []
        )
    }

    /// `ore.toml`'s `[agent] harness` for a repository, read once per path.
    ///
    /// `launchInputs` is evaluated from view bodies on every keystroke and
    /// `OreConfiguration.load` is a file read, so the answer is cached. A
    /// project's default agent is checked into the repository and moves about
    /// as often as its build script does; Settings rewrites the file from this
    /// same process and clears this when it does.
    @ObservationIgnored
    private var repositoryDefaultHarnesses: [String: HarnessKind?] = [:]

    func repositoryDefaultHarness(_ path: String) -> HarnessKind? {
        if let cached = repositoryDefaultHarnesses[path] { return cached }
        let resolved = OreConfiguration
            .load(repositoryPath: URL(fileURLWithPath: path))
            .defaultHarness
        // `updateValue`, not the subscript: the value type is itself optional,
        // and `dict[key] = nil` removes the entry — so "this repo has no
        // default" would be re-read from disk on every keystroke.
        repositoryDefaultHarnesses.updateValue(resolved, forKey: path)
        return resolved
    }

    /// Called after `ore.toml` is written from Settings.
    func forgetRepositoryDefaults() {
        repositoryDefaultHarnesses.removeAll()
    }

    /// The machine's side of "start work on this sentence".
    ///
    /// Lives here so the composer, the Advanced sheet and Start itself all
    /// read one resolution rather than three that drift apart.
    func launchInputs(
        instruction: String,
        harnessOverride: HarnessKind? = nil,
        modelOverride: String? = nil,
        repositoryOverride: String? = nil,
        wantsNewProject: Bool = false,
        localBranches: [String] = [],
        explicitBranch: String? = nil
    ) -> WorkspaceLaunchPlan.Inputs {
        WorkspaceLaunchPlan.Inputs(
            instruction: instruction,
            readyHarnesses: readyHarnesses,
            models: { [weak self] harness in
                (self?.knownModels(for: harness) ?? [])
                    .map { (id: $0.id, displayName: $0.displayName) }
            },
            repositories: repositories,
            recents: recentRepositories,
            current: currentRepositoryPath,
            localBranches: localBranches,
            harnessOverride: harnessOverride,
            modelOverride: modelOverride,
            repositoryOverride: repositoryOverride,
            wantsNewProject: wantsNewProject,
            explicitBranch: explicitBranch,
            repositoryDefaultHarness: { [weak self] path in
                self?.repositoryDefaultHarness(path) ?? nil
            }
        )
    }

    /// UserDefaults key for a harness's user-chosen default model.
    static func defaultModelKey(for harness: HarnessKind) -> String {
        "ore.defaultModel.\(harness.rawValue)"
    }

    /// Settings keys for the agent and model a new tab opens with, and for the
    /// Review button's own override. An empty stored value means "inherit", so
    /// nothing is pinned until the user actually picks something.
    enum DefaultKey {
        static let newChatHarness = "ore.defaultHarness"
        static let newChatModel = "ore.defaultModel"
        static let reviewHarness = "ore.review.harness"
        static let reviewModel = "ore.review.model"
    }

    /// The agent and model a chat starts with. Both are optional because either
    /// can be left to the core's own fallbacks.
    struct ChatDefaults: Equatable {
        var harness: HarnessKind?
        var model: String?
    }

    private static func pinned(_ key: String) -> String? {
        guard let value = UserDefaults.standard.string(forKey: key), !value.isEmpty else { return nil }
        return value
    }

    /// What the `+` button opens: the Settings pin if the user set one, else
    /// whatever the workspace is already using.
    func newChatDefaults(for workspaceID: WorkspaceID) -> ChatDefaults {
        let workspace = workspaces.first { $0.id == workspaceID }
        return resolveDefaults(
            harnessKey: DefaultKey.newChatHarness,
            modelKey: DefaultKey.newChatModel,
            inherited: ChatDefaults(harness: workspace?.harness, model: workspace?.model)
        )
    }

    /// What the Review button opens. Review pins fall back to the new-chat pins,
    /// which fall back to the workspace — one chain, so leaving review unset
    /// keeps it behaving exactly like any other new tab.
    func reviewDefaults(for workspaceID: WorkspaceID) -> ChatDefaults {
        resolveDefaults(
            harnessKey: DefaultKey.reviewHarness,
            modelKey: DefaultKey.reviewModel,
            inherited: newChatDefaults(for: workspaceID)
        )
    }

    private func resolveDefaults(
        harnessKey: String,
        modelKey: String,
        inherited: ChatDefaults
    ) -> ChatDefaults {
        let harness = Self.pinned(harnessKey).flatMap(HarnessKind.init(rawValue:)) ?? inherited.harness
        if let model = Self.pinned(modelKey) {
            return ChatDefaults(harness: harness, model: model)
        }
        // Switching agent invalidates the inherited model id — it names a model
        // in the other provider's catalogue, and handing it over is exactly what
        // produces "the selected model may not exist" once the agent starts.
        guard harness == inherited.harness else {
            return ChatDefaults(harness: harness, model: harness.flatMap { defaultModelID(for: $0) })
        }
        return ChatDefaults(harness: harness, model: inherited.model)
    }

    /// The default model id for a harness: the user's per-harness choice from
    /// Settings if set, else the catalogue's `isDefault` model. Drives the model
    /// chip's scroll-to-switch between harnesses.
    func defaultModelID(for harness: HarnessKind) -> String? {
        let key = Self.defaultModelKey(for: harness)
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            return saved
        }
        return knownModels(for: harness).first(where: \.isDefault)?.id
    }

    private func applyToChat(workspaceID: WorkspaceID, chatID: ChatID, event: AgentEvent) {
        chat(for: chatID).apply(event)
        if case .permissionRequest(let request) = event,
           let grant = workspaceAutoApprovals[workspaceID],
           grant.allows(request, in: workspaceID) {
            approveTimedWorkspaceRequest(request, workspaceID: workspaceID, chatID: chatID, grant: grant)
            return
        }
        if case .permissionRequest(let request) = event,
           UserDefaults.standard.bool(forKey: Self.automaticRoutinePermissionsKey),
           let workspace = workspaces.first(where: { $0.id == workspaceID })
                ?? (assistantWorkspace?.id == workspaceID ? assistantWorkspace : nil)
                ?? dreamWorkspaces.first(where: { $0.id == workspaceID }),
           let automatic = RoutinePermissionPolicy.automaticApproval(
               for: request, workspacePath: workspace.worktreePath
           ) {
            // Remove the card optimistically and answer the harness. Only the
            // positive-list policy above reaches here; uncertain or important
            // work continues through the ordinary needs-you surfaces. The
            // approval travels with the decision because this request never
            // becomes a card — the transcript is its only record.
            resolvePermission(
                request.id, decision: .allow, for: workspaceID,
                chatID: chatID, automatic: automatic
            )
            return
        }
        // The assistant never joins the ambient notification/narration funnel
        // — its voice is the voice mode: replies to spoken requests are read
        // aloud by the controller, and everything else stays quiet.
        guard assistantWorkspace?.id != workspaceID else {
            if case .turnCompleted(let result) = event {
                // Matched against the conversation each request was sent to,
                // not just "the assistant answered something". With more than
                // one assistant conversation a watch digest can be running in
                // one while the user's spoken question runs in another, and
                // whichever finishes first would otherwise be taken for both.
                if !assistantReplyWaiters.isEmpty, askAssistantChatID == chatID {
                    // Someone is waiting synchronously — Siri, Shortcuts, or
                    // Spotlight via an App Intent.
                    askAssistantChatID = nil
                    flushAssistantReplyWaiters(
                        with: NarrationPhraser.spokenNarration(
                            result.narration, limit: NarrationPolicy.assistantAnswerLimit
                        ) ?? "Done — the details are in ORE's Assistant window."
                    )
                } else if watchDigestChatID == chatID {
                    watchDigestChatID = nil
                    deliverWatchVerdict(result)
                }
                assistantRateLimitHandled = false
            }
            if let reason = AssistantFailoverPolicy.reason(for: event),
               !assistantRateLimitHandled,
               let current = chatIndex.summary(for: chatID)?.harness
                ?? assistantWorkspace?.harness,
               harnesses.contains(where: { $0.isReady && $0.kind != current }) {
                // Core performs the switch; this is only the spoken cue, and
                // only when another ready harness actually exists.
                assistantRateLimitHandled = true
                narration.speakAssistant(
                    AssistantFailoverPolicy.spokenHandoff(reason),
                    chatID: chatID
                )
            }
            voiceAssistant.observe(event, chatID: chatID)
            return
        }
        collectWatchEvent(event, workspaceID: workspaceID, chatID: chatID)
        if dreamWorkspaces.contains(where: { $0.id == workspaceID }) { return }
        let origin = narrationOrigin(workspaceID: workspaceID, chatID: chatID)
        // Needs-you events have two possible voice owners: ambient tab
        // narration, or the hands-free assistant flow that opens the mic for
        // the answer. Pick exactly one before either starts speaking; letting
        // both consume the event produced two back-to-back "quick checks".
        let assistantOwnsNarration: Bool
        switch event {
        case .permissionRequest(let request) where Self.isQuestionGate(request):
            // An AskUserQuestion gate is not an ask in its own right — it is
            // the channel the answer to the accompanying question travels
            // back through. Kept out of needs-you at intake, not merely
            // filtered by each surface, because every surface that shows it
            // offers Allow, and a bare Allow answers a question the user was
            // never shown. `ChatState.pendingPermission` still holds it, so
            // `answerQuestion` can route through it and retire it.
            assistantOwnsNarration = false
        case .permissionRequest(let request):
            assistantOwnsNarration = noteTabNeedsYou(.permission(TabNeedsYou.Permission(
                workspaceID: workspaceID, chatID: chatID, request: request
            )))
        case .question(let question):
            assistantOwnsNarration = noteTabNeedsYou(.question(TabNeedsYou.Question(
                workspaceID: workspaceID, chatID: chatID, question: question
            )))
        case .planUpdated(let update):
            assistantOwnsNarration = noteReadyPlan(
                update, workspaceID: workspaceID, chatID: chatID
            )
        default:
            assistantOwnsNarration = false
        }
        if !assistantOwnsNarration {
            narration.observe(event: event, chatID: chatID, origin: origin)
        }
        switch event {
        case .permissionResolved(let resolution):
            voiceAssistant.permissionResolved(resolution.id)
            // Resolved elsewhere — the assistant over MCP, or another window.
            // Retire the same set the local click would have.
            retireNeedsYou(resolving: resolution.id)
        case .toolCall(let call)
            where PlanProposalPolicy.proceedsPastProposal(call.name):
            removeNeedsYou {
                if case .plan(let item) = $0, item.chatID == chatID { return true }
                return false
            }
        case .turnStarted:
            removeNeedsYou {
                if case .plan(let item) = $0, item.chatID == chatID { return true }
                return false
            }
        case .turnCompleted:
            // Cursor's CreatePlan turn is already over when the plan is ready.
            // Dropping plan needs-you here would hide the ask.
            removeNeedsYou {
                switch $0 {
                case .permission(let item): return item.chatID == chatID
                case .question(let item): return item.chatID == chatID
                case .plan: return false
                }
            }
        default:
            break
        }
        let appInactive = !NSApp.isActive
        guard origin.isBackground || appInactive else { return }
        let place = origin.displayLabel ?? workspaceName(workspaceID)
        switch event {
        case .permissionRequest(let request) where Self.isQuestionGate(request):
            // The question itself notifies; its gate would be a second banner
            // for the same ask, offering Allow as the answer.
            break
        case .permissionRequest(let request):
            // "kailash — Run a command: curl -s https://…". The banner is the
            // only thing the user sees before deciding whether to come back,
            // so it names the act, not the tool's codename over the agent's
            // account of its own intent.
            let content = PermissionPresentation(request: request)
            var body = place + " — " + content.action
                + (content.target.map { ": \(PermissionPresentation.clip($0, to: 120))" } ?? "")
            if content.isAbbreviated {
                body += " — " + (content.hiddenLineSummary ?? "shortened")
                    + ". Open ORE to read it."
            }
            postNotification(
                title: "ORE needs you",
                body: body,
                workspaceID: workspaceID,
                chatID: chatID,
                // A banner that has clipped the command must not carry an
                // Allow button: the whole basis for deciding is the part
                // that did not fit. The plain banner still opens the chat.
                category: content.isAbbreviated ? nil : NotificationCategory.toolPermission,
                extraInfo: ["permissionID": request.id.rawValue]
            )
        case .question(let question):
            postNotification(
                title: "ORE needs you",
                body: place + " asks: \(question.prompt)",
                workspaceID: workspaceID,
                chatID: chatID,
                category: NotificationCategory.agentQuestion,
                extraInfo: ["questionID": question.id.rawValue]
            )
        case .planUpdated(let update):
            if case .proposal(let markdown, _) = update.content, update.isReady,
               PlanProposalPolicy.isReadyMarkdown(markdown) {
                postNotification(
                    title: "ORE needs you",
                    body: place + " has a plan ready.",
                    workspaceID: workspaceID,
                    chatID: chatID
                )
            }
        case .turnCompleted where UserDefaults.standard.object(forKey: "ore.notifications.turnComplete") as? Bool ?? true:
            postNotification(
                title: "Agent finished",
                body: place + " completed a turn.",
                workspaceID: workspaceID,
                chatID: chatID
            )
        default:
            break
        }
    }

    /// Whether a permission request is the hidden half of an AskUserQuestion.
    ///
    /// The user answers the question; ORE answers the gate on their behalf
    /// with what they said. Nothing may offer it as an Allow/Deny of its own.
    static func isQuestionGate(_ request: PermissionRequest) -> Bool {
        request.toolName == "AskUserQuestion"
    }

    /// `removeAll` on an observed array notifies even when nothing matched, and
    /// the per-event callers above match nothing almost every time.
    private func removeNeedsYou(where shouldRemove: (TabNeedsYou) -> Bool) {
        guard tabNeedsYou.contains(where: shouldRemove) else { return }
        tabNeedsYou.removeAll(where: shouldRemove)
    }

    @discardableResult
    private func noteTabNeedsYou(_ item: TabNeedsYou) -> Bool {
        let replacing = tabNeedsYou.contains { $0.id == item.id }
        tabNeedsYou.removeAll { $0.id == item.id }
        tabNeedsYou.append(item)
        // Same id (Claude linking a permission onto an already-ready plan)
        // must not speak again. Returning true still owns narration so the
        // engine's PlanReadinessGate is not the only thing preventing a
        // second "the plan is ready".
        if replacing { return true }
        let spokenByAssistant = voiceAssistant.needsYouArrived(item)
        informAssistantOfNeedsYou(item)
        return spokenByAssistant
    }

    /// Ready plans only. Drafts (`isReady: false`) and JSON debris stay off
    /// this list so the HUD cannot ask for approval of `}}`.
    @discardableResult
    private func noteReadyPlan(
        _ update: PlanUpdate,
        workspaceID: WorkspaceID,
        chatID: ChatID
    ) -> Bool {
        guard case .proposal(let markdown, let requestID) = update.content else { return false }
        guard let body = PlanProposalPolicy.normalizedMarkdown(markdown),
              update.isReady, PlanProposalPolicy.isReadyMarkdown(body)
        else { return false }
        return noteTabNeedsYou(.plan(TabNeedsYou.Plan(
            workspaceID: workspaceID,
            chatID: chatID,
            turnID: update.turnID,
            markdown: body,
            permissionRequestID: requestID
        )))
    }

    /// Approve or reject a ready plan from any surface (transcript card, HUD,
    /// menu bar, voice). Cursor has no permission id — those follow-ups are
    /// a new user turn. Claude's ExitPlanMode is the linked permission.
    func respondToPlan(
        chatID: ChatID,
        workspaceID: WorkspaceID,
        approve: Bool,
        feedback: String = ""
    ) {
        let chat = chat(for: chatID)
        let requestID: PermissionRequestID?
        if case .proposal(_, let id) = chat.plan {
            requestID = id
        } else if let item = tabNeedsYou.compactMap({
            if case .plan(let plan) = $0, plan.chatID == chatID { return plan }
            return nil
        }).last {
            requestID = item.permissionRequestID
        } else {
            requestID = nil
        }
        // The plan card owns pending review comments while it is visible. Drain
        // them into this decision before dismissing the card so they cannot be
        // stranded behind the now-restored composer.
        let comments = chat.takeDraftComments()
        persistDraftComments([], for: chatID)
        let note = PlanDecisionFeedback.combining(feedback, comments: comments)
        chat.dismissPlan()
        tabNeedsYou.removeAll {
            if case .plan(let item) = $0, item.chatID == chatID { return true }
            return false
        }
        if let requestID {
            resolvePermission(
                requestID,
                decision: approve
                    ? .allow
                    : .deny(reason: note.isEmpty ? "Revise the plan." : note),
                for: workspaceID,
                chatID: chatID
            )
            if approve { setPermissionMode(.default, for: workspaceID) }
            if approve, !note.isEmpty { send(note, to: workspaceID, chatID: chatID) }
            return
        }
        if approve { setPermissionMode(.default, for: workspaceID) }
        if approve {
            send(
                note.isEmpty ? "The user approved the plan. Implement it." : note,
                to: workspaceID,
                chatID: chatID
            )
        } else {
            send(
                note.isEmpty
                    ? "The user rejected the plan. Revise it."
                    : "The user rejected the plan: \(note)",
                to: workspaceID,
                chatID: chatID
            )
        }
    }

    /// Immediate, unlike the watch digest: the assistant may offer auto-allow
    /// but must not duplicate the HUD confirmation.
    private func informAssistantOfNeedsYou(_ item: TabNeedsYou) {
        guard proactiveWatchEnabled, let assistant = assistantWorkspace else { return }
        // Named, so the assistant can say "kailash" rather than inheriting the
        // anonymous "a tab" this notice used to hand it — it has no other way
        // to know where the ask came from, and it speaks what it is given.
        let ask = spokenPlace(for: item).map {
            NarrationPhraser.prefixed(item.spokenSummary, place: $0)
        } ?? item.spokenSummary
        send(
            """
            [ORE needs you] \(ask)
            The user is being asked via the HUD / a notification. Do not call \
            ResolveChatPermission or AnswerChatQuestion unless they tell you \
            to in this conversation. You MAY offer auto-allow for this tab.
            """,
            // Machine to machine, exactly like a digest: ORE wrote it, on an
            // event the user did not trigger, whether or not they are at the
            // keyboard. `.watch` keeps it out of the transcript, out of the
            // turn count, and out of any compaction summary.
            origin: .watch,
            to: assistant.id
        )
    }

    func autoAllowTab(workspaceID: WorkspaceID, chatID: ChatID, permissionID: PermissionRequestID?) {
        tabNeedsYou.removeAll {
            if case .permission(let item) = $0, item.chatID == chatID { return true }
            return false
        }
        // Every ordinary request the tab has open, not only the one clicked:
        // parallel tool calls ask at once, and a grant that answered one left
        // the harness blocked on the rest. Question and plan gates keep their
        // own cards — allowing those blindly would send back an empty answer.
        let state = chat(for: chatID)
        var allowed = state.pendingPermissions
            .filter { $0.toolName != "AskUserQuestion" && $0.toolName != "ExitPlanMode" }
            .map(\.id)
        if let permissionID, !allowed.contains(permissionID) {
            allowed.insert(permissionID, at: 0)
        }
        for id in allowed {
            // Authentication may take a moment; the user's click has already
            // answered these prompts, so silence them and retire the local
            // cards before proving the standing grant.
            voiceAssistant.permissionResolved(id)
            narration.cancelPermissionPrompt(id)
            state.resolvePermission(id)
        }
        Task { @MainActor in
            let proven = await Self.authenticateStandingGrant()
            for id in allowed {
                await client.send(.resolveChatPermission(
                    workspaceID, chatID, id, .allow
                ))
            }
            if proven {
                await client.send(.setChatPermissionMode(
                    workspaceID, chatID, .bypassPermissions
                ))
                try? await client.grantTabAutoAllow(chatID)
            }
        }
    }

    func revokeTabAutoAllow(_ chatID: ChatID) {
        Task { try? await client.revokeAssistantTabGrant(chatID) }
    }

    func revokeAssistantAlwaysGrant(_ actionClass: String) {
        Task { try? await client.revokeAssistantGrant(actionClass) }
    }

    /// Where a chat sits relative to what's on screen. "Background" covers two
    /// genuinely different situations — another workspace, or another tab of
    /// the workspace already open — and only the first is usefully named by
    /// the workspace. Announcing "over in ahmed-zewail" to someone already
    /// looking at ahmed-zewail tells them nothing and hides which tab it was.
    private func narrationOrigin(
        workspaceID: WorkspaceID,
        chatID: ChatID
    ) -> NarrationOrigin {
        let title = chatIndex.summary(for: chatID)?.title
        guard selectedWorkspaceID == workspaceID else {
            let name = workspaceName(workspaceID)
            // The title earns its place only when it says something the
            // workspace name doesn't.
            let distinct = title.flatMap {
                Self.isGenericChatTitle($0, workspaceName: name) ? nil : $0
            }
            return .otherWorkspace(name: name, chatTitle: distinct)
        }
        guard activeChatIDs[workspaceID] != chatID else { return .foreground }
        return .otherTab(chatTitle: title ?? "")
    }

    /// How to name a blocked tab out loud, or nil when it's the tab on screen.
    ///
    /// The same origin the ambient narration uses, so "kailash" is "kailash" in
    /// both — a spoken permission prompt naming the place differently from the
    /// line before it is the kind of seam a listener hears even when they
    /// can't say what changed.
    func spokenPlace(for item: TabNeedsYou) -> String? {
        narrationOrigin(workspaceID: item.workspaceID, chatID: item.chatID).spokenLabel
    }

    /// Drops everything keyed by a chat that no longer exists.
    ///
    /// Each of these is small, and each used to outlive its chat: a scheduled
    /// continuation would still fire against a deleted conversation, and the
    /// per-chat defaults accumulated one set of orphans per chat ever created.
    private func forget(_ chatID: ChatID) {
        release(chatID)
        narration.forget(chatID)
        translator.forget(chatID)
        // Observed: a removal that finds nothing would still notify readers.
        if ephemeralChatIDs.contains(chatID) { ephemeralChatIDs.remove(chatID) }
        chatRenamesInFlight.remove(chatID)
        continuationTasks.removeValue(forKey: chatID)?.cancel()
        scheduledContinuations.removeValue(forKey: chatID)
        persistScheduledContinuations()
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Self.continuationNotificationID(for: chatID)]
        )
        for key in [
            "ore.draftAttachments", "ore.draftComments",
            "ore.dismissedDiffComments", "ore.chatScroll",
            "ore.reasoningEffort", "ore.fastMode",
        ] {
            UserDefaults.standard.removeObject(forKey: "\(key).\(chatID.rawValue)")
        }
        for (workspaceID, inbox) in reviewCommentInbox where inbox == chatID {
            reviewCommentInbox[workspaceID] = nil
            UserDefaults.standard.removeObject(forKey: Self.reviewInboxKey(for: workspaceID))
        }
        for (workspaceID, stored) in storedReviewInbox where stored == chatID {
            storedReviewInbox[workspaceID] = nil
            UserDefaults.standard.removeObject(forKey: Self.reviewInboxKey(for: workspaceID))
        }
    }

    /// Drops a chat's in-memory state while keeping everything it needs to come
    /// back: a closed chat can be reopened, so drafts, scheduled continuations
    /// and its narration toggle stay, and `chat(for:)` reloads the transcript.
    private func release(_ chatID: ChatID) {
        // `narration.release` frees the chat's buffers but, unlike `forget`,
        // keeps the tab's speaker on, which a reopened tab should keep.
        narration.release(chatID)
        chatOwners.removeValue(forKey: chatID)
        coalescers.removeValue(forKey: chatID)
        lastBackgroundFlush.removeValue(forKey: chatID)
        if let state = chatStates[chatID] {
            // Rendered rows are cached by turn; a reopened chat re-renders.
            TranscriptCell.dropRenderCache(turnIDs: state.rows.map(\.turnID))
            chatStates.removeValue(forKey: chatID)
        }
        dismissedCommentKeys.removeValue(forKey: chatID)
        // A closed tab can no longer be answered, so its asks leave the HUD.
        removeNeedsYou { $0.chatID == chatID }
    }

    /// An archived workspace keeps its record but loses its checkout, so what
    /// was held in memory for it is dead weight until it is unarchived — and
    /// its terminal is a shell running in a directory that no longer exists.
    private func releaseArchived(_ workspaceID: WorkspaceID) {
        for chat in chats(for: workspaceID, includeClosed: true) { release(chat.id) }
        diffCache.remove(workspaceID)
        diffPrefetches.cancel(workspaceID)
        TerminalRegistry.shared.closeTerminal(for: workspaceID)
    }

    /// `chatOwners` is written on every agent event; only a real move is a write.
    private func noteOwner(_ workspaceID: WorkspaceID, of chatID: ChatID) {
        if chatOwners[chatID] != workspaceID { chatOwners[chatID] = workspaceID }
    }

    private func workspaceName(_ id: WorkspaceID) -> String {
        workspaces.first { $0.id == id }?.name ?? "A workspace"
    }

    private func postNotification(
        title: String,
        body: String,
        workspaceID: WorkspaceID? = nil,
        chatID: ChatID? = nil,
        category: String? = nil,
        extraInfo: [String: String] = [:]
    ) {
        guard UserDefaults.standard.object(forKey: "ore.notifications.enabled") as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if UserDefaults.standard.object(forKey: "ore.notifications.sound") as? Bool ?? true {
            content.sound = .default
        }
        // The category is what puts Allow/Deny/Reply buttons on the banner —
        // see AppDelegate.notificationCategories.
        if let category { content.categoryIdentifier = category }
        var userInfo: [String: String] = extraInfo
        if let workspaceID { userInfo["workspaceID"] = workspaceID.rawValue }
        if let chatID { userInfo["chatID"] = chatID.rawValue }
        content.userInfo = userInfo
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        ))
    }

    // MARK: - Notification actions

    /// A banner button was pressed — the app may not even have a window open.
    /// Everything here routes through the same paths the in-app buttons use.
    private func handleNotificationAction(_ info: [String: String]) {
        guard let action = info["actionIdentifier"] else { return }
        let workspaceID = info["workspaceID"].map(WorkspaceID.init(rawValue:))
        let chatID = info["chatID"].map(ChatID.init(rawValue:))

        switch action {
        case NotificationAction.allowTask, NotificationAction.allowOnce, NotificationAction.deny:
            guard let id = info["confirmationID"] else { return }
            let decision: AssistantConfirmationDecision = switch action {
            case NotificationAction.allowTask: .allow(.task)
            case NotificationAction.allowOnce: .allow(.once)
            default: .deny
            }
            resolveAssistantConfirmation(id, decision: decision)

        case NotificationAction.reply:
            guard let workspaceID, let chatID,
                  let questionID = info["questionID"].map(QuestionID.init(rawValue:)),
                  let text = info["replyText"]?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return }
            answerQuestion(questionID, answer: text, for: workspaceID, chatID: chatID)

        case NotificationAction.allowPermission, NotificationAction.denyPermission:
            guard let workspaceID, let chatID,
                  let permissionID = info["permissionID"]
                      .map(PermissionRequestID.init(rawValue:))
            else { return }
            let decision: PermissionDecision = action == NotificationAction.allowPermission
                ? .allow
                : .deny(reason: "The user denied this from a notification.")
            resolvePermission(
                permissionID, decision: decision,
                for: workspaceID, chatID: chatID
            )

        case NotificationAction.openDreams:
            pendingDreamsOpen = true
            NSApp.activate(ignoringOtherApps: true)

        default:
            break
        }
    }

    private func upsert(_ summary: WorkspaceSummary) {
        let previousSync = workspaces.first { $0.id == summary.id }?.baseSync
        var next = summary
        if let index = workspaces.firstIndex(where: { $0.id == summary.id }) {
            // Git dirt rides `workspaceLive`. Keeping the array's copy frozen
            // means a summary republish (unread, rename, status) does not
            // look like a git change to every `workspaces` reader.
            next.gitStatus = workspaces[index].gitStatus
            if workspaces[index] == next { return }
            workspaces[index] = next
        } else {
            workspaces.append(next)
            workspaceLive.seed(summary)
        }
        noteFleetChange(summary)
        // Origin movement does not touch the worktree, so the git-action
        // cache would otherwise keep offering Merge while this branch now
        // conflicts with master.
        if previousSync != summary.baseSync {
            Task { await refreshGitAction(for: summary.id) }
        }
    }

    /// Selection is part of workspace-list state too. Keeping an archived row
    /// selected leaves the detail pane and app intents pointing at a worktree
    /// that no longer exists even when the sidebar correctly filters the row.
    private func repairWorkspaceSelection() {
        selectedWorkspaceID = workspaceSelectionAfterListChange(
            selected: selectedWorkspaceID,
            active: sortedWorkspaces.map(\.id)
        )
    }

    private func upsertChat(_ summary: ChatSummary) {
        if let index = chatSummaries.firstIndex(where: { $0.id == summary.id }) {
            if chatSummaries[index] != summary {
                chatSummaries[index] = summary
            }
        } else {
            chatSummaries.append(summary)
        }
        chatIndex.upsert(summary)
        recomputeFleetActivity()
        // The engine's queue gate, brought over as-is. The composer decides
        // "send or queue" from this, so a guess derived from `status` would put
        // the button and the engine back out of step. Loaded states only — a
        // state created later reads it from the summary (`makeChatState`), and
        // creating one here loaded full history for every chat that changed.
        chatStates[summary.id]?.reconcileTurnActive(summary.isTurnActive)
        if activeChatIDs[summary.workspaceID] == nil, !summary.isClosed {
            let saved = UserDefaults.standard.string(
                forKey: "ore.activeChat.\(summary.workspaceID.rawValue)"
            )
            let open = chats(for: summary.workspaceID)
            activeChatIDs[summary.workspaceID] = saved.flatMap { raw in
                open.first { $0.id.rawValue == raw }?.id
            } ?? defaultChat(among: open, in: summary.workspaceID)?.id
        }
    }

    private func restoreActiveChats() {
        for workspace in workspaces {
            let saved = UserDefaults.standard.string(
                forKey: "ore.activeChat.\(workspace.id.rawValue)"
            )
            let open = chats(for: workspace.id)
            activeChatIDs[workspace.id] = saved.flatMap { raw in
                open.first { $0.id.rawValue == raw }?.id
            } ?? defaultChat(among: open, in: workspace.id)?.id
        }
    }

    private func adoptResearchIdentities() {
        var used = Set(workspaces.flatMap { workspace in
            [workspace.name, (workspace.worktreePath as NSString).lastPathComponent]
        })
        for workspace in workspaces {
            if let identity = researchIdentity(for: workspace) {
                UserDefaults.standard.set(
                    identity.slug,
                    forKey: "ore.researchIdentity.\(workspace.id.rawValue)"
                )
                // Repair a name the auto-namer poisoned with a provider error
                // ("You've hit your session limit"). The workspace's real
                // identity is still on file, so put it back rather than leaving
                // the window titled with a stale failure.
                if Self.looksLikeErrorTitle(workspace.name),
                   workspace.name != identity.name,
                   !identityRenamesInFlight.contains(workspace.id) {
                    identityRenamesInFlight.insert(workspace.id)
                    rename(workspace.id, to: identity.name)
                }
            } else if Self.isGenericWorkspaceName(workspace.name),
                      !identityRenamesInFlight.contains(workspace.id) {
                let identity = ResearchIdentity.next(excluding: used)
                used.insert(identity.name)
                used.insert(identity.slug)
                UserDefaults.standard.set(
                    identity.slug,
                    forKey: "ore.researchIdentity.\(workspace.id.rawValue)"
                )
                researchIdentityCache.removeValue(forKey: workspace.id)
                identityRenamesInFlight.insert(workspace.id)
                rename(workspace.id, to: identity.name, userInitiated: false)
            }
            adoptResearchChatTitles(in: workspace.id)
        }
    }

    private func adoptResearchChatTitles(in workspaceID: WorkspaceID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        let preferred = researchIdentity(for: workspace)
        var used = Set(chats(for: workspaceID, includeClosed: true)
            .filter { !Self.isGenericChatTitle($0.title, workspaceName: workspace.name) }
            .map(\.title))
        // A title that is really a provider error is renamed whether or not the
        // chat has run since: it was never a name, so there is no user intent
        // behind it to preserve.
        for chat in chats(for: workspaceID, includeClosed: true)
        where (Self.isGenericChatTitle(chat.title, workspaceName: workspace.name)
                && chat.lastActivity == nil
                || Self.looksLikeErrorTitle(chat.title))
            && !chatRenamesInFlight.contains(chat.id)
            // An ephemeral chat's name is a marker, not a title — renaming it
            // would surface a tab that is supposed to stay invisible.
            && !ephemeralChatIDs.contains(chat.id) {
            let title = ResearchIdentity.nextResearchTitle(excluding: used, preferred: preferred)
            used.insert(title)
            chatRenamesInFlight.insert(chat.id)
            renameChat(chat.id, in: workspaceID, to: title, userInitiated: false)
        }
    }

    private func rememberIdentityIfPresent(for workspace: WorkspaceSummary) {
        let key = "ore.researchIdentity.\(workspace.id.rawValue)"
        guard UserDefaults.standard.string(forKey: key) == nil,
              let identity = ResearchIdentity.matching(nameOrSlug: workspace.name) else { return }
        UserDefaults.standard.set(identity.slug, forKey: key)
        researchIdentityCache.removeValue(forKey: workspace.id)
    }

    /// A name that is actually a failure the auto-namer captured. The naming
    /// session runs on the same metered subscription as the chat, so when that
    /// hits a limit the limit notice is what comes back — and it reads exactly
    /// like a title, which is why it was adopted as one.
    nonisolated static func looksLikeErrorTitle(_ title: String) -> Bool {
        let value = title.lowercased()
        return [
            "session limit", "usage limit", "rate limit", "rate-limit",
            "quota", "too many requests", "try again later",
        ].contains { value.contains($0) }
    }

    private nonisolated static func isGenericWorkspaceName(_ name: String) -> Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty || value == "workspace" || value == "new workspace"
    }

    private nonisolated static func isGenericChatTitle(_ title: String, workspaceName: String) -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return true }
        if value.caseInsensitiveCompare("workspace") == .orderedSame
            || value.caseInsensitiveCompare("new workspace") == .orderedSame { return true }
        if value.caseInsensitiveCompare(workspaceName) == .orderedSame { return true }
        guard value.lowercased().hasPrefix("chat ") else { return false }
        return Int(value.dropFirst(5)) != nil
    }

    private func focusChanged(from previous: WorkspaceID?, to next: WorkspaceID?) {
        if let next { UserDefaults.standard.set(next.rawValue, forKey: "ore.selectedWorkspace") }
        narration.activeChatChanged(next.flatMap { activeChat(for: $0)?.id })
        Task {
            if let previous, let chatID = activeChatIDs[previous] {
                try? await client.setFocused(
                    workspaceID: previous, chatID: chatID, focused: false
                )
            }
            if let next, let chatID = activeChatIDs[next] {
                try? await client.setFocused(workspaceID: next, chatID: chatID, focused: true)
            }
        }
        // Looking at a workspace again is the other moment its remote state may
        // have moved without us — a PR reviewed or merged in a browser tab.
        if let next { Task { [weak self] in await self?.refreshGitAction(for: next) } }
        // Background worktrees skip diff refreshes while unseen; catch up now.
        if let workspace = selectedWorkspace { prefetchDiff(for: workspace) }
    }

    func dismissBanner(_ id: UUID) {
        banners.removeAll { $0.id == id }
    }

    private func show(_ error: any Error) {
        banners.append(Banner(
            message: (error as? CustomStringConvertible)?.description
                ?? error.localizedDescription,
            detail: nil
        ))
    }
}

/// Keeps a still-valid selection, otherwise moves to the first active row.
/// All windows share one `AppModel`, so repairing it here updates every scene
/// without window-local invalidation or an optimistic archive.
func workspaceSelectionAfterListChange(
    selected: WorkspaceID?,
    active: [WorkspaceID]
) -> WorkspaceID? {
    if let selected, active.contains(selected) { return selected }
    return active.first
}

/// Internal rather than file-private so the copy a stuck sign-in shows can be
/// asserted in a test: the timeout message is the only thing standing between
/// the user and a hang, and it names a command that has to stay correct.
enum HarnessAuthenticationError: LocalizedError, Sendable {
    case interactiveOnly
    case notInstalled(String)
    case failed(Int32)
    /// Carries the command to run by hand instead, because that is the only
    /// advice left once the browser handshake has plainly not happened.
    case timedOut(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .interactiveOnly:
            "Claude Code sign-in is interactive. The command has been copied for Terminal."
        case .notInstalled(let name):
            "\(name) is not installed."
        case .failed(let status):
            "The provider login exited with status \(status)."
        case .timedOut(let command):
            "Sign-in timed out. Run `\(command)` in Terminal instead."
        case .cancelled:
            "Sign-in cancelled."
        }
    }
}

private enum GitHubRepositoryInputError: LocalizedError, Sendable {
    case invalidReference
    var errorDescription: String? {
        "Enter a repository as owner/name or a GitHub URL."
    }
}

enum FilePresentationMode: String, Sendable {
    case source
    case diff
    /// The file rendered: markdown as a document, HTML as a page, an image as
    /// an image. A plan the agent wrote should read as a document, and an icon
    /// it drew should be looked at, not decoded.
    case preview

    enum PreviewKind: Sendable, Equatable {
        case markdown
        case html
        case image
    }

    /// What a preview of this path renders, or nil when there isn't one.
    static func previewKind(path: String) -> PreviewKind? {
        let ext = (path as NSString).pathExtension.lowercased()
        if ["md", "markdown", "mdown", "mdx"].contains(ext) { return .markdown }
        if ["html", "htm", "xhtml"].contains(ext) { return .html }
        if BinaryFileKind(path: path).isPreviewable { return .image }
        return nil
    }

    /// Whether this path can render as a document at all.
    static func supportsPreview(path: String) -> Bool {
        previewKind(path: path) != nil
    }

    /// Whether the file has a text form to open in the editor. A PNG does
    /// not, and offering Source for one only led to "Can't open this file".
    static func hasSource(path: String) -> Bool {
        !BinaryFileKind(path: path).isKnownBinary
    }

    /// What a plain "open this file" means for this path: documents, pages
    /// and images open as previews by default, everything else as source.
    static func preferred(forPath path: String) -> FilePresentationMode {
        supportsPreview(path: path) ? .preview : .source
    }
}

struct WorkspaceFileNode: Identifiable, Hashable, Sendable {
    var id: String { path }
    var path: String
    var name: String
    var isDirectory: Bool
    var children: [WorkspaceFileNode]?
}

extension WorkspaceSummary {
    /// The one thing the sidebar is for: does this agent need me right now.
    var needsAttention: Bool {
        hasUnread || status == .awaitingInput || status == .failed
    }
}

/// Per-workspace git dirt, independently observable so one worktree's file
/// writes do not rebuild the fleet list, sidebar sort, or every other pane.
@MainActor
@Observable
final class WorkspaceLiveState {
    var gitStatus = GitStatusSummary()
    /// Freshness stamp for the review pane. Updated even when the visible
    /// counts did not move, because files can change with the same +/- totals.
    var gitGeneration: UInt64 = 0

    func apply(_ status: GitStatusSummary) {
        gitGeneration = status.generation
        if !gitStatus.hasSameVisibleChrome(as: status) {
            gitStatus = status
        }
    }
}

@MainActor
final class WorkspaceLiveRegistry {
    private var states: [WorkspaceID: WorkspaceLiveState] = [:]

    func state(for id: WorkspaceID) -> WorkspaceLiveState {
        if let existing = states[id] { return existing }
        let created = WorkspaceLiveState()
        states[id] = created
        return created
    }

    func seed(_ summary: WorkspaceSummary) {
        let live = state(for: summary.id)
        live.gitStatus = summary.gitStatus
        live.gitGeneration = summary.gitStatus.generation
    }

    func remove(_ id: WorkspaceID) {
        states.removeValue(forKey: id)
    }
}

/// One workspace's cached diff, observable on its own for the same reason as
/// `WorkspaceLiveState`.
@MainActor
@Observable
final class WorkspaceDiffState {
    private(set) var snapshot: AppModel.DiffSnapshot?

    /// Equal re-reads — the common case for a refresh — do not notify.
    func store(_ next: AppModel.DiffSnapshot?) {
        if let next, let snapshot, snapshot.generation > next.generation { return }
        if snapshot != next { snapshot = next }
    }
}

@MainActor
final class WorkspaceDiffRegistry {
    private var states: [WorkspaceID: WorkspaceDiffState] = [:]

    func state(for id: WorkspaceID) -> WorkspaceDiffState {
        if let existing = states[id] { return existing }
        let created = WorkspaceDiffState()
        states[id] = created
        return created
    }

    func contains(_ state: WorkspaceDiffState, for id: WorkspaceID) -> Bool {
        states[id] === state
    }

    /// Cleared before it is dropped, so a pane still showing it redraws.
    func remove(_ id: WorkspaceID) {
        states.removeValue(forKey: id)?.store(nil)
    }
}
