import Foundation
import GRDB

/// The durable event queue.
///
/// Deliberately its own database (`$ORE_HOME/telemetry.sqlite`) rather than a
/// table inside `ore.sqlite`. Three reasons, all of which bite in practice:
///
///  1. `OreStore` runs with `PRAGMA foreign_keys = ON` and every table hangs
///     off `repository`/`workspace` with `onDelete: .cascade`. Telemetry rows
///     have no parent, and must specifically *survive* a workspace being
///     removed.
///  2. When the main store fails to open, the app falls back to an in-memory
///     one. That failure is precisely the thing worth reporting, and an
///     in-memory queue would drop the report on quit.
///  3. It keeps `OrePersistence` and `OreCore` free of any notion of
///     telemetry, which is what lets OreKit stay a library with no network
///     beacons in it.
public final class TelemetryStore: Sendable {
    /// GRDB's `DatabasePool` is already thread-safe, so this is a plain
    /// Sendable class rather than an actor. That matters at exactly one
    /// moment: `applicationWillTerminate`, where we need a synchronous write
    /// to land before the process goes away and an actor hop may not run.
    private let writer: any DatabaseWriter

    public let url: URL?

    public init(path: URL) throws {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)

        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: path.path, configuration: configuration)
        try TelemetrySchema.migrator.migrate(pool)
        self.writer = pool
        self.url = path
    }

    /// In-memory, for tests.
    public init() throws {
        let queue = try DatabaseQueue()
        try TelemetrySchema.migrator.migrate(queue)
        self.writer = queue
        self.url = nil
    }

    // MARK: - Queue

    /// Appends an event, evicting the oldest rows if the queue has grown past
    /// `cap`. A queue that grows without bound on a machine that has been
    /// offline for a month is a disk-space bug, and dropping the oldest
    /// analytics is the correct thing to lose.
    public func enqueue(_ row: QueuedEvent, cap: Int) throws {
        try writer.write { db in
            var row = row
            try row.insert(db)
            let count = try QueuedEvent.fetchCount(db)
            if count > cap {
                let excess = count - cap
                try db.execute(
                    sql: """
                        DELETE FROM telemetryEvent WHERE id IN
                        (SELECT id FROM telemetryEvent ORDER BY id ASC LIMIT ?)
                        """,
                    arguments: [excess]
                )
            }
        }
    }

    /// The next batch that is due, oldest first. Rows backing off after a
    /// failure are skipped until their `nextAttemptAt` passes.
    public func due(limit: Int, now: Date) throws -> [QueuedEvent] {
        try writer.read { db in
            try QueuedEvent
                .filter(sql: "nextAttemptAt IS NULL OR nextAttemptAt <= ?", arguments: [now])
                .order(sql: "id ASC")
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func delete(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        _ = try writer.write { db in try QueuedEvent.deleteAll(db, keys: ids) }
    }

    public func deleteAll() throws {
        _ = try writer.write { db in try QueuedEvent.deleteAll(db) }
    }

    public func count() throws -> Int {
        try writer.read { db in try QueuedEvent.fetchCount(db) }
    }

    /// Records a delivery failure and pushes the rows out to `nextAttemptAt`.
    public func backOff(ids: [Int64], until: Date) throws {
        guard !ids.isEmpty else { return }
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE telemetryEvent SET attempts = attempts + 1, nextAttemptAt = ?
                    WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                    """,
                arguments: StatementArguments([until] + ids.map { $0 as DatabaseValueConvertible })
            )
        }
    }

    // MARK: - Metadata

    public func metadata(_ key: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM telemetryMeta WHERE key = ?", arguments: [key])
        }
    }

    public func setMetadata(_ key: String, _ value: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO telemetryMeta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, value]
            )
        }
    }

    /// Claims a first-time milestone. Returns true only for the first caller,
    /// ever, on this install — which is what makes the activation funnel
    /// immune to retries and clock skew.
    public func claimMilestone(_ name: String, at date: Date) throws -> Bool {
        try writer.write { db in
            let existing = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM telemetryMilestone WHERE name = ?", arguments: [name]
            )
            guard existing == 0 else { return false }
            try db.execute(
                sql: "INSERT INTO telemetryMilestone (name, firstAt) VALUES (?, ?)",
                arguments: [name, date]
            )
            return true
        }
    }
}

// MARK: - Row

public struct QueuedEvent: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "telemetryEvent"

    public var id: Int64?
    /// Sent as PostHog's `$insert_id`, written once at enqueue. A retried
    /// batch is then deduplicated server-side instead of double-counting,
    /// which is the difference between "roughly DAU" and DAU.
    public var insertID: String
    public var name: String
    public var propertiesJSON: String
    /// Stamped at enqueue, not at send, so a session that happened on Tuesday
    /// still lands on Tuesday when an offline machine flushes it on Thursday.
    public var occurredAt: Date
    public var attempts: Int
    public var nextAttemptAt: Date?

    public init(
        id: Int64? = nil,
        insertID: String,
        name: String,
        propertiesJSON: String,
        occurredAt: Date,
        attempts: Int = 0,
        nextAttemptAt: Date? = nil
    ) {
        self.id = id
        self.insertID = insertID
        self.name = name
        self.propertiesJSON = propertiesJSON
        self.occurredAt = occurredAt
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - Schema

enum TelemetrySchema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1.queue") { db in
            try db.create(table: "telemetryEvent") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("insertID", .text).notNull().unique()
                table.column("name", .text).notNull()
                table.column("propertiesJSON", .text).notNull()
                table.column("occurredAt", .datetime).notNull()
                table.column("attempts", .integer).notNull().defaults(to: 0)
                table.column("nextAttemptAt", .datetime)
            }
            try db.create(
                index: "telemetryEvent_on_nextAttempt",
                on: "telemetryEvent",
                columns: ["nextAttemptAt", "id"]
            )

            // Install ID, opt-out state, the last-launch stamp.
            try db.create(table: "telemetryMeta") { table in
                table.primaryKey("key", .text)
                table.column("value", .text).notNull()
            }

            // Locally authoritative first-time flags for the activation funnel.
            try db.create(table: "telemetryMilestone") { table in
                table.primaryKey("name", .text)
                table.column("firstAt", .datetime).notNull()
            }
        }

        return migrator
    }
}
