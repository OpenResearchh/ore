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
        let failure: String?
        do {
            let store = try OreStore(path: OreStore.defaultURL)
            created = AppModel(
                client: InProcessCoreClient(
                    store: store,
                    harnessRegistry: .standard(
                        cursorAllowUnprompted: UserDefaults.standard.bool(
                            forKey: "ore.cursorAllowUnprompted"
                        ),
                        // The registry needs this too, not just the sessions
                        // below: probes strip provider credentials by default,
                        // so without it an ANTHROPIC_API_KEY user is told to
                        // sign in to a CLI that is already authenticated.
                        allowAPIKeyFallback: UserDefaults.standard.bool(
                            forKey: "ore.apiKeyFallback"
                        )
                    ),
                    allowAPIKeyFallback: UserDefaults.standard.bool(forKey: "ore.apiKeyFallback")
                ),
                telemetry: recorder
            )
            failure = nil
        } catch {
            // `OreStore.unopened()`, not the in-memory store this used to
            // substitute: that one worked. The sidebar filled, ⌘N made
            // worktrees, agents ran — and the whole day went away on quit,
            // behind a raw error in one pane of an otherwise normal window.
            created = AppModel(
                client: InProcessCoreClient(
                    store: OreStore.unopened(), harnessRegistry: .standard()
                ),
                telemetry: recorder
            )
            failure = LaunchFailure.message(for: error)
            _launchFailure = State(initialValue: failure)
        }
        _model = State(initialValue: created)
        // Started here, not in the window's task: App Intents, notification
        // actions, and the menu bar all need a live core before — or without —
        // any window existing. `start()` is idempotent, so the window calling
        // it again is harmless.
        //
        // Not started at all when the store failed: no engines, no harness
        // probe, no `AppModel.shared` for an App Intent to find. The window is
        // a failure screen and there is nothing behind it to drive.
        if failure == nil { created.start() }

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
            //
            // The height floor is lower than it looks like it should be, and
            // deliberately so: a minimum on the root of a `WindowGroup`
            // constrains the *content view*, not the window. Where the window
            // is shorter than the floor — a tiled half-screen, a display whose
            // visible frame is smaller than the app assumed — SwiftUI still
            // lays the root out at the floor and centres it, so the overflow
            // is clipped off the top and the bottom at once. That takes the
            // tab strips with it at one end and the sidebar's control bar at
            // the other, which is a far worse failure than a cramped window.
            .frame(minWidth: 1_080, minHeight: 560)
            .task {
                // First, ahead of anything that can await on the user: this
                // settles whatever the last launch staged, so an update that
                // landed gets its confirmation and one that didn't gets
                // reported, rather than coming back as a fresh "update
                // available" that says nothing about the attempt the user
                // already sat through.
                githubUpdater.reconcilePendingRestart()
                if launchFailure == nil { model.start() }
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
        // Sized to fit the smallest screen ORE is likely to open on rather
        // than the largest it looks good on. A 13" MacBook Air runs 1280x800
        // points by default, which leaves about 775 once the menu bar has its
        // share — so the old 1320x820 was wider *and* taller than the space it
        // was being asked to appear in, and the first launch on one of those
        // put the composer and the sidebar's controls below the bottom of the
        // screen. Anything larger is a window the user has resized, and that
        // is remembered.
        .defaultSize(width: 1_200, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                // ⌘N spins up a fresh worktree in the current tab's project;
                // when there's no active workspace to borrow a project from, it
                // falls back to the picker so the shortcut is never a no-op.
                //
                // Both disabled when the store never opened: a workspace made
                // now is a worktree on disk with no row to remember it.
                Button("New Worktree") {
                    if !model.createWorktreeInCurrentProject() { isShowingNewWorkspace = true }
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!LaunchFailure.commandsEnabled(launchFailure: launchFailure))

                // ⇧⌘N opens the full picker to choose project, seed, and harness.
                Button("New Workspace…") { isShowingNewWorkspace = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!LaunchFailure.commandsEnabled(launchFailure: launchFailure))

                Divider()

                // Each item that reads the model is its own view: a command
                // read here is a read by the whole `Scene`, so one agent's
                // status flip re-evaluated every window group, every command
                // and the menu bar label — mid-scroll, sixty times a second
                // while a fleet was busy. See `FleetCommand`.
                ArchiveWorkspaceCommand().environment(model)

                Button("Mark All Notifications Read") {
                    model.markAllNotificationsRead()
                }

                NextGitStepCommand().environment(model)
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand().environment(updater)
                GitHubUpdateCommand().environment(githubUpdater)
            }
            CommandGroup(after: .toolbar) {
                // ⌥⌘A opens the assistant's activity window from anywhere.
                OpenAssistantCommand()
                OpenDreamsCommand().environment(model)

                MuteAssistantCommand().environment(model)

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

                PendingPermissionCommands().environment(model)

                // ⇧⌘U walks everything in the fleet that is waiting on the
                // user — blocked tabs first, then failed turns — so the
                // sidebar's attention badge has a keyboard that answers it.
                NextNeedsYouCommand().environment(model)

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
            MenuBarStatusIcon().environment(model)
        }
        .menuBarExtraStyle(.window)
    }

    /// Through the model, not `sortedWorkspaces`: while the sidebar is holding
    /// its order still under the pointer, ⌘3 has to land on the row *showing*
    /// a ⌘3 badge, not on whatever the live sort has since promoted to third.
    /// Reading a function rather than a property also keeps the scene from
    /// observing the fleet list. See `SidebarOrderHold`.
    private func selectWorkspace(at index: Int) {
        guard let id = model.shortcutWorkspaceID(at: index) else { return }
        model.selectedWorkspaceID = id
    }

    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }
}

/// ⌃⌘A — Mail's archive chord. Stages a confirmation; archiving stops the
/// agent and removes the checkout from disk.
private struct ArchiveWorkspaceCommand: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Archive Workspace") {
            if let id = model.selectedWorkspaceID { model.requestArchive(id) }
        }
        .keyboardShortcut("a", modifiers: [.control, .command])
        .disabled(model.selectedWorkspace == nil)
    }
}

/// ⌥⌘G runs whatever the review pane is offering: open a PR, continue after a
/// merge, and so on. Its enablement reads the selected workspace's cached diff
/// and in-flight git ops, which move on every agent write.
private struct NextGitStepCommand: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Next Git Step") {
            model.performSuggestedGitAction()
        }
        .keyboardShortcut("g", modifiers: [.command, .option])
        .disabled(!model.canPerformSuggestedGitAction)
    }
}

private struct MuteAssistantCommand: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(model.narration.isMuted ? "Unmute Assistant" : "Mute Assistant") {
            model.narration.setMuted(!model.narration.isMuted)
        }
        .keyboardShortcut("s", modifiers: [.shift, .option, .command])
    }
}

/// ⇧⌘A / ⇧⌘D answer the selected tab's oldest generic permission. Both read
/// `actionablePermission`, which walks the selected chat's pending requests —
/// so it lands here, where a permission arriving only re-evaluates two menu
/// items.
private struct PendingPermissionCommands: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let isActionable = model.actionablePermission != nil
        Button("Allow Tool") { model.allowPendingPermission() }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!isActionable)

        Button("Deny Tool") { model.denyPendingPermission() }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!isActionable)
    }
}

private struct NextNeedsYouCommand: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Next Needs You") { model.focusNextNeedsYou() }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(!model.hasNeedsYouStops)
    }
}

/// The status item's glyph. Its own view so the stored attention count is
/// observed here and not by the whole `Scene`.
private struct MenuBarStatusIcon: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Image(systemName: model.attentionCount > 0
            ? "sparkles.square.filled.on.square"
            : "sparkles")
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

/// How a launch that could not open the database is presented.
///
/// Extracted from the views so the two decisions that matter — that the
/// message names the file, and that the new-workspace commands go dead — can
/// be tested without a window.
enum LaunchFailure {
    /// What the failure screen says.
    ///
    /// The path is the part the user can act on: "database is locked" is a
    /// sentence about a file nobody has ever told them the location of, and
    /// Reveal in Finder has to lead somewhere they recognise.
    static func message(
        for error: any Error,
        storePath: String = OreStore.defaultURL.path
    ) -> String {
        // A typed store error is already a sentence; a GRDB error is not, and
        // its raw description is the only place the SQLite message survives.
        let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return "\(detail)\n\nORE's database lives at \(storePath)"
    }

    /// ⌘N and ⇧⌘N. A workspace created now is a worktree on disk with no row
    /// anywhere to remember it by.
    static func commandsEnabled(launchFailure: String?) -> Bool {
        launchFailure == nil
    }
}

/// The entire window when the store would not open.
private struct LaunchFailureScreen: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("ORE couldn\u{2019}t open its database", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Reveal in Finder") {
                // Rooted at the enclosing folder so the window opens on `~/ore`
                // with the file selected, rather than on a fresh Finder root.
                _ = NSWorkspace.shared.selectFile(
                    OreStore.defaultURL.path,
                    inFileViewerRootedAtPath: OreStore.defaultURL
                        .deletingLastPathComponent().path
                )
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .textSelection(.enabled)
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
    @AppStorage("ore.reviewWidth") private var reviewWidth = 340.0
    @State private var reviewDragStart: CGFloat?
    /// The presence strip's usage card (limits, tokens, spend).
    @State private var showsUsagePopover = false

    // Onboarding signals that are not already on the model. Both start nil
    // meaning "not checked", which `Readiness` treats as "say nothing yet"
    // rather than "missing".
    @State private var githubStatus: GitHubClient.Status?
    @State private var gitAvailability: GitAvailability?
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
            git: gitAvailability,
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
        if let launchFailure {
            // The whole window, not a pane of it. A failure screen beside a
            // working sidebar and a live ⌘N is an invitation to do work that
            // cannot be saved.
            LaunchFailureScreen(message: launchFailure)
        } else {
            workspaceWindow
        }
    }

    private var workspaceWindow: some View {
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
                    HStack(spacing: 8) {
                        WorkspaceReviewButton(workspace: workspace)
                            // The toolbar packs this group hard against
                            // whatever ends the title area, and two rounded
                            // edges meeting with nothing between them read as
                            // an overlap rather than as two controls. Wider
                            // than the 8 pt between siblings on purpose: this
                            // gap separates the group from the chrome, not one
                            // button from the next.
                            .padding(.leading, 12)
                        GitActionToolbar(workspace: workspace)
                    }
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
        if let workspace = model.selectedWorkspace {
            // One structural path whether or not the terminal is open: only the
            // bottom slot changes identity. The terminal branch used to wrap
            // `workspaceMain` in a GeometryReader the dock branch didn't have,
            // so ⌥⌘T rebuilt ChatPane, the transcript table, the review pane
            // and the source editor — and every one lost its scroll position.
            WorkspaceBottomSplit(showsTerminal: bottomPane == .terminal) {
                workspaceMain(workspace)
            } dock: {
                bottomDock(workspace)
            } terminal: {
                TerminalPane(workspace: workspace) { bottomPane = .none }
            }
            .id(workspace.id)
            .background {
                GitDiffPrefetch(workspace: workspace)
            }
        } else {
            welcome
        }
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
                                height: geometry.size.height,
                                alignment: .top
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
                            // Top, not the default centre — the same lesson
                            // `ChatPane` already learned about its own stack.
                            // The inspector's fixed chrome (tab row, stack
                            // strip, ship status) can add up to more than a
                            // short pane has, and a centred overflow spills
                            // at *both* ends: the tab row loses its top to
                            // the pane's edge, and on a shorter window the
                            // whole row is carried outside the card. Anchored
                            // here, the overflow goes one way, and it is the
                            // status strip at the bottom that gives, not the
                            // navigation at the top.
                            .frame(
                                width: resolvedReviewWidth,
                                height: geometry.size.height,
                                alignment: .top
                            )
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
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
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
            async let git = Readiness.probeGit()
            githubStatus = await github
            let (availability, identity) = await git
            gitAvailability = availability
            hasGitIdentity = identity
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

/// The terminal pane's height rules, pulled out of the view so they can be
/// tested without a window.
enum TerminalSplitLayout {
    static let minimumHeight: CGFloat = 150
    static let maximumHeight: CGFloat = 420
    /// What the workspace above keeps however far the terminal is dragged:
    /// the chat's tab strip, a few rows, and the composer.
    static let workspaceReserve: CGFloat = 365

    /// A dragged or persisted height, held to the pane's own bounds.
    static func clamped(_ requested: CGFloat) -> CGFloat {
        min(max(requested, minimumHeight), maximumHeight)
    }

    /// The height actually laid out. `containerHeight` is zero until the
    /// column has been measured once; the request alone decides until then,
    /// rather than flashing the minimum for a frame.
    static func resolvedHeight(requested: CGFloat, containerHeight: CGFloat) -> CGFloat {
        let height = clamped(requested)
        guard containerHeight > 0 else { return height }
        return min(height, max(minimumHeight, containerHeight - workspaceReserve))
    }
}

/// The workspace column over its bottom slot: the collapsed dock bar, or the
/// terminal under a drag handle.
///
/// `main` sits at the same structural position in both states, so toggling the
/// terminal only swaps the slot beneath it. The column height and the live drag
/// are this view's own state, so a window resize or a divider drag re-runs this
/// small body instead of `RootView`'s.
private struct WorkspaceBottomSplit<Main: View, Dock: View, Terminal: View>: View {
    let showsTerminal: Bool
    @ViewBuilder var main: Main
    @ViewBuilder var dock: Dock
    @ViewBuilder var terminal: Terminal

    @AppStorage("ore.terminalHeight") private var terminalHeight = 240.0
    /// Whole points, so sub-point layout jitter doesn't write state.
    @State private var containerHeight: CGFloat = 0
    /// The height while the divider is held. Persisted only when the drag ends:
    /// writing `@AppStorage` per mouse event re-laid out the transcript and
    /// round-tripped UserDefaults on every one.
    @State private var dragHeight: CGFloat?
    @State private var dragStart: CGFloat?

    private var resolvedTerminalHeight: CGFloat {
        TerminalSplitLayout.resolvedHeight(
            requested: dragHeight ?? terminalHeight,
            containerHeight: containerHeight
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            main
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            if showsTerminal {
                resizeHandle
                terminal
                    .frame(height: resolvedTerminalHeight)
            } else {
                dock
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { noteContainerHeight(proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, height in
                        noteContainerHeight(height)
                    }
            }
        }
    }

    private func noteContainerHeight(_ height: CGFloat) {
        let rounded = height.rounded()
        if rounded != containerHeight { containerHeight = rounded }
    }

    private var resizeHandle: some View {
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
                    if dragStart == nil { dragStart = dragHeight ?? terminalHeight }
                    let next = TerminalSplitLayout.clamped(
                        (dragStart ?? terminalHeight) - value.translation.height
                    )
                    if next != dragHeight { dragHeight = next }
                }
                .onEnded { _ in
                    if let dragHeight { terminalHeight = dragHeight }
                    dragHeight = nil
                    dragStart = nil
                })
            .help("Drag to resize the terminal")
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
            approval.run.map { "Run, with \u{2318}R in the terminal:\n\($0)" },
            approval.archive.map { "Archive, when a workspace is archived:\n\($0)" },
        ].compactMap { $0 }.joined(separator: "\n\n")
        return "The ore.toml in \(repository) wants to run these commands as you. "
            + "Only allow them if you trust this repository.\n\n\(commands)"
    }
}
