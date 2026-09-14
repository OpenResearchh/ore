import AppKit
import OreProtocol
import SwiftUI

/// The one thing the fleet most wants from the user right now, resolved from
/// workspace summaries alone. Ordered by urgency: blocked beats failed beats
/// unread beats uncommitted. Internal so tests can pin the ladder.
enum FleetSuggestionResolver {
    struct Suggestion: Equatable {
        var id: String
        var icon: String
        var title: String
        var workspaceID: WorkspaceID
        var startsCommitAgent = false
    }

    static func resolve(_ workspaces: [WorkspaceSummary]) -> Suggestion? {
        let active = workspaces.filter { !$0.isArchived }
        if let workspace = active.first(where: { $0.status == .awaitingInput }) {
            return Suggestion(
                id: "needs-you", icon: "exclamationmark.circle",
                title: "\(workspace.name) is waiting on you",
                workspaceID: workspace.id
            )
        }
        if let workspace = active.first(where: { $0.status == .failed }) {
            return Suggestion(
                id: "failed", icon: "xmark.octagon",
                title: "\(workspace.name) hit an error — take a look",
                workspaceID: workspace.id
            )
        }
        if let workspace = active.first(where: { $0.hasUnread && $0.status == .idle }) {
            return Suggestion(
                id: "catch-up", icon: "checkmark.circle",
                title: "Catch up on \(workspace.name)",
                workspaceID: workspace.id
            )
        }
        if let workspace = active.first(where: {
            $0.status == .idle && $0.gitStatus.hasUncommittedChanges
        }) {
            return Suggestion(
                id: "commit", icon: "tray.and.arrow.down",
                title: "Commit \(workspace.name)'s changes",
                workspaceID: workspace.id,
                startsCommitAgent: true
            )
        }
        return nil
    }
}

/// ORE's menu bar presence: the fleet at a glance, pending approvals
/// answerable inline, and the assistant reachable — all of it alive whether
/// or not a window is open. Closing the last window parks ORE here instead
/// of quitting it (see `AppDelegate`), which is what turns the app into an
/// always-on assistant.
struct MenuBarDashboard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var questionDrafts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let suggestion = FleetSuggestionResolver.resolve(model.sortedWorkspaces.map { workspace in
                var copy = workspace
                copy.gitStatus = model.gitChrome(for: workspace.id)
                return copy
            }) {
                fleetSuggestionRow(suggestion)
                Divider()
            }
            if !model.assistantConfirmations.isEmpty {
                confirmations
                Divider()
            }
            if !model.tabNeedsYou.isEmpty {
                tabNeedsYou
                Divider()
            }
            if model.sortedWorkspaces.isEmpty {
                Text("No workspaces yet")
                    .foregroundStyle(.secondary)
                    .padding(OreTheme.Space.md)
            } else {
                if controlActiveState == .inactive {
                    // The menu's window is closed (or at least not in use):
                    // a static list, no timer. Opening it flips the state and
                    // brings the timeline back with a fresh date.
                    workspaceList(at: Date())
                } else {
                    // Only the ten-minute "recently finished" window ages on
                    // this clock; model changes re-render on their own.
                    TimelineView(.periodic(from: Date(), by: 60)) { context in
                        workspaceList(at: context.date)
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: OreTheme.Space.sm) {
            OreAppIcon(size: 18)
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
        case .armed: "Armed — release keys"
        case .listening, .answering: "Listening…"
        case .thinking: "Thinking…"
        case .speaking: "Speaking…"
        case .idle: "Hold ⇧⌥, then release"
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

    private var tabNeedsYou: some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.sm) {
            ForEach(model.tabNeedsYou) { item in
                Group {
                    switch item {
                    case .permission:
                        permissionCard(item)
                    case .question(let payload):
                        questionCard(item, payload: payload)
                    case .plan(let payload):
                        planCard(item, payload: payload)
                    }
                }
                .padding(OreTheme.Space.sm)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(OreTheme.Space.sm)
    }

    private func permissionCard(_ item: TabNeedsYou) -> some View {
        // `headline` clips to 80 characters and takes two lines here, so a
        // long or multi-line command is only partly on screen. Allow and
        // Always are withdrawn in that case — the menu bar has nowhere to
        // put the rest, and the rest is the part worth reading.
        let isAbbreviated: Bool = {
            guard case .permission(let payload) = item else { return false }
            return PermissionPresentation(request: payload.request).isAbbreviated
        }()
        return VStack(alignment: .leading, spacing: 6) {
            // `headline`, not `spokenSummary`: this card is read, and it sits
            // above an Allow button where the tool and its argument are the
            // whole point — see the note on both properties.
            Text(item.headline)
                .font(.system(size: OreTheme.Font.caption, weight: .medium))
                .lineLimit(2)
            HStack(spacing: OreTheme.Space.sm) {
                Button("Deny") { denyPermission(item) }
                    .controlSize(.small)
                Spacer()
                if isAbbreviated {
                    Button("Review…") { model.reveal(workspaceID: item.workspaceID, chatID: item.chatID) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .help("The full command doesn't fit here — open ORE to read it")
                } else {
                    Button("Allow") { allowPermission(item) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    Button("Always") { alwaysAllow(item) }
                        .controlSize(.small)
                }
            }
        }
    }

    private func questionCard(
        _ item: TabNeedsYou,
        payload: TabNeedsYou.Question
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(payload.question.prompt)
                .font(.system(size: OreTheme.Font.caption, weight: .medium))
                .lineLimit(3)
            if !payload.question.options.isEmpty {
                HStack(spacing: OreTheme.Space.xs) {
                    ForEach(payload.question.options, id: \.label) { option in
                        Button(option.label) {
                            answer(item, text: option.label)
                        }
                        .controlSize(.small)
                    }
                }
            }
            if payload.question.allowsFreeform {
                HStack(spacing: OreTheme.Space.xs) {
                    TextField("Your answer…", text: questionDraft(for: item.id))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submitQuestion(item) }
                    Button {
                        submitQuestion(item)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .disabled(questionText(for: item.id).isEmpty)
                }
            }
        }
    }

    private func planCard(_ item: TabNeedsYou, payload: TabNeedsYou.Plan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.headline)
                .font(.system(size: OreTheme.Font.caption, weight: .medium))
                .lineLimit(3)
            HStack(spacing: OreTheme.Space.sm) {
                Button("Reject") {
                    model.respondToPlan(
                        chatID: payload.chatID,
                        workspaceID: payload.workspaceID,
                        approve: false
                    )
                }
                .controlSize(.small)
                Spacer()
                Button("Approve") {
                    model.respondToPlan(
                        chatID: payload.chatID,
                        workspaceID: payload.workspaceID,
                        approve: true
                    )
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func allowPermission(_ item: TabNeedsYou) {
        if case .permission(let payload) = item {
            model.resolvePermission(
                payload.request.id, decision: .allow,
                for: payload.workspaceID, chatID: payload.chatID
            )
        }
    }

    private func denyPermission(_ item: TabNeedsYou) {
        if case .permission(let payload) = item {
            model.resolvePermission(
                payload.request.id,
                decision: .deny(reason: "The user denied this from the menu bar."),
                for: payload.workspaceID, chatID: payload.chatID
            )
        }
    }

    private func answer(_ item: TabNeedsYou, text: String) {
        guard case .question(let payload) = item else { return }
        model.answerQuestion(
            payload.question.id,
            answer: text,
            for: payload.workspaceID,
            chatID: payload.chatID
        )
        questionDrafts.removeValue(forKey: item.id)
    }

    private func submitQuestion(_ item: TabNeedsYou) {
        let text = questionText(for: item.id)
        guard !text.isEmpty else { return }
        answer(item, text: text)
    }

    private func questionDraft(for id: String) -> Binding<String> {
        Binding(
            get: { questionDrafts[id, default: ""] },
            set: { questionDrafts[id] = $0 }
        )
    }

    private func questionText(for id: String) -> String {
        questionDrafts[id, default: ""]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func alwaysAllow(_ item: TabNeedsYou) {
        guard case .permission(let payload) = item else { return }
        model.autoAllowTab(
            workspaceID: payload.workspaceID,
            chatID: payload.chatID,
            permissionID: payload.request.id
        )
    }

    @ViewBuilder
    private func workspaceList(at now: Date) -> some View {
        let visible = MenuBarWorkspaceVisibility.visible(
            model.sortedWorkspaces,
            needsYouWorkspaceIDs: Set(model.tabNeedsYou.map(\.workspaceID)),
            now: now
        )
        if visible.isEmpty {
            Text("No active agents")
                .font(.system(size: OreTheme.Font.caption))
                .foregroundStyle(.secondary)
                .padding(OreTheme.Space.md)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(visible.prefix(9)) { workspace in
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

    /// The fleet's one suggested next step, right under the header — the menu
    /// bar's version of the composer's suggestion ladder. Clicking acts:
    /// reveal the workspace, and for commit suggestions also ask its current
    /// tab's agent to commit.
    private func fleetSuggestionRow(_ suggestion: FleetSuggestionResolver.Suggestion) -> some View {
        Button {
            if let workspace = model.sortedWorkspaces.first(where: { $0.id == suggestion.workspaceID }) {
                if suggestion.startsCommitAgent {
                    model.commitWithAgent(in: workspace.id)
                }
                reveal(workspace)
            }
        } label: {
            HStack(spacing: OreTheme.Space.sm) {
                Image(systemName: suggestion.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                Text(suggestion.title)
                    .font(.system(size: OreTheme.Font.body, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, OreTheme.Space.md)
        .frame(height: 30)
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
        case .idle: return "finished"
        }
    }
}

/// The menu bar is an exception list, not a second sidebar. Finished agents
/// remain for a short handoff window; inert historical workspaces stay in the
/// main window where they do not compete with work happening now.
enum MenuBarWorkspaceVisibility {
    static let recentCompletionWindow: TimeInterval = 10 * 60

    static func visible(
        _ workspaces: [WorkspaceSummary],
        needsYouWorkspaceIDs: Set<WorkspaceID>,
        now: Date = Date()
    ) -> [WorkspaceSummary] {
        workspaces.filter {
            shouldShow($0, needsYouWorkspaceIDs: needsYouWorkspaceIDs, now: now)
        }
    }

    static func shouldShow(
        _ workspace: WorkspaceSummary,
        needsYouWorkspaceIDs: Set<WorkspaceID>,
        now: Date = Date()
    ) -> Bool {
        if needsYouWorkspaceIDs.contains(workspace.id) { return true }
        switch workspace.status {
        case .requesting, .thinking, .runningTool, .awaitingInput, .failed:
            return true
        case .idle:
            guard let lastActivity = workspace.lastActivity else { return false }
            let age = now.timeIntervalSince(lastActivity)
            return age >= 0 && age <= recentCompletionWindow
        case .interrupted:
            return false
        }
    }
}
