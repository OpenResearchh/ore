import AppKit
import OreGit
import OreProtocol
import SwiftUI

/// Creating a workspace: ⌘N, the most-used action in the app.
struct NewWorkspaceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var repositoryPath = ""
    @State private var harness: HarnessKind = .claudeCode
    @State private var modelName = ""
    @State private var prompt = ""
    @State private var seedKind = SeedKind.defaultBranch
    @State private var seedValue = ""
    @State private var stackOn: WorkspaceID?
    @State private var repositorySource = RepositorySource.local
    @State private var githubStatus: GitHubClient.Status?
    @State private var githubRepositories: [GitHubClient.Repository] = []
    @State private var githubQuery = ""
    @State private var githubReference = ""
    @State private var isLoadingGitHub = false
    @State private var isAuthenticatingGitHub = false
    @State private var isCreating = false
    @State private var operationError: String?
    @State private var createAnother = false
    @State private var seedItems: [GitHubClient.IssueListItem] = []
    @State private var localBranches: [String] = []
    @State private var isLoadingSeeds = false

    private enum RepositorySource: String, CaseIterable, Identifiable {
        case local = "On this Mac"
        case github = "GitHub"
        var id: String { rawValue }
    }

    private enum SeedKind: String, CaseIterable, Identifiable {
        case defaultBranch, branch, workspace, issue, pullRequest
        var id: String { rawValue }
        var title: String {
            switch self {
            case .defaultBranch: "Default branch"
            case .branch: "Existing branch"
            case .workspace: "Stack on workspace"
            case .issue: "GitHub issue"
            case .pullRequest: "GitHub pull request"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.md) {
            VStack(alignment: .leading, spacing: OreTheme.Space.xs) {
                Text("New Workspace")
                    .font(.system(size: 28, weight: .semibold))
                Text("Give an agent an isolated branch and a clear starting point.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Form {
                Picker("Repository source", selection: $repositorySource) {
                    ForEach(RepositorySource.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                if repositorySource == .local {
                    Picker("Repository", selection: $repositoryPath) {
                        if model.repositories.isEmpty {
                            Text("No repositories yet").tag("")
                        }
                        ForEach(model.repositories, id: \.self) { path in
                            Text((path as NSString).lastPathComponent).tag(path)
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Add Repository…") { chooseRepository() }
                            .buttonStyle(.link)
                    }
                } else {
                    githubRepositoryPicker
                }

                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Research identity") {
                        HStack(spacing: 8) {
                            Text(name)
                                .fontWeight(.medium)
                            Button { chooseAnotherIdentity() } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.plain)
                            .help("Choose another scientist")
                        }
                    }
                    if let identity = ResearchIdentity.matching(nameOrSlug: name) {
                        Text("\(identity.region) · \(identity.field)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("Agent", selection: $harness) {
                    ForEach(model.readyHarnesses, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }

                Picker("Model", selection: $modelName) {
                    Text("Default model").tag("")
                    ForEach(model.knownModels(for: harness)) { choice in
                        Text(choice.displayName).tag(choice.id)
                    }
                }

                Picker("Start from", selection: $seedKind) {
                    ForEach(SeedKind.allCases) { Text($0.title).tag($0) }
                }
                seedPicker

                VStack(alignment: .leading, spacing: 4) {
                    Text("First message").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(height: 70)
                }

                if let operationError {
                    Label(operationError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            HStack {
                Toggle("Create another", isOn: $createAnother)
                    .toggleStyle(.checkbox)
                    .help("Keep this sheet open after creating, so you can dispatch several workspaces quickly.")
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(OreSecondaryButtonStyle())
                Button {
                    Task { await create() }
                } label: {
                    if isCreating {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(repositorySource == .github ? "Cloning…" : "Creating…")
                        }
                    } else {
                        Text("Create")
                    }
                }
                    .buttonStyle(OrePrimaryButtonStyle())
                    .keyboardShortcut(.return)
                    .disabled(!canCreate || isCreating)
            }
        }
        .padding(OreTheme.Space.lg)
        .frame(width: 620)
        .frame(minHeight: 620)
        .task {
            await model.refreshRepositories()
            if name.isEmpty { name = model.suggestedResearchIdentity().name }
            if repositoryPath.isEmpty { repositoryPath = model.repositories.first ?? "" }
            if let ready = model.readyHarnesses.first { harness = ready }
            if let raw = UserDefaults.standard.string(forKey: AppModel.DefaultKey.newChatHarness),
               let preferred = HarnessKind(rawValue: raw), model.readyHarnesses.contains(preferred) {
                harness = preferred
                // The pinned model belongs to the pinned agent's catalogue, so it
                // only carries over when that agent is the one we ended up with.
                modelName = UserDefaults.standard.string(forKey: AppModel.DefaultKey.newChatModel) ?? ""
            }
        }
        .task(id: repositorySource) {
            if repositorySource == .github { await loadGitHub() }
        }
        .task(id: "\(repositoryPath)-\(seedKind.rawValue)") {
            await loadSeeds()
        }
    }

    @ViewBuilder
    private var seedPicker: some View {
        switch seedKind {
        case .defaultBranch:
            EmptyView()
        case .workspace:
            Picker("Workspace", selection: $stackOn) {
                Text("Choose a workspace").tag(WorkspaceID?.none)
                ForEach(model.sortedWorkspaces) { workspace in
                    Text(workspace.name).tag(WorkspaceID?.some(workspace.id))
                }
            }
        case .branch:
            if localBranches.isEmpty {
                TextField("Branch name", text: $seedValue)
            } else {
                Picker("Branch", selection: $seedValue) {
                    Text("Choose a branch").tag("")
                    ForEach(localBranches, id: \.self) { branch in
                        Text(branch).tag(branch)
                    }
                }
                TextField("Or type a branch name", text: $seedValue)
                    .font(.caption)
            }
        case .issue, .pullRequest:
            if isLoadingSeeds {
                ProgressView().controlSize(.small)
            } else if seedItems.isEmpty {
                TextField("Number", text: $seedValue)
            } else {
                Picker(seedKind == .issue ? "Issue" : "Pull request", selection: $seedValue) {
                    Text("Choose \(seedKind == .issue ? "an issue" : "a pull request")").tag("")
                    ForEach(seedItems) { item in
                        Text("#\(item.number)  \(item.title)").tag(String(item.number))
                    }
                }
                TextField("Or type a number", text: $seedValue)
                    .font(.caption)
            }
        }
    }

    private func chooseAnotherIdentity() {
        let used = Set(model.workspaces.flatMap { workspace in
            [workspace.name, (workspace.worktreePath as NSString).lastPathComponent]
        } + [name])
        name = ResearchIdentity.next(excluding: used).name
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        model.addRepository(path: url.path)
        Task {
            // Give the core a moment to resolve and store the repository root.
            try? await Task.sleep(for: .milliseconds(400))
            await model.refreshRepositories()
            repositoryPath = model.repositories.first { url.path.hasPrefix($0) }
                ?? model.repositories.first
                ?? ""
        }
    }

    @ViewBuilder
    private var githubRepositoryPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: githubStatus?.isAuthenticated == true
                    ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(githubStatus?.isAuthenticated == true ? .green : .orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(githubStatus?.isAuthenticated == true ? "GitHub connected" : "Connect GitHub")
                        .fontWeight(.medium)
                    Text(githubStatus?.diagnostic ?? "Choose any public, private, organization, or collaborator repository.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isLoadingGitHub || isAuthenticatingGitHub {
                    ProgressView().controlSize(.small)
                } else if githubStatus?.isAuthenticated != true {
                    Button("Sign in…") { Task { await authenticateGitHub() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(githubStatus?.isInstalled == false)
                } else {
                    Button { Task { await loadGitHub() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh repositories")
                }
            }

            if githubStatus?.isAuthenticated == true {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Find a repository", text: $githubQuery)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(OreTheme.subduedFill, in: RoundedRectangle(cornerRadius: 8))

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredGitHubRepositories.prefix(40)) { repository in
                            Button {
                                githubReference = repository.nameWithOwner
                            } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: repository.isPrivate ? "lock.fill" : "book.closed")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(repository.nameWithOwner)
                                            .fontWeight(.medium)
                                        if let detail = repository.description, !detail.isEmpty {
                                            Text(detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    if githubReference == repository.nameWithOwner {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    githubReference == repository.nameWithOwner
                                        ? OreTheme.selectedFill : .clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                }
                .frame(height: 155)
                .background(OreTheme.subduedFill.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(OreTheme.hairline))
            }

            TextField("owner/repository or GitHub URL", text: $githubReference)
                .textFieldStyle(.roundedBorder)
            Text("Paste a public repository even before signing in; private repositories use your GitHub CLI account.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var filteredGitHubRepositories: [GitHubClient.Repository] {
        guard !githubQuery.isEmpty else { return githubRepositories }
        return githubRepositories.filter {
            $0.nameWithOwner.localizedCaseInsensitiveContains(githubQuery)
                || ($0.description?.localizedCaseInsensitiveContains(githubQuery) ?? false)
        }
    }

    private var canCreate: Bool {
        repositorySource == .local
            ? !repositoryPath.isEmpty
            : !githubReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadGitHub() async {
        isLoadingGitHub = true
        defer { isLoadingGitHub = false }
        let status = await model.githubStatus()
        githubStatus = status
        guard status.isAuthenticated else { return }
        do {
            githubRepositories = try await model.githubRepositories()
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func authenticateGitHub() async {
        operationError = nil
        isAuthenticatingGitHub = true
        defer { isAuthenticatingGitHub = false }
        do {
            try await model.authenticateGitHub()
            await loadGitHub()
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func create() async {
        operationError = nil
        isCreating = true
        defer { isCreating = false }
        let selectedRepository: String
        do {
            if repositorySource == .github {
                selectedRepository = try await model.cloneGitHubRepository(githubReference)
            } else {
                selectedRepository = repositoryPath
            }
        } catch {
            operationError = error.localizedDescription
            return
        }

        model.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: selectedRepository,
            name: name.isEmpty ? model.suggestedResearchIdentity().name : name,
            seed: selectedSeed,
            harness: harness,
            model: modelName.isEmpty ? nil : modelName,
            initialPrompt: prompt.isEmpty ? nil : prompt,
            branchPrefix: UserDefaults.standard.string(forKey: "ore.branchPrefix")
        ))
        if createAnother {
            chooseAnotherIdentity()
            prompt = ""
            seedValue = ""
            stackOn = nil
        } else {
            dismiss()
        }
    }

    private func loadSeeds() async {
        seedItems = []
        localBranches = []
        guard repositorySource == .local, !repositoryPath.isEmpty else { return }
        isLoadingSeeds = true
        defer { isLoadingSeeds = false }
        switch seedKind {
        case .branch:
            localBranches = await model.localBranches(repositoryPath: repositoryPath)
        case .issue:
            seedItems = await model.githubIssues(repositoryPath: repositoryPath)
        case .pullRequest:
            seedItems = await model.githubPullRequests(repositoryPath: repositoryPath)
        default:
            break
        }
    }

    private var selectedSeed: CreateWorkspaceRequest.Seed {
        switch seedKind {
        case .defaultBranch: return .defaultBranch
        case .branch: return .branch(seedValue)
        case .workspace: return stackOn.map(CreateWorkspaceRequest.Seed.workspace) ?? .defaultBranch
        case .issue: return .githubIssue(number: Int(seedValue) ?? 0)
        case .pullRequest: return .githubPullRequest(number: Int(seedValue) ?? 0)
        }
    }
}

/// ⌘K. Jumps to a workspace, or searches every transcript.
///
/// Search matters more than it looks: with several agents working in parallel,
/// "which workspace was I doing the migration in?" stops being answerable from
/// memory after about the third one.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [AppModel.SearchResult] = []
    @FocusState private var focused: Bool
    @State private var selectedID: String?

    private struct PaletteCommand: Identifiable {
        var id: String
        var title: String
        var shortcut: String
        var action: () -> Void
    }

    private var commands: [PaletteCommand] {
        var values: [PaletteCommand] = [
            PaletteCommand(id: "new-chat", title: "New Chat Tab", shortcut: "⌘T") {
                if let id = model.selectedWorkspaceID { model.createChat(in: id) }
            },
            PaletteCommand(id: "settings", title: "Open Settings", shortcut: "⌘,") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            },
        ]
        if let workspace = model.selectedWorkspace {
            values.append(PaletteCommand(
                id: "pin", title: workspace.isPinned ? "Unpin Workspace" : "Pin Workspace",
                shortcut: "", action: { model.setPinned(!workspace.isPinned, for: workspace.id) }
            ))
            values.append(PaletteCommand(
                id: "archive", title: "Archive Workspace", shortcut: "",
                action: { model.archive(workspace.id) }
            ))
        }
        guard !query.isEmpty else { return values }
        return values.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var matchingWorkspaces: [WorkspaceSummary] {
        guard !query.isEmpty else { return model.sortedWorkspaces }
        return model.sortedWorkspaces.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.branch.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Jump to a workspace, or search every transcript…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .medium))
                .padding(OreTheme.Space.md)
                .focused($focused)
                .onSubmit { activateSelection() }
                .onKeyPress(.downArrow) {
                    moveSelection(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(-1)
                    return .handled
                }

            Rectangle().fill(OreTheme.hairline).frame(height: 1)

            List(selection: $selectedID) {
                if !commands.isEmpty {
                    Section("Commands") {
                        ForEach(commands) { command in
                            Button { run(command) } label: {
                                HStack {
                                    Label(command.title, systemImage: "command")
                                    Spacer()
                                    Text(command.shortcut).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .tag(command.id)
                        }
                    }
                }
                if !matchingWorkspaces.isEmpty {
                    Section("Workspaces") {
                        ForEach(matchingWorkspaces) { workspace in
                            Button {
                                model.selectedWorkspaceID = workspace.id
                                dismiss()
                            } label: {
                                HStack {
                                    Text(workspace.name)
                                    Spacer()
                                    Text(workspace.branch)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .tag("workspace-\(workspace.id.rawValue)")
                        }
                    }
                }

                if !results.isEmpty {
                    Section("In transcripts") {
                        ForEach(results) { result in
                            Button {
                                model.selectedWorkspaceID = result.workspaceID
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.workspaceName).font(.caption).foregroundStyle(.secondary)
                                    Text(result.snippet).lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: OreTheme.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: OreTheme.cardRadius).stroke(OreTheme.hairline) }
        .frame(width: 600, height: 440)
        .task { focused = true }
        .onChange(of: query) { _, _ in selectedID = commands.first?.id }
        .task(id: query) {
            // Debounced: search runs against SQLite's FTS index while the user
            // is still typing.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, query.count >= 2 else {
                results = []
                return
            }
            results = await model.search(query)
        }
    }

    private func openFirstResult() {
        if let workspace = matchingWorkspaces.first {
            model.selectedWorkspaceID = workspace.id
        } else if let result = results.first {
            model.selectedWorkspaceID = result.workspaceID
        }
        dismiss()
    }

    private func activateSelection() {
        if let selectedID,
           let command = commands.first(where: { $0.id == selectedID }) {
            run(command)
            return
        }
        if let selectedID, selectedID.hasPrefix("workspace-"),
           let workspace = matchingWorkspaces.first(where: {
               "workspace-\($0.id.rawValue)" == selectedID
           }) {
            model.selectedWorkspaceID = workspace.id
            dismiss()
            return
        }
        if let command = commands.first { run(command) } else { openFirstResult() }
    }

    private func run(_ command: PaletteCommand) {
        command.action()
        dismiss()
    }

    private func moveSelection(_ offset: Int) {
        let ids = commands.map(\.id) + matchingWorkspaces.map { "workspace-\($0.id.rawValue)" }
        guard !ids.isEmpty else { return }
        let index = selectedID.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : 0)
        selectedID = ids[(index + offset + ids.count) % ids.count]
    }
}

extension AppModel {
    /// Harnesses that are installed and signed in. Offering one that isn't
    /// would produce a workspace that fails on its first message.
    var readyHarnesses: [HarnessKind] {
        let ready = harnesses.filter(\.isReady).map(\.kind)
        return ready.isEmpty ? [.claudeCode, .codex] : ready
    }

}
