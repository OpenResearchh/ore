import AppKit
import OreCore
import OreProtocol
import SwiftUI

/// Settings is an inspector, not a pile of unrelated forms. The left rail is
/// stable navigation; the detail side explains the selected system and shows
/// the real CLI probe/model data that the running core is using.
struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage("ore.defaultHarness") private var harnessRaw = HarnessKind.claudeCode.rawValue
    @AppStorage("ore.defaultModel") private var defaultModel = ""
    @AppStorage("ore.branchPrefix") private var branchPrefix = "ore"
    @AppStorage("ore.cursorExperimental") private var cursorExperimental = false
    @AppStorage("ore.cursorAllowUnprompted") private var cursorAllowUnprompted = false
    @AppStorage("ore.apiKeyFallback") private var apiKeyFallback = false
    @AppStorage("ore.notifications.enabled") private var notifications = true
    @AppStorage("ore.notifications.turnComplete") private var turnComplete = true
    @AppStorage("ore.notifications.sound") private var sound = true
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
            case .projects: "Per-project setup, including gitignored files copied into every worktree."
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

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Workspace defaults", icon: "square.stack.3d.up") {
                SettingsRow("Branch prefix", detail: "Used for new worktree branches") {
                    TextField("ore", text: $branchPrefix).frame(width: 180)
                }
            }
            SettingsCard(title: "Notifications", icon: "bell") {
                Toggle("Allow notifications", isOn: $notifications)
                Toggle("Notify when a turn completes", isOn: $turnComplete)
                    .disabled(!notifications)
                Toggle("Play completion sounds", isOn: $sound)
                    .disabled(!notifications)
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

    private func modelOptions(for harness: HarnessKind) -> [(String, String)] {
        [("", "Agent default")] + appModel.knownModels(for: harness).map { ($0.id, $0.displayName) }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "New chats", icon: "message") {
                SettingsRow("Default agent", detail: "Existing chats keep their own agent") {
                    SettingsPicker(
                        selection: $harnessRaw,
                        options: HarnessKind.allCases.map { ($0.rawValue, $0.displayName) }
                    )
                }
                SettingsRow("Default model", detail: "The agent default is used when none is selected") {
                    SettingsPicker(selection: $defaultModel, options: modelOptions(for: defaultHarness))
                }
            }

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
                    Image(systemName: probe(for: selectedHarness)?.isReady == true ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(statusColor(probe(for: selectedHarness)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(agentStatusTitle).fontWeight(.semibold)
                        Text(agentStatusDetail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if probe(for: selectedHarness)?.isInstalled == true,
                       probe(for: selectedHarness)?.isReady != true {
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
                    probe(for: selectedHarness)?.isReady == true ? "CLI subscription connected" : "Provider sign-in needed",
                    systemImage: probe(for: selectedHarness)?.isReady == true
                        ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
                .foregroundStyle(probe(for: selectedHarness)?.isReady == true ? .green : .orange)
                Text("ORE launches your installed CLI and leaves authentication with that provider. It never extracts your OAuth credentials.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Allow API-key fallback", isOn: $apiKeyFallback)
                if selectedHarness == .cursorAgent {
                    Toggle("Enable experimental Cursor Agent (restart required)", isOn: $cursorExperimental)
                    Toggle("Run tools unprompted in Bypass mode (restart required)", isOn: $cursorAllowUnprompted)
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

    private var defaultHarness: HarnessKind { HarnessKind(rawValue: harnessRaw) ?? .claudeCode }
    private func probe(for kind: HarnessKind) -> HarnessProbeResult? { appModel.harnesses.first { $0.kind == kind } }
    private func statusColor(_ probe: HarnessProbeResult?) -> Color {
        guard let probe else { return .secondary }
        return probe.isReady ? .green : (probe.isInstalled ? .orange : .red)
    }
    private var agentStatusTitle: String {
        guard let probe = probe(for: selectedHarness) else { return "Checking installation…" }
        if probe.isReady { return "Connected and ready" }
        if !probe.isInstalled { return "CLI not found" }
        return "Sign-in required"
    }
    private var agentStatusDetail: String {
        probe(for: selectedHarness)?.diagnostic
            ?? (probe(for: selectedHarness)?.isReady == true ? "Available to new and existing chats." : "Install or authenticate the CLI, then refresh.")
    }
    private var loginMethod: String {
        switch probe(for: selectedHarness)?.authState {
        case .authenticated: "CLI subscription"
        case .notAuthenticated: "Not signed in"
        case .unknown, .none: "Managed by CLI"
        }
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

/// Per-project setup, currently the list of gitignored files (`.env` and
/// friends) copied into every new worktree. Reads and writes the checked-in
/// `ore.toml` directly, so the setting travels with the repository.
private struct ProjectsSettings: View {
    let repositories: [String]
    @State private var filesByRepo: [String: [String]] = [:]
    @State private var newEntry: [String: String] = [:]
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if repositories.isEmpty {
                Text("No projects yet. Add a repository from the New Workspace sheet to configure it here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(repositories, id: \.self) { repo in
                SettingsCard(title: (repo as NSString).lastPathComponent, icon: "folder") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Gitignored files copied into every new worktree of this project — e.g. .env, so a fresh worktree can build without extra setup.")
                            .font(.caption).foregroundStyle(.secondary)

                        let files = filesByRepo[repo] ?? []
                        if files.isEmpty {
                            Text("No files configured.")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        ForEach(files, id: \.self) { file in
                            HStack(spacing: 8) {
                                Image(systemName: "doc").foregroundStyle(.secondary)
                                Text(file).font(.system(.body, design: .monospaced))
                                Spacer()
                                Button { remove(file, from: repo) } label: {
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
                            .onSubmit { add(to: repo) }
                            Button("Add") { add(to: repo) }
                                .disabled((newEntry[repo] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
        }
        .task {
            guard !loaded else { return }
            for repo in repositories {
                filesByRepo[repo] = OreConfiguration
                    .load(repositoryPath: URL(fileURLWithPath: repo)).filesToCopy
            }
            loaded = true
        }
    }

    private func add(to repo: String) {
        let value = (newEntry[repo] ?? "").trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        var files = filesByRepo[repo] ?? []
        newEntry[repo] = ""
        guard !files.contains(value) else { return }
        files.append(value)
        filesByRepo[repo] = files
        persist(repo, files: files)
    }

    private func remove(_ file: String, from repo: String) {
        var files = filesByRepo[repo] ?? []
        files.removeAll { $0 == file }
        filesByRepo[repo] = files
        persist(repo, files: files)
    }

    private func persist(_ repo: String, files: [String]) {
        let url = URL(fileURLWithPath: repo)
        var config = OreConfiguration.load(repositoryPath: url)
        config.filesToCopy = files
        try? config.toTOML().write(
            to: url.appendingPathComponent(OreConfiguration.fileName),
            atomically: true,
            encoding: .utf8
        )
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
