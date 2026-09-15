import OreProtocol
import SwiftUI

/// Morning inbox for Dream Mode. A dedicated window so it survives closing
/// the main workspace window, the same way the Assistant does.
struct DreamReviewWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: DreamFindingID?
    @State private var hideLowConfidence = true
    @State private var transcriptFinding: DreamFindingSummary?
    /// The grouped inbox, rebuilt only when the findings or the filter change.
    /// This body also re-runs for every run-progress update while a dream is
    /// under way, and used to re-group the whole inbox each time.
    @State private var inboxMemo = DreamInboxSections.Memo()

    var body: some View {
        NavigationSplitView {
            inbox
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
        } detail: {
            if let finding = selectedFinding {
                DreamFindingDetail(
                    finding: finding,
                    onAccept: { model.resolveDreamFinding(finding.id, .accept) },
                    onReject: { reason in
                        model.resolveDreamFinding(finding.id, .reject(reason))
                    },
                    onDefer: { deferral in
                        model.resolveDreamFinding(finding.id, .snooze(deferral))
                    },
                    onViewTranscript: { transcriptFinding = finding },
                    onOpenEvidence: { evidence in
                        model.revealDreamEvidence(evidence, for: finding)
                    }
                )
            } else {
                ContentUnavailableView(
                    "No finding selected",
                    systemImage: "moon.zzz",
                    description: Text("Dreams wait here until you review them.")
                )
            }
        }
        .navigationTitle("Dreams")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Dream now") { model.startDreamNow() }
            }
            if model.dreamInbox.run?.state == .dreaming {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Stop", role: .destructive) { model.abortDreamRun() }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                sleepBanner
                if let run = model.dreamInbox.run {
                    runHeader(run)
                }
            }
        }
        .sheet(item: $transcriptFinding) { finding in
            DreamTranscriptSheet(finding: finding)
                .environment(model)
                .frame(minWidth: 560, minHeight: 480)
        }
    }

    private var selectedFinding: DreamFindingSummary? {
        visibleFindings.first { $0.id == selectedID } ?? visibleFindings.first
    }

    private var sections: DreamInboxSections {
        inboxMemo.resolve(model.dreamInbox.findings, hideLowConfidence: hideLowConfidence)
    }

    private var visibleFindings: [DreamFindingSummary] { sections.visible }

    private var inbox: some View {
        List(selection: $selectedID) {
            Toggle("Hide low confidence", isOn: $hideLowConfidence)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(sections.days) { day in
                Section(day.start.formatted(date: .abbreviated, time: .omitted)) {
                    ForEach(day.projects) { project in
                        Section(project.name) {
                            ForEach(project.findings) { finding in
                                DreamFindingRow(finding: finding)
                                    .tag(finding.id)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .oreOverlayScrollers()
    }

    @ViewBuilder
    private var sleepBanner: some View {
        let status = model.dreamSleepStatus
        if let copy = Self.sleepCopy(status) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: copy.icon)
                Text(copy.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(copy.background)
        }
    }

    private func runHeader(_ run: DreamRunSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: run.state == .dreaming ? "moon.stars" : "moon.zzz")
            VStack(alignment: .leading, spacing: 2) {
                Text(run.state == .dreaming ? "Dreaming now" : "Last run · \(run.state.rawValue)")
                    .font(.caption.weight(.semibold))
                Text(run.why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if run.tokenBudget > 0 {
                Text("\(run.tokensUsed)/\(run.tokenBudget) tokens")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private static func sleepCopy(_ status: DreamSleepStatus) -> (icon: String, text: String, background: Color)? {
        switch status {
        case .macMaySleep:
            return (
                "exclamationmark.triangle",
                "Dreams only run while this Mac is awake. Overnight, it will probably sleep — turn on Keep awake on AC in Settings, or use Dream now.",
                Color.orange.opacity(0.12)
            )
        case .keepAwakePausedOnBattery:
            return (
                "battery.25",
                "Keep awake is paused on battery. Plug in to run overnight.",
                Color.orange.opacity(0.12)
            )
        case .keepAwakeActive:
            return (
                "bolt.fill",
                "ORE will keep this Mac awake while plugged in during quiet hours (display may still sleep).",
                Color.green.opacity(0.08)
            )
        case .opportunistic, .disabled:
            return nil
        }
    }
}

/// The inbox as the list draws it: findings the filter lets through, grouped
/// by day (newest first), then by project (A to Z), each group keeping the
/// inbox's own order.
struct DreamInboxSections: Equatable {
    struct Project: Equatable, Identifiable {
        let name: String
        let findings: [DreamFindingSummary]
        var id: String { name }
    }

    struct Day: Equatable, Identifiable {
        let start: Date
        let projects: [Project]
        var id: Date { start }
    }

    private(set) var visible: [DreamFindingSummary] = []
    private(set) var days: [Day] = []

    init() {}

    init(
        findings: [DreamFindingSummary],
        hideLowConfidence: Bool,
        calendar: Calendar = .current
    ) {
        visible = findings.filter { finding in
            !(hideLowConfidence && finding.confidence < 0.5 && finding.status == .new)
        }
        let byDay = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.createdAt) }
        days = byDay.keys.sorted(by: >).map { day in
            let byProject = Dictionary(grouping: byDay[day] ?? []) { $0.repositoryName }
            return Day(
                start: day,
                projects: byProject.keys.sorted().map {
                    Project(name: $0, findings: byProject[$0] ?? [])
                }
            )
        }
    }

    /// Remembers the last grouping. An unchanged inbox is the same array
    /// storage, so the equality check that guards a rebuild is usually a
    /// pointer comparison.
    @MainActor
    final class Memo {
        private var findings: [DreamFindingSummary]?
        private var hideLowConfidence = false
        private var cached = DreamInboxSections()

        func resolve(_ findings: [DreamFindingSummary], hideLowConfidence: Bool) -> DreamInboxSections {
            if let previous = self.findings, previous == findings,
               self.hideLowConfidence == hideLowConfidence {
                return cached
            }
            self.findings = findings
            self.hideLowConfidence = hideLowConfidence
            cached = DreamInboxSections(findings: findings, hideLowConfidence: hideLowConfidence)
            return cached
        }
    }
}

private struct DreamFindingRow: View {
    let finding: DreamFindingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(finding.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                Spacer()
                Text(finding.status.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(finding.kind.rawValue)
                Text("·")
                Text(finding.severity.rawValue)
                Text("·")
                Text(String(format: "%.0f%%", finding.confidence * 100))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct DreamFindingDetail: View {
    let finding: DreamFindingSummary
    var onAccept: () -> Void
    var onReject: (DreamRejectReason) -> Void
    var onDefer: (DreamDeferral) -> Void
    var onViewTranscript: () -> Void
    var onOpenEvidence: (DreamEvidence) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(finding.title)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    chip(finding.severity.rawValue)
                    chip(String(format: "%.0f%% confident", finding.confidence * 100))
                    chip(finding.kind.rawValue)
                    chip(finding.repositoryName)
                }

                labeled("Why this dream ran", finding.why)

                Text(finding.summary)
                    .font(.body)
                    .textSelection(.enabled)

                if !finding.evidence.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Evidence")
                            .font(.headline)
                        ForEach(Array(finding.evidence.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "doc.text")
                                if let path = item.path {
                                    Button {
                                        onOpenEvidence(item)
                                    } label: {
                                        Text(item.line.map { "\(path):\($0)" } ?? path)
                                            .font(.body.monospaced())
                                    }
                                    .buttonStyle(.plain)
                                }
                                if let note = item.note {
                                    Text(note).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if let diff = finding.diffSnapshot, !diff.isEmpty {
                    DisclosureGroup("Diff snapshot") {
                        ScrollView(.horizontal) {
                            Text(diff)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .oreOverlayScrollers()
                        .frame(maxHeight: 280)
                    }
                }

                if finding.chatID != nil {
                    Button("View transcript", action: onViewTranscript)
                }

                if finding.status == .new || finding.status == .deferred {
                    HStack {
                        Button("Accept", action: onAccept)
                            .keyboardShortcut(.defaultAction)
                        Menu("Reject") {
                            ForEach(DreamRejectReason.allCases, id: \.self) { reason in
                                Button(reason.displayName) { onReject(reason) }
                            }
                        }
                        Menu("Defer") {
                            Button("Tonight") { onDefer(.tonight) }
                            Button("Next week") { onDefer(.nextWeek) }
                        }
                    }
                    .controlSize(.large)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .oreOverlayScrollers()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }

    private func labeled(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(body).font(.callout)
        }
    }
}

private struct DreamTranscriptSheet: View {
    @Environment(AppModel.self) private var model
    let finding: DreamFindingSummary
    @Environment(\.dismiss) private var dismiss
    @State private var expandedActivityGroups: Set<String> = []
    /// Held here so its identity survives every body pass — `TranscriptHost`
    /// compares it by reference.
    @State private var scrollAnchor = TranscriptScrollAnchor()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if let chatID = finding.chatID {
                transcript(chatID)
            } else {
                Text("No transcript is attached to this finding.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    /// The same `Equatable` host the chat pane and the Assistant window use.
    /// This sheet used to join every message into one selectable `Text` on
    /// each row update — while a dream streamed, the whole transcript was
    /// re-joined and re-laid out per delta, with nothing holding the reader's
    /// place. `state.rows` must not be read here; see `TranscriptHost.==`.
    @ViewBuilder
    private func transcript(_ chatID: ChatID) -> some View {
        let state = model.chat(for: chatID)
        if state.hasRows {
            TranscriptHost(
                chat: state,
                worktreePath: model.workspaces.first { $0.id == finding.workspaceID }?.worktreePath
                    ?? finding.repositoryPath,
                agentName: model.chatIndex.summary(for: chatID)?.harness.displayName ?? "Agent",
                agentHarness: model.chatIndex.summary(for: chatID)?.harness,
                searchQuery: "",
                persistenceKey: "dream-\(chatID.rawValue)",
                expandedActivityGroups: expandedActivityGroups,
                canFork: false,
                onRevert: { _ in },
                onToggleActivity: { group in
                    if !expandedActivityGroups.insert(group).inserted {
                        expandedActivityGroups.remove(group)
                    }
                },
                onOpenFile: { _ in },
                onTurnAction: { _, _ in },
                scrollAnchor: scrollAnchor
            )
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                DreamTranscriptJumpToLatest(anchor: scrollAnchor)
            }
        } else {
            Text("Loading transcript…")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Reads `isAwayFromBottom` in its own body, so the sheet isn't re-run each
/// time the reader leaves or returns to the foot of the transcript.
private struct DreamTranscriptJumpToLatest: View {
    let anchor: TranscriptScrollAnchor

    var body: some View {
        if anchor.isAwayFromBottom {
            JumpToLatestButton { anchor.jumpToBottom() }
                .padding(OreTheme.Space.md)
                .transition(.opacity)
        }
    }
}
