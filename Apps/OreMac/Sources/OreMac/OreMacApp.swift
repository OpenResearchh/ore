import AppKit
import OreCore
import OrePersistence
import OreProtocol
import SwiftUI
import UserNotifications

@main
struct OreMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var updater = Updater()
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
        // The store and the core are created before the first window exists, so
        // a broken database surfaces as a message rather than a blank window.
        let created: AppModel
        do {
            let store = try OreStore(path: OreStore.defaultURL)
            let experimental: Set<HarnessKind> = UserDefaults.standard.bool(
                forKey: "ore.cursorExperimental"
            ) ? [.cursorAgent] : []
            created = AppModel(client: InProcessCoreClient(
                store: store,
                harnessRegistry: .standard(
                    enabledExperimental: experimental,
                    cursorAllowUnprompted: UserDefaults.standard.bool(
                        forKey: "ore.cursorAllowUnprompted"
                    )
                ),
                allowAPIKeyFallback: UserDefaults.standard.bool(forKey: "ore.apiKeyFallback")
            ))
        } catch {
            created = AppModel(client: InProcessCoreClient(
                store: try! OreStore(), harnessRegistry: .standard()
            ))
            _launchFailure = State(initialValue: String(describing: error))
        }
        _model = State(initialValue: created)
        // Started here, not in the window's task: App Intents, notification
        // actions, and the menu bar all need a live core before — or without —
        // any window existing. `start()` is idempotent, so the window calling
        // it again is harmless.
        created.start()
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
                model.start()
                // Tap ⌥⌘ anywhere to dictate. Without Accessibility this still
                // works while ORE is frontmost, so it is never dead.
                VoiceHotkeyMonitor.shared.start()
                await requestNotificationPermission()
                // Sparkle owns updates for a signed, appcast-wired build; only
                // fall back to the GitHub-releases check when it isn't configured
                // (every unsigned build we pass around today).
                if !updater.isConfigured { await githubUpdater.check() }
            }
            .onDisappear {
                Task { await model.shutdown() }
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

struct RootView: View {
    @Environment(AppModel.self) private var model
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
        }
        .overlay(alignment: .top) { banners }
        .overlay { GitHubUpdatePrompt() }
        .sheet(isPresented: $isShowingNewWorkspace) { NewWorkspaceSheet() }
        .sheet(isPresented: $isShowingPalette) { CommandPalette() }
        .sheet(isPresented: $isShowingFilePalette) {
            if let workspace = model.selectedWorkspace {
                FilePalette(workspace: workspace)
            }
        }
        .sheet(isPresented: $isShowingShortcuts) { KeyboardShortcutsView() }
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
            .task(id: "\(workspace.id.rawValue)-\(workspace.gitStatus.generation)") {
                // The git action lives in the window toolbar now, so it has to
                // stay current even when the review pane is closed.
                model.prefetchDiff(for: workspace)
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
        Rectangle()
            .fill(OreTheme.hairline)
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
            Text("⌥⌘T")
                .font(.system(size: OreTheme.Font.caption, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, OreTheme.Space.md)
        .frame(height: OreTheme.RowHeight.bar)
        .background(OreTheme.Surface.chrome)
        .overlay(alignment: .top) {
            Rectangle().fill(OreTheme.hairline).frame(height: 1)
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
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Color.accentColor.gradient)
                .symbolEffect(.pulse, options: .nonRepeating)
            Text("Build in parallel.")
                .font(.system(size: 32, weight: .semibold))
            Text("Run several coding agents in parallel, each in its own git worktree.")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("New Workspace…") { isShowingNewWorkspace = true }
                .buttonStyle(OrePrimaryButtonStyle())
                .keyboardShortcut("n", modifiers: .command)
                .padding(.top, OreTheme.Space.sm)

            if !model.harnesses.isEmpty {
                HarnessStatusList(harnesses: model.harnesses)
                    .padding(.top, OreTheme.Space.md)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(OreTheme.Space.xl)
        .background(OreTheme.Surface.chrome)
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
        }
        .padding(.top, OreTheme.Space.sm)
        .animation(.smooth(duration: 0.3), value: model.banners.count)
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

/// The onboarding doctor's result, shown until the user has a workspace.
struct HarnessStatusList: View {
    let harnesses: [HarnessProbeResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(harnesses, id: \.kind) { harness in
                HStack(spacing: 6) {
                    Image(systemName: harness.isReady
                        ? "checkmark.circle.fill"
                        : (harness.isInstalled ? "exclamationmark.circle.fill" : "xmark.circle"))
                        .foregroundStyle(harness.isReady
                            ? Color.green
                            : (harness.isInstalled ? .orange : .secondary))

                    Text(harness.kind.displayName).fontWeight(.medium)

                    if let version = harness.version {
                        Text(version).font(.caption).foregroundStyle(.secondary)
                    }

                    if !harness.isInstalled {
                        Text("not installed").font(.caption).foregroundStyle(.secondary)
                    } else if harness.authState == .notAuthenticated {
                        // The fix is a specific command; saying so beats
                        // "authentication failed".
                        Text(harness.kind == .claudeCode ? "run `claude /login`" : "run `codex login`")
                            .font(.caption.monospaced())
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .oreCard(padding: 12, radius: 14)
    }
}
