import Foundation
import OreGit
import OrePersistence
import OreProtocol
import OreSupport

/// Creates and maintains the product-owned assistant workspace: one hidden
/// workspace per user, living at `$ORE_HOME/assistant`, whose agent
/// answers for the whole product rather than any one project.
///
/// Everything here is idempotent. `ensureAssistant` runs on every app start;
/// a home that already exists is left exactly as the assistant last wrote it —
/// its memory files are its only durable memory, so re-seeding them would be
/// amnesia, not repair.
public enum AssistantManager {
    struct ModelProfile: Sendable, Equatable {
        var model: String
        var reasoningEffort: ReasoningEffort?
    }

    public static let workspaceName = "Assistant"
    /// The Assistant routes, recalls and delegates; expensive repository work
    /// belongs to the project agents it hands work to. Keep one explicit lean
    /// profile per harness so a provider's frontier catalog default can never
    /// become the Assistant's accidental default.
    static func modelProfile(for harness: HarnessKind) -> ModelProfile {
        switch harness {
        case .claudeCode:
            ModelProfile(model: "claude-haiku-4-5-20251001", reasoningEffort: nil)
        case .codex:
            ModelProfile(model: "gpt-5.6-luna", reasoningEffort: .low)
        case .cursorAgent:
            ModelProfile(model: "composer-2.5", reasoningEffort: nil)
        }
    }

    /// Kept as the product's first-launch default for callers that do not yet
    /// name a harness explicitly.
    public static let defaultModel = modelProfile(for: .claudeCode).model

    @discardableResult
    public static func ensureAssistant(store: OreStore) async throws -> WorkspaceRecord? {
        // The home lives beside the database (`~/ore/assistant` in production),
        // so a scratch `ORE_HOME` — or a test fixture — gets its own assistant
        // and never touches the real one. An in-memory store has no home to
        // live beside, and no assistant.
        guard let databaseURL = store.url else { return nil }
        let home = databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("assistant", isDirectory: true)
        try await ensureHome(at: home)

        if let existing = try await store.assistantWorkspace() {
            return existing
        }
        // A previous run may have written the home (and even a workspace row)
        // before `kind = assistant` landed. Minting another id would look like
        // the Assistant "creating a new project" on every restart.
        if let recovered = try await recoverAssistantWorkspace(store: store, home: home) {
            return recovered
        }

        // Workspaces have a foreign key to a repository, so the home registers
        // as one — `OreStore.repositories()` hides it from every picker.
        try await store.addRepository(RepositoryRecord(
            path: home.path,
            name: workspaceName,
            defaultBranch: "main"
        ))
        let record = WorkspaceRecord(
            id: WorkspaceID.generate(),
            name: workspaceName,
            repositoryPath: home.path,
            worktreePath: home.path,
            branch: "main",
            baseBranch: "main",
            harness: .claudeCode,
            model: defaultModel,
            permissionMode: .acceptEdits,
            isNameUserSet: true,
            kind: .assistant
        )
        try await store.saveWorkspace(record)
        // Created explicitly rather than via `ensureDefaultChat` so the title
        // is flagged user-set — the first prompt must not rename the
        // assistant to "Summarize my workspaces".
        try await store.saveChat(ChatRecord(
            id: ChatID(rawValue: record.id),
            workspaceID: record.workspaceID,
            title: workspaceName,
            harness: .claudeCode,
            model: defaultModel,
            permissionMode: .acceptEdits,
            isTitleUserSet: true,
            reasoningEffort: modelProfile(for: .claudeCode).reasoningEffort
        ))
        return record
    }

    /// Same disk home, already a workspace row — reuse it, and mark it
    /// assistant if the kind never stuck.
    private static func recoverAssistantWorkspace(
        store: OreStore,
        home: URL
    ) async throws -> WorkspaceRecord? {
        let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path
        let orphan = try await store.workspaces(includeArchived: true, includeAssistant: true)
            .first { record in
                workspacePath(record.worktreePath) == homePath
                    || workspacePath(record.repositoryPath) == homePath
            }
        guard var recovered = orphan else { return nil }
        if recovered.workspaceKind != .assistant {
            recovered = try await store.updateWorkspace(recovered.workspaceID) {
                $0.kind = WorkspaceKind.assistant.rawValue
            } ?? recovered
        }
        _ = try await store.ensureDefaultChat(for: recovered)
        return recovered
    }

    private static func workspacePath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Home on disk

    /// `~/ore/assistant/` — a tiny git repository so the engine's status
    /// watcher and checkpoints are well-defined, holding the memory files that
    /// are the assistant's durable knowledge.
    private static func ensureHome(at home: URL) async throws {
        let files = FileManager.default
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        try files.createDirectory(
            at: home.appendingPathComponent("memory", isDirectory: true),
            withIntermediateDirectories: true
        )
        try files.createDirectory(
            at: home.appendingPathComponent(".context", isDirectory: true),
            withIntermediateDirectories: true
        )

        seedIfMissing(home.appendingPathComponent("MEMORY.md"), contents: """
        # Memory index

        One line per memory file, so future sessions know what's here without \
        reading everything.

        - [Projects](memory/projects.md) — what the user is working on across workspaces
        - [Relations](memory/relations.md) — how projects depend on each other, and where their contracts live
        - [Preferences](memory/preferences.md) — how the user likes things done
        - [Watch](memory/watch.md) — what deserves interrupting the user, and what to mute

        """)
        seedIfMissing(home.appendingPathComponent("memory/projects.md"), contents: """
        # Projects

        Nothing recorded yet.

        """)
        // Seeded factless on purpose. `AssistantMemory.recallDigest` carries
        // these files into the system prompt verbatim, and skips one that
        // still says only "Nothing recorded yet." — so guidance about *how*
        // to write the file belongs in `AssistantPrompt`, where it is
        // versioned with the app, not in the file, where it would be recalled
        // forever as though it were something the user said.
        seedIfMissing(home.appendingPathComponent("memory/relations.md"), contents: """
        # Project relations

        Nothing recorded yet.

        """)
        seedIfMissing(home.appendingPathComponent("memory/preferences.md"), contents: """
        # Preferences

        Nothing recorded yet.

        """)
        seedIfMissing(home.appendingPathComponent("memory/watch.md"), contents: """
        # Watch preferences

        What deserves interrupting the user, judged against every [ORE watch] \
        digest. Update this the moment the user says what to surface or mute.

        Current rules (defaults until the user says otherwise):
        - Surface: an agent finishing something the user explicitly asked to \
        be told about; failures; anything blocked on the user's input.
        - Stay quiet about: routine turn completions, progress chatter, and \
        anything the user is already looking at.

        """)

        let isRepository = files.fileExists(atPath: home.appendingPathComponent(".git").path)
        // The steady state — a home that already exists with a commit — is
        // every start after the first, and it leaves before spawning anything
        // else.
        if isRepository, await hasHead(in: home) { return }

        // Past here there is git work to do, and on macOS attempting it had a
        // cost: `runGit` fell back to `/usr/bin/git`, which until the Command
        // Line Tools are installed is a stub that exists only to ask `xcrun`
        // for the real binary. Launching it is what pops the system "install
        // the developer tools" dialog — unexplained, credited to no app in
        // particular, seconds after a brand-new user opened ORE.
        //
        // The readiness ladder asks this question properly now. Here we only
        // have to not make it worse: a git that cannot run already left this
        // repository uncreated, so returning changes nothing except who gets
        // to tell the user about it.
        //
        // Checked after the filesystem check, not before, so a normal start
        // does not pay for a probe whose answer it has no use for.
        guard await GitAvailability.probe().isReady else { return }

        if !isRepository {
            await runGit(["init", "--initial-branch", "main"], in: home)
        }
        // An initial commit gives the repo a HEAD, which the diff and status
        // machinery assume. Committed with a local identity so this works on a
        // machine with no global git config.
        await runGit(["add", "-A"], in: home)
        await runGit([
            "-c", "user.name=ORE", "-c", "user.email=assistant@ore.local",
            "commit", "-m", "Assistant home",
        ], in: home)
    }

    private static func seedIfMissing(_ url: URL, contents: String) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func hasHead(in directory: URL) async -> Bool {
        await runGit(["rev-parse", "--verify", "HEAD"], in: directory) == 0
    }

    /// Short-lived git via `ChildProcess`, so Linux launches share the
    /// `ProcessLaunch` lock instead of calling `Process.run()` / `waitUntilExit()`
    /// beside every other test's git spawn.
    @discardableResult
    private static func runGit(_ arguments: [String], in directory: URL) async -> Int32 {
        // The login-shell environment, like every other git launch in ORE.
        // This one read `ProcessInfo.processInfo.environment` — a GUI app's
        // PATH, which contains none of the version managers developers install
        // their tools with — and then fell back to the `/usr/bin/git` stub
        // when that came up empty.
        let environment = ShellEnvironment.childEnvironment()
        guard let git = ShellEnvironment.locate("git", in: environment) else { return 1 }
        guard let process = try? ChildProcess(
            executablePath: git,
            arguments: arguments,
            workingDirectory: directory,
            environment: environment
        ) else { return 1 }
        process.closeStandardInput()
        async let stdout = process.stdoutChunks.collectText()
        async let stderr = process.stderrChunks.collectText()
        _ = await stdout
        _ = await stderr
        return await process.waitForExit()
    }
}
