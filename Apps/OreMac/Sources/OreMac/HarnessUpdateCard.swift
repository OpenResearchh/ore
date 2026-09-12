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

    var body: some View {
        ForEach(model.pendingHarnessUpdates) { status in
            HarnessUpdateRow(
                status: status,
                update: model.harnessCLIUpdate,
                onUpdate: { model.updateHarnessCLI(status.kind) },
                onDismiss: { model.dismissHarnessUpdate(status) }
            )
        }
    }
}

private struct HarnessUpdateRow: View {
    let status: HarnessUpdateStatus
    /// The single in-flight CLI upgrade, whichever harness owns it.
    let update: AppModel.HarnessCLIUpdate?
    let onUpdate: () -> Void
    let onDismiss: () -> Void

    private var isUpdating: Bool {
        update?.kind == status.kind && update?.isRunning == true
    }

    /// Only this harness's failure, and only once it has stopped running.
    private var failure: String? {
        guard update?.kind == status.kind, update?.isRunning == false else { return nil }
        return update?.error
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

                if let failure {
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
                    // Copy-and-open rather than run-it-for-me on purpose:
                    // these can need root, and it is better for the user to
                    // read what runs as root and type their own password than
                    // for ORE to become something that executes privileged
                    // commands on request. See `HarnessRepair`.
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
                            Text("Runs as root — read it before you paste it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: OreTheme.Space.sm) {
                            CopyButton(
                                value: repair.script, label: "Copy fix", help: "Copy the commands"
                            )
                            .buttonStyle(OreSecondaryButtonStyle())
                            Button("Open Terminal") {
                                ExternalTools.openInTerminal(NSHomeDirectory())
                            }
                            .buttonStyle(OreSecondaryButtonStyle())
                            .help("Paste the commands here and press return")
                        }
                        .font(.system(size: OreTheme.Font.caption))
                    }
                }
            }

            Spacer(minLength: 8)

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
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
            .help(helpText)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
            .help("Hide until the next release")
        }
        .frame(maxWidth: 560)
        .oreCard(padding: 12, radius: 14)
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
