import AppKit
import OreGit
import OreProtocol
import SwiftUI

/// A real directory tree for changed files. Folder nodes are derived from the
/// paths returned by git, so this remains deterministic and works for added or
/// deleted files that may no longer exist in the workspace file index.
private struct DiffTreeNode: Identifiable {
    var id: String { file == nil ? "folder:\(path)" : "file:\(path)" }
    let name: String
    let path: String
    let file: FileDiff?
    let children: [DiffTreeNode]?

    var fileCount: Int {
        if file != nil { return 1 }
        return children?.reduce(0) { $0 + $1.fileCount } ?? 0
    }

    static func build(from diffs: [FileDiff]) -> [DiffTreeNode] {
        let entries = diffs.map { diff in
            (components: diff.path.split(separator: "/").map(String.init), file: diff)
        }
        return build(entries: entries, parent: "")
    }

    private static func build(
        entries: [(components: [String], file: FileDiff)],
        parent: String
    ) -> [DiffTreeNode] {
        let groups = Dictionary(grouping: entries) { $0.components.first ?? $0.file.path }
        return groups.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .compactMap { name in
                guard let group = groups[name], !group.isEmpty else { return nil }
                let path = parent.isEmpty ? name : "\(parent)/\(name)"
                if let direct = group.first(where: { $0.components.count <= 1 })?.file {
                    return DiffTreeNode(name: name, path: direct.path, file: direct, children: nil)
                }
                let descendants = group.map { entry in
                    (components: Array(entry.components.dropFirst()), file: entry.file)
                }
                return DiffTreeNode(
                    name: name,
                    path: path,
                    file: nil,
                    children: build(entries: descendants, parent: path)
                )
            }
    }

    static func folderPaths(in nodes: [DiffTreeNode]) -> Set<String> {
        var result: Set<String> = []
        func walk(_ nodes: [DiffTreeNode]) {
            for node in nodes where node.file == nil {
                result.insert(node.path)
                walk(node.children ?? [])
            }
        }
        walk(nodes)
        return result
    }
}

private struct VisibleDiffTreeNode: Identifiable {
    let node: DiffTreeNode
    let depth: Int
    var id: String { node.id }
}

private struct VisibleWorkspaceFileNode: Identifiable {
    let node: WorkspaceFileNode
    let depth: Int
    var id: String { node.id }
}

/// The review side of the app: the diff, and the ability to talk to the agent
/// about a specific line of it.
///
/// Commenting on a diff is the primary way to steer an agent — far more precise
/// than describing the problem in prose, because the comment carries the file
/// and the line with it and the agent doesn't have to guess what "that function"
/// meant.
struct ReviewPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var controlActiveState
    let workspace: WorkspaceSummary

    @State private var diffs: [FileDiff] = []
    @State private var isLoading = false
    @State private var viewedPaths: Set<String> = []
    @State private var loadError: String?
    @State private var tab: ReviewTab = .changes
    @State private var hoveredTab: ReviewTab?
    @State private var fileTree: [WorkspaceFileNode] = []
    @State private var fileSearch = ""
    @State private var isLoadingFiles = false
    @State private var expandedFileFolders: Set<String> = []
    @State private var expandedDiffFolders: Set<String> = []
    @State private var knownDiffFolders: Set<String> = []
    @State private var hasLoadedOnce = false
    @State private var workingTree: GitStatusSnapshot?
    @AppStorage("ore.review.changesLayout") private var changesLayoutRaw = "tree"
    @State private var diffScope: DiffScope = .all
    @State private var turnCheckpoints: [TurnCheckpoint] = []
    @State private var stackParent: WorkspaceSummary?
    @State private var stackChildren: [WorkspaceSummary] = []
    /// Workspace and git generation of the last diff refresh, so the
    /// generation task doesn't repeat the read the workspace task just did.
    @State private var lastRefreshKey: String?
    /// Whose files `fileTree` holds, and whose walk is the latest requested —
    /// a slow walk for a workspace the user already left must not land.
    @State private var fileTreeWorkspaceID: WorkspaceID?
    @State private var fileTreeRequestedFor: WorkspaceID?

    private enum DiffScope: Hashable {
        case all
        case sinceLastMessage
        case turn(String)

        var title: String {
            switch self {
            case .all: "All changes"
            case .sinceLastMessage: "Since last message"
            case .turn: "This turn"
            }
        }
    }

    private enum ReviewTab: Hashable { case allFiles, changes, requests }
    private var isTreeLayout: Bool { changesLayoutRaw != "list" }

    var body: some View {
        VStack(spacing: 0) {
            tabRow
            Rectangle().fill(OreTheme.hairline).frame(height: 1)
            if tab != .requests { BaseSyncBanner(workspace: workspace) }
            content
                .frame(maxHeight: .infinity)
            if tab != .requests {
                stackStrip
                // The panel owns workspace-specific async results in @State. Give
                // each workspace a distinct identity so checks from the previously
                // selected branch cannot remain visible while the new branch loads.
                ShipStatusPanel(workspace: workspace)
                    .id(workspace.id)
            }
        }
        // No fill of its own: the pane is cut from Liquid Glass where it is
        // laid out (`RootView.workspaceMain` clips it to the card radius and
        // applies `oreGlassSurface`). A material here as well would stack
        // glass on glass, which Apple's guidance is explicit about avoiding.
        .task(id: workspace.id) {
            knownDiffFolders = []
            expandedDiffFolders = []
            // Paint the last-known diff for this workspace immediately — a warm
            // cache makes the switch feel instant, and it never lingers on the
            // previously selected workspace's changes. Only a cold cache falls
            // back to the loading spinner.
            seedFromCache()
            // Only a cache with something in it counts as loaded. An empty
            // snapshot — every workspace gets one prefetched at launch, before
            // the agent has written anything — otherwise suppressed the
            // spinner and let the pane claim "No changes yet" for the whole
            // time the first real read was still running.
            hasLoadedOnce = model.cachedDiff(for: workspace.id)?.diffs.isEmpty == false
            diffScope = .all
            await refresh()
            await model.pullDraftComments(for: workspace.id)
            async let checkpoints = model.loadTurnCheckpoints(for: workspace.id)
            async let neighbors = model.loadStackNeighbors(for: workspace.id)
            turnCheckpoints = await checkpoints
            let stack = await neighbors
            stackParent = stack.parent
            stackChildren = stack.children
        }
        // Silent catch-up: the agent writing files should grow this list in
        // place, not flash a spinner over it. Debounced — the task restarts on
        // every generation, so a burst of writes lands as one diff read.
        .task(id: "\(model.gitGeneration(for: workspace.id))-\(model.isBackgroundPollingEnabled)") {
            try? await Task.sleep(for: ReviewRefreshPolicy.gitDebounce)
            guard !Task.isCancelled, model.isBackgroundPollingEnabled,
                  refreshKey != lastRefreshKey else { return }
            await refresh()
        }
        // The full workspace walk only feeds "All files", so it runs only
        // while that tab is showing, and again when it is shown after changes.
        .task(id: FileTreeRefreshKey(
            workspaceID: workspace.id,
            generation: model.gitGeneration(for: workspace.id),
            isVisible: tab == .allFiles && model.isBackgroundPollingEnabled
        )) {
            guard model.isBackgroundPollingEnabled else { return }
            await refreshFileTree()
        }
        // Agent PostDiffComment writes a gitignored file, so status generation
        // does not move. Poll so numbered anchors appear — but only while the
        // window is key, and quickly only while an agent here is mid-turn.
        // Becoming key restarts the task, which pulls straight away.
        .task(id: CommentPollKey(
            workspaceID: workspace.id,
            isWindowKey: controlActiveState == .key,
            isAgentBusy: ReviewRefreshPolicy.isAgentBusy(workspace.status)
        )) {
            guard let interval = ReviewRefreshPolicy.commentPollInterval(
                isWindowKey: controlActiveState == .key,
                isAgentBusy: ReviewRefreshPolicy.isAgentBusy(workspace.status)
            ) else { return }
            while !Task.isCancelled {
                await model.pullDraftComments(for: workspace.id)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private struct FileTreeRefreshKey: Hashable {
        let workspaceID: WorkspaceID
        let generation: UInt64
        let isVisible: Bool
    }

    private struct CommentPollKey: Hashable {
        let workspaceID: WorkspaceID
        let isWindowKey: Bool
        let isAgentBusy: Bool
    }

    private var refreshKey: String {
        "\(workspace.id.rawValue)#\(model.gitGeneration(for: workspace.id))"
    }

    /// Show the cached diff for this workspace at once, or clear whatever diff
    /// was carried over from the previously selected workspace.
    private func seedFromCache() {
        if let cached = model.cachedDiff(for: workspace.id) {
            diffs = cached.diffs
            knownDiffFolders = DiffTreeNode.folderPaths(in: DiffTreeNode.build(from: cached.diffs))
        } else {
            diffs = []
        }
    }

    private var pendingRequestCount: Int {
        model.workspacePermissionGroups(for: workspace.id).reduce(0) { $0 + $1.pendingCount }
    }

    // Workspace destinations; actions live in the window toolbar.
    private var tabRow: some View {
        HStack(spacing: OreTheme.Space.xs) {
            segment("All files", count: nil, target: .allFiles)
            segment("Changes", count: diffs.count, target: .changes)

            segment("Requests", count: pendingRequestCount > 0 ? pendingRequestCount : nil, target: .requests)
            Spacer(minLength: 0)

        }
        .padding(.horizontal, OreTheme.Space.sm)
        .frame(height: OreTheme.RowHeight.bar)
        // Sits directly on the inspector's glass — a bar material here would
        // stack a second pane over it.
    }

    private func segment(_ title: String, count: Int?, target: ReviewTab) -> some View {
        let isSelected = tab == target
        return Button { tab = target } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: OreTheme.Font.body, weight: isSelected ? .semibold : .regular))
                if let count {
                    Text("\(count)")
                        .font(.system(size: OreTheme.Font.caption).monospacedDigit())
                        .foregroundStyle(target == .requests ? Color.orange : .secondary)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                isSelected ? OreTheme.selectedFill
                    : hoveredTab == target ? OreTheme.subduedFill : .clear,
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(OrePressableButtonStyle())
        .foregroundStyle(isSelected ? .primary : .secondary)
        .fixedSize(horizontal: true, vertical: false)
        .onHover { hovering in
            if hovering { hoveredTab = target }
            else if hoveredTab == target { hoveredTab = nil }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .requests:
            WorkspaceRequestsPane(workspace: workspace)
                .id(workspace.id)
        case .allFiles:
            allFilesView
        case .changes:
            if diffs.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
    }

    private var allFilesView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Find in workspace", text: $fileSearch)
                    .textFieldStyle(.plain)
                if !fileSearch.isEmpty {
                    Button { fileSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, OreTheme.Space.sm)
            .frame(height: 34)

            Divider()

            if isLoadingFiles && fileTree.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if fileTree.isEmpty {
                ContentUnavailableView("No files", systemImage: "folder")
            } else {
                List {
                    if fileSearch.isEmpty {
                        ForEach(visibleFileTree) { item in
                            fileTreeRow(item.node, depth: item.depth)
                        }
                    } else {
                        ForEach(filteredFiles) { node in fileTreeRow(node, showPath: true) }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                // Overlay scrollers, not none: a file tree with no knob gives
                // the reader no idea how far down a thousand paths they are.
                .oreOverlayScrollers()
            }
        }
        // The list rides the inspector's glass; an opaque well here would punch
        // a matte hole in the pane.
    }

    private func fileTreeRow(
        _ node: WorkspaceFileNode,
        depth: Int = 0,
        showPath: Bool = false
    ) -> some View {
        Button {
            if node.isDirectory {
                toggleFileFolder(node.path)
            } else {
                model.openSourceFile(node.path, in: workspace.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: node.isDirectory
                    ? (expandedFileFolders.contains(node.path) ? "chevron.down" : "chevron.right")
                    : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                    .opacity(node.isDirectory ? 1 : 0)
                SourceFileIcon(path: node.path, isDirectory: node.isDirectory, size: 17)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name).lineLimit(1)
                    if showPath {
                        Text(node.path)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 16)
            .frame(minHeight: OreTheme.RowHeight.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !node.isDirectory {
                Button("Open") { model.openSourceFile(node.path, in: workspace.id) }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(
                        workspace.worktreePath + "/" + node.path,
                        inFileViewerRootedAtPath: workspace.worktreePath
                    )
                }
            }
        }
    }

    private var visibleFileTree: [VisibleWorkspaceFileNode] {
        var result: [VisibleWorkspaceFileNode] = []
        func append(_ nodes: [WorkspaceFileNode], depth: Int) {
            for node in nodes {
                result.append(VisibleWorkspaceFileNode(node: node, depth: depth))
                if node.isDirectory, expandedFileFolders.contains(node.path) {
                    append(node.children ?? [], depth: depth + 1)
                }
            }
        }
        append(fileTree, depth: 0)
        return result
    }

    private func toggleFileFolder(_ path: String) {
        if expandedFileFolders.contains(path) { expandedFileFolders.remove(path) }
        else { expandedFileFolders.insert(path) }
    }

    private var filteredFiles: [WorkspaceFileNode] {
        func flatten(_ nodes: [WorkspaceFileNode]) -> [WorkspaceFileNode] {
            nodes.flatMap { node in [node] + flatten(node.children ?? []) }
        }
        return flatten(fileTree).filter {
            !$0.isDirectory && $0.path.localizedCaseInsensitiveContains(fileSearch)
        }
    }

    private var draftComments: [DiffCommentReference] {
        if let inbox = model.reviewInboxChatID(for: workspace.id) {
            return model.chat(for: inbox).draftComments
        }
        return []
    }

    private var diffScopeMenu: some View {
        Menu {
            Button("All changes") { Task { await applyScope(.all) } }
            Button("Since last message") { Task { await applyScope(.sinceLastMessage) } }
            if !turnCheckpoints.isEmpty {
                Divider()
                ForEach(Array(turnCheckpoints.suffix(12).reversed())) { checkpoint in
                    Button("Turn \(checkpoint.ordinal + 1)") {
                        Task { await applyScope(.turn(checkpoint.commit)) }
                    }
                }
            }
        } label: {
            Text(diffScope.title)
                .font(.system(size: OreTheme.Font.caption, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(OreTheme.subduedFill, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show all changes, since the last message, or one turn")
    }

    @ViewBuilder
    private var stackStrip: some View {
        if stackParent != nil || !stackChildren.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                if let parent = stackParent {
                    Button(parent.name) { model.selectedWorkspaceID = parent.id }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.left")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(workspace.name)
                    .fontWeight(.semibold)
                if !stackChildren.isEmpty {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    ForEach(stackChildren) { child in
                        Button(child.name) { model.selectedWorkspaceID = child.id }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: OreTheme.Font.caption))
            .padding(.horizontal, OreTheme.Space.sm)
            .frame(height: 26)
        }
    }

    private func applyScope(_ scope: DiffScope) async {
        diffScope = scope
        do {
            switch scope {
            case .all:
                diffs = try await model.refreshDiff(for: workspace).diffs
            case .sinceLastMessage:
                guard let commit = turnCheckpoints.last?.commit else {
                    diffs = try await model.refreshDiff(for: workspace).diffs
                    return
                }
                diffs = try await model.loadDiffFromCheckpoint(commit, for: workspace.id)
            case .turn(let commit):
                if let index = turnCheckpoints.firstIndex(where: { $0.commit == commit }),
                   index + 1 < turnCheckpoints.count {
                    let next = turnCheckpoints[index + 1].commit
                    diffs = try await model.loadDiffBetweenCheckpoints(
                        from: commit, to: next, for: workspace.id
                    )
                } else {
                    diffs = try await model.loadDiffFromCheckpoint(commit, for: workspace.id)
                }
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private var emptyState: some View {
        VStack(spacing: OreTheme.Space.sm) {
            if isLoading && !hasLoadedOnce {
                ProgressView()
            } else if let loadError {
                // "Couldn't read git" is a different fact from "nothing changed",
                // and conflating them is what made a real diff read as empty.
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Couldn’t load the diff")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, OreTheme.Space.lg)
                Button("Try Again") { Task { await refresh() } }
                    .buttonStyle(.bordered)
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("No changes yet")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Anything the agent writes shows up here against \(workspace.baseBranch).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private enum ViewedCountStyle { case words, compact, totalsOnly }

    private func changeSummary(
        _ style: ViewedCountStyle,
        insertions: Int,
        deletions: Int
    ) -> some View {
        HStack(spacing: OreTheme.Space.sm) {
            switch style {
            case .words:
                Text("\(viewedPaths.count)/\(diffs.count) viewed")
                    .foregroundStyle(.secondary)
            case .compact:
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle")
                        .imageScale(.small)
                    Text("\(viewedPaths.count)/\(diffs.count)")
                }
                .foregroundStyle(.secondary)
            case .totalsOnly:
                EmptyView()
            }
            Text("+\(insertions)")
                .foregroundStyle(OreTheme.added)
            Text("−\(deletions)")
                .foregroundStyle(OreTheme.removed)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            let insertions = diffs.reduce(0) { $0 + $1.insertions }
            let deletions = diffs.reduce(0) { $0 + $1.deletions }
            HStack(spacing: OreTheme.Space.sm) {
                changesLayoutToggle
                diffScopeMenu
                    .fixedSize()
                Spacer(minLength: OreTheme.Space.sm)
                // One line at any pane width. Squeezed, "0/138 viewed" wrapped
                // into two stacked words beside the totals; now the count
                // tightens to a tick and a fraction, then gives way entirely.
                ViewThatFits(in: .horizontal) {
                    changeSummary(.words, insertions: insertions, deletions: deletions)
                    changeSummary(.compact, insertions: insertions, deletions: deletions)
                    changeSummary(.totalsOnly, insertions: insertions, deletions: deletions)
                }
                .help("\(viewedPaths.count) of \(diffs.count) files viewed")
            }
            .font(.system(size: OreTheme.Font.caption).monospacedDigit())
            .padding(.horizontal, OreTheme.Space.sm)
            .frame(height: 28)

            Divider()

            // One bucketing pass for the whole list. The section builders used
            // to call `diffs(in:)` six times over, and `diffs(in:)` rebuilt the
            // staged and unstaged path Sets once per *file* it tested — an
            // O(files²) sweep on every body pass of a live-updating pane.
            let buckets = changeBuckets
            List {
                if !buckets.conflicted.isEmpty {
                    Section {
                        ForEach(buckets.conflicted, id: \.path) { file in
                            fileRow(file, isConflicted: true, showFolder: true)
                        }
                    } header: {
                        changeSectionHeaderLabel(
                            "Conflicts", files: buckets.conflicted, tint: .orange
                        )
                    }
                }
                if buckets.showsSections {
                    ForEach(buckets.sections) { section in
                        Section {
                            changeRows(for: section.files)
                        } header: {
                            changeSectionHeaderLabel(section.bucket.title, files: section.files)
                        }
                    }
                } else {
                    changeRows(for: buckets.unconflicted)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            // See `allFilesView`: a knob that tells the reader where they are,
            // drawn as an overlay so it never paints the legacy white track.
            .oreOverlayScrollers()
        }
        // Rides the inspector's glass — see `allFilesView`.
    }

    private var changesLayoutToggle: some View {
        HStack(spacing: 0) {
            layoutButton(
                "list.bullet.indent",
                selected: isTreeLayout,
                help: "Tree view"
            ) { changesLayoutRaw = "tree" }
            layoutButton(
                "list.bullet",
                selected: !isTreeLayout,
                help: "File list"
            ) { changesLayoutRaw = "list" }
        }
        .padding(2)
        .background(OreTheme.subduedFill, in: Capsule())
    }

    private func layoutButton(
        _ systemImage: String,
        selected: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(width: 22, height: 18)
                .background(selected ? OreTheme.selectedFill : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func fileRow(
        _ file: FileDiff,
        isConflicted: Bool = false,
        showFolder: Bool,
        depth: Int = 0
    ) -> some View {
        HStack(spacing: 8) {
            if !showFolder {
                Color.clear.frame(width: 10, height: 1)
            }
            Text(statusLetter(file.status))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color(for: file.status))
                .frame(width: 12)

            SourceFileIcon(path: file.path, size: 16)

            // Filename leads, folder trails dimmed. Path-first rows truncated
            // into "…c/Sources/OreMac/" soup and buried the one part that
            // identifies the file.
            HStack(spacing: 5) {
                Text((file.path as NSString).lastPathComponent)
                    .font(.system(size: OreTheme.Font.body, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if showFolder {
                    let prefix = (file.path as NSString).deletingLastPathComponent
                    if !prefix.isEmpty {
                        Text(prefix)
                            .font(.system(size: OreTheme.Font.caption))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .layoutPriority(0)
                    }
                }
            }
            .opacity(viewedPaths.contains(file.path) ? 0.55 : 1)

            Spacer(minLength: 4)

            if file.insertions > 0 {
                Text("+\(file.insertions)")
                    .font(.system(size: OreTheme.Font.caption).monospacedDigit())
                    .foregroundStyle(OreTheme.added)
            }
            if file.deletions > 0 {
                Text("−\(file.deletions)")
                    .font(.system(size: OreTheme.Font.caption).monospacedDigit())
                    .foregroundStyle(OreTheme.removed)
            }

            if isConflicted {
                Button("Ours") {
                    model.resolveConflict(path: file.path, side: .ours, in: workspace.id)
                }
                .buttonStyle(.borderless)
                .help("Keep this workspace's version")
                Button("Theirs") {
                    model.resolveConflict(path: file.path, side: .theirs, in: workspace.id)
                }
                .buttonStyle(.borderless)
                .help("Take the incoming version")
            }

            Button { toggleViewed(file.path) } label: {
                Image(systemName: viewedPaths.contains(file.path) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(viewedPaths.contains(file.path) ? Color.accentColor : Color.secondary.opacity(0.45))
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help(viewedPaths.contains(file.path) ? "Mark as not viewed" : "Mark as viewed")
        }
        .frame(minHeight: OreTheme.RowHeight.row)
        .padding(.leading, 5 + CGFloat(depth) * 16)
        .padding(.trailing, 5)
        .background {
            if model.activeFilePath[workspace.id] == file.path {
                RoundedRectangle(cornerRadius: 7)
                    .fill(OreTheme.selectedFill)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.openDiffFile(file.path, in: workspace.id)
        }
        .contextMenu {
            Button("Open") { model.openDiffFile(file.path, in: workspace.id) }
            if isConflicted {
                Button("Accept ours") {
                    model.resolveConflict(path: file.path, side: .ours, in: workspace.id)
                }
                Button("Accept theirs") {
                    model.resolveConflict(path: file.path, side: .theirs, in: workspace.id)
                }
            }
            Button(viewedPaths.contains(file.path) ? "Mark as Not Viewed" : "Mark as Viewed") {
                toggleViewed(file.path)
            }
        }
    }

    private var changeBuckets: ReviewChangeBuckets {
        ReviewChangeBuckets(diffs: diffs, workingTreeFiles: workingTree?.files ?? [])
    }

    private func changeSectionHeaderLabel(
        _ title: String,
        files: [FileDiff],
        tint: Color = .secondary
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: OreTheme.Font.caption, weight: .semibold))
                .foregroundStyle(tint)
                .textCase(.uppercase)
            Text("\(files.count)")
                .font(.system(size: OreTheme.Font.caption).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            let plus = files.reduce(0) { $0 + $1.insertions }
            let minus = files.reduce(0) { $0 + $1.deletions }
            if plus > 0 {
                Text("+\(plus)")
                    .foregroundStyle(OreTheme.added)
            }
            if minus > 0 {
                Text("−\(minus)")
                    .foregroundStyle(OreTheme.removed)
            }
        }
        .font(.system(size: OreTheme.Font.caption).monospacedDigit())
    }

    @ViewBuilder
    private func changeRows(for files: [FileDiff]) -> some View {
        if isTreeLayout {
            ForEach(visibleDiffTree(from: files)) { item in
                let node = item.node
                if let file = node.file {
                    fileRow(file, showFolder: false, depth: item.depth)
                } else {
                    Button { toggleDiffFolder(node.path) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: expandedDiffFolders.contains(node.path)
                                ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 10)
                            SourceFileIcon(path: node.path, isDirectory: true, size: 16)
                            Text(node.name)
                                .font(.system(size: OreTheme.Font.body, weight: .medium))
                            Spacer(minLength: 0)
                            Text("\(node.fileCount)")
                                .font(.system(size: OreTheme.Font.caption).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.leading, CGFloat(item.depth) * 16)
                        .frame(minHeight: OreTheme.RowHeight.row)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            ForEach(files, id: \.path) { file in
                fileRow(file, showFolder: true)
            }
        }
    }

    private func visibleDiffTree(from files: [FileDiff]) -> [VisibleDiffTreeNode] {
        var result: [VisibleDiffTreeNode] = []
        func append(_ nodes: [DiffTreeNode], depth: Int) {
            for node in nodes {
                result.append(VisibleDiffTreeNode(node: node, depth: depth))
                if node.file == nil, expandedDiffFolders.contains(node.path) {
                    append(node.children ?? [], depth: depth + 1)
                }
            }
        }
        append(DiffTreeNode.build(from: files), depth: 0)
        return result
    }

    private func toggleDiffFolder(_ path: String) {
        if expandedDiffFolders.contains(path) { expandedDiffFolders.remove(path) }
        else { expandedDiffFolders.insert(path) }
    }

    private func statusLetter(_ status: GitFileChange.Status) -> String {
        switch status {
        case .added: return "A"
        case .untracked: return "U"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .conflicted: return "!"
        default: return "•"
        }
    }

    // MARK: - Behaviour

    private func refresh() async {
        lastRefreshKey = refreshKey
        let showLoader = !hasLoadedOnce && diffs.isEmpty
        if showLoader { isLoading = true }
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        async let tree = model.loadWorkingTreeStatus(for: workspace.id)
        do {
            // Load through the shared cache so the diff we just read also warms
            // the next switch back to this workspace.
            let snapshot = try await model.refreshDiff(for: workspace)
            let loaded = snapshot.diffs
            workingTree = await tree
            let stored = await model.loadViewedFiles(for: workspace.id)
            diffs = loaded
            // Fingerprinting every file walks every line of the whole diff.
            // On the main actor, once per git generation, that was the review
            // list's single largest hitch while an agent was writing.
            let fingerprints = await Task.detached(priority: .userInitiated) {
                loaded.map { ($0.path, DiffContentHash.of($0)) }
            }.value
            viewedPaths = Set(fingerprints.compactMap { stored[$0.0] == $0.1 ? $0.0 : nil })
            expandNewDiffFolders(in: loaded)
            loadError = nil
        } catch {
            // Leave any diff we already have on screen; overwriting a good diff
            // on a transient failure would be its own bug. The banner tells the
            // truth either way.
            loadError = error.localizedDescription
            workingTree = await tree
        }
    }

    /// Walks the workspace for "All files". A no-op while that tab is hidden;
    /// the refresh key includes visibility, so showing the tab runs it.
    private func refreshFileTree() async {
        guard tab == .allFiles else { return }
        let workspaceID = workspace.id
        fileTreeRequestedFor = workspaceID
        if fileTreeWorkspaceID != workspaceID {
            // Another workspace's tree must not stand in while this one loads.
            fileTree = []
        } else {
            // Already showing this workspace: coalesce a burst of changes.
            try? await Task.sleep(for: ReviewRefreshPolicy.gitDebounce)
            guard !Task.isCancelled else { return }
        }
        if fileTree.isEmpty { isLoadingFiles = true }
        let files = await model.workspaceFiles(for: workspace)
        // Not gated on cancellation: while an agent writes steadily, every
        // walk would be cancelled by the next change and the tree would never
        // update. Only a walk for a workspace no longer requested is dropped.
        guard fileTreeRequestedFor == workspaceID else { return }
        fileTree = files
        fileTreeWorkspaceID = workspaceID
        isLoadingFiles = false
    }

    /// Folders the user hasn't seen yet start expanded so a live agent writing
    /// nested files doesn't hide them behind collapsed tree nodes.
    private func expandNewDiffFolders(in loaded: [FileDiff]) {
        let folders = DiffTreeNode.folderPaths(in: DiffTreeNode.build(from: loaded))
        expandedDiffFolders.formUnion(folders.subtracting(knownDiffFolders))
        knownDiffFolders = folders
    }

    private func toggleViewed(_ path: String) {
        if viewedPaths.contains(path) {
            viewedPaths.remove(path)
            model.markViewed(path, hash: nil, for: workspace.id)
            return
        }
        // The tick lands now; the fingerprint follows. Hashing a large file's
        // diff on the main actor put a visible stall on the click.
        viewedPaths.insert(path)
        guard let file = diffs.first(where: { $0.path == path }) else {
            model.markViewed(path, hash: nil, for: workspace.id)
            return
        }
        Task {
            let hash = await Task.detached(priority: .userInitiated) {
                DiffContentHash.of(file)
            }.value
            model.markViewed(path, hash: hash, for: workspace.id)
        }
    }

    private func color(for status: GitFileChange.Status) -> Color {
        switch status {
        case .added, .untracked: return .green
        case .deleted: return .red
        case .conflicted: return .orange
        default: return .blue
        }
    }
}

/// The Changes list, split into its sections in one pass.
///
/// Pulled out of the view because it was three computed properties that each
/// rebuilt a `Set<String>` from the worktree status, called from a `bucket(for:)`
/// that ran once per file, called from a `diffs(in:)` that the body called six
/// times. Building it once and passing it down is both faster and testable.
struct ReviewChangeBuckets {
    enum Bucket: String, CaseIterable, Identifiable {
        case unstaged, staged, committed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .unstaged: "Unstaged"
            case .staged: "Staged"
            case .committed: "Committed"
            }
        }
    }

    struct Section: Identifiable {
        var bucket: Bucket
        var files: [FileDiff]
        var id: String { bucket.rawValue }
    }

    /// Conflicts come first and out of the staging split: resolving them is the
    /// only thing the reviewer can usefully do next.
    let conflicted: [FileDiff]
    /// Everything else, in diff order — what the list shows when it isn't split.
    let unconflicted: [FileDiff]
    /// Non-empty buckets only, in `Bucket.allCases` order.
    let sections: [Section]

    /// Staging already has a home on the Commits tab. Changes only splits into
    /// Unstaged / Staged / Committed when more than one of those is present —
    /// a lone "UNSTAGED" header just repeats the tab count and +/- totals.
    var showsSections: Bool { sections.count > 1 }

    init(diffs: [FileDiff], workingTreeFiles: [GitFileChange]) {
        var conflictedPaths: Set<String> = []
        var unstagedPaths: Set<String> = []
        var stagedPaths: Set<String> = []
        for change in workingTreeFiles {
            if change.status == .conflicted { conflictedPaths.insert(change.path) }
            if change.isUnstaged { unstagedPaths.insert(change.path) }
            if change.isStaged { stagedPaths.insert(change.path) }
        }

        var conflicted: [FileDiff] = []
        var unconflicted: [FileDiff] = []
        var byBucket: [Bucket: [FileDiff]] = [:]
        for file in diffs {
            if conflictedPaths.contains(file.path) {
                conflicted.append(file)
                continue
            }
            unconflicted.append(file)
            // Unstaged wins over staged: `git add -p` leaves a file in both, and
            // the half that still needs a decision is the one to surface.
            let bucket: Bucket = unstagedPaths.contains(file.path) ? .unstaged
                : stagedPaths.contains(file.path) ? .staged : .committed
            byBucket[bucket, default: []].append(file)
        }

        self.conflicted = conflicted
        self.unconflicted = unconflicted
        self.sections = Bucket.allCases.compactMap { bucket in
            guard let files = byBucket[bucket], !files.isEmpty else { return nil }
            return Section(bucket: bucket, files: files)
        }
    }
}

/// When the review pane re-reads git and the agent's posted comments. Pulled
/// out of the view so the cadence is testable.
enum ReviewRefreshPolicy {
    /// Git changes arrive in bursts while an agent writes; one read per burst.
    static let gitDebounce = Duration.milliseconds(300)
    static let busyCommentPoll = Duration.seconds(1)
    static let idleCommentPoll = Duration.seconds(5)

    /// `nil` means don't poll: nobody is looking, and becoming key restarts
    /// polling with an immediate pull.
    static func commentPollInterval(isWindowKey: Bool, isAgentBusy: Bool) -> Duration? {
        guard isWindowKey else { return nil }
        return isAgentBusy ? busyCommentPoll : idleCommentPoll
    }

    /// Mid-turn — the only time an agent can be posting a comment.
    static func isAgentBusy(_ status: AgentStatus) -> Bool {
        switch status {
        case .thinking, .requesting, .runningTool: true
        case .idle, .awaitingInput, .interrupted, .failed: false
        }
    }
}

/// Name of the diff document's scroll coordinate space, so the gutter's
/// drag-select reads y-positions in the row list's own frame.
private let oreDiffSpaceName = "oreDiffDoc"

// MARK: - Flattened diff rows

/// Which line of which hunk a selection or a comment points at.
struct DiffLineRef: Hashable {
    var hunk: Int
    var line: Int
}

/// One row of a rendered diff: a hunk header, or one line of code.
///
/// Built once per load, off the main actor, and handed to the view finished.
/// The renderer used to nest two `ForEach`es over `file.hunks` and re-derive
/// each row's language and syntax colours inside `body`, so every materialised
/// row re-lexed its line on every parent update — including on each step of a
/// drag-select. Now `body` only draws what is already in the row.
struct DiffDocumentRow: Identifiable, Equatable {
    /// Offset in the flat array. An integer, where the old id was a string
    /// rebuilt per row per pass. It is stable for the same reason that one was:
    /// the whole set is rebuilt when the diff changes rather than patched, so a
    /// row never has to survive a re-diff under the same id and carry a stale
    /// cached height into whatever now sits at that offset.
    let id: Int
    /// Nil on a hunk header, which can't be selected or commented on.
    let ref: DiffLineRef?
    /// Nil on a hunk header.
    let kind: DiffLine.Kind?
    let oldNumber: String
    let newNumber: String
    /// The file line a comment on this row anchors to, when there is one.
    let commentLine: Int?
    /// Marker plus syntax-coloured code, or the `@@ … @@` text of a header.
    let text: AttributedString
    let height: CGFloat

    var isHeader: Bool { kind == nil }
}

/// A whole file's diff, flattened and measured.
struct DiffRowSet: Equatable {
    static let empty = DiffRowSet(rows: [], offsets: [0], columns: 0)

    let rows: [DiffDocumentRow]
    /// Prefix sums of the row heights, `rows.count + 1` long: `offsets[i]` is
    /// where row `i` starts. Rows have fixed heights, so a drag over the gutter
    /// finds its row with a binary search — replacing a `GeometryReader` plus
    /// `PreferenceKey` on every line, which rewrote `@State` (and re-ran the
    /// document's `body`) as rows scrolled in and out.
    let offsets: [CGFloat]
    /// The longest row in monospaced character cells, which fixes the document
    /// width. Sizing to the widest *materialised* row instead is what makes a
    /// lazy stack's estimates jump as you scroll.
    let columns: Int

    var height: CGFloat { offsets.last ?? 0 }

    /// The row containing `y` in the row list's own coordinate space.
    func row(atY y: CGFloat) -> DiffDocumentRow? {
        guard !rows.isEmpty, y >= 0, y < height else { return nil }
        var low = 0
        var high = rows.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return rows[low]
    }
}

/// Turns a `FileDiff` into rows. Pure and free of the main actor, so a load can
/// run the whole pass — flatten, lex, colour, measure — in `Task.detached`.
enum DiffRowBuilder {
    static let fontSize: CGFloat = 11
    /// Fixed, and the same for every line. Wrapped lines gave the lazy stack
    /// heights it could not predict, so its estimate — and the scroller knob —
    /// jumped whenever the reader scrolled back up.
    static let lineHeight: CGFloat = 18
    static let headerHeight: CGFloat = 22
    /// Old number, new number, comment slot.
    static let gutterWidth: CGFloat = 38 + 38 + 26
    /// Drag-select strip, matching the gutter minus part of the comment slot so
    /// the "+" button still takes its own clicks.
    static let dragWidth: CGFloat = 90
    /// A tab lands on the next four-column stop, which is roughly how the text
    /// system draws one at this size. Counting it as one cell made tab-indented
    /// files measure far narrower than they draw, and clipped their ends.
    static let tabStop = 4

    static var font: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }

    /// One character cell. Monospaced, so this is exact, and cached because
    /// `documentWidth` is asked for it on every layout pass.
    static let cellWidth: CGFloat = font.maximumAdvancement.width

    /// Width the document needs so no line is clipped, given a viewport.
    static func documentWidth(columns: Int, viewport: CGFloat) -> CGFloat {
        // Two cells of slack: the column count approximates tabs and treats
        // every scalar as one cell, so it can land a hair short.
        max(viewport, gutterWidth + 4 + CGFloat(columns + 2) * cellWidth)
    }

    /// How many monospaced cells a line occupies, expanding tabs.
    static func columns(in text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars {
            if scalar == "\t" { count += tabStop - (count % tabStop) } else { count += 1 }
        }
        return count
    }

    static func marker(for kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        case .context: " "
        case .noNewline: "\\"
        }
    }

    static func headerText(_ hunk: DiffHunk) -> String {
        "@@ −\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@ \(hunk.header)"
    }

    static func build(_ file: FileDiff) -> DiffRowSet {
        let font = self.font
        // Hoisted out of the row loop: it was being looked up per line, per pass.
        let language = SyntaxHighlighter.language(forPath: file.path)
        var rows: [DiffDocumentRow] = []
        var offsets: [CGFloat] = [0]
        var y: CGFloat = 0
        var widest = 0
        rows.reserveCapacity(file.hunks.reduce(0) { $0 + $1.lines.count + 1 })

        for (hunkIndex, hunk) in file.hunks.enumerated() {
            let header = headerText(hunk)
            widest = max(widest, columns(in: header))
            rows.append(DiffDocumentRow(
                id: rows.count, ref: nil, kind: nil, oldNumber: "", newNumber: "",
                commentLine: nil, text: AttributedString(header), height: headerHeight
            ))
            y += headerHeight
            offsets.append(y)

            for (lineIndex, line) in hunk.lines.enumerated() {
                let marker = marker(for: line.kind)
                widest = max(widest, columns(in: marker) + columns(in: line.text))
                rows.append(DiffDocumentRow(
                    id: rows.count,
                    ref: DiffLineRef(hunk: hunkIndex, line: lineIndex),
                    kind: line.kind,
                    oldNumber: line.oldLineNumber.map(String.init) ?? "",
                    newNumber: line.newLineNumber.map(String.init) ?? "",
                    commentLine: line.newLineNumber ?? line.oldLineNumber,
                    text: AttributedString(paint(line, marker: marker, language: language, font: font)),
                    height: lineHeight
                ))
                y += lineHeight
                offsets.append(y)
            }
        }
        return DiffRowSet(rows: rows, offsets: offsets, columns: widest)
    }

    /// Highlighted per line: a diff line is rarely a complete parse unit, so
    /// this is the lexer pass rather than tree-sitter, which would report
    /// errors more often than it would report colour.
    private static func paint(
        _ line: DiffLine,
        marker: String,
        language: String?,
        font: NSFont
    ) -> NSAttributedString {
        guard line.kind != .noNewline else {
            return NSAttributedString(
                string: marker + line.text,
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            )
        }
        let result = NSMutableAttributedString(
            string: marker,
            attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        )
        result.append(SyntaxHighlighter.shared.highlightLine(line.text, language: language, font: font))
        return result
    }
}

/// The fingerprint a "viewed" tick is remembered against, so a file that
/// changes after it was ticked comes back unticked.
///
/// Off the main actor and allocation-light on purpose: this runs over every
/// file in the diff on each refresh, and it used to join every line of every
/// hunk into one string first — on the main actor, mid-agent-turn.
enum DiffContentHash {
    static func of(_ file: FileDiff) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func feed(_ text: String) {
            for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        }
        var first = true
        for hunk in file.hunks {
            for line in hunk.lines {
                if !first { feed("\n") }
                first = false
                // Byte-for-byte what the joined string used to be, so ticks
                // stored by earlier builds still match.
                feed(line.kind.rawValue)
                feed(":")
                feed(line.text)
            }
        }
        return String(hash, radix: 16)
    }
}

/// A file's diff shown as a document in the centre column — opened as a tab
/// from the review list, the way a file opens in an editor rather than in a
/// cramped side pane. Carries the review affordances that belong with the code:
/// mark-viewed, and commenting (single line, or a dragged range).
/// A read-only rendered-markdown document: the transcript's renderer pointed
/// at a file. Selection works; editing goes through the Source segment.
private struct MarkdownPreview: NSViewRepresentable {
    let markdown: String

    /// Everything the detached pass needs, gathered on the main actor and then
    /// only read. `NSFont` and `NSAppearance` are immutable but not `Sendable`.
    private struct Request: @unchecked Sendable {
        let source: String
        let baseFont: NSFont
        let appearance: NSAppearance
    }

    /// A finished render on its way back to the main actor. `NSAttributedString`
    /// is not `Sendable`, but this one is built by a single detached pass and
    /// only read afterwards — the same bargain `SourceHighlightResult` makes.
    private struct Rendered: @unchecked Sendable {
        let value: NSAttributedString
    }

    /// The whole markdown pass: parse, highlight every fence, build the
    /// attributed string. Off the main actor by design — see the note on
    /// `MarkdownRenderer` for what makes that safe, and why the appearance has
    /// to be made current first.
    private nonisolated static func render(_ request: Request) -> Rendered {
        var result = NSAttributedString()
        request.appearance.performAsCurrentDrawingAppearance {
            result = MarkdownRenderer(
                baseFont: request.baseFont,
                textColor: .labelColor,
                highlighter: SyntaxHighlighter.shared
            ).render(request.source, highlighting: .all)
        }
        return Rendered(value: result)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // A rendered README can run to thousands of lines. Non-contiguous
        // layout lets the text system lay out the viewport and leave the rest
        // until it is asked for, instead of the whole document on first draw.
        textView.layoutManager?.allowsNonContiguousLayout = true

        // OreOverlayScrollView, not NSScrollView: it clamps `scrollerStyle`
        // to overlay for good, so flipping "always show scroll bars" system-wide
        // can't bolt AppKit's opaque white ladder onto the glass mid-session.
        let scroll = OreOverlayScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        /// What the text storage currently holds; nil until the first render
        /// lands, which is what tells `updateNSView` there is no reader
        /// position worth keeping.
        var applied: String?
        /// The source the newest render was asked for — in flight or already
        /// applied. A result whose source is no longer this one is stale and
        /// gets dropped rather than written over a newer document.
        var requested: String?
        var render: Task<Void, Never>?

        deinit { render?.cancel() }
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard scroll.documentView is NSTextView else { return }
        // Re-render only when the text itself moved — updateNSView also fires
        // for unrelated SwiftUI churn, and markdown parsing isn't free.
        let coordinator = context.coordinator
        guard coordinator.requested != markdown else { return }
        coordinator.requested = markdown
        coordinator.render?.cancel()

        let source = markdown
        let baseFont = NSFont.systemFont(ofSize: OreTheme.Font.prose)
        // The room the render has to resolve against. A worker thread has no
        // window to ask, and both the link-symbol cache and the highlighter's
        // cache key on the current drawing appearance, so it is captured from
        // the view here and made current inside the task.
        let appearance = scroll.effectiveAppearance
        let request = Request(source: source, baseFont: baseFont, appearance: appearance)
        // The one piece of the render that wants the main actor: SF Symbol
        // images for link chips. Built here, for this size and — note the
        // wrapper — this room, because the cache keys on the appearance and the
        // detached pass will look them up under the view's, not NSApp's.
        appearance.performAsCurrentDrawingAppearance {
            MarkdownRenderer.prewarmLinkSymbols(baseFont: baseFont)
        }

        // A README runs to thousands of lines, and parsing, highlighting every
        // fence and building the attributed string for all of it used to happen
        // on the main actor — a visible stall on open, and again on every save
        // the agent made while the reader was scrolling.
        coordinator.render = Task { [weak coordinator] in
            let rendered = await Task.detached(priority: .userInitiated) {
                Self.render(request)
            }.value.value
            guard !Task.isCancelled, let coordinator, coordinator.requested == source,
                  let textView = scroll.documentView as? NSTextView
            else { return }
            let isRewrite = coordinator.applied != nil
            coordinator.applied = source
            // Read the reader's place *before* the storage goes, and read it
            // now rather than when the render was queued: replacing it
            // wholesale resets the scroll to the top, so an agent saving a long
            // README mid-read used to yank them back to the first line.
            let anchor = isRewrite ? Self.topCharacter(of: textView, in: scroll) : nil
            textView.textStorage?.setAttributedString(rendered)
            if let anchor { Self.restore(anchor, in: textView, scroll: scroll) }
        }
    }

    /// The character at the top of the viewport, or nil when the reader is
    /// already at the top and there is nothing to restore.
    private static func topCharacter(of textView: NSTextView, in scroll: NSScrollView) -> Int? {
        guard let layout = textView.layoutManager, let container = textView.textContainer else {
            return nil
        }
        let top = scroll.contentView.bounds.minY
        guard top > 0 else { return nil }
        let point = NSPoint(x: textView.textContainerInset.width, y: top)
        return layout.characterIndexForGlyph(at: layout.glyphIndex(for: point, in: container))
    }

    private static func restore(_ character: Int, in textView: NSTextView, scroll: NSScrollView) {
        guard let layout = textView.layoutManager, let container = textView.textContainer,
              character < (textView.textStorage?.length ?? 0) else { return }
        let glyphs = layout.glyphRange(
            forCharacterRange: NSRange(location: character, length: 1),
            actualCharacterRange: nil
        )
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        // The rewrite may have made the document shorter than the old offset.
        let limit = max(0, textView.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, rect.minY), limit)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

struct DiffDocumentView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceSummary
    let path: String

    @State private var file: FileDiff?
    @State private var isLoading = false
    @State private var isViewed = false
    @State private var commentTarget: CommentTarget?
    // A dragged line selection: the two anchors are stored as "row keys"
    // (hunkIndex, lineIndex) and normalised when a comment is composed.
    @State private var selectionAnchor: LineRef?
    @State private var selectionFocus: LineRef?
    /// The diff, flattened and syntax-coloured once per load.
    @State private var rowSet: DiffRowSet = .empty
    /// The loaded diff's fingerprint, computed off main with the rows rather
    /// than re-derived on the main actor every time "Viewed" is touched.
    @State private var contentFingerprint = ""
    @State private var sourceText = ""
    @State private var savedSourceText = ""
    @State private var sourceError: String?
    /// A deleted document's last version, so its preview still has something
    /// to render.
    @State private var baseText: String?
    @State private var mode: FilePresentationMode = .diff
    @State private var isSaving = false
    @State private var conflictHunks: [ConflictHunk] = []

    typealias LineRef = DiffLineRef

    private struct CommentTarget: Identifiable {
        var id: String { "\(filePath):\(startLine)-\(endLine)" }
        var filePath: String
        var startLine: Int
        var endLine: Int
        var context: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(OreTheme.hairline).frame(height: 1)
            if !conflictHunks.isEmpty {
                conflictBanner
            }

            if mode == .preview, supportsPreview {
                documentPreview
            } else if mode == .source, hasSource {
                sourceEditor
            } else if let file {
                diffScroll(file)
            } else if isLoading && file == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: OreTheme.Space.sm) {
                    Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No diff for this file")
                        .font(.system(size: OreTheme.Font.title, weight: .medium))
                        .foregroundStyle(.secondary)
                    if hasSource {
                        Button("Open Source") { setMode(.source) }
                            .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Full height whatever the state: the header stays pinned to the top
        // and a one-line message never shrinks the document to its own size.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Code wants paper, not weather: syntax colour on drifting wallpaper
        // light is where translucency stops being worth it. One opaque sheet,
        // not the two stacked translucent fills this used to be (0.85 here and
        // 0.6 again under the diff, the same colour twice) — that cost a blend
        // per frame across the whole document for a difference nobody could see.
        .background(OreTheme.Surface.content)
        .task(id: path) { await load() }
        // Debounced: the generation moves on every write in the worktree, so a
        // working agent would otherwise have this file re-read, re-flattened
        // and re-hashed many times a second. One pass per burst, the same
        // policy the review list uses.
        .task(id: model.gitGeneration(for: workspace.id)) { await load(debounced: true) }
        .onChange(of: model.fileFocus[workspace.id]?[path]) { _, focus in
            // A `file:line` click on an already-open file must show source, not
            // the diff, so the line reveal lands somewhere visible.
            if focus != nil, hasSource { mode = .source }
        }
        .sheet(item: $commentTarget) { target in
            CommentSheet(
                filePath: target.filePath,
                line: target.startLine,
                endLine: target.endLine,
                context: target.context
            ) { body in
                model.addDiffComment(
                    DiffCommentReference(
                        filePath: target.filePath,
                        startLine: target.startLine,
                        endLine: target.endLine,
                        body: body,
                        context: target.context
                    ),
                    for: workspace.id
                )
                clearSelection()
            }
        }
    }

    private var header: some View {
        HStack(spacing: OreTheme.Space.sm) {
            SourceFileIcon(path: path, size: 18)
            Text((path as NSString).lastPathComponent)
                .font(.system(size: OreTheme.Font.title, weight: .semibold))
                .lineLimit(1)
            let folder = (path as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                Text(folder)
                    .font(.system(size: OreTheme.Font.caption))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: OreTheme.Space.sm)

            Picker("View", selection: modeBinding) {
                if supportsPreview { Text("Preview").tag(FilePresentationMode.preview) }
                if hasSource { Text("Source").tag(FilePresentationMode.source) }
                if file != nil { Text("Diff").tag(FilePresentationMode.diff) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if mode == .source, sourceText != savedSourceText {
                Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isSaving)
                    .keyboardShortcut("s", modifiers: .command)
            }

            if mode == .source {
                Text(FileVisualIdentity(path: path).label.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            if let file {
                Text("+\(file.insertions)")
                    .font(.system(size: OreTheme.Font.caption).monospacedDigit())
                    .foregroundStyle(OreTheme.added)
                Text("−\(file.deletions)")
                    .font(.system(size: OreTheme.Font.caption).monospacedDigit())
                    .foregroundStyle(OreTheme.removed)
            }

            Toggle(isOn: $isViewed) { Text("Viewed").font(.system(size: OreTheme.Font.body)) }
                .toggleStyle(.checkbox)
                .onChange(of: isViewed) { _, viewed in
                    model.markViewed(path, hash: viewed ? contentFingerprint : nil, for: workspace.id)
                }

            Button { model.closeDiffFile(path, in: workspace.id) } label: {
                Image(systemName: "xmark").frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Close this file tab")
        }
        .padding(.horizontal, OreTheme.Space.md)
        .frame(height: 40)
        .background(.bar)
    }

    private var modeBinding: Binding<FilePresentationMode> {
        Binding(
            get: { mode },
            set: { value in
                mode = value
                model.setFilePresentationMode(value, path: path, in: workspace.id)
            }
        )
    }

    private func setMode(_ value: FilePresentationMode) {
        mode = value
        model.setFilePresentationMode(value, path: path, in: workspace.id)
    }

    private var supportsPreview: Bool {
        FilePresentationMode.supportsPreview(path: path)
    }

    private var hasSource: Bool {
        FilePresentationMode.hasSource(path: path)
    }

    /// The rendered file — how a markdown document, an HTML page or an image
    /// opens by default. Source and diff stay one segment away.
    @ViewBuilder
    private var documentPreview: some View {
        switch FilePresentationMode.previewKind(path: path) {
        case .image:
            ScrollView {
                BinaryFilePreview(
                    path: path,
                    // Only a deletion changes what "the file" is here; the
                    // side-by-side comparison belongs to the Diff segment.
                    status: file?.status == .deleted ? .deleted : nil,
                    originalPath: file?.originalPath,
                    workspaceID: workspace.id,
                    worktreePath: workspace.worktreePath,
                    generation: model.gitGeneration(for: workspace.id),
                    onComment: { commentOnWholeFile() }
                )
            }
            .oreOverlayScrollers()
        case .html:
            if isLoading && sourceText.isEmpty && baseText == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let sourceError, baseText == nil {
                unavailable(sourceError)
            } else {
                HTMLFilePreview(
                    worktreePath: workspace.worktreePath,
                    path: path,
                    generation: model.gitGeneration(for: workspace.id),
                    fallbackHTML: baseText
                )
                .clipped()
            }
        case .markdown, nil:
            markdownPreview
        }
    }

    @ViewBuilder
    private var markdownPreview: some View {
        if isLoading && sourceText.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let text = sourceError == nil ? sourceText : baseText {
            MarkdownPreview(markdown: text)
                .accessibilityLabel("Preview of \((path as NSString).lastPathComponent)")
                .clipped()
        } else {
            unavailable(sourceError ?? "")
        }
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Can’t open this file", systemImage: "doc.badge.ellipsis")
        } description: {
            Text(message)
        } actions: {
            if file != nil, mode != .diff {
                Button("Show Diff") { setMode(.diff) }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var sourceEditor: some View {
        if isLoading && sourceText.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let sourceError {
            unavailable(sourceError)
        } else {
            SourceCodeEditor(
                text: $sourceText,
                path: path,
                focus: model.fileFocus[workspace.id]?[path]
            )
                .accessibilityLabel("Source for \((path as NSString).lastPathComponent)")
                .clipped()
        }
    }

    private func diffScroll(_ file: FileDiff) -> some View {
        // One GeometryReader for the document — not one per line, which is what
        // the old frame-reporting rows amounted to. It only supplies the
        // viewport width the rows are stretched to.
        GeometryReader { geo in
            let width = DiffRowBuilder.documentWidth(
                columns: rowSet.columns, viewport: geo.size.width
            )
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rowSet.rows) { row in
                        DiffLineRow(
                            row: row,
                            width: width,
                            isSelected: isSelected(row),
                            onComment: commentSingle
                        )
                        .equatable()
                    }
                    if file.isBinary {
                        // An icon or a screenshot is precisely the change a
                        // reviewer most needs to *see*, and it was the one case
                        // showing the least: git reduces it to "Binary files
                        // differ" and this pane printed that as "Binary file".
                        BinaryFilePreview(
                            path: file.path,
                            status: file.status,
                            originalPath: file.originalPath,
                            workspaceID: workspace.id,
                            worktreePath: workspace.worktreePath,
                            generation: model.gitGeneration(for: workspace.id),
                            onComment: { commentOnWholeFile() }
                        )
                    }
                    if file.isTruncated {
                        Text("This diff is too large to display.")
                            .foregroundStyle(.secondary).padding()
                    }
                }
                // Fixed width for every row, from the longest line in the whole
                // diff rather than from whichever rows happen to be on screen.
                .frame(width: width, alignment: .leading)
                .coordinateSpace(name: oreDiffSpaceName)
                .overlay(alignment: .topLeading) {
                    // Drag within the gutter strip to select a line range.
                    // Confining the gesture to the ~90pt gutter keeps it from
                    // fighting the scroll view, which still owns vertical drags
                    // over the code.
                    Color.clear
                        .frame(width: DiffRowBuilder.dragWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 4, coordinateSpace: .named(oreDiffSpaceName))
                                .onChanged { value in
                                    // Fixed row heights make this arithmetic —
                                    // a binary search over precomputed offsets
                                    // — instead of a scan of live frames.
                                    if let ref = rowSet.row(atY: value.location.y)?.ref {
                                        updateSelection(to: ref)
                                    }
                                }
                                .onEnded { _ in commentSelection(in: file) }
                        )
                }
                // Outside the coordinate space, so row offsets stay measured
                // from the first row rather than from the padding.
                .padding(.vertical, 6)
            }
            .oreOverlayScrollers()
        }
        // No fill: the document already lays one opaque sheet of paper down
        // (see `body`). Two stacked translucent fills of the same colour cost a
        // blend per frame over the whole diff and looked identical.
    }

    // MARK: - Selection

    private func isSelected(_ row: DiffDocumentRow) -> Bool {
        guard let ref = row.ref else { return false }
        return isSelected(hunk: ref.hunk, line: ref.line)
    }

    private func isSelected(hunk: Int, line: Int) -> Bool {
        guard let a = selectionAnchor, let b = selectionFocus, a.hunk == b.hunk, hunk == a.hunk else { return false }
        return line >= min(a.line, b.line) && line <= max(a.line, b.line)
    }

    private func updateSelection(to ref: LineRef) {
        if selectionAnchor == nil { selectionAnchor = ref }
        // Selection is kept within a single hunk — a range spanning a hunk
        // boundary isn't a contiguous region of the file.
        if ref.hunk == selectionAnchor?.hunk { selectionFocus = ref }
    }

    private func clearSelection() {
        selectionAnchor = nil
        selectionFocus = nil
    }

    /// A comment on a file that has no lines to anchor to.
    ///
    /// Binary files still need review — "this icon is the wrong shade" is a
    /// perfectly good review comment — but every other comment path here
    /// starts from a line number. Line 1 stands in for the file as a whole,
    /// which is the same convention GitHub uses for file-level comments.
    private func commentOnWholeFile() {
        commentTarget = CommentTarget(
            filePath: path, startLine: 1, endLine: 1,
            context: (path as NSString).lastPathComponent
        )
    }

    /// Looked up from the current `file` rather than captured per row: the row
    /// carries only what it draws, and the closure it hands out survives an
    /// `.equatable()` skip without going stale.
    private func commentSingle(_ row: DiffDocumentRow) {
        guard let ref = row.ref, let file, file.hunks.indices.contains(ref.hunk) else { return }
        let hunk = file.hunks[ref.hunk]
        guard hunk.lines.indices.contains(ref.line) else { return }
        let line = hunk.lines[ref.line]
        guard let number = line.newLineNumber ?? line.oldLineNumber else { return }
        commentTarget = CommentTarget(
            filePath: path, startLine: number, endLine: number,
            context: contextAround(lines: [line], in: hunk)
        )
    }

    private func commentSelection(in file: FileDiff) {
        guard let a = selectionAnchor, let b = selectionFocus, a.hunk == b.hunk,
              file.hunks.indices.contains(a.hunk) else { clearSelection(); return }
        let hunk = file.hunks[a.hunk]
        let lo = min(a.line, b.line), hi = max(a.line, b.line)
        guard lo != hi else { clearSelection(); return }   // a single click isn't a drag-select
        let selected = (lo...hi).compactMap { hunk.lines.indices.contains($0) ? hunk.lines[$0] : nil }
        let numbers = selected.compactMap { $0.newLineNumber ?? $0.oldLineNumber }
        guard let start = numbers.first, let end = numbers.last else { clearSelection(); return }
        commentTarget = CommentTarget(
            filePath: path, startLine: start, endLine: end,
            context: contextAround(lines: selected, in: hunk)
        )
    }

    // MARK: - Data

    /// Every assignment here re-runs `body`, and on a debounced pass almost
    /// nothing has usually changed — so each one is guarded on being a real
    /// change rather than written unconditionally.
    private func load(debounced: Bool = false) async {
        if debounced {
            try? await Task.sleep(for: ReviewRefreshPolicy.gitDebounce)
            guard !Task.isCancelled else { return }
        }
        let showLoader = file == nil && sourceText.isEmpty
        if showLoader { isLoading = true }
        defer { isLoading = false }
        // A PNG has no text to read, and trying is what used to put "can only
        // edit UTF-8 text files" where the image should have been.
        let readsSource = hasSource
        let workspace = self.workspace
        let path = self.path
        let sourceRead: Task<Result<String, any Error>, Never>? = readsSource
            ? Task { [model] in
                do { return .success(try await model.fileContents(path: path, in: workspace)) }
                catch { return .failure(error) }
            }
            : nil
        let diffs = (try? await model.loadDiff(for: workspace.id)) ?? []
        let loaded = diffs.first { $0.path == path }
        let isDeleted = loaded?.status == .deleted

        if loaded != file {
            // Flatten, lex, colour and fingerprint the whole diff away from the
            // main actor. Both passes walk every line, and both used to run on
            // the main actor once per git generation.
            let built = await Task.detached(priority: .userInitiated) { () -> (DiffRowSet, String) in
                guard let loaded else { return (.empty, "") }
                return (DiffRowBuilder.build(loaded), DiffContentHash.of(loaded))
            }.value
            guard !Task.isCancelled else { return }
            // All three together, and only once the rows exist: publishing
            // `file` first and then bailing on cancellation would leave rows
            // that no longer match it, and the next load would see no change
            // and never rebuild them.
            file = loaded
            rowSet = built.0
            contentFingerprint = built.1
        }

        switch await sourceRead?.value {
        case .success(let text):
            if sourceText != text { sourceText = text }
            if savedSourceText != text { savedSourceText = text }
            if sourceError != nil { sourceError = nil }
        case .failure(let error):
            let message = Self.sourceErrorMessage(error, isDeleted: isDeleted)
            if sourceError != message { sourceError = message }
        case nil:
            if sourceError != nil { sourceError = nil }
        }

        // A deleted document still has a preview: the version it had at the base.
        let previewKind = FilePresentationMode.previewKind(path: path)
        if isDeleted, sourceError != nil, previewKind == .markdown || previewKind == .html {
            let data = await model.baseFileData(path: file?.originalPath ?? path, in: workspace.id)
            let text = data.flatMap { String(data: $0, encoding: .utf8) }
            if baseText != text { baseText = text }
        } else if baseText != nil {
            baseText = nil
        }

        let requested = model.filePresentationModes[workspace.id]?[path]
            ?? (supportsPreview ? .preview : .diff)
        var resolved = file == nil && requested == .diff
            ? FilePresentationMode.preferred(forPath: path)
            : requested
        if resolved == .source, !readsSource {
            resolved = supportsPreview ? .preview : .diff
        }
        if mode != resolved { mode = resolved }
        let stored = await model.loadViewedFiles(for: workspace.id)
        if file != nil {
            let viewed = stored[path] == contentFingerprint
            if isViewed != viewed { isViewed = viewed }
        }
        let hunks = await model.loadConflictHunks(path: path, for: workspace.id)
        if conflictHunks != hunks { conflictHunks = hunks }
    }

    /// Why the editor can't show this file, in terms of this file.
    private static func sourceErrorMessage(_ error: any Error, isDeleted: Bool) -> String {
        if isDeleted {
            return "This file was deleted on this branch. The diff shows what it contained."
        }
        switch (error as? CocoaError)?.code {
        case .fileReadTooLarge?:
            return "This file is larger than 2 MB, more than ORE opens in its editor."
        case .fileReadInapplicableStringEncoding?:
            return "This isn’t a UTF-8 text file, so it can’t be edited here."
        case .fileReadNoSuchFile?, .fileNoSuchFile?:
            return "This file isn’t in the worktree."
        default:
            return "ORE can only edit UTF-8 text files smaller than 2 MB."
        }
    }

    private var conflictBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("\(conflictHunks.count) conflict\(conflictHunks.count == 1 ? "" : "s")")
                    .font(.system(size: OreTheme.Font.body, weight: .semibold))
                Spacer()
                Button("Ours") {
                    model.resolveConflict(path: path, side: .ours, in: workspace.id)
                }
                Button("Theirs") {
                    model.resolveConflict(path: path, side: .theirs, in: workspace.id)
                }
            }
            ForEach(conflictHunks) { hunk in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(hunk.startLine)–\(hunk.endLine)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(hunk.ours.components(separatedBy: "\n").first ?? "")
                        .lineLimit(1)
                        .font(.caption)
                    Spacer()
                    Button("Ours") {
                        model.resolveConflictHunk(
                            path: path, startLine: hunk.startLine, side: .ours, in: workspace.id
                        )
                    }
                    .controlSize(.small)
                    Button("Theirs") {
                        model.resolveConflictHunk(
                            path: path, startLine: hunk.startLine, side: .theirs, in: workspace.id
                        )
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, OreTheme.Space.md)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private func save() async {
        guard sourceText != savedSourceText else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.saveFileContents(sourceText, path: path, in: workspace)
            savedSourceText = sourceText
            sourceError = nil
        } catch {
            sourceError = error.localizedDescription
        }
    }

    private func contextAround(lines: [DiffLine], in hunk: DiffHunk) -> String {
        guard let first = lines.first,
              let index = hunk.lines.firstIndex(where: {
                  $0.newLineNumber == first.newLineNumber && $0.oldLineNumber == first.oldLineNumber
              }) else { return lines.map(\.text).joined(separator: "\n") }
        let start = max(hunk.lines.startIndex, index - 3)
        let end = min(hunk.lines.endIndex, index + lines.count + 3)
        return hunk.lines[start..<end].map { entry in
            let marker = entry.kind == .added ? "+" : (entry.kind == .removed ? "-" : " ")
            return marker + entry.text
        }.joined(separator: "\n")
    }
}

/// One row of a diff — a hunk header or a line — drawn from a finished
/// `DiffDocumentRow`.
///
/// `Equatable`, and applied through `.equatable()`. Rows slide under the
/// pointer constantly while scrolling and the document's own state changes on
/// every drag-select step; without this, every materialised row re-ran `body`
/// each time, and `body` used to re-lex the line.
private struct DiffLineRow: View, Equatable {
    let row: DiffDocumentRow
    /// The document width, so every row's tint spans the full line even when
    /// the code is shorter than the viewport.
    let width: CGFloat
    let isSelected: Bool
    /// Deliberately left out of `==`: the parent rebuilds this closure on every
    /// pass, but it always does the same thing — look the row's ref up in the
    /// parent's current state. Closures can't be compared, and treating a fresh
    /// one as a change would defeat the point of being Equatable at all.
    let onComment: (DiffDocumentRow) -> Void

    /// `nonisolated` because `Equatable` is: SwiftUI compares view values
    /// without promising the main actor, and every field read here is a plain
    /// `let` of a Sendable type.
    nonisolated static func == (lhs: DiffLineRow, rhs: DiffLineRow) -> Bool {
        lhs.isSelected == rhs.isSelected && lhs.width == rhs.width && lhs.row == rhs.row
    }

    var body: some View {
        HStack(spacing: 0) {
            if row.isHeader {
                Text(row.text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
            } else {
                Text(row.oldNumber)
                    .frame(width: 38, alignment: .trailing)
                Text(row.newNumber)
                    .frame(width: 38, alignment: .trailing)
                // The comment slot, held open by the overlay below.
                Color.clear.frame(width: 26)
                // One line, at its natural width: wrapping is what made row
                // heights unpredictable. The document scrolls sideways instead.
                Text(row.text)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: DiffRowBuilder.fontSize, design: .monospaced))
        .foregroundStyle(textColor)
        .frame(width: width, height: row.height, alignment: .leading)
        .background(background)
        .overlay(alignment: .leading) {
            if !row.isHeader {
                DiffRowCommentButton(row: row, isSelected: isSelected) { onComment(row) }
            }
        }
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(Color.accentColor).frame(width: 2) }
        }
    }

    private var textColor: Color {
        row.kind == .noNewline ? .secondary : .primary
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.20) }
        switch row.kind {
        case nil: return OreTheme.subduedFill
        case .added: return .green.opacity(0.13)
        case .removed: return .red.opacity(0.13)
        default: return .clear
        }
    }
}

/// The gutter's "+", and the hover state that reveals it.
///
/// Commenting is the point of the diff view, so the affordance is one click
/// from any line — and it is always shown for a selected range, which is where
/// the "+" from the reference appears.
///
/// Its own view purely so `isHovering` lives here. Rows pass under a still
/// pointer on every scroll, and hover state held on the row itself re-ran the
/// row's `body` each time — which, before the rows were precomputed, meant
/// re-lexing the line. The transparent backing keeps the target the whole row,
/// which is the reach it has always had; only the state moved.
private struct DiffRowCommentButton: View {
    let row: DiffDocumentRow
    let isSelected: Bool
    let onComment: () -> Void
    @State private var isHovering = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .overlay(alignment: .leading) {
                Button(action: onComment) {
                    Image(systemName: "plus.bubble")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .frame(width: 26, height: row.height)
                // Past the two number columns, into the gutter's third slot.
                .padding(.leading, 76)
                .opacity(isHovering || isSelected ? 1 : 0)
                .disabled(row.commentLine == nil)
            }
    }
}

private struct CommentSheet: View {
    let filePath: String
    let line: Int
    var endLine: Int
    let context: String
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var body_ = ""

    private var title: String {
        let name = (filePath as NSString).lastPathComponent
        return line == endLine ? "\(name):\(line)" : "\(name) · lines \(line)–\(endLine)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.md) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))

            Text(context)
                .font(.system(size: 10, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(OreTheme.subduedFill, in: RoundedRectangle(cornerRadius: 12))

            TextEditor(text: $body_)
                .font(.body)
                .frame(height: 90)
                .overlay(alignment: .topLeading) {
                    if body_.isEmpty {
                        Text("What should the agent change here?")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Text("Sent with your next message.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(OreSecondaryButtonStyle())
                Button("Add Comment") {
                    onSubmit(body_)
                    dismiss()
                }
                .buttonStyle(OrePrimaryButtonStyle())
                .disabled(body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .oreCard(padding: OreTheme.Space.lg)
        .padding(OreTheme.Space.lg)
        .frame(width: 520)
    }
}

/// The GitLens-style strip above the action bar: uncommitted work, commits
/// not yet on any remote, and what CI thinks of what was pushed. Two tabs —
/// Commits (unpushed work) and Checks — with the panel switching itself to
/// Checks when runs start or change state, since that's the moment the user
/// is actually waiting on.
private struct ShipStatusPanel: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceSummary

    /// ~a quarter of a typical review pane; user-resizable and persisted.
    @AppStorage("ore.reviewShipHeight") private var height = 200.0
    @State private var dragStart: CGFloat?
    @State private var tab: ShipTab = .commits
    @State private var hoveredTab: ShipTab?
    @State private var hoveredCommit: String?
    @State private var hoveredCheck: String?
    /// The SHA whose chip is currently showing "Copied".
    @State private var copiedSHA: String?
    @State private var commits: [CommitInfo] = []
    @State private var workingTree: GitStatusSnapshot?
    @State private var pullRequest: GitHubClient.PullRequest?
    /// Signature of the last seen check states. Auto-switching happens only
    /// when this changes, so a user's manual tab choice survives quiet polls.
    @State private var checksFingerprint: Int?
    @State private var expandedCheck: String?
    @State private var checkLogs: [String: String] = [:]
    @State private var loadingCheckLog: String?

    private enum ShipTab: Hashable { case commits, checks }

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            header
            list
                .frame(height: max(80, min(height, 400) - 34))
        }
        // The suggested action is in the key because the panel's own poll gives
        // up the moment it sees no PR (`guard let pr` below), and a PR opened
        // from the terminal moves no local file to restart it. When the action
        // notices the PR, the panel reloads with it.
        //
        // Hidden host: the poll is three child processes per iteration, and CI
        // can run for half an hour. Ending the task while hidden, and keying
        // on the flag, means showing the window restarts it with a fresh load.
        .task(id: "\(workspace.id.rawValue)-\(model.gitGeneration(for: workspace.id))-\(model.gitAction(for: workspace.id).title)-\(model.isBackgroundPollingEnabled)") {
            guard model.isBackgroundPollingEnabled else { return }
            await load()
            // CI has no local filesystem event to ride on. GitHub often posts
            // the first check runs several seconds after a push, so poll fast
            // briefly even before any runs appear — but only inside a short
            // window measured from this task's start (the task restarts on
            // every git-status change, i.e. after each push). Without that
            // bound, a repo with no CI has permanently empty `checks` and would
            // pin us at a 4s `gh` poll forever.
            let started = ContinuousClock.now
            while !Task.isCancelled {
                guard let pr = pullRequest else { return }
                let withinFirstRunWindow = started.duration(to: .now) < .seconds(90)
                // Nothing running and no runs will appear now → let the task end;
                // the next git-status change restarts it.
                if pr.checks.isEmpty, !pr.hasRunningChecks, !withinFirstRunWindow {
                    return
                }
                let fast = pr.hasRunningChecks || (pr.checks.isEmpty && withinFirstRunWindow)
                try? await Task.sleep(for: .seconds(fast ? 4 : 12))
                guard !Task.isCancelled, model.isBackgroundPollingEnabled else { return }
                await load()
            }
        }
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
                    if dragStart == nil { dragStart = height }
                    height = min(max((dragStart ?? height) - value.translation.height, 120), 400)
                }
                .onEnded { _ in dragStart = nil })
            .help("Drag to resize")
    }

    private var header: some View {
        HStack(spacing: OreTheme.Space.xs) {
            segment("Commits", count: commits.count, target: .commits)
            segment("Checks", count: activeCheckCount, target: .checks)
            Spacer(minLength: 0)
            if pullRequest?.failingChecks.isEmpty == false {
                Button {
                    model.rerunFailedChecks(workspace.id)
                } label: {
                    Label("Re-run failed", systemImage: "arrow.clockwise")
                        .font(.system(size: OreTheme.Font.caption, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Re-run the failed jobs on GitHub")
            }
            if pullRequest?.hasRunningChecks == true {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, OreTheme.Space.sm)
        .frame(height: 29)
    }

    /// Running or failing checks are the ones worth counting; a wall of green
    /// needs no number.
    private var activeCheckCount: Int? {
        guard let pullRequest, !pullRequest.checks.isEmpty else { return nil }
        let active = pullRequest.checks.filter { !$0.isComplete || !$0.isSuccess }.count
        return active > 0 ? active : pullRequest.checks.count
    }

    private func segment(_ title: String, count: Int?, target: ShipTab) -> some View {
        let isSelected = tab == target
        return Button {
            // Commits is a verb here, not just a filter: with uncommitted work
            // in the tree, clicking it asks the current tab's agent — which
            // already knows the work — to stage and commit with real
            // messages. With a clean tree it stays a tab.
            if target == .commits, model.gitChrome(for: workspace.id).hasUncommittedChanges {
                model.commitWithAgent(in: workspace.id)
            }
            tab = target
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: OreTheme.Font.body, weight: isSelected ? .semibold : .regular))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: OreTheme.Font.caption).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 21)
            .background(
                isSelected ? OreTheme.selectedFill
                    : hoveredTab == target ? OreTheme.subduedFill : .clear,
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(OrePressableButtonStyle())
        .foregroundStyle(isSelected ? .primary : .secondary)
        .fixedSize(horizontal: true, vertical: false)
        .onHover { hovering in
            if hovering { hoveredTab = target }
            else if hoveredTab == target { hoveredTab = nil }
        }
    }

    @ViewBuilder
    private var list: some View {
        switch tab {
        case .commits: commitsList
        case .checks: checksList
        }
    }

    private var commitsList: some View {
        Group {
            if commits.isEmpty, (workingTree?.files.isEmpty ?? true) {
                shipEmpty(
                    icon: "checkmark.circle",
                    text: model.gitChrome(for: workspace.id).hasUncommittedChanges
                        ? "No commits yet" : "Everything pushed"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let workingTree {
                            if workingTree.unstagedFileCount > 0 {
                                wipRow(
                                    title: "Unstaged",
                                    subtitle: fileCountLabel(workingTree.unstagedFileCount),
                                    insertions: workingTree.unstagedInsertions,
                                    deletions: workingTree.unstagedDeletions,
                                    icon: "pencil.circle",
                                    isFirst: true,
                                    isLast: workingTree.stagedFileCount == 0 && commits.isEmpty
                                )
                            }
                            if workingTree.stagedFileCount > 0 {
                                wipRow(
                                    title: "Staged",
                                    subtitle: fileCountLabel(workingTree.stagedFileCount),
                                    insertions: workingTree.stagedInsertions,
                                    deletions: workingTree.stagedDeletions,
                                    icon: "checkmark.circle",
                                    isFirst: workingTree.unstagedFileCount == 0,
                                    isLast: commits.isEmpty
                                )
                            }
                        }
                        ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                            commitRow(
                                commit,
                                isFirst: index == 0 && !hasWorkingTreeWIP,
                                isLast: index == commits.count - 1
                            )
                        }
                    }
                    .padding(.vertical, 6)
                }
                .oreOverlayScrollers()
            }
        }
    }

    private var hasWorkingTreeWIP: Bool {
        (workingTree?.unstagedFileCount ?? 0) > 0 || (workingTree?.stagedFileCount ?? 0) > 0
    }

    private func fileCountLabel(_ count: Int) -> String {
        "\(count) file\(count == 1 ? "" : "s")"
    }

    private func wipRow(
        title: String,
        subtitle: String,
        insertions: Int,
        deletions: Int,
        icon: String,
        isFirst: Bool,
        isLast: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            timelineDot(isFirst: isFirst, isLast: isLast, filled: false)
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: OreTheme.Font.body, weight: .medium))
                Text(subtitle)
                    .font(.system(size: OreTheme.Font.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if insertions > 0 || deletions > 0 {
                HStack(spacing: 4) {
                    if insertions > 0 {
                        Text("+\(insertions)")
                            .foregroundStyle(OreTheme.added)
                    }
                    if deletions > 0 {
                        Text("−\(deletions)")
                            .foregroundStyle(OreTheme.removed)
                    }
                }
                .font(.system(size: OreTheme.Font.caption, design: .monospaced).weight(.medium))
            }
        }
        .padding(.horizontal, OreTheme.Space.sm)
        .padding(.vertical, 7)
    }

    private func commitRow(_ commit: CommitInfo, isFirst: Bool, isLast: Bool) -> some View {
        let hovering = hoveredCommit == commit.sha
        return HStack(alignment: .center, spacing: 10) {
            timelineDot(isFirst: isFirst, isLast: isLast, filled: true)
            OreMonogram(name: commit.author, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject)
                    .font(.system(size: OreTheme.Font.body, weight: .medium))
                    .lineLimit(2)
                Text("\(commit.author) · \(commit.date.formatted(.relative(presentation: .named)))")
                    .font(.system(size: OreTheme.Font.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if commit.insertions > 0 || commit.deletions > 0 {
                HStack(spacing: 4) {
                    if commit.insertions > 0 {
                        Text("+\(commit.insertions)")
                            .foregroundStyle(OreTheme.added)
                    }
                    if commit.deletions > 0 {
                        Text("−\(commit.deletions)")
                            .foregroundStyle(OreTheme.removed)
                    }
                }
                .font(.system(size: OreTheme.Font.caption, design: .monospaced).weight(.medium))
            }
            // The chip says "Copied" for a beat instead of the SHA. The
            // clipboard gives no sign of its own, and a button that looks
            // identical before and after is indistinguishable from one that
            // did nothing.
            Button(action: { copySHA(commit.sha); flashCopiedSHA(commit.sha) }) {
                Text(copiedSHA == commit.sha ? "Copied" : commit.shortSHA)
                    .font(.system(size: OreTheme.Font.caption, design: .monospaced))
                    .foregroundStyle(copiedSHA == commit.sha
                        ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(OreTheme.subduedFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .animation(.easeOut(duration: 0.15), value: copiedSHA)
            .help(copiedSHA == commit.sha ? "Copied" : "Copy commit SHA")
        }
        .padding(.horizontal, OreTheme.Space.sm)
        .padding(.vertical, 7)
        .background(hovering ? OreTheme.subduedFill : .clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredCommit = hovering ? commit.sha : (hoveredCommit == commit.sha ? nil : hoveredCommit)
        }
    }

    private func timelineDot(isFirst: Bool, isLast: Bool, filled: Bool) -> some View {
        ZStack {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : Color.primary.opacity(0.12))
                    .frame(width: 1)
                Rectangle()
                    .fill(isLast ? Color.clear : Color.primary.opacity(0.12))
                    .frame(width: 1)
            }
            Circle()
                .fill(filled ? Color.accentColor.opacity(0.22) : Color.clear)
                .overlay {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: filled ? 0 : 1.5)
                }
                .frame(width: 11, height: 11)
                .overlay {
                    if filled {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5, height: 5)
                    }
                }
        }
        .frame(width: 14)
    }

    /// Which SHA the row is currently acknowledging, keyed by value so only
    /// the commit that was clicked reports back.
    private func flashCopiedSHA(_ sha: String) {
        copiedSHA = sha
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if copiedSHA == sha { copiedSHA = nil }
        }
    }

    private func copySHA(_ sha: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sha, forType: .string)
    }

    private var checksList: some View {
        Group {
            if let pullRequest, !pullRequest.checks.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(pullRequest.checks, id: \.self) { check in
                            checkRow(check)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .oreOverlayScrollers()
            } else if pullRequest != nil {
                shipEmpty(icon: "checklist", text: "No checks reported")
            } else {
                shipEmpty(icon: "arrow.triangle.pull", text: "No pull request yet")
            }
        }
    }

    private func checkRow(_ check: GitHubClient.CheckRun) -> some View {
        let hovering = hoveredCheck == check.name
        let expanded = expandedCheck == check.name
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: OreTheme.Space.sm) {
                Group {
                    if !check.isComplete {
                        ProgressView().controlSize(.mini)
                    } else if check.isSuccess {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(check.name)
                        .font(.system(size: OreTheme.Font.body, weight: .medium))
                        .lineLimit(1)
                    if let workflow = check.workflow, !workflow.isEmpty {
                        Text(workflow)
                            .font(.system(size: OreTheme.Font.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let duration = check.duration {
                    Text(Self.format(duration: duration))
                        .font(.system(size: OreTheme.Font.caption).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if !check.isSuccess, check.isComplete {
                    Button {
                        toggleCheckLog(check)
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "doc.text")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Show failing log")
                }
                if let link = check.link, let url = URL(string: link) {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open this check on GitHub")
                }
            }
            if expanded {
                if loadingCheckLog == check.name {
                    ProgressView().controlSize(.small)
                } else if let log = checkLogs[check.name], !log.isEmpty {
                    ScrollView {
                        Text(log)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .oreOverlayScrollers()
                    .frame(maxHeight: 160)
                    .padding(6)
                    .background(OreTheme.subduedFill, in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Text("No log available yet.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, OreTheme.Space.sm)
        .padding(.vertical, 7)
        .background(hovering ? OreTheme.subduedFill : .clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredCheck = hovering ? check.name : (hoveredCheck == check.name ? nil : hoveredCheck)
        }
        .onTapGesture {
            if !check.isSuccess, check.isComplete { toggleCheckLog(check) }
        }
    }

    private func toggleCheckLog(_ check: GitHubClient.CheckRun) {
        if expandedCheck == check.name {
            expandedCheck = nil
            return
        }
        expandedCheck = check.name
        guard checkLogs[check.name] == nil else { return }
        loadingCheckLog = check.name
        Task {
            let log = await model.loadCheckLog(named: check.name, for: workspace.id)
            checkLogs[check.name] = log ?? ""
            loadingCheckLog = nil
        }
    }

    private func shipEmpty(icon: String, text: String) -> some View {
        HStack(spacing: OreTheme.Space.sm) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: OreTheme.Font.body))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func format(duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        let minutes = total / 60, seconds = total % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }

    private func load() async {
        async let loadedCommits = model.loadUnpushedCommits(for: workspace.id)
        async let loadedPR = model.loadPullRequestStatus(for: workspace.id)
        async let loadedTree = model.loadWorkingTreeStatus(for: workspace.id)
        commits = await loadedCommits
        workingTree = await loadedTree
        let pr = await loadedPR
        let changed = pr != pullRequest
        pullRequest = pr
        // The toolbar's "Checks running" reads its own copy of the PR, which
        // nothing else refreshes when CI finishes. This read is live and has
        // just refilled the shared cache, so the recompute costs no fetch.
        if changed {
            await model.refreshGitAction(for: workspace.id)
        }

        // Auto-switch to Checks when runs appear or progress; return to
        // Commits when a PR (and its checks) go away entirely.
        guard let pr, !pr.checks.isEmpty else {
            checksFingerprint = nil
            if tab == .checks { tab = .commits }
            return
        }
        var hasher = Hasher()
        for check in pr.checks {
            hasher.combine(check.name)
            hasher.combine(check.state)
        }
        let fingerprint = hasher.finalize()
        if fingerprint != checksFingerprint {
            let hadPrevious = checksFingerprint != nil
            checksFingerprint = fingerprint
            // Progress mid-run, or a fresh run starting, pulls focus; the
            // very first fetch after opening the pane does so only when
            // something is actually running.
            if pr.hasRunningChecks || hadPrevious {
                tab = .checks
            }
        }
    }
}

/// The next git step, shown in the window toolbar so shipping isn't buried
/// under the review pane. Hidden when there is nothing to do — a clean tree
/// with no commits ahead of base must not offer "Create pull request".
struct GitActionToolbar: View {
    @Environment(AppModel.self) private var model
    static let checksPollInterval = 10
    let workspace: WorkspaceSummary

    @State private var chosenBase: String?
    @State private var branches: [String] = []
    @State private var prURL: String?
    @State private var editor: GitEditor?

    private enum GitEditor: String, Identifiable {
        case commit, pullRequest, merge
        var id: String { rawValue }
    }

    private var action: SuggestedGitAction {
        model.gitAction(for: workspace.id)
    }

    private var actionImpliesPR: Bool {
        switch action {
        case .waitForChecks, .fixFailingChecks, .waitForReview, .merge,
             .resolveConflicts, .retargetAfterParentMerged, .merged,
             .waitForParentToMerge:
            return true
        default:
            return false
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if case .createPullRequest(let defaultBase, _) = action {
                baseMenu(defaultBase: defaultBase)
            }

            switch presentation {
            case .hidden:
                EmptyView()
            case .status(let title):
                Label(title, systemImage: icon)
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: OreTheme.Font.body, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("\(title). \(shortcutHint)")
            case .action(let title):
                Button {
                    presentOrPerform()
                } label: {
                    GitBusyLabel(
                        title: title,
                        systemImage: icon,
                        isBusy: isThisActionBusy
                    )
                }
                .buttonStyle(OreGitActionButtonStyle(tone: tone))
                .disabled(model.isGitOpInFlight(workspace.id))
                .help(actionHelp)
                .fixedSize()
                .accessibilityLabel(title)
                .accessibilityHint(actionHelp)
                // The default click delegates commit / PR to an agent tab; the
                // hand-written path survives here for the times the message
                // matters more than the minutes.
                .contextMenu {
                    if case .commit = action {
                        Button("Write Commit Message Manually…") { editor = .commit }
                    }
                    if case .createPullRequest = action {
                        Button("Write PR Title and Body Manually…") { editor = .pullRequest }
                    }
                }
                .popover(item: $editor) { kind in
                    gitEditor(kind)
                }
            }

            // Red CI shouldn't dead-end the flow. The primary action still
            // hands the failure to the agent; this is the escape hatch for a
            // failure the user has already judged irrelevant. It opens the same
            // MergeEditor as the normal merge, so the method choice is
            // unchanged — the popover is anchored on the primary button above.
            if action.mergeableDespiteChecks != nil {
                Button("Merge anyway") { editor = .merge }
                    .buttonStyle(OreSecondaryButtonStyle())
                    .disabled(model.isGitOpInFlight(workspace.id))
                    .help("Merge this pull request despite the failing checks")
                    .accessibilityLabel("Merge anyway")
                    .accessibilityHint("Merge this pull request despite the failing checks")
            }

            if case .merged = action {
                Button("Archive") { model.requestArchive(workspace.id) }
                    .buttonStyle(OreSecondaryButtonStyle())
                    .help("Archive this workspace — frees the worktree's disk space")
            }

            if let prURL, let url = URL(string: prURL) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Open this pull request on GitHub")
            }
        }
        .task(id: "\(workspace.id.rawValue)-\(action.title)-\(model.gitGeneration(for: workspace.id))") {
            if case .createPullRequest = action {
                branches = await model.remoteBranches(for: workspace.id)
            }
            prURL = actionImpliesPR ? await model.pullRequestURL(for: workspace.id) : nil
        }
        // "Checks running" is a claim about GitHub that no local event will
        // ever correct, so while it is showing it polls for itself — with the
        // review pane closed too. Ends the moment the title changes.
        .task(id: "\(workspace.id.rawValue)-checks-\(action.title)") {
            guard case .waitForChecks = action else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.checksPollInterval))
                if Task.isCancelled { return }
                await model.refreshChecks(for: workspace.id)
            }
        }
    }

    private enum Presentation {
        case hidden
        case status(String)
        case action(String)
    }

    /// Create PR / Continue / Merge only appear when that step is actually
    /// possible. Waiting states are a label, not a dummy button.
    private var presentation: Presentation {
        switch action {
        case .none:
            return .hidden
        case .committedNoRemote, .waitForChecks, .waitForReview, .waitForParentToMerge:
            // `committedNoRemote` is a real state with a diff to see — report it
            // rather than hiding it the way a clean, changeless tree is hidden.
            return .status(action.title)
        case .merged:
            return .action("Continue")
        default:
            return action.isActionable ? .action(action.title) : .status(action.title)
        }
    }

    private var tone: OreGitActionTone {
        switch action {
        case .commit: return .commit
        case .push, .createGitHubRepo: return .publish
        case .createPullRequest: return .pullRequest
        case .merge, .retargetAfterParentMerged: return .merge
        case .fixFailingChecks, .resolveConflicts: return .danger
        case .merged: return .success
        case .setUpGitHub: return .quiet
        default: return .pullRequest
        }
    }

    private var icon: String {
        switch action {
        case .none: return "checkmark.circle"
        case .committedNoRemote: return "checkmark.circle.badge.questionmark"
        case .createGitHubRepo: return "plus.rectangle.on.folder"
        case .commit: return "square.and.arrow.down"
        case .push: return "arrow.up.circle.fill"
        case .createPullRequest: return "arrow.triangle.pull"
        case .waitForChecks: return "clock"
        case .fixFailingChecks: return "xmark.octagon.fill"
        case .resolveConflicts: return "arrow.triangle.branch"
        case .waitForReview: return "person.2"
        case .merge: return "arrow.triangle.merge"
        case .waitForParentToMerge: return "square.stack.3d.up"
        case .retargetAfterParentMerged: return "arrow.uturn.right"
        case .merged: return "arrow.uturn.forward.circle.fill"
        case .setUpGitHub: return "gear"
        }
    }

    private var shortcutHint: String { "⌥⌘G" }

    private var actionHelp: String {
        switch action {
        case .commit:
            return "Ask this tab's agent to commit these changes, with messages written from the diff. (\(shortcutHint))"
        case .push(let count, let isFirst):
            return isFirst
                ? "Publish this branch to origin. (\(shortcutHint))"
                : "Push \(count) unpushed commit\(count == 1 ? "" : "s") to origin. (\(shortcutHint))"
        case .createPullRequest:
            return "Ask this tab's agent to commit what's left, push, and open the pull request. (\(shortcutHint))"
        case .createGitHubRepo:
            return "Create a GitHub repository for this project and publish the branch. (\(shortcutHint))"
        case .fixFailingChecks:
            return "Hand the failing CI logs to the agent. (\(shortcutHint))"
        case .resolveConflicts:
            return "Ask the agent to rebase and resolve conflicts. (\(shortcutHint))"
        case .merge:
            return "Merge this pull request. (\(shortcutHint))"
        case .retargetAfterParentMerged:
            return "Point this pull request at the new base. (\(shortcutHint))"
        case .merged:
            return "Pull the default branch locally and start a fresh branch in this worktree. (\(shortcutHint))"
        case .setUpGitHub:
            return "Sign in to GitHub with gh so this workspace can push and open PRs."
        default:
            return "\(action.title). (\(shortcutHint))"
        }
    }

    private func baseMenu(defaultBase: String) -> some View {
        let base = chosenBase ?? defaultBase
        return Menu {
            Button("\(defaultBase) (default)") { chosenBase = defaultBase }
            if !branches.isEmpty { Divider() }
            ForEach(branches.filter { $0 != workspace.branch }, id: \.self) { branch in
                Button(branch) { chosenBase = branch }
            }
        } label: {
            // One `Text`, not a styled `HStack`: a borderless menu on macOS
            // renders its label the way AppKit renders a menu item — image
            // first, and only the first string survives — which is why the
            // picker read "into ⌄" with the branch name missing entirely.
            Text("into \(base)")
                .font(.system(size: OreTheme.Font.body))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose the branch to merge into")
    }

    private func presentOrPerform() {
        guard !model.isGitOpInFlight(workspace.id) else { return }
        switch action {
        case .commit:
            // No sheet, no questions: the current tab's agent stages and
            // commits everything with real messages. The message editor
            // remains reachable through the button's context menu.
            model.commitWithAgent(in: workspace.id)
        case .createPullRequest:
            // Same default flow for shipping: commit what's left, push, open
            // the PR against the chosen base — one click, zero prompts.
            model.shipWithAgent(in: workspace.id, base: chosenBase)
        case .merge:
            editor = .merge
        default:
            perform()
        }
    }

    private var isThisActionBusy: Bool {
        switch (action, model.gitOp(for: workspace.id)) {
        case (.merged, .continueAfterMerge),
             (.createPullRequest, .createPullRequest),
             (.merge, .merge):
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private func gitEditor(_ kind: GitEditor) -> some View {
        switch kind {
        case .commit:
            CommitEditor(workspace: workspace) { editor = nil }
        case .pullRequest:
            PullRequestEditor(
                workspace: workspace,
                base: chosenBase ?? defaultPRBase,
                isStacked: isStackedPR
            ) { editor = nil }
        case .merge:
            MergeEditor(workspace: workspace) { editor = nil }
        }
    }

    private var defaultPRBase: String {
        if case .createPullRequest(let base, _) = action { return base }
        return workspace.baseBranch
    }

    private var isStackedPR: Bool {
        if case .createPullRequest(_, let stacked) = action { return stacked }
        return workspace.stackedOn != nil
    }

    private func perform() {
        if case .createPullRequest(let defaultBase, _) = action {
            model.performSuggestedGitAction(for: workspace, baseOverride: chosenBase ?? defaultBase)
        } else {
            model.performSuggestedGitAction(for: workspace)
        }
    }
}

private struct CommitEditor: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceSummary
    var onDone: () -> Void
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commit").font(.headline)
            TextEditor(text: $message)
                .font(.body)
                .frame(width: 340, height: 110)
            HStack {
                Button("Ask agent") {
                    onDone()
                    model.placePromptInComposer(GitShipPrompt.commit(), in: workspace.id)
                }
                Spacer()
                Button("Commit") {
                    model.submitCommit(message: message, for: workspace)
                    onDone()
                }
                .keyboardShortcut(.return)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
    }
}

private struct PullRequestEditor: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceSummary
    let base: String
    let isStacked: Bool
    var onDone: () -> Void
    @State private var title = ""
    @State private var prBody = ""
    @State private var draft = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Create pull request").font(.headline)
            TextField("Title", text: $title)
            Text("onto \(base)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $prBody)
                .font(.body)
                .frame(width: 360, height: 120)
            Toggle("Draft", isOn: $draft)
            HStack {
                Button("Ask agent") {
                    onDone()
                    model.placePromptInComposer(
                        GitShipPrompt.pullRequest(base: base, isStacked: isStacked),
                        in: workspace.id
                    )
                }
                Spacer()
                Button("Create") {
                    model.submitPullRequest(
                        title: title.isEmpty ? workspace.name : title,
                        body: prBody,
                        base: base,
                        draft: draft,
                        for: workspace
                    )
                    onDone()
                }
                .keyboardShortcut(.return)
                .disabled(model.isGitOpInFlight(workspace.id))
            }
        }
        .padding(14)
        .onAppear { title = workspace.name }
    }
}

private struct MergeEditor: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceSummary
    var onDone: () -> Void
    @AppStorage("ore.mergeMethod") private var method = "squash"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Merge pull request").font(.headline)
            Picker("Method", selection: $method) {
                Text("Squash").tag("squash")
                Text("Merge commit").tag("merge")
                Text("Rebase").tag("rebase")
            }
            .pickerStyle(.radioGroup)
            HStack {
                Spacer()
                Button("Merge") {
                    model.submitMerge(method: method, for: workspace)
                    onDone()
                }
                .keyboardShortcut(.return)
                .disabled(model.isGitOpInFlight(workspace.id))
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}

private struct GitBusyLabel: View {
    let title: String
    let systemImage: String
    var isBusy: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: systemImage)
            }
            Text(title)
        }
    }
}

/// Origin's default branch moved: pull the local ref, or rebase this branch,
/// without sending the user to GitHub.
private struct BaseSyncBanner: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceSummary

    var body: some View {
        if let prompt {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: OreTheme.Space.sm) {
                    Image(systemName: prompt.icon)
                        .foregroundStyle(prompt.tone)
                        .frame(width: 16)
                    Text(prompt.title)
                        .font(.system(size: OreTheme.Font.body, weight: .semibold))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                Text(prompt.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)

                HStack(spacing: OreTheme.Space.sm) {
                    Spacer(minLength: 24)
                    if prompt.showPull {
                        Button {
                            model.pullDefaultBranch(workspace.id)
                        } label: {
                            if model.gitOp(for: workspace.id) == .pullDefaultBranch {
                                ProgressView().controlSize(.mini)
                            } else {
                                Text("Pull \(prompt.defaultBranch)")
                            }
                        }
                        .buttonStyle(OreSecondaryButtonStyle())
                        .disabled(model.isGitOpInFlight(workspace.id))
                    }
                    if prompt.showRebase {
                        Button("Rebase with agent") {
                            model.placePromptInComposer(
                                GitShipPrompt.rebaseOnto(prompt.defaultBranch),
                                in: workspace.id
                            )
                        }
                        .buttonStyle(OrePrimaryButtonStyle())
                    }
                }
            }
            .padding(12)
            .background(
                prompt.tone.opacity(0.10),
                in: RoundedRectangle(cornerRadius: OreTheme.controlRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: OreTheme.controlRadius)
                    .stroke(prompt.tone.opacity(0.35), lineWidth: 1)
            }
            .padding(.horizontal, OreTheme.Space.sm)
            .padding(.vertical, OreTheme.Space.xs)
        }
    }

    private var prompt: Prompt? {
        guard let sync = workspace.baseSync, sync.needsAttention else { return nil }
        if case .merged = model.gitAction(for: workspace.id) { return nil }
        return Prompt(sync: sync)
    }

    private struct Prompt {
        var defaultBranch: String
        var title: String
        var detail: String
        var icon: String
        var tone: Color
        var showPull: Bool
        var showRebase: Bool

        init(sync: BaseSyncStatus) {
            defaultBranch = sync.defaultBranch
            showPull = sync.localDefaultBehindOrigin > 0
            showRebase = sync.workspaceBehindOrigin > 0
            if sync.wouldConflict {
                icon = "exclamationmark.triangle.fill"
                tone = OreTheme.warning
                title = "This branch conflicts with origin/\(sync.defaultBranch)"
                detail = Self.conflictDetail(sync)
            } else if sync.workspaceBehindOrigin > 0 {
                icon = "arrow.down.circle"
                tone = Color.accentColor
                title = "origin/\(sync.defaultBranch) moved"
                detail = "\(sync.workspaceBehindOrigin) commit\(sync.workspaceBehindOrigin == 1 ? "" : "s") behind · Rebase in ORE to update this branch."
            } else {
                icon = "arrow.down.circle"
                tone = Color.accentColor
                title = "Local \(sync.defaultBranch) is behind origin"
                detail = "\(sync.localDefaultBehindOrigin) commit\(sync.localDefaultBehindOrigin == 1 ? "" : "s") to pull so Continue and new workspaces start from current \(sync.defaultBranch)."
            }
        }

        private static func conflictDetail(_ sync: BaseSyncStatus) -> String {
            var parts: [String] = []
            if sync.workspaceBehindOrigin > 0 {
                parts.append(
                    "\(sync.workspaceBehindOrigin) commit\(sync.workspaceBehindOrigin == 1 ? "" : "s") on origin/\(sync.defaultBranch) are not in this branch."
                )
            }
            if sync.localDefaultBehindOrigin > 0 {
                parts.append("Local \(sync.defaultBranch) is also behind; pull it first.")
            }
            parts.append("Ask the agent to rebase so you don't have to leave ORE.")
            return parts.joined(separator: " ")
        }
    }
}

