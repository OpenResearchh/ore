import Foundation
import Testing

@testable import OreTelemetry

/// Delivery semantics. The queue is the part most likely to lose data
/// silently, so every claim made about it in the plan gets a test here.
@Suite("Telemetry queue survives failure without losing or spamming")
struct TelemetryQueueTests {
    private func scratchHome() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ore-telemetry-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func context() -> TelemetryContext {
        TelemetryContext(
            installID: "install-uuid",
            appVersion: "0.7.2",
            build: "1",
            osVersion: "26.0",
            arch: "arm64",
            installChannel: .installScript,
            sessionID: "session"
        )
    }

    /// An event with no milestone key, so a loop of them actually queues a
    /// row each time rather than being collapsed to one.
    private func repeatable() -> TelemetryEvent {
        .turnCompleted(
            harness: .claudeCode, model: .sonnet, outcome: .completed,
            duration: .to15s, isFirst: false
        )
    }

    private func configuration(endpoint: String = "https://example.invalid/batch/")
        -> TelemetryClient.Configuration
    {
        TelemetryClient.Configuration(
            apiKey: "test-key",
            endpoint: URL(string: endpoint)!,
            batchSize: 50,
            maxQueueRows: 100,
            maxAttempts: 8
        )
    }

    /// Nothing may be dropped just because the network is down.
    @Test("Events survive a failing transport")
    func noLossWhenOffline() async throws {
        let store = try TelemetryStore()
        let client = TelemetryClient(
            configuration: configuration(),
            store: store,
            context: context(),
            transport: { _ in nil }
        )

        for _ in 0..<20 {
            await client.recordForTesting(repeatable())
        }
        await client.flush()

        #expect(try store.count() == 20)
    }

    /// The durability claim: the queue is on disk, not in memory. Closing the
    /// store and reopening the same file must find the rows still there —
    /// this is what makes an offline session on Tuesday still count.
    @Test("The queue survives the store being closed and reopened")
    func survivesRestart() async throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("telemetry.sqlite")

        do {
            let store = try TelemetryStore(path: path)
            let client = TelemetryClient(
                configuration: configuration(), store: store, context: context(),
                transport: { _ in nil }
            )
            for _ in 0..<5 {
                await client.recordForTesting(repeatable())
            }
            await client.flush()
            #expect(try store.count() == 5)
        }

        let reopened = try TelemetryStore(path: path)
        #expect(try reopened.count() == 5, "rows did not survive reopening the database")
    }

    @Test("A successful send clears the queue")
    func successDeletes() async throws {
        let store = try TelemetryStore()
        let client = TelemetryClient(
            configuration: configuration(), store: store, context: context(),
            transport: { _ in 200 }
        )
        for _ in 0..<10 {
            await client.recordForTesting(.pullRequestCreated(isFirst: false))
        }
        await client.flush()
        #expect(try store.count() == 0)
    }

    /// The bug this guards: events were queued and never sent, because
    /// nothing but the tests ever called `flush()`. The schedule has to send
    /// the backlog on its own, and keep sending what arrives after.
    @Test("Periodic delivery sends the backlog and what follows, unprompted")
    func periodicDeliverySends() async throws {
        let store = try TelemetryStore()
        let client = TelemetryClient(
            configuration: configuration(), store: store, context: context(),
            transport: { _ in 200 }
        )
        await client.recordForTesting(repeatable())
        let delivery = Task { await client.deliverPeriodically(every: .milliseconds(50)) }
        defer { delivery.cancel() }

        try await waitUntil { try store.count() == 0 }
        await client.recordForTesting(repeatable())
        try await waitUntil { try store.count() == 0 }
        #expect(try store.count() == 0)
    }

    private func waitUntil(_ condition: () throws -> Bool) async throws {
        for _ in 0..<100 where try !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A 400 means the payload will be rejected identically forever.
    /// Retrying it blocks every event queued behind it, so it must be
    /// dropped rather than retried.
    @Test("A 400 drops the batch instead of poisoning the queue")
    func poisonPillIsDropped() async throws {
        let store = try TelemetryStore()
        let client = TelemetryClient(
            configuration: configuration(), store: store, context: context(),
            transport: { _ in 400 }
        )
        await client.recordForTesting(repeatable())
        await client.flush()
        #expect(try store.count() == 0, "a permanently-rejected row must not be retried forever")
    }

    /// A 429 or 5xx is transient, so the rows stay and back off.
    @Test("A 429 retains the batch and backs off")
    func rateLimitRetains() async throws {
        let store = try TelemetryStore()
        let client = TelemetryClient(
            configuration: configuration(), store: store, context: context(),
            transport: { _ in 429 },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        await client.recordForTesting(repeatable())
        await client.flush()

        #expect(try store.count() == 1)
        // Backed off into the future, so an immediate retry finds nothing due.
        let due = try store.due(limit: 10, now: Date(timeIntervalSince1970: 1_000))
        #expect(due.isEmpty, "a backed-off row must not be immediately retried")
    }

    /// An unbounded queue on a machine that has been offline for a month is a
    /// disk-space bug. Old analytics is the correct thing to lose.
    @Test("The queue is capped and evicts oldest first")
    func queueIsCapped() async throws {
        let store = try TelemetryStore()
        let client = TelemetryClient(
            configuration: configuration(), store: store, context: context(),
            transport: { _ in nil }
        )
        for _ in 0..<150 {
            await client.recordForTesting(repeatable())
        }
        #expect(try store.count() == 100, "queue exceeded maxQueueRows")
    }

    /// The activation funnel depends on `is_first` being true exactly once,
    /// no matter how many times the app claims it. The repeats themselves
    /// still have to be recorded though — they are ordinary pull requests,
    /// and swallowing them made the product look like everyone opened one PR
    /// and stopped.
    @Test("A milestone flag is claimed once; the repeats are still counted")
    func milestonesAreOnce() async throws {
        let store = try TelemetryStore()
        let client = TelemetryClient(
            configuration: configuration(), store: store, context: context(),
            transport: { _ in nil }
        )
        for _ in 0..<5 {
            await client.recordForTesting(.pullRequestCreated(isFirst: true))
        }

        let rows = try store.due(limit: 10, now: Date())
        #expect(rows.count == 5, "repeat events were dropped along with the milestone")
        let firsts = rows.filter { $0.propertiesJSON.contains("\"is_first\":true") }
        #expect(firsts.count == 1, "a first-time milestone was recorded more than once")
    }

    /// `app_installed` has no meaningful repeat: a second one is a bug or a
    /// restored database, and must not become a row.
    @Test("Install-once events are dropped entirely on a repeat")
    func installOnlyMilestonesDoNotRepeat() async throws {
        let store = try TelemetryStore()
        let client = TelemetryClient(
            configuration: configuration(), store: store, context: context(),
            transport: { _ in nil }
        )
        for _ in 0..<3 {
            await client.recordForTesting(.appInstalled(channel: .installScript))
        }
        #expect(try store.count() == 1, "app_installed was recorded more than once")
    }

    /// Opting out sends one final marker so the denominator stays honest,
    /// then goes permanently silent and purges what was pending.
    ///
    /// Counting rows is not enough here: a purge and an upload both leave an
    /// empty table. This records what the transport was actually handed, so
    /// the test can tell "deleted the backlog" from "shipped the backlog on
    /// the way out" — the latter being exactly what a user pressing the
    /// switch is trying to prevent.
    @Test("Opting out uploads only the opt-out marker and then goes silent")
    func optOutIsFinal() async throws {
        let store = try TelemetryStore()
        let sent = Uploads()
        let client = TelemetryClient(
            configuration: configuration(), store: store, context: context(),
            transport: { request in
                sent.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
                return 200
            }
        )
        await client.recordForTesting(repeatable())
        await client.optOut()

        #expect(try store.count() == 0)
        let bodies = sent.all()
        #expect(bodies.count == 1, "opting out made more than one request")
        #expect(bodies.first?.contains("telemetry_opt_out") == true)
        #expect(
            bodies.first?.contains("turn_completed") == false,
            "the queued backlog was uploaded instead of deleted"
        )

        await client.recordForTesting(repeatable())
        await client.flush()
        #expect(try store.count() == 0, "recording continued after opt-out")
        #expect(sent.all().count == 1, "a request was made after opt-out")
    }
}

/// Somewhere for the fake transport, which is called from the client's
/// executor, to leave what it saw.
private final class Uploads: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []

    func append(_ body: String) {
        lock.lock()
        defer { lock.unlock() }
        bodies.append(body)
    }

    func all() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }
}

extension TelemetryClient {
    /// `record` is deliberately fire-and-forget via an unstructured Task,
    /// which is right for production and untestable as-is. This awaits the
    /// same path so assertions are deterministic.
    func recordForTesting(_ event: TelemetryEvent) async {
        await enqueue(event)
    }
}
