import AppKit
import OreCore
import OrePersistence
import OreProtocol
import OreTelemetry
import ServiceManagement
import SwiftUI
import UserNotifications

/// The Settings scene's root: a shell with no inputs of its own.
///
/// AppKit keeps the Settings hosting view for the whole process once it has
/// been opened, and re-runs its root body on display cycles to answer
/// `NSHostingView.minSize()` (see `refreshLaunchAtLogin`). Keeping that root
/// trivial means the re-run stops here: `SettingsPanes` takes no inputs, so
/// SwiftUI has nothing new to hand it and skips its body.
///
/// With `ore.debug.unmountClosedSettings` set, the panes are also dropped
/// while the window is closed — off by default, because it resets the pane's
/// local state (the selected agent, an open license) between openings.
struct SettingsView: View {
    private static let unmountsWhileClosed =
        UserDefaults.standard.bool(forKey: "ore.debug.unmountClosedSettings")

    @State private var isOnScreen = true

    var body: some View {
        if Self.unmountsWhileClosed {
            // A ZStack, not a Group: its appear/disappear belong to the
            // container, so swapping the panes out can't re-trigger them.
            ZStack {
                if isOnScreen {
                    SettingsPanes()
                }
            }
            .frame(width: 950, height: 650)
            .onAppear { isOnScreen = true }
            .onDisappear { isOnScreen = false }
        } else {
            SettingsPanes()
        }
    }
}

/// Settings is an inspector, not a pile of unrelated forms. The left rail is
/// stable navigation; the detail side explains the selected system and shows
/// the real CLI probe/model data that the running core is using.
private struct SettingsPanes: View {
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
    @AppStorage(VoiceAssistantController.quietModeKey) private var quietMode = false
    @AppStorage(VoiceAssistantController.silenceAutoSendKey) private var silenceAutoSend = false
    @AppStorage(VoiceHotkeyMonitor.holdToTalkKey) private var holdToTalk = false
    @AppStorage(VoiceHotkeyMonitor.legacyHoldDictationKey) private var legacyHoldDictation = false
    @AppStorage("ore.assistant.proactive") private var assistantProactive = true
    @AppStorage(AppModel.automaticRoutinePermissionsKey)
    private var automaticRoutinePermissions = AppModel.automaticRoutinePermissionsDefault
    @AppStorage("ore.settingsSection") private var sectionRaw = "Agents"
    @AppStorage(DreamSettingsStore.enabled) private var dreamsEnabled = false
    @AppStorage(DreamSettingsStore.quietStart) private var quietStart = 60
    @AppStorage(DreamSettingsStore.quietEnd) private var quietEnd = 420
    @AppStorage(DreamSettingsStore.idleMinutes) private var idleMinutes = 20
    @AppStorage(DreamSettingsStore.requireACPower) private var requireACPower = true
    @AppStorage(DreamSettingsStore.preventSleep) private var preventSleep = false
    @AppStorage(DreamSettingsStore.nightTokenCap) private var nightTokenCap = 50_000
    @AppStorage(DreamSettingsStore.headroomFraction) private var headroomFraction = 0.25
    @AppStorage(DreamSettingsStore.copySecrets) private var copySecrets = false

    @State private var selectedHarness: HarnessKind = .claudeCode
    @State private var authenticatingHarness: HarnessKind?
    @State private var authenticationNotice: String?
    /// Mirrors the login-item state. See `refreshLaunchAtLogin` for why this is
    /// cached rather than read live.
    @State private var launchesAtLogin = false
    /// Set when macOS has accepted the login item but is waiting for the user
    /// to approve it. Read from the same `status` call as `launchesAtLogin`.
    @State private var loginItemNeedsApproval = false
    /// Whether macOS will deliver ORE's notifications at all. An app
    /// preference and a system grant are different questions and this pane only
    /// ever asked the first one.
    @State private var notificationsBlocked = false
    @State private var showsPhraseTuning = false
    /// Cached: `FinishPhraseStore.currentSpoken` decodes JSON, and this body
    /// re-runs every display cycle. Refreshed when the tuning sheet closes.
    @State private var finishPhraseSpoken = FinishPhraseStore.currentSpoken
    /// Cached for the same reason: it asks `SystemLanguageModel` for its
    /// availability. Refreshed each time the narration card appears.
    @State private var summarizerAvailability = ""

    private enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case appearance = "Appearance"
        case models = "Default Models"
        case projects = "Projects"
        case agents = "Agents"
        case environment = "Environment"
        case dreams = "Dreams"
        case privacy = "Privacy"
        case about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintbrush"
            case .models: "sparkles"
            case .projects: "folder"
            case .agents: "cpu"
            case .environment: "terminal"
            case .dreams: "moon.stars"
            case .privacy: "hand.raised"
            case .about: "info.circle"
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
            case .dreams: "Overnight research while this Mac is idle. Off by default, read-only, budgeted."
            case .privacy: "What ORE sends, what it never sends, and how to see or stop it."
            case .about: "Who makes ORE, its license, and the open-source work it is built on."
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
                    OreAppIcon(size: 34)
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

                let readyHarnesses = appModel.readyHarnesses
                HStack(spacing: 7) {
                    Circle()
                        .fill(readyHarnesses.isEmpty ? Color.orange : Color.green)
                        .frame(width: 7, height: 7)
                    Text("\(readyHarnesses.count) agents ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(16)
            }
            .frame(width: 205)
            .background(Color.black.opacity(0.12))

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
                // Every card on the page slides under the pointer while this
                // scrolls; both are no-ops unless their debug switch is set.
                .environment(\.oreFlatGlass, OreGlassDebug.flatScrollingCards)
                .oreGlassGroup()
            }
            .oreOverlayScrollers()
            .background(Color.clear)
        }
        .frame(width: 950, height: 650)
        .background {
            ZStack {
                OreTheme.Surface.content
                OreWindowGlassBase()
                Color.black.opacity(0.28)
            }
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        // Two user-paced reads instead of one per display cycle: when Settings
        // opens, and when they navigate to the pane the toggle is on — which is
        // also when they'd be coming back from System Settings › Login Items.
        .task { refreshLaunchAtLogin() }
        .onChange(of: sectionRaw) { _, _ in
            if section == .general { refreshLaunchAtLogin() }
        }
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
        case .dreams: dreams
        case .privacy: PrivacySettings()
        case .about: AboutSettings()
        }
    }

    private var hotkey: VoiceHotkeyMonitor { .shared }

    /// The system is still the source of truth, but it is *read* at moments the
    /// user creates, never from a view body.
    ///
    /// `SMAppService.status` is a synchronous XPC round trip to
    /// `backgroundtaskmanagementd`. Reading it from a `Binding.get` that
    /// `SettingsView.body` evaluates put that round trip inside
    /// `CA::Transaction::commit()` — AppKit re-runs this body on every display
    /// cycle to answer `NSHostingView.minSize()`, and the hosting view lives
    /// for the whole process once Settings has been opened once. A sample of
    /// the running app spent 27% of main-thread wall time in that one call,
    /// with the daemon at ~11% CPU answering the flood. Every scroll, click
    /// and keystroke in the entire app queued behind it, whether or not the
    /// Settings window was even visible.
    private func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchesAtLogin = status == .enabled
        // `register()` returns success while the service sits at
        // `.requiresApproval` — macOS wants the user to tick ORE under Login
        // Items first. The read-back below then found "not enabled" and the
        // toggle flipped itself off, which reads as broken rather than pending.
        loginItemNeedsApproval = status == .requiresApproval
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { launchesAtLogin },
            set: { enabled in
                if enabled {
                    try? SMAppService.mainApp.register()
                } else {
                    try? SMAppService.mainApp.unregister()
                }
                // Read back rather than trusting the write: registration can
                // fail (an unapproved login item stays disabled), and a toggle
                // that flips anyway would be lying about the system's state.
                refreshLaunchAtLogin()
            }
        )
    }

    private var hotkeyTitle: String {
        holdToTalk && !legacyHoldDictation
            ? "⇧⌥ — tap to dictate, hold to talk to the assistant"
            : "⇧⌥ — tap to dictate, hold then release for the assistant"
    }

    private var hotkeyDetail: String {
        guard hotkey.isGlobal else {
            return "Tap to dictate while ORE is frontmost. Allow Accessibility to arm the hands-free assistant from any app."
        }
        if holdToTalk && !legacyHoldDictation {
            return "Tap ⇧⌥ in ORE to dictate. For the assistant, hold until the cue, keep holding while you speak, then release to send."
        }
        return "Tap ⇧⌥ in ORE to dictate. For the assistant, hold until the cue, release, speak, then say “\(finishPhraseSpoken).”"
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Workspace defaults", icon: "square.stack.3d.up") {
                SettingsRow("Branch prefix", detail: "Used for new worktree branches") {
                    TextField("ore", text: $branchPrefix).frame(width: 180)
                }
            }
            SettingsCard(title: "Agent permissions", icon: "checkmark.shield") {
                Toggle(
                    "Automatically allow routine terminal commands",
                    isOn: $automaticRoutinePermissions
                )
                Text("Off until you turn it on: every command asks first. Turn it on and agents may inspect files, check git state, and run familiar builds and tests inside the workspace without interrupting you — ORE records each one in the transcript. Publishing, deleting, installing software, rewriting history, privileged commands, anything reaching outside the workspace, and anything ORE cannot confidently classify still ask, whatever this is set to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsCard(title: "Always on", icon: "menubar.arrow.up.rectangle") {
                Toggle("Start ORE at login", isOn: launchAtLogin)
                if loginItemNeedsApproval {
                    Text("macOS needs you to approve ORE under Login Items before this takes effect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
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
                // "Allow notifications" read like the system grant and was not
                // one — it is ORE's own preference, and it stayed on while
                // macOS quietly dropped every banner.
                Toggle("Notify me in ORE", isOn: $notifications)
                Toggle("Notify when a turn completes", isOn: $turnComplete)
                    .disabled(!notifications)
                Toggle("Play completion sounds", isOn: $sound)
                    .disabled(!notifications)
                if notificationsBlocked {
                    Text("macOS is blocking ORE's notifications, so none of these can be delivered. The permission prompt only appears once, on first launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Notification Settings") {
                        SystemSettingsLink.open(.notifications)
                    }
                }
            }
            .task { notificationsBlocked = await Self.notificationsAreBlocked() }
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
                Text("Even without the speaker toggle, background agents say when they finish, fail, or need you — named by workspace, never their ambient progress. ORE also watches the worktrees themselves, and mentions a branch that starts conflicting, a base that ran away, or a tab you left waiting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                NarrationVoicePicker(voice: appModel.narration.neuralVoice)
                    .disabled(!narrationEnabled)
                // Whether the smarter narration path exists on this machine.
                // "Ready" versus "turn on Apple Intelligence" is the answer to
                // why narration is or isn't summarizing the agent's own words.
                Text("On-device summaries — \(summarizerAvailability)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .onAppear {
                        summarizerAvailability = appModel.narration.summarizerAvailability
                    }
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
                Toggle("Keep the assistant quiet while you listen to music", isOn: $quietMode)
                Text("The HUD and chimes still show progress. The assistant speaks the answer to a question you asked, not confirmations, progress, or “still on it.”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Hold ⇧⌥ to talk", isOn: $holdToTalk)
                    .disabled(legacyHoldDictation)
                Text("The mic stays open only while you hold the chord. Release sends; a click or Escape drops it. Better with Bluetooth headphones, which otherwise sit on the telephony profile until you say the finish phrase.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                SettingsRow(
                    hotkeyTitle,
                    detail: hotkeyDetail
                ) {
                    if hotkey.isGlobal {
                        Label("Enabled", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Button("Allow…") {
                            // The system prompt fires once per app, ever.
                            // `requestAccessibility` returns false immediately
                            // for anyone who dismissed it — so this button was a
                            // no-op for precisely the people who needed it.
                            if !hotkey.requestAccessibility() {
                                SystemSettingsLink.open(.accessibility)
                            }
                        }
                    }
                }
                Divider()
                SettingsRow(
                    "Finish phrase",
                    detail: "“\(finishPhraseSpoken)” ends a hands-free request. Tune it against your own voice — the recognizer's actual transcriptions become accepted variants — or choose different words."
                ) {
                    Button("Tune…") { showsPhraseTuning = true }
                        .disabled(appModel.voiceAssistant.phase != .idle)
                }
                Divider()
                Toggle("Send after 3 seconds of silence", isOn: $silenceAutoSend)
                    .disabled(holdToTalk || legacyHoldDictation)
                Text("Optional backstop for hands-free requests. A soft cue plays one second before sending; speaking again cancels the countdown. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Toggle("Hold ⇧⌥ dictates into the composer instead", isOn: $legacyHoldDictation)
                Text("Restores the pre-assistant gesture: holding the chord in another app pulls ORE frontmost and dictates into the focused composer, instead of talking to the assistant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear { hotkey.refreshTrust() }
            .sheet(isPresented: $showsPhraseTuning) {
                finishPhraseSpoken = FinishPhraseStore.currentSpoken
            } content: {
                FinishPhraseTuningSheet()
            }
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
                // A probe is a login shell per harness and the update check
                // goes to the network: this can take half a minute. With no
                // busy state it looked inert and people pressed it again.
                // Same treatment as the update button below.
                Button { appModel.refreshHarnesses() } label: {
                    if appModel.isRefreshingHarnesses {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Refreshing…")
                        }
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(appModel.isRefreshingHarnesses)
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
                    // "CLI not found" used to be a dead end here: the pane
                    // named the PATH it had searched and stopped, while the
                    // one install command in the app lived on the welcome
                    // card and was always Claude Code's. This is the screen
                    // somebody opens to set up a *specific* agent.
                    //
                    // Bound on a probe that has actually returned, rather than
                    // `isInstalled != true`: offering to install something the
                    // user may already have, because the probe is still in
                    // flight, is the retraction the ladder is careful to avoid.
                    if let installProbe = probe(for: selectedHarness), !installProbe.isInstalled {
                        Button {
                            copyInstallCommand()
                        } label: {
                            Label("Copy install command", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if probe(for: selectedHarness)?.isInstalled == true,
                       probe(for: selectedHarness)?.authState == .notAuthenticated {
                        if authenticatingHarness == selectedHarness {
                            // "Waiting for browser…" used to be the whole story
                            // for as long as the process lived, with no way out
                            // of it short of quitting ORE.
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Waiting for browser…")
                                Button("Cancel") { appModel.cancelHarnessAuthentication() }
                            }
                        } else {
                            Button {
                                beginHarnessAuthentication()
                            } label: {
                                Label(
                                    selectedHarness == .claudeCode ? "Copy sign-in command" : "Sign in…",
                                    systemImage: selectedHarness == .claudeCode ? "doc.on.doc" : "person.crop.circle.badge.checkmark"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(authenticatingHarness != nil)
                        }
                    }
                }

                if let authenticationNotice {
                    Text(authenticationNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                // The link the CLI printed. When the browser does not open by
                // itself — a headless session, a default browser that refused —
                // this is the only way through, and it was going to /dev/null.
                if let url = appModel.harnessAuthenticationURL {
                    HStack(spacing: 8) {
                        Text(url)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Copy link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Divider()
                SettingsValueRow(label: "Version", value: probe(for: selectedHarness)?.version ?? "Not detected")
                harnessUpdateRow
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
                // Read once, at core construction (`OreMacApp.swift`), so
                // flipping it mid-session changes nothing until relaunch —
                // exactly like the Cursor toggle two rows down.
                Toggle("Allow API-key fallback (restart required)", isOn: $apiKeyFallback)
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

    /// The upgrade half of the Version row: what the install channel is
    /// publishing, and the button that installs it. Silent until the first
    /// check lands, so the pane never shows an empty "Update" affordance.
    @ViewBuilder
    private var harnessUpdateRow: some View {
        if let status = appModel.harnessUpdate(for: selectedHarness) {
            HStack(alignment: .firstTextBaseline) {
                Text("Update").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                if status.isUpdateAvailable, let latest = status.latestVersion {
                    Text("v\(latest) available")
                    Button(action: { appModel.updateHarnessCLI(selectedHarness) }) {
                        if isUpdatingSelectedHarness {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Updating…")
                            }
                        } else {
                            Text("Update now")
                        }
                    }
                    .disabled(isUpdatingSelectedHarness)
                    .help(status.updateCommand.map { "Runs \($0) in your login shell" }
                        ?? "Install the latest CLI")
                } else if let failure = status.failure {
                    Text(failure).foregroundStyle(.secondary)
                } else {
                    Text("Up to date").foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let update = appModel.harnessCLIUpdate,
               update.kind == selectedHarness,
               !update.isRunning,
               let error = update.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isUpdatingSelectedHarness: Bool {
        appModel.harnessCLIUpdate?.kind == selectedHarness
            && appModel.harnessCLIUpdate?.isRunning == true
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

    private var dreams: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Overnight research", icon: "moon.stars") {
                Toggle("Enable Dream Mode", isOn: $dreamsEnabled)
                Text("While you sleep, ORE reviews a project, hunts for bugs, and audits dependencies. Research only — it never pushes, never opens a PR, and never spends the quota you need in the morning. Off until you turn it on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Like the shoemaker's elves: work happens overnight, and you review it in the morning.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            SettingsCard(title: "Sleep", icon: "bolt.fill") {
                sleepStatusCopy
                Toggle("Keep Mac awake on AC during quiet hours", isOn: $preventSleep)
                    .disabled(!dreamsEnabled)
                Text("Only while plugged in. The display may still sleep. ORE never holds the Mac awake on battery. If this is off, overnight dreams only run if the Mac happens to stay awake — use Dream now from the Dreams window anytime. ⌥⌘D opens Dreams.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Only dream while plugged in", isOn: $requireACPower)
                    .disabled(!dreamsEnabled)
            }

            SettingsCard(title: "When", icon: "clock") {
                SettingsRow("Quiet hours start", detail: "Local time") {
                    DatePicker(
                        "",
                        selection: quietStartDate,
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .frame(width: 110)
                }
                SettingsRow("Quiet hours end", detail: "Local time") {
                    DatePicker(
                        "",
                        selection: quietEndDate,
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .frame(width: 110)
                }
                if let recommendation = appModel.dreamInbox.quietHoursRecommendation {
                    Button(recommendation.reason) {
                        quietStart = recommendation.startMinutes
                        quietEnd = recommendation.endMinutes
                        appModel.pushDreamSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                SettingsRow("Idle for", detail: "No keyboard or mouse") {
                    Stepper("\(idleMinutes) min", value: $idleMinutes, in: 5...120, step: 5)
                        .frame(width: 140)
                }
            }

            SettingsCard(title: "Budget", icon: "gauge") {
                SettingsRow("Night token cap", detail: "Hard stop for the whole night") {
                    TextField("50000", value: $nightTokenCap, format: .number)
                        .frame(width: 100)
                }
                SettingsRow("Morning headroom", detail: "Reserved so morning quota survives") {
                    Picker("", selection: $headroomFraction) {
                        Text("10%").tag(0.10)
                        Text("25%").tag(0.25)
                        Text("40%").tag(0.40)
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
                Text("Dreams may spend \(Int(Double(nightTokenCap) * (1 - headroomFraction))) tokens tonight. A run that hits the cap writes up findings and stops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsCard(title: "Safety", icon: "lock.shield") {
                Toggle("Copy .env and secrets into dream worktrees", isOn: $copySecrets)
                Text("Off: research dreams run without secrets. On: copies whatever ore.toml lists under [files] copy, the same as a normal workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsCard(title: "Excluded projects", icon: "eye.slash") {
                if appModel.repositories.isEmpty {
                    Text("Add a project first, then you can keep private repos out of overnight research.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appModel.repositories, id: \.self) { path in
                        Toggle(URL(fileURLWithPath: path).lastPathComponent, isOn: excludedRepoBinding(path))
                    }
                    Text("Excluded projects are never dreamed about, including Dream now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: dreamsEnabled) { _, _ in appModel.pushDreamSettings() }
        .onChange(of: preventSleep) { _, _ in appModel.pushDreamSettings() }
        .onChange(of: requireACPower) { _, _ in appModel.pushDreamSettings() }
        .onChange(of: quietStart) { _, _ in appModel.pushDreamSettings() }
        .onChange(of: quietEnd) { _, _ in appModel.pushDreamSettings() }
        .onChange(of: idleMinutes) { _, _ in appModel.pushDreamSettings() }
        .onChange(of: nightTokenCap) { _, _ in appModel.pushDreamSettings() }
        .onChange(of: headroomFraction) { _, _ in appModel.pushDreamSettings() }
        .onChange(of: copySecrets) { _, _ in appModel.pushDreamSettings() }
        .onAppear { appModel.refreshDreamSleepStatus() }
    }

    @ViewBuilder
    private var sleepStatusCopy: some View {
        switch appModel.dreamSleepStatus {
        case .macMaySleep:
            Text("Your Mac will likely sleep overnight. Dreams only run while it is awake.")
                .font(.caption)
                .foregroundStyle(.orange)
        case .keepAwakePausedOnBattery:
            Text("Keep awake is paused — plug in to run overnight.")
                .font(.caption)
                .foregroundStyle(.orange)
        case .keepAwakeActive:
            Text("ORE will keep this Mac awake during quiet hours while plugged in.")
                .font(.caption)
                .foregroundStyle(.green)
        case .opportunistic:
            Text("Dreams run opportunistically while the Mac happens to be awake.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .disabled:
            Text("Dream Mode is off. Overnight research will not start.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var quietStartDate: Binding<Date> {
        Binding(
            get: { Self.date(fromMinutes: quietStart) },
            set: { quietStart = Self.minutes(from: $0) }
        )
    }

    private var quietEndDate: Binding<Date> {
        Binding(
            get: { Self.date(fromMinutes: quietEnd) },
            set: { quietEnd = Self.minutes(from: $0) }
        )
    }

    private func excludedRepoBinding(_ path: String) -> Binding<Bool> {
        Binding(
            get: {
                (UserDefaults.standard.stringArray(forKey: DreamSettingsStore.excludedRepos) ?? [])
                    .contains(path)
            },
            set: { excluded in
                var paths = Set(UserDefaults.standard.stringArray(forKey: DreamSettingsStore.excludedRepos) ?? [])
                if excluded {
                    paths.insert(path)
                } else {
                    paths.remove(path)
                }
                UserDefaults.standard.set(Array(paths).sorted(), forKey: DreamSettingsStore.excludedRepos)
                appModel.pushDreamSettings()
            }
        )
    }

    private static func date(fromMinutes minutes: Int) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = minutes / 60
        components.minute = minutes % 60
        return Calendar.current.date(from: components) ?? Date()
    }

    private static func minutes(from date: Date) -> Int {
        Calendar.current.component(.hour, from: date) * 60
            + Calendar.current.component(.minute, from: date)
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

    /// Whether macOS has been told not to deliver ORE's notifications.
    ///
    /// Asked at all because nothing did: the pane offered three switches, all
    /// of them ORE's own, and a denial at first launch left every one of them
    /// on while not a single banner arrived. `UNNotificationSettings` is an
    /// ObjC class and not `Sendable`, so the one answer wanted is read out of
    /// it inside the callback and nothing else crosses back.
    private static func notificationsAreBlocked() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus == .denied)
            }
        }
    }

    /// Hands over the command rather than running it: installing a CLI writes
    /// to the user's PATH and, for two of the three vendors, pipes a script
    /// into a shell. That is their decision to take in their own terminal,
    /// where they can read it first.
    private func copyInstallCommand() {
        let command = HarnessSetup.installCommand(for: selectedHarness)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        authenticationNotice =
            "Copied `\(command)`. Run it in Terminal, then press Refresh."
    }

    private func beginHarnessAuthentication() {
        authenticationNotice = nil
        if selectedHarness == .claudeCode {
            let command = HarnessSetup.signInCommand(for: .claudeCode)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            authenticationNotice = "Copied `\(command)`. Run it in Terminal, finish the browser login, then press Refresh."
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

/// The pane PRIVACY.md points at.
///
/// Everything the document promises the user can do has to exist here, or the
/// document is a lie: turn it off, see exactly what is queued before it is
/// sent, and copy the one identifier needed to ask for deletion.
private struct PrivacySettings: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(TelemetryConsent.analyticsKey)
    private var analytics = TelemetryConsent.analyticsDefault

    @State private var pending: [TelemetryInspection.PendingEvent] = []
    @State private var showsPending = false
    @State private var copiedInstallID = false
    /// Loaded once per appearance, off the main actor: it opens the telemetry
    /// SQLite store, and used to do so from a computed property read twice in
    /// `body`.
    @State private var installID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Anonymous usage data", icon: "chart.bar") {
                Toggle("Share anonymous usage data", isOn: $analytics)
                Text("Six counters — installed, launched, workspace created, turn finished, pull request opened, and this switch being turned off. Durations and dates are reported as ranges, never exact values, and your IP address is not kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Turning this off deletes anything still queued on this Mac and stops recording immediately. It takes effect now, not at the next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsCard(title: "Never collected", icon: "lock.shield") {
                ForEach(Self.neverCollected, id: \.self) { item in
                    Label(item, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Enforced by the type system: every event is a case of a closed enum whose properties can only be a number, a flag, or a token from a fixed list. There is no way to put a file path in one without changing the types.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard(title: "Pending events", icon: "tray.full") {
                Text("Everything queued on this Mac and not yet sent, exactly as it would be uploaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(showsPending ? "Hide pending events" : "Show pending events") {
                        showsPending.toggle()
                        if showsPending { reload() }
                    }
                    if showsPending {
                        Button("Refresh") { reload() }
                    }
                    Spacer()
                }
                if showsPending {
                    if pending.isEmpty {
                        Text("Nothing is queued.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(pending) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(event.name) · \(event.occurredAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption.weight(.medium))
                                Text(event.properties)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            SettingsCard(title: "Your install ID", icon: "number") {
                Text("A random UUID made on this Mac. It is the whole identity — there is no account, and nothing here is tied to your name, email, or GitHub.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(installID ?? "Not created yet — nothing has been recorded.")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    if let installID {
                        Button(copiedInstallID ? "Copied" : "Copy install ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(installID, forType: .string)
                            copiedInstallID = true
                        }
                    }
                }
                Text("To have everything associated with this ID deleted, email it to privacy@openresearchh.com.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .task {
            installID = await Task.detached(priority: .userInitiated) {
                TelemetryInspection.installID(home: OreHome.directory)
            }.value
        }
        // Recording has to stop the moment the switch moves, not at the next
        // launch: the queue is purged here, and `make` refuses to build a
        // recording client next time.
        .onChange(of: analytics) { _, isOn in
            guard !isOn else { return }
            let recorder = appModel.telemetry
            Task { await recorder.optOut() }
            if showsPending { reload() }
        }
    }

    private static let neverCollected = [
        "Prompt text, or anything you type into ORE",
        "Anything an agent says, thinks, or writes",
        "Diffs, patches, or file contents",
        "File paths and file names",
        "Repository, branch, commit, and pull request names",
        "API keys and agent CLI credentials",
    ]

    /// The store is SQLite on disk; read it off the main actor.
    private func reload() {
        Task {
            pending = await Task.detached(priority: .userInitiated) {
                TelemetryInspection.pending(home: OreHome.directory)
            }.value
        }
    }
}

/// Who makes ORE, the license it is shared under, and the open-source work it
/// ships — with every license text reproduced in the app, as those licenses ask.
private struct AboutSettings: View {
    @State private var openDocument: LegalDocument?
    @State private var documentText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "ORE", icon: "info.circle") {
                HStack(spacing: 14) {
                    OreAppIcon(size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ORE")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text("Version \(OreAbout.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Made by \(OreAbout.company)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    linkButton("Website", systemImage: "globe", url: OreAbout.website)
                    linkButton("Source code", systemImage: "chevron.left.forwardslash.chevron.right", url: OreAbout.repository)
                    linkButton("Release notes", systemImage: "doc.text", url: OreAbout.releaseNotes)
                    linkButton("Privacy contact", systemImage: "envelope", url: OreAbout.privacyContact)
                    Spacer(minLength: 0)
                }
            }

            SettingsCard(title: "License", icon: "checkmark.seal") {
                Text(OreAbout.copyright)
                    .font(.callout)
                    .textSelection(.enabled)
                Text("ORE is open source under the \(OreAbout.licenseName): you may use, change and share it on those terms, and it comes without warranty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    documentButton(.license, show: "View license", hide: "Hide license")
                    documentButton(.notice, show: "View notice", hide: "Hide notice")
                    Spacer()
                }
                if openDocument == .license || openDocument == .notice {
                    documentView
                }
            }

            SettingsCard(title: "Acknowledgements", icon: "heart") {
                Text("ORE is built on open-source work. Each project keeps its own license, and every one is reproduced in full inside the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(ThirdPartyComponent.all) { component in
                        componentRow(component)
                        if component != ThirdPartyComponent.all.last { Divider() }
                    }
                }
                HStack {
                    documentButton(
                        .thirdPartyLicenses,
                        show: "View full license texts",
                        hide: "Hide full license texts"
                    )
                    Spacer()
                }
                if openDocument == .thirdPartyLicenses {
                    documentView
                }
            }

            Text("Claude, Codex and Cursor are trademarks of their respective owners. ORE is not affiliated with or endorsed by them.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func linkButton(_ title: String, systemImage: String, url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Label(title, systemImage: systemImage)
        }
        .help(url.absoluteString.replacingOccurrences(of: "mailto:", with: ""))
    }

    /// Opens the text in place. Read from the bundle on the click, never in
    /// `body`, which Settings re-runs every display cycle.
    private func documentButton(_ document: LegalDocument, show: String, hide: String) -> some View {
        Button(openDocument == document ? hide : show) {
            if openDocument == document {
                openDocument = nil
            } else {
                documentText = document.text
                    ?? "This build doesn't include \(document.rawValue). It is at the root of the source repository."
                openDocument = document
            }
        }
    }

    private var documentView: some View {
        LegalTextView(text: documentText)
            .frame(height: 280)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func componentRow(_ component: ThirdPartyComponent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(component.name)
                    .font(.callout.weight(.medium))
                Text("\(component.purpose) · \(component.credit)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(component.license)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button { NSWorkspace.shared.open(component.url) } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .help("Open \(component.name)")
        }
        .padding(.vertical, 7)
    }
}

/// A license text, read-only and selectable.
///
/// Not a SwiftUI `Text` in a `ScrollView`: ThirdPartyLicenses is ~59 KB, and a
/// selectable `Text` lays the whole of it out as one block inside a scroll
/// view nested in the page's own. An NSTextView with non-contiguous layout
/// only lays out what is on screen, and its overlay-only scroll view matches
/// every other scroller in the app.
private struct LegalTextView: NSViewRepresentable {
    let text: String

    final class Coordinator {
        var lastApplied: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 from the start: non-contiguous layout is a layout-manager
        // feature, and reaching for `layoutManager` on a TextKit 2 view swaps
        // its whole text stack out after the fact.
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.layoutManager?.allowsNonContiguousLayout = true

        let scroll = OreOverlayScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Compared against what was last applied, not `textView.string`,
        // which would bridge the whole document on every update.
        guard context.coordinator.lastApplied != text else { return }
        context.coordinator.lastApplied = text
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        ))
        textView.scroll(.zero)
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
    /// Edits not yet written to `ore.toml`. Every keystroke in a script field
    /// is an edit, and each used to be a TOML encode plus an atomic file write
    /// on the main actor; now they settle for a moment and write once.
    @State private var unsaved: [String: OreConfiguration] = [:]

    private static let persistDebounce: Duration = .milliseconds(400)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if repositories.isEmpty {
                Text("No projects yet. Add a repository from the New Workspace sheet to configure it here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(repositories, id: \.self) { repo in
                let config = Binding(
                    get: { configs[repo] ?? OreConfiguration() },
                    set: { configs[repo] = $0; unsaved[repo] = $0 }
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
            let repos = repositories
            let found = await Task.detached(priority: .userInitiated) {
                Dictionary(uniqueKeysWithValues: repos.map {
                    ($0, OreConfiguration.load(repositoryPath: URL(fileURLWithPath: $0)))
                })
            }.value
            // An edit made while the files were loading wins over the file.
            configs.merge(found) { edited, _ in edited }
            loaded = true
        }
        // Restarts on every edit, so only a pause in typing reaches the disk.
        .task(id: unsaved) {
            guard !unsaved.isEmpty else { return }
            try? await Task.sleep(for: Self.persistDebounce)
            guard !Task.isCancelled else { return }
            flushUnsaved()
        }
        // Leaving the pane cancels the debounce above; the last edit must
        // still land.
        .onDisappear { flushUnsaved() }
    }

    private func flushUnsaved() {
        guard !unsaved.isEmpty else { return }
        let writes = unsaved
        unsaved = [:]
        // `[agent] harness` is now read back when a workspace is started, from
        // a per-path cache. This is the one place in the process that rewrites
        // the file it was read from.
        appModel.forgetRepositoryDefaults()
        Task.detached(priority: .utility) {
            for (repo, config) in writes {
                Self.persist(repo, config)
            }
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

    private nonisolated static func persist(_ repo: String, _ config: OreConfiguration) {
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
