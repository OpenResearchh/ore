import Foundation

/// Read-only access to the local queue, for Settings → Privacy.
///
/// PRIVACY.md promises "Show pending events prints the exact rows queued on
/// your machine, before they are sent". A promise like that is only worth
/// anything if the UI reads the same database the client writes, so this
/// opens the real store rather than mirroring state in the app.
///
/// Deliberately separate from `TelemetryClient`: it must work when telemetry
/// is off and the recorder is a no-op, which is precisely when someone is
/// most likely to go looking.
public enum TelemetryInspection {
    public struct PendingEvent: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let occurredAt: Date
        /// The serialized properties, exactly as they would be uploaded.
        public let properties: String
    }

    /// The anonymous ID that identifies this install to PostHog, and the only
    /// value someone needs in order to ask for their data to be deleted.
    public static func installID(home: URL) -> String? {
        guard let store = openStore(home: home) else { return nil }
        return (try? store.metadata(TelemetryContext.Keys.installID)) ?? nil
    }

    public static func pending(home: URL, limit: Int = 200) -> [PendingEvent] {
        guard let store = openStore(home: home) else { return [] }
        // `distantFuture` rather than `now` so rows that are backed off after
        // a failed send are shown too. Hiding them would mean the list said
        // "nothing pending" while the queue was full.
        let rows = (try? store.due(limit: limit, now: .distantFuture)) ?? []
        return rows.map {
            PendingEvent(
                id: $0.insertID,
                name: $0.name,
                occurredAt: $0.occurredAt,
                properties: $0.propertiesJSON
            )
        }
    }

    /// Only opens an existing file. Inspecting the queue must never be what
    /// creates it on a machine that has telemetry turned off.
    private static func openStore(home: URL) -> TelemetryStore? {
        let path = home.appendingPathComponent("telemetry.sqlite")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try? TelemetryStore(path: path)
    }
}
