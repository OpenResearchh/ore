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
    private var backgroundPollingEnabled = true
    var harnessProbes: [HarnessProbeResult] = []
    var harnessUpdates: [HarnessUpdateStatus] = []
    private var lastHarnessUpdateCheck: Date?
    /// What the previous run learned about the harnesses, read once from disk.
    private var harnessCache: HarnessDiscoveryCache?
    /// The check awaits the network, and the actor releases between awaits, so
    /// launch and a Refresh click can otherwise overlap on the same registries.
    private var harnessUpdateCheckInFlight = false
    var modelCatalog: [HarnessKind: [AgentModel]] = [:]
    /// First messages parked while their repository's `ore.toml` setup script
    /// waits to be allowed. See `createWorkspace`.
    private var promptsHeldForScriptApproval: [WorkspaceID: HeldPrompt] = [:]
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

        case .approveRepositoryScripts(let approval):
            try await approveRepositoryScripts(approval)

        case .declineRepositoryScripts(let approval):
            declineRepositoryScripts(approval)

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

        case .sendMessage(let request):
            let engine = try await engine(for: request.workspaceID)
            _ = try await engine.send(request)

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
            // The login-shell PATH is cached for the life of the process, and
            // an explicit probe is almost always someone coming back from a
            // Terminal window where they just ran ORE's own install command.
            // Without this the answer was frozen at launch, so the one action
            // ORE told them to take could not be seen to have worked.
            ShellEnvironment.invalidateCache()
            async let probes = harnessRegistry.probeAll()
            async let catalogs = harnessRegistry.discoverAllModels()
            harnessProbes = await probes
            continuation.yield(.harnessProbeCompleted(harnessProbes))
            let discovered = await catalogs
            for (harness, models) in discovered {
                recordModels(models, for: harness)
            }
            // An explicit probe is the user asking about right now; what it
            // found replaces whatever launch would otherwise reuse.
            persistCatalogs(discovered)
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

        // The product's own hidden workspace. Ensured before anything is
        // published so it rides the first snapshot and starts — and resumes
        // its session — exactly like any other workspace; `store.workspaces()`
        // below deliberately excludes it.
        let assistant = (try? await AssistantManager.ensureAssistant(store: store)) ?? nil
        let records = try await store.workspaces()

        // The sidebar is waiting on this, and stored rows are enough to draw
        // it. With no engine running yet the snapshot is built from the store
        // alone; each engine's live state follows as its own update, so launch
        // no longer waits for the whole fleet to start one engine at a time.
        try await resync(nil)

        // Behind the first paint, alongside the engines: probing spawns every
        // agent CLI, and nothing on screen needs it to draw.
        Task { [weak self] in
            await self?.discoverHarnessesAtLaunch()
        }

        if assistant != nil { startAssistantBridge() }
        await startEngines((assistant.map { [$0] } ?? []) + records)
        try await restoreOrphanedDreams()
    }

    /// Enough to keep git and SQLite from being hit by the whole fleet at
    /// once, while a dozen workspaces still come up in a few rounds.
    static let engineStartupConcurrency = 4

    private func startEngines(_ records: [WorkspaceRecord]) async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for record in records {
                if running >= Self.engineStartupConcurrency {
                    _ = await group.next()
                    running -= 1
                }
                group.addTask { await self.startEngineAtLaunch(record) }
                running += 1
            }
        }
    }

    /// An engine's streams replay its state on subscription, but those can
    /// land before its chats and status have loaded; one summary once `start`
    /// has finished is what replaces the stored row the snapshot carried.
    private func startEngineAtLaunch(_ record: WorkspaceRecord) async {
        let engine: WorkspaceEngine
        do {
            engine = try await makeEngine(for: record)
        } catch {
            return
        }
        let summary = await engine.summary()
        publishFromActiveEngine(.workspaceUpdated(summary), id: record.workspaceID, engine: engine)
    }

    /// Probes, then model catalogs, then the update check — reusing what the
    /// last run learned where it is still true, since every piece of this
    /// spawns a CLI or queries a registry and almost never changes between
    /// launches.
    private func discoverHarnessesAtLaunch() async {
        let probes = await harnessRegistry.probeAll()
        recordProbes(probes)

        let cache = loadedHarnessCache()
        let now = Date()
        var missing: Set<HarnessKind> = []
        for harness in harnessRegistry.available {
            let version = probes.first { $0.kind == harness.kind }?.version
            if let models = cache.catalog(for: harness.kind, harnessVersion: version, now: now) {
                recordModels(models, for: harness.kind)
            } else {
                missing.insert(harness.kind)
            }
        }
        if !missing.isEmpty {
            let discovered = await harnessRegistry.discoverModels(for: missing)
            for (harness, models) in discovered {
                recordModels(models, for: harness)
            }
            persistCatalogs(discovered)
        }
        await reconcileAssistantConfiguration()

        // A check the previous run made still holds if the installed versions
        // it compared against haven't moved; adopting it spends the throttle
        // exactly as if this run had made it.
        if harnessUpdates.isEmpty, lastHarnessUpdateCheck == nil,
           let cached = cache.updates(matching: probes, now: Date()) {
            harnessUpdates = cached
            lastHarnessUpdateCheck = cache.lastUpdateCheck
            continuation.yield(.harnessUpdatesChecked(cached))
        }
        // Behind the probe, and behind everything the user is waiting for:
        // whether Codex shipped a point release is never worth a slower
        // launch, and the card can appear a second late.
        await checkHarnessUpdates(force: false)
    }

    /// Beside the database, like the assistant's home: a scratch `ORE_HOME`
    /// or a test fixture gets its own, and an in-memory store gets none.
    private var harnessCacheURL: URL? {
        store.url?.deletingLastPathComponent()
            .appendingPathComponent("harness-cache.json")
    }

    private func loadedHarnessCache() -> HarnessDiscoveryCache {
        if let harnessCache { return harnessCache }
        let loaded = harnessCacheURL.map(HarnessDiscoveryCache.load(from:)) ?? HarnessDiscoveryCache()
        harnessCache = loaded
        return loaded
    }

    private func updateHarnessCache(_ change: (inout HarnessDiscoveryCache) -> Void) {
        guard let url = harnessCacheURL else { return }
        var cache = loadedHarnessCache()
        change(&cache)
        harnessCache = cache
        cache.save(to: url)
    }

    private func persistCatalogs(_ discovered: [(HarnessKind, [AgentModel])]) {
        let worthKeeping = discovered.filter {
            HarnessDiscoveryCache.cachedCatalogKinds.contains($0.0) && !$0.1.isEmpty
        }
        guard !worthKeeping.isEmpty else { return }
        let probes = harnessProbes
        let now = Date()
        updateHarnessCache { cache in
            for (harness, models) in worthKeeping {
                cache.storeCatalog(
                    models,
                    for: harness,
                    harnessVersion: probes.first { $0.kind == harness }?.version,
                    now: now
                )
            }
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
        // `isLaunchable`, not `isInstalled`: a quarantined or broken binary
        // keeps its path on the probe now, and asking a registry for the
        // latest version of a CLI ORE could not run stores a "did not report a
        // version" failure against it on every window that opens.
        let installed = harnessProbes.filter(\.isLaunchable)
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
        let sorted = statuses.sorted { $0.kind.rawValue < $1.kind.rawValue }
        // Only a check that actually reached a channel spends the throttle. A
        // laptop that launched offline should find out when it reconnects, not
        // in six hours. Persisted, or every relaunch re-queried the registries.
        if statuses.contains(where: { $0.failure == nil }) {
            let now = Date()
            lastHarnessUpdateCheck = now
            updateHarnessCache { cache in
                cache.lastUpdateCheck = now
                cache.updates = sorted
            }
        }
        harnessUpdates = sorted
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

        // Checked here, not left to the first workspace.
        //
        // `canonicalRepositoryURL` falls back to the path exactly as given
        // when `rev-parse --show-toplevel` fails. That is correct for its own
        // job — resolving symlinks — but it meant *any* folder could be
        // registered as a project. The user picked a directory, got a sidebar
        // entry that looked like every other one, and only discovered it was
        // not a repository when their first workspace died on a raw git
        // command line, by which point the mistake was several screens behind
        // them.
        guard (try? await git.topLevel()) != nil else {
            throw GitError.notARepository(path: root.path)
        }
        // A repository with no commits has no HEAD, and `git worktree add`
        // fails on it with "invalid reference: HEAD" — accurate, and useless
        // to somebody who has just cloned an empty repo or run `git init`.
        guard (try? await git.resolve("HEAD")) != nil else {
            throw GitError.repositoryHasNoCommits(path: root.path)
        }

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

        // `ore.toml` is repository content — after a clone, someone else's —
        // so its scripts wait for the user to read and allow them once.
        let scripts = configuration.scripts
        let prompt = initialPrompt.flatMap { $0.isEmpty ? nil : $0 }
        var promptIsHeld = false
        if scripts.setup != nil || scripts.run != nil || scripts.archive != nil {
            let approved = (try? await store.repositoryScriptsApproved(
                repositoryPath: record.repositoryPath,
                setup: scripts.setup,
                run: scripts.run,
                archive: scripts.archive
            )) == true
            if !approved {
                // The approval dialog stays up for as long as the user takes to
                // read it, and the setup script behind it is what makes the
                // worktree buildable. Sending the first turn here meant the
                // agent ran its first build against a worktree with no
                // dependencies installed, and then reported that as the
                // repository's own failure. The message waits for the script.
                if let prompt, scripts.setup != nil {
                    promptsHeldForScriptApproval[record.workspaceID] = HeldPrompt(
                        text: prompt,
                        origin: request.promptOrigin
                    )
                    promptIsHeld = true
                }
                continuation.yield(.repositoryScriptsNeedApproval(RepositoryScriptsApproval(
                    workspaceID: record.workspaceID,
                    repositoryPath: record.repositoryPath,
                    setup: scripts.setup,
                    run: scripts.run,
                    archive: scripts.archive
                )))
            } else if let setup = scripts.setup {
                await runScript(setup, in: worktree.path, workspaceID: record.workspaceID)
            }
        }
        if let prompt, !promptIsHeld {
            _ = try? await engine.send(SendMessageRequest(
                workspaceID: record.workspaceID,
                text: prompt,
                queueIfBusy: false,
                origin: request.promptOrigin
            ))
        }
        return record
    }

    /// A first message parked until its worktree is actually prepared.
    private struct HeldPrompt {
        var text: String
        var origin: MessageOrigin
    }

    /// Sends the first message held back for a setup script, now that the
    /// script has had its chance to run.
    private func sendPromptHeldForScriptApproval(_ id: WorkspaceID) async {
        guard let held = promptsHeldForScriptApproval.removeValue(forKey: id),
              let workspaceEngine = try? await engine(for: id)
        else { return }
        _ = try? await workspaceEngine.send(SendMessageRequest(
            workspaceID: id,
            text: held.text,
            queueIfBusy: false,
            origin: held.origin
        ))
    }

    /// The user read a repository's `ore.toml` and said no.
    ///
    /// Nothing runs — and, the part that was silent, the first message held
    /// back for the setup script is never going to be sent. Declining used to
    /// produce an app-layer banner about the scripts and no word at all about
    /// the turn that quietly evaporated, so the text comes back with it.
    func declineRepositoryScripts(_ approval: RepositoryScriptsApproval) {
        returnPromptHeldForScriptApproval(
            approval.workspaceID,
            because: "This project's ore.toml setup script wasn't allowed to run, so the "
                + "worktree isn't prepared and the message was held back rather than "
                + "sent into it."
        )
    }

    /// Give a held first message back to the user rather than dropping it, for
    /// every way the setup it was waiting for can fail to happen. A dropped
    /// prompt is worse than an early one: the early one at least still exists.
    private func returnPromptHeldForScriptApproval(
        _ id: WorkspaceID,
        because reason: String
    ) {
        guard let held = promptsHeldForScriptApproval.removeValue(forKey: id) else { return }
        continuation.yield(.commandFailed(CommandFailure(
            workspaceID: id,
            message: "Your first message wasn't sent.",
            detail: reason + " Here it is to send when you're ready:\n\n\(held.text)"
        )))
    }

    /// The user read a repository's `ore.toml` scripts and allowed them. Only
    /// the text they were shown is approved: if the file changed while the
    /// prompt was open, the new text is asked about and nothing runs.
    private func approveRepositoryScripts(_ approval: RepositoryScriptsApproval) async throws {
        do {
            try await runRepositoryScriptApproval(approval)
        } catch {
            // Only on a throw. The "ore.toml changed while the dialog was open"
            // path returns instead, and has to keep the message held for the
            // re-ask it is about to yield.
            returnPromptHeldForScriptApproval(
                approval.workspaceID,
                because: "ORE couldn't prepare this workspace, so the message was held back "
                    + "rather than sent into an unprepared worktree."
            )
            throw error
        }
    }

    private func runRepositoryScriptApproval(_ approval: RepositoryScriptsApproval) async throws {
        guard let record = try await store.workspace(approval.workspaceID) else {
            throw OreCoreError.workspaceNotFound(approval.workspaceID)
        }
        let scripts = OreConfiguration.load(
            repositoryPath: URL(fileURLWithPath: record.repositoryPath)
        ).scripts
        guard scripts.setup == approval.setup,
              scripts.run == approval.run,
              scripts.archive == approval.archive
        else {
            continuation.yield(.repositoryScriptsNeedApproval(RepositoryScriptsApproval(
                workspaceID: approval.workspaceID,
                repositoryPath: record.repositoryPath,
                setup: scripts.setup,
                run: scripts.run,
                archive: scripts.archive,
                runsSetup: approval.runsSetup
            )))
            return
        }
        try await store.approveRepositoryScripts(
            repositoryPath: record.repositoryPath,
            setup: scripts.setup,
            run: scripts.run,
            archive: scripts.archive
        )
        if approval.runsSetup, let setup = scripts.setup {
            await runScript(
                setup,
                in: URL(fileURLWithPath: record.worktreePath),
                workspaceID: approval.workspaceID
            )
        }
        // After the script, never before: this is the whole reason the first
        // message was held. Unconditional, so a ⌘R approval (which does not
        // re-run setup) releases a parked message rather than stranding it.
        await sendPromptHeldForScriptApproval(approval.workspaceID)
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
            let approved = (try? await store.repositoryScriptsApproved(
                repositoryPath: record.repositoryPath,
                setup: configuration.scripts.setup,
                run: configuration.scripts.run,
                archive: archiveScript
            )) == true
            if approved {
                await runScript(archiveScript, in: worktree, workspaceID: id)
            } else {
                continuation.yield(.commandFailed(CommandFailure(
                    workspaceID: id,
                    message: "Skipped this project's archive script.",
                    detail: "The scripts in ore.toml haven't been approved on this Mac, "
                        + "so `\(archiveScript)` didn't run."
                )))
            }
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
        // A push moves the PR's checks without going through `gh`, so the
        // remembered PR (and its check status) is stale now.
        await GitHubClient(repositoryURL: URL(fileURLWithPath: record.repositoryPath))
            .forgetCachedPullRequests()
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
            allowAPIKeyFallback: allowAPIKeyFallback,
            backgroundPollingEnabled: backgroundPollingEnabled
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
                // Deltas are nearly the whole stream and can't say anything
                // about quota or provider health; they skip the extra hops.
                guard InProcessCoreClient.carriesHarnessHealth(routed.event) else { continue }
                await self.observeHarnessHealth(
                    chatID: routed.chatID,
                    event: routed.event,
                    workspaceHarness: HarnessKind(rawValue: record.harness) ?? .claudeCode,
                    isAssistant: engine.isAssistantWorkspace
                )
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

    /// The only events any health consumer below acts on: quota reports,
    /// errors, and turn boundaries.
    nonisolated static func carriesHarnessHealth(_ event: AgentEvent) -> Bool {
        switch event {
        case .rateLimit, .sessionError, .turnCompleted: return true
        default: return false
        }
    }

    private func observeHarnessHealth(
        chatID: ChatID,
        event: AgentEvent,
        workspaceHarness: HarnessKind,
        isAssistant: Bool
    ) async {
        await recordHarnessRateLimit(chatID: chatID, event: event)
        noteDreamHarnessRateLimit(harness: workspaceHarness, event: event)
        // The Assistant is the product's own agent. A rate-limited or dead CLI
        // must not mute it while another harness is ready. Project tabs keep
        // their harness; only this workspace moves.
        if isAssistant {
            await considerAssistantFailover(chatID: chatID, event: event)
        }
    }

    func recordHarnessRateLimit(chatID: ChatID, event: AgentEvent) async {
        // Classified before the store is read: this runs for agent events, and
        // only these few can change what is known about a harness's quota.
        enum Change {
            case report(RateLimitReport)
            case cleared
            case exhaustedByError
        }
        let change: Change
        switch event {
        case .rateLimit(let value):
            change = .report(value)
        case .turnCompleted(let result) where result.outcome != .failed:
            // A successful turn is stronger evidence than an older exhausted
            // snapshot, including one whose provider supplied no reset time.
            change = .cleared
        case .sessionError, .turnCompleted:
            guard AssistantFailoverPolicy.reason(for: event) == .rateLimited else { return }
            change = .exhaustedByError
        default:
            return
        }

        // Read per event rather than cached: a chat's harness moves on
        // failover and on a user switch, and these events arrive a few times
        // per turn, not per token.
        let stored = try? await store.chat(chatID)
        guard let chat = stored else { return }
        guard let harness = HarnessKind(rawValue: chat.harness) else { return }

        let report: RateLimitReport
        switch change {
        case .report(let value):
            report = value
        case .cleared:
            harnessRateLimits.removeValue(forKey: harness)
            return
        case .exhaustedByError:
            let previous = harnessRateLimits[harness]?.report
            report = RateLimitReport(
                status: .exhausted,
                window: previous?.window,
                resetsAt: previous?.resetsAt
            )
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

    /// A GUI host can suspend periodic git work while hidden. Headless clients
    /// retain polling by default; explicit actions and filesystem events are
    /// independent of this setting.
    public func setBackgroundPollingEnabled(_ enabled: Bool) async {
        guard backgroundPollingEnabled != enabled else { return }
        backgroundPollingEnabled = enabled
        for engine in engines.values {
            // A newer visibility change can arrive while an engine catches up.
            guard backgroundPollingEnabled == enabled else { return }
            await engine.setBackgroundPollingEnabled(enabled)
        }
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
                environment: ShellEnvironment.childEnvironment(),
                // The failure report is built from stdout; stderr was never read.
                discardStandardError: true
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

    /// A file as it was at the workspace's merge base, or nil when it did not
    /// exist there. Binary-safe: this is how a deleted image is still shown.
    public func baseFileData(workspaceID: WorkspaceID, path: String) async throws -> Data? {
        try await engine(for: workspaceID).baseFileData(path: path)
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

    public func moveQueuedMessage(id: Int64, direction: Int) async throws {
        try await store.moveQueuedMessage(id: id, direction: direction)
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

    /// A chat's whole history in one query rather than one `blocks(turnID:)`
    /// per turn. One entry per turn that has blocks, in transcript order, each
    /// with its blocks by ordinal; turns without blocks are omitted, so match
    /// entries to `transcript(chatID:)` by `turnID`.
    public func blocks(chatID: ChatID) async throws -> [(turnID: TurnID, blocks: [BlockRecord])] {
        try await store.blocks(chatID: chatID)
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
        let scripts = OreConfiguration.load(
            repositoryPath: URL(fileURLWithPath: record.repositoryPath)
        ).scripts
        var runScriptApproval: RepositoryScriptsApproval?
        if scripts.run != nil {
            let approved = (try? await store.repositoryScriptsApproved(
                repositoryPath: record.repositoryPath,
                setup: scripts.setup,
                run: scripts.run,
                archive: scripts.archive
            )) == true
            if !approved {
                runScriptApproval = RepositoryScriptsApproval(
                    workspaceID: workspaceID,
                    repositoryPath: record.repositoryPath,
                    setup: scripts.setup,
                    run: scripts.run,
                    archive: scripts.archive,
                    runsSetup: false
                )
            }
        }
        return WorkspaceEnvironment(
            worktreePath: record.worktreePath,
            runScript: scripts.run,
            setupScript: scripts.setup,
            runScriptApproval: runScriptApproval
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
        let discovered = await catalogs
        for (harness, models) in discovered {
            recordModels(models, for: harness)
        }
        persistCatalogs(discovered)
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
        /// Set when `runScript` hasn't been allowed on this Mac: what ⌘R asks
        /// about instead of running it.
        public var runScriptApproval: RepositoryScriptsApproval?
    }
}

/// What launch may reuse from the previous run's harness discovery, stored as
/// `harness-cache.json` beside the database.
///
/// Every entry is keyed to what would invalidate it — a catalog to the CLI
/// version that produced it, an update check to the installed versions it
/// compared — so reuse can only skip work, never show a stale answer about a
/// binary that has since changed. An unreadable file is simply an empty cache.
struct HarnessDiscoveryCache: Codable, Sendable, Equatable {
    struct Catalog: Codable, Sendable, Equatable {
        var harnessVersion: String?
        var fetchedAt: Date
        var models: [AgentModel]
    }

    /// Keyed by `HarnessKind.rawValue`: a string-keyed dictionary encodes as a
    /// JSON object, an enum-keyed one as a flat array.
    var catalogs: [String: Catalog] = [:]
    var lastUpdateCheck: Date?
    var updates: [HarnessUpdateStatus] = []

    /// Server-side catalogs do change without a CLI upgrade; half a day bounds
    /// how long a new model can stay hidden, and Refresh always fetches.
    static let catalogLifetime: TimeInterval = 12 * 60 * 60

    /// Only catalogs that cost a process: Codex starts an app-server and Cursor
    /// runs `--list-models`. Claude's list ships in this build, so caching it
    /// could only hide a newer one.
    static let cachedCatalogKinds: Set<HarnessKind> = [.codex, .cursorAgent]

    func catalog(for kind: HarnessKind, harnessVersion: String?, now: Date) -> [AgentModel]? {
        guard Self.cachedCatalogKinds.contains(kind),
              let entry = catalogs[kind.rawValue],
              entry.harnessVersion == harnessVersion,
              entry.fetchedAt <= now,
              now.timeIntervalSince(entry.fetchedAt) < Self.catalogLifetime,
              !entry.models.isEmpty
        else { return nil }
        return entry.models
    }

    mutating func storeCatalog(
        _ models: [AgentModel],
        for kind: HarnessKind,
        harnessVersion: String?,
        now: Date
    ) {
        guard Self.cachedCatalogKinds.contains(kind), !models.isEmpty else { return }
        catalogs[kind.rawValue] = Catalog(
            harnessVersion: harnessVersion, fetchedAt: now, models: models
        )
    }

    /// The last update check, when it is inside the throttle window and was
    /// made against exactly the harnesses and versions installed now.
    func updates(matching probes: [HarnessProbeResult], now: Date) -> [HarnessUpdateStatus]? {
        guard let lastUpdateCheck,
              lastUpdateCheck <= now,
              now.timeIntervalSince(lastUpdateCheck) < InProcessCoreClient.harnessUpdateCheckInterval,
              !updates.isEmpty
        else { return nil }
        // The same filter `checkHarnessUpdates` applies when it decides what
        // to ask about. If these two ever disagree the cached set can never
        // match the probed one, and the throttle silently stops throttling.
        let installed = probes.filter(\.isLaunchable)
        guard Set(installed.map(\.kind)) == Set(updates.map(\.kind)) else { return nil }
        for probe in installed {
            guard let status = updates.first(where: { $0.kind == probe.kind }),
                  status.installedVersion == HarnessVersion.normalize(probe.version)
            else { return nil }
        }
        return updates
    }

    static func load(from url: URL) -> HarnessDiscoveryCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(HarnessDiscoveryCache.self, from: data)
        else { return HarnessDiscoveryCache() }
        return cache
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private extension CoreCommand {
    /// The workspace a failure should be reported against, when there is one.
    var workspaceID: WorkspaceID? {
        switch self {
        case .archiveWorkspace(let id), .unarchiveWorkspace(let id),
             .stopSession(let id):
            return id
        case .deleteWorkspace(let id, _), .setPermissionMode(let id, _):
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
             .stopChatSession(let id, _):
            return id
        case .resolveChatPermission(let id, _, _, _, _),
             .answerChatQuestion(let id, _, _, _),
             .revertChatToCheckpoint(let id, _, _):
            return id
        case .resync(let id):
            return id
        case .approveRepositoryScripts(let approval),
             .declineRepositoryScripts(let approval):
            return approval.workspaceID
        case .addRepository, .createProject, .createWorkspace, .probeHarnesses,
             .checkHarnessUpdates,
             .resolveAssistantConfirmation, .updateDreamSettings,
             .updateDreamEnvironment, .startDreamRun, .abortDreamRun,
             .resolveDreamFinding, .listDreamFindings:
            return nil
        }
    }
}

/// Whether a pinned model id has been outlived by the catalog that names it.
///
/// A provider retiring a model leaves the pin behind: the id keeps being sent
/// to the CLI, which rejects it, while Settings shows "Agent default" because
/// it cannot find the id to display. Clearing it needs a catalog that was
/// actually answered — discovery returns nothing whenever the CLI could not be
/// asked at all (not installed, not signed in, offline), and an empty list is
/// not evidence that anything is gone.
///
/// That is also why this is not folded into the app's `defaultModelID`: that
/// runs on every cold start, before the first discovery, when the catalog is
/// empty by definition. Checking there would silently unpin a perfectly good
/// model on every launch. It belongs with a freshly discovered catalog, which
/// is what `recordModels` publishes as `.modelCatalogUpdated`.
///
/// The verdict is reached here, where the catalog is known, and applied by the
/// app: the pin itself is client state (`UserDefaults`), which never crosses
/// the core boundary.
public enum StaleModelPin {
    public static func isStale(_ pinnedID: String?, in catalog: [AgentModel]) -> Bool {
        guard let pinnedID, !pinnedID.isEmpty, !catalog.isEmpty else { return false }
        return !catalog.contains { $0.id == pinnedID }
    }
}
