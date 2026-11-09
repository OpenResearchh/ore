import OreProtocol
import SwiftUI

/// "Claude Code 2.1.263 is available" — one card per harness whose install
/// channel is publishing something newer than what's on PATH.
///
/// Deliberately not the modal `GitHubUpdatePrompt` treatment. ORE updating
/// itself is a restart the user has to agree to; a harness CLI moving a point
/// release is news, not an interruption, and blocking the window over someone
/// else's release cadence would be the wrong trade. It stacks with the app's
/// other banners, so an update never covers an error.
struct HarnessUpdateBanner: View {
    @Environment(AppModel.self) private var model
    var onOpenInTerminal: (HarnessKind, HarnessRepair) -> Void
    var onShowTerminal: (HarnessKind) -> Void

    var body: some View {
        ForEach(model.pendingHarnessUpdates) { status in
            HarnessUpdateRow(
                status: status,
                update: model.harnessCLIUpdate,
                onUpdate: { model.updateHarnessCLI(status.kind) },
                onDismiss: { model.dismissHarnessUpdate(status) },
                onOpenInTerminal: { repair in onOpenInTerminal(status.kind, repair) },
                onShowTerminal: { onShowTerminal(status.kind) }
            )
        }
    }
}

private struct HarnessUpdateRow: View {
    @Environment(AppModel.self) private var model
    let status: HarnessUpdateStatus
    /// The single in-flight CLI upgrade, whichever harness owns it.
    let update: AppModel.HarnessCLIUpdate?
    let onUpdate: () -> Void
    let onDismiss: () -> Void
    let onOpenInTerminal: (HarnessRepair) -> Void
    let onShowTerminal: () -> Void

    private var isUpdating: Bool {
        update?.kind == status.kind && update?.isRunning == true
    }

    /// Only this harness's failure, and only once it has stopped running.
    private var failure: String? {
        guard update?.kind == status.kind, update?.isRunning == false else { return nil }
        return update?.error
    }

    private var terminalRepairState: AppModel.HarnessCLIUpdate.TerminalRepairState? {
        guard update?.kind == status.kind else { return nil }
        return update?.terminalRepairState
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HarnessMark(harness: status.kind, size: 20)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                Text("\(status.kind.displayName) \(status.latestVersion ?? "") is available")
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let terminalRepairState {
                    terminalRepairProgress(terminalRepairState)
                        .transition(.blurReplace.combined(with: .opacity))
                } else if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    // "Fix ownership of the install directory" is advice, not
                    // a way out: it leaves the user to work out which
                    // directory and which command. Hand over the exact lines
                    // for the install that actually failed instead.
                    //
                    // Root repairs are staged, not executed: the integrated
                    // terminal shows the exact commands and waits for Return.
                    // Repairs that need no elevation get an explicit Run label
                    // and can start immediately. See `HarnessRepair`.
                    if let repair = update?.repair {
                        Text(repair.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(repair.script)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(OreTheme.subduedFill, in: RoundedRectangle(cornerRadius: 6))

                        if repair.needsRoot {
                            Text("Runs as root — review the commands before pressing Return.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: OreTheme.Space.sm) {
                            CopyButton(
                                value: repair.script, label: "Copy fix", help: "Copy the commands"
                            )
                            .buttonStyle(OreSecondaryButtonStyle())
                            if model.selectedWorkspace != nil {
                                terminalButton(for: repair)
                            }
                        }
                        .font(.system(size: OreTheme.Font.caption))
                    }
                }
            }

            Spacer(minLength: 8)

            if terminalRepairState == nil {
                Button(action: onUpdate) {
                    HStack(spacing: 6) {
                        if isUpdating {
                            ProgressView().controlSize(.small)
                            Text("Updating…")
                        } else {
                            Image(systemName: "arrow.down.app")
                            Text(failure == nil ? "Update" : "Try Again")
                        }
                    }
                    .font(.system(size: OreTheme.Font.caption, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isUpdating)
                .help(helpText)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isUpdating || terminalRepairState != nil)
            .help("Hide until the next release")
        }
        .frame(maxWidth: 560)
        .oreCard(padding: 12, radius: 14)
        .animation(.smooth(duration: 0.3), value: terminalRepairState)
    }

    private func terminalRepairProgress(
        _ state: AppModel.HarnessCLIUpdate.TerminalRepairState
    ) -> some View {
        Button(action: onShowTerminal) {
            HStack(spacing: 7) {
                switch state {
                case .waiting:
                    ProgressView().controlSize(.small)
                    Text(update?.repair?.needsRoot == true
                        ? "Ready in Terminal — press Return to run"
                        : "Running in Terminal…")
                case .verifying:
                    ProgressView().controlSize(.small)
                    Text("Checking the installed version…")
                case .succeeded:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .symbolEffect(.bounce, value: true)
                    Text("Updated successfully")
                }
            }
            .font(.system(size: OreTheme.Font.caption, weight: .semibold))
            .foregroundStyle(state == .succeeded ? Color.green : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(OreTheme.subduedFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(state == .succeeded ? "Update complete" : "Show the repair terminal")
        .disabled(state == .succeeded)
    }

    @ViewBuilder
    private func terminalButton(for repair: HarnessRepair) -> some View {
        if repair.needsRoot {
            Button("Review in Terminal") { onOpenInTerminal(repair) }
                .buttonStyle(OreSecondaryButtonStyle())
                .help("Open ORE's workspace terminal with the commands ready; press Return to run")
        } else {
            Button("Run in Terminal") { onOpenInTerminal(repair) }
                .buttonStyle(OrePrimaryButtonStyle())
                .help("Run these commands in ORE's workspace terminal")
        }
    }

    private var detail: String {
        let installed = status.installedVersion.map { "You're on \($0)" } ?? "Installed version unknown"
        guard let command = status.updateCommand else { return installed + "." }
        return "\(installed). ORE will run \(command)."
    }

    private var helpText: String {
        guard let command = status.updateCommand else {
            return "Install the latest \(status.kind.displayName) CLI"
        }
        return "Runs \(command) in your login shell"
    }
}
