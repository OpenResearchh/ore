import AppKit
import OreProtocol
import SwiftUI

/// ORE's menu bar presence: the fleet at a glance, pending approvals
/// answerable inline, and the assistant reachable — all of it alive whether
/// or not a window is open. Closing the last window parks ORE here instead
/// of quitting it (see `AppDelegate`), which is what turns the app into an
/// always-on assistant.
struct MenuBarDashboard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !model.assistantConfirmations.isEmpty {
                confirmations
                Divider()
            }
            if model.sortedWorkspaces.isEmpty {
                Text("No workspaces yet")
                    .foregroundStyle(.secondary)
                    .padding(OreTheme.Space.md)
            } else {
                workspaceList
            }
            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: OreTheme.Space.sm) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
            Text("ORE").font(.system(size: OreTheme.Font.body, weight: .semibold))
            Spacer()
            Text(voiceHint)
                .font(.system(size: OreTheme.Font.caption))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, OreTheme.Space.md)
        .frame(height: 34)
    }

    private var voiceHint: String {
        switch model.voiceAssistant.phase {
        case .listening, .answering: "Listening…"
        case .thinking: "Thinking…"
        case .idle: "Hold ⇧⌥ to talk"
        }
    }

    /// The assistant's pending approvals — answerable right here. "For this
    /// task" is the prominent one for the same reason it is everywhere else:
    /// the user asked for the work, so one yes should cover it.
    private var confirmations: some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.sm) {
            ForEach(model.assistantConfirmations) { confirmation in
                VStack(alignment: .leading, spacing: 6) {
                    Text(confirmation.summary)
                        .font(.system(size: OreTheme.Font.caption, weight: .medium))
                        .lineLimit(2)
                    HStack(spacing: OreTheme.Space.sm) {
                        Button("Deny") {
                            model.resolveAssistantConfirmation(confirmation.id, decision: .deny)
                        }
                        .controlSize(.small)
                        Spacer()
                        Button("Once") {
                            model.resolveAssistantConfirmation(
                                confirmation.id, decision: .allow(.once)
                            )
                        }
                        .controlSize(.small)
                        Button("This task") {
                            model.resolveAssistantConfirmation(
                                confirmation.id, decision: .allow(.task)
                            )
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(OreTheme.Space.sm)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(OreTheme.Space.sm)
    }

    private var workspaceList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.sortedWorkspaces.prefix(9)) { workspace in
                Button {
                    reveal(workspace)
                } label: {
                    HStack(spacing: OreTheme.Space.sm) {
                        Circle()
                            .fill(statusColor(for: workspace))
                            .frame(width: 7, height: 7)
                        Text(workspace.name)
                            .lineLimit(1)
                        Spacer()
                        Text(statusLabel(for: workspace))
                            .font(.system(size: OreTheme.Font.caption))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, OreTheme.Space.md)
                .frame(height: 26)
            }
        }
        .padding(.vertical, OreTheme.Space.xs)
    }

    private var footer: some View {
        HStack {
            Button("Open ORE") { openMain() }
            Spacer()
            Button("Assistant") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "assistant")
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
        .padding(OreTheme.Space.sm)
    }

    private func reveal(_ workspace: WorkspaceSummary) {
        model.selectedWorkspaceID = workspace.id
        openMain()
    }

    private func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }

    /// One dot, three truths: red needs you, accent is working, grey is idle.
    private func statusColor(for workspace: WorkspaceSummary) -> Color {
        if workspace.needsAttention { return .orange }
        switch workspace.status {
        case .requesting, .thinking, .runningTool: return .accentColor
        case .failed: return .red
        case .awaitingInput: return .orange
        case .idle, .interrupted: return Color.secondary.opacity(0.5)
        }
    }

    private func statusLabel(for workspace: WorkspaceSummary) -> String {
        if workspace.needsAttention, workspace.status != .awaitingInput { return "needs you" }
        switch workspace.status {
        case .requesting, .thinking: return "working"
        case .runningTool: return "running"
        case .awaitingInput: return "needs you"
        case .failed: return "failed"
        case .interrupted: return "stopped"
        case .idle: return ""
        }
    }
}
