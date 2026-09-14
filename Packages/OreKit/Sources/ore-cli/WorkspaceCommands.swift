import Foundation
import OreCore
import OreGit
import OrePersistence
import OreProtocol
import OreSupport

// Drives the whole core from a terminal: repositories, workspaces, chat, review
// and git actions, with no Mac app in the picture. Anything the app can do has
// to be reachable here first, which keeps the command/event boundary honest and
// makes a core bug reproducible without a UI.

/// Runs one command against a core client and prints the events it produced.
func runWorkspaceCommand(_ command: String, options: CommandLineOptions) async {
    let store: OreStoreHandle
    do {
        store = try OreStoreHandle(path: options.databaseURL)
    } catch {
        FileHandle.standardError.write(Data("could not open the database: \(error)\n".utf8))
        exit(1)
    }

    let client = InProcessCoreClient(
        store: store.store,
        harnessRegistry: .standard(),
        worktreeRoot: options.value(for: "--worktree-root").map {
            FilePath.expandingTildeURL($0)
        }
    )
    let printer = CoreEventPrinter()
    let eventTask = Task {
        for await event in client.events {
            await printer.render(event)
        }
    }
    try? await client.start()

    switch command {
    case "repos":
        await listRepositories(client)

    case "add-repo":
        guard let path = options.positional.first else {
            usage("add-repo <path>")
            return
        }
        await client.send(.addRepository(path: path))
        await settle()

    case "new-project":
        await createProject(client, options: options)

    case "workspaces":
        await listWorkspaces(client, printer: printer)

    case "new":
        await createWorkspace(client, options: options)

    case "say":
        await say(client, options: options, printer: printer)

    case "diff":
        await showDiff(client, options: options, printer: printer)

    case "git-action":
        await showGitAction(client, options: options, printer: printer)

    case "archive":
        guard let id = await resolveWorkspace(client, options: options, printer: printer) else { break }
        await client.send(.archiveWorkspace(id))
        await settle()

    case "delete":
        guard let id = await resolveWorkspace(client, options: options, printer: printer) else { break }
        await client.send(.deleteWorkspace(id, deleteBranch: options.flag("--delete-branch")))
        await settle()

    case "turns":
        guard let id = await resolveWorkspace(client, options: options, printer: printer) else { break }
        for turn in (try? await client.transcript(workspaceID: id)) ?? [] {
            print("\(turn.ordinal)  \(turn.id.prefix(8))  \(turn.outcome ?? "running")"
                + "  ckpt=\(turn.checkpointCommit?.prefix(8) ?? "none")")
            if let prompt = turn.prompt { print("   › \(prompt.prefix(80))") }
        }

    case "revert":
        guard let id = await resolveWorkspace(client, options: options, printer: printer),
              let turn = options.value(for: "--turn")
        else {
            usage("revert --workspace <id> --turn <turn-id>")
            break
        }
        // Accept a prefix, as everywhere else.
        let turns = (try? await client.transcript(workspaceID: id)) ?? []
        guard let match = turns.first(where: { $0.id.hasPrefix(turn) }) else {
            FileHandle.standardError.write(Data("no turn matches \(turn)\n".utf8))
            break
        }
        await client.send(.revertToCheckpoint(id, TurnID(rawValue: match.id)))
        await settle(seconds: 6)

    case "search":
        guard let query = options.positional.first else {
            usage("search <query>")
            return
        }
        for hit in (try? await client.search(query)) ?? [] {
            print("· \(hit.workspaceName): \(hit.snippet)")
        }

    default:
        usage("unknown command: \(command)")
    }

    eventTask.cancel()
    await client.shutdown()
}

// MARK: - Commands

private func listRepositories(_ client: InProcessCoreClient) async {
    let repositories = (try? await client.repositories()) ?? []
    guard !repositories.isEmpty else {
        print("No repositories yet. Add one with: ore-cli add-repo <path>")
        return
    }
    for repository in repositories {
        print("\(repository.name)  \(repository.path)  (\(repository.defaultBranch))")
    }
}

private func listWorkspaces(_ client: InProcessCoreClient, printer: CoreEventPrinter) async {
    await client.send(.resync(nil))
    await settle()
    let workspaces = await printer.workspaces()
    guard !workspaces.isEmpty else {
        print("No workspaces yet. Create one with: ore-cli new --repo <path> --name <name>")
        return
    }
    for workspace in workspaces {
        let mark = workspace.hasUnread ? "●" : " "
        let changes = workspace.gitStatus.changedFileCount
        print("\(mark) \(workspace.id.rawValue.prefix(8))  \(workspace.name)")
        print("    \(workspace.branch) → \(workspace.baseBranch)  ·  \(workspace.status.rawValue)"
            + (changes > 0 ? "  ·  \(changes) changed" : "")
            + (workspace.stackedOn != nil ? "  ·  stacked" : ""))
    }
}

private func createProject(_ client: InProcessCoreClient, options: CommandLineOptions) async {
    guard let name = options.value(for: "--name") ?? options.positional.first else {
        usage("new-project <name> [--parent <dir>] [--no-workspace] "
            + "[--harness claude|codex] [--model <id>] [--prompt <text>]")
        return
    }
    await client.send(.createProject(CreateProjectRequest(
        name: name,
        parentDirectory: options.value(for: "--parent"),
        createWorkspace: !options.flag("--no-workspace"),
        workspaceName: options.value(for: "--workspace-name"),
        harness: options.harnessKind,
        model: options.value(for: "--model"),
        initialPrompt: options.value(for: "--prompt")
    )))
    // git init plus a worktree and an optional setup script.
    await settle(seconds: 8)
}

private func createWorkspace(_ client: InProcessCoreClient, options: CommandLineOptions) async {
    guard let repository = options.value(for: "--repo") else {
        usage("new --repo <path> --name <name> [--harness claude|codex] [--stack-on <workspace-id>] [--prompt <text>]")
        return
    }
    let seed: CreateWorkspaceRequest.Seed
    if let parent = options.value(for: "--stack-on") {
        seed = .workspace(WorkspaceID(rawValue: parent))
    } else if let issue = options.value(for: "--issue").flatMap(Int.init) {
        seed = .githubIssue(number: issue)
    } else if let branch = options.value(for: "--branch") {
        seed = .branch(branch)
    } else {
        seed = .defaultBranch
    }

    await client.send(.createWorkspace(CreateWorkspaceRequest(
        repositoryPath: repository,
        name: options.value(for: "--name") ?? "workspace",
        seed: seed,
        harness: options.harnessKind,
        model: options.value(for: "--model"),
        initialPrompt: options.value(for: "--prompt")
    )))
    // Worktree creation plus an optional setup script.
    await settle(seconds: 8)
}

private func say(
    _ client: InProcessCoreClient,
    options: CommandLineOptions,
    printer: CoreEventPrinter
) async {
    guard let id = await resolveWorkspace(client, options: options, printer: printer),
          let text = options.value(for: "--text") ?? options.positional.first
    else {
        usage("say --workspace <id> --text <message>")
        return
    }
    await client.send(.sendMessage(SendMessageRequest(workspaceID: id, text: text)))

    // Stream until the turn finishes, so the rig shows the same thing the app
    // would show.
    let autoAllow = options.flag("--auto-allow")
    let deadline = ContinuousClock.now.advanced(by: .seconds(options.timeoutSeconds))
    while ContinuousClock.now < deadline {
        if await printer.turnCompleted { break }

        // Stands in for the user clicking Allow. The agent blocks until every
        // request is answered, so a headless run needs some answer — and this
        // exercises the same path the button does.
        if autoAllow, let pending = await printer.takePendingPermission() {
            await client.send(.resolvePermission(id, pending, .allow))
        }
        try? await Task.sleep(for: .milliseconds(200))
    }
}

private func showDiff(
    _ client: InProcessCoreClient,
    options: CommandLineOptions,
    printer: CoreEventPrinter
) async {
    guard let id = await resolveWorkspace(client, options: options, printer: printer) else { return }
    let diffs = (try? await client.diff(workspaceID: id, againstBase: true)) ?? []
    guard !diffs.isEmpty else {
        print("No changes against the base branch.")
        return
    }
    for file in diffs {
        print("\(file.path)  +\(file.insertions) -\(file.deletions)"
            + (file.isBinary ? "  (binary)" : ""))
        guard options.flag("--full") else { continue }
        for hunk in file.hunks {
            print("  @@ -\(hunk.oldStart) +\(hunk.newStart) @@ \(hunk.header)")
            for line in hunk.lines {
                let marker: String
                switch line.kind {
                case .added: marker = "+"
                case .removed: marker = "-"
                case .context: marker = " "
                case .noNewline: marker = "\\"
                }
                print("  \(marker)\(line.text)")
            }
        }
    }
}

private func showGitAction(
    _ client: InProcessCoreClient,
    options: CommandLineOptions,
    printer: CoreEventPrinter
) async {
    guard let id = await resolveWorkspace(client, options: options, printer: printer) else { return }
    let action = (try? await client.suggestedGitAction(workspaceID: id)) ?? .none
    print("→ \(action.title)")
    print("   actionable: \(action.isActionable)  ·  delegates to agent: \(action.delegatesToAgent)")
}

// MARK: - Helpers

/// Accepts a full id or a unique prefix, because typing a UUID is not a thing
/// anyone should have to do.
private func resolveWorkspace(
    _ client: InProcessCoreClient,
    options: CommandLineOptions,
    printer: CoreEventPrinter
) async -> WorkspaceID? {
    await client.send(.resync(nil))
    await settle()
    let workspaces = await printer.workspaces()

    guard let requested = options.value(for: "--workspace") else {
        if workspaces.count == 1 { return workspaces[0].id }
        FileHandle.standardError.write(Data("--workspace <id> is required\n".utf8))
        return nil
    }
    let matches = workspaces.filter { $0.id.rawValue.hasPrefix(requested) }
    if matches.count == 1 { return matches[0].id }
    if matches.isEmpty {
        FileHandle.standardError.write(Data("no workspace matches \(requested)\n".utf8))
    } else {
        FileHandle.standardError.write(Data("\(requested) is ambiguous\n".utf8))
    }
    return nil
}

private func settle(seconds: Double = 2) async {
    try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
}

private func usage(_ message: String) {
    FileHandle.standardError.write(Data("usage: ore-cli \(message)\n".utf8))
}

/// Renders `CoreEvent`s and keeps the latest workspace list, so commands can
/// resolve ids without a second query path.
actor CoreEventPrinter {
    private var latest: [WorkspaceID: WorkspaceSummary] = [:]
    private(set) var turnCompleted = false
    private var isStreamingText = false
    private var pendingPermissions: [PermissionRequestID] = []

    func takePendingPermission() -> PermissionRequestID? {
        pendingPermissions.isEmpty ? nil : pendingPermissions.removeFirst()
    }

    func workspaces() -> [WorkspaceSummary] {
        latest.values.sorted { $0.name < $1.name }
    }

    func render(_ event: CoreEvent) {
        switch event {
        case .snapshot(let snapshot):
            for workspace in snapshot.workspaces { latest[workspace.id] = workspace }

        case .workspaceAdded(let summary):
            latest[summary.id] = summary
            endLine()
            print("+ \(summary.name)  \(summary.id.rawValue.prefix(8))  \(summary.branch)")
            print("  \(summary.worktreePath)")

        case .workspaceUpdated(let summary):
            latest[summary.id] = summary

        case .workspaceRemoved(let id):
            latest.removeValue(forKey: id)
            endLine()
            print("- removed \(id.rawValue.prefix(8))")

        case .agent(_, _, let agentEvent):
            render(agentEvent)

        case .promptSubmitted(_, _, let submission):
            // Only prompts the assistant sent are echoed. A prompt this
            // terminal was given on the command line is already on screen
            // directly above, and printing it back reads as a stutter.
            guard submission.origin == .agent else { break }
            endLine()
            let state = submission.isQueued ? "queued" : "sent"
            print("↳ ORE \(state) a prompt: \(submission.text)")

        case .chatAdded(let chat), .chatUpdated(let chat):
            endLine()
            print("· chat \(chat.title)  \(chat.id.rawValue.prefix(8))")

        case .chatRemoved, .chatsListed:
            break

        case .gitStatusChanged(let id, let status):
            latest[id]?.gitStatus = status

        case .harnessProbeCompleted, .harnessUpdatesChecked, .modelCatalogUpdated:
            break

        case .commandFailed(let failure):
            endLine()
            print("! \(failure.message)")
            if let detail = failure.detail { print("  \(detail)") }

        case .repositoryScriptsNeedApproval(let approval):
            endLine()
            let repository = URL(fileURLWithPath: approval.repositoryPath).lastPathComponent
            print("? \(repository)'s ore.toml scripts didn't run: approve them in the ORE app first")

        case .assistantConfirmationRequested(let confirmation):
            endLine()
            print("? assistant asks: \(confirmation.summary)")

        case .assistantConversationCompacted(_, _, let successor):
            endLine()
            print("· assistant conversation compacted → \(successor.rawValue.prefix(8))")

        case .assistantConfirmationResolved, .assistantUIAction:
            break

        case .dreamRunStateChanged, .dreamTaskUpdated,
             .dreamFindingAdded, .dreamFindingUpdated, .dreamInboxUpdated:
            break
        }
    }

    private func render(_ event: AgentEvent) {
        switch event {
        case .textDelta(let delta):
            isStreamingText = true
            FileHandle.standardOutput.write(Data(delta.text.utf8))
        case .turnCompleted(let result):
            endLine()
            print("· turn \(result.outcome.rawValue)")
            turnCompleted = true
        case .toolCall(let call):
            endLine()
            print("→ \(call.name)(\(call.displayName ?? ""))")
        case .permissionRequest(let request):
            endLine()
            print("? permission: \(request.toolName) \(request.summary ?? "")")
            pendingPermissions.append(request.id)
        case .sessionError(let error):
            endLine()
            print("! \(error.message)")
        default:
            break
        }
    }

    private func endLine() {
        guard isStreamingText else { return }
        isStreamingText = false
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

/// Keeps the store alive for the duration of a command.
struct OreStoreHandle {
    let store: OreStore

    init(path: URL) throws {
        store = try OreStore(path: path)
    }
}
