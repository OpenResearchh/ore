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
///
/// Reads are `nonisolated`: the actor holds no state of its own, and WAL lets
/// readers run beside the writer, so a sidebar query has no reason to queue
/// behind every agent's transcript write. Writes stay on the actor.
public actor OreStore {
    private let writer: any DatabaseWriter

    /// Where this store lives on disk; nil for the in-memory test store. Lets
    /// the engine hand the database's location to a second process (the
    /// assistant's MCP server) without re-deriving `OreHome` there.
    public nonisolated let url: URL?

    public init(path: URL) throws {
        var configuration = Configuration()
        // WAL plus a busy timeout: the app reads on several tasks while the
        // engine writes, and without this a concurrent read fails outright
        // rather than waiting a few milliseconds.
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            // Under WAL, NORMAL only risks the last commits on power loss, never
            // corruption, and drops an fsync from every transcript write.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }

        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: path.path, configuration: configuration)
        try OreSchema.migrator.migrate(pool)
        self.writer = pool
        self.url = path
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
        self.url = nil
    }

    /// A read-only view of another process's live database — the assistant's
    /// MCP server reads the app's store this way. No migrator on purpose: a
    /// reader must never race the owning process over the schema, and WAL
    /// already lets one writer and this reader coexist.
    public init(readOnlyPath: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(5)
        let queue = try DatabaseQueue(path: readOnlyPath.path, configuration: configuration)
        self.writer = queue
        self.url = readOnlyPath
    }

    public static var defaultURL: URL {
        OreHome.directory.appendingPathComponent("ore.sqlite")
    }

    /// Escape hatch for anything not worth a dedicated method.
    public func write<T: Sendable>(_ body: @Sendable (Database) throws -> T) throws -> T {
        try writer.write(body)
    }

    public nonisolated func read<T: Sendable>(_ body: @Sendable (Database) throws -> T) async throws -> T {
        try await writer.read(body)
    }

    // MARK: - Repositories

    public func addRepository(_ record: RepositoryRecord) throws {
        try writer.write { db in
            try record.save(db)
        }
    }

    /// Every repository the user added. The assistant workspace's home is
    /// registered as a repository too (workspaces have a foreign key to one),
    /// but it is the product's, not the user's, so it never appears here — no
    /// picker should offer to create a workspace in it.
    public nonisolated func repositories() async throws -> [RepositoryRecord] {
        try await writer.read { db in
            try RepositoryRecord.fetchAll(db, sql: """
                SELECT repository.* FROM repository
                WHERE NOT EXISTS (
                    SELECT 1 FROM workspace
                    WHERE workspace.repositoryPath = repository.path
                      AND workspace.kind = 'assistant'
                )
                ORDER BY name
                """)
        }
    }

    // MARK: - Workspaces

    public func saveWorkspace(_ record: WorkspaceRecord) throws {
        try writer.write { db in try record.save(db) }
    }

    public nonisolated func workspace(_ id: WorkspaceID) async throws -> WorkspaceRecord? {
        try await writer.read { db in try WorkspaceRecord.fetchOne(db, key: id.rawValue) }
    }

    /// Sidebar order: pinned first, then most recently active. A workspace the
    /// user pinned is one they're coming back to; recency handles the rest.
    ///
    /// Product-owned workspaces (assistant, dream) are excluded by default so
    /// every existing caller — the sidebar, name uniqueness, engine startup —
    /// keeps seeing only the user's own workspaces.
    public nonisolated func workspaces(
        includeArchived: Bool = false,
        includeAssistant: Bool = false
    ) async throws -> [WorkspaceRecord] {
        try await writer.read { db in
            var request = WorkspaceRecord.all()
            if !includeArchived {
                request = request.filter(Column("isArchived") == false)
            }
            if !includeAssistant {
                request = request.filter(Column("kind") == WorkspaceKind.standard.rawValue)
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

    /// The product-owned assistant workspace, if it has been created.
    public nonisolated func assistantWorkspace() async throws -> WorkspaceRecord? {
        try await writer.read { db in
            try WorkspaceRecord
                .filter(Column("kind") == WorkspaceKind.assistant.rawValue)
                .fetchOne(db)
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
    public nonisolated func children(of id: WorkspaceID) async throws -> [WorkspaceRecord] {
        try await writer.read { db in
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

    public nonisolated func chat(_ id: ChatID) async throws -> ChatRecord? {
        try await writer.read { db in try ChatRecord.fetchOne(db, key: id.rawValue) }
    }

    public nonisolated func chats(
        workspaceID: WorkspaceID, includeClosed: Bool = true
    ) async throws -> [ChatRecord] {
        try await writer.read { db in
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

    public nonisolated func nextChatSortIndex(workspaceID: WorkspaceID) async throws -> Int {
        try await writer.read { db in
            let maximum = try Int.fetchOne(
                db,
                sql: "SELECT MAX(sortIndex) FROM chat WHERE workspaceID = ?",
                arguments: [workspaceID.rawValue]
            )
            return (maximum ?? -1) + 1
        }
    }

    public func saveChatTransition(_ transition: ChatTransition) throws {
        try writer.write { db in try ChatTransitionRecord(transition).save(db) }
    }

    public nonisolated func chatTransitions(chatID: ChatID) async throws -> [ChatTransition] {
        try await writer.read { db in
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

    public nonisolated func latestSession(for workspaceID: WorkspaceID) async throws -> SessionRecord? {
        try await writer.read { db in
            try SessionRecord
                .filter(Column("workspaceID") == workspaceID.rawValue)
                .order(Column("startedAt").desc)
                .fetchOne(db)
        }
    }

    public nonisolated func latestSession(for chatID: ChatID) async throws -> SessionRecord? {
        try await writer.read { db in
            try SessionRecord
                .filter(Column("chatID") == chatID.rawValue)
                .order(Column("startedAt").desc)
                .fetchOne(db)
        }
    }

    public nonisolated func session(_ id: SessionID) async throws -> SessionRecord? {
        try await writer.read { db in try SessionRecord.fetchOne(db, key: id.rawValue) }
    }

    public func saveTurn(_ record: TurnRecord) throws {
        try writer.write { db in try record.save(db) }
    }

    public nonisolated func nextTurnOrdinal(sessionID: SessionID) async throws -> Int {
        try await writer.read { db in
            let maximum = try Int.fetchOne(
                db,
                sql: "SELECT MAX(ordinal) FROM turn WHERE sessionID = ?",
                arguments: [sessionID.rawValue]
            )
            return (maximum ?? -1) + 1
        }
    }

    public nonisolated func turns(sessionID: SessionID) async throws -> [TurnRecord] {
        try await writer.read { db in
            try TurnRecord
                .filter(Column("sessionID") == sessionID.rawValue)
                .order(Column("ordinal"))
                .fetchAll(db)
        }
    }

    /// The newest turn of a conversation without materialising the transcript:
    /// one row, ordered the same way `turns(chatID:)` is, cheap enough for
    /// every sidebar row to ask for its snippet line.
    public nonisolated func latestTurn(chatID: ChatID) async throws -> TurnRecord? {
        try await writer.read { db in
            try TurnRecord.fetchOne(
                db,
                sql: """
                    SELECT turn.*
                    FROM turn
                    JOIN session ON session.id = turn.sessionID
                    WHERE session.chatID = ?
                    ORDER BY session.startedAt DESC, turn.ordinal DESC, turn.startedAt DESC
                    LIMIT 1
                    """,
                arguments: [chatID.rawValue]
            )
        }
    }

    /// The visible transcript belongs to the chat, not to any one provider
    /// incarnation. Sessions are ordered first so ordinals can restart at zero
    /// after a cross-harness handoff without scrambling history.
    public nonisolated func turns(chatID: ChatID) async throws -> [TurnRecord] {
        try await writer.read { db in
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

    /// How long a conversation is, without materialising it — `turns(chatID:)`
    /// loads every row and then every text block behind it, which is far too
    /// much to do on the path a turn completes through.
    ///
    /// `excludingOrigins` is what makes the number mean "turns the person
    /// had". The assistant's chat also carries ORE's own fleet digests, and a
    /// conversation length that counts those describes the fleet, not the user.
    public nonisolated func turnCount(
        chatID: ChatID, excludingOrigins: Set<MessageOrigin> = []
    ) async throws -> Int {
        try await writer.read { db in
            var sql = """
                SELECT COUNT(*)
                FROM turn
                JOIN session ON session.id = turn.sessionID
                WHERE session.chatID = ?
                """
            var arguments: [DatabaseValueConvertible] = [chatID.rawValue]
            if !excludingOrigins.isEmpty {
                let holes = excludingOrigins.map { _ in "?" }.joined(separator: ", ")
                sql += " AND turn.promptOrigin NOT IN (\(holes))"
                arguments += excludingOrigins.map(\.rawValue)
            }
            return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(arguments)) ?? 0
        }
    }

    /// The conversation as prose, for a model that is about to summarize it.
    ///
    /// Deliberately not `handoffContext`: that one hands a *successor session*
    /// enough to keep going and is near-verbatim by design. This is raw
    /// material to be compressed, so it reaches further back and clips each
    /// turn hard — breadth matters more than fidelity when the next step is a
    /// summary, and an unbounded transcript is exactly what compaction exists
    /// to escape.
    public nonisolated func conversationTranscript(
        chatID: ChatID,
        excludingOrigins: Set<MessageOrigin> = [],
        turnLimit: Int = 60,
        charactersPerTurn: Int = 700
    ) async throws -> String? {
        let turns = try await turns(chatID: chatID)
            .filter { !excludingOrigins.contains(MessageOrigin(rawValue: $0.promptOrigin) ?? .user) }
            .suffix(turnLimit)
        guard !turns.isEmpty else { return nil }

        var exchanges: [String] = []
        for turn in turns {
            var parts: [String] = []
            if let prompt = turn.prompt, !prompt.isEmpty {
                parts.append("User: \(String(prompt.prefix(charactersPerTurn)))")
            }
            // The stored summary is the reply's own text, so it saves loading
            // every block for turns whose blocks would only be re-clipped.
            let blocks = (try? await blocks(turnID: turn.turnID)) ?? []
            let reply = turn.summary ?? blocks
                .filter { $0.blockKind == .text }
                .map(\.text)
                .joined(separator: "\n")
            if !reply.isEmpty {
                parts.append("Assistant: \(String(reply.prefix(charactersPerTurn)))")
            }
            if let plan = Self.planTranscriptLine(in: blocks) {
                parts.append(String(plan.prefix(charactersPerTurn)))
            }
            if !parts.isEmpty { exchanges.append(parts.joined(separator: "\n")) }
        }
        return exchanges.isEmpty ? nil : exchanges.joined(separator: "\n\n")
    }

    public nonisolated func handoffContext(
        chatID: ChatID, transcriptTailLimit: Int = 8
    ) async throws -> String? {
        let turns = try await turns(chatID: chatID)
        guard !turns.isEmpty else { return nil }

        var sections: [String] = []
        let summaries = turns.compactMap(\.summary).filter { !$0.isEmpty }
        if !summaries.isEmpty {
            sections.append("Prior turn summaries:\n" + summaries.suffix(12).map { "- \($0)" }.joined(separator: "\n"))
        }

        var transcript: [String] = []
        for turn in turns.suffix(transcriptTailLimit) {
            var parts: [String] = []
            if let prompt = turn.prompt, !prompt.isEmpty { parts.append("User: \(prompt)") }
            let blocks = (try? await blocks(turnID: turn.turnID)) ?? []
            let text = blocks
                .filter { $0.blockKind == .text }
                .map(\.text)
                .joined(separator: "\n")
            if !text.isEmpty { parts.append("Assistant: \(String(text.suffix(4_000)))") }
            if let plan = Self.planTranscriptLine(in: blocks) {
                parts.append(plan)
            }
            if !parts.isEmpty { transcript.append(parts.joined(separator: "\n")) }
        }
        if !transcript.isEmpty {
            sections.append("Recent transcript:\n" + transcript.joined(separator: "\n\n"))
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    /// Plan blocks are a first-class transcript row, but they used to be
    /// dropped here — so "read the plan" saw only "I'll inspect…" text while
    /// approval controls were already on screen.
    private static func planTranscriptLine(in blocks: [BlockRecord]) -> String? {
        let plans = blocks.filter {
            $0.blockKind == .plan && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let block = plans.last else { return nil }
        let payload = block.decodedPayload
        if payload?.arrayValue != nil {
            return "Todos:\n\(block.text)"
        }
        let ready = payload?["isReady"]?.boolValue ?? true
        let label = ready ? "Plan" : "Plan (still being written)"
        return "\(label):\n\(block.text)"
    }

    public nonisolated func turn(_ id: TurnID) async throws -> TurnRecord? {
        try await writer.read { db in try TurnRecord.fetchOne(db, key: id.rawValue) }
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

    public nonisolated func block(_ id: String) async throws -> BlockRecord? {
        try await writer.read { db in try BlockRecord.fetchOne(db, key: id) }
    }

    public func appendBlocks(_ records: [BlockRecord]) throws {
        guard !records.isEmpty else { return }
        try writer.write { db in
            for record in records { try record.save(db) }
        }
    }

    public nonisolated func blocks(turnID: TurnID) async throws -> [BlockRecord] {
        try await writer.read { db in
            try BlockRecord
                .filter(Column("turnID") == turnID.rawValue)
                .order(Column("ordinal"))
                .fetchAll(db)
        }
    }

    /// Every block of a conversation in one read, for loading its history
    /// without a query per turn.
    ///
    /// Shape: one entry per turn that has blocks, in `turns(chatID:)` order,
    /// each holding that turn's blocks by ordinal. Turns without blocks are
    /// absent, so pair the result with `turns(chatID:)` by `turnID`.
    public nonisolated func blocks(
        chatID: ChatID
    ) async throws -> [(turnID: TurnID, blocks: [BlockRecord])] {
        let records = try await writer.read { db in
            try BlockRecord.fetchAll(
                db,
                sql: """
                    SELECT block.*
                    FROM block
                    JOIN turn ON turn.id = block.turnID
                    JOIN session ON session.id = turn.sessionID
                    WHERE session.chatID = ?
                    ORDER BY session.startedAt, turn.ordinal, turn.startedAt, block.turnID,
                             block.ordinal
                    """,
                arguments: [chatID.rawValue]
            )
        }
        var grouped: [(turnID: TurnID, blocks: [BlockRecord])] = []
        for record in records {
            if grouped.last?.turnID.rawValue == record.turnID {
                grouped[grouped.count - 1].blocks.append(record)
            } else {
                grouped.append((TurnID(rawValue: record.turnID), [record]))
            }
        }
        return grouped
    }

    public nonisolated func nextBlockOrdinal(turnID: TurnID) async throws -> Int {
        try await writer.read { db in
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
        /// The tab the hit is in. Optional only because `session.chatID` was
        /// added by a migration; every session written since carries one.
        public var chatID: ChatID?
        public var chatTitle: String?
        /// Closed tabs keep their history but are not a place to send more
        /// work — the assistant should ReopenChat or CreateChat instead.
        public var isClosed: Bool
        public var turnID: TurnID
        public var blockID: String
        public var snippet: String
        public var createdAt: Date
    }

    /// Which conversations a search is allowed to look at.
    ///
    /// The assistant's own conversations are a different kind of history from
    /// a project's: they are what the *user and the assistant* said, not what
    /// an agent did in a repository. Mixing them into every fleet-wide search
    /// buries the project hit that was asked for, so the caller says which it
    /// means rather than getting both by accident.
    public enum SearchScope: String, Sendable, CaseIterable {
        case projects
        case assistant
        case all

        fileprivate var predicate: String {
            switch self {
            case .projects: "AND workspace.kind != 'assistant'"
            case .assistant: "AND workspace.kind = 'assistant'"
            case .all: ""
            }
        }
    }

    /// Full-text search across transcripts, newest first.
    ///
    /// This is what makes "which workspace was I doing the migration in?"
    /// answerable — with several agents running in parallel, the user's own
    /// memory stops being a reliable index. Hits name the *tab*, not just the
    /// workspace: the answer to "where was I doing X" is only useful if the
    /// follow-up can be sent to the conversation that was already carrying it.
    public nonisolated func search(
        _ query: String,
        scope: SearchScope = .projects,
        workspaceID: WorkspaceID? = nil,
        limit: Int = 50
    ) async throws -> [SearchHit] {
        let pattern = FTS5Pattern(matchingAllPrefixesIn: query)
        guard let pattern else { return [] }

        var values: [any DatabaseValueConvertible] = [pattern]
        let workspaceClause = workspaceID == nil ? "" : "AND workspace.id = ?"
        if let workspaceID {
            values.append(workspaceID.rawValue)
        }
        values.append(limit)
        let arguments: StatementArguments = StatementArguments(values)

        return try await writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    workspace.id AS workspaceID,
                    workspace.name AS workspaceName,
                    session.chatID AS chatID,
                    chat.title AS chatTitle,
                    chat.isClosed AS isClosed,
                    block.turnID AS turnID,
                    block.id AS blockID,
                    snippet(blockSearch, 0, '«', '»', '…', 12) AS snippet,
                    block.createdAt AS createdAt
                FROM blockSearch
                JOIN block ON block.rowid = blockSearch.rowid
                JOIN turn ON turn.id = block.turnID
                JOIN session ON session.id = turn.sessionID
                JOIN workspace ON workspace.id = session.workspaceID
                LEFT JOIN chat ON chat.id = session.chatID
                WHERE blockSearch MATCH ? \(scope.predicate) \(workspaceClause)
                ORDER BY block.createdAt DESC
                LIMIT ?
                """,
                arguments: arguments
            )
            return rows.map { row in
                SearchHit(
                    workspaceID: WorkspaceID(rawValue: row["workspaceID"]),
                    workspaceName: row["workspaceName"],
                    chatID: (row["chatID"] as String?).map(ChatID.init(rawValue:)),
                    chatTitle: row["chatTitle"],
                    isClosed: (row["isClosed"] as Bool?) ?? false,
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

    public nonisolated func pendingDiffComments(workspaceID: WorkspaceID) async throws -> [DiffCommentRecord] {
        try await writer.read { db in
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

    public func deletePendingDiffComments(
        workspaceID: WorkspaceID,
        matching references: [DiffCommentReference]
    ) throws {
        let keys = Set(references.map(\.identityKey))
        guard !keys.isEmpty else { return }
        try writer.write { db in
            let pending = try DiffCommentRecord
                .filter(Column("workspaceID") == workspaceID.rawValue)
                .filter(Column("isSent") == false)
                .fetchAll(db)
            for record in pending where keys.contains(record.reference.identityKey) {
                if let id = record.id {
                    try DiffCommentRecord.deleteOne(db, key: id)
                }
            }
        }
    }

    public func markViewed(_ record: ViewedFileRecord) throws {
        try writer.write { db in try record.save(db) }
    }

    public nonisolated func viewedFiles(workspaceID: WorkspaceID) async throws -> [String: String] {
        try await writer.read { db in
            let records = try ViewedFileRecord
                .filter(Column("workspaceID") == workspaceID.rawValue)
                .fetchAll(db)
            return Dictionary(
                records.map { ($0.filePath, $0.contentHash) },
                uniquingKeysWith: { _, last in last }
            )
        }
    }

    // MARK: - Assistant actions

    public func recordAssistantAction(_ record: AssistantActionRecord) throws {
        try writer.write { db in
            var record = record
            try record.insert(db)
        }
    }

    public nonisolated func assistantActions(limit: Int = 200) async throws -> [AssistantActionRecord] {
        try await writer.read { db in
            try AssistantActionRecord
                .order(Column("createdAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func saveAssistantGrant(_ actionClass: String) throws {
        try writer.write { db in
            try AssistantGrantRecord(actionClass: actionClass).save(db)
        }
    }

    public nonisolated func assistantGrants() async throws -> [String] {
        try await writer.read { db in
            try AssistantGrantRecord.fetchAll(db).map(\.actionClass)
        }
    }

    public func deleteAssistantGrant(_ actionClass: String) throws {
        _ = try writer.write { db in
            try AssistantGrantRecord.deleteOne(db, key: actionClass)
        }
    }

    public func saveAssistantTabGrant(_ chatID: ChatID) throws {
        try writer.write { db in
            try AssistantTabGrantRecord(chatID: chatID).save(db)
        }
    }

    public nonisolated func assistantTabGrants() async throws -> [ChatID] {
        try await writer.read { db in
            try AssistantTabGrantRecord.fetchAll(db).map(\.id)
        }
    }

    public nonisolated func hasAssistantTabGrant(_ chatID: ChatID) async throws -> Bool {
        try await writer.read { db in
            try AssistantTabGrantRecord.fetchOne(db, key: chatID.rawValue) != nil
        }
    }

    public func deleteAssistantTabGrant(_ chatID: ChatID) throws {
        _ = try writer.write { db in
            try AssistantTabGrantRecord.deleteOne(db, key: chatID.rawValue)
        }
    }

    // MARK: - Repository script approvals

    /// `ore.toml` scripts run as the user, so they run only after the user has
    /// seen them. The approval covers this exact text; an edit asks again.
    public func approveRepositoryScripts(
        repositoryPath: String, setup: String?, run: String?, archive: String?
    ) throws {
        try writer.write { db in
            try RepositoryScriptApprovalRecord(
                repositoryPath: repositoryPath, setup: setup, run: run, archive: archive
            ).save(db)
        }
    }

    public nonisolated func repositoryScriptsApproved(
        repositoryPath: String, setup: String?, run: String?, archive: String?
    ) async throws -> Bool {
        try await writer.read { db in
            guard let record = try RepositoryScriptApprovalRecord.fetchOne(db, key: repositoryPath) else {
                return false
            }
            return record.setup == setup && record.run == run && record.archive == archive
        }
    }

    // MARK: - Message queue

    public func enqueueMessage(_ record: QueuedMessageRecord) throws {
        try writer.write { db in
            var record = record
            record.sortIndex = (try Int64.fetchOne(db, sql: "SELECT MAX(sortIndex) FROM queuedMessage") ?? 0) + 1
            try record.insert(db)
        }
    }

    public nonisolated func queuedMessages(workspaceID: WorkspaceID) async throws -> [QueuedMessageRecord] {
        try await writer.read { db in
            try QueuedMessageRecord
                .filter(Column("workspaceID") == workspaceID.rawValue)
                .order(Column("sortIndex"), Column("id"))
                .fetchAll(db)
        }
    }

    public nonisolated func queuedMessages(chatID: ChatID) async throws -> [QueuedMessageRecord] {
        try await writer.read { db in
            try QueuedMessageRecord
                .filter(Column("chatID") == chatID.rawValue)
                .order(Column("sortIndex"), Column("id"))
                .fetchAll(db)
        }
    }

    /// Takes the first queued message in the user's order, removing it in the same transaction so
    /// two drains can't deliver the same message twice.
    public func dequeueMessage(workspaceID: WorkspaceID) throws -> QueuedMessageRecord? {
        try writer.write { db in
            guard let record = try QueuedMessageRecord
                .filter(Column("workspaceID") == workspaceID.rawValue)
                .order(Column("sortIndex"), Column("id"))
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
                .order(Column("sortIndex"), Column("id"))
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

    /// Move within the current queue in one transaction. A message that has
    /// already drained is ignored; identity, attachments and timestamps stay intact.
    public func moveQueuedMessage(id: Int64, direction: Int) throws {
        guard direction == -1 || direction == 1 else { return }
        try writer.write { db in
            guard let record = try QueuedMessageRecord.fetchOne(db, key: id) else { return }
            let records = try QueuedMessageRecord
                .filter(Column("workspaceID") == record.workspaceID)
                .filter(Column("chatID") == record.chatID)
                .order(Column("sortIndex"), Column("id"))
                .fetchAll(db)
            guard let index = records.firstIndex(where: { $0.id == id }),
                  records.indices.contains(index + direction) else { return }
            let neighbor = records[index + direction]
            try QueuedMessageRecord.filter(Column("id") == id)
                .updateAll(db, Column("sortIndex").set(to: neighbor.sortIndex))
            try QueuedMessageRecord.filter(Column("id") == neighbor.id)
                .updateAll(db, Column("sortIndex").set(to: record.sortIndex))
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

    // MARK: - Dream Mode

    public func saveDreamRun(_ record: DreamRunRecord) throws {
        try writer.write { db in try record.save(db) }
    }

    public nonisolated func dreamRun(_ id: DreamRunID) async throws -> DreamRunRecord? {
        try await writer.read { db in try DreamRunRecord.fetchOne(db, key: id.rawValue) }
    }

    public nonisolated func latestDreamRun() async throws -> DreamRunRecord? {
        try await writer.read { db in
            try DreamRunRecord
                .order(Column("createdAt").desc)
                .fetchOne(db)
        }
    }

    public nonisolated func activeDreamRun() async throws -> DreamRunRecord? {
        try await writer.read { db in
            try DreamRunRecord.fetchOne(
                db,
                sql: """
                SELECT * FROM dreamRun
                WHERE state IN ('planned', 'dreaming', 'paused', 'windingDown')
                ORDER BY createdAt DESC
                LIMIT 1
                """
            )
        }
    }

    public func saveDreamTask(_ record: DreamTaskRecord) throws {
        try writer.write { db in try record.save(db) }
    }

    public nonisolated func dreamTask(_ id: DreamTaskID) async throws -> DreamTaskRecord? {
        try await writer.read { db in try DreamTaskRecord.fetchOne(db, key: id.rawValue) }
    }

    public nonisolated func dreamTasks(runID: DreamRunID) async throws -> [DreamTaskRecord] {
        try await writer.read { db in
            try DreamTaskRecord
                .filter(Column("runID") == runID.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    public func saveDreamFinding(_ record: DreamFindingRecord) throws {
        try writer.write { db in try record.save(db) }
    }

    public nonisolated func dreamFinding(_ id: DreamFindingID) async throws -> DreamFindingRecord? {
        try await writer.read { db in try DreamFindingRecord.fetchOne(db, key: id.rawValue) }
    }

    public nonisolated func dreamFinding(dedupeKey: String) async throws -> DreamFindingRecord? {
        try await writer.read { db in
            try DreamFindingRecord
                .filter(Column("dedupeKey") == dedupeKey)
                .order(Column("lastSeenAt").desc)
                .fetchOne(db)
        }
    }

    public nonisolated func dreamFindings(
        statuses: [DreamFindingStatus] = DreamFindingStatus.allCases
    ) async throws -> [DreamFindingRecord] {
        try await writer.read { db in
            let placeholders = statuses.map { _ in "?" }.joined(separator: ", ")
            return try DreamFindingRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM dreamFinding
                WHERE status IN (\(placeholders))
                ORDER BY createdAt DESC
                """,
                arguments: StatementArguments(statuses.map(\.rawValue))
            )
        }
    }

    public func appendDreamLedger(_ record: DreamLedgerRecord) throws {
        try writer.write { db in
            var record = record
            try record.insert(db)
        }
    }

    public nonisolated func dreamLedgerTokens(runID: DreamRunID) async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(tokens), 0) FROM dreamLedger WHERE runID = ?",
                arguments: [runID.rawValue]
            ) ?? 0
        }
    }

    public nonisolated func dreamLedgerTokens(since: Date) async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(tokens), 0) FROM dreamLedger WHERE createdAt >= ?",
                arguments: [since]
            ) ?? 0
        }
    }

    public nonisolated func dreamFindings(runID: DreamRunID) async throws -> [DreamFindingRecord] {
        try await writer.read { db in
            try DreamFindingRecord
                .filter(Column("runID") == runID.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    public nonisolated func dreamKindAcceptance() async throws -> [DreamKindAcceptance] {
        try await writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    dreamTask.repositoryPath AS repositoryPath,
                    dreamTask.kind AS kind,
                    SUM(CASE WHEN dreamFinding.status = 'accepted' THEN 1 ELSE 0 END) AS accepted,
                    SUM(CASE WHEN dreamFinding.status = 'rejected' THEN 1 ELSE 0 END) AS rejected
                FROM dreamFinding
                JOIN dreamTask ON dreamTask.id = dreamFinding.taskID
                WHERE dreamFinding.status IN ('accepted', 'rejected')
                GROUP BY dreamTask.repositoryPath, dreamTask.kind
                """
            )
            return rows.compactMap { row in
                guard let kind = DreamKind(rawValue: row["kind"]) else { return nil }
                return DreamKindAcceptance(
                    repositoryPath: row["repositoryPath"],
                    kind: kind,
                    accepted: Int(row["accepted"] as Int64),
                    rejected: Int(row["rejected"] as Int64)
                )
            }
        }
    }

    public func resurfaceDeferredDreamFindings(now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE dreamFinding
                SET status = 'new', deferredUntil = NULL, lastSeenAt = ?
                WHERE status = 'deferred'
                  AND deferredUntil IS NOT NULL
                  AND deferredUntil <= ?
                """,
                arguments: [now, now]
            )
        }
    }

    public func expireStaleDreamFindings(
        now: Date = Date(),
        olderThan: TimeInterval = DreamRetention.findingDays
    ) throws {
        let cutoff = now.addingTimeInterval(-olderThan)
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE dreamFinding
                SET status = 'expired', lastSeenAt = ?
                WHERE status = 'new'
                  AND createdAt < ?
                """,
                arguments: [now, cutoff]
            )
        }
    }

    /// 14-day turn activity per user repository, plus whether any pinned
    /// workspace on that repo is sitting untouched.
    public nonisolated func dreamRepositoryActivity(since: Date) async throws -> [DreamRepositoryActivity] {
        try await writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    repository.path AS repositoryPath,
                    repository.name AS repositoryName,
                    COALESCE(activity.turnCount, 0) AS turnCount,
                    activity.lastTurnAt AS lastTurnAt,
                    EXISTS(
                        SELECT 1 FROM workspace
                        WHERE workspace.repositoryPath = repository.path
                          AND workspace.kind = 'standard'
                          AND workspace.isArchived = 0
                          AND workspace.isPinned = 1
                    ) AS isPinned
                FROM repository
                LEFT JOIN (
                    SELECT
                        workspace.repositoryPath AS repositoryPath,
                        COUNT(*) AS turnCount,
                        MAX(turn.startedAt) AS lastTurnAt
                    FROM turn
                    JOIN session ON session.id = turn.sessionID
                    JOIN workspace ON workspace.id = session.workspaceID
                    WHERE workspace.kind = 'standard'
                      AND turn.startedAt > ?
                    GROUP BY workspace.repositoryPath
                ) AS activity ON activity.repositoryPath = repository.path
                WHERE NOT EXISTS (
                    SELECT 1 FROM workspace
                    WHERE workspace.repositoryPath = repository.path
                      AND workspace.kind = 'assistant'
                )
                ORDER BY turnCount DESC, repositoryName ASC
                """,
                arguments: [since]
            )
            return rows.map { row in
                DreamRepositoryActivity(
                    repositoryPath: row["repositoryPath"],
                    repositoryName: row["repositoryName"],
                    turnCount: row["turnCount"],
                    lastTurnAt: row["lastTurnAt"],
                    isPinned: (row["isPinned"] as Int64) != 0
                )
            }
        }
    }

    /// Hour-of-day histogram of the user's own turns, used to recommend quiet
    /// hours. Computed off the render loop on purpose.
    public nonisolated func quietHoursRecommendation(now: Date = Date()) async throws -> QuietHoursRecommendation? {
        let since = now.addingTimeInterval(-14 * 24 * 3600)
        let hours: [Int] = try await writer.read { db in
            try Int.fetchAll(
                db,
                sql: """
                SELECT CAST(strftime('%H', turn.startedAt) AS INTEGER)
                FROM turn
                JOIN session ON session.id = turn.sessionID
                JOIN workspace ON workspace.id = session.workspaceID
                WHERE workspace.kind = 'standard'
                  AND turn.promptOrigin = 'user'
                  AND turn.startedAt > ?
                """,
                arguments: [since]
            )
        }
        guard hours.count >= 20 else { return nil }
        var counts = Array(repeating: 0, count: 24)
        for hour in hours {
            guard (0..<24).contains(hour) else { continue }
            counts[hour] += 1
        }
        // Six-hour window with the fewest turns.
        var bestStart = 1
        var bestSum = Int.max
        for start in 0..<24 {
            var sum = 0
            for offset in 0..<6 {
                sum += counts[(start + offset) % 24]
            }
            if sum < bestSum {
                bestSum = sum
                bestStart = start
            }
        }
        let end = (bestStart + 6) % 24
        let startMinutes = bestStart * 60
        let endMinutes = end * 60
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        func clock(_ minutes: Int) -> String {
            let comps = DateComponents(hour: minutes / 60, minute: minutes % 60)
            let date = Calendar.current.date(from: comps) ?? Date()
            return formatter.string(from: date)
        }
        return QuietHoursRecommendation(
            startMinutes: startMinutes,
            endMinutes: endMinutes,
            reason: "You're rarely active \(clock(startMinutes))–\(clock(endMinutes))"
        )
    }
}
