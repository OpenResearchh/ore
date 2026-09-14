import AppKit
import OreCore
import OreGit
import OrePersistence
import OreProtocol
import OreTelemetry
import SwiftUI
import UserNotifications

/// Launch work that must not hold up the first frame. Runs once: shortly after
/// the first window appears, or from a fallback timer when no window does.
@MainActor
enum DeferredLaunchWork {
    private static var pending: (@MainActor () -> Void)?

    static func schedule(_ work: @escaping @MainActor () -> Void) {
        pending = work
    }

    static func runIfNeeded() {
        guard let work = pending else { return }
        pending = nil
        work()
    }
}

/// Stands in for the telemetry client until `TelemetryClient.make` has run
/// after the first frame. Events recorded before then are held and handed
/// over in order; an opt-out before then drops them and is passed on.
final class DeferredTelemetryRecorder: TelemetryRecorder, @unchecked Sendable {
    private let lock = NSLock()
    private var target: (any TelemetryRecorder)?
    private var buffered: [TelemetryEvent] = []
    private var optedOutEarly = false
    /// Launch-window events are a handful; the cap only guards a runaway.
    static let bufferLimit = 256

    init() {}

    func install(_ recorder: any TelemetryRecorder) {
        guard let forwardOptOut = attach(recorder) else { return }
        if forwardOptOut {
            Task { await recorder.optOut() }
        }
    }

    /// `nil` when a recorder is already installed; otherwise whether an early
    /// opt-out still has to reach the real one.
    private func attach(_ recorder: any TelemetryRecorder) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard target == nil else { return nil }
        target = recorder
        if !optedOutEarly {
            for event in buffered { recorder.record(event) }
        }
        buffered = []
        return optedOutEarly
    }

    func record(_ event: TelemetryEvent) {
        lock.lock()
        defer { lock.unlock() }
        if let target {
            target.record(event)
        } else if !optedOutEarly, buffered.count < Self.bufferLimit {
            buffered.append(event)
        }
    }

    func recordBlocking(_ event: TelemetryEvent) {
        lock.lock()
        defer { lock.unlock() }
        if let target {
            target.recordBlocking(event)
        } else if !optedOutEarly, buffered.count < Self.bufferLimit {
            // Lost if the process dies first — a quit within a second of
            // launch, before there is a store to write to.
            buffered.append(event)
        }
    }

    func optOut() async {
        await currentTarget(optingOut: true)?.optOut()
    }

    func optIn() async {
        await currentTarget(optingIn: true)?.optIn()
    }

    func flush() async {
        await currentTarget()?.flush()
    }

    func pendingDescriptions() async -> [String] {
        await currentTarget()?.pendingDescriptions() ?? []
    }

    /// Synchronous so the lock is never held across a suspension.
    private func currentTarget(
        optingOut: Bool = false,
        optingIn: Bool = false
    ) -> (any TelemetryRecorder)? {
        lock.lock()
        defer { lock.unlock() }
        if target == nil {
            if optingOut {
                optedOutEarly = true
                buffered = []
            } else if optingIn {
                optedOutEarly = false
            }
        }
        return target
    }
}

@main
struct OreMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var updater: Updater
    @State private var githubUpdater = GitHubUpdater()
    @State private var launchFailure: String?
    @State private var isShowingNewWorkspace = false
    @State private var isShowingPalette = false
    @State private var isShowingFilePalette = false
    @State private var isShowingShortcuts = false
    // Mirror RootView's pane flags so the menu shortcuts can toggle them.
    @AppStorage("ore.showsSidebar") private var showsSidebar = true
    @AppStorage("ore.showsReview") private var showsReview = true

    init() {
        // Before anything reads a preference, so "never set" and "set to the
        // default" are the same value everywhere rather than each caller
        // guessing. Notably the routine-approval switch, which defaults off.
        AppModel.registerDefaults()
        TelemetryConsent.registerDefaults()

        // Anonymous usage analytics. The client itself is built after the
        // first frame (see `DeferredLaunchWork` below) — `make` opens its own
        // SQLite store, which has no business delaying the window. Until then
        // this stand-in buffers, so a launch is still counted when the store
        // below fails to open — that failure is exactly the thing worth
        // knowing about.
        let recorder = DeferredTelemetryRecorder()

        // The store and the core are created before the first window exists, so
        // a broken database surfaces as a message rather than a blank window.
        let created: AppModel
        do {
            let store = try OreStore(path: OreStore.defaultURL)
            created = AppModel(
                client: InProcessCoreClient(
                    store: store,
                    harnessRegistry: .standard(
                        cursorAllowUnprompted: UserDefaults.standard.bool(
                            forKey: "ore.cursorAllowUnprompted"
                        )
                    ),
                    allowAPIKeyFallback: UserDefaults.standard.bool(forKey: "ore.apiKeyFallback")
                ),
                telemetry: recorder
            )
        } catch {
            created = AppModel(
                client: InProcessCoreClient(
                    store: try! OreStore(), harnessRegistry: .standard()
                ),
                telemetry: recorder
            )
            _launchFailure = State(initialValue: String(describing: error))
        }
        _model = State(initialValue: created)
        // Started here, not in the window's task: App Intents, notification
        // actions, and the menu bar all need a live core before — or without —
        // any window existing. `start()` is idempotent, so the window calling
        // it again is harmless.
        created.start()

        // Created stopped; started with the rest of the deferred work.
        let updater = Updater()
        _updater = State(initialValue: updater)
        DeferredLaunchWork.schedule {
            updater.startIfNeeded()
            Task.detached(priority: .utility) {
                // `make` returns a no-op for debug builds, for any build with
                // no key stamped into Info.plist (every contributor's, and
                // every fork's), when ORE_TELEMETRY=0, and when the user has
                // opted out — which it checks itself, synchronously, before
                // returning a recording client, so the launch events below
                // cannot beat consent to the queue. Silence is the default,
                // and nothing downstream needs to know it might be off.
                // See PRIVACY.md.
                let telemetry = TelemetryClient.make(home: OreHome.directory)
                if let facts = telemetry.launch {
                    if facts.isNewInstall {
                        telemetry.recorder.record(.appInstalled(channel: facts.channel))
                    }
                    telemetry.recorder.record(
                        .appLaunched(reason: .cold, daysSinceInstall: facts.daysSinceInstall)
                    )
                }
                recorder.install(telemetry.recorder)
            }
        }
        // A launch can show no window at all (the menu bar keeps ORE alive),
        // and the window's task is what normally runs this.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            DeferredLaunchWork.runIfNeeded()
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView(
                isShowingNewWorkspace: $isShowingNewWorkspace,
                isShowingPalette: $isShowingPalette,
                isShowingFilePalette: $isShowingFilePalette,
                launchFailure: launchFailure,
                isShowingShortcuts: $isShowingShortcuts
            )
            .environment(model)
            .environment(updater)
            .environment(githubUpdater)
            // Match the combined pane minimums while leaving enough room for a
            // real navigation sidebar; narrower windows collapse columns using
            // NavigationSplitView instead of crushing labels and controls.
            .frame(minWidth: 1_080, minHeight: 650)
            .task {
                // First, ahead of anything that can await on the user: this
                // settles whatever the last launch staged, so an update that
                // landed gets its confirmation and one that didn't gets
                // reported, rather than coming back as a fresh "update
                // available" that says nothing about the attempt the user
                // already sat through.
                githubUpdater.reconcilePendingRestart()
                model.start()
                // Sparkle and telemetry setup, a beat after the window is up.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    DeferredLaunchWork.runIfNeeded()
                }
                // Tap ⌥⌘ anywhere to dictate. Without Accessibility this still
                // works while ORE is frontmost, so it is never dead.
                VoiceHotkeyMonitor.shared.start()
                await requestNotificationPermission()
                // Sparkle owns updates for a signed, appcast-wired build; only
                // fall back to the GitHub-releases check when it isn't configured
                // (every unsigned build we pass around today).
                if !updater.isConfigured { await githubUpdater.check() }
            }
        }
        .defaultSize(width: 1_320, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                // ⌘N spins up a fresh worktree in the current tab's project;
                // when there's no active workspace to borrow a project from, it
                // falls back to the picker so the shortcut is never a no-op.
                Button("New Worktree") {
                    if !model.createWorktreeInCurrentProject() { isShowingNewWorkspace = true }
                }
                .keyboardShortcut("n", modifiers: .command)

                // ⇧⌘N opens the full picker to choose project, seed, and harness.
                Button("New Workspace…") { isShowingNewWorkspace = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                // ⌃⌘A — Mail's archive chord. Stages a confirmation; archiving
                // stops the agent and removes the checkout from disk.
                Button("Archive Workspace") {
                    if let id = model.selectedWorkspaceID { model.requestArchive(id) }
                }
                .keyboardShortcut("a", modifiers: [.control, .command])
                .disabled(model.selectedWorkspace == nil)

                Button("Mark All Notifications Read") {
                    model.markAllNotificationsRead()
                }

                Button("Next Git Step") {
                    model.performSuggestedGitAction()
                }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(!model.canPerformSuggestedGitAction)
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand().environment(updater)
                GitHubUpdateCommand().environment(githubUpdater)
            }
            CommandGroup(after: .toolbar) {
                // ⌥⌘A opens the assistant's activity window from anywhere.
                OpenAssistantCommand()
                OpenDreamsCommand().environment(model)

                Button(model.narration.isMuted ? "Unmute Assistant" : "Mute Assistant") {
                    model.narration.setMuted(!model.narration.isMuted)
                }
                .keyboardShortcut("s", modifiers: [.shift, .option, .command])

                Button("Command Palette") { isShowingPalette = true }
                    .keyboardShortcut("k", modifiers: .command)

                Button("Open File…") { isShowingFilePalette = true }
                    .keyboardShortcut("p", modifiers: .command)

                Button("Keyboard Shortcuts") { isShowingShortcuts = true }
                    .keyboardShortcut("/", modifiers: .command)

                Divider()

                Button(showsSidebar ? "Hide Sidebar" : "Show Sidebar") {
                    showsSidebar.toggle()
                }
                .keyboardShortcut("b", modifiers: .command)

                Button(showsReview ? "Hide Review" : "Show Review") {
                    showsReview.toggle()
                }
                .keyboardShortcut("b", modifiers: [.command, .option])

                Divider()

                Button("New Tab") {
                    if let id = model.selectedWorkspaceID { model.createChat(in: id) }
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Close Tab") {
                    guard let workspaceID = model.selectedWorkspaceID else { return }
                    if let path = model.activeFilePath[workspaceID] {
                        model.closeDiffFile(path, in: workspaceID)
                    } else if let chat = model.activeChat(for: workspaceID) {
                        model.requestCloseChat(chat.id, in: workspaceID, title: chat.title)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)

                // ⌥⌘←/→ moves between tabs (Chrome's idiom); ⇧⌘[ / ⇧⌘] do the
                // same. Plain ⌘←/→ is intentionally avoided — it's move-to-line-
                // start/end inside the composer, which the arrows must not steal.
                Button("Previous Tab") {
                    if let id = model.selectedWorkspaceID { model.cycleChat(in: id, offset: -1) }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

                Button("Next Tab") {
                    if let id = model.selectedWorkspaceID { model.cycleChat(in: id, offset: 1) }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

                Button("Previous Chat") {
                    if let id = model.selectedWorkspaceID { model.cycleChat(in: id, offset: -1) }
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Button("Next Chat") {
                    if let id = model.selectedWorkspaceID { model.cycleChat(in: id, offset: 1) }
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Divider()

                Button("Allow Tool") { model.allowPendingPermission() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(model.actionablePermission == nil)

                Button("Deny Tool") { model.denyPendingPermission() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(model.actionablePermission == nil)

                // ⇧⌘U walks everything in the fleet that is waiting on the
                // user — blocked tabs first, then failed turns — so the
                // sidebar's attention badge has a keyboard that answers it.
                Button("Next Needs You") { model.focusNextNeedsYou() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(!model.hasNeedsYouStops)

                Divider()

                // ⌘1–9 jumps straight to a workspace, so switching between
                // parallel agents never requires the mouse.
                ForEach(1...9, id: \.self) { index in
                    Button("Workspace \(index)") { selectWorkspace(at: index - 1) }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(index)")), modifiers: .command
                        )
                }
            }
        }

        Settings { SettingsView().environment(model) }

        // The assistant's only visible surface: an auditable activity log with
        // a composer, in its own window so it floats over any workspace.
        Window("Assistant", id: "assistant") {
            AssistantActivityView()
                .environment(model)
        }
        .defaultSize(width: 560, height: 700)

        Window("Dreams", id: "dreams") {
            DreamReviewWindow()
                .environment(model)
        }
        .defaultSize(width: 920, height: 640)

        // The always-there ORE: fleet status, inline approvals, and the
        // assistant — alive with every window closed.
        MenuBarExtra {
            MenuBarDashboard()
                .environment(model)
        } label: {
            Image(systemName: model.attentionCount > 0 ? "sparkles.square.filled.on.square" : "sparkles")
        }
        .menuBarExtraStyle(.window)
    }

    private func selectWorkspace(at index: Int) {
        let workspaces = model.sortedWorkspaces
        guard workspaces.indices.contains(index) else { return }
        model.selectedWorkspaceID = workspaces[index].id
    }

    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }
}

/// Menu command for the Assistant window. A tiny view rather than a plain
/// `Button` because `openWindow` is an environment action, and only views
/// have environments.
private struct OpenAssistantCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Assistant") { openWindow(id: "assistant") }
            .keyboardShortcut("a", modifiers: [.command, .option])
    }
}

private struct OpenDreamsCommand: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            Button("Dreams") { openWindow(id: "dreams") }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Button("Dream now") {
                model.startDreamNow()
                openWindow(id: "dreams")
            }
        }
        .onChange(of: model.pendingDreamsOpen) { _, wanted in
            guard wanted else { return }
            openWindow(id: "dreams")
            model.consumePendingDreamsOpen()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Binding var isShowingNewWorkspace: Bool
    @Binding var isShowingPalette: Bool
    @Binding var isShowingFilePalette: Bool
    var launchFailure: String?
    @Binding var isShowingShortcuts: Bool

    // Persisted, so the app comes back the way it was left. A layout that
    // resets on every launch makes the terminal feel like a thing you have to
    // re-open rather than a pane that is simply there.
    @AppStorage("ore.showsReview") private var showsReview = true
    @AppStorage("ore.showsSidebar") private var showsSidebar = true
    @AppStorage("ore.bottomPane") private var bottomPaneRaw = BottomPane.none.rawValue
    @AppStorage("ore.terminalHeight") private var terminalHeight = 240.0
    @AppStorage("ore.reviewWidth") private var reviewWidth = 340.0
    @State private var terminalDragStart: CGFloat?
    @State private var reviewDragStart: CGFloat?
    /// The presence strip's usage card (limits, tokens, spend).
    @State private var showsUsagePopover = false

    // Onboarding signals that are not already on the model. Both start nil
    // meaning "not checked", which `Readiness` treats as "say nothing yet"
    // rather than "missing".
    @State private var githubStatus: GitHubClient.Status?
    @State private var hasGitIdentity: Bool?

    /// What the user still needs before ORE is useful to them. Recomputed
    /// from live state rather than cached, so the card also reflects things
    /// breaking later — an agent signing itself out months from now shows up
    /// here without any extra plumbing.
    private var readiness: Readiness {
        Readiness.evaluate(
            harnesses: model.harnesses,
            hasProbedHarnesses: model.hasProbedHarnesses,
            repositoryCount: model.repositories.count,
            workspaceCount: model.workspaces.count,
            github: githubStatus,
            hasGitIdentity: hasGitIdentity
        )
    }

    private var bottomPane: BottomPane {
        get { BottomPane(rawValue: bottomPaneRaw) ?? .none }
        nonmutating set { bottomPaneRaw = newValue.rawValue }
    }

    enum BottomPane: String, CaseIterable {
        case none
        case terminal
    }

    var body: some View {
        // NavigationSplitView gives the sidebar the real system chrome —
        // translucent material, automatic scroll-edge effects, and on macOS 26
        // the proper Liquid Glass treatment — none of which a hand-rolled
        // HSplitView gets. The system also supplies the sidebar toggle in its
        // standard toolbar position, so we no longer add one ourselves.
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            detail
                // The whole detail column sits on the wallpaper's light, the
                // way the system already renders the sidebar. Every pane above
                // is translucent, so this one layer is what makes the window
                // read as glass instead of a grid of white rectangles.
                .background {
                    ZStack {
                        // Full screen deliberately falls back to this calm,
                        // opaque reading surface; the visual-effect view hides
                        // while the window owns the display.
                        OreTheme.Surface.content
                        OreWindowGlassBase()
                        // Smoke in the glass: a bright wallpaper region (a
                        // nebula core, a sunlit photo) otherwise backlights
                        // the prose right through the HUD material. This keeps
                        // the see-through quality while capping how loud
                        // what's behind can get.
                        Color.black.opacity(0.22)
                    }
                    .ignoresSafeArea()
                }
        }
        // The reference design is smoked glass: a dark panel over whatever the
        // desktop is showing, even on a bright wallpaper in light mode. Dark
        // isn't a theme here so much as the color of the glass itself — light-
        // mode vibrancy renders the same materials as a milky white sheet.
        // Scoped to this window (sheets included); Settings and the assistant
        // window still follow the system.
        .preferredColorScheme(.dark)
        // The title bar is part of the same sheet of glass, not a separate
        // opaque lid: with the background hidden, the glass base (which already
        // ignores the safe area) runs all the way to the window's top edge and
        // the toolbar's controls float directly on it.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .overlay(alignment: .top) { banners }
        .overlay { GitHubUpdatePrompt() }
        .overlay {
            if let briefing = model.launchBriefing {
                LaunchBriefingOverlay(briefing: briefing) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        model.dismissLaunchBriefing()
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.launchBriefing == nil)
        .onChange(of: model.pendingDreamsOpen) { _, wanted in
            guard wanted else { return }
            openWindow(id: "dreams")
            model.consumePendingDreamsOpen()
        }
        .sheet(isPresented: $isShowingNewWorkspace) { NewWorkspaceSheet() }
        .sheet(isPresented: $isShowingPalette) { CommandPalette() }
        .sheet(isPresented: $isShowingFilePalette) {
            if let workspace = model.selectedWorkspace {
                FilePalette(workspace: workspace)
            }
        }
        .sheet(isPresented: $isShowingShortcuts) { KeyboardShortcutsView() }
        .modifier(ScriptApprovalDialog())
        .confirmationDialog(
            "Archive \u{201C}\(model.pendingArchive?.workspace.name ?? "workspace")\u{201D}?",
            isPresented: Binding(
                get: { model.pendingArchive != nil },
                set: { if !$0 { model.pendingArchive = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Archive") {
                if let pending = model.pendingArchive { model.archive(pending.id) }
                model.pendingArchive = nil
            }
            Button("Cancel", role: .cancel) { model.pendingArchive = nil }
        } message: {
            Text(
                "This stops the agent and removes the worktree from disk to free "
                + "space. The branch, uncommitted work, and all chats are "
                + "preserved — restore it anytime from the Archived section."
            )
        }
        .confirmationDialog(
            "Delete \u{201C}\(model.pendingArchivedDelete?.workspace.name ?? "workspace")\u{201D}?",
            isPresented: Binding(
                get: { model.pendingArchivedDelete != nil },
                set: { if !$0 { model.pendingArchivedDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Workspace", role: .destructive) {
                if let pending = model.pendingArchivedDelete {
                    model.delete(pending.id, deleteBranch: false)
                }
                model.pendingArchivedDelete = nil
            }
            Button("Delete Workspace and Branch", role: .destructive) {
                if let pending = model.pendingArchivedDelete {
                    model.delete(pending.id, deleteBranch: true)
                }
                model.pendingArchivedDelete = nil
            }
            Button("Cancel", role: .cancel) { model.pendingArchivedDelete = nil }
        } message: {
            Text(
                "This stops the agent and removes the worktree from disk. The "
                + "workspace, its chats, and its preserved uncommitted work are "
                + "deleted permanently. This cannot be undone."
            )
        }
        .onChange(of: model.attentionCount) { _, count in
            // Dock badge counts workspaces needing attention, not events —
            // it should mean "this many agents are waiting on you".
            NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        }
        .toolbar {
            if let workspace = model.selectedWorkspace {
                ToolbarItem(placement: .primaryAction) {
                    GitActionToolbar(workspace: workspace)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showsReview.toggle() } label: {
                    Label(
                        showsReview ? "Hide Review" : "Show Review",
                        systemImage: "sidebar.right"
                    )
                    .symbolVariant(showsReview ? .fill : .none)
                }
                .help(showsReview ? "Hide the review pane" : "Show the review pane")
                .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }
    }

    // Bridges NavigationSplitView's column visibility to the persisted
    // `showsSidebar` flag, so the sidebar comes back the way it was left
    // without introducing a second source of truth.
    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { showsSidebar ? .all : .detailOnly },
            set: { showsSidebar = ($0 != .detailOnly) }
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let failure = launchFailure {
            ContentUnavailableView(
                "ORE couldn't open its database",
                systemImage: "exclamationmark.triangle",
                description: Text(failure)
            )
        } else if let workspace = model.selectedWorkspace {
            Group {
                if bottomPane == .terminal {
                    GeometryReader { geometry in
                        let resolvedTerminalHeight = min(
                            min(max(terminalHeight, 150), 420),
                            max(150, geometry.size.height - 365)
                        )
                        VStack(spacing: 0) {
                            workspaceMain(workspace)
                                .frame(
                                    width: geometry.size.width,
                                    height: max(360, geometry.size.height - resolvedTerminalHeight - 5)
                                )
                                .clipped()
                            terminalResizeHandle
                            TerminalPane(workspace: workspace) { bottomPane = .none }
                                .frame(height: resolvedTerminalHeight)
                        }
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height,
                            alignment: .top
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        workspaceMain(workspace)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                        bottomDock(workspace)
                    }
                }
            }
            .id(workspace.id)
            .background {
                GitDiffPrefetch(workspace: workspace)
            }
        } else {
            welcome
        }
    }

    private var terminalResizeHandle: some View {
        Rectangle()
            .fill(OreTheme.hairline)
            .frame(height: 5)
            .overlay {
                Capsule()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 34, height: 2)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() }
                else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if terminalDragStart == nil { terminalDragStart = terminalHeight }
                    terminalHeight = min(
                        max((terminalDragStart ?? terminalHeight) - value.translation.height, 150),
                        420
                    )
                }
                .onEnded { _ in terminalDragStart = nil })
            .help("Drag to resize the terminal")
    }

    private func workspaceMain(_ workspace: WorkspaceSummary) -> some View {
        GeometryReader { geometry in
            Group {
                if showsReview {
                    let minimumChatWidth = min(420, max(300, geometry.size.width * 0.52))
                    let maximumReviewWidth = max(195, geometry.size.width - minimumChatWidth - 5)
                    let minimumReviewWidth = min(280, maximumReviewWidth)
                    let resolvedReviewWidth = min(
                        max(reviewWidth, minimumReviewWidth),
                        maximumReviewWidth
                    )
                    HStack(spacing: 0) {
                        ChatPane(workspace: workspace)
                            .frame(
                                width: max(0, geometry.size.width - resolvedReviewWidth - 5),
                                height: geometry.size.height
                            )
                            .clipped()
                        reviewResizeHandle
                        ReviewPane(workspace: workspace)
                            // A floating glass inspector: clipped to the card
                            // radius, cut from glass, and inset from the
                            // window's edges so the wallpaper base reads
                            // around it — a pane resting *on* the window
                            // rather than a column welded into it.
                            .clipShape(RoundedRectangle(
                                cornerRadius: OreTheme.cardRadius, style: .continuous
                            ))
                            .oreGlassSurface(
                                .rect(cornerRadius: OreTheme.cardRadius),
                                elevation: .inset
                            )
                            .padding(.vertical, OreTheme.Space.sm)
                            .padding(.trailing, OreTheme.Space.sm)
                            .frame(width: resolvedReviewWidth, height: geometry.size.height)
                            .clipped()
                    }
                } else {
                    ChatPane(workspace: workspace)
                }
            }
            // NavigationSplitView does not always forward a finite ideal size
            // to a lone detail child. Pinning the workspace to the actual
            // viewport prevents an infinitely-flexible empty state from
            // centring a much taller view and pushing tabs/composer offscreen.
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    private var reviewResizeHandle: some View {
        // Invisible except for its grip: the inspector floats now, so a filled
        // divider bar would weld it back onto the chat column.
        Rectangle()
            .fill(.clear)
            .frame(width: 5)
            .overlay {
                Capsule()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 2, height: 34)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() }
                else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if reviewDragStart == nil { reviewDragStart = reviewWidth }
                    reviewWidth = (reviewDragStart ?? reviewWidth) - value.translation.width
                }
                .onEnded { _ in reviewDragStart = nil })
            .help("Drag to resize the workspace inspector")
    }

    /// Pane controls live where their pane opens. A top-toolbar terminal button
    /// that reveals content at the opposite edge of the window feels spatially
    /// disconnected; this compact dock also makes the keyboard shortcut visible.
    ///
    /// Collapsing the pane does not close its terminals — their shells keep
    /// running — so the dock lists them. A bar that said only "Terminal" gave
    /// no sign that three builds were still going underneath it, and reopening
    /// always landed on whichever tab happened to be first.
    private func bottomDock(_ workspace: WorkspaceSummary) -> some View {
        let tabs = TerminalRegistry.shared.tabs[workspace.id] ?? []
        return HStack(spacing: OreTheme.Space.sm) {
            Button { bottomPane = .terminal } label: {
                // An explicit icon + text (not a `Label`) so this matches the
                // sidebar footer's construction exactly and the two bars sit on
                // the same baseline.
                HStack(spacing: OreTheme.Space.sm) {
                    Image(systemName: "terminal")
                        .font(.system(size: OreTheme.Font.body))
                        .foregroundStyle(.secondary)
                    Text("Terminal")
                        .font(.system(size: OreTheme.Font.body, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("t", modifiers: [.command, .option])
            .help("Open the workspace terminal (⌥⌘T)")

            if !tabs.isEmpty {
                Rectangle().fill(OreTheme.hairline).frame(width: 1, height: 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: OreTheme.Space.xs) {
                        ForEach(tabs) { tab in
                            dockTerminalTab(tab, in: workspace)
                        }
                    }
                }
            }

            Spacer(minLength: OreTheme.Space.sm)

            // The agents' presence roster lives here now — bottom-right, out
            // of the tab strip's way, every harness accounted for. Hovering
            // (or clicking) opens the usage card: limits, tokens, spend.
            AgentPresenceStrip(
                chats: model.chats(for: workspace.id).filter {
                    !model.isEphemeralChat($0.id)
                        && !$0.title.hasPrefix(AppModel.ephemeralChatPrefix)
                },
                showsAllHarnesses: true
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { showsUsagePopover = true }
            }
            .onTapGesture { showsUsagePopover.toggle() }
            .popover(isPresented: $showsUsagePopover, arrowEdge: .top) {
                HarnessUsagePopover(snapshots: model.harnessUsage(in: workspace.id))
            }
            .help("Agent usage and limits")

            Rectangle().fill(OreTheme.hairline).frame(width: 1, height: 16)
            openInTools(workspace)
        }
        .padding(.horizontal, OreTheme.Space.md)
        .frame(height: OreTheme.RowHeight.bar)
        // A detached glass capsule floating just off the window's foot — the
        // bottom-bar treatment Apple moved to with Liquid Glass — instead of a
        // full-width strip welded on with a hairline.
        .oreGlassSurface(.capsule, elevation: .inset)
        .padding(.horizontal, OreTheme.Space.md)
        .padding(.vertical, OreTheme.Space.xs + 2)
    }

    /// Hand-off to the tools outside ORE, at the foot of the window where the
    /// other workspace-scoped controls already live.
    ///
    /// A worktree is a real directory, and the honest answer to "what
    /// actually changed" is sometimes Finder or a full editor. Before this,
    /// getting there meant reconstructing the path by hand — the worktree
    /// lives under `~/ore/workspaces/<repo>/<slug>`, which nobody is going to
    /// type.
    @ViewBuilder
    private func openInTools(_ workspace: WorkspaceSummary) -> some View {
        Button {
            ExternalTools.revealInFinder(workspace.worktreePath)
        } label: {
            // Finder's own icon, asked of the system. `folder` is the symbol
            // every *other* folder in ORE uses, so it said "a directory"
            // rather than "Finder" — and sat beside a Cursor button showing
            // its real logo, which made the row look half-finished.
            AppMark(target: .finder, size: 16)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("f", modifiers: [.command, .option])
        .help("Open this worktree in Finder (⌥⌘F)")

        // A real Terminal window, not ORE's pane: the pane dies with the tab,
        // and a long build or an interactive rebase wants to outlive it.
        Button {
            ExternalTools.openInTerminal(workspace.worktreePath)
        } label: {
            AppMark(target: .terminal, size: 16)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("t", modifiers: [.command, .option, .shift])
        .help("Open this worktree in Terminal (⇧⌥⌘T)")

        CopyPathButton(path: workspace.worktreePath)

        // Only when Cursor is actually installed. A button that opens
        // nothing, or worse offers to install something, is worse than no
        // button — and most users will never have it.
        if ExternalTools.isCursorInstalled {
            Button {
                ExternalTools.openInCursor(workspace.worktreePath)
            } label: {
                // The real Cursor mark, which already ships in the bundle for
                // the cursor-agent harness. A generic SF Symbol here would
                // read as "some editor" rather than naming the one it opens.
                HarnessMark(harness: .cursorAgent, size: 15)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("e", modifiers: [.command, .option])
            .help("Open this worktree in Cursor (⌥⌘E)")
        }
    }

    private func dockTerminalTab(_ tab: TerminalTab, in workspace: WorkspaceSummary) -> some View {
        let isActive = TerminalRegistry.shared.activeTab(for: workspace.id) == tab.id
        return Button {
            TerminalRegistry.shared.selectTab(tab.id, for: workspace.id)
            bottomPane = .terminal
        } label: {
            Text(tab.title)
                .font(.system(size: OreTheme.Font.caption, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    isActive ? OreTheme.selectedFill : OreTheme.subduedFill,
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(OrePressableButtonStyle())
        .help("Open \(tab.title)")
    }

    private var welcome: some View {
        VStack(spacing: OreTheme.Space.md) {
            OreAppIcon(size: 72)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
            Text("Build in parallel.")
                .font(.system(size: 32, weight: .semibold))
            Text("Run several coding agents in parallel, each in its own git worktree.")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // The primary action is only the primary action once the user
            // can actually use it. With no agent installed, "New Workspace…"
            // leads to a sheet that cannot produce working work, so the
            // next-step card takes the lead instead.
            if readiness.isReady {
                Button("New Workspace…") { isShowingNewWorkspace = true }
                    .buttonStyle(OrePrimaryButtonStyle())
                    .keyboardShortcut("n", modifiers: .command)
                    .padding(.top, OreTheme.Space.sm)
            }

            NextStepCard(
                readiness: readiness,
                onAddProject: { isShowingNewWorkspace = true },
                onNewWorkspace: { isShowingNewWorkspace = true }
            )
            .padding(.top, OreTheme.Space.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(OreTheme.Space.xl)
        // Probed here rather than at launch: both shell out, and the only
        // place the answers are used is this screen. A user who already has
        // workspaces never pays for them.
        .task {
            async let github = model.githubStatus()
            async let git = Readiness.probeGitIdentity()
            githubStatus = await github
            hasGitIdentity = await git
        }
        // No fill: the welcome floats directly on the window's glass base.
    }

    private var banners: some View {
        VStack(spacing: 6) {
            ForEach(model.banners) { banner in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(banner.message).fontWeight(.medium)
                        if let detail = banner.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    Button {
                        model.dismissBanner(banner.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 560)
                .oreCard(padding: 12, radius: 14)
            }
            HarnessUpdateBanner()
        }
        .padding(.top, OreTheme.Space.sm)
        .animation(.smooth(duration: 0.3), value: model.banners.count)
        .animation(.smooth(duration: 0.3), value: model.pendingHarnessUpdates.count)
    }
}

/// Prefetch lives in its own view so a git-generation bump does not rebuild
/// the window chrome — only this task identity changes.
private struct GitDiffPrefetch: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceSummary

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: "\(workspace.id.rawValue)-\(model.gitGeneration(for: workspace.id))") {
                // The git action lives in the window toolbar now, so it has to
                // stay current even when the review pane is closed.
                model.prefetchDiff(for: workspace)
            }
    }
}

private struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss
    private let shortcuts = [
        ("New workspace", "⌘N"), ("Command palette", "⌘K"),
        ("Open file", "⌘P"), ("Archive workspace", "⌃⌘A"),
        ("New tab", "⌘T"), ("Close tab", "⌘W"),
        ("Previous / next tab", "⌥⌘←  ⌥⌘→"), ("Cancel turn", "⌘."),
        ("Send / queue", "⌘↩"),
        ("Allow / deny tool", "↩  Esc"),
        ("Allow / deny from composer", "⇧⌘A  ⇧⌘D"),
        ("Next thing needing you", "⇧⌘U"),
        ("Dictate prompt", "⌥⌘M"), ("Dictate — tap to start/stop", "⇧⌥"),
        ("Talk to the assistant, anywhere", "hold ⇧⌥"),
        ("Narrate this tab", "⌥⌘S"),
        ("Assistant", "⌥⌘A"),
        ("Next git step", "⌥⌘G"),
        ("Toggle terminal", "⌥⌘T"),
        ("Jump to workspace", "⌘1–9"), ("This cheatsheet", "⌘/"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 9) {
                ForEach(shortcuts, id: \.0) { label, keys in
                    GridRow {
                        Text(label)
                        Text(keys).font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .oreCard(padding: OreTheme.Space.lg)
        .padding(OreTheme.Space.lg)
        .frame(width: 440)
    }
}

private struct FilePalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspace: WorkspaceSummary

    @State private var files: [WorkspaceFileNode] = []
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var focused: Bool

    private var matches: [WorkspaceFileNode] {
        let candidates = flatten(files)
        guard !query.isEmpty else { return Array(candidates.prefix(80)) }
        return candidates
            .filter { $0.path.localizedCaseInsensitiveContains(query) }
            .sorted { score($0.path) < score($1.path) }
            .prefix(80).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Open file in \(workspace.name)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { openSelection() }
                Text("⌘P").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            Divider()

            if files.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(matches, selection: $selection) { node in
                    Button { open(node.path) } label: {
                        HStack(spacing: 10) {
                            SourceFileIcon(path: node.path, size: 17)
                                .frame(width: 16)
                            Text((node.path as NSString).lastPathComponent)
                                .foregroundStyle(.primary)
                            Text((node.path as NSString).deletingLastPathComponent)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tag(node.path)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 620, height: 470)
        .background(.regularMaterial)
        .task {
            files = await model.workspaceFiles(for: workspace)
            selection = matches.first?.path
            focused = true
        }
        .onChange(of: query) { _, _ in selection = matches.first?.path }
    }

    private func flatten(_ nodes: [WorkspaceFileNode]) -> [WorkspaceFileNode] {
        nodes.flatMap { node in
            node.isDirectory ? flatten(node.children ?? []) : [node]
        }
    }

    private func score(_ path: String) -> Int {
        let name = (path as NSString).lastPathComponent
        if name.localizedCaseInsensitiveCompare(query) == .orderedSame { return 0 }
        if name.range(of: query, options: [.caseInsensitive, .anchored]) != nil { return 1 }
        if name.localizedCaseInsensitiveContains(query) { return 2 }
        return 3
    }

    private func openSelection() {
        if let selection { open(selection) }
        else if let first = matches.first { open(first.path) }
    }

    private func open(_ path: String) {
        model.openSourceFile(path, in: workspace.id)
        dismiss()
    }
}

/// The `ore.toml` approval prompt. Kept out of `RootView`'s modifier chain,
/// which is already longer than the type checker will solve in one piece.
private struct ScriptApprovalDialog: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Run this project\u{2019}s scripts?",
            // Not dismissed through the binding: a button's own action already
            // removed its item, and clearing again here would drop the next one.
            isPresented: Binding(
                get: { !model.pendingScriptApprovals.isEmpty },
                set: { _ in }
            ),
            titleVisibility: .visible,
            presenting: model.pendingScriptApprovals.first
        ) { approval in
            Button("Run Scripts") { model.approveRepositoryScripts(approval) }
            Button("Don\u{2019}t Run", role: .cancel) { model.declineRepositoryScripts(approval) }
        } message: { approval in
            Text(Self.message(for: approval))
        }
    }

    static func message(for approval: RepositoryScriptsApproval) -> String {
        let repository = URL(fileURLWithPath: approval.repositoryPath).lastPathComponent
        let commands = [
            approval.setup.map { "Setup, on every new workspace:\n\($0)" },
            approval.archive.map { "Archive, when a workspace is archived:\n\($0)" },
        ].compactMap { $0 }.joined(separator: "\n\n")
        return "The ore.toml in \(repository) wants to run these commands as you. "
            + "Only allow them if you trust this repository.\n\n\(commands)"
    }
}
