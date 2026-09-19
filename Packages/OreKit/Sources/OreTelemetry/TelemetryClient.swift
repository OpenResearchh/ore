import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif

/// What the app talks to. Everything is fire-and-forget: telemetry must never
/// be able to slow down, block, or fail a user action.
public protocol TelemetryRecorder: Sendable {
    nonisolated func record(_ event: TelemetryEvent)
    /// Terminate path only — a synchronous enqueue with no network, so the
    /// row is on disk before the process dies and goes out next launch.
    nonisolated func recordBlocking(_ event: TelemetryEvent)
    func optOut() async
    func optIn() async
    func flush() async
    /// Backs the "show me exactly what is about to be sent" button in
    /// Settings. Being able to read your own queue is worth more to a
    /// developer audience than any promise in a privacy policy.
    func pendingDescriptions() async -> [String]
}

extension TelemetryRecorder {
    /// Sends what is queued now, then again every `interval` until the task
    /// is cancelled.
    ///
    /// Recording only ever wrote to the local queue; nothing in the app called
    /// `flush()`, so no event but the opt-out marker ever reached PostHog. The
    /// schedule lives here, next to the queue, so a host starts it with one
    /// call instead of having to remember to.
    ///
    /// `tolerance` lets the system coalesce the wake-up with others: an idle
    /// ORE should not be woken just to find an empty queue.
    public func deliverPeriodically(
        every interval: Duration,
        tolerance: Duration? = nil
    ) async {
        while !Task.isCancelled {
            await flush()
            do {
                try await Task.sleep(for: interval, tolerance: tolerance)
            } catch {
                return
            }
        }
    }
}

/// The no-op. Returned by `TelemetryClient.make` whenever telemetry is off for
/// any reason, so nothing downstream needs to know it might be disabled.
public struct NoopTelemetry: TelemetryRecorder {
    public init() {}
    public nonisolated func record(_ event: TelemetryEvent) {}
    public nonisolated func recordBlocking(_ event: TelemetryEvent) {}
    public func optOut() async {}
    public func optIn() async {}
    public func flush() async {}
    public func pendingDescriptions() async -> [String] { [] }
}

public actor TelemetryClient: TelemetryRecorder {
    /// The same injectable-transport seam `HarnessUpdateChecker.Fetcher` uses,
    /// so the whole delivery path is testable without a network or an account.
    public typealias Transport = @Sendable (URLRequest) async -> Int?

    public struct Configuration: Sendable {
        public var apiKey: String
        public var endpoint: URL
        public var batchSize: Int
        public var maxQueueRows: Int
        public var maxAttempts: Int

        public init(
            apiKey: String,
            endpoint: URL,
            batchSize: Int = 50,
            maxQueueRows: Int = 5_000,
            maxAttempts: Int = 8
        ) {
            self.apiKey = apiKey
            self.endpoint = endpoint
            self.batchSize = batchSize
            self.maxQueueRows = maxQueueRows
            self.maxAttempts = maxAttempts
        }
    }

    private let configuration: Configuration
    private let store: TelemetryStore
    private let context: TelemetryContext
    private let transport: Transport
    private let now: @Sendable () -> Date

    private var distinctID: String
    private var optedOut = false
    private var flushing = false

    public init(
        configuration: Configuration,
        store: TelemetryStore,
        context: TelemetryContext,
        transport: @escaping Transport = TelemetryClient.liveTransport,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.store = store
        self.context = context
        self.transport = transport
        self.now = now
        self.distinctID = context.installID
        self.optedOut = (try? store.metadata(Keys.optedOut)) == "1"
    }

    // MARK: - Recording

    public nonisolated func record(_ event: TelemetryEvent) {
        Task { await self.enqueue(event) }
    }

    public nonisolated func recordBlocking(_ event: TelemetryEvent) {
        // No actor hop and no network: at terminate, a hop may never be
        // scheduled. GRDB's write is synchronous by design, which is exactly
        // what this moment needs.
        //
        // Consent is read from the store rather than from the actor's own
        // `optedOut`, because this path cannot hop to check it — and a
        // shutdown write that skipped the check would rebuild a queue the
        // user had already had deleted.
        guard !storedOptOut else { return }
        try? persist(event, distinctID: context.installID)
    }

    /// The persisted opt-out, readable without entering the actor.
    private nonisolated var storedOptOut: Bool {
        ((try? store.metadata(Keys.optedOut)) ?? nil) == "1"
    }

    /// Internal rather than private so tests can await the same path that
    /// `record` fires and forgets.
    func enqueue(_ event: TelemetryEvent) async {
        guard !optedOut else { return }
        // Milestones are claimed before the row is written, so a first-time
        // event can never be double-counted even if the app is force-quit
        // mid-flush and the caller retries next launch.
        var recorded = event
        if let key = event.milestoneKey,
           (try? store.claimMilestone(key, at: now())) != true {
            // Someone already claimed it, so this is not the first one. Keep
            // the event and drop only the claim; a recurring milestone that
            // vanished for the rest of the install was the worse bug.
            guard !event.isInstallOnly, let repeated = event.notFirst else { return }
            recorded = repeated
        }
        try? persist(recorded, distinctID: distinctID)
    }

    private nonisolated func persist(
        _ event: TelemetryEvent,
        distinctID: String
    ) throws {
        let payload = TelemetryPayload.properties(
            for: event,
            context: context,
            distinctID: distinctID
        )
        let json = try JSONEncoder.telemetry.encode(payload)
        let row = QueuedEvent(
            insertID: UUID().uuidString,
            name: event.name,
            propertiesJSON: String(decoding: json, as: UTF8.self),
            occurredAt: now()
        )
        try store.enqueue(row, cap: configuration.maxQueueRows)
    }

    // MARK: - Opt out

    /// Stop recording, forget the queue, and send nothing but the marker.
    ///
    /// The order is the whole point. Flushing first — which is what this used
    /// to do — meant the one moment a user's backlog was uploaded was the
    /// moment they asked for it to be deleted, the opposite of what PRIVACY.md
    /// promises. Anything already handed to the transport cannot be recalled,
    /// so the switch flips before the delete and the delete happens before
    /// anything is sent.
    public func optOut() async {
        guard !optedOut else { return }
        optedOut = true
        try? store.setMetadata(Keys.optedOut, "1")
        try? store.deleteAll()
        // The marker alone, so the denominator for every other metric stays
        // honest instead of a user silently vanishing from the population.
        // It carries no properties — see `TelemetryEvent.telemetryOptOut`.
        try? persist(.telemetryOptOut, distinctID: distinctID)
        await deliver()
        try? store.deleteAll()
    }

    public func optIn() async {
        optedOut = false
        try? store.setMetadata(Keys.optedOut, "0")
    }

    // MARK: - Delivery

    public func flush() async {
        guard !optedOut else { return }
        await deliver()
    }

    private func deliver() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }

        while true {
            guard let batch = try? store.due(limit: configuration.batchSize, now: now()), !batch.isEmpty
            else { return }

            guard let request = makeRequest(for: batch) else {
                // Unencodable batch: dropping beats blocking the queue forever.
                try? store.delete(ids: batch.compactMap(\.id))
                continue
            }

            let status = await transport(request)
            let ids = batch.compactMap(\.id)
            if status.map({ !(200...299).contains($0) }) ?? true {
                Self.log("delivery of \(ids.count) events got \(status.map(String.init) ?? "no response")")
            }

            switch status {
            case .some(200...299):
                try? store.delete(ids: ids)
            case .some(400...499) where status != 429:
                // A rejected payload will be rejected identically forever.
                // Retrying it is a poison pill that blocks every event behind
                // it, so it is dropped deliberately.
                try? store.delete(ids: ids)
            default:
                // 429, 5xx, or no response at all: keep the rows and back off.
                let attempts = (batch.map(\.attempts).max() ?? 0) + 1
                if attempts >= configuration.maxAttempts {
                    try? store.delete(ids: ids)
                } else {
                    let delay = min(pow(2.0, Double(attempts)) * 30, 3600)
                    try? store.backOff(ids: ids, until: now().addingTimeInterval(delay))
                }
                return
            }

            if batch.count < configuration.batchSize { return }
        }
    }

    /// Failures used to vanish: a 401 from the wrong key or region deleted
    /// the batch without a trace. Status codes only — never payloads.
    private static func log(_ message: String) {
        #if canImport(os)
        Logger(subsystem: "dev.ore.telemetry", category: "delivery").notice("\(message, privacy: .public)")
        #endif
    }

    private func makeRequest(for batch: [QueuedEvent]) -> URLRequest? {
        let items = batch.compactMap { row -> String? in
            let timestamp = row.occurredAt.formatted(.iso8601)
            return """
                {"event":"\(row.name)","properties":\(row.propertiesJSON),\
                "timestamp":"\(timestamp)","uuid":"\(row.insertID)"}
                """
        }
        guard !items.isEmpty else { return nil }

        let body = """
            {"api_key":"\(configuration.apiKey)","batch":[\(items.joined(separator: ","))]}
            """
        var request = URLRequest(url: configuration.endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ore-telemetry", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(body.utf8)
        return request
    }

    public func pendingDescriptions() async -> [String] {
        guard let rows = try? store.due(limit: 200, now: .distantFuture) else { return [] }
        return rows.map { "\($0.name)  \($0.propertiesJSON)" }
    }

    // MARK: - Live transport

    public static let liveTransport: Transport = { request in
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    enum Keys {
        static let optedOut = "optedOut"
    }
}

// MARK: - Encoding helpers

extension JSONEncoder {
    static let telemetry: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

