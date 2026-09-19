import AppKit
import ImageIO
import OreGit
import OreProtocol
import SwiftUI

/// The list of parallel workspaces.
///
/// This is the app's real home screen. With several agents running at once the
/// question a developer has is never "what is everything doing" — it's "which
/// one needs me right now", and the sidebar is built to answer that at a
/// glance: anything blocked or finished sorts to the top and carries a dot,
/// and there is at most one dot per workspace.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var showArchived = false
    @State private var renameWorkspace: WorkspaceSummary?
    @State private var renameText = ""
    /// The order on screen while the person is pointing at or scrolling the
    /// list; nil while the list follows the live order. See `SidebarOrderHold`.
    @State private var heldOrder: SidebarHeldOrder?
    /// Pointer and scroll bookkeeping for the hold. A plain reference, not
    /// view state: live scroll notifications arrive during the gesture, and
    /// writing observed state from them would re-run this body mid-scroll —
    /// the very thing the hold exists to prevent.
    @State private var holdClock = SidebarHoldClock()
    @Environment(\.controlActiveState) private var controlActiveState
    @AppStorage("ore.collapsedRepositories") private var collapsedRepositoriesRaw = ""
    @AppStorage("ore.sidebar.filter") private var filterRaw = SidebarFilter.all.rawValue

    /// Debug: the pinned strip as fixed chrome under the filter tabs instead of
    /// a row inside the List, so no horizontal scroll view ever sits in the
    /// list's scroll content. Off by default: the strip then stays put while
    /// the list scrolls, which is a visible change.
    private static let pinnedStripOutsideList = UserDefaults.standard.bool(
        forKey: "ore.debug.sidebarStripOutsideList"
    )

    private var collapsedRepositories: Set<String> {
        Set(collapsedRepositoriesRaw.split(separator: "\n").map(String.init))
    }

    private var filter: SidebarFilter {
        SidebarFilter(rawValue: filterRaw) ?? .all
    }

    /// ⌘1–9 jumps to a workspace by its position in the displayed order.
    /// Mapping each of the first nine to its number lets the sidebar show the
    /// shortcut inline, so switching between parallel agents is discoverable,
    /// not hidden.
    private static func workspaceShortcuts(_ ordered: [WorkspaceSummary]) -> [WorkspaceID: Int] {
        var result: [WorkspaceID: Int] = [:]
        for (index, workspace) in ordered.prefix(9).enumerated() {
            result[workspace.id] = index + 1
        }
        return result
    }

    /// The layout as the model stands, under the current filter. Only the
    /// Active tab reads the active set: under All, reading it would re-run the
    /// whole list every time an agent started or stopped.
    private func resolveLayout(held: SidebarHeldOrder?) -> SidebarLayout {
        SidebarLayout(
            workspaces: model.sortedWorkspaces,
            activeIDs: filter == .active ? model.activeWorkspaceIDs : nil,
            held: held
        )
    }

    var body: some View {
        // Resolved once per pass and handed down. The fleet-wide answers (who
        // is active, how many are working) are stored on the model and change
        // only when they do, and each row reads its own chats — so one tab's
        // status flip re-runs that row, not this list.
        let layout = resolveLayout(held: heldOrder)
        let shortcuts = Self.workspaceShortcuts(layout.ordered)
        let selectedID = model.selectedWorkspaceID
        List {
            if layout.ordered.isEmpty {
                emptyState
            } else if filter == .active, layout.listed.isEmpty, layout.pinned.isEmpty {
                Text("All agents are idle")
                    .font(.system(size: OreTheme.Font.body))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, OreTheme.Space.sm)
            }

            if !Self.pinnedStripOutsideList, !layout.pinned.isEmpty {
                Section {
                    PinnedStrip(workspaces: layout.pinned)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(
                            top: 2, leading: OreTheme.Space.sm,
                            bottom: OreTheme.Space.xs, trailing: OreTheme.Space.sm
                        ))
                } header: {
                    Text("Pinned")
                }
            }

            ForEach(layout.groups) { repository in
                DisclosureGroup(isExpanded: repositoryBinding(repository.path)) {
                    ForEach(repository.workspaces) { workspace in
                        WorkspaceRow(
                            workspace: workspace,
                            identity: model.researchIdentity(for: workspace),
                            isSelected: selectedID == workspace.id,
                            shortcutIndex: shortcuts[workspace.id],
                            onRename: {
                                renameText = workspace.name
                                renameWorkspace = workspace
                            }
                        )
                            .padding(.leading, OreTheme.Space.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectedWorkspaceID = workspace.id }
                            // One concrete background faded in and out: swapping
                            // between two type-erased views rebuilt the row
                            // background on every selection change.
                            .listRowBackground(
                                SidebarSelectionBackground()
                                    .opacity(selectedID == workspace.id ? 1 : 0)
                            )
                            .contextMenu { menu(for: workspace) }
                    }
                } label: {
                    RepositoryRow(repository: repository.name, workspaces: repository.workspaces)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // The chevron alone was a small target; the whole header
                        // row toggles expansion now, which is what a click here
                        // reads as.
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let binding = repositoryBinding(repository.path)
                            withAnimation(.easeOut(duration: 0.2)) {
                                binding.wrappedValue.toggle()
                            }
                        }
                        .contextMenu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [URL(fileURLWithPath: repository.path)]
                                )
                            }
                            Divider()
                            Button("Delete Project\u{2026}", role: .destructive) {
                                model.requestProjectDelete(repository.path)
                            }
                        }
                }
                .listRowSeparator(.hidden)
            }

            if !model.archivedWorkspaces.isEmpty {
                Section(isExpanded: $showArchived) {
                    ForEach(model.archivedWorkspaces) { workspace in
                        ArchivedWorkspaceRow(workspace: workspace)
                            .contextMenu {
                                Button("Restore") { model.unarchive(workspace.id) }
                                Button("Copy Branch Name") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        workspace.branch, forType: .string
                                    )
                                }
                                Divider()
                                Button("Delete Permanently…", role: .destructive) {
                                    model.requestPermanentDelete(workspace)
                                }
                            }
                    }
                } header: {
                    Text(archivedHeader)
                }
            }
        }
        .onChange(of: model.selectedWorkspaceID) { _, selected in
            guard let selected,
                  let workspace = model.sortedWorkspaces.first(where: { $0.id == selected })
            else { return }
            setRepository(workspace.repositoryPath, expanded: true)
        }
        // Warm every row's portrait up front instead of on first render, so
        // faces appear with the list rather than popping in as you scroll.
        .task(id: layout.ordered.count) {
            for workspace in model.sortedWorkspaces {
                guard !Task.isCancelled else { return }
                guard let identity = model.researchIdentity(for: workspace) else { continue }
                _ = await ScientistPortraitCache.load(for: identity)
            }
        }
        .listStyle(.sidebar)
        // Inside a NavigationSplitView the system already renders the sidebar's
        // translucent material (and Liquid Glass on macOS 26); hiding the List's
        // own background lets that show through. A manual glassEffect here would
        // fight the system chrome, so it's intentionally gone.
        .scrollContentBackground(.hidden)
        // No resting track: under "always show scroll bars" the legacy track
        // is an opaque strip down the glass, and macOS `List` ignores
        // `.scrollIndicators` — the probe reaches the AppKit scroller directly.
        .scrollIndicators(.hidden)
        .background(OreListScrollerOverlay())
        .background(SidebarScrollProbe(
            onScrollStart: noteScrollStarted,
            onScrollEnd: noteScrollEnded
        ))
        .safeAreaInset(edge: .top, spacing: 0) {
            if !layout.ordered.isEmpty {
                VStack(spacing: 0) {
                    SidebarFilterTabs(filterRaw: $filterRaw, allCount: layout.ordered.count)
                        .padding(.horizontal, OreTheme.Space.sm)
                        .padding(.top, OreTheme.Space.xs)
                        .padding(.bottom, OreTheme.Space.sm)
                    if Self.pinnedStripOutsideList, !layout.pinned.isEmpty {
                        PinnedStrip(workspaces: layout.pinned)
                            .padding(.horizontal, OreTheme.Space.sm)
                            .padding(.bottom, OreTheme.Space.sm)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // Above the bar rather than inside it: the bar is one fixed
                // row of controls, and this is prose that has to wrap.
                SidebarNarrationNotice()
                HStack(spacing: OreTheme.Space.sm) {
                    SidebarPresencePill(total: layout.ordered.count)
                    Spacer()
                    // The assistant's global mute sits with the app-wide controls,
                    // not in a tab: it silences every workspace at once.
                    SidebarMuteButton()
                    SettingsLink {
                        Image(systemName: "gearshape")
                            .font(.system(size: OreTheme.Font.body))
                            .frame(width: 28, height: OreTheme.RowHeight.bar)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Settings (⌘,)")
                }
                .padding(.leading, OreTheme.Space.md)
                .padding(.trailing, OreTheme.Space.xs)
                .frame(height: OreTheme.RowHeight.bar)
                .layoutProbe("sidebar-controls")
                // No bar, no hairline: the system sidebar is already Liquid
                // Glass on macOS 26, and layering a second material over it is
                // exactly the glass-on-glass stacking Apple warns against. The
                // connected pill carries its own glass; rows scrolling under
                // pick up the system's scroll-edge treatment.
            }
        }
        .onHover { pointerMoved(inside: $0) }
        // A hold normally ends when the pointer leaves. Tracking areas are
        // key-window-scoped, so a pointer parked over the sidebar while the
        // user switches apps never reports an exit — and the order would stay
        // frozen for as long as they were away. Treat losing the window as
        // losing the pointer.
        .onChange(of: controlActiveState) { _, state in
            guard state == .inactive else { return }
            holdClock.pointerInside = false
            settleHold()
        }
        // ⌘1–9 lives in the app's commands, which cannot see this view's state.
        // While the order is held the model is told what is on screen; nil
        // hands the shortcuts back to the live order.
        .onChange(of: heldOrder == nil ? nil : layout.shortcutOrder, initial: true) { _, order in
            model.sidebarShortcutOrder = order
        }
        .onDisappear {
            holdClock.reset()
            heldOrder = nil
            model.sidebarShortcutOrder = nil
        }
        .alert("Rename Workspace", isPresented: Binding(
            get: { renameWorkspace != nil },
            set: { if !$0 { renameWorkspace = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let id = renameWorkspace?.id { model.rename(id, to: renameText) }
                renameWorkspace = nil
            }
            Button("Cancel", role: .cancel) { renameWorkspace = nil }
        }
    }

    // MARK: Order hold

    private func pointerMoved(inside: Bool) {
        holdClock.pointerInside = inside
        if inside { beginHold() } else { settleHold() }
    }

    private func noteScrollStarted() {
        holdClock.isScrolling = true
        beginHold()
    }

    private func noteScrollEnded() {
        holdClock.isScrolling = false
        holdClock.lastScrollEnd = Date()
        settleHold()
    }

    /// Freezes what is on screen now. Only the first call writes view state;
    /// every later one while holding just cancels a pending release.
    private func beginHold() {
        holdClock.cancelRelease()
        guard heldOrder == nil else { return }
        heldOrder = resolveLayout(held: nil).heldOrder
    }

    private func settleHold() {
        holdClock.cancelRelease()
        switch SidebarOrderHold.release(
            pointerInside: holdClock.pointerInside,
            isScrolling: holdClock.isScrolling,
            lastScrollEnd: holdClock.lastScrollEnd,
            now: Date()
        ) {
        case .hold:
            return
        case .now:
            releaseHold()
        case .after(let delay):
            holdClock.releaseTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                settleHold()
            }
        }
    }

    private func releaseHold() {
        guard heldOrder != nil else { return }
        // Whatever re-sorted while the list held still moves now, visibly,
        // instead of jumping out from under the pointer.
        withAnimation(.snappy) { heldOrder = nil }
    }

    /// "Archived (3) · 1.2 GB freed" — the total makes the payoff of parking
    /// finished work visible at a glance.
    private var archivedHeader: String {
        let workspaces = model.archivedWorkspaces
        let freedBytes = workspaces.compactMap(\.archivedDiskBytes).reduce(0, +)
        guard freedBytes > 0 else { return "Archived (\(workspaces.count))" }
        let freed = ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file)
        return "Archived (\(workspaces.count)) · \(freed) freed"
    }

    private func repositoryBinding(_ path: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedRepositories.contains(path) },
            set: { expanded in setRepository(path, expanded: expanded) }
        )
    }

    private func setRepository(_ path: String, expanded: Bool) {
        var values = collapsedRepositories
        if expanded { values.remove(path) } else { values.insert(path) }
        collapsedRepositoriesRaw = values.sorted().joined(separator: "\n")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.sm) {
            Text("No workspaces")
                .font(.headline)
            Text("Press ⌘N to start one. Each runs an agent in its own git worktree, "
                + "so several can work at once without colliding.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, OreTheme.Space.sm)
    }

    @ViewBuilder
    private func menu(for workspace: WorkspaceSummary) -> some View {
        WorkspaceActionsMenu(
            workspace: workspace,
            onRename: {
                renameText = workspace.name
                renameWorkspace = workspace
            }
        )
    }
}

/// What the sidebar lists, in the order it lists it: the pinned strip, then
/// repository groups. Pure so the order hold is testable without a window.
/// Internal for tests.
struct SidebarLayout {
    struct RepositoryGroup: Identifiable {
        var id: String { path }
        var path: String
        var name: String
        var workspaces: [WorkspaceSummary]

        /// The most recent activity across the group's workspaces, used to float
        /// the last-worked-in project to the top of the sidebar.
        var latestActivity: Date? {
            workspaces.compactMap(\.lastActivity).max()
        }
    }

    /// Every unarchived workspace in displayed order — `sortedWorkspaces`, or
    /// the held order while the sidebar holds still. ⌘1–9 counts along this.
    var ordered: [WorkspaceSummary]
    var pinned: [WorkspaceSummary]
    /// What the main list shows: pinned rows live in their own strip, and the
    /// Active tab narrows to workspaces that are doing something or need you.
    var listed: [WorkspaceSummary]
    var groups: [RepositoryGroup]

    /// `activeIDs` is nil under the All tab. `held` re-expresses the live data
    /// in the order last shown; see `SidebarOrderHold.merge`.
    init(workspaces live: [WorkspaceSummary], activeIDs: Set<WorkspaceID>?, held: SidebarHeldOrder?) {
        if let held {
            let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            ordered = SidebarOrderHold.merge(held: held.workspaceIDs, live: live.map(\.id))
                .compactMap { byID[$0] }
        } else {
            ordered = live
        }
        pinned = ordered.filter(\.isPinned)
        listed = ordered.filter { !$0.isPinned && (activeIDs?.contains($0.id) ?? true) }
        var groups = Self.repositoryGroups(listed)
        if let held {
            let order = SidebarOrderHold.merge(held: held.repositoryPaths, live: groups.map(\.path))
            let position = Dictionary(
                order.enumerated().map { ($1, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            groups.sort { (position[$0.path] ?? .max) < (position[$1.path] ?? .max) }
        }
        self.groups = groups
    }

    /// What to freeze when a hold begins: exactly this layout's order.
    var heldOrder: SidebarHeldOrder {
        SidebarHeldOrder(workspaceIDs: ordered.map(\.id), repositoryPaths: groups.map(\.path))
    }

    var shortcutOrder: [WorkspaceID] {
        ordered.prefix(9).map(\.id)
    }

    private static func repositoryGroups(_ listedWorkspaces: [WorkspaceSummary]) -> [RepositoryGroup] {
        Dictionary(grouping: listedWorkspaces, by: \.repositoryPath)
            .map { path, workspaces in
                RepositoryGroup(
                    path: path,
                    name: (path as NSString).lastPathComponent,
                    workspaces: workspaces
                )
            }
            // Most recently worked-in project on top: the one you touched last is
            // the one you're most likely coming back to. `sortedWorkspaces` is
            // already recency-ordered, so a group's latest activity is its first
            // workspace's.
            .sorted { first, second in
                let firstActivity = first.latestActivity ?? .distantPast
                let secondActivity = second.latestActivity ?? .distantPast
                if firstActivity != secondActivity { return firstActivity > secondActivity }

                // Dictionary iteration order is deliberately unspecified. Most
                // untouched repositories have no activity date, so without a
                // tie-breaker every unrelated model update could swap those
                // project sections even though neither project had changed.
                return first.path < second.path
            }
    }
}

/// The sidebar's order at the moment a hold began.
struct SidebarHeldOrder: Equatable {
    var workspaceIDs: [WorkspaceID]
    var repositoryPaths: [String]
}

/// Keeps rows from moving under the person using them.
///
/// The live order re-sorts on attention and recency, so with agents running
/// rows and whole project sections jumped mid-scroll, and a click could land
/// on whatever slid into place. While the pointer is over the sidebar — or a
/// flick's momentum is still settling — the displayed order holds; status,
/// names, and counts keep updating in place, and the queued order is applied
/// with an animation once the hold ends.
enum SidebarOrderHold {
    /// How long after a scroll gesture ends the order still holds, so a flick
    /// that carries the pointer out of the sidebar doesn't reorder under the
    /// last rows it showed.
    static let scrollGrace: TimeInterval = 1.5

    enum Release: Equatable {
        case hold
        case now
        case after(TimeInterval)
    }

    static func release(
        pointerInside: Bool,
        isScrolling: Bool,
        lastScrollEnd: Date?,
        now: Date
    ) -> Release {
        if pointerInside || isScrolling { return .hold }
        guard let lastScrollEnd else { return .now }
        let remaining = scrollGrace - now.timeIntervalSince(lastScrollEnd)
        return remaining > 0 ? .after(remaining) : .now
    }

    /// `live` in `held`'s order. Anything gone is dropped at once — a row for
    /// a removed workspace can't stay — and anything new takes its live
    /// position, since a new row is almost always one the person just made.
    static func merge<ID: Hashable>(held: [ID], live: [ID]) -> [ID] {
        let liveSet = Set(live)
        var result = held.filter { liveSet.contains($0) }
        let kept = Set(result)
        for (index, id) in live.enumerated() where !kept.contains(id) {
            result.insert(id, at: min(index, result.count))
        }
        return result
    }

    /// The workspace ⌘(index+1) selects: the held order when the sidebar is
    /// holding, the live order otherwise, and never one that has since gone.
    static func shortcutTarget(at index: Int, held: [WorkspaceID]?, live: [WorkspaceID]) -> WorkspaceID? {
        let order = held ?? live
        guard order.indices.contains(index) else { return nil }
        let id = order[index]
        return held == nil || live.contains(id) ? id : nil
    }
}

/// Mutable, unobserved companion to the hold. See `Sidebar.holdClock`.
@MainActor
final class SidebarHoldClock {
    var pointerInside = false
    var isScrolling = false
    var lastScrollEnd: Date?
    var releaseTask: Task<Void, Never>?

    func cancelRelease() {
        releaseTask?.cancel()
        releaseTask = nil
    }

    func reset() {
        cancelRelease()
        pointerInside = false
        isScrolling = false
        lastScrollEnd = nil
    }
}

/// Reports the sidebar List's live scroll gestures — a trackpad flick and its
/// momentum — so the order hold can outlast a pointer that leaves mid-flick.
/// The List's scroll view is a sibling of this background probe, found the
/// way `OreScrollerOverlay` finds it: climb a few levels, search down.
private struct SidebarScrollProbe: NSViewRepresentable {
    var onScrollStart: () -> Void
    var onScrollEnd: () -> Void

    final class Probe: NSView {
        var onScrollStart: (() -> Void)?
        var onScrollEnd: (() -> Void)?
        private weak var observed: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // The sibling scroll view may not be installed on this pass.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.attachIfNeeded() }
            }
        }

        /// Cheap once attached, so `updateNSView` can call it on every pass:
        /// the List's scroll view can be installed several passes after the
        /// probe lands, and a single async retry would miss it.
        func attachIfNeeded() {
            if let observed, observed.window != nil { return }
            guard let scroll = findScrollView() else { return }
            let center = NotificationCenter.default
            if let observed {
                center.removeObserver(self, name: nil, object: observed)
            }
            // Selector-based, so the center drops them when the probe goes.
            center.addObserver(
                self, selector: #selector(liveScrollStarted),
                name: NSScrollView.willStartLiveScrollNotification, object: scroll
            )
            center.addObserver(
                self, selector: #selector(liveScrollEnded),
                name: NSScrollView.didEndLiveScrollNotification, object: scroll
            )
            observed = scroll
        }

        @objc private func liveScrollStarted(_ note: Notification) { onScrollStart?() }
        @objc private func liveScrollEnded(_ note: Notification) { onScrollEnd?() }

        /// The List's own scroll view: table-backed and holding the probe's
        /// centre. A pinned strip's horizontal scroll view never qualifies.
        private func findScrollView() -> NSScrollView? {
            guard let window else { return nil }
            let centre = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            var root: NSView? = superview
            for _ in 0..<5 {
                guard let candidate = root else { break }
                if let found = Self.tableScrollView(in: candidate, window: window, containing: centre) {
                    return found
                }
                root = candidate.superview
            }
            return nil
        }

        private static func tableScrollView(
            in view: NSView, window: NSWindow, containing point: NSPoint
        ) -> NSScrollView? {
            if let scroll = view as? NSScrollView,
               scroll.window === window,
               scroll.documentView is NSTableView,
               scroll.convert(scroll.bounds, to: nil).contains(point) {
                return scroll
            }
            for subview in view.subviews {
                if let found = tableScrollView(in: subview, window: window, containing: point) {
                    return found
                }
            }
            return nil
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onScrollStart = onScrollStart
        probe.onScrollEnd = onScrollEnd
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.onScrollStart = onScrollStart
        probe.onScrollEnd = onScrollEnd
        probe.attachIfNeeded()
    }
}

/// The selected row's pill.
private struct SidebarSelectionBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: OreTheme.pillRadius, style: .continuous)
            .fill(OreTheme.sidebarSelectedFill)
            .overlay {
                RoundedRectangle(cornerRadius: OreTheme.pillRadius, style: .continuous)
                    .strokeBorder(OreTheme.selectedStroke, lineWidth: 0.75)
            }
            .padding(.vertical, 2)
    }
}

/// The reference design's segmented capsule: All | Active, each with its
/// count. Selection stays quiet (a primary wash, not accent) so the blue
/// pill remains reserved for the selected workspace row. Its own view so the
/// Active count's changes redraw the capsule, not the list.
private struct SidebarFilterTabs: View {
    @Environment(AppModel.self) private var model
    @Binding var filterRaw: String
    let allCount: Int

    var body: some View {
        let filter = SidebarFilter(rawValue: filterRaw) ?? .all
        let activeCount = model.activeWorkspaceIDs.count
        HStack(spacing: 2) {
            ForEach(SidebarFilter.allCases) { tab in
                let isOn = filter == tab
                Button {
                    filterRaw = tab.rawValue
                } label: {
                    HStack(spacing: 4) {
                        Text(tab.title)
                            .font(.system(size: OreTheme.Font.body, weight: isOn ? .semibold : .regular))
                        Text("\(tab == .all ? allCount : activeCount)")
                            .font(.system(size: OreTheme.Font.caption).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background(
                        isOn ? Color.primary.opacity(0.1) : .clear,
                        in: Capsule()
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(OrePressableButtonStyle())
            }
        }
        .padding(3)
        .modifier(SidebarGlassCapsule())
        .animation(.easeOut(duration: 0.15), value: filterRaw)
    }
}

/// The footer's presence pill: green while any agent is live, quiet gray
/// otherwise — the sidebar's own "Connected" light. Reads the working count
/// itself, so agents starting and stopping redraw only the pill.
private struct SidebarPresencePill: View {
    @Environment(AppModel.self) private var model
    let total: Int

    var body: some View {
        let working = model.workingCount
        let isLive = working > 0
        HStack(spacing: 6) {
            Circle()
                .fill(isLive ? OreTheme.Presence.active : OreTheme.Presence.idle)
                .frame(width: 7, height: 7)
            // "Workspaces", not "active" — the filter tab above already uses
            // "Active" to mean something narrower, and one word carrying two
            // meanings on one surface reads as a bug.
            Text(isLive
                ? "\(working) working"
                : "\(total) workspace\(total == 1 ? "" : "s")")
                .font(.system(size: OreTheme.Font.caption, weight: .medium))
        }
        .foregroundStyle(isLive ? OreTheme.Presence.active : Color.secondary)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .modifier(SidebarGlassCapsule(
            tint: isLive ? OreTheme.Presence.active.opacity(0.12) : nil
        ))
        .animation(.easeOut(duration: 0.2), value: isLive)
    }
}

/// Why narration isn't using the voice the user chose — and, where one could
/// help, the button that fixes it.
///
/// The mismatch is heard, not seen. `NarrationEngine` attempts the neural load
/// once per session and never retries, so somebody who picked the neural voice
/// and then never reopened Settings heard the system voice indefinitely with
/// nothing anywhere saying why. This sits above the sidebar's own speaker
/// control, which is where a person who has noticed the wrong voice already
/// goes looking.
///
/// Not in the assistant HUD, which would be the more obvious home: that panel
/// sets `ignoresMouseEvents` whenever it is showing the voice pill alone, so
/// a Download button drawn there could not be pressed.
private struct SidebarNarrationNotice: View {
    @Environment(AppModel.self) private var model
    /// Dismissed for this session only, and only until the notice itself
    /// changes. `.unsupported` carries no button to resolve it, so without
    /// this it would sit in the sidebar forever repeating a fact the user has
    /// read and cannot act on.
    @State private var dismissed: NeuralVoiceNotice?

    var body: some View {
        let notice = model.narration.neuralVoiceNotice
        if let notice, notice != dismissed {
            HStack(alignment: .top, spacing: OreTheme.Space.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: OreTheme.Font.caption))
                    .foregroundStyle(.orange)
                Text(notice.message)
                    .font(.system(size: OreTheme.Font.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    // No button when the notice carries no title: that is the
                    // case where a retry loads the same files on the same
                    // hardware to the same end.
                    if let title = notice.retryTitle {
                        Button(title) { model.narration.retryNeuralVoice() }
                            .buttonStyle(.link)
                            .font(.system(size: OreTheme.Font.caption, weight: .medium))
                    }
                    Button { dismissed = notice } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss")
                }
            }
            .padding(.horizontal, OreTheme.Space.md)
            .padding(.vertical, OreTheme.Space.sm)
            .background(OreTheme.subduedFill)
            .overlay(alignment: .top) {
                Rectangle().fill(OreTheme.hairline).frame(height: 1)
            }
        }
    }
}

private struct SidebarMuteButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let isMuted = model.narration.isMuted
        Button {
            model.narration.setMuted(!isMuted)
        } label: {
            Image(systemName: isMuted ? "speaker.slash" : "speaker.wave.2")
                .font(.system(size: OreTheme.Font.body))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: OreTheme.RowHeight.bar)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isMuted
            ? "Unmute the assistant (⇧⌥⌘S)"
            : "Mute the assistant (⇧⌥⌘S)")
        .accessibilityLabel(isMuted ? "Unmute assistant" : "Mute assistant")
    }
}

/// Liquid Glass on macOS 26 for the sidebar's capsule chrome (filter tabs,
/// presence pill); the flat fill + hairline treatment everywhere older.
private struct SidebarGlassCapsule: ViewModifier {
    var tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                content.glassEffect(.regular.tint(tint), in: .capsule)
            } else {
                content.glassEffect(.regular, in: .capsule)
            }
        } else {
            content
                .background(tint ?? OreTheme.subduedFill, in: Capsule())
                .overlay { Capsule().stroke(OreTheme.hairline, lineWidth: 1) }
        }
    }
}

/// The sidebar's two lenses: everything, or only workspaces that are doing
/// something / waiting on the person.
enum SidebarFilter: String, CaseIterable, Identifiable {
    case all, active

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .active: "Active"
        }
    }
}

/// The status to actually surface for a workspace. `workspace.status` can be
/// stuck on an old failed tab; this instead lets live, attention-worthy states
/// win, and otherwise reflects the *most recently active* chat — so a stale
/// failure stops dominating once a newer tab has moved on. Shared by the row,
/// the avatar ring, and the Active filter so they never disagree.
func sidebarEffectiveStatus(
    for workspace: WorkspaceSummary, chats: [ChatSummary]
) -> AgentStatus {
    guard !chats.isEmpty else { return workspace.status }
    if chats.contains(where: { $0.status == .runningTool }) { return .runningTool }
    if chats.contains(where: { $0.status == .thinking }) { return .thinking }
    if chats.contains(where: { $0.status == .requesting }) { return .requesting }
    if chats.contains(where: { $0.status == .awaitingInput }) { return .awaitingInput }
    let latest = chats.max {
        ($0.lastActivity ?? $0.createdAt) < ($1.lastActivity ?? $1.createdAt)
    }
    return latest?.status ?? workspace.status
}

/// The fleet-wide answers the sidebar shows — which workspaces are active, how
/// many are working — in one pass. `AppModel` runs it when the fleet or a chat
/// changes and stores the result, so no view recomputes it per render.
/// Internal for tests.
enum SidebarFleetActivity {
    struct Summary: Equatable {
        var activeIDs: Set<WorkspaceID> = []
        var workingCount = 0
    }

    /// "Active" is the reference design's question — who is doing something or
    /// waiting on me — not merely "exists": an agent working, blocked, failed,
    /// or finished with unread output all count.
    static func isActive(_ workspace: WorkspaceSummary, status: AgentStatus) -> Bool {
        if workspace.hasUnread { return true }
        switch status {
        case .thinking, .requesting, .runningTool, .awaitingInput, .failed: return true
        case .idle, .interrupted: return false
        }
    }

    static func isWorking(_ status: AgentStatus) -> Bool {
        switch status {
        case .thinking, .requesting, .runningTool: return true
        default: return false
        }
    }

    /// `workspaces` are the unarchived ones; `chats` returns a workspace's
    /// open tabs.
    static func resolve(
        _ workspaces: [WorkspaceSummary],
        chats: (WorkspaceID) -> [ChatSummary]
    ) -> Summary {
        var summary = Summary()
        for workspace in workspaces {
            let status = sidebarEffectiveStatus(for: workspace, chats: chats(workspace.id))
            if isActive(workspace, status: status) { summary.activeIDs.insert(workspace.id) }
            if isWorking(status) { summary.workingCount += 1 }
        }
        return summary
    }
}

/// "3h", "5d" — the reference design's timestamp column. A full relative
/// sentence ("5 days ago") is the row's widest element for its least important
/// fact; the compact form keeps the name in charge. Internal for tests.
func sidebarCompactAge(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    let minutes = Int(seconds / 60)
    if minutes < 1 { return "now" }
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    if days < 7 { return "\(days)d" }
    if days < 30 { return "\(days / 7)w" }
    if days < 365 { return "\(days / 30)mo" }
    return "\(days / 365)y"
}

/// The reference design's pinned strip: a horizontal row of avatars above the
/// list, one tap from anywhere. Pinned workspaces live here instead of in the
/// repository groups so pinning visibly promotes them.
private struct PinnedStrip: View {
    let workspaces: [WorkspaceSummary]

    var body: some View {
        // A horizontal scroll view inside the List can catch the vertical
        // gesture meant for the list. Only use one when the avatars actually
        // overflow; when they fit, the same row is laid out plainly.
        ViewThatFits(in: .horizontal) {
            avatars
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                avatars
            }
        }
    }

    private var avatars: some View {
        HStack(alignment: .top, spacing: OreTheme.Space.md) {
            ForEach(workspaces) { workspace in
                PinnedWorkspace(workspace: workspace)
            }
        }
        .padding(.horizontal, OreTheme.Space.xs)
    }
}

/// One pinned avatar. Reads selection and identity itself, so selecting a
/// workspace redraws the strip's items rather than the list around them.
private struct PinnedWorkspace: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceSummary

    var body: some View {
        let isSelected = model.selectedWorkspaceID == workspace.id
        VStack(spacing: 4) {
            WorkspaceAvatar(
                workspace: workspace,
                size: 36,
                identity: model.researchIdentity(for: workspace)
            )
            Text(workspace.name)
                .font(.system(
                    size: OreTheme.Font.caption,
                    weight: isSelected ? .semibold : .regular
                ))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .lineLimit(1)
                .frame(maxWidth: 56)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedWorkspaceID = workspace.id }
        .contextMenu {
            WorkspaceActionsMenu(workspace: workspace, onRename: {})
        }
        .help(workspace.name)
    }
}

/// In-memory portrait cache so every sidebar row doesn't re-hit the corpus on
/// disk. Misses are remembered too — a scientist with no cached portrait must
/// not retrigger a lookup on every redraw.
@MainActor
private enum ScientistPortraitCache {
    private static var images: [String: NSImage] = [:]
    private static var misses: Set<String> = []
    /// One decode per portrait even when the warm-up pass and a row ask at once.
    private static var loads: [String: Task<NSImage?, Never>] = [:]
    /// The largest avatar is 36 pt; three pixels a point covers Retina with
    /// room. The corpus portraits are far larger than any avatar needs.
    private nonisolated static let maxPixelSize = 108

    /// `@unchecked`: the image is created in the detached task and only read
    /// on the main actor after it is handed over.
    private struct Decoded: @unchecked Sendable {
        var image: NSImage?
    }

    static func load(for identity: ResearchIdentity) async -> NSImage? {
        let slug = identity.slug
        if let image = images[slug] { return image }
        if misses.contains(slug) { return nil }
        if let pending = loads[slug] { return await pending.value }
        let load = Task<NSImage?, Never> { @MainActor in
            guard let profile = await ScientistCorpus.shared.profile(for: identity),
                  let url = ScientistCorpus.shared.imageURL(for: profile) else { return nil }
            // Decoded at avatar size off the main actor. `NSImage(contentsOf:)`
            // here decoded the full portrait on main for a 28 pt circle.
            return await Task.detached(priority: .utility) {
                Self.decodeThumbnail(at: url)
            }.value.image
        }
        loads[slug] = load
        let image = await load.value
        loads[slug] = nil
        if let image {
            images[slug] = image
        } else {
            misses.insert(slug)
        }
        return image
    }

    nonisolated private static func decodeThumbnail(at url: URL) -> Decoded {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            // Decode here, in this task, rather than when SwiftUI draws it.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            return Decoded(image: NSImage(contentsOf: url))
        }
        return Decoded(image: NSImage(
            cgImage: thumbnail,
            size: NSSize(width: thumbnail.width, height: thumbnail.height)
        ))
    }
}

/// One workspace as a face: the scientist's portrait when the workspace is
/// named for one (monogram until it loads, or when it isn't), a status ring
/// that spins while the agent works, and the harness mark tucked in the
/// corner so you can tell which agent lives here without reading anything.
private struct WorkspaceAvatar: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceSummary
    var size: CGFloat = 28
    /// The scientist this workspace is named for, when it is.
    var identity: ResearchIdentity?
    /// On the selected row's solid accent pill, colored rings vanish — the
    /// ring turns white there instead.
    var onProminentFill = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var portrait: NSImage?

    /// Read here, by id, so a tab's status change redraws this avatar only.
    private var status: AgentStatus {
        sidebarEffectiveStatus(for: workspace, chats: model.chats(for: workspace.id))
    }

    var body: some View {
        let status = self.status
        Group {
            if let portrait {
                Image(nsImage: portrait)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                OreMonogram(name: workspace.name, size: size)
            }
        }
        .task(id: identity?.slug) {
            guard let identity else {
                portrait = nil
                return
            }
            portrait = await ScientistPortraitCache.load(for: identity)
        }
        .overlay { statusRing(status) }
        .overlay(alignment: .bottomTrailing) {
            HarnessMark(harness: workspace.harness, size: size * 0.42)
                .offset(x: 2, y: 2)
        }
        .help(statusHelp(status))
    }

    @ViewBuilder
    private func statusRing(_ status: AgentStatus) -> some View {
        switch status {
        case .thinking, .requesting, .runningTool:
            if reduceMotion {
                ring(onProminentFill ? .white : OreTheme.Status.running)
            } else {
                SpinningRing(color: onProminentFill ? .white : OreTheme.Status.running)
                    .padding(-2.5)
            }
        case .awaitingInput:
            ring(onProminentFill ? .white : OreTheme.Status.needsYou)
        case .failed:
            ring(onProminentFill ? .white : OreTheme.Status.failed)
        case .interrupted:
            ring(onProminentFill ? .white : OreTheme.Status.interrupted)
        case .idle:
            EmptyView()
        }
    }

    private func ring(_ color: Color) -> some View {
        Circle()
            .stroke(color, lineWidth: 2)
            .padding(-2.5)
    }

    private func statusHelp(_ status: AgentStatus) -> String {
        switch status {
        case .thinking, .requesting, .runningTool: "Agent working"
        case .awaitingInput: "Needs your attention"
        case .failed: "Agent failed"
        case .interrupted: "Agent interrupted"
        case .idle: workspace.hasUnread ? "Finished with unread activity" : "No agent is working"
        }
    }
}

/// A short arc orbiting the avatar while the agent works — the row-scale
/// version of the composer's sweeping busy border. Animated by the render
/// server (`OrbitingArc`), so a sidebar full of busy rows ticks nothing here.
private struct SpinningRing: View {
    let color: Color
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        OrbitingArc(color: color, isPaused: controlActiveState != .key)
    }
}

/// Actions shared by the row's ⋯ menu and the right-click context menu.
private struct WorkspaceActionsMenu: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceSummary
    let onRename: () -> Void

    var body: some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(
                nil, inFileViewerRootedAtPath: workspace.worktreePath
            )
        }
        Button("Copy Branch Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(workspace.branch, forType: .string)
        }
        Button("Rename…") { onRename() }
        Button(workspace.isPinned ? "Unpin" : "Pin") {
            model.setPinned(!workspace.isPinned, for: workspace.id)
        }
        Divider()
        Button("New Workspace Stacked on This") {
            model.createWorkspace(CreateWorkspaceRequest(
                repositoryPath: workspace.repositoryPath,
                name: "\(workspace.name) follow-up",
                seed: .workspace(workspace.id),
                harness: workspace.harness
            ))
        }
        Divider()
        Button("Archive…") { model.requestArchive(workspace.id) }
        Button("Delete Worktree…", role: .destructive) {
            model.requestPermanentDelete(workspace)
        }
    }
}

/// One parked workspace: what it was, when it was parked, and what parking it
/// gave back. Restore is inline because it's the only action that brings the
/// row back to life; everything else lives in the context menu.
private struct ArchivedWorkspaceRow: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(workspace.branch)
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail {
                        Text("·").font(.system(size: 10.5))
                        Text(detail).font(.system(size: 10.5))
                    }
                }
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: OreTheme.Space.sm)
            Button("Restore") { model.unarchive(workspace.id) }
                .buttonStyle(.link)
                .font(.system(size: OreTheme.Font.body))
        }
        .padding(.vertical, 1)
    }

    private var detail: String? {
        var parts: [String] = []
        if let archivedAt = workspace.archivedAt {
            parts.append(archivedAt.formatted(.relative(presentation: .named)))
        }
        if let bytes = workspace.archivedDiskBytes, bytes > 0 {
            let freed = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            parts.append("freed \(freed)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct RepositoryRow: View {
    @Environment(AppModel.self) private var model
    let repository: String
    let workspaces: [WorkspaceSummary]

    var body: some View {
        HStack(spacing: OreTheme.Space.sm) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(repository)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            let changes = workspaces.reduce(0) { $0 + model.gitChrome(for: $1.id).changedFileCount }
            if changes > 0 {
                Text("\(changes)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("\(workspaces.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 36)
    }
}

private struct WorkspaceRow: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceSummary
    /// The scientist this workspace is named for — drives the portrait avatar.
    var identity: ResearchIdentity?
    let isSelected: Bool
    /// The ⌘-number that jumps here, when this workspace is one of the first
    /// nine. Shown small in the row so the shortcut is discoverable.
    var shortcutIndex: Int?
    let onRename: () -> Void
    @State private var isHovering = false
    /// The mock's chat-list texture: each idle row carries a one-line snippet
    /// of the last exchange, loaded lazily the way portraits are. Status still
    /// outranks it — a row that needs you says so, not what was said last.
    @State private var digest: String?

    /// This workspace's open tabs, read by id: the row observes its own list,
    /// so a chat changing elsewhere in the fleet never redraws it.
    private var chats: [ChatSummary] {
        model.chats(for: workspace.id)
    }

    var body: some View {
        HStack(spacing: OreTheme.Space.sm) {
            WorkspaceAvatar(
                workspace: workspace,
                size: 28,
                identity: identity,
                onProminentFill: false
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(workspace.name)
                        .font(.system(
                            size: 14,
                            weight: effectiveNeedsAttention ? .bold
                                : workspace.hasUnread || isSelected ? .semibold : .regular
                        ))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    if let pullRequestState {
                        SidebarPullRequestBadge(
                            state: pullRequestState,
                            isSelected: isSelected
                        )
                    }

                    Spacer(minLength: 4)

                    if let activity = workspace.lastActivity {
                        Text(sidebarCompactAge(activity))
                            .font(.system(size: 10.5, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color(.tertiaryLabelColor))
                    }
                }

                // The second line has to earn its place: a column of rows all
                // saying "Ready" is noise. Quiet idle rows with no diff stay
                // one line tall.
                if hasSecondLine {
                    HStack(spacing: 6) {
                        if workspace.stackedOn != nil {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.secondary)
                        }
                        if let secondLineText {
                            Text(secondLineText)
                                .font(.system(size: 12))
                                .foregroundStyle(effectiveNeedsAttention ? indicatorColor : Color.secondary)
                                .lineLimit(1)
                        }

                        // Left-aligned with the text, not floated to the far
                        // edge — the counts belong to the row's sentence, and
                        // right-aligned they read as a detached column.
                        HStack(spacing: 4) {
                            if git.insertions > 0 {
                                Text("+\(git.insertions)")
                                    .foregroundStyle(OreTheme.added)
                            }
                            if git.deletions > 0 {
                                Text("−\(git.deletions)")
                                    .foregroundStyle(OreTheme.removed)
                            }
                        }
                        .font(.caption2.monospacedDigit())

                        Spacer(minLength: 0)
                    }
                }
            }

            if workspace.hasUnread, effectiveStatus == .idle, !isSelected {
                // Count-free by design: a workspace either has something new or
                // it doesn't. See WorkspaceSummary.hasUnread.
                Circle()
                    .fill(OreTheme.Status.unread)
                    .frame(width: 8, height: 8)
                    .help("Finished with unread activity")
            }

            trailingSlot
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Re-fetched only when the workspace actually has new activity, so the
        // sidebar never polls; a quiet row costs one query per turn completed,
        // and the model's cache means scrolling back to a row costs none.
        .task(id: digestKey) {
            let fetched = await model.lastTurnDigest(
                for: workspace.id, lastActivity: workspace.lastActivity
            )
            if fetched != digest { digest = fetched }
        }
    }

    /// The ⋯ menu and the ⌘-number share one fixed slot. The menu stays
    /// mounted and only fades in: it is an NSPopUpButton underneath, and
    /// mounting one whenever a row slid under a resting pointer was real work
    /// mid-scroll, and relaid out the row around it.
    private var trailingSlot: some View {
        let showsActions = isHovering || isSelected
        return ZStack {
            if let shortcutIndex {
                Text("⌘\(shortcutIndex)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .help("Jump here with ⌘\(shortcutIndex)")
                    .opacity(showsActions ? 0 : 1)
            }
            Menu {
                WorkspaceActionsMenu(workspace: workspace, onRename: onRename)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .help("Workspace actions")
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
            .accessibilityHidden(!showsActions)
        }
        .frame(width: 24, height: 24)
    }

    /// Identity for the snippet load: a new turn moves `lastActivity`, which
    /// re-runs the task; anything else leaves the cached line alone.
    private var digestKey: String {
        "\(workspace.id.rawValue)-\(workspace.lastActivity?.timeIntervalSinceReferenceDate ?? 0)"
    }

    /// Status wins the second line; the conversation snippet fills it the rest
    /// of the time, which is what makes the list read like the mock's chat
    /// list instead of a table of idle machines.
    private var secondLineText: String? {
        statusLine ?? shownDigest
    }

    /// The model's snippet for this exact activity stamp when it has one, so
    /// a row that scrolls back into view is two lines tall from its first
    /// frame instead of growing once its read lands.
    private var shownDigest: String? {
        if let cached = model.cachedTurnDigest(for: workspace.id, lastActivity: workspace.lastActivity) {
            return cached
        }
        return digest
    }

    private var effectiveStatus: AgentStatus {
        sidebarEffectiveStatus(for: workspace, chats: chats)
    }

    private var effectiveNeedsAttention: Bool {
        effectiveStatus == .awaitingInput || effectiveStatus == .failed
    }

    private var runningAgentCount: Int {
        chats.filter { summary in
            summary.status == .thinking || summary.status == .requesting || summary.status == .runningTool
        }.count
    }

    private var indicatorColor: Color {
        switch effectiveStatus {
        case .awaitingInput: return OreTheme.Status.needsYou
        case .failed: return OreTheme.Status.failed
        case .thinking, .requesting, .runningTool: return OreTheme.Status.running
        case .interrupted: return OreTheme.Status.interrupted
        case .idle: return workspace.hasUnread ? OreTheme.Status.unread : .clear
        }
    }

    /// What the second line says, or nil when it would only say "Ready".
    private var statusLine: String? {
        switch effectiveStatus {
        case .awaitingInput: return "Needs you"
        case .runningTool:
            return runningAgentCount > 1 ? "\(runningAgentCount) agents using tools" : "Running a tool"
        case .thinking:
            return runningAgentCount > 1 ? "\(runningAgentCount) agents thinking" : "Thinking"
        case .requesting:
            return runningAgentCount > 1 ? "\(runningAgentCount) agents working" : "Working"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .idle: return workspace.hasUnread ? "Finished — new activity" : nil
        }
    }

    private var git: GitStatusSummary { model.gitChrome(for: workspace.id) }

    private var pullRequestState: SidebarPullRequestState? {
        SidebarPullRequestState(pullRequest: model.pullRequest(for: workspace.id))
    }

    private var hasSecondLine: Bool {
        secondLineText != nil
            || workspace.stackedOn != nil
            || git.insertions > 0
            || git.deletions > 0
    }
}

enum SidebarPullRequestState: Equatable {
    case open(number: Int)
    case merged(number: Int)

    init?(number: Int, state: String) {
        switch state.uppercased() {
        case "OPEN": self = .open(number: number)
        case "MERGED": self = .merged(number: number)
        default: return nil
        }
    }

    init?(pullRequest: GitHubClient.PullRequest?) {
        guard let pullRequest else { return nil }
        self.init(number: pullRequest.number, state: pullRequest.state)
    }

    var number: Int {
        switch self {
        case .open(let number), .merged(let number): return number
        }
    }

    var icon: String {
        switch self {
        case .open: return "arrow.triangle.pull"
        case .merged: return "arrow.triangle.merge"
        }
    }

    var help: String {
        switch self {
        case .open(let number): return "Pull request #\(number) is open"
        case .merged(let number): return "Pull request #\(number) was merged"
        }
    }
}

private struct SidebarPullRequestBadge: View {
    let state: SidebarPullRequestState
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 2.5) {
            Image(systemName: state.icon)
                .font(.system(size: 8, weight: .semibold))
            Text("#\(state.number)")
                .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(tone.opacity(isSelected ? 0.2 : 0.1), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(foreground.opacity(isSelected ? 0.7 : 0.55), lineWidth: 0.75)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.help)
        .help(state.help)
    }

    private var tone: Color {
        switch state {
        case .open: return Color(nsColor: .systemGreen)
        case .merged: return Color(nsColor: .systemPurple)
        }
    }

    private var foreground: Color {
        tone
    }
}
