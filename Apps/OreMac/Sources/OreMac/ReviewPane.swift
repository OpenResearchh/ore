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
    @State private var reviewSetup: ReviewSetup?
    @State private var reviewInstructions = ""
    @State private var reviewModel = ""
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

    private struct ReviewSetup: Identifiable {
        var id: String { "review-setup" }
    }

    private enum ReviewTab: Hashable { case allFiles, changes }
    private var isTreeLayout: Bool { changesLayoutRaw != "list" }

        var body: some View {
        VStack(spacing: 0) {
            tabRow
            Rectangle().fill(OreTheme.hairline).frame(height: 1)
            BaseSyncBanner(workspace: workspace)
            content
                .frame(maxHeight: .infinity)
            stackStrip
            // The panel owns workspace-specific async results in @State. Give
            // each workspace a distinct identity so checks from the previously
            // selected branch cannot remain visible while the new branch loads.
            ShipStatusPanel(workspace: workspace)
                .id(workspace.id)
        }
        // No fill of its own: the pane is cut from Liquid Glass where it is
        // laid out (`RootView.workspaceMain` clips it to the card radius and
        // applies `oreGlassSurface`). A material here as well would stack
        // glass on glass, which Apple's guidance is explicit about avoiding.
        .sheet(item: $reviewSetup) { _ in
            reviewSetupSheet
        }
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

    // File browsing and changes are destinations. Review is an action, so it is
    // a labelled button here instead of an empty destination.
    private var tabRow: some View {
        HStack(spacing: OreTheme.Space.xs) {
            segment("All files", count: nil, target: .allFiles)
            segment("Changes", count: diffs.count, target: .changes)

            Spacer(minLength: 2)

            if tab == .allFiles {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Button { startAIReview() } label: {
                HStack(spacing: 5) {
                    if model.chatCreationsInFlight.contains(workspace.id) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text("Review")
                    if !draftComments.isEmpty {
                        Text("\(draftComments.count)")
                            .font(.caption2.monospacedDigit())
                    }
                }
                .font(.system(size: OreTheme.Font.body, weight: .medium))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(OreTheme.subduedFill, in: Capsule())
                .overlay(Capsule().stroke(OreTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(OrePressableButtonStyle())
            .disabled(model.chatCreationsInFlight.contains(workspace.id))
            .fixedSize(horizontal: true, vertical: false)
            .help("Open a dedicated agent review of the current diff")
            .contextMenu {
                ForEach(reviewModelChoices) { choice in
                    Button(choice.displayName) { startAIReview(reviewerModel: choice.id) }
                }
                Divider()
                Button("Custom instructions…") {
                    reviewModel = ""
                    reviewSetup = ReviewSetup()
                }
            }
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
                        .foregroundStyle(.secondary)
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
                .scrollIndicators(.hidden)
                // List ignores the modifier above on macOS — see the probe.
                .background(OreListScrollerOverlay())
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

    private func startAIReview(reviewerModel: String? = nil, instructions: String? = nil) {
        var prompt = """
        Review the current workspace diff. Look for correctness, security, tests, and maintainability. \
        Use GetWorkspaceDiff and GetDiffComments, then post each finding with PostDiffComment \
        (filePath, startLine, endLine, body) so they land as numbered anchored comments — not as prose. \
        After posting, list the findings as "1. … 2. …" so the user can say "fix 2 and 4".
        """
        if let instructions, !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\nAdditional instructions:\n\(instructions)"
        }
        model.createChat(
            in: workspace.id,
            initialMessage: prompt,
            defaults: reviewDefaults,
            model: reviewerModel,
            isReview: true
        )
    }

    /// The agent and model the Review button opens with, from Settings.
    private var reviewDefaults: AppModel.ChatDefaults {
        model.reviewDefaults(for: workspace.id)
    }

    /// Models to offer for a one-off review, drawn from the agent the review
    /// will actually run on rather than the workspace's.
    private var reviewModelChoices: [AgentModel] {
        model.knownModels(for: reviewDefaults.harness ?? workspace.harness)
    }

    private var reviewSetupSheet: some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.md) {
            Text("Review with agent")
                .font(.system(size: 20, weight: .semibold))
            Picker("Model", selection: $reviewModel) {
                Text("Review default").tag("")
                ForEach(reviewModelChoices) { choice in
                    Text(choice.displayName).tag(choice.id)
                }
            }
            Text("Custom instructions")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $reviewInstructions)
                .font(.body)
                .frame(height: 120)
            HStack {
                Spacer()
                Button("Cancel") { reviewSetup = nil }
                    .buttonStyle(OreSecondaryButtonStyle())
                Button("Start review") {
                    startAIReview(
                        reviewerModel: reviewModel.isEmpty ? nil : reviewModel,
                        instructions: reviewInstructions
                    )
                    reviewSetup = nil
                }
                .buttonStyle(OrePrimaryButtonStyle())
            }
        }
        .padding(OreTheme.Space.lg)
        .frame(width: 480)
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

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack(spacing: OreTheme.Space.sm) {
                changesLayoutToggle
                diffScopeMenu
                Spacer()
                Text("\(viewedPaths.count)/\(diffs.count) viewed")
                    .foregroundStyle(.secondary)
                Text("+\(diffs.reduce(0) { $0 + $1.insertions })")
                    .foregroundStyle(OreTheme.added)
                Text("−\(diffs.reduce(0) { $0 + $1.deletions })")
                    .foregroundStyle(OreTheme.removed)
            }
            .font(.system(size: OreTheme.Font.caption).monospacedDigit())
            .padding(.horizontal, OreTheme.Space.sm)
            .frame(height: 28)

            Divider()

            List {
                if !conflictedDiffs.isEmpty {
                    Section {
                        ForEach(conflictedDiffs, id: \.path) { file in
                            fileRow(file, showFolder: true)
                        }
                    } header: {
                        changeSectionHeaderLabel("Conflicts", files: conflictedDiffs, tint: .orange)
                    }
                }
                if showsChangeBuckets {
                    ForEach(ChangeBucket.allCases.filter { !diffs(in: $0).isEmpty }) { bucket in
                        Section {
                            changeRows(for: diffs(in: bucket))
                        } header: {
                            changeSectionHeader(bucket, files: diffs(in: bucket))
                        }
                    }
                } else {
                    changeRows(for: diffs.filter { !conflictedPaths.contains($0.path) })
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            // List ignores the modifier above on macOS — see the probe.
            .background(OreListScrollerOverlay())
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

    private func fileRow(_ file: FileDiff, showFolder: Bool, depth: Int = 0) -> some View {
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

            if conflictedPaths.contains(file.path) {
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
            if conflictedPaths.contains(file.path) {
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

    private enum ChangeBucket: String, CaseIterable, Identifiable {
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

    private var unstagedPaths: Set<String> {
        Set((workingTree?.files ?? []).filter(\.isUnstaged).map(\.path))
    }

    private var stagedPaths: Set<String> {
        Set((workingTree?.files ?? []).filter(\.isStaged).map(\.path))
    }

    /// Staging already has a home on the Commits tab. Changes only splits into
    /// Unstaged / Staged / Committed when more than one of those is present —
    /// a lone "UNSTAGED" header just repeats the tab count and +/- totals.
    private var showsChangeBuckets: Bool {
        ChangeBucket.allCases.filter { !diffs(in: $0).isEmpty }.count > 1
    }

    private func bucket(for path: String) -> ChangeBucket {
        if unstagedPaths.contains(path) { return .unstaged }
        if stagedPaths.contains(path) { return .staged }
        return .committed
    }

    private var conflictedPaths: Set<String> {
        Set((workingTree?.files ?? []).filter { $0.status == .conflicted }.map(\.path))
    }

    private var conflictedDiffs: [FileDiff] {
        diffs.filter { conflictedPaths.contains($0.path) }
    }

    private func diffs(in bucket: ChangeBucket) -> [FileDiff] {
        diffs.filter { self.bucket(for: $0.path) == bucket && !conflictedPaths.contains($0.path) }
    }

    private func changeSectionHeader(_ bucket: ChangeBucket, files: [FileDiff]) -> some View {
        changeSectionHeaderLabel(bucket.title, files: files)
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
            viewedPaths = Set(loaded.compactMap { file in
                stored[file.path] == contentHash(file) ? file.path : nil
            })
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
        } else {
            viewedPaths.insert(path)
            let hash = diffs.first(where: { $0.path == path }).map(contentHash)
            model.markViewed(path, hash: hash, for: workspace.id)
        }
    }

    private func contentHash(_ file: FileDiff) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let text = file.hunks.flatMap(\.lines).map { "\($0.kind):\($0.text)" }.joined(separator: "\n")
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
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

/// Name of the diff document's scroll coordinate space, shared so a line row
/// can report its frame in the same space the drag-select gesture reads.
private let oreDiffSpaceName = "oreDiffDoc"

/// One diff line's on-screen rectangle, collected so a drag over the gutter can
/// map its y-position back to a specific line.
private struct LineFrame: Equatable {
    let ref: DiffDocumentView.LineRef
    let rect: CGRect
}

private struct LineFramesKey: PreferenceKey {
    static let defaultValue: [LineFrame] = []
    static func reduce(value: inout [LineFrame], nextValue: () -> [LineFrame]) {
        value.append(contentsOf: nextValue())
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

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        // Overlay, explicitly: with "always show scroll bars" set system-wide,
        // AppKit's legacy scroller paints an opaque track — a white ladder
        // bolted onto the glass. Every scroll surface in the window makes the
        // same choice so the bars read as one family.
        scroll.scrollerStyle = .overlay
        // One knob family window-wide — see TranscriptView.
        scroll.scrollerKnobStyle = .light
        scroll.autohidesScrollers = true
        return scroll
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastRendered: String?
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Re-render only when the text itself moved — updateNSView also fires
        // for unrelated SwiftUI churn, and markdown parsing isn't free.
        guard context.coordinator.lastRendered != markdown else { return }
        context.coordinator.lastRendered = markdown
        let rendered = MarkdownRenderer(
            baseFont: .systemFont(ofSize: OreTheme.Font.prose),
            textColor: .labelColor,
            highlighter: SyntaxHighlighter.shared
        ).render(markdown, highlighting: .all)
        textView.textStorage?.setAttributedString(rendered)
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
    @State private var lineFrames: [LineFrame] = []
    @State private var sourceText = ""
    @State private var savedSourceText = ""
    @State private var sourceError: String?
    /// A deleted document's last version, so its preview still has something
    /// to render.
    @State private var baseText: String?
    @State private var mode: FilePresentationMode = .diff
    @State private var isSaving = false
    @State private var conflictHunks: [ConflictHunk] = []

    struct LineRef: Equatable { var hunk: Int; var line: Int }

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
        // light is where translucency stops being worth it. Nearly opaque, with
        // just enough of the glass base bleeding through to stay in the same
        // window as everything else.
        .background(OreTheme.Surface.content.opacity(0.85))
        .task(id: path) { await load() }
        .task(id: model.gitGeneration(for: workspace.id)) { await load() }
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
                    model.markViewed(path, hash: viewed ? contentHash() : nil, for: workspace.id)
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
            .scrollIndicators(.hidden)
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
        // Indicators off here and on every glass-riding scroll surface — with
        // "always show scroll bars" set system-wide these drew the legacy
        // white track, one pane at a time.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(file.hunks.enumerated()), id: \.element.diffRowID) { hunkIndex, hunk in
                    HunkHeader(hunk: hunk)
                    ForEach(Array(hunk.lines.enumerated()), id: \.element.diffRowID) { lineIndex, line in
                        DiffLineRow(
                            line: line,
                            language: SyntaxHighlighter.language(forPath: file.path),
                            ref: LineRef(hunk: hunkIndex, line: lineIndex),
                            isSelected: isSelected(hunk: hunkIndex, line: lineIndex),
                            onComment: { commentSingle(line, in: hunk) }
                        )
                    }
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
            .padding(.vertical, 6)
            .coordinateSpace(name: oreDiffSpaceName)
            .onPreferenceChange(LineFramesKey.self) { lineFrames = $0 }
            .overlay(alignment: .topLeading) {
                // Drag within the gutter strip to select a line range. Confining
                // the gesture to the ~90pt gutter keeps it from fighting the
                // scroll view, which still owns vertical drags over the code.
                Color.clear
                    .frame(width: 90)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .named(oreDiffSpaceName))
                            .onChanged { value in
                                if let ref = lineAt(value.location.y) { updateSelection(to: ref) }
                            }
                            .onEnded { _ in commentSelection(in: file) }
                    )
            }
        }
        .scrollIndicators(.hidden)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
    }

    private func lineAt(_ y: CGFloat) -> LineRef? {
        lineFrames.first { $0.rect.minY <= y && y <= $0.rect.maxY }?.ref
    }

    // MARK: - Selection

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

    private func commentSingle(_ line: DiffLine, in hunk: DiffHunk) {
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

    private func load() async {
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
        file = diffs.first { $0.path == path }
        let isDeleted = file?.status == .deleted

        switch await sourceRead?.value {
        case .success(let text):
            sourceText = text
            savedSourceText = text
            sourceError = nil
        case .failure(let error):
            sourceError = Self.sourceErrorMessage(error, isDeleted: isDeleted)
        case nil:
            sourceError = nil
        }

        // A deleted document still has a preview: the version it had at the base.
        let previewKind = FilePresentationMode.previewKind(path: path)
        if isDeleted, sourceError != nil, previewKind == .markdown || previewKind == .html {
            let data = await model.baseFileData(path: file?.originalPath ?? path, in: workspace.id)
            baseText = data.flatMap { String(data: $0, encoding: .utf8) }
        } else {
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
        mode = resolved
        let stored = await model.loadViewedFiles(for: workspace.id)
        if let file { isViewed = stored[path] == contentHash(file) }
        conflictHunks = await model.loadConflictHunks(path: path, for: workspace.id)
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

    private func contentHash(_ explicit: FileDiff? = nil) -> String {
        guard let file = explicit ?? file else { return "" }
        var hash: UInt64 = 14_695_981_039_346_656_037
        let text = file.hunks.flatMap(\.lines).map { "\($0.kind):\($0.text)" }.joined(separator: "\n")
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
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

private struct HunkHeader: View {
    let hunk: DiffHunk

    var body: some View {
        Text("@@ −\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@ \(hunk.header)")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(OreTheme.subduedFill)
    }
}

private struct DiffLineRow: View {
    let line: DiffLine
    let language: String?
    let ref: DiffDocumentView.LineRef
    var isSelected: Bool = false
    let onComment: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldLineNumber.map(String.init) ?? "")
                .frame(width: 38, alignment: .trailing)
            Text(line.newLineNumber.map(String.init) ?? "")
                .frame(width: 38, alignment: .trailing)

            // Commenting is the point of this view, so the affordance lives in
            // the gutter, one click from any line — and it's always shown for a
            // selected range, which is where the "+" from the reference appears.
            Button(action: onComment) {
                Image(systemName: "plus.bubble")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .frame(width: 26, height: 26)
            .opacity(isHovering || isSelected ? 1 : 0)
            .disabled(line.kind == .noNewline)

            // Highlighted per line: a diff line is rarely a complete parse
            // unit, so this is the regex pass rather than tree-sitter, which
            // would report errors more often than colour.
            Text(AttributedString(highlighted))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(textColor)
        .padding(.vertical, 1.5)
        .background(isSelected ? Color.accentColor.opacity(0.20) : background)
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(Color.accentColor).frame(width: 2) }
        }
        .onHover { isHovering = $0 }
        .contentShape(Rectangle())
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: LineFramesKey.self,
                    value: [LineFrame(ref: ref, rect: geo.frame(in: .named(oreDiffSpaceName)))]
                )
            }
        )
    }

    private var highlighted: NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
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
        result.append(SyntaxHighlighter.shared.highlightLine(
            line.text, language: language, font: font
        ))
        return result
    }

    private var marker: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return " "
        case .noNewline: return "\\"
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .noNewline: return .secondary
        default: return .primary
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: return .green.opacity(0.13)
        case .removed: return .red.opacity(0.13)
        default: return .clear
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
                .scrollIndicators(.hidden)
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
                .scrollIndicators(.hidden)
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
                    .scrollIndicators(.hidden)
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
        pullRequest = pr

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

private extension DiffHunk {
    /// A hunk keeps its identity as long as it covers the same range. Keying the
    /// diff list on array offset instead let LazyVStack carry a previous hunk's
    /// cached height into whatever hunk now sits at that offset after a re-diff —
    /// the phantom vertical gaps.
    var diffRowID: String { "h\(oldStart)-\(oldCount)-\(newStart)-\(newCount)" }
}

private extension DiffLine {
    /// Stable within a hunk: every line has a distinct (old, new) pair —
    /// additions differ by new number, deletions by old, context by both — and
    /// `kind` disambiguates the rare no-newline markers.
    var diffRowID: String { "\(oldLineNumber ?? -1):\(newLineNumber ?? -1):\(kind.rawValue)" }
}
