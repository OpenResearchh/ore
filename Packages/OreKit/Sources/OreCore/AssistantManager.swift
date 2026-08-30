import Foundation
import OrePersistence
import OreProtocol

/// Creates and maintains the product-owned assistant workspace: one hidden
/// workspace per user, living at `OreHome.assistantDirectory`, whose agent
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
        try ensureHome(at: home)

        if let existing = try await store.assistantWorkspace() {
            return existing
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

    // MARK: - Home on disk

    /// `~/ore/assistant/` — a tiny git repository so the engine's status
    /// watcher and checkpoints are well-defined, holding the memory files that
    /// are the assistant's durable knowledge.
    private static func ensureHome(at home: URL) throws {
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
        seedIfMissing(home.appendingPathComponent("memory/relations.md"), contents: """
        # Project relations

        How the user's projects depend on each other — which is the backend, \
        frontend, SDK, or infra of which, and where each contract lives (API \
        routes, shared types, published packages). Record a relation the \
        moment it's learned, from the user's words or from what project \
        agents surface. Format, one block per relation:

        - <project A> ⇄ <project B>: <nature of the dependency>. \
        Contract: <where it lives>. Learned: <how/when>.

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

        if !files.fileExists(atPath: home.appendingPathComponent(".git").path) {
            runGit(["init", "--initial-branch", "main"], in: home)
        }
        // An initial commit gives the repo a HEAD, which the diff and status
        // machinery assume. Committed with a local identity so this works on a
        // machine with no global git config.
        if !hasHead(in: home) {
            runGit(["add", "-A"], in: home)
            runGit([
                "-c", "user.name=ORE", "-c", "user.email=assistant@ore.local",
                "commit", "-m", "Assistant home",
            ], in: home)
        }
    }

    private static func seedIfMissing(_ url: URL, contents: String) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func hasHead(in directory: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--verify", "HEAD"]
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func runGit(_ arguments: [String], in directory: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
