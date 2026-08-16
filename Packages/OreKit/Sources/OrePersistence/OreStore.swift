import Foundation
import GRDB
import OreProtocol
import OreSupport

/// Where ORE keeps its state.
///
/// `ORE_HOME` overrides it, which is what makes it possible to run a second
/// instance against a scratch directory — for development, and so a test run
/// can never touch the state a real session depends on.
public enum OreHome {
    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["ORE_HOME"], !override.isEmpty {
            return FilePath.expandingTildeURL(override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ore", isDirectory: true)
    }

    public static var worktreeRoot: URL {
        directory.appendingPathComponent("workspaces", isDirectory: true)
    }
}

/// The database.
///
/// Everything durable goes through here: workspaces, transcripts, review state,
/// the message queue. Live state that changes many times a second — streaming
/// text, git status generations — deliberately does not; it lives in the engine
/// and is only written at boundaries. A transcript that survives a crash is
/// worth a write; a token counter updating at 60Hz is not.
public actor OreStore {
    private let writer: any DatabaseWriter

    public init(path: URL) throws {
        var configuration = Configuration()
        // WAL plus a busy timeout: the app reads on several tasks while the
        // engine writes, and without this a concurrent read fails outright
        // rather than waiting a few milliseconds.
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: path.path, configuration: configuration)
        try OreSchema.migrator.migrate(pool)
        self.writer = pool
    }

    /// In-memory store, for tests.
    public init() throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: configuration)
        try OreSchema.migrator.migrate(queue)
        self.writer = queue
    }

    public static var defaultURL: URL {
        OreHome.directory.appendingPathComponent("ore.sqlite")
    }

    /// Escape hatch for anything not worth a dedicated method.
    public func write<T: Sendable>(_ body: @Sendable (Database) throws -> T) throws -> T {
        try writer.write(body)
    }

    public func read<T: Sendable>(_ body: @Sendable (Database) throws -> T) throws -> T {
        try writer.read(body)
    }

    // MARK: - Repositories

    public func addRepository(_ record: RepositoryRecord) throws {
        try writer.write { db in
            try record.save(db)
        }
    }

    public func repositories() throws -> [RepositoryRecord] {
        try writer.read { db in
            try RepositoryRecord.order(Column("name")).fetchAll(db)
        }
    }

    // MARK: - Workspaces

    public func saveWorkspace(_ record: WorkspaceRecord) throws {
        try writer.write { db in try record.save(db) }
    }

    public func workspace(_ id: WorkspaceID) throws -> WorkspaceRecord? {
        try writer.read { db in try WorkspaceRecord.fetchOne(db, key: id.rawValue) }
    }

    /// Sidebar order: pinned first, then most recently active. A workspace the
    /// user pinned is one they're coming back to; recency handles the rest.
    public func workspaces(includeArchived: Bool = false) throws -> [WorkspaceRecord] {
        try writer.read { db in
            var request = WorkspaceRecord.all()
            if !includeArchived {
                request = request.filter(Column("isArchived") == false)
            }
            return try request
                .order(
                    Column("isPinned").desc,
                    Column("lastActivityAt").desc,
                    Column("createdAt").desc
                )
                .fetchAll(db)
        }
    }

    public func deleteWorkspace(_ id: WorkspaceID) throws {
        _ = try writer.write { db in
            try WorkspaceRecord.deleteOne(db, key: id.rawValue)
        }
    }

    public func updateWorkspace(
        _ id: WorkspaceID,
        _ mutate: @Sendable @escaping (inout WorkspaceRecord) -> Void
    ) throws -> WorkspaceRecord? {
        try writer.write { db in
            guard var record = try WorkspaceRecord.fetchOne(db, key: id.rawValue) else {
                return nil
            }
            mutate(&record)
            try record.update(db)
            return record
        }
    }

    /// Workspaces stacked directly on this one.
    public func children(of id: WorkspaceID) throws -> [WorkspaceRecord] {
        try writer.read { db in
            try WorkspaceRecord
                .filter(Column("stackedOnWorkspaceID") == id.rawValue)
                .fetchAll(db)
        }
    }

    // MARK: - Sessions and turns

    // MARK: - Chats

    public func saveChat(_ record: ChatRecord) throws {
        try writer.write { db in try record.save(db) }
    }

    public func chat(_ id: ChatID) throws -> ChatRecord? {
        try writer.read { db in try ChatRecord.fetchOne(db, key: id.rawValue) }
    }

    public func chats(workspaceID: WorkspaceID, includeClosed: Bool = true) throws -> [ChatRecord] {
        try writer.read { db in
            var request = ChatRecord.filter(Column("workspaceID") == workspaceID.rawValue)
            if !includeClosed {
                request = request.filter(Column("isClosed") == false)
            }
            return try request.order(Column("sortIndex"), Column("createdAt")).fetchAll(db)
        }
    }

    /// Returns the compatibility/default chat, creating it when a test or an
    /// older caller inserted a workspace row directly after migrations ran.
    public func ensureDefaultChat(for workspace: WorkspaceRecord) throws -> ChatRecord {
        try writer.write { db in
            if let existing = try ChatRecord
                .filter(Column("workspaceID") == workspace.id)
                .order(Column("sortIndex"), Column("createdAt"))
                .fetchOne(db) {
                return existing
            }
            let researchTitle = ResearchIdentity.matching(nameOrSlug: workspace.name)?
                .researchTitles.first
            let record = ChatRecord(
                id: ChatID(rawValue: workspace.id),
                workspaceID: workspace.workspaceID,
                title: researchTitle ?? workspace.name,
                harness: HarnessKind(rawValue: workspace.harness) ?? .claudeCode,
                model: workspace.model,
                permissionMode: PermissionMode(rawValue: workspace.permissionMode) ?? .default
            )
            try record.insert(db)
            return record
        }
    }

    public func nextChatSortIndex(workspaceID: WorkspaceID) throws -> Int {
        try writer.read { db in
            let maximum = try Int.fetchOne(
                db,
                sql: "SELECT MAX(sortIndex) FROM chat WHERE workspaceID = ?",
                arguments: [workspaceID.rawValue]
            )
            return (maximum ?? -1) + 1
        }
    }

    public func updateChat(
        _ id: ChatID,
        _ mutate: @Sendable @escaping (inout ChatRecord) -> Void
    ) throws -> ChatRecord? {
        try writer.write { db in
            guard var record = try ChatRecord.fetchOne(db, key: id.rawValue) else { return nil }
            mutate(&record)
            try record.update(db)
            return record
        }
    }

    public func deleteChat(_ id: ChatID) throws {
        _ = try writer.write { db in try ChatRecord.deleteOne(db, key: id.rawValue) }
    }

    public func saveChatTransition(_ transition: ChatTransition) throws {
        try writer.write { db in try ChatTransitionRecord(transition).save(db) }
    }

    public func chatTransitions(chatID: ChatID) throws -> [ChatTransition] {
        try writer.read { db in
            try ChatTransitionRecord
                .filter(Column("chatID") == chatID.rawValue)
                .order(Column("createdAt"), Column("id"))
                .fetchAll(db)
                .map(\.transition)
        }
    }

    // MARK: - Sessions and turns

    public func saveSession(_ record: SessionRecord) throws {
        try writer.write { db in try record.save(db) }
    }

    public func latestSession(for workspaceID: WorkspaceID) throws -> SessionRecord? {
        try writer.read { db in
            try SessionRecord
                .filter(Column("workspaceID") == workspaceID.rawValue)
                .order(Column("startedAt").desc)
                .fetchOne(db)
        }
    }

    public func latestSession(for chatID: ChatID) throws -> SessionRecord? {
        try writer.read { db in
            try SessionRecord
                .filter(Column("chatID") == chatID.rawValue)
                .order(Column("startedAt").desc)
                .fetchOne(db)
        }
    }

    public func session(_ id: SessionID) throws -> SessionRecord? {
        try writer.read { db in try SessionRecord.fetchOne(db, key: id.rawValue) }
    }

    public func saveTurn(_ record: TurnRecord) throws {
        try writer.write { db in try record.save(db) }
    }

    public func nextTurnOrdinal(sessionID: SessionID) throws -> Int {
        try writer.read { db in
            let maximum = try Int.fetchOne(
                db,
                sql: "SELECT MAX(ordinal) FROM turn WHERE sessionID = ?",
                arguments: [sessionID.rawValue]
            )
            return (maximum ?? -1) + 1
        }
    }

    public func turns(sessionID: SessionID) throws -> [TurnRecord] {
        try writer.read { db in
            try TurnRecord
                .filter(Column("sessionID") == sessionID.rawValue)
                .order(Column("ordinal"))
                .fetchAll(db)
        }
    }

    /// The visible transcript belongs to the chat, not to any one provider
    /// incarnation. Sessions are ordered first so ordinals can restart at zero
    /// after a cross-harness handoff without scrambling history.
    public func turns(chatID: ChatID) throws -> [TurnRecord] {
        try writer.read { db in
            try TurnRecord.fetchAll(
                db,
                sql: """
                    SELECT turn.*
                    FROM turn
                    JOIN session ON session.id = turn.sessionID
                    WHERE session.chatID = ?
                    ORDER BY session.startedAt, turn.ordinal, turn.startedAt
                    """,
                arguments: [chatID.rawValue]
            )
        }
    }

    public func handoffContext(chatID: ChatID, transcriptTailLimit: Int = 8) throws -> String? {
        let turns = try turns(chatID: chatID)
        guard !turns.isEmpty else { return nil }

        var sections: [String] = []
        let summaries = turns.compactMap(\.summary).filter { !$0.isEmpty }
        if !summaries.isEmpty {
            sections.append("Prior turn summaries:\n" + summaries.suffix(12).map { "- \($0)" }.joined(separator: "\n"))
        }

        let tail = turns.suffix(transcriptTailLimit)
        let transcript = tail.compactMap { turn -> String? in
            var parts: [String] = []
            if let prompt = turn.prompt, !prompt.isEmpty { parts.append("User: \(prompt)") }
            let text = (try? blocks(turnID: turn.turnID))?
                .filter { $0.blockKind == .text }
                .map(\.text)
                .joined(separator: "\n") ?? ""
            if !text.isEmpty { parts.append("Assistant: \(String(text.suffix(4_000)))") }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        if !transcript.isEmpty {
            sections.append("Recent transcript:\n" + transcript.joined(separator: "\n\n"))
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    public func turn(_ id: TurnID) throws -> TurnRecord? {
        try writer.read { db in try TurnRecord.fetchOne(db, key: id.rawValue) }
    }

    /// Drops a turn and everything after it. This is the transcript half of a
    /// checkpoint revert: the conversation must end where the code does, or the
    /// agent resumes with a memory of work that no longer exists.
    public func deleteTurnsFrom(sessionID: SessionID, ordinal: Int) throws {
        _ = try writer.write { db in
            try TurnRecord
                .filter(Column("sessionID") == sessionID.rawValue)
                .filter(Column("ordinal") >= ordinal)
                .deleteAll(db)
        }
    }

    /// Truncates a chat across provider incarnations. This is the transcript
    /// half of reverting past a model/harness handoff: later sessions must go
    /// too, or `latestSession` would resume a provider that remembers deleted
    /// work.
    public func deleteTranscriptFrom(chatID: ChatID, turnID: TurnID) throws {
        try writer.write { db in
            guard let turn = try TurnRecord.fetchOne(db, key: turnID.rawValue),
                  let session = try SessionRecord.fetchOne(db, key: turn.sessionID),
                  session.chatID == chatID.rawValue
            else { return }

            try db.execute(
                sql: """
                    DELETE FROM session
                    WHERE chatID = ? AND (
                        startedAt > ? OR (startedAt = ? AND id > ?)
                    )
                    """,
                arguments: [chatID.rawValue, session.startedAt, session.startedAt, session.id]
            )
            _ = try TurnRecord
                .filter(Column("sessionID") == session.id)
                .filter(Column("ordinal") >= turn.ordinal)
                .deleteAll(db)
            _ = try ChatTransitionRecord
                .filter(Column("chatID") == chatID.rawValue)
                .filter(Column("createdAt") > turn.startedAt)
                .deleteAll(db)
        }
    }

    // MARK: - Blocks

    public func appendBlock(_ record: BlockRecord) throws {
        try writer.write { db in try record.save(db) }
    }

    public func block(_ id: String) throws -> BlockRecord? {
        try writer.read { db in try BlockRecord.fetchOne(db, key: id) }
    }

    public func appendBlocks(_ records: [BlockRecord]) throws {
        guard !records.isEmpty else { return }
        try writer.write { db in
            for record in records { try record.save(db) }
        }
    }

    public func blocks(turnID: TurnID) throws -> [BlockRecord] {
        try writer.read { db in
            try BlockRecord
                .filter(Column("turnID") == turnID.rawValue)
                .order(Column("ordinal"))
                .fetchAll(db)
        }
    }

    public func nextBlockOrdinal(turnID: TurnID) throws -> Int {
        try writer.read { db in
            let maximum = try Int.fetchOne(
                db,
                sql: "SELECT MAX(ordinal) FROM block WHERE turnID = ?",
                arguments: [turnID.rawValue]
            )
            return (maximum ?? -1) + 1
        }
    }

    // MARK: - Search

    public struct SearchHit: Sendable, Hashable {
        public var workspaceID: WorkspaceID
        public var workspaceName: String
        public var turnID: TurnID
        public var blockID: String
        public var snippet: String
        public var createdAt: Date
    }

    /// Full-text search across every transcript, newest first.
    ///
    /// This is what makes "which workspace was I doing the migration in?"
    /// answerable — with several agents running in parallel, the user's own
    /// memory stops being a reliable index.
    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        let pattern = FTS5Pattern(matchingAllPrefixesIn: query)
        guard let pattern else { return [] }

        return try writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    workspace.id AS workspaceID,
                    workspace.name AS workspaceName,
                    block.turnID AS turnID,
                    block.id AS blockID,
                    snippet(blockSearch, 0, '«', '»', '…', 12) AS snippet,
                    block.createdAt AS createdAt
                FROM blockSearch
                JOIN block ON block.rowid = blockSearch.rowid
                JOIN turn ON turn.id = block.turnID
                JOIN session ON session.id = turn.sessionID
                JOIN workspace ON workspace.id = session.workspaceID
                WHERE blockSearch MATCH ?
                ORDER BY block.createdAt DESC
                LIMIT ?
                """,
                arguments: [pattern, limit]
            )
            return rows.map { row in
                SearchHit(
                    workspaceID: WorkspaceID(rawValue: row["workspaceID"]),
                    workspaceName: row["workspaceName"],
                    turnID: TurnID(rawValue: row["turnID"]),
                    blockID: row["blockID"],
                    snippet: row["snippet"],
                    createdAt: row["createdAt"]
                )
            }
        }
    }

    // MARK: - Review state

    public func addDiffComment(_ record: DiffCommentRecord) throws -> DiffCommentRecord {
        try writer.write { db in
            var record = record
            try record.insert(db)
            return record
        }
    }

    public func pendingDiffComments(workspaceID: WorkspaceID) throws -> [DiffCommentRecord] {
        try writer.read { db in
            try DiffCommentRecord
                .filter(Column("workspaceID") == workspaceID.rawValue)
                .filter(Column("isSent") == false)
                .order(Column("filePath"), Column("startLine"))
                .fetchAll(db)
        }
    }

    public func markDiffCommentsSent(workspaceID: WorkspaceID) throws {
        _ = try writer.write { db in
            try DiffCommentRecord
                .filter(Column("workspaceID") == workspaceID.rawValue)
                .filter(Column("isSent") == false)
                .updateAll(db, Column("isSent").set(to: true))
        }
    }

    public func deleteDiffComment(id: Int64) throws {
        _ = try writer.write { db in try DiffCommentRecord.deleteOne(db, key: id) }
    }

    public func markViewed(_ record: ViewedFileRecord) throws {
        try writer.write { db in try record.save(db) }
    }

    public func viewedFiles(workspaceID: WorkspaceID) throws -> [String: String] {
        try writer.read { db in
            let records = try ViewedFileRecord
                .filter(Column("workspaceID") == workspaceID.rawValue)
                .fetchAll(db)
            return Dictionary(
                records.map { ($0.filePath, $0.contentHash) },
                uniquingKeysWith: { _, last in last }
            )
        }
    }

    // MARK: - Message queue

    public func enqueueMessage(_ record: QueuedMessageRecord) throws {
        try writer.write { db in
            var record = record
            try record.insert(db)
        }
    }

    public func queuedMessages(workspaceID: WorkspaceID) throws -> [QueuedMessageRecord] {
        try writer.read { db in
            try QueuedMessageRecord
                .filter(Column("workspaceID") == workspaceID.rawValue)
                .order(Column("id"))
                .fetchAll(db)
        }
    }

    public func queuedMessages(chatID: ChatID) throws -> [QueuedMessageRecord] {
        try writer.read { db in
            try QueuedMessageRecord
                .filter(Column("chatID") == chatID.rawValue)
                .order(Column("id"))
                .fetchAll(db)
        }
    }

    /// Takes the oldest queued message, removing it in the same transaction so
    /// two drains can't deliver the same message twice.
    public func dequeueMessage(workspaceID: WorkspaceID) throws -> QueuedMessageRecord? {
        try writer.write { db in
            guard let record = try QueuedMessageRecord
                .filter(Column("workspaceID") == workspaceID.rawValue)
                .order(Column("id"))
                .fetchOne(db)
            else { return nil }
            try record.delete(db)
            return record
        }
    }

    public func dequeueMessage(chatID: ChatID) throws -> QueuedMessageRecord? {
        try writer.write { db in
            guard let record = try QueuedMessageRecord
                .filter(Column("chatID") == chatID.rawValue)
                .order(Column("id"))
                .fetchOne(db)
            else { return nil }
            try record.delete(db)
            return record
        }
    }

    public func clearQueue(workspaceID: WorkspaceID) throws {
        _ = try writer.write { db in
            try QueuedMessageRecord
                .filter(Column("workspaceID") == workspaceID.rawValue)
                .deleteAll(db)
        }
    }

    public func clearQueue(chatID: ChatID) throws {
        _ = try writer.write { db in
            try QueuedMessageRecord
                .filter(Column("chatID") == chatID.rawValue)
                .deleteAll(db)
        }
    }

    public func updateQueuedMessage(id: Int64, text: String) throws {
        _ = try writer.write { db in
            try QueuedMessageRecord
                .filter(Column("id") == id)
                .updateAll(db, Column("text").set(to: text))
        }
    }

    public func deleteQueuedMessage(id: Int64) throws {
        _ = try writer.write { db in
            try QueuedMessageRecord.deleteOne(db, key: id)
        }
    }

    public func unmarkViewed(workspaceID: WorkspaceID, filePath: String) throws {
        _ = try writer.write { db in
            try ViewedFileRecord
                .filter(Column("workspaceID") == workspaceID.rawValue)
                .filter(Column("filePath") == filePath)
                .deleteAll(db)
        }
    }
}
