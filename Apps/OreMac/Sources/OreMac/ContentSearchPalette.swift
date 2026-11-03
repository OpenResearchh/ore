import OreProtocol
import SwiftUI

/// ⌘⇧F: search file contents in the selected worktree.
struct ContentSearchPalette: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceSummary
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var hits: [WorkspaceContentHit] = []
    @State private var selection: String?
    @State private var isSearching = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            QuickPaletteDivider()
            results
            QuickPaletteDivider()
            QuickPaletteFooter(summary: summary)
        }
        .frame(width: 640, height: 500)
        .quickPaletteChrome()
        .onAppear { focused = true }
        .onChange(of: query) { _, next in
            scheduleSearch(next)
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search file contents", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .medium))
                .focused($focused)
                .onSubmit { openSelection() }
                .onKeyPress(.downArrow) {
                    moveSelection(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(-1)
                    return .handled
                }
            if isSearching {
                ProgressView().controlSize(.small)
            }
            QuickPaletteKeycap(text: "⇧⌘F")
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, OreTheme.Space.md)
        .frame(height: 58)
    }

    @ViewBuilder
    private var results: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            QuickPaletteEmptyState(
                icon: "doc.text.magnifyingglass",
                title: "Search inside this worktree",
                detail: "Case-insensitive by default. Opens the file at the matching line."
            )
        } else if hits.isEmpty, !isSearching {
            QuickPaletteEmptyState(
                icon: "doc.text.magnifyingglass",
                title: "No lines match “\(query)”",
                detail: "Try a symbol name, a string, or a path fragment."
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(hits) { hit in
                            QuickPaletteRow(
                                title: "\(hit.path):\(hit.line)",
                                detail: hit.text,
                                trailing: nil,
                                isSelected: selection == hit.id,
                                action: { open(hit) }
                            ) {
                                SourceFileIcon(path: hit.path, size: 17)
                                    .frame(width: 18)
                            }
                            .id(hit.id)
                        }
                    }
                    .padding(OreTheme.Space.sm)
                }
                .oreOverlayScrollers()
                .onChange(of: selection) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private var summary: String {
        if isSearching { return "Searching" }
        let count = hits.count
        return "\(count) match\(count == 1 ? "" : "es")"
    }

    private func scheduleSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hits = []
            selection = nil
            isSearching = false
            return
        }
        isSearching = true
        let worktree = workspace.worktreePath
        Task.detached(priority: .userInitiated) {
            let found = WorkspaceContentSearch.search(query: trimmed, in: worktree)
            await MainActor.run {
                guard self.query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
                hits = found
                selection = found.first?.id
                isSearching = false
            }
        }
    }

    private func openSelection() {
        guard let selection, let hit = hits.first(where: { $0.id == selection }) else { return }
        open(hit)
    }

    private func open(_ hit: WorkspaceContentHit) {
        model.openSourceFile(hit.path, in: workspace.id, line: hit.line)
        onDismiss()
    }

    private func moveSelection(_ offset: Int) {
        let ids = hits.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : 0)
        selection = ids[(index + offset + ids.count) % ids.count]
    }
}
