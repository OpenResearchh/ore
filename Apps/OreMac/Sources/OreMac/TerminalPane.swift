import AppKit
import OreCore
import OreProtocol
import SwiftTerm
import SwiftUI

/// A real shell in the workspace's worktree.
///
/// Agents write code; people still need to run it. Without a terminal the loop
/// breaks at the most important moment — "does this actually work?" — and the
/// user leaves the app to answer it, losing the connection between the change
/// and the workspace it belongs to.
///
/// The terminal *view* is owned by a registry rather than by the SwiftUI
/// hierarchy. That is the whole design: SwiftUI destroys and rebuilds views as
/// the user navigates, and a terminal that dies when you glance at another
/// workspace is worse than no terminal. Keeping the view alive keeps its PTY,
/// its child process and its scrollback alive with it.
/// One terminal tab: a stable identity and a display title. The view itself
/// lives in the registry, not here, so it survives navigation.
struct TerminalTab: Identifiable, Hashable {
    let id: UUID
    var title: String
}

@MainActor
@Observable
final class TerminalRegistry {
    static let shared = TerminalRegistry()

    private var views: [WorkspaceID: [UUID: OreTerminalView]] = [:]
    /// Tab order and titles, per workspace. Observed, so opening or closing a
    /// tab updates the dock's strip.
    private(set) var tabs: [WorkspaceID: [TerminalTab]] = [:]
    /// Which tab is showing, per workspace. Held here rather than in the pane's
    /// `@State` so the collapsed dock can list the open terminals and switch to
    /// one directly — the pane is not in the hierarchy to be asked.
    private(set) var activeTabIDs: [WorkspaceID: UUID] = [:]
    /// Localhost URLs seen in output, per workspace.
    private(set) var detectedURLs: [WorkspaceID: [URL]] = [:]

    func activeTab(for workspaceID: WorkspaceID) -> UUID? {
        let open = tabs[workspaceID] ?? []
        if let id = activeTabIDs[workspaceID], open.contains(where: { $0.id == id }) { return id }
        return open.first?.id
    }

    func selectTab(_ tabID: UUID, for workspaceID: WorkspaceID) {
        activeTabIDs[workspaceID] = tabID
    }

    /// Ensures a workspace has at least one terminal, returning its tabs. Called
    /// off the view-update path (from `.task`) so seeding never mutates state
    /// mid-render.
    @discardableResult
    func ensureTabs(for workspaceID: WorkspaceID, workingDirectory: String) -> [TerminalTab] {
        if tabs[workspaceID]?.isEmpty ?? true {
            _ = addTab(for: workspaceID, workingDirectory: workingDirectory)
        }
        return tabs[workspaceID] ?? []
    }

    @discardableResult
    func addTab(for workspaceID: WorkspaceID, workingDirectory: String) -> TerminalTab {
        let index = (tabs[workspaceID]?.count ?? 0) + 1
        let tab = TerminalTab(id: UUID(), title: "Terminal \(index)")
        tabs[workspaceID, default: []].append(tab)
        _ = view(for: tab.id, workspaceID: workspaceID, workingDirectory: workingDirectory)
        activeTabIDs[workspaceID] = tab.id
        return tab
    }

    func view(
        for tabID: UUID,
        workspaceID: WorkspaceID,
        workingDirectory: String
    ) -> OreTerminalView {
        if let existing = views[workspaceID]?[tabID] { return existing }

        let terminal = OreTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        terminal.configureAppearance()
        terminal.onDetectedURL = { [weak self] url in
            self?.recordURL(url, for: workspaceID)
        }

        // A login shell, so the user's aliases, prompt and version managers are
        // all present — the same environment their own terminal has. zsh is the
        // fallback rather than sh because this only ever runs on macOS, where
        // it is both present and the system default.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        terminal.startProcess(
            executable: shell,
            args: ["-l"],
            environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"),
            currentDirectory: workingDirectory
        )
        views[workspaceID, default: [:]][tabID] = terminal
        return terminal
    }

    func closeTab(_ tabID: UUID, for workspaceID: WorkspaceID) {
        let next = TabCloseSelection.replacement(
            closing: tabID,
            active: activeTabIDs[workspaceID],
            open: (tabs[workspaceID] ?? []).map(\.id)
        )
        views[workspaceID]?.removeValue(forKey: tabID)?.terminate()
        tabs[workspaceID]?.removeAll { $0.id == tabID }
        if activeTabIDs[workspaceID] == tabID {
            activeTabIDs[workspaceID] = next
        }
    }

    /// Sends a command to a workspace's first terminal (creating it if needed),
    /// as if the user typed it, so it lands in shell history.
    func run(_ command: String, in workspaceID: WorkspaceID, workingDirectory: String) {
        let tab = ensureTabs(for: workspaceID, workingDirectory: workingDirectory).first!
        view(for: tab.id, workspaceID: workspaceID, workingDirectory: workingDirectory)
            .send(txt: command + "\n")
    }

    func closeTerminal(for workspaceID: WorkspaceID) {
        views[workspaceID]?.values.forEach { $0.terminate() }
        views.removeValue(forKey: workspaceID)
        tabs.removeValue(forKey: workspaceID)
        activeTabIDs.removeValue(forKey: workspaceID)
        detectedURLs.removeValue(forKey: workspaceID)
    }

    func closeAll() {
        // Iterating `views.keys` directly while `closeTerminal` mutates the
        // dictionary skipped entries; a snapshot closes every workspace, and
        // `tabs` is included so a workspace whose views were never realised
        // still gets its bookkeeping cleared.
        for id in Set(views.keys).union(tabs.keys) { closeTerminal(for: id) }
    }

    private func recordURL(_ url: URL, for workspaceID: WorkspaceID) {
        var existing = detectedURLs[workspaceID] ?? []
        guard !existing.contains(url) else { return }
        // Only the last few are useful; a dev server that restarts a dozen
        // times shouldn't fill the bar.
        existing.append(url)
        if existing.count > 4 { existing.removeFirst(existing.count - 4) }
        detectedURLs[workspaceID] = existing
    }
}

/// A terminal that also watches its own output for a local server address.
///
/// A dev server prints its URL once, in a scroll of build noise, and the user
/// then hunts for it. Catching it as it goes past turns that into a button.
final class OreTerminalView: LocalProcessTerminalView {
    var onDetectedURL: ((URL) -> Void)?

    /// Output arrives in arbitrary chunks, so a URL can be split across two of
    /// them. A small trailing buffer is kept so the match doesn't depend on
    /// where the chunk boundary happened to fall.
    private var pendingText = ""

    private static let urlExpression = try? NSRegularExpression(
        pattern: #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(?::\d+)?(?:/[^\s"'<>]*)?"#,
        options: [.caseInsensitive]
    )

    func configureAppearance() {
        // Match the app's own text rendering rather than SwiftTerm's default,
        // so the terminal doesn't look pasted in.
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        nativeBackgroundColor = .textBackgroundColor
        nativeForegroundColor = .labelColor
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        scanForURLs(in: slice)
    }

    private func scanForURLs(in slice: ArraySlice<UInt8>) {
        guard let expression = Self.urlExpression else { return }

        pendingText += String(decoding: slice, as: UTF8.self)
        // Bound the buffer: it exists to bridge a chunk boundary, not to hold
        // the session's output.
        if pendingText.count > 4096 {
            pendingText = String(pendingText.suffix(2048))
        }

        let range = NSRange(pendingText.startIndex..., in: pendingText)
        var lastMatchEnd = pendingText.startIndex

        for match in expression.matches(in: pendingText, range: range) {
            guard let matchRange = Range(match.range, in: pendingText) else { continue }
            // A match touching the end may be truncated; wait for more output.
            if matchRange.upperBound == pendingText.endIndex { break }

            let text = String(pendingText[matchRange])
            if let url = URL(string: stripped(text)) {
                let deliver = onDetectedURL
                DispatchQueue.main.async { deliver?(url) }
            }
            lastMatchEnd = matchRange.upperBound
        }

        if lastMatchEnd > pendingText.startIndex {
            pendingText = String(pendingText[lastMatchEnd...])
        }
    }

    /// Terminals wrap URLs in punctuation and escape sequences more often than
    /// not.
    private func stripped(_ text: String) -> String {
        var result = text
        while let last = result.last, ".,;:)]}\"'".contains(last) {
            result.removeLast()
        }
        return result
    }
}

/// Hosts the workspace's terminal, without owning it.
struct TerminalPane: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceSummary
    var onCollapse: () -> Void = {}

    @State private var environment: InProcessCoreClient.WorkspaceEnvironment?
    @State private var hoveredTabID: UUID?

    private var registry: TerminalRegistry { .shared }
    private var activeTabID: UUID? { registry.activeTab(for: workspace.id) }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Rectangle().fill(OreTheme.hairline).frame(height: 1)

            if let environment, let activeTabID {
                TerminalViewRepresentable(
                    tabID: activeTabID,
                    workspaceID: workspace.id,
                    workingDirectory: environment.worktreePath
                )
                // Swap the hosted terminal view when the active tab changes;
                // each one is kept alive by the registry, so scrollback and its
                // process survive the switch.
                .id(activeTabID)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: workspace.id) {
            let env = await model.workspaceEnvironment(for: workspace.id)
            environment = env
            guard let env else { return }
            registry.ensureTabs(for: workspace.id, workingDirectory: env.worktreePath)
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            Button { onCollapse() } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 28, height: OreTheme.RowHeight.bar)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide the terminal (⌥⌘T)")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: OreTheme.Space.xs) {
                    ForEach(registry.tabs[workspace.id] ?? []) { tab in
                        terminalTabLabel(tab)
                    }
                    Button { addTerminal() } label: {
                        Image(systemName: "plus")
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New terminal")
                }
                .padding(.horizontal, OreTheme.Space.xs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingControls
                .padding(.trailing, OreTheme.Space.sm)
        }
        .frame(height: OreTheme.RowHeight.bar)
        .background(.bar)
    }

    private func terminalTabLabel(_ tab: TerminalTab) -> some View {
        let isSelected = activeTabID == tab.id
        return Button { registry.selectTab(tab.id, for: workspace.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: OreTheme.Font.body))
                    .foregroundStyle(.secondary)
                Text(tab.title)
                    .font(.system(size: OreTheme.Font.body, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                if (registry.tabs[workspace.id]?.count ?? 0) > 1 {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .opacity(hoveredTabID == tab.id || isSelected ? 1 : 0)
                        .contentShape(Rectangle())
                        .onTapGesture { closeTerminal(tab) }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                isSelected ? OreTheme.selectedFill
                    : hoveredTabID == tab.id ? OreTheme.subduedFill : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(OrePressableButtonStyle())
        .foregroundStyle(isSelected ? .primary : .secondary)
        .onHover { hovering in
            if hovering { hoveredTabID = tab.id }
            else if hoveredTabID == tab.id { hoveredTabID = nil }
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        // Any localhost URL the running process announced.
        ForEach(registry.detectedURLs[workspace.id] ?? [], id: \.self) { url in
            Button { NSWorkspace.shared.open(url) } label: {
                Label(url.port.map { ":\($0)" } ?? url.host() ?? "open", systemImage: "safari")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help(url.absoluteString)
        }

        if let script = environment?.runScript {
            Button { runScript(script) } label: {
                Label("Run", systemImage: "play.fill").font(.system(size: OreTheme.Font.body))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: .command)
            .help("Run `\(script)` (⌘R)")
        }
    }

    private func addTerminal() {
        guard let environment else { return }
        registry.addTab(for: workspace.id, workingDirectory: environment.worktreePath)
    }

    private func closeTerminal(_ tab: TerminalTab) {
        registry.closeTab(tab.id, for: workspace.id)
    }

    private func runScript(_ script: String) {
        guard let environment else { return }
        registry.run(script, in: workspace.id, workingDirectory: environment.worktreePath)
    }
}

private struct TerminalViewRepresentable: NSViewRepresentable {
    let tabID: UUID
    let workspaceID: WorkspaceID
    let workingDirectory: String

    func makeNSView(context: Context) -> NSView {
        // The registry hands back the same view for a tab every time, which is
        // what keeps the PTY and its scrollback alive across navigation.
        TerminalRegistry.shared.view(
            for: tabID, workspaceID: workspaceID, workingDirectory: workingDirectory
        )
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
