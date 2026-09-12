import AppKit
import OreGit
import SwiftUI

/// The onboarding surface: one thing to do, not a wall of setup.
///
/// This replaces a bare list of harness statuses that told the user what was
/// wrong but never what to do about it, and left them to work out which of
/// several red rows actually mattered. `Readiness` does the ordering; this
/// renders the single highest-priority unmet step and tucks the rest behind
/// a summary line.
///
/// It is not a wizard and there is nothing to dismiss. It lives in the empty
/// state, so it appears exactly when the user has nothing else to look at,
/// and disappears on its own the moment nothing is blocking — including
/// later, if an agent signs itself out months from now.
struct NextStepCard: View {
    let readiness: Readiness
    var onAddProject: () -> Void
    var onNewWorkspace: () -> Void

    @State private var isExpanded = false
    @State private var copied = false

    var body: some View {
        // Nothing to say before the probes land, and nothing to say once the
        // user can work. Both silences are deliberate.
        if let step = readiness.nextStep {
            VStack(alignment: .leading, spacing: OreTheme.Space.sm) {
                header(step)
                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actionRow(step)
                if readiness.relevantSteps.count > 1 {
                    Divider().opacity(0.5)
                    checklistToggle
                    if isExpanded { checklist }
                }
            }
            .frame(maxWidth: 380, alignment: .leading)
            .oreCard(padding: 16, radius: 16)
        }
    }

    private func header(_ step: ReadinessStep) -> some View {
        HStack(spacing: 8) {
            Image(systemName: step.isBlocking ? "exclamationmark.circle.fill" : "circle.dashed")
                .foregroundStyle(step.isBlocking ? OreTheme.brand : Color.secondary)
            Text(step.title)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func actionRow(_ step: ReadinessStep) -> some View {
        switch step.action {
        case .none:
            EmptyView()

        case .copyCommand(let command):
            VStack(alignment: .leading, spacing: 8) {
                // Show the command as well as offering to copy it. Setup ends
                // in a terminal either way, and a user who can see the exact
                // command can decide whether they trust it.
                Text(command)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(OreTheme.subduedFill, in: RoundedRectangle(cornerRadius: 8))
                Button(copied ? "Copied" : (step.actionTitle ?? "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        copied = false
                    }
                }
                .buttonStyle(OrePrimaryButtonStyle())
            }

        case .addProject:
            Button(step.actionTitle ?? "Add project…", action: onAddProject)
                .buttonStyle(OrePrimaryButtonStyle())

        case .newWorkspace:
            Button(step.actionTitle ?? "New workspace", action: onNewWorkspace)
                .buttonStyle(OrePrimaryButtonStyle())

        case .openSettings, .openURL:
            EmptyView()
        }
    }

    private var checklistToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text("\(readiness.satisfiedCount) of \(readiness.relevantSteps.count) ready")
                    .font(.system(size: 12))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(readiness.relevantSteps) { step in
                HStack(spacing: 7) {
                    Image(systemName: step.status == .satisfied ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(step.status == .satisfied ? Color.green : .secondary)
                    Text(step.title)
                        .font(.system(size: 12))
                        .foregroundStyle(step.status == .satisfied ? .secondary : .primary)
                    if !step.isBlocking && step.status != .satisfied {
                        // Say so out loud. Otherwise an unchecked box reads as
                        // "you cannot use this yet", which is not true.
                        Text("optional")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.top, 2)
    }
}
