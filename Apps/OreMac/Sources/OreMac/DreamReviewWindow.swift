import OreProtocol
import SwiftUI

/// Morning inbox for Dream Mode. A dedicated window so it survives closing
/// the main workspace window, the same way the Assistant does.
struct DreamReviewWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: DreamFindingID?
    @State private var hideLowConfidence = true
    @State private var transcriptFinding: DreamFindingSummary?

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

    private var visibleFindings: [DreamFindingSummary] {
        model.dreamInbox.findings.filter { finding in
            if hideLowConfidence, finding.confidence < 0.5, finding.status == .new {
                return false
            }
            return true
        }
    }

    private var inbox: some View {
        List(selection: $selectedID) {
            Toggle("Hide low confidence", isOn: $hideLowConfidence)
                .font(.caption)
                .foregroundStyle(.secondary)

            let grouped = Dictionary(grouping: visibleFindings) {
                Calendar.current.startOfDay(for: $0.createdAt)
            }
            ForEach(grouped.keys.sorted(by: >), id: \.self) { day in
                Section(day.formatted(date: .abbreviated, time: .omitted)) {
                    let byRepo = Dictionary(grouping: grouped[day] ?? []) { $0.repositoryName }
                    ForEach(byRepo.keys.sorted(), id: \.self) { repo in
                        Section(repo) {
                            ForEach(byRepo[repo] ?? []) { finding in
                                DreamFindingRow(finding: finding)
                                    .tag(finding.id)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
                let state = model.chat(for: chatID)
                let text = state.rows
                    .filter { $0.kind == .userMessage || $0.kind == .assistantText }
                    .map(\.text)
                    .joined(separator: "\n\n")
                ScrollView {
                    Text(text.isEmpty ? "Loading transcript…" : text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No transcript is attached to this finding.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
}
