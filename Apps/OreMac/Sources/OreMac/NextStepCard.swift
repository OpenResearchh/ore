import AppKit
import OreGit
import OreProtocol
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
    var harnesses: [HarnessProbeResult] = []
    var onAddProject: () -> Void
    var onNewWorkspace: () -> Void
    var onGitHubStatusChanged: (() -> Void)? = nil

    @Environment(AppModel.self) private var model
    @State private var isExpanded = false
    @State private var copied = false
    @State private var setupError: String?

    var body: some View {
        // Nothing to say once the user can work — that silence is deliberate.
        // The other one was not: see `fallbackStep`.
        if let step = readiness.nextStep ?? Self.fallbackStep(for: readiness) {
            VStack(alignment: .leading, spacing: OreTheme.Space.sm) {
                header(step)
                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if step.status == .unknown {
                    // There is no action to offer for a rung that has not
                    // answered yet, and inventing one is what the ladder
                    // refuses to do. A spinner says the same thing honestly.
                    ProgressView().controlSize(.small)
                } else {
                    actionRow(step)
                }
                if let setupError, !setupError.isEmpty {
                    Text(setupError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if let url = model.harnessAuthenticationURL {
                    signInLink(url)
                }
                if readiness.relevantSteps.count > 1 {
                    Divider().opacity(0.5)
                    checklistToggle
                    if isExpanded { checklist }
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            .oreCard(padding: 16, radius: 16)
        }
    }

    /// The step to show when `nextStep` has nothing.
    ///
    /// `Readiness.nextStep` returns nil while a *blocking* rung is still
    /// `.unknown`, so the ladder never advises something it may have to retract
    /// a moment later. The welcome screen read that nil as "nothing to say" and
    /// drew nothing at all — and when a probe hung, or core start threw before
    /// any probe was spawned, the emptiness was permanent: no card, no button,
    /// no error, on the one screen a brand-new user has. The copy for this
    /// state ("Checking for coding agents…") was already written in
    /// `Readiness`; it had simply never been reachable.
    ///
    /// A `nonisolated static func` rather than a computed property so the
    /// choice can be tested without a window — and without a main-actor hop,
    /// since `View` conformance makes everything else on this type
    /// `@MainActor`.
    nonisolated static func fallbackStep(for readiness: Readiness) -> ReadinessStep? {
        readiness.steps.first { $0.isBlocking && $0.status == .unknown }
    }

    private func header(_ step: ReadinessStep) -> some View {
        // A rung that has not answered yet is not a warning: an alarm icon
        // over "Checking for coding agents…" reads as a failure that has not
        // happened.
        let isAlarming = step.isBlocking && step.status != .unknown
        return HStack(spacing: 8) {
            Image(systemName: isAlarming ? "exclamationmark.circle.fill" : "circle.dashed")
                .foregroundStyle(isAlarming ? OreTheme.brand : Color.secondary)
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
            commandBlock(command, primaryTitle: step.actionTitle ?? "Run in Terminal")

        case .addProject:
            Button(step.actionTitle ?? "Add project…", action: onAddProject)
                .buttonStyle(OrePrimaryButtonStyle())

        case .newWorkspace:
            Button(step.actionTitle ?? "New workspace", action: onNewWorkspace)
                .buttonStyle(OrePrimaryButtonStyle())

        case .signIn(let kind):
            VStack(alignment: .leading, spacing: 10) {
                signInControls(kind)
                alternativeInstalls(besides: kind)
            }

        case .installAgents:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(HarnessSetup.offeredKinds(from: harnesses), id: \.self) { kind in
                    harnessInstallRow(kind)
                }
            }

        case .githubSignIn:
            githubSignInControls()

        case .githubInstall:
            VStack(alignment: .leading, spacing: 8) {
                Text(GitHubCLISetup.installCommand)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(OreTheme.subduedFill, in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 8) {
                    Button("Install GitHub CLI") { model.installGitHubCLI() }
                        .buttonStyle(OrePrimaryButtonStyle())
                    Button("Copy") {
                        ExternalTools.copyPath(GitHubCLISetup.installCommand)
                    }
                    .buttonStyle(.bordered)
                    Button("Download page") {
                        if let url = URL(string: GitHubCLISetup.downloadURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

        case .openSettings, .openURL:
            EmptyView()
        }
    }

    private func commandBlock(_ command: String, primaryTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Show the command as well as offering to run it. Setup ends
            // in a terminal either way, and a user who can see the exact
            // command can decide whether they trust it.
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OreTheme.subduedFill, in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                Button(primaryTitle) {
                    ExternalTools.copyAndRunInTerminal(command)
                }
                .buttonStyle(OrePrimaryButtonStyle())
                Button(copied ? "Copied" : "Copy") {
                    ExternalTools.copyPath(command)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        copied = false
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func signInControls(_ kind: HarnessKind) -> some View {
        if model.authenticatingHarness == kind {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for browser…")
                Button("Cancel") { model.cancelHarnessAuthentication() }
            }
        } else {
            Button(kind == .claudeCode ? "Open Terminal to sign in" : "Sign in…") {
                Task { await signIn(kind) }
            }
            .buttonStyle(OrePrimaryButtonStyle())
        }
    }

    private func harnessInstallRow(_ kind: HarnessKind) -> some View {
        HStack(spacing: 8) {
            HarnessMark(harness: kind, size: 16)
            Text(kind.displayName)
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
            Button("Install") {
                model.installHarness(kind)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func alternativeInstalls(besides current: HarnessKind) -> some View {
        let others = HarnessSetup.offeredKinds(from: harnesses).filter { kind in
            kind != current && !(harnesses.first(where: { $0.kind == kind })?.isReady ?? false)
        }
        if !others.isEmpty {
            Text("Or install a different agent — you only need one.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(others, id: \.self) { kind in
                harnessInstallRow(kind)
            }
        }
    }

    private func githubSignInControls() -> some View {
        Group {
            if model.isAuthenticatingGitHub {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for GitHub…")
                }
            } else {
                Button("Sign in…") {
                    Task { await signInGitHub() }
                }
                .buttonStyle(OrePrimaryButtonStyle())
            }
        }
    }

    private func signInLink(_ url: String) -> some View {
        HStack(spacing: 8) {
            Text(url)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Copy link") { ExternalTools.copyPath(url) }
                .buttonStyle(.borderless)
        }
    }

    private func signIn(_ kind: HarnessKind) async {
        setupError = nil
        do {
            try await model.startHarnessSignIn(kind)
        } catch {
            setupError = error.localizedDescription
        }
    }

    private func signInGitHub() async {
        setupError = nil
        do {
            try await model.authenticateGitHub()
            onGitHubStatusChanged?()
        } catch {
            setupError = error.localizedDescription
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
