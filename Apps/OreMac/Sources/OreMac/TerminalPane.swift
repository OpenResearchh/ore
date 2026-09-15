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
        // Archiving calls this for workspaces that never opened a terminal;
        // removing absent keys would still notify every dock observing these.
        guard views[workspaceID] != nil || tabs[workspaceID] != nil
            || activeTabIDs[workspaceID] != nil || detectedURLs[workspaceID] != nil
        else { return }
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

    private var urlScanner = TerminalURLScanner()

    /// GPU rendering through SwiftTerm's Metal path. SwiftTerm's CoreGraphics
    /// renderer redraws the whole grid for every line scrolled, which competes
    /// with the rest of the window's scroll frames during a build or a log
    /// tail. The Metal path is still marked experimental upstream, so it stays
    /// off unless set with
    /// `defaults write <bundle id> ore.debug.terminalMetal -bool YES`.
    static let metalRendererRequested =
        UserDefaults.standard.bool(forKey: "ore.debug.terminalMetal")

    /// SwiftTerm's scroller, styled to match the rest of the window. It is a
    /// standalone `NSScroller`, not part of an `NSScrollView`, so AppKit never
    /// fades it the way it fades every other overlay knob in ORE; the view
    /// does that itself below.
    private weak var styledScroller: NSScroller?
    private var lastScrollPosition: Double = 0
    private var lastScrollActivity: CFTimeInterval = 0
    private var scrollerFadeScheduled = false
    /// How long the knob stays after the last movement, roughly what AppKit
    /// gives its own overlay scrollers.
    private static let scrollerIdleDelay: CFTimeInterval = 1.0

    func configureAppearance() {
        // Match the app's own text rendering rather than SwiftTerm's default,
        // so the terminal doesn't look pasted in.
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        // ORE is dark-only — `OreMacApp` sets `.preferredColorScheme(.dark)`.
        // That is a SwiftUI environment value, though, and it does not reach an
        // NSView's effective appearance. `.textBackgroundColor` and
        // `.labelColor` are *dynamic*: SwiftTerm resolves them once, here, at
        // assignment — before this view is in a window — so they resolved
        // against the system appearance instead of the app's. On a Mac set to
        // Light that painted a white terminal with black text inside ORE's
        // dark chrome, which is what it looked like: a blank white panel.
        appearance = NSAppearance(named: .darkAqua)
        let dark = NSAppearance(named: .darkAqua) ?? effectiveAppearance
        dark.performAsCurrentDrawingAppearance {
            nativeBackgroundColor = .textBackgroundColor
            nativeForegroundColor = .labelColor
        }

        // The light knob is what every other scroll view in the window uses —
        // the window is always dark. It starts hidden and appears only while
        // the scrollback moves. `alphaValue` rather than `isHidden`: SwiftTerm
        // stops reserving the scroller's width when it is hidden, which would
        // reflow every line each time the knob came and went.
        if let scroller = subviews.lazy.compactMap({ $0 as? NSScroller }).first {
            scroller.knobStyle = .light
            scroller.alphaValue = 0
            styledScroller = scroller
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftTerm wants a window before its Metal view is built, and rebinds
        // the renderer itself when the view later moves between windows, so
        // this only has to switch it on once. On failure it keeps drawing with
        // CoreGraphics, which is the right fallback.
        guard Self.metalRendererRequested, window != nil, !isUsingMetalRenderer else { return }
        try? setUseMetal(true)
    }

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        // Output arriving while the view is pinned to the bottom keeps the
        // position at 1, so a build log doesn't hold the knob on screen; only
        // real movement through the scrollback shows it.
        guard position != lastScrollPosition else { return }
        lastScrollPosition = position
        guard canScroll else { return }
        revealScroller()
    }

    // A wheel flick that lands on the first or the last line moves nothing, so
    // the knob stays hidden even though that is when the reader most wants it.
    // `TerminalView.scrollWheel` is `public override`, not `open`, so it can't
    // be hooked from here; any movement at all does reveal the knob, which
    // covers everything except a flick against an end stop.

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // A faded knob is invisible but still a view. Without this, a click
        // anywhere down the trailing edge grabs a scrollbar the user can't see
        // and jumps the scrollback; the terminal gets the click instead, the
        // way it does everywhere else in the pane. Once the knob is on screen
        // it takes its own clicks again, and a drag already in progress keeps
        // them regardless of what this returns.
        if let scroller = styledScroller, scroller.alphaValue < 0.05,
           hit === scroller || hit?.isDescendant(of: scroller) == true {
            return self
        }
        return hit
    }

    /// Runs on the main thread: `LocalProcessTerminalView.setup()` builds its
    /// `LocalProcess` with the default main queue and is internal to SwiftTerm,
    /// so the only way to move the read off main is to stop using this class
    /// and re-own the process, the window size and the termination wiring. That
    /// wouldn't buy the frame back anyway — the terminal's state is main-only,
    /// so `feed` has to hop straight back. What is worth doing is making the
    /// part ORE adds cost nothing; see `TerminalURLScanner`.
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        let urls = urlScanner.scan(slice)
        guard !urls.isEmpty else { return }
        // A turn later: recording a URL mutates observed registry state, which
        // shouldn't happen from inside SwiftTerm's feed.
        let deliver = onDetectedURL
        DispatchQueue.main.async { urls.forEach { deliver?($0) } }
    }

    private func revealScroller() {
        guard let scroller = styledScroller else { return }
        // SwiftTerm styles the scroller once; put the app's answer back in case
        // anything reset it since.
        if scroller.scrollerStyle != .overlay { scrollerStyle = .overlay }
        if scroller.knobStyle != .light { scroller.knobStyle = .light }

        lastScrollActivity = CACurrentMediaTime()
        if scroller.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                scroller.animator().alphaValue = 1
            }
        }
        scheduleScrollerFade(after: Self.scrollerIdleDelay)
    }

    /// One pending check rather than a fresh timer per scrolled line: when it
    /// fires early because the reader kept scrolling, it re-arms for the
    /// remainder.
    private func scheduleScrollerFade(after delay: CFTimeInterval) {
        guard !scrollerFadeScheduled else { return }
        scrollerFadeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.scrollerFadeScheduled = false
            let idle = CACurrentMediaTime() - self.lastScrollActivity
            // A held knob can sit still without the reader being done with it.
            if idle < Self.scrollerIdleDelay || NSEvent.pressedMouseButtons & 1 != 0 {
                self.scheduleScrollerFade(after: max(0.1, Self.scrollerIdleDelay - idle))
                return
            }
            guard let scroller = self.styledScroller else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                scroller.animator().alphaValue = 0
            }
        }
    }
}

/// Finds local server addresses in a terminal's output stream.
///
/// This runs on the main thread for every chunk SwiftTerm feeds, next to the
/// parser, so it has to cost close to nothing for output that holds no URL — a
/// build log, `seq`, a `yes` flood. Every match needs `://`, so a byte search
/// for that separator decides whether a chunk is decoded at all; only chunks
/// that contain one pay for a String and the regex.
///
/// Output arrives in arbitrary chunks, so a URL can be split across two of
/// them. A small carry of undecided bytes is kept so the match doesn't depend
/// on where the chunk boundary happened to fall, and it is trimmed after every
/// scan to just the part that could still become an address.
struct TerminalURLScanner {
    /// "https:/" — the longest run a chunk boundary can cut before its `://`
    /// is whole.
    static let schemeCarry = 7
    /// Bound on the carry: it exists to bridge a chunk boundary, not to hold
    /// the session's output.
    static let carryLimit = 2048
    /// How close to the end an unmatched `://` must be to still be the start
    /// of an address. The host follows the separator directly, and the
    /// longest one with a port ("0.0.0.0:65535") fits well inside this.
    static let openCandidateWindow = 32

    private(set) var carry: [UInt8] = []

    private static let colon = UInt8(ascii: ":")
    private static let slash = UInt8(ascii: "/")

    private static let urlExpression = try? NSRegularExpression(
        pattern: #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(?::\d+)?(?:/[^\s"'<>]*)?"#,
        options: [.caseInsensitive]
    )

    /// Feeds one chunk of output and returns the addresses it completed.
    mutating func scan(_ chunk: ArraySlice<UInt8>) -> [URL] {
        guard !chunk.isEmpty else { return [] }

        // The separator can be whole in the chunk, already in the carry (an
        // address left open last time), or cut across the boundary between
        // them. None of the three is the common case, and it costs a memchr.
        guard Self.firstSeparator(in: carry[...]) != nil
            || Self.separatorSpans(carry, chunk)
            || Self.firstSeparator(in: chunk) != nil
        else {
            carry.append(contentsOf: chunk.suffix(Self.schemeCarry))
            if carry.count > Self.schemeCarry {
                carry.removeFirst(carry.count - Self.schemeCarry)
            }
            return []
        }

        var buffer = carry
        buffer.append(contentsOf: chunk)
        carry.removeAll(keepingCapacity: true)
        guard let expression = Self.urlExpression,
              let separator = Self.firstSeparator(in: buffer[...])
        else { return [] }

        // Nothing before the first separator's scheme can belong to a match.
        let text = String(decoding: buffer[max(0, separator - 5)...], as: UTF8.self)

        var urls: [URL] = []
        var resolved = text.startIndex
        var openMatchStart: String.Index?
        let range = NSRange(text.startIndex..., in: text)
        for match in expression.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            // A match touching the end may be truncated — so may one that
            // stops at a trailing ":" whose port hasn't arrived. Wait for more
            // output.
            let rest = text[matchRange.upperBound...]
            if rest.isEmpty || rest == ":" {
                openMatchStart = matchRange.lowerBound
                break
            }
            if let url = URL(string: Self.stripped(String(text[matchRange]))) {
                urls.append(url)
            }
            resolved = matchRange.upperBound
        }

        let tail: Substring.UTF8View
        if let openMatchStart {
            tail = text.utf8[openMatchStart...]
        } else if let candidate = text[resolved...].range(of: "://", options: .backwards),
                  text.utf8.distance(from: candidate.lowerBound, to: text.endIndex)
                    <= Self.openCandidateWindow {
            // An address whose host hasn't fully arrived ("http://localh").
            let schemeStart = text.utf8.index(candidate.lowerBound, offsetBy: -5, limitedBy: resolved)
                ?? resolved
            tail = text.utf8[schemeStart...]
        } else {
            tail = text.utf8[resolved...].suffix(Self.schemeCarry)
        }
        carry.append(contentsOf: tail.suffix(Self.carryLimit))
        return urls
    }

    /// Offset of the first `://` in `bytes`, relative to the slice's start.
    static func firstSeparator(in bytes: ArraySlice<UInt8>) -> Int? {
        bytes.withUnsafeBufferPointer { buffer -> Int? in
            guard buffer.count >= 3, let base = buffer.baseAddress else { return nil }
            var offset = 0
            while offset <= buffer.count - 3 {
                guard let hit = memchr(base + offset, Int32(colon), buffer.count - 2 - offset)
                else { return nil }
                let index = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
                if base[index + 1] == slash, base[index + 2] == slash { return index }
                offset = index + 1
            }
            return nil
        }
    }

    /// Whether a `://` starts at the end of `head` and finishes in `tail`.
    static func separatorSpans(_ head: [UInt8], _ tail: ArraySlice<UInt8>) -> Bool {
        guard let last = head.last, let first = tail.first else { return false }
        if last == colon {
            return first == slash && tail.dropFirst().first == slash
        }
        if last == slash, head.count >= 2, head[head.count - 2] == colon {
            return first == slash
        }
        return false
    }

    /// Terminals wrap URLs in punctuation and escape sequences more often than
    /// not.
    static func stripped(_ text: String) -> String {
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
