import AppKit
import Foundation
import LocalAuthentication
import Observation
import OreCore
import OreGit
import OrePersistence
import OreProtocol
import UserNotifications

/// The app's view state.
///
/// One `@Observable` object holding what every surface reads. It is the only
/// thing in the app that talks to the core: views send commands through it and
/// read state from it, so there is exactly one place where the boundary is
/// crossed and exactly one ordering of updates.
@MainActor
@Observable
final class AppModel {
    private(set) var workspaces: [WorkspaceSummary] = []
    /// The product-owned assistant workspace, routed out of `workspaces` at
    /// event intake. This is the single point that keeps it off the sidebar,
    /// out of ⌘1–9, and away from every picker — the Assistant window is the
    /// only surface that reads it.
    private(set) var assistantWorkspace: WorkspaceSummary?
    /// Pending "may the assistant do this?" questions, newest last. Rendered
    /// as cards in the Assistant window; the core times them out (denying)
    /// after two minutes.
    private(set) var assistantConfirmations: [AssistantConfirmation] = []
    /// Project tabs blocked on a permission or question, for the HUD / menu bar
    /// when the user is in another app.
    private(set) var tabNeedsYou: [TabNeedsYou] = []
    private(set) var harnesses: [HarnessProbeResult] = []
    private(set) var modelCatalog: [HarnessKind: [AgentModel]] = [:]
    private(set) var repositories: [String] = []
    private(set) var isLoaded = false

    var selectedWorkspaceID: WorkspaceID? {
        didSet {
            guard selectedWorkspaceID != oldValue else { return }
            focusChanged(from: oldValue, to: selectedWorkspaceID)
        }
    }

    private(set) var chatSummaries: [ChatSummary] = []
    /// Live transcript state is keyed by durable chat identity, never by
    /// workspace: several tabs in one worktree can stream concurrently.
    private(set) var chatStates: [ChatID: ChatState] = [:]
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
    struct DiffSnapshot {
        var generation: UInt64
        var diffs: [FileDiff]
        var gitAction: SuggestedGitAction
    }
    private(set) var diffCache: [WorkspaceID: DiffSnapshot] = [:]

    /// Speaks agent activity aloud for tabs whose speaker toggle is on.
    let narration = NarrationEngine()
    /// Hold-⇧⌥-anywhere voice mode: speech in, narrated assistant replies out.
    let voiceAssistant = VoiceAssistantController()

    private let client: InProcessCoreClient
    private var eventTask: Task<Void, Never>?
    /// Batches streaming deltas so a fast model can't drive the transcript's
    /// layout at the rate the tokens arrive.
    private var coalescers: [ChatID: TextDeltaCoalescer] = [:]
    private var chatOwners: [ChatID: WorkspaceID] = [:]
    private var pendingNewChatMessages: [WorkspaceID: [String]] = [:]
    /// Draft text to drop into a chat that hasn't been published yet, so Commit
    /// / Create PR can open a tab without sending until the user hits return.
    private var pendingNewChatDrafts: [WorkspaceID: [String]] = [:]
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
    private var pendingDrafts: [ChatID: (workspaceID: WorkspaceID, text: String)] = [:]
    private var draftFlushTask: Task<Void, Never>?

    struct Banner: Identifiable, Sendable {
        let id = UUID()
        var message: String
        var detail: String?
    }

    init(client: InProcessCoreClient) {
        self.client = client
    }

    // MARK: - Lifecycle

    /// The one live model, for entry points that exist outside the SwiftUI
    /// scene tree — App Intents (Siri, Shortcuts, Spotlight) chief among them.
    private(set) static weak var shared: AppModel?

    static func running() -> AppModel? { shared }

    private var started = false

    func start() {
        // Idempotent: called from app init (so intents and the menu bar work
        // before any window exists) and again from the window's task.
        guard !started else { return }
        started = true
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
            try? await client.start()
            await refreshRepositories()
            isLoaded = true
            // A beat for the fleet snapshot to land, then say hello.
            try? await Task.sleep(for: .milliseconds(800))
            prepareLaunchBriefing()
        }
        restoreScheduledContinuations()
        startFleetAwareness()
        NotificationCenter.default.addObserver(
            forName: .oreOpenFromNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let workspace = notification.userInfo?["workspaceID"] as? String
            let chat = notification.userInfo?["chatID"] as? String
            Task { @MainActor in
                self?.openFromNotification(workspaceID: workspace, chatID: chat)
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

    /// Flushes coalesced deltas at ~40Hz, but only while something is pending.
    ///
    /// The transcript is the app's hottest surface, and every delta that
    /// reaches it costs a layout pass. Batching at a fixed cadence decouples
    /// rendering cost from token rate. A timer that ran forever still woke the
    /// main actor 40 times a second while the app sat idle.
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
        eventTask?.cancel()
        flushTask?.cancel()
        fleetTickTask?.cancel()
        for task in continuationTasks.values { task.cancel() }
        continuationTasks.removeAll()
        await client.shutdown()
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

        let lastSeen = defaults.double(forKey: Self.lastSeenKey)
        let lastSeenAt = lastSeen > 0 ? Date(timeIntervalSince1970: lastSeen) : nil
        let briefing = LaunchBriefing.compose(
            workspaces: sortedWorkspaces,
            lastSeenAt: lastSeenAt,
            userName: LaunchBriefing.firstName(from: NSFullUserName())
        )
        launchBriefing = briefing

        // Speak only when there was a real absence: a voice greeting on every
        // quick relaunch is clingy, and the master narration switch always
        // wins. Milestone priority — it defers to anything urgent.
        let awayLongEnough = lastSeenAt.map {
            Date().timeIntervalSince($0) > LaunchBriefing.spokenAwayThreshold
        } ?? true
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

    func dismissLaunchBriefing() {
        launchBriefing = nil
    }

    // MARK: - Reading

    var selectedWorkspace: WorkspaceSummary? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    /// The assistant's single chat tab, once the snapshot has arrived.
    var assistantChatID: ChatID? {
        guard let assistant = assistantWorkspace else { return nil }
        return activeChat(for: assistant.id)?.id
            ?? chatSummaries.first { $0.workspaceID == assistant.id }?.id
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
    private static func authenticateStandingGrant() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        return (try? await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "let the ORE assistant always perform this kind of action"
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
        guard proactiveWatchEnabled, assistantWorkspace != nil else { return }
        let place = "\(workspaceName(workspaceID))"
            + (chatSummaries.first { $0.id == chatID }.map { " / \($0.title)" } ?? "")

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
                try? await Task.sleep(for: Self.fleetTick)
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

    var hasNeedsYouStops: Bool { !needsYouStops.isEmpty }

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

    func chats(for workspaceID: WorkspaceID, includeClosed: Bool = false) -> [ChatSummary] {
        chatSummaries
            .filter { $0.workspaceID == workspaceID && (includeClosed || !$0.isClosed) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func activeChat(for workspaceID: WorkspaceID) -> ChatSummary? {
        let open = chats(for: workspaceID)
        if let id = activeChatIDs[workspaceID], let chat = open.first(where: { $0.id == id }) {
            return chat
        }
        return open.first
    }

    func chat(for id: ChatID) -> ChatState {
        if let existing = chatStates[id] { return existing }
        let state = ChatState()
        state.draftAttachments = Self.loadDraftAttachments(for: id)
        chatStates[id] = state
        Task { await loadHistory(for: id) }
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
        let state = chat(for: id)
        guard !state.hasLoadedHistory else { return }
        guard let turns = try? await client.transcript(chatID: id) else { return }

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

            guard let blocks = try? await client.blocks(turnID: turnID) else { continue }
            for block in blocks {
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
        if let transitions = try? await client.chatTransitions(chatID: id) {
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
        }
        rows.sort { $0.createdAt < $1.createdAt }
        state.loadHistory(rows)
        await pullDraftComments(for: id)
    }

    /// Merge pending review comments (including ones an agent posted to the
    /// JSON file) into this chat's draft list so they show as numbered anchors.
    func pullDraftComments(for id: ChatID) async {
        let workspaceID = chatOwners[id] ?? WorkspaceID(rawValue: id.rawValue)
        await pullDraftComments(for: workspaceID, into: chat(for: id))
    }

    func pullDraftComments(for workspaceID: WorkspaceID) async {
        await pullDraftComments(for: workspaceID, into: chat(for: workspaceID))
    }

    private func pullDraftComments(for workspaceID: WorkspaceID, into state: ChatState) async {
        guard let comments = try? await client.pendingDiffComments(workspaceID: workspaceID) else {
            return
        }
        for comment in comments where !state.draftComments.contains(comment) {
            state.addDraftComment(comment)
        }
    }

    private static func row(
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
            return TranscriptRow(
                id: block.id, turnID: turnID, kind: .plan,
                text: block.text, isComplete: true, createdAt: block.createdAt
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
    var sortedWorkspaces: [WorkspaceSummary] {
        workspaces
            .filter { !$0.isArchived }
            .sorted { first, second in
                if first.isPinned != second.isPinned { return first.isPinned }
                if first.needsAttention != second.needsAttention { return first.needsAttention }
                return (first.lastActivity ?? .distantPast) > (second.lastActivity ?? .distantPast)
            }
    }

    var archivedWorkspaces: [WorkspaceSummary] {
        workspaces.filter(\.isArchived)
    }

    var attentionCount: Int {
        workspaces.filter { !$0.isArchived && $0.needsAttention }.count
    }

    // MARK: - Commands

    func addRepository(path: String) {
        Task { await client.send(.addRepository(path: path)) }
    }

    func createWorkspace(_ request: CreateWorkspaceRequest) {
        var request = request
        if request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.name = suggestedResearchIdentity().name
        }
        Task { await client.send(.createWorkspace(request)) }
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

    private func send(
        _ text: String,
        attachments: [Attachment] = [],
        effort: ReasoningEffort? = nil,
        serviceTier: String? = nil,
        origin: MessageOrigin = .user,
        to id: WorkspaceID,
        chatID: ChatID
    ) {
        let state = chat(for: chatID)
        let comments = state.takeDraftComments()
        cancelScheduledContinuation(for: chatID)
        persistDraftAttachments([], for: chatID)
        // The text just left the composer, so any buffered copy of it is stale.
        // Clearing the summary here rather than waiting out the debounce is what
        // keeps the tab bar's unsent-draft pencil from lingering after a send.
        discardPendingDraft(for: chatID)
        if var summary = chatSummaries.first(where: { $0.id == chatID }), !summary.draftText.isEmpty {
            summary.draftText = ""
            upsertChat(summary)
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

    func resolvePermission(
        _ requestID: PermissionRequestID,
        decision: PermissionDecision,
        for id: WorkspaceID,
        chatID: ChatID? = nil
    ) {
        let resolvedChatID = chatID ?? activeChat(for: id)?.id
        guard let resolvedChatID else { return }
        // Optimistic and exact: the click is authoritative locally, so do not
        // wait for the provider's round trip while a now-obsolete prompt keeps
        // talking or opens its hands-free answer microphone.
        voiceAssistant.permissionResolved(requestID)
        narration.cancelPermissionPrompt(requestID)
        chat(for: resolvedChatID).resolvePermission(requestID)
        tabNeedsYou.removeAll {
            if case .permission(let item) = $0, item.request.id == requestID { return true }
            return false
        }
        Task { await client.send(.resolveChatPermission(id, resolvedChatID, requestID, decision)) }
    }

    /// The Allow/Deny card currently on screen, if the generic buttons own it.
    /// AskUserQuestion and ExitPlanMode keep their dedicated cards instead.
    var actionablePermission: PermissionRequest? {
        guard let chat = selectedChat, let permission = chat.pendingPermission else { return nil }
        if permission.toolName == "AskUserQuestion" { return nil }
        if permission.toolName == "ExitPlanMode", case .proposal = chat.plan { return nil }
        return permission
    }

    func allowPendingPermission() {
        guard let workspaceID = selectedWorkspaceID,
              let permission = actionablePermission else { return }
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

    func answerQuestion(
        _ questionID: QuestionID,
        answer: String,
        for id: WorkspaceID,
        chatID: ChatID? = nil
    ) {
        let resolvedChatID = chatID ?? activeChat(for: id)?.id
        guard let resolvedChatID else { return }
        chat(for: resolvedChatID).resolveQuestion(questionID)
        tabNeedsYou.removeAll {
            if case .question(let item) = $0, item.question.id == questionID { return true }
            return false
        }
        Task { await client.send(.answerChatQuestion(id, resolvedChatID, questionID, answer: answer)) }
    }

    /// Answer a permission-gated question (Claude's AskUserQuestion) by returning
    /// the answer *through* the tool-permission reply, which both delivers it as
    /// the tool result and unblocks the turn — instead of allowing the tool (an
    /// empty answer) and racing a separate, droppable user message.
    func answerQuestion(
        _ questionID: QuestionID,
        viaPermission permissionID: PermissionRequestID,
        answer: String,
        for id: WorkspaceID
    ) {
        guard let chatID = activeChat(for: id)?.id else { return }
        chat(for: chatID).resolveQuestion(questionID)
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmed.isEmpty
            ? "The user dismissed the question without choosing; continue."
            : "The user answered your question: \"\(trimmed)\". Continue with this answer in mind."
        resolvePermission(permissionID, decision: .deny(reason: message), for: id)
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
        model: String? = nil
    ) {
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

    /// The temporary "commit clerk" tab: forked from the active chat — so it
    /// already knows what the work was about and can write honest messages —
    /// named Commit, and immediately prompted to stage and commit everything.
    /// The composer's suggestion chip offers closing the tab once the tree is
    /// clean (see `composerSuggestion` in ChatPane).
    func startCommitAgent(in workspaceID: WorkspaceID) {
        guard let source = activeChat(for: workspaceID),
              chatCreationsInFlight.insert(workspaceID).inserted else { return }
        pendingNewChatMessages[workspaceID, default: []].append(Self.commitAgentPrompt)
        showChatInCenter(workspaceID)
        let used = Set(chats(for: workspaceID, includeClosed: true).map(\.title))
        Task { await client.send(.createChat(CreateChatRequest(
            workspaceID: workspaceID,
            title: ResearchIdentity.unique("Commit", excluding: used),
            harness: source.harness,
            model: source.model,
            permissionMode: source.permissionMode,
            forkFrom: source.id
        ))) }
    }

    static let commitAgentPrompt = """
        Commit all outstanding work in this worktree. Review everything staged \
        and unstaged, group related changes into one or more coherent commits, \
        and write clear, conventional commit messages that explain the why. \
        Include untracked files that belong to the work; leave anything that \
        looks accidental uncommitted and call it out. Do not push. Proceed \
        without asking for confirmation.
        """

    /// The "ship it" sibling of `startCommitAgent`: a temporary tab that
    /// commits whatever is outstanding, pushes, and opens the pull request —
    /// the whole default flow, no sheets, no questions.
    func startShipAgent(in workspaceID: WorkspaceID, base: String? = nil) {
        guard let source = activeChat(for: workspaceID),
              chatCreationsInFlight.insert(workspaceID).inserted else { return }
        let baseBranch = base
            ?? workspaces.first { $0.id == workspaceID }?.baseBranch
            ?? "main"
        pendingNewChatMessages[workspaceID, default: []].append("""
            Ship this branch. Commit any outstanding staged and unstaged work \
            with clear, conventional commit messages, push the branch, and \
            open a pull request against \(baseBranch) with a concise title \
            and a description that covers what changed and why. Never force \
            push. Proceed without asking for confirmation, and finish by \
            reporting the pull request URL.
            """)
        showChatInCenter(workspaceID)
        let used = Set(chats(for: workspaceID, includeClosed: true).map(\.title))
        Task { await client.send(.createChat(CreateChatRequest(
            workspaceID: workspaceID,
            title: ResearchIdentity.unique("Ship", excluding: used),
            harness: source.harness,
            model: source.model,
            permissionMode: source.permissionMode,
            forkFrom: source.id
        ))) }
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

    func openFromNotification(workspaceID: String?, chatID: String?) {
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
            || self.chat(for: chat.id).isBusy
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

    func loadGitAction(for id: WorkspaceID) async throws -> SuggestedGitAction {
        try await client.suggestedGitAction(workspaceID: id)
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
    func cachedDiff(for id: WorkspaceID) -> DiffSnapshot? { diffCache[id] }

    /// Loads a workspace's diff and suggested git action together, caches the
    /// result, and returns it. The concurrent reads mean the review pane waits
    /// on the slower of the two rather than their sum.
    @discardableResult
    func refreshDiff(for workspace: WorkspaceSummary) async throws -> DiffSnapshot {
        async let diffs = loadDiff(for: workspace.id)
        async let action = loadGitAction(for: workspace.id)
        let snapshot = DiffSnapshot(
            generation: workspace.gitStatus.generation,
            diffs: try await diffs,
            gitAction: try await action
        )
        // Reads race: the review pane refreshes on both workspace switch and
        // every git-status bump, and `prefetchDiff` runs more in the
        // background. They finish out of order, so an older read landing last
        // used to overwrite fresh changes with the empty diff from before the
        // agent wrote anything — the "Changes 0 even though files are
        // modified" that only showed up sometimes. The newest generation wins,
        // and a stale caller is handed the newer snapshot rather than its own.
        if let cached = diffCache[workspace.id], cached.generation > snapshot.generation {
            return cached
        }
        diffCache[workspace.id] = snapshot
        return snapshot
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
        guard let action = try? await loadGitAction(for: workspaceID) else { return }
        guard var snapshot = diffCache[workspaceID] else { return }
        guard snapshot.gitAction != action else { return }
        snapshot.gitAction = action
        diffCache[workspaceID] = snapshot
    }

    /// Best-effort background warm-up of a workspace's diff so a later switch is
    /// instant. Skips work when the cache already matches the current git-status
    /// generation; failures are swallowed since the real refresh reports them.
    func prefetchDiff(for workspace: WorkspaceSummary) {
        if let cached = diffCache[workspace.id],
           cached.generation == workspace.gitStatus.generation { return }
        Task(priority: .utility) { [weak self] in
            _ = try? await self?.refreshDiff(for: workspace)
        }
    }

    /// Warms the transcript for a workspace's active chat so its centre column
    /// shows history immediately on switch instead of the empty state. Reading
    /// the `ChatState` is enough — it kicks off `loadHistory` on first access.
    func prefetchHistory(for workspaceID: WorkspaceID) {
        guard let chatID = activeChatIDs[workspaceID] else { return }
        if let state = chatStates[chatID], state.hasLoadedHistory { return }
        _ = chat(for: chatID)
    }

    /// Warms diffs and transcripts for every workspace shortly after they load,
    /// so navigating between worktrees feels instant rather than cold.
    private func warmWorkspaces() {
        for workspace in workspaces {
            prefetchDiff(for: workspace)
            prefetchHistory(for: workspace.id)
        }
    }

    func addDiffComment(_ reference: DiffCommentReference, for id: WorkspaceID) {
        chat(for: id).addDraftComment(reference)
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

    func updateQueuedMessage(_ id: Int64, text: String) async {
        try? await client.updateQueuedMessage(id: id, text: text)
    }

    func deleteQueuedMessage(_ id: Int64) async {
        try? await client.deleteQueuedMessage(id: id)
        if let chat = selectedChatSummary {
            var updated = chat
            updated.queuedMessageCount = max(0, updated.queuedMessageCount - 1)
            upsertChat(updated)
        }
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

    func refreshHarnesses() {
        Task { await client.send(.probeHarnesses) }
    }

    struct HarnessCLIUpdate: Equatable {
        var kind: HarnessKind
        var isRunning: Bool
        var error: String?
    }
    private(set) var harnessCLIUpdate: HarnessCLIUpdate?

    /// Upgrade the chat's agent CLI, restart its session so the new binary
    /// is the one we spawn, then resend the last prompt.
    func updateHarnessCLI(for chat: ChatSummary) {
        let kind = chat.harness
        harnessCLIUpdate = HarnessCLIUpdate(kind: kind, isRunning: true, error: nil)
        Task {
            do {
                try await client.updateHarnessCLI(kind)
                await client.send(.stopChatSession(chat.workspaceID, chat.id))
                harnessCLIUpdate = nil
                retryLastTurn(in: chat.workspaceID, chatID: chat.id)
            } catch {
                harnessCLIUpdate = HarnessCLIUpdate(
                    kind: kind,
                    isRunning: false,
                    error: error.localizedDescription
                )
            }
        }
    }

    /// Starts the provider's own browser-based login. Credentials remain in
    /// the CLI's credential store; ORE only observes the process exit and then
    /// re-runs its readiness probe.
    func authenticateHarness(_ kind: HarnessKind) async throws {
        guard kind != .claudeCode else { throw HarnessAuthenticationError.interactiveOnly }
        guard let executable = harnesses.first(where: { $0.kind == kind })?.executablePath
        else { throw HarnessAuthenticationError.notInstalled(kind.displayName) }

        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["login"]
            process.currentDirectoryURL = OreHome.directory
            process.environment = ProcessInfo.processInfo.environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { child in
                continuation.resume(returning: child.terminationStatus)
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
        guard exitCode == 0 else { throw HarnessAuthenticationError.failed(exitCode) }
        await client.send(.probeHarnesses)
    }

    func suggestedResearchIdentity() -> ResearchIdentity {
        let used = Set(workspaces.flatMap { workspace in
            [workspace.name, (workspace.worktreePath as NSString).lastPathComponent]
        })
        return ResearchIdentity.next(excluding: used)
    }

    func researchIdentity(for workspace: WorkspaceSummary) -> ResearchIdentity? {
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

    func saveFileContents(_ contents: String, path: String, in workspace: WorkspaceSummary) async throws {
        let root = workspace.worktreePath
        try await Task.detached(priority: .userInitiated) {
            let url = try Self.safeFileURL(root: root, relativePath: path)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }

    private nonisolated static func safeFileURL(root: String, relativePath: String) throws -> URL {
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
        switch event {
        case .snapshot(let snapshot):
            assistantWorkspace = snapshot.workspaces.first(where: \.isAssistant)
            workspaces = snapshot.workspaces.filter { !$0.isAssistant }
            chatSummaries = snapshot.chats
            chatOwners = Dictionary(
                snapshot.chats.map { ($0.id, $0.workspaceID) },
                uniquingKeysWith: { _, last in last }
            )
            harnesses = snapshot.harnesses
            // Priming, not observing: the fleet's state at launch is the
            // briefing's story, and the watcher must not narrate a night's
            // worth of drift as though it just happened.
            for workspace in workspaces { fleetWatcher.observe(workspace) }
            restoreActiveChats()
            adoptResearchIdentities()
            if selectedWorkspaceID == nil {
                if let saved = UserDefaults.standard.string(forKey: "ore.selectedWorkspace"),
                   workspaces.contains(where: { $0.id.rawValue == saved }) {
                    selectedWorkspaceID = WorkspaceID(rawValue: saved)
                } else {
                    selectedWorkspaceID = sortedWorkspaces.first?.id
                }
            }
            warmWorkspaces()

        case .workspaceAdded(let summary):
            guard !summary.isAssistant else {
                assistantWorkspace = summary
                break
            }
            upsert(summary)
            rememberIdentityIfPresent(for: summary)
            selectedWorkspaceID = summary.id
            prefetchDiff(for: summary)

        case .workspaceUpdated(let summary):
            guard !summary.isAssistant else {
                assistantWorkspace = summary
                break
            }
            upsert(summary)
            identityRenamesInFlight.remove(summary.id)
            rememberIdentityIfPresent(for: summary)

        case .workspaceRemoved(let id):
            workspaces.removeAll { $0.id == id }
            fleetWatcher.forget(id)
            let removed = chatSummaries.filter { $0.workspaceID == id }.map(\.id)
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
            if selectedWorkspaceID == id { selectedWorkspaceID = sortedWorkspaces.first?.id }

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
            }

        case .promptSubmitted(let id, let chatID, let submission):
            chatOwners[chatID] = id
            chat(for: chatID).applyPromptSubmission(submission)

        case .agent(let id, let chatID, let agentEvent):
            chatOwners[chatID] = id
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
            chatOwners[chat.id] = chat.workspaceID
            upsertChat(chat)
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
            if !isEphemeral,
               chat.workspaceID != assistantWorkspace?.id
                || assistantConversationsAwaitingFocus.remove(chat.workspaceID) != nil {
                selectChat(chat.id, in: chat.workspaceID)
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
            chatOwners[chat.id] = chat.workspaceID
            chatRenamesInFlight.remove(chat.id)
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

        case .assistantConversationCompacted(let id, _, let successor):
            // ORE retired the conversation the user was in, so following it is
            // the whole point — unlike `chatAdded`, this event only ever fires
            // for a seam ORE made itself.
            selectChat(successor, in: id)

        case .chatRemoved(_, let chatID):
            forget(chatID)
            chatSummaries.removeAll { $0.id == chatID }

        case .chatsListed(let workspaceID, let chats):
            for chat in chats {
                chatOwners[chat.id] = workspaceID
                upsertChat(chat)
            }
            adoptResearchChatTitles(in: workspaceID)

        case .gitStatusChanged(let id, let status):
            guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
            workspaces[index].gitStatus = status
            // The tree changed, so any cached diff is now stale — warm a fresh
            // one in the background so the review pane stays instant.
            prefetchDiff(for: workspaces[index])

        case .harnessProbeCompleted(let probes):
            harnesses = probes

        case .modelCatalogUpdated(let harness, let models):
            modelCatalog[harness] = models

        case .commandFailed(let failure):
            if let workspaceID = failure.workspaceID {
                chatCreationsInFlight.remove(workspaceID)
                pendingEphemeralWorkspaces.remove(workspaceID)
                gitOpsInFlight[workspaceID] = nil
            }
            banners.append(Banner(message: failure.message, detail: failure.detail))
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
            if case .rateLimit(let report) = event, report.status == .exhausted,
               !assistantRateLimitHandled {
                // The assistant's own provider ran dry; move it to another
                // ready harness so the next question still gets answered.
                assistantRateLimitHandled = true
                Task { await client.assistantRateLimited(chatID: chatID) }
                narration.speakAssistant(
                    "I've hit my provider's rate limit — switching to another "
                        + "agent to keep answering.",
                    chatID: chatID
                )
            }
            voiceAssistant.observe(event, chatID: chatID)
            return
        }
        collectWatchEvent(event, workspaceID: workspaceID, chatID: chatID)
        let origin = narrationOrigin(workspaceID: workspaceID, chatID: chatID)
        // Needs-you events have two possible voice owners: ambient tab
        // narration, or the hands-free assistant flow that opens the mic for
        // the answer. Pick exactly one before either starts speaking; letting
        // both consume the event produced two back-to-back "quick checks".
        let assistantOwnsNarration: Bool
        switch event {
        case .permissionRequest(let request):
            assistantOwnsNarration = noteTabNeedsYou(.permission(TabNeedsYou.Permission(
                workspaceID: workspaceID, chatID: chatID, request: request
            )))
        case .question(let question):
            assistantOwnsNarration = noteTabNeedsYou(.question(TabNeedsYou.Question(
                workspaceID: workspaceID, chatID: chatID, question: question
            )))
        default:
            assistantOwnsNarration = false
        }
        if !assistantOwnsNarration {
            narration.observe(event: event, chatID: chatID, origin: origin)
        }
        switch event {
        case .permissionResolved(let resolution):
            voiceAssistant.permissionResolved(resolution.id)
            tabNeedsYou.removeAll {
                if case .permission(let item) = $0, item.request.id == resolution.id { return true }
                return false
            }
        case .turnCompleted:
            tabNeedsYou.removeAll {
                switch $0 {
                case .permission(let item): return item.chatID == chatID
                case .question(let item): return item.chatID == chatID
                }
            }
        default:
            break
        }
        let appInactive = !NSApp.isActive
        guard origin.isBackground || appInactive else { return }
        let place = origin.displayLabel ?? workspaceName(workspaceID)
        switch event {
        case .permissionRequest(let request):
            postNotification(
                title: "ORE needs you",
                body: place + " wants to run \(request.toolName)."
                    + (request.summary.map { " \($0)" } ?? ""),
                workspaceID: workspaceID,
                chatID: chatID,
                category: NotificationCategory.toolPermission,
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

    @discardableResult
    private func noteTabNeedsYou(_ item: TabNeedsYou) -> Bool {
        tabNeedsYou.removeAll { $0.id == item.id }
        tabNeedsYou.append(item)
        let spokenByAssistant = voiceAssistant.needsYouArrived(item)
        informAssistantOfNeedsYou(item)
        return spokenByAssistant
    }

    /// Immediate, unlike the watch digest: the assistant may offer auto-allow
    /// but must not duplicate the HUD confirmation.
    private func informAssistantOfNeedsYou(_ item: TabNeedsYou) {
        guard proactiveWatchEnabled, let assistant = assistantWorkspace else { return }
        send(
            """
            [ORE needs you] \(item.spokenSummary)
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
        if let permissionID {
            // Authentication may take a moment; the user's click has already
            // answered this prompt, so silence it and retire the local card
            // before proving the standing grant.
            voiceAssistant.permissionResolved(permissionID)
            narration.cancelPermissionPrompt(permissionID)
            chat(for: chatID).resolvePermission(permissionID)
        }
        Task { @MainActor in
            let proven = await Self.authenticateStandingGrant()
            if let permissionID {
                await client.send(.resolveChatPermission(
                    workspaceID, chatID, permissionID, .allow
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
        let title = chatSummaries.first { $0.id == chatID }?.title
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

    /// Drops everything keyed by a chat that no longer exists.
    ///
    /// Each of these is small, and each used to outlive its chat: a scheduled
    /// continuation would still fire against a deleted conversation, and the
    /// per-chat defaults accumulated one set of orphans per chat ever created.
    private func forget(_ chatID: ChatID) {
        narration.forget(chatID)
        chatOwners.removeValue(forKey: chatID)
        coalescers.removeValue(forKey: chatID)
        lastBackgroundFlush.removeValue(forKey: chatID)
        chatStates.removeValue(forKey: chatID)
        chatRenamesInFlight.remove(chatID)
        continuationTasks.removeValue(forKey: chatID)?.cancel()
        scheduledContinuations.removeValue(forKey: chatID)
        persistScheduledContinuations()
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Self.continuationNotificationID(for: chatID)]
        )
        for key in [
            "ore.draftAttachments", "ore.chatScroll",
            "ore.reasoningEffort", "ore.fastMode",
        ] {
            UserDefaults.standard.removeObject(forKey: "\(key).\(chatID.rawValue)")
        }
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
            let state = chat(for: chatID)
            state.resolveQuestion(questionID)
            // Claude's AskUserQuestion pairs the question with a permission
            // gate; the answer has to travel through the permission reply or
            // the turn stays blocked (see answerQuestion(_:viaPermission:)).
            if let permission = state.pendingPermission,
               permission.toolName == "AskUserQuestion" {
                state.resolvePermission(permission.id)
                Task {
                    await client.send(.resolveChatPermission(
                        workspaceID, chatID, permission.id,
                        .deny(reason: "The user answered your question: \"\(text)\". Continue with this answer in mind.")
                    ))
                }
            } else {
                Task {
                    await client.send(.answerChatQuestion(
                        workspaceID, chatID, questionID, answer: text
                    ))
                }
            }

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

        default:
            break
        }
    }

    private func upsert(_ summary: WorkspaceSummary) {
        let previousSync = workspaces.first { $0.id == summary.id }?.baseSync
        if let index = workspaces.firstIndex(where: { $0.id == summary.id }) {
            workspaces[index] = summary
        } else {
            workspaces.append(summary)
        }
        noteFleetChange(summary)
        // Origin movement does not touch the worktree, so the git-action
        // cache would otherwise keep offering Merge while this branch now
        // conflicts with master.
        if previousSync != summary.baseSync {
            Task { await refreshGitAction(for: summary.id) }
        }
    }

    private func upsertChat(_ summary: ChatSummary) {
        if let index = chatSummaries.firstIndex(where: { $0.id == summary.id }) {
            chatSummaries[index] = summary
        } else {
            chatSummaries.append(summary)
        }
        // The engine's queue gate, brought over as-is. The composer decides
        // "send or queue" from this, so a guess derived from `status` would put
        // the button and the engine back out of step.
        chat(for: summary.id).reconcileTurnActive(summary.isTurnActive)
        if activeChatIDs[summary.workspaceID] == nil, !summary.isClosed {
            let saved = UserDefaults.standard.string(
                forKey: "ore.activeChat.\(summary.workspaceID.rawValue)"
            )
            activeChatIDs[summary.workspaceID] = saved.flatMap { raw in
                chats(for: summary.workspaceID).first { $0.id.rawValue == raw }?.id
            } ?? chats(for: summary.workspaceID).first?.id
        }
    }

    private func restoreActiveChats() {
        for workspace in workspaces {
            let saved = UserDefaults.standard.string(
                forKey: "ore.activeChat.\(workspace.id.rawValue)"
            )
            activeChatIDs[workspace.id] = saved.flatMap { raw in
                chats(for: workspace.id).first { $0.id.rawValue == raw }?.id
            } ?? chats(for: workspace.id).first?.id
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

private enum HarnessAuthenticationError: LocalizedError, Sendable {
    case interactiveOnly
    case notInstalled(String)
    case failed(Int32)

    var errorDescription: String? {
        switch self {
        case .interactiveOnly:
            "Claude Code sign-in is interactive. The command has been copied for Terminal."
        case .notInstalled(let name):
            "\(name) is not installed."
        case .failed(let status):
            "The provider login exited with status \(status)."
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
    /// Rendered markdown. Only offered for markdown files — a plan the agent
    /// wrote should read as a document, not as raw markup.
    case preview

    /// Whether this path can render as a document at all.
    static func supportsPreview(path: String) -> Bool {
        ["md", "markdown", "mdown", "mdx"]
            .contains((path as NSString).pathExtension.lowercased())
    }

    /// What a plain "open this file" means for this path: markdown reads as a
    /// document by default, everything else as source.
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
