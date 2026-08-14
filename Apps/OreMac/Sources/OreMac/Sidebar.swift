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

    private var collapsedRepositories: Set<String> {
        Set(collapsedRepositoriesRaw.split(separator: "\n").map(String.init))
    }

    private struct RepositoryGroup: Identifiable {
        var id: String { path }
        var path: String
        var name: String
        var workspaces: [WorkspaceSummary]
    }

    private var repositoryGroups: [RepositoryGroup] {
        Dictionary(grouping: model.sortedWorkspaces, by: \.repositoryPath)
            .map { path, workspaces in
                RepositoryGroup(
                    path: path,
                    name: (path as NSString).lastPathComponent,
                    workspaces: workspaces
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            if model.sortedWorkspaces.isEmpty {
                emptyState
            }

            ForEach(repositoryGroups) { repository in
                DisclosureGroup(isExpanded: repositoryBinding(repository.path)) {
                    ForEach(repository.workspaces) { workspace in
                        WorkspaceRow(
                            workspace: workspace,
                            chats: model.chats(for: workspace.id),
                            isSelected: model.selectedWorkspaceID == workspace.id,
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
                                    ? OreTheme.selectedFill
                                    : Color.clear
                            )
                            .contextMenu { menu(for: workspace) }
                    }
                } label: {
                    RepositoryRow(repository: repository.name, workspaces: repository.workspaces)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .listRowSeparator(.hidden)
            }

            if !model.archivedWorkspaces.isEmpty {
                Section(isExpanded: $showArchived) {
                    ForEach(model.archivedWorkspaces) { workspace in
                        HStack {
                            Text(workspace.name)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Restore") { model.unarchive(workspace.id) }
                                .buttonStyle(.link)
                        }
                    }
                } header: {
                    Text("Archived (\(model.archivedWorkspaces.count))")
                }
            }
        }
        .onChange(of: model.selectedWorkspaceID) { _, selected in
            guard let selected,
                  let workspace = model.sortedWorkspaces.first(where: { $0.id == selected })
            else { return }
            setRepository(workspace.repositoryPath, expanded: true)
        }
        .listStyle(.sidebar)
        // Inside a NavigationSplitView the system already renders the sidebar's
        // translucent material (and Liquid Glass on macOS 26); hiding the List's
        // own background lets that show through. A manual glassEffect here would
        // fight the system chrome, so it's intentionally gone.
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: OreTheme.Space.sm) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: OreTheme.Font.body))
                    .foregroundStyle(.secondary)
                Text("\(model.sortedWorkspaces.count) active")
                    .font(.system(size: OreTheme.Font.body))
                    .foregroundStyle(.secondary)
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
            .background(.bar)
            .overlay(alignment: .top) {
                Rectangle().fill(OreTheme.hairline).frame(height: 1)
            }
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
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(
                nil, inFileViewerRootedAtPath: workspace.worktreePath
            )
        }
        Button("Copy Branch Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(workspace.branch, forType: .string)
        }
        Button("Rename…") {
            renameText = workspace.name
            renameWorkspace = workspace
        }
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
        Button("Archive") { model.archive(workspace.id) }
        Button("Delete…", role: .destructive) {
            model.delete(workspace.id, deleteBranch: false)
        }
    }
}

private struct RepositoryRow: View {
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
            let changes = workspaces.reduce(0) { $0 + $1.gitStatus.changedFileCount }
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
    let workspace: WorkspaceSummary
    let chats: [ChatSummary]
    let isSelected: Bool
    let onRename: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: OreTheme.Space.sm) {
            statusIcon
                .frame(width: 16)

            VStack(alignment: .leading, spacing: OreTheme.Space.xs) {
                HStack(spacing: 4) {
                    if workspace.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    Text(workspace.name)
                        .font(.system(
                            size: 14,
                            weight: effectiveNeedsAttention ? .bold
                                : workspace.hasUnread ? .semibold : .regular
                        ))
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if workspace.stackedOn != nil {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(effectiveNeedsAttention ? indicatorColor : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                if workspace.gitStatus.insertions > 0 {
                    Text("+\(workspace.gitStatus.insertions)")
                        .foregroundStyle(OreTheme.added)
                }
                if workspace.gitStatus.deletions > 0 {
                    Text("−\(workspace.gitStatus.deletions)")
                        .foregroundStyle(OreTheme.removed)
                }
            }
            .font(.caption2.monospacedDigit())

            if isHovering || isSelected {
                Button(action: onRename) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Rename workspace")
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    /// The status to actually surface for this workspace. `workspace.status` can
    /// be stuck on an old failed tab; this instead lets live, attention-worthy
    /// states win, and otherwise reflects the *most recently active* chat — so a
    /// stale failure stops dominating once a newer tab has moved on.
    private var effectiveStatus: AgentStatus {
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

    private var effectiveNeedsAttention: Bool {
        effectiveStatus == .awaitingInput || effectiveStatus == .failed
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch effectiveStatus {
        case .thinking, .requesting, .runningTool:
            ProgressView()
                .controlSize(.small)
                .tint(OreTheme.Status.running)
                .help(runningAgentCount > 1 ? "\(runningAgentCount) agents working" : "Agent working")
        case .awaitingInput:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(OreTheme.Status.needsYou)
                .help("Needs your attention")
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(OreTheme.Status.failed)
                .help("Agent failed")
        case .interrupted:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(OreTheme.Status.interrupted)
                .help("Agent interrupted")
        case .idle:
            Image(systemName: workspace.hasUnread ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(workspace.hasUnread ? OreTheme.Status.unread : Color.secondary.opacity(0.55))
                .help(workspace.hasUnread ? "Finished with unread activity" : "No agent is working")
        }
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

    private var statusText: String {
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
        case .idle:
            guard let activity = workspace.lastActivity else { return "Ready" }
            return activity.formatted(.relative(presentation: .named))
        }
    }
}
