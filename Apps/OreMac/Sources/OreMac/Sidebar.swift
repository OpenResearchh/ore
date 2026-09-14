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
    @AppStorage("ore.collapsedRepositories") private var collapsedRepositoriesRaw = ""
    @AppStorage("ore.sidebar.filter") private var filterRaw = SidebarFilter.all.rawValue

    private var collapsedRepositories: Set<String> {
        Set(collapsedRepositoriesRaw.split(separator: "\n").map(String.init))
    }

    private var filter: SidebarFilter {
        SidebarFilter(rawValue: filterRaw) ?? .all
    }

    /// "Active" is the reference design's question — who is doing something or
    /// waiting on me — not merely "exists": an agent working, blocked, failed,
    /// or finished with unread output all count.
    private static func isActive(_ workspace: WorkspaceSummary, chats: [ChatSummary]) -> Bool {
        if workspace.hasUnread { return true }
        switch sidebarEffectiveStatus(for: workspace, chats: chats) {
        case .thinking, .requesting, .runningTool, .awaitingInput, .failed: return true
        case .idle, .interrupted: return false
        }
    }

    private struct RepositoryGroup: Identifiable {
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

    /// ⌘1–9 jumps to a workspace by its position in `sortedWorkspaces`. Mapping
    /// each of the first nine to its number lets the sidebar show the shortcut
    /// inline, so switching between parallel agents is discoverable, not hidden.
    private static func workspaceShortcuts(_ sortedWorkspaces: [WorkspaceSummary]) -> [WorkspaceID: Int] {
        var result: [WorkspaceID: Int] = [:]
        for (index, workspace) in sortedWorkspaces.prefix(9).enumerated() {
            result[workspace.id] = index + 1
        }
        return result
    }

    var body: some View {
        // Everything derived from the fleet is resolved once per pass and
        // handed down. `sortedWorkspaces` sorts on every read and `chats(for:)`
        // filters every summary; as computed properties they ran several times
        // per workspace, plus once per row for the shortcut map.
        let workspaces = model.sortedWorkspaces
        let chatsByWorkspace = Dictionary(
            workspaces.map { ($0.id, model.chats(for: $0.id)) },
            uniquingKeysWith: { first, _ in first }
        )
        let activeIDs = Set(workspaces.lazy
            .filter { Self.isActive($0, chats: chatsByWorkspace[$0.id] ?? []) }
            .map(\.id))
        let pinnedWorkspaces = workspaces.filter(\.isPinned)
        // What the main list shows: pinned rows live in their own strip, and the
        // Active tab narrows to workspaces that are doing something or need you.
        let listedWorkspaces = workspaces.filter {
            !$0.isPinned && (filter != .active || activeIDs.contains($0.id))
        }
        let workingCount = workspaces.lazy.filter { workspace in
            switch sidebarEffectiveStatus(for: workspace, chats: chatsByWorkspace[workspace.id] ?? []) {
            case .thinking, .requesting, .runningTool: return true
            default: return false
            }
        }.count
        let shortcuts = Self.workspaceShortcuts(workspaces)
        List {
            if workspaces.isEmpty {
                emptyState
            } else if filter == .active, listedWorkspaces.isEmpty, pinnedWorkspaces.isEmpty {
                Text("All agents are idle")
                    .font(.system(size: OreTheme.Font.body))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, OreTheme.Space.sm)
            }

            if !pinnedWorkspaces.isEmpty {
                Section {
                    PinnedStrip(workspaces: pinnedWorkspaces, chatsFor: { chatsByWorkspace[$0] ?? [] })
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(
                            top: 2, leading: OreTheme.Space.sm,
                            bottom: OreTheme.Space.xs, trailing: OreTheme.Space.sm
                        ))
                } header: {
                    Text("Pinned")
                }
            }

            ForEach(Self.repositoryGroups(listedWorkspaces)) { repository in
                DisclosureGroup(isExpanded: repositoryBinding(repository.path)) {
                    ForEach(repository.workspaces) { workspace in
                        WorkspaceRow(
                            workspace: workspace,
                            chats: chatsByWorkspace[workspace.id] ?? [],
                            identity: model.researchIdentity(for: workspace),
                            isSelected: model.selectedWorkspaceID == workspace.id,
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
                            .listRowBackground(
                                model.selectedWorkspaceID == workspace.id
                                    ? AnyView(
                                        RoundedRectangle(
                                            cornerRadius: OreTheme.pillRadius,
                                            style: .continuous
                                        )
                                        .fill(OreTheme.sidebarSelectedFill)
                                        .overlay {
                                            RoundedRectangle(
                                                cornerRadius: OreTheme.pillRadius,
                                                style: .continuous
                                            )
                                            .strokeBorder(OreTheme.selectedStroke, lineWidth: 0.75)
                                        }
                                        .padding(.vertical, 2)
                                    )
                                    : AnyView(Color.clear)
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
        .task(id: workspaces.count) {
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if !workspaces.isEmpty {
                filterTabs(allCount: workspaces.count, activeCount: activeIDs.count)
                    .padding(.horizontal, OreTheme.Space.sm)
                    .padding(.top, OreTheme.Space.xs)
                    .padding(.bottom, OreTheme.Space.sm)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: OreTheme.Space.sm) {
                connectedPill(working: workingCount, total: workspaces.count)
                Spacer()
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
            // No bar, no hairline: the system sidebar is already Liquid Glass
            // on macOS 26, and layering a second material over it is exactly
            // the glass-on-glass stacking Apple warns against. The connected
            // pill carries its own glass; rows scrolling under pick up the
            // system's scroll-edge treatment.
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

    /// The reference design's segmented capsule: All | Active, each with its
    /// count. Selection stays quiet (a primary wash, not accent) so the blue
    /// pill remains reserved for the selected workspace row.
    private func filterTabs(allCount: Int, activeCount: Int) -> some View {
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

    /// The footer's presence pill: green while any agent is live, quiet gray
    /// otherwise — the sidebar's own "Connected" light.
    private func connectedPill(working: Int, total: Int) -> some View {
        let isLive = working > 0
        return HStack(spacing: 6) {
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
    @Environment(AppModel.self) private var model
    let workspaces: [WorkspaceSummary]
    let chatsFor: (WorkspaceID) -> [ChatSummary]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: OreTheme.Space.md) {
                ForEach(workspaces) { workspace in
                    let isSelected = model.selectedWorkspaceID == workspace.id
                    VStack(spacing: 4) {
                        WorkspaceAvatar(
                            workspace: workspace,
                            chats: chatsFor(workspace.id),
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
            .padding(.horizontal, OreTheme.Space.xs)
        }
    }
}

/// In-memory portrait cache so every sidebar row doesn't re-hit the corpus on
/// disk. Misses are remembered too — a scientist with no cached portrait must
/// not retrigger a lookup on every redraw.
@MainActor
private enum ScientistPortraitCache {
    private static var images: [String: NSImage] = [:]
    private static var misses: Set<String> = []

    static func load(for identity: ResearchIdentity) async -> NSImage? {
        if let image = images[identity.slug] { return image }
        if misses.contains(identity.slug) { return nil }
        guard let profile = await ScientistCorpus.shared.profile(for: identity),
              let url = ScientistCorpus.shared.imageURL(for: profile),
              let image = NSImage(contentsOf: url) else {
            misses.insert(identity.slug)
            return nil
        }
        images[identity.slug] = image
        return image
    }
}

/// One workspace as a face: the scientist's portrait when the workspace is
/// named for one (monogram until it loads, or when it isn't), a status ring
/// that spins while the agent works, and the harness mark tucked in the
/// corner so you can tell which agent lives here without reading anything.
private struct WorkspaceAvatar: View {
    let workspace: WorkspaceSummary
    let chats: [ChatSummary]
    var size: CGFloat = 28
    /// The scientist this workspace is named for, when it is.
    var identity: ResearchIdentity?
    /// On the selected row's solid accent pill, colored rings vanish — the
    /// ring turns white there instead.
    var onProminentFill = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var portrait: NSImage?

    private var status: AgentStatus {
        sidebarEffectiveStatus(for: workspace, chats: chats)
    }

    var body: some View {
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
        .overlay { statusRing }
        .overlay(alignment: .bottomTrailing) {
            HarnessMark(harness: workspace.harness, size: size * 0.42)
                .offset(x: 2, y: 2)
        }
        .help(statusHelp)
    }

    @ViewBuilder
    private var statusRing: some View {
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

    private var statusHelp: String {
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
/// version of the composer's sweeping busy border, sharing its cadence.
private struct SpinningRing: View {
    let color: Color
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        TimelineView(
            .animation(minimumInterval: OreTheme.decorativeAnimationInterval, paused: controlActiveState != .key)
        ) { context in
            let period = 1.6
            let angle = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period * 360
            Circle()
                .trim(from: 0, to: 0.32)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(angle))
        }
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
    let chats: [ChatSummary]
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

    var body: some View {
        HStack(spacing: OreTheme.Space.sm) {
            WorkspaceAvatar(
                workspace: workspace,
                chats: chats,
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

            if isHovering || isSelected {
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
            } else if let shortcutIndex {
                Text("⌘\(shortcutIndex)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 24)
                    .help("Jump here with ⌘\(shortcutIndex)")
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Re-fetched only when the workspace actually has new activity, so the
        // sidebar never polls; a quiet row costs one query per turn completed.
        .task(id: digestKey) {
            digest = await model.lastTurnDigest(for: workspace.id)
        }
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
        statusLine ?? digest
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
