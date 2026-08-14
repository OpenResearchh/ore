import Foundation
import OreGit
import OreHarness
import OrePersistence
import OreProtocol
import OreSupport

/// The core, as the Mac app sees it.
///
/// Everything crosses this boundary as `CoreCommand` in and `CoreEvent` out —
/// two `Codable` enums and nothing else. Today it's dispatched in-process; the
/// hosted version of ORE is the same two enums over a socket, and keeping the
/// boundary honest now is what makes that a change of transport rather than a
/// rewrite.
public actor InProcessCoreClient: CoreClient {
    public nonisolated let events: AsyncStream<CoreEvent>
    private nonisolated let continuation: AsyncStream<CoreEvent>.Continuation

    private let store: OreStore
    private let harnessRegistry: HarnessRegistry
    private let worktreeRoot: URL?
    private let allowAPIKeyFallback: Bool

    private var engines: [WorkspaceID: WorkspaceEngine] = [:]
    private var engineTasks: [WorkspaceID: [Task<Void, Never>]] = [:]
    private var gitClients: [String: GitClient] = [:]
    private var harnessProbes: [HarnessProbeResult] = []
    private var modelCatalog: [HarnessKind: [AgentModel]] = [:]

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

        case .createWorkspace(let request):
            try await createWorkspace(request)

        case .archiveWorkspace(let id):
            try await archiveWorkspace(id)

        case .unarchiveWorkspace(let id):
            try await unarchiveWorkspace(id)

        case .deleteWorkspace(let id, let deleteBranch):
            try await deleteWorkspace(id, deleteBranch: deleteBranch)

        case .renameWorkspace(let id, let name):
            try await engine(for: id).rename(name)

        case .setWorkspacePinned(let id, let pinned):
            try await engine(for: id).setPinned(pinned)

        case .addDiffComment(let id, let reference):
            try await engine(for: id).addDiffComment(reference)

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

        case .push(let id):
            try await push(id)

        case .createPullRequest(let id, let title, let body, let base, let draft):
            _ = try await createPullRequest(id, title: title, body: body, base: base, draft: draft)

        case .retargetPullRequest(let id, let number, let base):
            try await retargetPullRequest(id, number: number, base: base)

        case .mergePullRequest(let id, let method):
            try await mergePullRequest(id, method: method)

        case .createChat(let request):
            let chat = try await engine(for: request.workspaceID).createChat(request)
            continuation.yield(.chatAdded(chat))

        case .renameChat(let id, let chatID, let title):
            _ = try await engine(for: id).renameChat(chatID, title: title)

        case .closeChat(let workspaceID, let chatID):
            let chat = try await engine(for: workspaceID).closeChat(chatID)
            continuation.yield(.chatUpdated(chat))

        case .reopenChat(let workspaceID, let chatID):
            let chat = try await engine(for: workspaceID).closeChat(chatID, closed: false)
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
            let chats = try await engine(for: workspaceID).chatSummaries()
            continuation.yield(.chatsListed(workspaceID, chats))

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

        case .resolvePermission(let id, let requestID, let decision):
            try await engine(for: id).resolvePermission(requestID, with: decision)

        case .resolveChatPermission(let id, let chatID, let requestID, let decision):
            try await engine(for: id).resolvePermission(
                requestID, with: decision, chatID: chatID
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

        case .probeHarnesses:
            async let probes = harnessRegistry.probeAll()
            async let catalogs = harnessRegistry.discoverAllModels()
            harnessProbes = await probes
            continuation.yield(.harnessProbeCompleted(harnessProbes))
            for (harness, models) in await catalogs {
                recordModels(models, for: harness)
            }

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
        for record in try await store.workspaces() {
            _ = try? await makeEngine(for: record)
        }
        try await resync(nil)

        Task { [weak self] in
            guard let self else { return }
            async let probes = self.harnessRegistry.probeAll()
            async let catalogs = self.harnessRegistry.discoverAllModels()
            await self.recordProbes(probes)
            for (harness, models) in await catalogs {
                await self.recordModels(models, for: harness)
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

    private func resync(_ id: WorkspaceID?) async throws {
        if let id {
            let engine = try await engine(for: id)
            continuation.yield(.workspaceUpdated(await engine.summary()))
            return
        }

        var summaries: [WorkspaceSummary] = []
        var chats: [ChatSummary] = []
        for record in try await store.workspaces(includeArchived: true) {
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
        continuation.yield(.snapshot(CoreSnapshot(
            workspaces: summaries, chats: chats, harnesses: harnessProbes
        )))
    }

    // MARK: - Repositories

    private func addRepository(path: String) async throws {
        let root = try await canonicalRepositoryURL(path)
        let git = try gitClient(for: root.path)

        try await store.addRepository(RepositoryRecord(
            path: root.path,
            name: root.lastPathComponent,
            defaultBranch: await git.defaultBranch()
        ))
        try await resync(nil)
    }

    /// The one true path for a repository.
    ///
    /// Everything keys off this — the `repository` row, each workspace's
    /// foreign key, the `GitClient` cache — so the same repo reached by two
    /// spellings has to resolve to one string. On macOS that is not a nicety:
    /// `/tmp` is a symlink to `/private/tmp`, and a home directory can be too,
    /// so "add the repo, then make a workspace in it" would otherwise fail on a
    /// foreign key the user has no way to understand.
    private func canonicalRepositoryURL(_ path: String) async throws -> URL {
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

    private func createWorkspace(_ request: CreateWorkspaceRequest) async throws {
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
        continuation.yield(.workspaceAdded(await engine.summary()))

        if let setup = configuration.scripts.setup {
            await runScript(setup, in: worktree.path, workspaceID: record.workspaceID)
        }
        if let initialPrompt, !initialPrompt.isEmpty {
            _ = try? await engine.send(SendMessageRequest(
                workspaceID: record.workspaceID, text: initialPrompt, queueIfBusy: false
            ))
        }
    }

    private func archiveWorkspace(_ id: WorkspaceID) async throws {
        guard let record = try await store.workspace(id) else {
            throw OreCoreError.workspaceNotFound(id)
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

        let git = try gitClient(for: record.repositoryPath)
        let manager = WorktreeManager(git: git, root: worktreeRoot)
        let preservedCommit = try await manager.archive(at: worktree, workspaceID: id)

        _ = try await store.updateWorkspace(id) { record in
            record.isArchived = true
            record.archivedStateCommit = preservedCommit
        }
        try await resync(nil)
    }

    private func unarchiveWorkspace(_ id: WorkspaceID) async throws {
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
        }
        if let updated {
            let engine = try await makeEngine(for: updated)
            continuation.yield(.workspaceUpdated(await engine.summary()))
        }
    }

    private func deleteWorkspace(_ id: WorkspaceID, deleteBranch: Bool) async throws {
        guard let record = try await store.workspace(id) else {
            throw OreCoreError.workspaceNotFound(id)
        }
        await stopEngine(id)

        let git = try gitClient(for: record.repositoryPath)
        let manager = WorktreeManager(git: git, root: worktreeRoot)
        try? await manager.remove(
            at: URL(fileURLWithPath: record.worktreePath),
            deleteBranch: deleteBranch ? record.branch : nil,
            force: true
        )
        // ORE's own refs must not outlive the thing they describe.
        try? await CheckpointStore(git: git).removeAll(workspaceID: id)

        try await store.deleteWorkspace(id)
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

    private func commit(_ id: WorkspaceID, message: String) async throws {
        let (_, git, worktree) = try await workspaceAndGit(id)
        try await git.runSerialized(["add", "-A"], in: worktree)
        try await git.runSerialized([
            "commit", "-m", message.trimmingCharacters(in: .whitespacesAndNewlines)
        ], in: worktree)
        try await resync(id)
    }

    private func push(_ id: WorkspaceID) async throws {
        let (record, git, worktree) = try await workspaceAndGit(id)
        try await git.runSerialized(["push", "-u", "origin", record.branch], in: worktree)
        try await resync(id)
    }

    @discardableResult
    private func createPullRequest(
        _ id: WorkspaceID, title: String, body: String, base: String, draft: Bool
    ) async throws -> String {
        let (record, _, _) = try await workspaceAndGit(id)
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

    private func retargetPullRequest(_ id: WorkspaceID, number: Int, base: String) async throws {
        let (record, _, _) = try await workspaceAndGit(id)
        try await GitHubClient(repositoryURL: URL(fileURLWithPath: record.repositoryPath))
            .retargetPullRequest(number: number, to: base)
        try await resync(id)
    }

    private func mergePullRequest(_ id: WorkspaceID, method: String) async throws {
        let (record, _, _) = try await workspaceAndGit(id)
        let github = GitHubClient(repositoryURL: URL(fileURLWithPath: record.repositoryPath))
        guard let pr = await github.pullRequest(forBranch: record.branch) else {
            throw OreCoreError.noPullRequest(record.branch)
        }
        let mergeMethod = GitHubClient.MergeMethod(rawValue: method) ?? .squash
        // Archive owns worktree cleanup; keep the branch until its checkpointed
        // state has been preserved and the worktree has been removed safely.
        try await github.merge(number: pr.number, method: mergeMethod, deleteBranch: false)
        try await archiveWorkspace(id)
    }

    // MARK: - Engines

    private func engine(for id: WorkspaceID) async throws -> WorkspaceEngine {
        if let engine = engines[id] { return engine }
        guard let record = try await store.workspace(id) else {
            throw OreCoreError.workspaceNotFound(id)
        }
        return try await makeEngine(for: record)
    }

    @discardableResult
    private func makeEngine(for record: WorkspaceRecord) async throws -> WorkspaceEngine {
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

        // Each engine's two streams are tagged with the workspace and merged
        // into one ordered feed, so the client has a single source of truth
        // rather than N it has to reconcile.
        let id = record.workspaceID
        let agentTask = Task { [weak self, continuation] in
            for await routed in engine.events {
                guard self != nil else { return }
                continuation.yield(.agent(id, routed.chatID, routed.event))
            }
        }
        let summaryTask = Task { [weak self, continuation] in
            for await summary in await engine.summaryUpdates() {
                guard self != nil else { return }
                continuation.yield(.workspaceUpdated(summary))
            }
        }
        let chatTask = Task { [weak self, continuation] in
            for await chat in await engine.chatUpdates() {
                guard self != nil else { return }
                continuation.yield(.chatUpdated(chat))
            }
        }
        engineTasks[id] = [agentTask, summaryTask, chatTask]

        await engine.start()
        return engine
    }

    private func stopEngine(_ id: WorkspaceID) async {
        if let engine = engines.removeValue(forKey: id) {
            await engine.stop()
        }
        engineTasks.removeValue(forKey: id)?.forEach { $0.cancel() }
    }

    public func shutdown() async {
        for id in engines.keys {
            await stopEngine(id)
        }
        continuation.finish()
    }

    // MARK: - Scripts

    /// Runs a lifecycle script in the worktree, through the user's login shell
    /// so their version managers and aliases apply.
    private func runScript(_ script: String, in directory: URL, workspaceID: WorkspaceID) async {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let process = try? ChildProcess(
            executablePath: shell,
            arguments: ["-lc", script],
            workingDirectory: directory,
            environment: ShellEnvironment.childEnvironment()
        ) else { return }
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

    private func gitClient(for path: String) throws -> GitClient {
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

    public func search(_ query: String) async throws -> [OreStore.SearchHit] {
        try await store.search(query)
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
        case .renameWorkspace(let id, _), .setWorkspacePinned(let id, _),
             .addDiffComment(let id, _), .markFileViewed(let id, _, _),
             .commit(let id, _), .push(let id), .createPullRequest(let id, _, _, _, _),
             .retargetPullRequest(let id, _, _), .mergePullRequest(let id, _):
            return id
        case .resolvePermission(let id, _, _), .answerQuestion(let id, _, _),
             .revertToCheckpoint(let id, _):
            return id
        case .sendMessage(let request):
            return request.workspaceID
        case .createChat(let request):
            return request.workspaceID
        case .renameChat(let id, _, _):
            return id
        case .closeChat(let id, _), .reopenChat(let id, _),
             .switchChatHarness(let id, _, _, _), .setChatModel(let id, _, _),
             .setChatDraft(let id, _, _), .interruptChatTurn(let id, _),
             .setChatPermissionMode(let id, _, _),
             .startChatSession(let id, _, _), .stopChatSession(let id, _):
            return id
        case .resolveChatPermission(let id, _, _, _),
             .answerChatQuestion(let id, _, _, _),
             .revertChatToCheckpoint(let id, _, _):
            return id
        case .resync(let id):
            return id
        case .addRepository, .createWorkspace, .probeHarnesses:
            return nil
        }
    }
}
