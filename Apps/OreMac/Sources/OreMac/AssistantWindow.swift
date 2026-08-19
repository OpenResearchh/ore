import OrePersistence
import OreProtocol
import SwiftUI

/// The Assistant's activity window: the one surface where the hidden
/// assistant workspace is visible.
///
/// Deliberately not a `ChatPane` — there is no diff, no git action, no tab
/// bar. What the user needs here is an auditable record (what did it do, what
/// does it remember) and a composer to talk to it with until voice mode
/// arrives.
struct AssistantActivityView: View {
    @Environment(AppModel.self) private var model

    private enum Tab: String, CaseIterable {
        case activity = "Activity"
        case actions = "Actions"
        case memory = "Memory"
    }

    @State private var tab: Tab = .activity
    @State private var draft = ""
    @State private var expandedActivityGroups: Set<String> = []
    @State private var memo = TranscriptDisplay.Memo()
    @FocusState private var composerFocused: Bool

    var body: some View {
        Group {
            if let assistant = model.assistantWorkspace, let chatID = model.assistantChatID {
                content(assistant: assistant, chatID: chatID)
            } else {
                ContentUnavailableView(
                    "The assistant is starting up",
                    systemImage: "sparkles",
                    description: Text("Its workspace appears here once ORE finishes loading.")
                )
            }
        }
        .frame(minWidth: 440, minHeight: 480)
    }

    private func content(assistant: WorkspaceSummary, chatID: ChatID) -> some View {
        let state = model.chat(for: chatID)
        return VStack(spacing: 0) {
            header(state: state)
            Divider()
            switch tab {
            case .activity:
                activity(assistant: assistant, chatID: chatID, state: state)
            case .actions:
                AssistantAuditView()
            case .memory:
                AssistantMemoryView(homePath: assistant.worktreePath)
            }
        }
    }

    private func header(state: ChatState) -> some View {
        HStack(spacing: OreTheme.Space.md) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
            Text("Assistant")
                .font(.system(size: OreTheme.Font.body, weight: .semibold))
            if state.status != .idle {
                Text(state.status.rawValue)
                    .font(.system(size: OreTheme.Font.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
        }
        .padding(.horizontal, OreTheme.Space.md)
        .frame(height: OreTheme.RowHeight.bar)
    }

    private func activity(
        assistant: WorkspaceSummary,
        chatID: ChatID,
        state: ChatState
    ) -> some View {
        VStack(spacing: 0) {
            if state.hasRows {
                TranscriptView(
                    rows: TranscriptDisplay.rows(
                        from: state.rows,
                        isBusy: state.isBusy,
                        expanded: expandedActivityGroups,
                        memo: memo,
                        hidingPlanTurnID: nil,
                        revision: state.rowsRevision
                    ),
                    isBusy: state.isBusy,
                    worktreePath: assistant.worktreePath,
                    persistenceKey: "assistant-\(chatID.rawValue)",
                    onRevert: { _ in },
                    onToggleActivity: { group in
                        if !expandedActivityGroups.insert(group).inserted {
                            expandedActivityGroups.remove(group)
                        }
                    },
                    onOpenFile: { _ in }
                )
            } else {
                ContentUnavailableView(
                    "Ask about your work",
                    systemImage: "sparkles",
                    description: Text(
                        "Try “what's happening across my workspaces?” — everything "
                        + "the assistant does and remembers is auditable here."
                    )
                )
                .frame(maxHeight: .infinity)
            }

            ForEach(model.assistantConfirmations) { confirmation in
                confirmationCard(confirmation)
            }
            if let permission = state.pendingPermission {
                permissionCard(permission, workspaceID: assistant.id)
            }
            if let question = state.pendingQuestion {
                questionCard(question, workspaceID: assistant.id)
            }

            Divider()
            composer(assistant: assistant)
        }
    }

    /// The assistant wants to do something consequential. "Allow for this
    /// task" is the default-prominent choice: a user who asked for the work
    /// shouldn't be re-asked for every step of it.
    private func confirmationCard(_ confirmation: AssistantConfirmation) -> some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.sm) {
            HStack(spacing: OreTheme.Space.sm) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                Text(confirmation.summary).fontWeight(.medium)
                Spacer()
            }
            HStack(spacing: OreTheme.Space.sm) {
                Button("Deny") {
                    model.resolveAssistantConfirmation(confirmation.id, decision: .deny)
                }
                Spacer()
                Button("Once") {
                    model.resolveAssistantConfirmation(
                        confirmation.id, decision: .allow(.once)
                    )
                }
                Button("Allow for this task") {
                    model.resolveAssistantConfirmation(
                        confirmation.id, decision: .allow(.task)
                    )
                }
                .buttonStyle(.borderedProminent)
                Button("Always") {
                    model.resolveAssistantConfirmation(
                        confirmation.id, decision: .allow(.always)
                    )
                }
                .help("Never ask about \(confirmation.actionClass.displayName.lowercased()) again")
            }
        }
        .padding(OreTheme.Space.md)
        .background(Color.accentColor.opacity(0.07))
    }

    private func permissionCard(
        _ permission: PermissionRequest,
        workspaceID: WorkspaceID
    ) -> some View {
        HStack(spacing: OreTheme.Space.md) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.toolName).fontWeight(.medium)
                if let summary = permission.summary {
                    Text(summary)
                        .font(.system(size: OreTheme.Font.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button("Deny") {
                model.resolvePermission(
                    permission.id,
                    decision: .deny(reason: "The user denied this in ORE."),
                    for: workspaceID
                )
            }
            Button("Allow") {
                model.resolvePermission(permission.id, decision: .allow, for: workspaceID)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(OreTheme.Space.md)
        .background(Color.orange.opacity(0.06))
    }

    private func questionCard(
        _ question: AgentQuestion,
        workspaceID: WorkspaceID
    ) -> some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.sm) {
            Text(question.prompt).fontWeight(.medium)
            HStack {
                ForEach(question.options, id: \.label) { option in
                    Button(option.label) {
                        model.answerQuestion(
                            question.id, answer: option.label, for: workspaceID
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(OreTheme.Space.md)
        .background(Color.accentColor.opacity(0.06))
    }

    private func composer(assistant: WorkspaceSummary) -> some View {
        HStack(spacing: OreTheme.Space.sm) {
            TextField("Ask across all your projects…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($composerFocused)
                .onSubmit(sendDraft)
            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(
                        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.secondary
                            : Color.accentColor
                    )
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(OreTheme.Space.md)
        .task { composerFocused = true }
    }

    private func sendDraft() {
        guard let assistant = model.assistantWorkspace else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        model.send(text, to: assistant.id)
    }
}

/// Every action the assistant has taken (or been refused), newest first.
/// Trust in an agent that acts for you is built on being able to check.
private struct AssistantAuditView: View {
    @Environment(AppModel.self) private var model
    @State private var actions: [AssistantActionRecord] = []

    var body: some View {
        Group {
            if actions.isEmpty {
                ContentUnavailableView(
                    "No actions yet",
                    systemImage: "checklist",
                    description: Text("Everything the assistant does on your behalf is recorded here.")
                )
            } else {
                List(actions, id: \.id) { action in
                    HStack(alignment: .top, spacing: OreTheme.Space.md) {
                        Image(systemName: symbol(for: action.decision))
                            .foregroundStyle(tint(for: action.decision))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.summary)
                            Text(decisionLabel(action.decision))
                                .font(.system(size: OreTheme.Font.caption))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(action.createdAt.formatted(.relative(presentation: .named)))
                            .font(.system(size: OreTheme.Font.caption))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .task { actions = await model.assistantAuditActions() }
        // A confirmation resolving means a row just landed.
        .onChange(of: model.assistantConfirmations.count) { _, _ in
            Task { actions = await model.assistantAuditActions() }
        }
    }

    private func symbol(for decision: String) -> String {
        if decision == "denied" || decision == "timedOut" { return "xmark.circle" }
        if decision == "failed" { return "exclamationmark.triangle" }
        return "checkmark.circle"
    }

    private func tint(for decision: String) -> Color {
        if decision == "denied" || decision == "timedOut" { return .secondary }
        if decision == "failed" { return .orange }
        return .green
    }

    private func decisionLabel(_ decision: String) -> String {
        switch decision {
        case "auto": "Ran automatically"
        case "allowed:once": "You allowed it"
        case "allowed:task", "granted:task": "Covered by a task approval"
        case "allowed:always", "granted:always": "Always allowed"
        case "denied": "You declined"
        case "timedOut": "Timed out unanswered"
        case "failed": "Failed"
        default: decision
        }
    }
}

/// Read-only view of the assistant's memory files. The assistant writes them;
/// the user audits them. Editing belongs in a conversation ("forget that"),
/// not a text editor racing the agent.
private struct AssistantMemoryView: View {
    let homePath: String

    private struct MemoryFile: Identifiable {
        let id: String
        let name: String
        let url: URL
    }

    @State private var files: [MemoryFile] = []
    @State private var selectedID: String?
    @State private var contents = ""

    var body: some View {
        HSplitView {
            List(files, selection: $selectedID) { file in
                Label(file.name, systemImage: "doc.text")
                    .tag(file.id)
            }
            .frame(minWidth: 150, idealWidth: 180, maxWidth: 240)

            ScrollView {
                Text(contents.isEmpty ? "Empty." : contents)
                    .font(.system(size: OreTheme.Font.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(OreTheme.Space.md)
            }
        }
        .task { load() }
        .onChange(of: selectedID) { _, _ in loadSelection() }
    }

    private func load() {
        let home = URL(fileURLWithPath: homePath)
        var found: [MemoryFile] = [MemoryFile(
            id: "MEMORY.md",
            name: "MEMORY.md",
            url: home.appendingPathComponent("MEMORY.md")
        )]
        let memoryDirectory = home.appendingPathComponent("memory", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: memoryDirectory, includingPropertiesForKeys: nil
        )) ?? []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension == "md" {
            found.append(MemoryFile(
                id: "memory/\(url.lastPathComponent)",
                name: url.lastPathComponent,
                url: url
            ))
        }
        files = found
        if selectedID == nil { selectedID = found.first?.id }
        loadSelection()
    }

    private func loadSelection() {
        guard let file = files.first(where: { $0.id == selectedID }) else {
            contents = ""
            return
        }
        contents = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
    }
}
