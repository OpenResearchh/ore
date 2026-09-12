import Foundation
import OreGit
import OreHarness
import OrePersistence
import OreProtocol
import OreSupport

struct HarnessRateLimitObservation: Sendable, Equatable {
    var report: RateLimitReport
    var observedAt: Date
    var chatID: ChatID
}

/// The core, as the Mac app sees it.
///
/// Everything crosses this boundary as `CoreCommand` in and `CoreEvent` out —
/// two `Codable` enums and nothing else. Today it's dispatched in-process; the
/// hosted version of ORE is the same two enums over a socket, and keeping the
/// boundary honest now is what makes that a change of transport rather than a
/// rewrite.
public actor InProcessCoreClient: CoreClient {
    public nonisolated let events: AsyncStream<CoreEvent>
    nonisolated let continuation: AsyncStream<CoreEvent>.Continuation

    let store: OreStore
    /// Internal so the Assistant action layer can describe every registered
    /// harness alongside its live probe/model inventory.
    let harnessRegistry: HarnessRegistry
    let worktreeRoot: URL?
    private let allowAPIKeyFallback: Bool

    private var engines: [WorkspaceID: WorkspaceEngine] = [:]
    private var engineTasks: [WorkspaceID: [Task<Void, Never>]] = [:]
    private var gitClients: [String: GitClient] = [:]
    var harnessProbes: [HarnessProbeResult] = []
    var harnessUpdates: [HarnessUpdateStatus] = []
    private var lastHarnessUpdateCheck: Date?
    /// The check awaits the network, and the actor releases between awaits, so
    /// launch and a Refresh click can otherwise overlap on the same registries.
    private var harnessUpdateCheckInFlight = false
    var modelCatalog: [HarnessKind: [AgentModel]] = [:]
    /// Most recent provider quota signal seen on any tab for each harness.
    /// Providers emit these during sessions rather than through discovery, so
    /// the MCP inventory also reports when no observation exists.
    var harnessRateLimits: [HarnessKind: HarnessRateLimitObservation] = [:]

    /// Invalidates whole-list reads that suspended while a workspace or chat
    /// mutation completed. Actor isolation does not make an async method
    /// atomic: `resync` awaits each engine, so an older snapshot could
    /// otherwise be emitted after a newer archive/create/close event and put
    /// stale rows back in the UI.
    private var listRevision: UInt64 = 0

    #if DEBUG
    /// Deterministic seam for the stale-snapshot regression test. Production
    /// never installs it; taking it before awaiting makes it one-shot.
    var beforeSnapshotEmission: (@Sendable () async -> Void)?
    #endif

    // Assistant action lane — see AssistantActions.swift for the policy and
    // dispatch. Stored here because extensions can't add storage.
    var assistantBridge: AssistantBridgeServer?
    var pendingAssistantConfirmations: [String: CheckedContinuation<AssistantResolution, Never>] = [:]
    var assistantTaskGrants: [AssistantTaskGrantKey: Date] = [:]
    var assistantAlwaysGrants: Set<AssistantActionClass> = []
    /// Harnesses that already failed or exhausted quota this incident, so a
    /// second error does not bounce back onto the one we just left.
    var assistantFailedHarnesses: [ChatID: Set<HarnessKind>] = [:]
    var assistantFailoverInFlight: Set<ChatID> = []
    var assistantFailoverAt: [ChatID: ContinuousClock.Instant] = [:]

    var dreamSettings = DreamSettings.default
    var dreamEnvironment: DreamEnvironmentSnapshot?
    var dreamSchedulerState = DreamScheduler.State()
    var dreamWorkerTask: Task<Void, Never>?
    var dreamHarnessParkedUntil: [HarnessKind: Date] = [:]

    public init(
        store: OreStore,
        harnessRegistry: HarnessRegistry = .standard(),
        worktreeRoot: URL? = nil,
        allowAPIKeyFallback: Bool = false
    ) {
        self.store = store
        self.harnessRegistry = harnessRegistry
        self.worktreeRoot = worktreeRoot
        self.allowAPIKeyFallback = allowAPIKeyFallback

        let (stream, continuation) = AsyncStream<CoreEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.continuation = continuation
    }

    // MARK: - Command dispatch

    public func send(_ command: CoreCommand) async {
        do {
            try await dispatch(command)
        } catch {
            // A failed command is reported, never thrown across the boundary:
            // the UI gets a message it can show rather than an exception it
            // has to model.
            continuation.yield(.commandFailed(CommandFailure(
                workspaceID: command.workspaceID,
                message: describe(error),
                detail: String(describing: error)
            )))
        }
    }

    private func dispatch(_ command: CoreCommand) async throws {
        switch command {
        case .addRepository(let path):
            try await addRepository(path: path)

        case .createProject(let request):
            _ = try await createProject(request)

        case .createWorkspace(let request):
            try await createWorkspace(request)

        case .archiveWorkspace(let id):
            try await archiveWorkspace(id)

        case .unarchiveWorkspace(let id):
            try await unarchiveWorkspace(id)

        case .deleteWorkspace(let id, let deleteBranch):
            try await deleteWorkspace(id, deleteBranch: deleteBranch)

        case .renameWorkspace(let id, let name, let userInitiated):
            try await engine(for: id).rename(name, userInitiated: userInitiated)
            markListMutation()

        case .setWorkspacePinned(let id, let pinned):
            try await engine(for: id).setPinned(pinned)
            markListMutation()

        case .addDiffComment(let id, let reference):
            try await engine(for: id).addDiffComment(reference)

        case .clearDiffComments(let id, let references):
            try await engine(for: id).clearDiffComments(references)

        case .markFileViewed(let id, let path, let contentHash):
            if let contentHash {
                try await store.markViewed(ViewedFileRecord(
                    workspaceID: id, filePath: path, contentHash: contentHash
                ))
            } else {
                try await store.unmarkViewed(workspaceID: id, filePath: path)
            }

        case .commit(let id, let message):
            try await commit(id, message: message)

        case .createGitHubRepo(let id):
            try await createGitHubRepo(id)

        case .push(let id):
            try await push(id)

        case .createPullRequest(let id, let title, let body, let base, let draft):
            _ = try await createPullRequest(id, title: title, body: body, base: base, draft: draft)

        case .retargetPullRequest(let id, let number, let base):
            try await retargetPullRequest(id, number: number, base: base)

        case .mergePullRequest(let id, let method):
            try await mergePullRequest(id, method: method)

        case .continueAfterMerge(let id):
            try await engine(for: id).continueAfterMerge()
            try await resync(id)

        case .pullDefaultBranch(let id):
            try await engine(for: id).pullDefaultBranch()
            try await resync(id)

        case .resolveConflict(let id, let path, let side):
            guard let conflictSide = ConflictSide(rawValue: side) else { return }
            try await engine(for: id).resolveConflict(path: path, side: conflictSide)
            try await resync(id)

        case .resolveConflictHunk(let id, let path, let startLine, let side):
            guard let conflictSide = ConflictSide(rawValue: side) else { return }
            try await engine(for: id).resolveConflictHunk(
                path: path, startLine: startLine, side: conflictSide
            )
            try await resync(id)

        case .rerunFailedChecks(let id):
            try await engine(for: id).rerunFailedChecks()

        case .createChat(let request):
            let chat = try await engine(for: request.workspaceID).createChat(request)
            markListMutation()
            continuation.yield(.chatAdded(chat))

        case .renameChat(let id, let chatID, let title, let userInitiated):
            _ = try await engine(for: id).renameChat(
                chatID, title: title, userInitiated: userInitiated
            )
            markListMutation()

        case .closeChat(let workspaceID, let chatID):
            let chat = try await engine(for: workspaceID).closeChat(chatID)
            markListMutation()
            continuation.yield(.chatUpdated(chat))

        case .reopenChat(let workspaceID, let chatID):
            let chat = try await engine(for: workspaceID).closeChat(chatID, closed: false)
            markListMutation()
            continuation.yield(.chatUpdated(chat))

        case .switchChatHarness(let workspaceID, let chatID, let harness, let model):
            let chat = try await engine(for: workspaceID).switchHarness(
                chatID: chatID, harness: harness, model: model
            )
            continuation.yield(.chatUpdated(chat))

        case .setChatModel(let workspaceID, let chatID, let model):
            let chat = try await engine(for: workspaceID).setModel(chatID: chatID, model: model)
            continuation.yield(.chatUpdated(chat))

        case .setChatDraft(let workspaceID, let chatID, let text):
            let chat = try await engine(for: workspaceID).setDraft(chatID: chatID, text: text)
            continuation.yield(.chatUpdated(chat))

        case .listChats(let workspaceID):
            try await listChats(workspaceID)

        case .sendMessage(let request):
            let engine = try await engine(for: request.workspaceID)
            _ = try await engine.send(request)

        case .interruptTurn(let id):
            try await engine(for: id).interrupt()

        case .interruptChatTurn(let id, let chatID):
            try await engine(for: id).interrupt(chatID: chatID)

        case .setPermissionMode(let id, let mode):
            try await engine(for: id).setPermissionMode(mode)

        case .setChatPermissionMode(let id, let chatID, let mode):
            try await engine(for: id).setPermissionMode(mode, chatID: chatID)

        case .setChatEffort(let id, let chatID, let effort):
            let chat = try await engine(for: id).setEffort(chatID: chatID, effort: effort)
            continuation.yield(.chatUpdated(chat))

        case .resolvePermission(let id, let requestID, let decision):
            try await engine(for: id).resolvePermission(requestID, with: decision)

        case .resolveChatPermission(let id, let chatID, let requestID, let decision, let automatic):
            try await engine(for: id).resolvePermission(
                requestID, with: decision, chatID: chatID, automatic: automatic
            )

        case .answerQuestion(let id, let questionID, let answer):
            try await engine(for: id).answerQuestion(questionID, answer: answer)

        case .answerChatQuestion(let id, let chatID, let questionID, let answer):
            try await engine(for: id).answerQuestion(
                questionID, answer: answer, chatID: chatID
            )

        case .revertToCheckpoint(let id, let turnID):
            try await engine(for: id).revert(to: turnID)

        case .revertChatToCheckpoint(let id, let chatID, let turnID):
            try await engine(for: id).revert(to: turnID, chatID: chatID)

        case .startSession(let id, let request):
            _ = try await engine(for: id).ensureSession(request)

        case .startChatSession(let id, let chatID, let request):
            _ = try await engine(for: id).ensureSession(request, chatID: chatID)

        case .stopSession(let id):
            try await engine(for: id).stopSession()

        case .stopChatSession(let id, let chatID):
            try await engine(for: id).stopSession(chatID: chatID)

        case .resolveAssistantConfirmation(let id, let decision):
            resolveAssistantConfirmation(id: id, decision: decision)

        case .updateDreamSettings(let settings):
            try await applyDreamSettings(settings)

        case .updateDreamEnvironment(let snapshot):
            try await applyDreamEnvironment(snapshot)

        case .startDreamRun(let manual, let repositoryPath):
            try await beginDreamRun(manual: manual, repositoryPath: repositoryPath)

        case .abortDreamRun:
            try await abortActiveDreamRun()

        case .resolveDreamFinding(let id, let resolution):
            try await resolveDreamFinding(id, resolution)

        case .listDreamFindings:
            try await publishDreamInbox()

        case .probeHarnesses:
            async let probes = harnessRegistry.probeAll()
            async let catalogs = harnessRegistry.discoverAllModels()
            harnessProbes = await probes
            continuation.yield(.harnessProbeCompleted(harnessProbes))
            for (harness, models) in await catalogs {
                recordModels(models, for: harness)
            }
            await reconcileAssistantConfiguration()

        case .checkHarnessUpdates(let force):
            await checkHarnessUpdates(force: force)

        case .resync(let id):
            try await resync(id)
        }
    }

    // MARK: - Startup

    /// Loads persisted state and starts an engine per workspace.
    ///
    /// Everything is restored, including sessions: switching to a workspace
    /// after a relaunch should show the conversation the user left, not an
    /// empty one.
    public func start() async throws {
        // Pay the login-shell probe now, off the critical path, so the first
        // agent launch doesn't stall on it.
        ShellEnvironment.warm()

        // The product's own hidden workspace. Ensured before the engines load
        // so it starts — and resumes its session — exactly like any other
        // workspace; `store.workspaces()` below deliberately excludes it.
        if let assistant = ((try? await AssistantManager.ensureAssistant(store: store)) ?? nil) {
            _ = try? await makeEngine(for: assistant)
            startAssistantBridge()
        }

        for record in try await store.workspaces() {
            _ = try? await makeEngine(for: record)
        }
        try await restoreOrphanedDreams()
        try await resync(nil)

        Task { [weak self] in
            guard let self else { return }
            async let probes = self.harnessRegistry.probeAll()
            async let catalogs = self.harnessRegistry.discoverAllModels()
            await self.recordProbes(probes)
            for (harness, models) in await catalogs {
                await self.recordModels(models, for: harness)
            }
            await self.reconcileAssistantConfiguration()
            // Behind the probe, and behind everything the user is waiting for:
            // whether Codex shipped a point release is never worth a slower
            // launch, and the card can appear a second late.
            await self.checkHarnessUpdates(force: false)
        }
    }

    private func recordProbes(_ probes: [HarnessProbeResult]) {
        harnessProbes = probes
        continuation.yield(.harnessProbeCompleted(probes))
    }

    private func recordModels(_ models: [AgentModel], for harness: HarnessKind) {
        guard !models.isEmpty else { return }
        modelCatalog[harness] = models
        continuation.yield(.modelCatalogUpdated(harness, models))
    }

    /// How long a check holds. Agent CLIs ship most days, not most minutes, and
    /// every window that opens would otherwise re-hit three registries.
    static let harnessUpdateCheckInterval: TimeInterval = 6 * 60 * 60

    /// Asks each installed harness's install channel for its published version.
    ///
    /// Network work, so it runs concurrently and swallows its own failures: a
    /// harness whose registry is unreachable reports that on its status row and
    /// nothing else in the app notices.
    func checkHarnessUpdates(force: Bool) async {
        guard !harnessUpdateCheckInFlight else { return }
        if !force, let last = lastHarnessUpdateCheck,
           Date().timeIntervalSince(last) < Self.harnessUpdateCheckInterval {
            return
        }
        let installed = harnessProbes.filter(\.isInstalled)
        guard !installed.isEmpty else { return }

        harnessUpdateCheckInFlight = true
        defer { harnessUpdateCheckInFlight = false }

        let statuses = await withTaskGroup(of: HarnessUpdateStatus.self) { group in
            for probe in installed {
                group.addTask {
                    await HarnessUpdateChecker.check(
                        kind: probe.kind,
                        installedVersion: probe.version,
                        executablePath: probe.executablePath
                    )
                }
            }
            var results: [HarnessUpdateStatus] = []
            for await status in group { results.append(status) }
            return results
        }
        // Only a check that actually reached a channel spends the throttle. A
        // laptop that launched offline should find out when it reconnects, not
        // in six hours.
        if statuses.contains(where: { $0.failure == nil }) {
            lastHarnessUpdateCheck = Date()
        }
        harnessUpdates = statuses.sorted { $0.kind.rawValue < $1.kind.rawValue }
        continuation.yield(.harnessUpdatesChecked(harnessUpdates))
    }

    func resync(_ id: WorkspaceID?) async throws {
        let revision = listRevision
        if let id {
            let engine = try await engine(for: id)
            let summary = await engine.summary()
            guard revision == listRevision else {
                try await resync(id)
                return
            }
            continuation.yield(.workspaceUpdated(summary))
            return
        }

        var summaries: [WorkspaceSummary] = []
        var chats: [ChatSummary] = []
        // The assistant rides the snapshot too — tagged by kind, so the app
        // can route it to the Assistant window instead of the sidebar.
        for record in try await store.workspaces(includeArchived: true, includeAssistant: true) {
            if let engine = engines[record.workspaceID] {
                summaries.append(await engine.summary())
                chats.append(contentsOf: (try? await engine.chatSummaries()) ?? [])
            } else {
                summaries.append(record.summary())
                chats.append(contentsOf: (try? await store.chats(
                    workspaceID: record.workspaceID
                ).map { $0.summary() }) ?? [])
            }
        }
        let snapshot = CoreSnapshot(
            workspaces: summaries,
            chats: chats,
            harnesses: harnessProbes,
            harnessUpdates: harnessUpdates
        )
        #if DEBUG
        if let hook = beforeSnapshotEmission {
            beforeSnapshotEmission = nil
            await hook()
        }
        #endif
        guard revision == listRevision else {
            // A successful list mutation owns the newer truth. Rebuild instead
            // of publishing this stale cache; retrying also guarantees a cold
            // client still receives every pre-existing row.
            try await resync(nil)
            return
        }
        continuation.yield(.snapshot(snapshot))
    }

    private func listChats(_ workspaceID: WorkspaceID) async throws {
        let revision = listRevision
        let chats = try await engine(for: workspaceID).chatSummaries()
        guard revision == listRevision else {
            try await listChats(workspaceID)
            return
        }
        continuation.yield(.chatsListed(workspaceID, chats))
    }

    func markListMutation() {
        listRevision &+= 1
    }

    #if DEBUG
    func pauseBeforeNextSnapshotEmission(_ hook: @escaping @Sendable () async -> Void) {
        beforeSnapshotEmission = hook
    }
    #endif

    // MARK: - Repositories

    func addRepository(path: String) async throws {
        let root = try await canonicalRepositoryURL(path)
        let git = try gitClient(for: root.path)

        try await store.addRepository(RepositoryRecord(
            path: root.path,
            name: root.lastPathComponent,
            defaultBranch: await git.defaultBranch()
        ))
        try await resync(nil)
    }

    /// What `createProject` made, for the caller that has to describe it.
    struct CreatedProject: Sendable {
        var repositoryPath: String
        var repositoryName: String
        var defaultBranch: String
        var workspace: WorkspaceRecord?
    }

    /// Start a project that doesn't exist yet: create the repository, register
    /// it, and open its first workspace.
    ///
    /// Registration goes through `addRepository` rather than straight to the
    /// store so the new path is canonicalized exactly like every other one —
    /// `~/ore` under a symlinked home, or a `/tmp` fixture, otherwise gets
    /// stored one way and looked up another, and the workspace that follows
    /// fails its foreign key.
    @discardableResult
    func createProject(_ request: CreateProjectRequest) async throws -> CreatedProject {
        let parent = request.parentDirectory
            .map { FilePath.expandingTildeURL($0).standardizedFileURL }
            ?? OreHome.directory.appendingPathComponent("repositories", isDirectory: true)

        let created = try await RepositoryInitializer.create(name: request.name, in: parent)
        try await addRepository(path: created.path.path)

        var project = CreatedProject(
            repositoryPath: created.path.path,
            repositoryName: created.path.lastPathComponent,
            defaultBranch: created.defaultBranch
        )
        guard request.createWorkspace else { return project }

        project.workspace = try await createWorkspace(CreateWorkspaceRequest(
            repositoryPath: created.path.path,
            // Falling back to the project's own name rather than nothing: an
            // empty name makes a worktree literally called "workspace", which
            // tells the user nothing in a sidebar.
            name: request.workspaceName ?? request.name,
            seed: .defaultBranch,
            harness: request.harness,
            model: request.model,
            initialPrompt: request.initialPrompt,
            promptOrigin: request.promptOrigin,
            branchPrefix: request.branchPrefix
        ))
        return project
    }

    /// The one true path for a repository.
    ///
    /// Everything keys off this — the `repository` row, each workspace's
    /// foreign key, the `GitClient` cache — so the same repo reached by two
    /// spellings has to resolve to one string. On macOS that is not a nicety:
    /// `/tmp` is a symlink to `/private/tmp`, and a home directory can be too,
    /// so "add the repo, then make a workspace in it" would otherwise fail on a
    /// foreign key the user has no way to understand.
    func canonicalRepositoryURL(_ path: String) async throws -> URL {
        let expanded = FilePath.expandingTildeURL(path).standardizedFileURL

        // `git rev-parse --show-toplevel` both resolves symlinks and turns a
        // path inside the repository into the repository itself.
        if let git = try? GitClient(repositoryURL: expanded),
           let root = try? await git.topLevel() {
            return root.standardizedFileURL
        }
        return expanded.resolvingSymlinksInPath()
    }

    // MARK: - Workspaces

    @discardableResult
    func createWorkspace(_ request: CreateWorkspaceRequest) async throws -> WorkspaceRecord {
        let repositoryPath = try await canonicalRepositoryURL(request.repositoryPath)
        guard try await store.repositories().contains(where: { $0.path == repositoryPath.path })
        else {
            throw OreCoreError.repositoryNotFound(repositoryPath.path)
        }
        let git = try gitClient(for: repositoryPath.path)
        let configuration = OreConfiguration.load(repositoryPath: repositoryPath)
        let defaultBranch = await git.defaultBranch()

        var name = request.name
        var initialPrompt = request.initialPrompt
        var baseRevision = defaultBranch
        var baseBranch = defaultBranch
        var stackedOn: WorkspaceID?

        switch request.seed {
        case .defaultBranch:
            break

        case .branch(let branch):
            baseRevision = branch
            baseBranch = branch

        case .workspace(let parentID):
            // Stacking: branch from the parent's head, and target its branch
            // when the PR is opened. This is the natural output shape of
            // sequential agent work.
            guard let parent = try await store.workspace(parentID) else {
                throw OreCoreError.workspaceNotFound(parentID)
            }
            baseRevision = parent.branch
            baseBranch = parent.branch
            stackedOn = parentID

        case .githubIssue(let number):
            let gitHub = GitHubClient(repositoryURL: repositoryPath)
            let issue = try await gitHub.issue(number: number)
            if name.isEmpty { name = "#\(issue.number) \(issue.title)" }
            initialPrompt = initialPrompt ?? """
            Work on GitHub issue #\(issue.number): \(issue.title)

            \(issue.body)

            \(issue.url)
            """

        case .githubPullRequest(let number):
            let gitHub = GitHubClient(repositoryURL: repositoryPath)
            let pullRequest = try await gitHub.pullRequestSeed(number: number)
            if name.isEmpty { name = "PR #\(pullRequest.number) \(pullRequest.title)" }
            if let head = pullRequest.headRefName {
                baseRevision = head
            }
            initialPrompt = initialPrompt ?? """
            Continue work on PR #\(pullRequest.number): \(pullRequest.title)

            \(pullRequest.body)

            \(pullRequest.url)
            """
        }

        // Scientist identities are product-level workspace identities, so two
        // concurrent creation paths (UI, CLI, or restored sheet) must not pick
        // the same one. WorktreeManager still guarantees path uniqueness for
        // arbitrary custom names; this preserves the curated identity pool.
        if ResearchIdentity.matching(nameOrSlug: name) != nil {
            let existing = try await store.workspaces()
            let used = Set(existing.flatMap { record in
                [record.name, URL(fileURLWithPath: record.worktreePath).lastPathComponent]
            })
            if used.contains(where: {
                $0.caseInsensitiveCompare(name) == .orderedSame
                    || ResearchIdentity.slugify($0) == ResearchIdentity.slugify(name)
            }) {
                name = ResearchIdentity.next(excluding: used).name
            }
        }

        let manager = WorktreeManager(git: git, root: worktreeRoot)
        let worktree = try await manager.create(WorktreeManager.CreateRequest(
            name: name.isEmpty ? "workspace" : name,
            branchPrefix: request.branchPrefix ?? configuration.branchPrefix,
            baseRevision: baseRevision,
            baseBranch: baseBranch,
            filesToCopy: configuration.filesToCopy
        ))

        let record = WorkspaceRecord(
            id: WorkspaceID.generate(),
            name: name.isEmpty ? worktree.path.lastPathComponent : name,
            repositoryPath: repositoryPath.path,
            worktreePath: worktree.path.path,
            branch: worktree.branch,
            baseBranch: worktree.baseBranch,
            stackedOnWorkspaceID: stackedOn,
            harness: request.harness,
            model: request.model ?? configuration.defaultModel
        )
        try await store.saveWorkspace(record)
        _ = try await store.ensureDefaultChat(for: record)

        if !worktree.missingCopies.isEmpty {
            // Not fatal, but the user needs to know: a missing `.env` shows up
            // as a mysterious build failure ten minutes later otherwise.
            continuation.yield(.commandFailed(CommandFailure(
                workspaceID: record.workspaceID,
                message: "Some files couldn't be copied into the worktree.",
                detail: worktree.missingCopies.joined(separator: ", ")
            )))
        }

        let engine = try await makeEngine(for: record)
        markListMutation()
        continuation.yield(.workspaceAdded(await engine.summary()))

        if let setup = configuration.scripts.setup {
            await runScript(setup, in: worktree.path, workspaceID: record.workspaceID)
        }
        if let initialPrompt, !initialPrompt.isEmpty {
            _ = try? await engine.send(SendMessageRequest(
                workspaceID: record.workspaceID,
                text: initialPrompt,
                queueIfBusy: false,
                origin: request.promptOrigin
            ))
        }
        return record
    }

    func archiveWorkspace(_ id: WorkspaceID) async throws {
        guard let record = try await store.workspace(id) else {
            throw OreCoreError.workspaceNotFound(id)
        }
        guard record.workspaceKind != .assistant else {
            throw OreCoreError.assistantWorkspaceProtected
        }
        let configuration = OreConfiguration.load(
            repositoryPath: URL(fileURLWithPath: record.repositoryPath)
        )
        let worktree = URL(fileURLWithPath: record.worktreePath)

        // Archive scripts stop containers and free ports; they have to run
        // before the checkout disappears out from under them.
        if let archiveScript = configuration.scripts.archive {
            await runScript(archiveScript, in: worktree, workspaceID: id)
        }

        await stopEngine(id)

        // Measure the checkout before it disappears — the reclaimed space is
        // exactly what the archived browser reports back to the user.
        let reclaimedBytes = await Task.detached(priority: .utility) {
            Self.directorySize(at: worktree)
        }.value

        let git = try gitClient(for: record.repositoryPath)
        let manager = WorktreeManager(git: git, root: worktreeRoot)
        let preservedCommit = try await manager.archive(at: worktree, workspaceID: id)

        guard let updated = try await store.updateWorkspace(id, { record in
            record.isArchived = true
            record.archivedStateCommit = preservedCommit
            record.archivedAt = Date()
            record.archivedDiskBytes = reclaimedBytes
        }) else {
            throw OreCoreError.workspaceNotFound(id)
        }
        markListMutation()
        // Publish the committed row directly. A whole snapshot is slower and,
        // because building it suspends on every engine, used to be able to
        // arrive out of order with another mutation.
        continuation.yield(.workspaceUpdated(updated.summary()))
    }

    /// Total allocated size of a directory tree. Best-effort: unreadable
    /// entries are skipped rather than failing the archive.
    private nonisolated static func directorySize(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    func unarchiveWorkspace(_ id: WorkspaceID) async throws {
        guard let record = try await store.workspace(id) else {
            throw OreCoreError.workspaceNotFound(id)
        }
        let git = try gitClient(for: record.repositoryPath)
        let worktree = URL(fileURLWithPath: record.worktreePath)

        try await git.runSerialized(["worktree", "add", worktree.path, record.branch])

        // Uncommitted work was preserved on a ref at archive time; put the user
        // back exactly where they left off, not merely on the right branch.
        if let commit = record.archivedStateCommit {
            try? await git.runSerialized(
                ["restore", "--worktree", "--source", commit, "--", "."],
                in: worktree
            )
        }

        let updated = try await store.updateWorkspace(id) { record in
            record.isArchived = false
            record.archivedStateCommit = nil
            record.archivedAt = nil
            record.archivedDiskBytes = nil
        }
        if let updated {
            let engine = try await makeEngine(for: updated)
            markListMutation()
            continuation.yield(.workspaceUpdated(await engine.summary()))
        }
    }

    func deleteWorkspace(_ id: WorkspaceID, deleteBranch: Bool) async throws {
        guard let record = try await store.workspace(id) else {
            throw OreCoreError.workspaceNotFound(id)
        }
        guard record.workspaceKind != .assistant else {
            throw OreCoreError.assistantWorkspaceProtected
        }
        await stopEngine(id)

        let git = try gitClient(for: record.repositoryPath)
        let manager = WorktreeManager(git: git, root: worktreeRoot)
        try? await manager.remove(
            at: URL(fileURLWithPath: record.worktreePath),
            deleteBranch: deleteBranch ? record.branch : nil,
            force: true
        )
        // ORE's own refs must not outlive the thing they describe. The archive
        // ref lives outside the checkpoint namespace, so it needs its own
        // cleanup or it would pin the archived tree in the repository forever.
        try? await CheckpointStore(git: git).removeAll(workspaceID: id)
        try? await git.runSerialized(["update-ref", "-d", "refs/ore/archive/\(id.rawValue)"])

        try await store.deleteWorkspace(id)
        markListMutation()
        continuation.yield(.workspaceRemoved(id))
    }

    private func workspaceAndGit(_ id: WorkspaceID) async throws -> (WorkspaceRecord, GitClient, URL) {
        guard let record = try await store.workspace(id) else {
            throw OreCoreError.workspaceNotFound(id)
        }
        return (
            record,
            try gitClient(for: record.repositoryPath),
            URL(fileURLWithPath: record.worktreePath)
        )
    }

    func commit(_ id: WorkspaceID, message: String) async throws {
        let (_, git, worktree) = try await workspaceAndGit(id)
        try await git.runSerialized(["add", "-A"], in: worktree)
        try await git.runSerialized([
            "commit", "-m", message.trimmingCharacters(in: .whitespacesAndNewlines)
        ], in: worktree)
        try await resync(id)
    }

    func push(_ id: WorkspaceID) async throws {
        let (record, git, worktree) = try await workspaceAndGit(id)
        try await git.runSerialized(["push", "-u", "origin", record.branch], in: worktree)
        try await resync(id)
    }

    /// Creates a GitHub repo from the canonical checkout and publishes its base
    /// branch. Sourcing from `repositoryPath` (which sits on the base branch)
    /// means GitHub's default branch is the base — the branch PRs target — and
    /// leaves the workspace's own branch to the normal "Publish branch" step
    /// that follows once a remote exists.
    func createGitHubRepo(_ id: WorkspaceID) async throws {
        let (record, _, _) = try await workspaceAndGit(id)
        let name = (record.repositoryPath as NSString).lastPathComponent
        let github = GitHubClient(repositoryURL: URL(fileURLWithPath: record.repositoryPath))
        try await github.createRepository(name: name, sourcePath: record.repositoryPath)
        try await resync(id)
    }

    @discardableResult
    func createPullRequest(
        _ id: WorkspaceID, title: String, body: String, base: String, draft: Bool
    ) async throws -> String {
        let (record, git, worktree) = try await workspaceAndGit(id)
        // Publishing is part of opening a PR now, not a step before it: `gh pr
        // create --head` needs the branch on the remote, so push (and set
        // upstream) first. This is a no-op — "Everything up-to-date" — when the
        // branch is already published, so it stays safe to re-run.
        try await git.runSerialized(["push", "-u", "origin", record.branch], in: worktree)
        let github = GitHubClient(repositoryURL: URL(fileURLWithPath: record.repositoryPath))
        let url = try await github.createPullRequest(
            branch: record.branch,
            base: base.isEmpty ? record.baseBranch : base,
            title: title.isEmpty ? record.name : title,
            body: body,
            draft: draft
        )
        try await resync(id)
        return url
    }

    /// Remote branches available as a PR base, for the review pane's picker.
    public func remoteBranches(workspaceID id: WorkspaceID) async -> [String] {
        guard let (_, git, _) = try? await workspaceAndGit(id) else { return [] }
        return await git.remoteBranches()
    }

    /// The open PR's URL for a workspace's branch, if one exists (for "View on
    /// GitHub").
    public func pullRequestURL(workspaceID id: WorkspaceID) async -> String? {
        guard let (record, _, _) = try? await workspaceAndGit(id) else { return nil }
        let github = GitHubClient(repositoryURL: URL(fileURLWithPath: record.repositoryPath))
        return await github.pullRequest(forBranch: record.branch)?.url
    }

    func retargetPullRequest(_ id: WorkspaceID, number: Int, base: String) async throws {
        let (record, _, _) = try await workspaceAndGit(id)
        try await GitHubClient(repositoryURL: URL(fileURLWithPath: record.repositoryPath))
            .retargetPullRequest(number: number, to: base)
        try await resync(id)
    }

    func mergePullRequest(_ id: WorkspaceID, method: String) async throws {
        let (record, _, _) = try await workspaceAndGit(id)
        let github = GitHubClient(repositoryURL: URL(fileURLWithPath: record.repositoryPath))
        guard let pr = await github.pullRequest(forBranch: record.branch) else {
            throw OreCoreError.noPullRequest(record.branch)
        }
        let mergeMethod = GitHubClient.MergeMethod(rawValue: method) ?? .squash
        // Keep the branch: archive is a separate, explicit action so the
        // worktree stays until the user presses Archive.
        try await github.merge(number: pr.number, method: mergeMethod, deleteBranch: false)
        try await resync(id)
    }

    // MARK: - Engines

    func engine(for id: WorkspaceID) async throws -> WorkspaceEngine {
        if let engine = engines[id] { return engine }
        guard let record = try await store.workspace(id) else {
            throw OreCoreError.workspaceNotFound(id)
        }
        return try await makeEngine(for: record)
    }

    @discardableResult
    func makeEngine(for record: WorkspaceRecord) async throws -> WorkspaceEngine {
        if let existing = engines[record.workspaceID] { return existing }

        let git = try gitClient(for: record.repositoryPath)
        let engine = WorkspaceEngine(
            record: record,
            store: store,
            git: git,
            harnessRegistry: harnessRegistry,
            allowAPIKeyFallback: allowAPIKeyFallback
        )
        engines[record.workspaceID] = engine

        // Each engine's streams are tagged with the workspace and merged into
        // one ordered feed, so the client has a single source of truth rather
        // than N it has to reconcile.
        let id = record.workspaceID
        let agentTask = Task { [weak self] in
            for await routed in engine.events {
                guard !Task.isCancelled, let self else { return }
                await self.publishFromActiveEngine(
                    .agent(id, routed.chatID, routed.event), id: id, engine: engine
                )
                await self.recordHarnessRateLimit(
                    chatID: routed.chatID, event: routed.event
                )
                // The Assistant is the product's own agent. A rate-limited or
                // dead CLI must not mute it while another harness is ready.
                // Project tabs keep their harness; only this workspace moves.
                await self.noteDreamHarnessRateLimit(
                    harness: HarnessKind(rawValue: record.harness) ?? .claudeCode,
                    event: routed.event
                )
                if engine.isAssistantWorkspace {
                    await self.considerAssistantFailover(
                        chatID: routed.chatID, event: routed.event
                    )
                }
            }
        }
        let summaryTask = Task { [weak self] in
            for await summary in await engine.summaryUpdates() {
                guard !Task.isCancelled, let self else { return }
                await self.publishFromActiveEngine(
                    .workspaceUpdated(summary), id: id, engine: engine
                )
            }
        }
        let chatTask = Task { [weak self] in
            for await chat in await engine.chatUpdates() {
                guard !Task.isCancelled, let self else { return }
                await self.publishFromActiveEngine(
                    .chatUpdated(chat), id: id, engine: engine
                )
            }
        }
        let gitTask = Task { [weak self] in
            for await status in await engine.gitStatusUpdates() {
                guard !Task.isCancelled, let self else { return }
                await self.publishFromActiveEngine(
                    .gitStatusChanged(id, status), id: id, engine: engine
                )
            }
        }
        let promptTask = Task { [weak self, continuation] in
            for await routed in await engine.promptSubmissions() {
                guard self != nil else { return }
                continuation.yield(.promptSubmitted(id, routed.chatID, routed.submission))
            }
        }
        let compactionTask = Task { [weak self, continuation] in
            for await seam in await engine.conversationCompactions() {
                guard self != nil else { return }
                continuation.yield(
                    .assistantConversationCompacted(id, from: seam.from, to: seam.to)
                )
            }
        }
        engineTasks[id] = [agentTask, summaryTask, chatTask, gitTask, promptTask, compactionTask]

        await engine.start()
        return engine
    }

    func recordHarnessRateLimit(chatID: ChatID, event: AgentEvent) async {
        guard let chat = try? await store.chat(chatID),
              let harness = HarnessKind(rawValue: chat.harness)
        else { return }

        let report: RateLimitReport
        switch event {
        case .rateLimit(let value):
            report = value
        case .turnCompleted(let result) where result.outcome != .failed:
            // A successful turn is stronger evidence than an older exhausted
            // snapshot, including one whose provider supplied no reset time.
            harnessRateLimits.removeValue(forKey: harness)
            return
        case .sessionError, .turnCompleted:
            guard AssistantFailoverPolicy.reason(for: event) == .rateLimited else { return }
            let previous = harnessRateLimits[harness]?.report
            report = RateLimitReport(
                status: .exhausted,
                window: previous?.window,
                resetsAt: previous?.resetsAt
            )
        default:
            return
        }

        harnessRateLimits[harness] = HarnessRateLimitObservation(
            report: report, observedAt: Date(), chatID: chatID
        )
    }

    /// Returns only a still-relevant observation. Warning/exhausted snapshots
    /// expire at their provider reset time; allowed/unknown remain useful as
    /// the latest observation but never exclude a harness.
    func harnessRateLimit(
        _ harness: HarnessKind,
        now: Date = Date()
    ) -> HarnessRateLimitObservation? {
        guard let observation = harnessRateLimits[harness] else { return nil }
        if (observation.report.status == .warning
                || observation.report.status == .exhausted),
           !observation.report.applies(at: now) {
            harnessRateLimits.removeValue(forKey: harness)
            return nil
        }
        return observation
    }

    /// A stopped engine still owns buffered AsyncStream elements. Validate its
    /// identity on the core actor before forwarding them so an archived
    /// workspace's cached summary cannot overwrite the committed archive row.
    private func publishFromActiveEngine(
        _ event: CoreEvent,
        id: WorkspaceID,
        engine: WorkspaceEngine
    ) {
        guard engines[id] === engine else { return }
        continuation.yield(event)
    }

    private func stopEngine(_ id: WorkspaceID) async {
        if let engine = engines.removeValue(forKey: id) {
            await engine.stop()
        }
        engineTasks.removeValue(forKey: id)?.forEach { $0.cancel() }
    }

    public func shutdown() async {
        stopAssistantBridge()
        for id in engines.keys {
            await stopEngine(id)
        }
        continuation.finish()
    }

    // MARK: - Scripts

    /// Runs a lifecycle script in the worktree, through the user's login shell
    /// so their version managers and aliases apply.
    private func runScript(_ script: String, in directory: URL, workspaceID: WorkspaceID) async {
        let shell = ShellEnvironment.loginShellPath
        let process: ChildProcess
        do {
            process = try ChildProcess(
                executablePath: shell,
                arguments: ShellEnvironment.commandArguments(for: shell, script: script),
                workingDirectory: directory,
                environment: ShellEnvironment.childEnvironment()
            )
        } catch {
            // Silently returning here is how a setup script that never ran
            // looked identical to one that succeeded — the worktree just came
            // up missing whatever it was supposed to create.
            continuation.yield(.commandFailed(CommandFailure(
                workspaceID: workspaceID,
                message: "The setup script couldn't be started.",
                detail: "\(shell): \(describe(error))"
            )))
            return
        }
        process.closeStandardInput()

        let output = await process.stdoutChunks.collectText()
        let status = await process.waitForExit()
        guard status != 0 else { return }

        continuation.yield(.commandFailed(CommandFailure(
            workspaceID: workspaceID,
            message: "The setup script failed (status \(status)).",
            detail: String(output.suffix(4000))
        )))
    }

    // MARK: - Helpers

    func gitClient(for path: String) throws -> GitClient {
        if let existing = gitClients[path] { return existing }
        let client = try GitClient(repositoryURL: URL(fileURLWithPath: path))
        gitClients[path] = client
        return client
    }

    private func describe(_ error: any Error) -> String {
        (error as? CustomStringConvertible)?.description ?? error.localizedDescription
    }

    // MARK: - Direct reads
    //
    // The command/event pair carries state changes. Reads that are request/
    // response by nature — "give me the diff for this file" — would be awkward
    // as an event round trip, so they're plain async calls the in-process
    // client answers directly. A remote client would answer them over the same
    // socket with a request id.

    public func diff(workspaceID: WorkspaceID, againstBase: Bool = true) async throws -> [FileDiff] {
        try await engine(for: workspaceID).diff(againstBase: againstBase)
    }

    public func suggestedGitAction(workspaceID: WorkspaceID) async throws -> SuggestedGitAction {
        try await engine(for: workspaceID).suggestedGitAction()
    }

    public func suggestedGitStatus(workspaceID: WorkspaceID) async throws -> SuggestedGitStatus {
        try await engine(for: workspaceID).suggestedGitStatus()
    }

    /// Commits not yet on the upstream (or, without one, not on the base).
    public func unpushedCommits(workspaceID: WorkspaceID) async throws -> [CommitInfo] {
        try await engine(for: workspaceID).unpushedCommits()
    }

    public func workingTreeStatus(workspaceID: WorkspaceID) async -> GitStatusSnapshot? {
        try? await engine(for: workspaceID).workingTreeStatus()
    }

    /// The branch's PR with live check runs; nil when gh is missing,
    /// unauthenticated, or no PR exists.
    public func pullRequestStatus(workspaceID: WorkspaceID) async throws -> GitHubClient.PullRequest? {
        try await engine(for: workspaceID).currentPullRequest()
    }

    public func conflictHunks(workspaceID: WorkspaceID, path: String) async throws -> [ConflictHunk] {
        try await engine(for: workspaceID).conflictHunks(path: path)
    }

    public func turnCheckpoints(workspaceID: WorkspaceID, chatID: ChatID) async throws -> [TurnCheckpoint] {
        try await engine(for: workspaceID).turnCheckpoints(chatID: chatID)
    }

    public func lastTurnDigest(workspaceID: WorkspaceID, chatID: ChatID) async throws -> String? {
        try await engine(for: workspaceID).lastTurnDigest(chatID: chatID)
    }

    public func diffFromCheckpoint(
        workspaceID: WorkspaceID,
        commit: String
    ) async throws -> [FileDiff] {
        try await engine(for: workspaceID).diffFromCheckpoint(commit)
    }

    public func diffBetweenCheckpoints(
        workspaceID: WorkspaceID,
        from: String,
        to: String
    ) async throws -> [FileDiff] {
        try await engine(for: workspaceID).diffBetweenTurnCheckpoints(from: from, to: to)
    }

    public func checkLog(workspaceID: WorkspaceID, named name: String) async -> String? {
        try? await engine(for: workspaceID).checkLog(named: name)
    }

    public func stackNeighbors(
        workspaceID: WorkspaceID
    ) async throws -> (parent: WorkspaceSummary?, children: [WorkspaceSummary]) {
        let (parent, children) = try await engine(for: workspaceID).stackNeighbors()
        return (parent?.summary(), children.map { $0.summary() })
    }

    public func localBranches(workspaceID id: WorkspaceID) async -> [String] {
        guard let (_, git, _) = try? await workspaceAndGit(id) else { return [] }
        return await git.localBranches()
    }

    public func localBranches(repositoryPath: String) async -> [String] {
        guard let git = try? GitClient(repositoryURL: URL(fileURLWithPath: repositoryPath)) else {
            return []
        }
        return await git.localBranches()
    }

    public func githubIssues(repositoryPath: String) async throws -> [GitHubClient.IssueListItem] {
        try await GitHubClient(repositoryURL: URL(fileURLWithPath: repositoryPath)).issues()
    }

    public func githubPullRequests(repositoryPath: String) async throws -> [GitHubClient.IssueListItem] {
        try await GitHubClient(repositoryURL: URL(fileURLWithPath: repositoryPath)).pullRequests()
    }

    public func addDiffComment(
        workspaceID: WorkspaceID,
        _ reference: DiffCommentReference
    ) async throws {
        try await engine(for: workspaceID).addDiffComment(reference)
    }

    public func pendingDiffComments(
        workspaceID: WorkspaceID
    ) async throws -> [DiffCommentReference] {
        try await engine(for: workspaceID).pendingDiffComments()
    }

    public func viewedFiles(workspaceID: WorkspaceID) async throws -> [String: String] {
        try await store.viewedFiles(workspaceID: workspaceID)
    }

    public func queuedMessages(chatID: ChatID) async throws -> [QueuedMessageRecord] {
        try await store.queuedMessages(chatID: chatID)
    }

    public func updateQueuedMessage(id: Int64, text: String) async throws {
        try await store.updateQueuedMessage(id: id, text: text)
    }

    public func deleteQueuedMessage(id: Int64) async throws {
        try await store.deleteQueuedMessage(id: id)
    }

    public func forwardFailingChecks(workspaceID: WorkspaceID) async throws {
        try await engine(for: workspaceID).forwardFailingChecks()
    }

    public func setFocused(workspaceID: WorkspaceID, focused: Bool) async throws {
        try await engine(for: workspaceID).setFocused(focused)
    }

    public func setFocused(
        workspaceID: WorkspaceID,
        chatID: ChatID,
        focused: Bool
    ) async throws {
        try await engine(for: workspaceID).setFocused(focused, chatID: chatID)
    }

    /// Compact live fleet state for the assistant: focused tab, open chats,
    /// chips, git dirt, and anything waiting on the user.
    public func assistantAppStateText() async -> String {
        var focusedLine = "focused: none"
        var blocks: [String] = []
        for (id, engine) in engines {
            let summary = await engine.summary()
            if !summary.isStandard { continue }
            let chats = (try? await engine.chatSummaries(includeClosed: false)) ?? []
            let focused = await engine.focusedChatIDValue()
            if let focused {
                let title = chats.first { $0.id == focused }?.title ?? focused.rawValue
                focusedLine = "focused: \(summary.name) / \(title) "
                    + "(workspaceID \(id.rawValue), chatID \(focused.rawValue))"
            }
            let git = await engine.gitStatusValue()
            // The repository, not just the workspace name: two workspaces on
            // the same repo are the same project and two on different repos
            // are the relation the assistant has to reason about. Without it
            // "kailash" and "kaguya" are indistinguishable siblings.
            let repository = URL(fileURLWithPath: summary.repositoryPath).lastPathComponent
            var lines: [String] = [
                "workspace \(summary.name) (\(id.rawValue)) repo \(repository) "
                    + "branch \(summary.branch) "
                    + "status \(summary.status.rawValue)"
                    + (git.hasUncommittedChanges
                        ? " dirty \(git.changedFileCount) files"
                        : "")
            ]
            for chat in chats {
                var chip = "  tab \"\(chat.title)\" (\(chat.id.rawValue)) "
                    + "\(chat.harness.rawValue)"
                    + (chat.model.map { "/\($0)" } ?? "")
                    + " mode=\(chat.permissionMode.rawValue)"
                    + (chat.reasoningEffort.map { " effort=\($0.rawValue)" } ?? "")
                    + " status=\(chat.status.rawValue)"
                    + " turns=\(chat.turnCount)"
                if chat.queuedMessageCount > 0 {
                    chip += " queued=\(chat.queuedMessageCount)"
                }
                if chat.isTurnActive { chip += " turn-active" }
                if focused == chat.id { chip += " [focused]" }
                // The composer's staged (unsent) text, so the assistant can see
                // what SetComposerDraft would replace and answer "what's in the
                // box" truthfully. Tagged files are UI-only state the core never
                // sees, so they are deliberately not reported here.
                let draft = chat.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !draft.isEmpty {
                    let oneLine = draft.replacingOccurrences(of: "\n", with: " ")
                    let clipped = oneLine.count > 80
                        ? String(oneLine.prefix(80)) + "…" : oneLine
                    chip += " draft=\"\(clipped)\""
                }
                lines.append(chip)
            }
            for pending in await engine.pendingInput() {
                var line = "  pending \(pending.kind) id=\(pending.id) "
                    + "chatID=\(pending.chatID.rawValue) on \"\(pending.title)\": "
                    + pending.summary
                if !pending.options.isEmpty {
                    line += " options=[\(pending.options.joined(separator: " | "))]"
                }
                if pending.kind == "question" {
                    line += pending.allowsFreeform ? " freeform=allowed" : " freeform=not-allowed"
                }
                lines.append(line)
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        if blocks.isEmpty {
            return "[ORE app state]\n\(focusedLine)\nNo project workspaces."
        }
        return "[ORE app state]\n\(focusedLine)\n" + blocks.joined(separator: "\n")
    }

    /// Live fleet as routing candidates. Assistant workspace omitted — it is
    /// never a destination for repository work.
    func routingSnapshot() async -> AssistantTaskRouter.Snapshot {
        let assistantID = (try? await store.assistantWorkspace())?.workspaceID
            ?? WorkspaceID(rawValue: "assistant")
        var focusedWorkspaceID: WorkspaceID?
        var focusedChatID: ChatID?
        var workspaces: [AssistantTaskRouter.Workspace] = []
        for (id, engine) in engines {
            let summary = await engine.summary()
            if !summary.isStandard { continue }
            let chats = (try? await engine.chatSummaries(includeClosed: true)) ?? []
            let focused = await engine.focusedChatIDValue()
            if let focused {
                focusedWorkspaceID = id
                focusedChatID = focused
            }
            let git = await engine.liveGitStatus()
            let pending = await engine.pendingInput()
            let pendingIDs = Set(pending.map(\.chatID))
            workspaces.append(AssistantTaskRouter.Workspace(
                id: id,
                name: summary.name,
                repo: URL(fileURLWithPath: summary.repositoryPath).lastPathComponent,
                dirtyFileCount: git.hasUncommittedChanges ? git.changedFileCount : 0,
                tabs: chats.map { chat in
                    AssistantTaskRouter.Tab(
                        id: chat.id,
                        title: chat.title,
                        status: chat.status,
                        isClosed: chat.isClosed,
                        isFocused: focused == chat.id,
                        pendingInput: pendingIDs.contains(chat.id)
                    )
                }
            ))
        }
        return AssistantTaskRouter.Snapshot(
            assistantWorkspaceID: assistantID,
            focusedWorkspaceID: focusedWorkspaceID,
            focusedChatID: focusedChatID,
            workspaces: workspaces
        )
    }

    /// The most recently active project worktree on this repository, if any.
    /// Used by the Assistant's CreateWorkspace so a restarted session reuses
    /// the worktree it already owns instead of minting a sibling.
    func existingProjectWorkspace(onRepository path: String) async -> WorkspaceRecord? {
        let wanted = URL(fileURLWithPath: path).standardizedFileURL
        let records = (try? await store.workspaces()) ?? []
        return records.first { record in
            URL(fileURLWithPath: record.repositoryPath).standardizedFileURL == wanted
        }
    }

    /// An existing worktree on this repository with uncommitted files — the
    /// reason CreateWorkspace asks before forking a sibling.
    func dirtySibling(
        onRepository path: String
    ) async -> (id: WorkspaceID, name: String, files: Int)? {
        let wanted = URL(fileURLWithPath: path).standardizedFileURL
        for (id, engine) in engines {
            let summary = await engine.summary()
            if !summary.isStandard { continue }
            let repo = URL(fileURLWithPath: summary.repositoryPath).standardizedFileURL
            guard repo == wanted else { continue }
            let git = await engine.liveGitStatus()
            if git.hasUncommittedChanges {
                return (id, summary.name, git.changedFileCount)
            }
        }
        return nil
    }

    public func transcript(workspaceID: WorkspaceID) async throws -> [TurnRecord] {
        let engine = try await engine(for: workspaceID)
        guard let chat = try await engine.chatSummaries().first else { return [] }
        return try await store.turns(chatID: chat.id)
    }

    public func transcript(chatID: ChatID) async throws -> [TurnRecord] {
        try await store.turns(chatID: chatID)
    }

    public func chatTransitions(chatID: ChatID) async throws -> [ChatTransition] {
        try await store.chatTransitions(chatID: chatID)
    }

    public func chats(workspaceID: WorkspaceID, includeClosed: Bool = true) async throws -> [ChatSummary] {
        try await engine(for: workspaceID).chatSummaries(includeClosed: includeClosed)
    }

    public func blocks(turnID: TurnID) async throws -> [BlockRecord] {
        try await store.blocks(turnID: turnID)
    }

    public func search(
        _ query: String,
        scope: OreStore.SearchScope = .projects,
        workspaceID: WorkspaceID? = nil
    ) async throws -> [OreStore.SearchHit] {
        try await store.search(query, scope: scope, workspaceID: workspaceID)
    }

    public func repositories() async throws -> [RepositoryRecord] {
        try await store.repositories()
    }

    /// The workspace's worktree and its `ore.toml` scripts.
    ///
    /// The terminal pane needs both: where to open a shell, and what ⌘R should
    /// run. Reading the config here rather than in the UI keeps `ore.toml`'s
    /// shape a core concern.
    public func workspaceEnvironment(
        workspaceID: WorkspaceID
    ) async throws -> WorkspaceEnvironment {
        guard let record = try await store.workspace(workspaceID) else {
            throw OreCoreError.workspaceNotFound(workspaceID)
        }
        let configuration = OreConfiguration.load(
            repositoryPath: URL(fileURLWithPath: record.repositoryPath)
        )
        return WorkspaceEnvironment(
            worktreePath: record.worktreePath,
            runScript: configuration.scripts.run,
            setupScript: configuration.scripts.setup
        )
    }

    /// Upgrade the locally installed agent CLI, then re-probe so the next
    /// session picks up the new binary. The running session is left alone —
    /// the caller should stop it before retrying a turn.
    public func updateHarnessCLI(_ kind: HarnessKind) async throws {
        let path = harnessProbes.first(where: { $0.kind == kind })?.executablePath
            ?? ShellEnvironment.locate(kind.defaultExecutableName)
        try await HarnessCLIUpdater.update(kind: kind, executablePath: path)
        async let probes = harnessRegistry.probeAll()
        async let catalogs = harnessRegistry.discoverAllModels()
        harnessProbes = await probes
        continuation.yield(.harnessProbeCompleted(harnessProbes))
        for (harness, models) in await catalogs {
            recordModels(models, for: harness)
        }
        await reconcileAssistantConfiguration()
        // Re-check against the channel, not just the binary: this is what
        // clears the update card, and what tells the user when an upgrade
        // "succeeded" without actually moving the version.
        await checkHarnessUpdates(force: true)
    }

    /// The upgrade situation for one harness, as of the last check.
    public func harnessUpdateStatus(_ kind: HarnessKind) -> HarnessUpdateStatus? {
        harnessUpdates.first { $0.kind == kind }
    }

    /// What to run when an upgrade failed because something isn't writable.
    ///
    /// Asked for only after a failure, because answering it costs two short
    /// shell calls (`npm config get prefix`, `brew --prefix`) and the answer
    /// is only useful once there is something to repair.
    public func harnessPermissionRepair(_ kind: HarnessKind) async -> HarnessRepair? {
        let path = harnessProbes.first(where: { $0.kind == kind })?.executablePath
            ?? ShellEnvironment.locate(kind.defaultExecutableName)
        return await HarnessCLIUpdater.permissionRepair(for: kind, executablePath: path)
    }

    public struct WorkspaceEnvironment: Sendable, Hashable {
        public var worktreePath: String
        public var runScript: String?
        public var setupScript: String?
    }
}

private extension CoreCommand {
    /// The workspace a failure should be reported against, when there is one.
    var workspaceID: WorkspaceID? {
        switch self {
        case .archiveWorkspace(let id), .unarchiveWorkspace(let id),
             .interruptTurn(let id), .stopSession(let id), .listChats(let id):
            return id
        case .deleteWorkspace(let id, _), .setPermissionMode(let id, _),
             .startSession(let id, _):
            return id
        case .renameWorkspace(let id, _, _), .setWorkspacePinned(let id, _),
             .addDiffComment(let id, _), .clearDiffComments(let id, _),
             .markFileViewed(let id, _, _),
             .commit(let id, _), .createGitHubRepo(let id), .push(let id),
             .createPullRequest(let id, _, _, _, _),
             .retargetPullRequest(let id, _, _), .mergePullRequest(let id, _),
             .continueAfterMerge(let id), .pullDefaultBranch(let id),
             .rerunFailedChecks(let id):
            return id
        case .resolveConflict(let id, _, _), .resolveConflictHunk(let id, _, _, _):
            return id
        case .resolvePermission(let id, _, _), .answerQuestion(let id, _, _),
             .revertToCheckpoint(let id, _):
            return id
        case .sendMessage(let request):
            return request.workspaceID
        case .createChat(let request):
            return request.workspaceID
        case .renameChat(let id, _, _, _):
            return id
        case .closeChat(let id, _), .reopenChat(let id, _),
             .switchChatHarness(let id, _, _, _), .setChatModel(let id, _, _),
             .setChatDraft(let id, _, _), .interruptChatTurn(let id, _),
             .setChatPermissionMode(let id, _, _),
             .setChatEffort(let id, _, _),
             .startChatSession(let id, _, _), .stopChatSession(let id, _):
            return id
        case .resolveChatPermission(let id, _, _, _, _),
             .answerChatQuestion(let id, _, _, _),
             .revertChatToCheckpoint(let id, _, _):
            return id
        case .resync(let id):
            return id
        case .addRepository, .createProject, .createWorkspace, .probeHarnesses,
             .checkHarnessUpdates,
             .resolveAssistantConfirmation, .updateDreamSettings,
             .updateDreamEnvironment, .startDreamRun, .abortDreamRun,
             .resolveDreamFinding, .listDreamFindings:
            return nil
        }
    }
}
