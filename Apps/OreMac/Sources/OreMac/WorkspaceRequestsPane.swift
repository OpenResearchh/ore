import OreProtocol
import SwiftUI

struct WorkspaceRequestsPane: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceSummary
    @State private var durationMinutes = 15
    @State private var isEnabling = false
    @State private var autoApprovalError: String?

    private var groups: [AppModel.WorkspacePermissionGroup] {
        model.workspacePermissionGroups(for: workspace.id)
    }

    private var approvableCount: Int {
        groups.reduce(0) { count, group in
            count + group.requests.filter(WorkspacePermissionPolicy.isToolRequest).count
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        // Claiming attention with an empty list below reads as a
                        // bug. The heading states what the pane *is* until
                        // something actually wants the reader.
                        Text(groups.isEmpty ? "Requests" : "Needs your attention")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Across all tabs in this workspace")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    // A dimmed button still advertises an action; with nothing
                    // approvable there is none to advertise.
                    if approvableCount > 0 {
                        Button("Approve all (\(approvableCount))") {
                            model.approveWorkspaceRequests(for: workspace.id)
                        }
                        .buttonStyle(OreSecondaryButtonStyle())
                        .help("Approve the current tool requests across this workspace. Questions and plans stay pending.")
                    }
                }
                autoApprovalControl
            }
            .padding(10)
            Divider()

            if groups.isEmpty {
                // Sits just under the header rather than centred in the whole
                // pane: the document column is full height whatever it shows,
                // and dead-centre put "All caught up" hundreds of points away
                // from the thing it is the answer to. The header already says
                // this covers every tab, so the line repeating it is gone.
                VStack(spacing: 9) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("All caught up")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.top, 36)
                .padding(.horizontal, 20)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 7) {
                                Button {
                                    model.reveal(workspaceID: workspace.id, chatID: group.chat.id)
                                } label: {
                                    HStack(spacing: 6) {
                                        HarnessMark(harness: group.chat.harness, size: 15)
                                        Text(group.chat.title).lineLimit(1)
                                        Text("\(group.pendingCount)")
                                            .foregroundStyle(.secondary)
                                        Spacer(minLength: 0)
                                        Image(systemName: "arrow.up.forward")
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.system(size: 12, weight: .medium))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Open this chat")
                                ForEach(group.requests, id: \.id) { request in
                                    WorkspaceRequestCard(request: request, harness: group.chat.harness) { decision in
                                        model.resolvePermission(
                                            request.id, decision: decision,
                                            for: workspace.id, chatID: group.chat.id
                                        )
                                    } onOpenChat: {
                                        model.reveal(workspaceID: workspace.id, chatID: group.chat.id)
                                    }
                                }
                                ForEach(group.questions, id: \.id) { question in
                                    conversationCard("Question", detail: question.prompt, icon: "bubble.left", chatID: group.chat.id)
                                }
                                if group.hasPlan {
                                    conversationCard("Plan ready for review", detail: "Read the plan, request changes, or approve it in chat.", icon: "list.bullet.clipboard", chatID: group.chat.id)
                                }
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
    }

    private func conversationCard(_ title: String, detail: String, icon: String, chatID: ChatID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Review in chat") { model.reveal(workspaceID: workspace.id, chatID: chatID) }
                .buttonStyle(OreSecondaryButtonStyle())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OreTheme.subduedFill, in: RoundedRectangle(cornerRadius: 10))
    }

    private var autoApprovalControl: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let grant = model.workspaceAutoApprovals[workspace.id]
            let isActive = grant.map { context.date < $0.expiresAt } ?? false
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: isActive ? "bolt.shield.fill" : "bolt.shield")
                        .foregroundStyle(isActive ? Color.orange : .secondary)
                    Text("Auto-approve")
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 8)
                    Toggle("Auto-approve", isOn: Binding(
                        get: { isActive },
                        set: { enabled in
                            autoApprovalError = nil
                            if enabled {
                                isEnabling = true
                                Task { @MainActor in
                                    let enabled = await model.enableWorkspaceAutoApproval(
                                        for: workspace.id, minutes: durationMinutes
                                    )
                                    isEnabling = false
                                    if !enabled { autoApprovalError = "Auto-approve wasn’t enabled." }
                                }
                            } else {
                                model.disableWorkspaceAutoApproval(for: workspace.id)
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(isEnabling)
                }
                if isEnabling {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Waiting for authentication…").font(.caption2)
                    }
                } else if isActive, let grant {
                    HStack {
                        Text("Time remaining")
                        Spacer()
                        Text(Self.remainingTime(until: grant.expiresAt, now: context.date))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    HStack {
                        Text("Duration").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Picker("Duration", selection: $durationMinutes) {
                            ForEach([5, 15, 30, 60], id: \.self) { minutes in
                                Text(minutes == 60 ? "1 hour" : "\(minutes) minutes").tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                }
                Text("Approves current and new tool requests in every tab here while ORE is open. Questions and plans still need you.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let autoApprovalError {
                    Text(autoApprovalError).font(.caption2).foregroundStyle(.red)
                }
            }
            .padding(9)
            .background(isActive ? Color.orange.opacity(0.08) : OreTheme.subduedFill, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private static func remainingTime(until deadline: Date, now: Date) -> String {
        let seconds = max(0, Int(ceil(deadline.timeIntervalSince(now))))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct WorkspaceRequestCard: View {
    let request: PermissionRequest
    let harness: HarnessKind
    let onDecision: (PermissionDecision) -> Void
    let onOpenChat: () -> Void
    @State private var isExpanded = true
    @State private var isEditing = false
    @State private var editedText = ""

    private var content: PermissionPresentation { PermissionPresentation(request: request) }
    private var isTool: Bool { WorkspacePermissionPolicy.isToolRequest(request) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: isTool ? "hand.raised" : "bubble.left")
                        .foregroundStyle(.orange)
                    Text(content.action)
                        .font(.system(size: 12, weight: .semibold))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                if let target = content.target {
                    Text(target)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let detail = content.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Input details") {
                    Text(WorkspacePermissionPolicy.inputText(request.input))
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                if isTool {
                    HStack(spacing: 6) {
                        Button("Approve") { onDecision(.allow) }
                            .buttonStyle(OrePrimaryButtonStyle())
                        Button("Deny") { onDecision(.deny(reason: "Denied from workspace Requests.")) }
                            .buttonStyle(OreSecondaryButtonStyle())
                        Spacer(minLength: 0)
                        if WorkspacePermissionPolicy.canEdit(request, harness: harness) {
                            Button {
                                editedText = request.toolName == "Bash"
                                    ? request.input["command"]?.stringValue ?? ""
                                    : WorkspacePermissionPolicy.inputText(request.input)
                                isEditing = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit and approve")
                            .help("Edit the input before approving")
                        }
                    }
                    if !content.grants.isEmpty {
                        Menu("Approval options") {
                            ForEach(Array(content.grants.enumerated()), id: \.offset) { _, grant in
                                Button(grant.full) { onDecision(.allowWithSuggestion(grant.raw)) }
                            }
                        }
                        .font(.caption)
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                } else {
                    Button("Review in chat", action: onOpenChat)
                        .buttonStyle(OreSecondaryButtonStyle())
                }
            }
        }
        .padding(10)
        .background(OreTheme.subduedFill, in: RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $isEditing) { editSheet }
    }

    private var replacementInput: JSONValue? {
        if request.toolName == "Bash" {
            guard !editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  var fields = request.input.objectValue else { return nil }
            fields["command"] = .string(editedText)
            return .object(fields)
        }
        return WorkspacePermissionPolicy.editedInput(editedText)
    }

    private var editSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit and approve").font(.headline)
            Text(request.toolName == "Bash" ? "The agent will run this command." : "Edit the tool’s input as a JSON object.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $editedText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
            if replacementInput == nil {
                Text(request.toolName == "Bash" ? "Enter a command." : "Enter a valid JSON object.")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { isEditing = false }
                    .buttonStyle(OreSecondaryButtonStyle())
                Button("Approve edited request") {
                    guard let replacementInput else { return }
                    isEditing = false
                    onDecision(.allow(updatedInput: replacementInput))
                }
                .buttonStyle(OrePrimaryButtonStyle())
                .disabled(replacementInput == nil)
            }
        }
        .padding(20)
        .frame(width: 480, height: 330)
    }
}
