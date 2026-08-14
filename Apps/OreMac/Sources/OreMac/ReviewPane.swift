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
    let workspace: WorkspaceSummary

    @State private var diffs: [FileDiff] = []
    @State private var gitAction: SuggestedGitAction = .none
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
    @AppStorage("ore.review.changesLayout") private var changesLayoutRaw = "tree"

    private enum ReviewTab: Hashable { case allFiles, changes }
    private var isTreeLayout: Bool { changesLayoutRaw != "list" }

    var body: some View {
        VStack(spacing: 0) {
            tabRow
            Rectangle().fill(OreTheme.hairline).frame(height: 1)
            content
                .frame(maxHeight: .infinity)
            Rectangle().fill(OreTheme.hairline).frame(height: 1)
            GitActionBar(action: gitAction, workspace: workspace) {
                await refresh()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: workspace.id) {
            knownDiffFolders = []
            expandedDiffFolders = []
            // Paint the last-known diff for this workspace immediately — a warm
            // cache makes the switch feel instant, and it never lingers on the
            // previously selected workspace's changes. Only a cold cache falls
            // back to the loading spinner.
            seedFromCache()
            hasLoadedOnce = model.cachedDiff(for: workspace.id) != nil
            await refresh()
        }
        // Silent catch-up: the agent writing files should grow this list in
        // place, not flash a spinner over it.
        .task(id: workspace.gitStatus.generation) { await refresh() }
    }

    /// Show the cached diff for this workspace at once, or clear whatever diff
    /// was carried over from the previously selected workspace.
    private func seedFromCache() {
        if let cached = model.cachedDiff(for: workspace.id) {
            diffs = cached.diffs
            gitAction = cached.gitAction
            knownDiffFolders = DiffTreeNode.folderPaths(in: DiffTreeNode.build(from: cached.diffs))
        } else {
            diffs = []
            gitAction = .none
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
                    Image(systemName: "sparkles")
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
            .fixedSize(horizontal: true, vertical: false)
            .help("Open a dedicated agent review of the current diff")
        }
        .padding(.horizontal, OreTheme.Space.sm)
        .frame(height: OreTheme.RowHeight.bar)
        .background(.bar)
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
            .background(.bar)

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
            }
        }
        .background(.ultraThinMaterial)
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
        model.chat(for: workspace.id).draftComments
    }

    private func startAIReview() {
        model.createChat(
            in: workspace.id,
            initialMessage: "Review the current workspace diff. Look for correctness, security, tests, and maintainability. Use the ORE diff and review-comment tools, then report findings with file and line references."
        )
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
                Text("\(diffs.count) file\(diffs.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Spacer()
                changesLayoutToggle
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
                if isTreeLayout {
                    ForEach(visibleDiffTree) { item in
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
                    ForEach(diffs, id: \.path) { file in
                        fileRow(file, showFolder: true)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .background(.ultraThinMaterial)
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

            HStack(spacing: 0) {
                if showFolder {
                    let prefix = (file.path as NSString).deletingLastPathComponent
                    if !prefix.isEmpty {
                        Text(prefix + "/")
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .layoutPriority(0)
                    }
                }
                Text((file.path as NSString).lastPathComponent)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .font(.system(size: OreTheme.Font.body))
            .strikethrough(viewedPaths.contains(file.path), color: .secondary)

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

            Button { toggleViewed(file.path) } label: {
                Image(systemName: viewedPaths.contains(file.path) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(viewedPaths.contains(file.path) ? Color.accentColor : .secondary)
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
            Button(viewedPaths.contains(file.path) ? "Mark as Not Viewed" : "Mark as Viewed") {
                toggleViewed(file.path)
            }
        }
    }

    private var diffTree: [DiffTreeNode] {
        DiffTreeNode.build(from: diffs)
    }

    private var visibleDiffTree: [VisibleDiffTreeNode] {
        var result: [VisibleDiffTreeNode] = []
        func append(_ nodes: [DiffTreeNode], depth: Int) {
            for node in nodes {
                result.append(VisibleDiffTreeNode(node: node, depth: depth))
                if node.file == nil, expandedDiffFolders.contains(node.path) {
                    append(node.children ?? [], depth: depth + 1)
                }
            }
        }
        append(diffTree, depth: 0)
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
        let showLoader = !hasLoadedOnce && diffs.isEmpty
        if showLoader { isLoading = true }
        if fileTree.isEmpty { isLoadingFiles = true }
        defer {
            isLoading = false
            isLoadingFiles = false
            hasLoadedOnce = true
        }
        async let files = model.workspaceFiles(for: workspace)
        do {
            // Load through the shared cache so the diff we just read also warms
            // the next switch back to this workspace.
            let snapshot = try await model.refreshDiff(for: workspace)
            let loaded = snapshot.diffs
            let stored = await model.loadViewedFiles(for: workspace.id)
            diffs = loaded
            gitAction = snapshot.gitAction
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
        }
        fileTree = await files
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
    @State private var mode: FilePresentationMode = .diff
    @State private var isSaving = false

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

            if mode == .source {
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
                    Button("Open Source") { setMode(.source) }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: path) { await load() }
        .task(id: workspace.gitStatus.generation) { await load() }
        .onChange(of: model.fileFocus[workspace.id]?[path]) { _, focus in
            // A `file:line` click on an already-open file must show source, not
            // the diff, so the line reveal lands somewhere visible.
            if focus != nil { mode = .source }
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
                Text("Source").tag(FilePresentationMode.source)
                if file != nil { Text("Diff").tag(FilePresentationMode.diff) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: file == nil ? 78 : 140)

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

    @ViewBuilder
    private var sourceEditor: some View {
        if isLoading && sourceText.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let sourceError {
            ContentUnavailableView(
                "Can’t open this file",
                systemImage: "doc.badge.ellipsis",
                description: Text(sourceError)
            )
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
                    Text("Binary file").foregroundStyle(.secondary).padding()
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
        async let loadedSource = try? model.fileContents(path: path, in: workspace)
        let diffs = (try? await model.loadDiff(for: workspace.id)) ?? []
        file = diffs.first { $0.path == path }
        if let text = await loadedSource {
            sourceText = text
            savedSourceText = text
            sourceError = nil
        } else {
            sourceError = "ORE can only edit UTF-8 text files smaller than 2 MB."
        }
        let requested = model.filePresentationModes[workspace.id]?[path] ?? .diff
        mode = file == nil ? .source : requested
        let stored = await model.loadViewedFiles(for: workspace.id)
        if let file { isViewed = stored[path] == contentHash(file) }
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

/// The single most prominent control in the app: the next step to ship this
/// work, whatever that currently is.
private struct GitActionBar: View {
    @Environment(AppModel.self) private var model
    let action: SuggestedGitAction
    let workspace: WorkspaceSummary
    let onRefresh: () async -> Void

    @State private var chosenBase: String?
    @State private var branches: [String] = []
    @State private var prURL: String?

    /// True for states that only exist once a PR has been opened, so we only
    /// spend a `gh` call to fetch its URL when there's actually one to show.
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
        bar
        .padding(.horizontal, OreTheme.Space.md)
        .frame(height: 42)
        .background(.bar)
        .task(id: "\(workspace.id.rawValue)-\(action.title)-\(workspace.gitStatus.generation)") {
            if case .createPullRequest = action {
                branches = await model.remoteBranches(for: workspace.id)
            }
            prURL = actionImpliesPR ? await model.pullRequestURL(for: workspace.id) : nil
        }
    }

    private var bar: some View {
        Group {
            if action.isActionable {
                HStack(spacing: OreTheme.Space.sm) {
                    refreshButton
                    Spacer(minLength: 0)
                }
            } else {
                // Keep controls in the leading cluster. HSplitView may retain
                // a wider child than the clipped on-screen slice while the
                // window is compact; trailing alignment would hide the actions.
                HStack(spacing: OreTheme.Space.sm) {
                    Image(systemName: icon).foregroundStyle(.secondary)
                    Text(action.title)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    refreshButton
                }
            }
        }
    }

    private var refreshButton: some View {
        HStack(spacing: OreTheme.Space.sm) {
            if case .createPullRequest(let defaultBase, _) = action {
                baseMenu(defaultBase: defaultBase)
            }
            if action.isActionable {
                Button(action.title) { perform() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if let prURL, let url = URL(string: prURL) {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("View on GitHub", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
                .help("Open this pull request on GitHub")
            }
            Button { Task { await onRefresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Refresh repository status")
        }
    }

    /// The PR base-branch chooser, shown only while about to open a PR. Defaults
    /// to the workspace's base and lists the repo's remote branches.
    private func baseMenu(defaultBase: String) -> some View {
        let base = chosenBase ?? defaultBase
        return Menu {
            Button("\(defaultBase) (default)") { chosenBase = defaultBase }
            if !branches.isEmpty { Divider() }
            ForEach(branches.filter { $0 != workspace.branch }, id: \.self) { branch in
                Button(branch) { chosenBase = branch }
            }
        } label: {
            HStack(spacing: 4) {
                Text("into").foregroundStyle(.secondary)
                Text(base).fontWeight(.medium)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
            }
            .font(.system(size: OreTheme.Font.body))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose the branch to merge into")
    }

    private var icon: String {
        switch action {
        case .none: return "checkmark.circle"
        case .committedNoRemote: return "checkmark.circle.badge.questionmark"
        case .createGitHubRepo: return "plus.rectangle.on.folder"
        case .commit: return "square.and.arrow.down"
        case .push: return "arrow.up.circle"
        case .createPullRequest: return "arrow.triangle.pull"
        case .waitForChecks: return "clock"
        case .fixFailingChecks: return "xmark.octagon"
        case .resolveConflicts: return "arrow.triangle.branch"
        case .waitForReview: return "person.2"
        case .merge: return "arrow.triangle.merge"
        case .waitForParentToMerge: return "square.stack.3d.up"
        case .retargetAfterParentMerged: return "arrow.uturn.right"
        case .merged: return "checkmark.seal.fill"
        case .setUpGitHub: return "gear"
        }
    }

    private func perform() {
        // Honour a chosen base branch when opening a PR; otherwise the action's
        // own default applies.
        if case .createPullRequest(let defaultBase, _) = action {
            model.createPullRequest(base: chosenBase ?? defaultBase, for: workspace)
        } else {
            model.performGitAction(action, for: workspace)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await onRefresh()
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
