import OrePersistence
import OreProtocol
import SwiftUI

/// The second conversation of the reference design's split layout: a slim
/// header (title + live presence), the shared transcript host, and a compact
/// composer — beside the main chat, never instead of it.
///
/// Deliberately lighter than `ChatPane`: no tab strip, no diff documents, no
/// voice, no attachment shelf. The main column keeps all of that; this one
/// exists so a second agent can be watched and answered without switching
/// tabs. Anything heavier and it stops being a glance and starts being a
/// second app.
struct SplitChatColumn: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceSummary
    let chatID: ChatID

    @State private var draft = ""
    @State private var expandedActivityGroups: Set<String> = []
    /// Its own anchor, deliberately — sharing the main pane's would make one
    /// column's "jump to latest" scroll the other.
    @State private var scrollAnchor = TranscriptScrollAnchor()
    @FocusState private var focused: Bool

    var body: some View {
        let state = model.chat(for: chatID)
        let summary = model.chats(for: workspace.id).first { $0.id == chatID }
        VStack(spacing: 0) {
            header(summary: summary, state: state)
            Rectangle().fill(OreTheme.hairline).frame(height: 1)
            if state.hasRows {
                TranscriptHost(
                    chat: state,
                    worktreePath: workspace.worktreePath,
                    agentName: summary?.harness.displayName ?? "Agent",
                    searchQuery: "",
                    persistenceKey: "split-\(chatID.rawValue)",
                    expandedActivityGroups: expandedActivityGroups,
                    canFork: false,
                    onRevert: { _ in },
                    onToggleActivity: { group in
                        if !expandedActivityGroups.insert(group).inserted {
                            expandedActivityGroups.remove(group)
                        }
                    },
                    // Files open in the main column's document tabs — the
                    // split stays a conversation.
                    onOpenFile: { model.openSourceFile($0, in: workspace.id) },
                    onTurnAction: { _, _ in },
                    scrollAnchor: scrollAnchor
                )
                .equatable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomTrailing) { jumpToLatest }
            } else {
                ContentUnavailableView(
                    summary?.title ?? "New chat",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("This conversation appears here as it happens.")
                )
                .frame(maxHeight: .infinity)
            }
            composer(summary: summary, state: state)
        }
        .onChange(of: chatID) { _, _ in
            expandedActivityGroups = []
            draft = ""
        }
    }

    /// The mock's per-pane header: who this is and whether they're doing
    /// something, with the one control the pane needs — closing it.
    private func header(summary: ChatSummary?, state: ChatState) -> some View {
        HStack(spacing: OreTheme.Space.sm) {
            if let summary {
                HarnessMark(harness: summary.harness, size: 14)
            }
            Text(summary?.title ?? "Chat")
                .font(.system(size: OreTheme.Font.body, weight: .semibold))
                .lineLimit(1)
            Text(presenceLine(summary: summary, state: state))
                .font(.system(size: OreTheme.Font.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: OreTheme.Space.sm)
            Button {
                model.closeSplitChat(in: workspace.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(OreTheme.glassControlFill, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close the split — the conversation stays in its tab")
        }
        .padding(.horizontal, OreTheme.Space.md)
        .frame(height: OreTheme.RowHeight.bar)
    }

    private func presenceLine(summary: ChatSummary?, state: ChatState) -> String {
        let name = summary?.harness.displayName ?? "Agent"
        guard state.status != .idle else { return "\(name) is idle" }
        return ComposerBusyCopy.label(
            harness: summary?.harness ?? .claudeCode,
            status: state.status,
            runningToolLabel: state.runningToolLabel,
            isStarting: false,
            lastEventAt: nil,
            now: Date()
        )
    }

    @ViewBuilder
    private var jumpToLatest: some View {
        if scrollAnchor.isAwayFromBottom {
            JumpToLatestButton { scrollAnchor.jumpToBottom() }
                .padding(.trailing, OreTheme.Space.md)
                .padding(.bottom, OreTheme.Space.sm)
                .transition(.opacity)
        }
    }

    private func composer(summary: ChatSummary?, state: ChatState) -> some View {
        let isEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            if state.isBusy {
                Button {
                    model.interrupt(workspace.id, chatID: chatID)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: OreTheme.Font.caption, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop this agent")
            }
            HStack(alignment: .bottom, spacing: OreTheme.Space.sm) {
                TextField(
                    "Message \(summary?.harness.displayName ?? "agent")…",
                    text: $draft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: OreTheme.Font.prose))
                .lineLimit(1...8)
                .focused($focused)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                // ⌥⌘↩ — plain ⌘↩ belongs to the main composer; two claimants
                // to one chord in one window and SwiftUI picks silently.
                .keyboardShortcut(.return, modifiers: [.command, .option])
                .disabled(isEmpty)
                .help("Send (⌥⌘↩)")
            }
            // The same glass surface as every composer, so this one is its own
            // busy indicator too.
            .oreComposerSurface(padding: 10, isBusy: state.isBusy)
        }
        .padding(.horizontal, OreTheme.Space.md)
        .padding(.vertical, 10)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        model.send(text, to: workspace.id, chatID: chatID)
    }
}
