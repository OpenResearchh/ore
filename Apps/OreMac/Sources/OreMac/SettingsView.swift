import AppKit
import OreCore
import OreProtocol
import ServiceManagement
import SwiftUI

/// Settings is an inspector, not a pile of unrelated forms. The left rail is
/// stable navigation; the detail side explains the selected system and shows
/// the real CLI probe/model data that the running core is using.
struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(AppModel.DefaultKey.newChatHarness) private var harnessRaw = ""
    @AppStorage(AppModel.DefaultKey.newChatModel) private var defaultModel = ""
    @AppStorage(AppModel.DefaultKey.reviewHarness) private var reviewHarnessRaw = ""
    @AppStorage(AppModel.DefaultKey.reviewModel) private var reviewModel = ""
    @AppStorage("ore.branchPrefix") private var branchPrefix = "ore"
    @AppStorage("ore.cursorAllowUnprompted") private var cursorAllowUnprompted = false
    @AppStorage("ore.apiKeyFallback") private var apiKeyFallback = false
    @AppStorage("ore.notifications.enabled") private var notifications = true
    @AppStorage("ore.notifications.turnComplete") private var turnComplete = true
    @AppStorage("ore.notifications.sound") private var sound = true
    @AppStorage(NarrationEngine.masterSwitchKey) private var narrationEnabled = true
    @AppStorage(AppModel.greetingEnabledKey) private var greetingEnabled = true
    @AppStorage(AppModel.greetingVoiceKey) private var greetingVoice = true
    @AppStorage(NarrationEngine.fleetSwitchKey) private var fleetNarration = true
    @AppStorage(VoiceAssistantController.voiceAskKey) private var voiceAsks = true
    @AppStorage(VoiceHotkeyMonitor.legacyHoldDictationKey) private var legacyHoldDictation = false
    @AppStorage("ore.assistant.proactive") private var assistantProactive = true
    @AppStorage("ore.settingsSection") private var sectionRaw = "Agents"

    @State private var selectedHarness: HarnessKind = .claudeCode
    @State private var authenticatingHarness: HarnessKind?
    @State private var authenticationNotice: String?

    private enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case appearance = "Appearance"
        case models = "Default Models"
        case projects = "Projects"
        case agents = "Agents"
        case environment = "Environment"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintbrush"
            case .models: "sparkles"
            case .projects: "folder"
            case .agents: "cpu"
            case .environment: "terminal"
            }
        }
        var detail: String {
            switch self {
            case .general: "Workspace behavior, notifications, and everyday defaults."
            case .appearance: "ORE follows the visual and accessibility choices of this Mac."
            case .models: "Choose how new conversations begin and inspect every available model."
            case .projects: "Per-project ore.toml: scripts, files to copy, branch prefix, and default agent."
            case .agents: "See the coding harnesses ORE can reach, their authentication, and models."
            case .environment: "Understand where work lives and what every terminal and agent inherits."
            }
        }
    }

    private var section: Section {
        get { Section(rawValue: sectionRaw) ?? .agents }
        nonmutating set { sectionRaw = newValue.rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.accentColor.gradient)
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("ORE").font(.system(size: 14, weight: .semibold))
                        Text("Settings").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: 62)

                Divider()

                VStack(spacing: 4) {
                    ForEach(Section.allCases) { item in
                        Button { section = item } label: {
                            HStack(spacing: 11) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 14, weight: .medium))
                                    .frame(width: 20)
                                Text(item.rawValue)
                                    .font(.system(size: 13, weight: section == item ? .semibold : .regular))
                                Spacer()
                            }
                            .padding(.horizontal, 11)
                            .frame(height: 38)
                            .foregroundStyle(.primary)
                            .background(
                                section == item ? OreTheme.selectedFill : .clear,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(OrePressableButtonStyle())
                        .focusable(false)
                    }
                }
                .padding(10)

                Spacer(minLength: 12)

                HStack(spacing: 7) {
                    Circle()
                        .fill(appModel.readyHarnesses.isEmpty ? Color.orange : Color.green)
                        .frame(width: 7, height: 7)
                    Text("\(appModel.readyHarnesses.count) agents ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(16)
            }
            .frame(width: 205)
            .background(.thinMaterial)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(section.rawValue)
                            .font(.system(size: 27, weight: .semibold, design: .rounded))
                        Text(section.detail)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    detail
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 26)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 950, height: 650)
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .general: general
        case .appearance: appearance
        case .models: models
        case .projects: ProjectsSettings(repositories: appModel.repositories)
        case .agents: agents
        case .environment: environment
        }
    }

    private var hotkey: VoiceHotkeyMonitor { .shared }

    /// Bound straight to `SMAppService` — the system is the source of truth,
    /// so the toggle can never disagree with System Settings › Login Items.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                if enabled {
                    try? SMAppService.mainApp.register()
                } else {
                    try? SMAppService.mainApp.unregister()
                }
            }
        )
    }

    private var hotkeyDetail: String {
        hotkey.isGlobal
            ? "Tap ⇧⌥ in ORE to dictate into the composer; tap again to stop. Hold ⇧⌥ anywhere to talk to the assistant."
            : "Tap to dictate while ORE is frontmost. Allow Accessibility to also hold ⇧⌥ for the assistant from any other app."
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Workspace defaults", icon: "square.stack.3d.up") {
                SettingsRow("Branch prefix", detail: "Used for new worktree branches") {
                    TextField("ore", text: $branchPrefix).frame(width: 180)
                }
            }
            SettingsCard(title: "Always on", icon: "menubar.arrow.up.rectangle") {
                Toggle("Start ORE at login", isOn: launchAtLogin)
                Text("ORE lives in the menu bar: agents keep running and the assistant keeps answering ⇧⌥ with every window closed. Starting at login makes that permanent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Toggle("Proactive updates from the assistant", isOn: $assistantProactive)
                Text("The assistant watches activity across your workspaces and speaks up only for what matters — failures, finished work you asked about, agents blocked on you. Tell it what to surface or mute (\u{201C}only update me about kailash\u{201D}) and it remembers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsCard(title: "Notifications", icon: "bell") {
                Toggle("Allow notifications", isOn: $notifications)
                Toggle("Notify when a turn completes", isOn: $turnComplete)
                    .disabled(!notifications)
                Toggle("Play completion sounds", isOn: $sound)
                    .disabled(!notifications)
            }
            SettingsCard(title: "Launch briefing", icon: "sunrise") {
                Toggle("Greet me at launch", isOn: $greetingEnabled)
                Toggle("Speak the briefing aloud", isOn: $greetingVoice)
                    .disabled(!greetingEnabled || !narrationEnabled)
                Text("When ORE opens, a short card sums up what happened while you were away — who finished, who needs you, what's still running. The voice only chimes in after a real absence, and only while narration is allowed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsCard(title: "Spoken narration", icon: "speaker.wave.2") {
                Toggle("Allow spoken narration", isOn: $narrationEnabled)
                Text("Tabs with the speaker toggled on narrate their agent's work aloud — what it's doing now, what needs you, and when it finishes. Summaries are generated on this Mac; nothing leaves it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Announce every workspace's milestones", isOn: $fleetNarration)
                    .disabled(!narrationEnabled)
                Text("Even without the speaker toggle, background agents say when they finish, fail, or need you — named by workspace, never their ambient progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                NarrationVoicePicker(voice: appModel.narration.neuralVoice)
                    .disabled(!narrationEnabled)
                // Whether the smarter narration path exists on this machine.
                // "Ready" versus "turn on Apple Intelligence" is the answer to
                // why narration is or isn't summarizing the agent's own words.
                Text("On-device summaries — \(appModel.narration.summarizerAvailability)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsCard(title: "Voice input", icon: "mic") {
                Text("The composer mic (⌥⌘M) transcribes English into the prompt. Recognition prefers an on-device model; if one isn't available it falls back to Apple's speech service. Audio is never sent to ORE or to your agent provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Open the mic when an agent asks a question", isOn: $voiceAsks)
                Text("When an agent asks you something with options, ORE speaks the question, plays a soft chime, and listens for your answer — say an option or your own words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                SettingsRow(
                    "⇧⌥ — tap to dictate, hold for the assistant",
                    detail: hotkeyDetail
                ) {
                    if hotkey.isGlobal {
                        Label("Enabled", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Button("Allow…") {
                            hotkey.requestAccessibility()
                        }
                    }
                }
                Divider()
                Toggle("Hold ⇧⌥ dictates into the composer instead", isOn: $legacyHoldDictation)
                Text("Restores the pre-assistant gesture: holding the chord in another app pulls ORE frontmost and dictates into the focused composer, instead of talking to the assistant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear { hotkey.refreshTrust() }
        }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Native appearance", icon: "circle.lefthalf.filled") {
                Label("ORE follows your Mac’s appearance, accent colour, contrast, text size, and Reduce Motion settings.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.secondary)
                Text("Navigation and the composer use system materials so Liquid Glass automatically adapts across displays and accessibility modes.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// A binding over the per-harness default-model UserDefaults key. `@AppStorage`
    /// can't take a dynamic key, so this bridges one by hand.
    private func harnessDefaultModel(_ harness: HarnessKind) -> Binding<String> {
        let key = AppModel.defaultModelKey(for: harness)
        return Binding(
            get: { UserDefaults.standard.string(forKey: key) ?? "" },
            set: { UserDefaults.standard.set($0, forKey: key) }
        )
    }

    private func modelOptions(
        for harness: HarnessKind?,
        placeholder: String = "Agent default"
    ) -> [(String, String)] {
        guard let harness else { return [("", placeholder)] }
        return [("", placeholder)] + appModel.knownModels(for: harness).map { ($0.id, $0.displayName) }
    }

    private func harnessOptions(placeholder: String) -> [(String, String)] {
        [("", placeholder)] + HarnessKind.allCases.map { ($0.rawValue, $0.displayName) }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "New chats", icon: "message") {
                SettingsRow("Default agent", detail: "Existing chats keep their own agent") {
                    SettingsPicker(
                        selection: $harnessRaw,
                        options: harnessOptions(placeholder: "Same as workspace")
                    )
                }
                SettingsRow(
                    "Default model",
                    detail: pinnedHarness == nil
                        ? "Pin an agent above to pin its model too"
                        : "The agent default is used when none is selected"
                ) {
                    SettingsPicker(
                        selection: $defaultModel,
                        options: modelOptions(for: pinnedHarness, placeholder: "Same as workspace")
                    )
                    .disabled(pinnedHarness == nil)
                }
            }
            // A model id belongs to exactly one agent, so a pin left over from
            // the previous agent would name a model the new one cannot run.
            .onChange(of: harnessRaw) { defaultModel = "" }

            SettingsCard(title: "Review button", icon: "sparkles") {
                SettingsRow("Agent", detail: "Used by Review in the Changes tab") {
                    SettingsPicker(
                        selection: $reviewHarnessRaw,
                        options: harnessOptions(placeholder: "Same as new chats")
                    )
                }
                SettingsRow(
                    "Model",
                    detail: pinnedReviewHarness == nil
                        ? "Pin an agent above or under New chats to pin its model too"
                        : "Right-clicking Review still offers a one-off model"
                ) {
                    SettingsPicker(
                        selection: $reviewModel,
                        options: modelOptions(
                            for: pinnedReviewHarness,
                            placeholder: "Same as new chats"
                        )
                    )
                    .disabled(pinnedReviewHarness == nil)
                }
            }
            .onChange(of: reviewHarnessRaw) { reviewModel = "" }

            SettingsCard(title: "Default model per agent", icon: "cpu") {
                ForEach(appModel.readyHarnesses, id: \.self) { harness in
                    SettingsRow(
                        harness.displayName,
                        detail: "Used when switching to this agent with the model chip"
                    ) {
                        SettingsPicker(
                            selection: harnessDefaultModel(harness),
                            options: modelOptions(for: harness)
                        )
                    }
                }
            }

            SettingsCard(title: "Available models", icon: "list.bullet.rectangle") {
                ForEach(appModel.knownModels(for: defaultHarness)) { model in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: model.isDefault ? "star.fill" : "circle")
                            .foregroundStyle(model.isDefault ? Color.orange : Color.secondary.opacity(0.45))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName).fontWeight(.medium)
                            Text(model.description).font(.caption).foregroundStyle(.secondary)
                            Text(model.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) {
                ForEach(HarnessKind.allCases, id: \.self) { kind in
                    Button { selectedHarness = kind } label: {
                        HStack(spacing: 7) {
                            HarnessMark(harness: kind, size: 18)
                            Text(kind.displayName)
                            Circle().fill(statusColor(probe(for: kind))).frame(width: 6, height: 6)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(selectedHarness == kind ? OreTheme.selectedFill : .clear, in: Capsule())
                    }
                    .buttonStyle(OrePressableButtonStyle())
                }
                Spacer()
                Button { appModel.refreshHarnesses() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            SettingsCard(title: selectedHarness.displayName, harness: selectedHarness) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: agentStatusIcon)
                        .font(.system(size: 22))
                        .foregroundStyle(statusColor(probe(for: selectedHarness)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(agentStatusTitle).fontWeight(.semibold)
                        Text(agentStatusDetail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if probe(for: selectedHarness)?.isInstalled == true,
                       probe(for: selectedHarness)?.authState == .notAuthenticated {
                        Button {
                            beginHarnessAuthentication()
                        } label: {
                            if authenticatingHarness == selectedHarness {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Waiting for browser…")
                                }
                            } else {
                                Label(
                                    selectedHarness == .claudeCode ? "Copy sign-in command" : "Sign in…",
                                    systemImage: selectedHarness == .claudeCode ? "doc.on.doc" : "person.crop.circle.badge.checkmark"
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(authenticatingHarness != nil)
                    }
                }

                if let authenticationNotice {
                    Text(authenticationNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Divider()
                SettingsValueRow(label: "Version", value: probe(for: selectedHarness)?.version ?? "Not detected")
                SettingsValueRow(label: "Provider", value: selectedHarness.displayName)
                SettingsValueRow(label: "Login method", value: loginMethod)
                SettingsValueRow(label: "Executable", value: probe(for: selectedHarness)?.executablePath ?? selectedHarness.defaultExecutableName, monospaced: true)
            }

            SettingsCard(title: "Authentication", icon: "key") {
                Label(
                    authenticationStatusTitle,
                    systemImage: authenticationStatusIcon
                )
                .foregroundStyle(authenticationStatusColor)
                Text("ORE launches your installed CLI and leaves authentication with that provider. It never extracts your OAuth credentials.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Allow API-key fallback", isOn: $apiKeyFallback)
                if selectedHarness == .cursorAgent {
                    Toggle("Run tools unprompted in Bypass mode (restart required)", isOn: $cursorAllowUnprompted)
                    Label("Cursor Agent support is experimental", systemImage: "flask")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Cursor's CLI has no approval channel. ORE normally lets Cursor's auto-review classifier decide each tool call; this runs every command instead, with no prompt, whenever the chat is in Bypass Permissions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            SettingsCard(title: "Models · \(appModel.knownModels(for: selectedHarness).count)", icon: "sparkles") {
                ForEach(appModel.knownModels(for: selectedHarness)) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName).fontWeight(.medium)
                            Text(model.description).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.isDefault { Text("DEFAULT").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var environment: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                SettingsCard(title: "Workspace runtime", icon: "externaldrive") {
                    SettingsValueRow(label: "Storage", value: "~/ore", monospaced: true)
                    SettingsValueRow(label: "Worktrees", value: "One per workspace")
                    SettingsValueRow(label: "Active", value: "\(appModel.workspaces.count)")
                }

                SettingsCard(title: "Agent shell", icon: "terminal") {
                    SettingsValueRow(label: "Environment", value: "Login shell PATH")
                    SettingsValueRow(label: "Working dir", value: "Selected worktree")
                    SettingsValueRow(label: "Terminal", value: "Same environment")
                }
            }

            SettingsCard(title: "Isolation", icon: "lock.shield") {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Every workspace receives its own git worktree. Its terminal and agents start in that directory, so parallel tasks do not share an accidental working directory.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard(title: "Effective paths", icon: "folder") {
                SettingsValueRow(label: "Workspaces", value: "~/ore/workspaces", monospaced: true)
                SettingsValueRow(label: "Database", value: "~/ore/ore.sqlite", monospaced: true)
                SettingsValueRow(label: "Attachments", value: ".context/attachments", monospaced: true)
                Text("Paths are shown without expanding your home directory, so settings and screenshots do not expose personal account details.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The agent pinned for new chats, or nil while they still follow the workspace.
    private var pinnedHarness: HarnessKind? { HarnessKind(rawValue: harnessRaw) }
    /// The agent pinned for the Review button, falling back to the new-chat pin.
    private var pinnedReviewHarness: HarnessKind? {
        HarnessKind(rawValue: reviewHarnessRaw) ?? pinnedHarness
    }
    /// Whose model catalogue the "Available models" list should show.
    private var defaultHarness: HarnessKind { pinnedHarness ?? .claudeCode }
    private func probe(for kind: HarnessKind) -> HarnessProbeResult? { appModel.harnesses.first { $0.kind == kind } }
    private func statusColor(_ probe: HarnessProbeResult?) -> Color {
        guard let probe else { return .secondary }
        if probe.isEnabled == false { return .secondary }
        return probe.isReady ? .green : (probe.isInstalled ? .orange : .red)
    }
    private var agentStatusIcon: String {
        guard let probe = probe(for: selectedHarness) else { return "ellipsis.circle.fill" }
        if probe.isEnabled == false { return "pause.circle.fill" }
        return probe.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }
    private var agentStatusTitle: String {
        guard let probe = probe(for: selectedHarness) else { return "Checking installation…" }
        if !probe.isInstalled { return "CLI not found" }
        if probe.isEnabled == false { return "Installed · enable to use" }
        if probe.isReady { return "Connected and ready" }
        return "Sign-in required"
    }
    private var agentStatusDetail: String {
        guard let probe = probe(for: selectedHarness) else {
            return "Checking the login-shell PATH…"
        }
        if probe.isEnabled == false {
            return "ORE detected the CLI, but this build has disabled the Cursor integration."
        }
        return probe.diagnostic
            ?? (probe.isReady
                ? "Available to new and existing chats."
                : "Install or authenticate the CLI, then refresh.")
    }
    private var loginMethod: String {
        switch probe(for: selectedHarness)?.authState {
        case .authenticated: "CLI subscription"
        case .notAuthenticated: "Not signed in"
        case .unknown, .none: "Managed by CLI"
        }
    }
    private var authenticationStatusTitle: String {
        guard let probe = probe(for: selectedHarness) else { return "Checking CLI authentication…" }
        if probe.isEnabled == false { return "Integration disabled" }
        return probe.isReady ? "CLI subscription connected" : "Provider sign-in needed"
    }
    private var authenticationStatusIcon: String {
        guard let probe = probe(for: selectedHarness) else { return "ellipsis.circle.fill" }
        if probe.isEnabled == false { return "pause.circle.fill" }
        return probe.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }
    private var authenticationStatusColor: Color {
        guard let probe = probe(for: selectedHarness) else { return .secondary }
        if probe.isEnabled == false { return .secondary }
        return probe.isReady ? .green : .orange
    }

    private func beginHarnessAuthentication() {
        authenticationNotice = nil
        if selectedHarness == .claudeCode {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("claude", forType: .string)
            authenticationNotice = "Copied `claude`. Run it in Terminal and choose your account, then press Refresh."
            return
        }

        let kind = selectedHarness
        authenticatingHarness = kind
        Task {
            defer { authenticatingHarness = nil }
            do {
                try await appModel.authenticateHarness(kind)
                authenticationNotice = "Sign-in completed. Refreshing \(kind.displayName)…"
            } catch {
                authenticationNotice = error.localizedDescription
            }
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String?
    let harness: HarnessKind?
    @ViewBuilder let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.harness = nil
        self.content = content()
    }

    init(title: String, harness: HarnessKind, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = nil
        self.harness = harness
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                if let harness { HarnessMark(harness: harness, size: 19) }
                else if let icon { Image(systemName: icon).frame(width: 19) }
                Text(title)
            }
            .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .oreCard(padding: 16, radius: 16)
    }
}

/// Per-project setup stored in the checked-in `ore.toml`.
private struct ProjectsSettings: View {
    @Environment(AppModel.self) private var appModel
    let repositories: [String]
    @State private var configs: [String: OreConfiguration] = [:]
    @State private var newEntry: [String: String] = [:]
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if repositories.isEmpty {
                Text("No projects yet. Add a repository from the New Workspace sheet to configure it here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(repositories, id: \.self) { repo in
                let config = Binding(
                    get: { configs[repo] ?? OreConfiguration() },
                    set: { configs[repo] = $0; persist(repo, $0) }
                )
                SettingsCard(title: (repo as NSString).lastPathComponent, icon: "folder") {
                    VStack(alignment: .leading, spacing: 14) {
                        filesSection(repo: repo, config: config)
                        Divider()
                        scriptsSection(config: config)
                        Divider()
                        defaultsSection(config: config)
                    }
                }
            }
        }
        .task {
            guard !loaded else { return }
            for repo in repositories {
                configs[repo] = OreConfiguration.load(repositoryPath: URL(fileURLWithPath: repo))
            }
            loaded = true
        }
    }

    @ViewBuilder
    private func filesSection(repo: String, config: Binding<OreConfiguration>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gitignored files copied into every new worktree — e.g. .env.")
                .font(.caption).foregroundStyle(.secondary)
            let files = config.wrappedValue.filesToCopy
            if files.isEmpty {
                Text("No files configured.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(files, id: \.self) { file in
                HStack(spacing: 8) {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    Text(file).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button {
                        var next = config.wrappedValue
                        next.filesToCopy.removeAll { $0 == file }
                        config.wrappedValue = next
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                }
            }
            HStack {
                TextField(".env", text: Binding(
                    get: { newEntry[repo] ?? "" },
                    set: { newEntry[repo] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { addFile(to: repo, config: config) }
                Button("Add") { addFile(to: repo, config: config) }
                    .disabled((newEntry[repo] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @ViewBuilder
    private func scriptsSection(config: Binding<OreConfiguration>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scripts")
                .font(.system(size: 13, weight: .semibold))
            scriptRow("Setup", detail: "Runs once after a worktree is created", text: Binding(
                get: { config.wrappedValue.scripts.setup ?? "" },
                set: {
                    var next = config.wrappedValue
                    next.scripts.setup = $0.nilIfEmpty
                    config.wrappedValue = next
                }
            ))
            scriptRow("Run", detail: "Dev server or watcher, started with ⌘R", text: Binding(
                get: { config.wrappedValue.scripts.run ?? "" },
                set: {
                    var next = config.wrappedValue
                    next.scripts.run = $0.nilIfEmpty
                    config.wrappedValue = next
                }
            ))
            scriptRow("Archive", detail: "Runs before archiving: stop containers, free ports", text: Binding(
                get: { config.wrappedValue.scripts.archive ?? "" },
                set: {
                    var next = config.wrappedValue
                    next.scripts.archive = $0.nilIfEmpty
                    config.wrappedValue = next
                }
            ))
        }
    }

    private func scriptRow(_ title: String, detail: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            TextField(title.lowercased(), text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }

    @ViewBuilder
    private func defaultsSection(config: Binding<OreConfiguration>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Workspace defaults")
                .font(.system(size: 13, weight: .semibold))
            SettingsRow("Branch prefix", detail: "Used for new worktree branches of this project") {
                TextField("ore", text: Binding(
                    get: { config.wrappedValue.branchPrefix },
                    set: {
                        var next = config.wrappedValue
                        next.branchPrefix = $0.isEmpty ? "ore" : $0
                        config.wrappedValue = next
                    }
                ))
                .frame(width: 140)
            }
            SettingsRow("Default agent", detail: "Overrides the app default for this repository") {
                Picker("Agent", selection: Binding(
                    get: { config.wrappedValue.defaultHarness?.rawValue ?? "" },
                    set: {
                        var next = config.wrappedValue
                        next.defaultHarness = HarnessKind(rawValue: $0)
                        config.wrappedValue = next
                    }
                )) {
                    Text("App default").tag("")
                    ForEach(appModel.readyHarnesses, id: \.self) { kind in
                        Text(kind.displayName).tag(kind.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            SettingsRow("Default model", detail: "Used when a new workspace doesn't pick one") {
                TextField("Model id", text: Binding(
                    get: { config.wrappedValue.defaultModel ?? "" },
                    set: {
                        var next = config.wrappedValue
                        next.defaultModel = $0.nilIfEmpty
                        config.wrappedValue = next
                    }
                ))
                .frame(width: 180)
            }
        }
    }

    private func addFile(to repo: String, config: Binding<OreConfiguration>) {
        let value = (newEntry[repo] ?? "").trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        newEntry[repo] = ""
        var next = config.wrappedValue
        guard !next.filesToCopy.contains(value) else { return }
        next.filesToCopy.append(value)
        config.wrappedValue = next
    }

    private func persist(_ repo: String, _ config: OreConfiguration) {
        let url = URL(fileURLWithPath: repo)
        try? config.toTOML().write(
            to: url.appendingPathComponent(OreConfiguration.fileName),
            atomically: true,
            encoding: .utf8
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A fixed-width dropdown. SwiftUI's menu `Picker` sizes its button to the
/// widest *option* (so a harness with long model names overflowed and knocked
/// the controls out of alignment); a `Menu` with an explicit-width label shows
/// the short selected value and keeps every control the same width.
private struct SettingsPicker: View {
    @Binding var selection: String
    let options: [(String, String)]
    var width: CGFloat = 240

    private var currentLabel: String {
        options.first { $0.0 == selection }?.1 ?? options.first?.1 ?? ""
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Button(option.1) { selection = option.0 }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentLabel).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: 26)
            .background(OreTheme.subduedFill, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(OreTheme.hairline))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    init(_ title: String, detail: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }
}

private struct SettingsValueRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
