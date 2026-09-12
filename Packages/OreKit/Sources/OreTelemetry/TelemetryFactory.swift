import Foundation

/// Where the user's answer to "share anonymous usage data" lives.
///
/// In `UserDefaults` because that is what the Settings toggle binds to, and
/// mirrored into the telemetry store so the opt-out survives someone deleting
/// preferences. `TelemetryClient.make` reads it before it will hand back a
/// recording client, so consent is settled before the first launch event is
/// enqueued rather than by a task racing it.
public enum TelemetryConsent {
    public static let analyticsKey = "ore.privacy.analytics"

    /// Registered default. Opt-out rather than opt-in for anonymous,
    /// bucketed, code-free usage counts, disclosed in PRIVACY.md and
    /// switchable in Settings → Privacy.
    public static let analyticsDefault = true

    public static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [analyticsKey: analyticsDefault])
    }

    public static func isAllowed(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: analyticsKey) as? Bool ?? analyticsDefault
    }
}

extension TelemetryClient {
    /// The only way the app builds a recorder.
    ///
    /// Four independent kill switches, any one of which yields
    /// `NoopTelemetry`:
    ///
    ///   - `#if DEBUG` — a developer running from Xcode never reports.
    ///   - no API key in Info.plist — `bundle.sh` only stamps it for release
    ///     builds from the release machine, so a contributor building from a
    ///     clean clone, and any fork, emit nothing into our project.
    ///   - `ORE_TELEMETRY=0` — an explicit escape hatch for anyone who wants
    ///     one without digging through Settings.
    ///   - the user's opt-out, read from the store.
    ///
    /// That matters much more now the repository is public: the default for a
    /// stranger who clones and builds ORE must be silence, without them
    /// having to know telemetry exists at all.
    public static func make(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL,
        isAllowed: Bool = TelemetryConsent.isAllowed()
    ) -> (recorder: any TelemetryRecorder, launch: LaunchFacts?) {
        // First, and synchronously. The caller records `app_installed` and
        // `app_launched` the moment this returns, so consent cannot be an
        // unordered task racing those calls — which is how a user who had
        // opted out, then deleted `~/ore`, got a fresh install ID, two queued
        // launch events, and an `optOut()` that uploaded them.
        guard isAllowed else {
            purgeQueue(home: home)
            return (NoopTelemetry(), nil)
        }

        #if DEBUG
        // Debug builds are silent unless a local endpoint is explicitly set,
        // which is how the delivery path gets exercised end to end offline
        // (point it at `nc -l 8088` and read the real payloads).
        guard environment["ORE_TELEMETRY_ENDPOINT"] != nil else { return (NoopTelemetry(), nil) }
        #endif

        guard environment["ORE_TELEMETRY"] != "0" else { return (NoopTelemetry(), nil) }

        let key = (bundle.object(forInfoDictionaryKey: "OREPostHogKey") as? String) ?? ""
        let overrideEndpoint = environment["ORE_TELEMETRY_ENDPOINT"]
        guard !key.isEmpty || overrideEndpoint != nil else { return (NoopTelemetry(), nil) }

        let endpointString = overrideEndpoint
            ?? (bundle.object(forInfoDictionaryKey: "OREPostHogEndpoint") as? String)
            ?? "https://us.i.posthog.com/batch/"
        guard let endpoint = URL(string: endpointString) else { return (NoopTelemetry(), nil) }

        guard let store = try? TelemetryStore(path: home.appendingPathComponent("telemetry.sqlite"))
        else { return (NoopTelemetry(), nil) }

        let resolved = TelemetryContext.resolve(bundle: bundle, home: home, store: store)
        let facts = launchFacts(
            store: store,
            isNewInstall: resolved.isNewInstall,
            channel: resolved.context.installChannel
        )

        let client = TelemetryClient(
            configuration: Configuration(apiKey: key, endpoint: endpoint),
            store: store,
            context: resolved.context
        )
        return (client, facts)
    }

    /// Nothing may sit queued while the user has telemetry off — including a
    /// backlog from before they turned it off, and including relaunches after
    /// the `optOut()` that purged it never ran (preferences restored from a
    /// backup, say). Cheap: one file check and one delete.
    private static func purgeQueue(home: URL) {
        let path = home.appendingPathComponent("telemetry.sqlite")
        guard FileManager.default.fileExists(atPath: path.path),
              let store = try? TelemetryStore(path: path)
        else { return }
        try? store.setMetadata(Keys.optedOut, "1")
        try? store.deleteAll()
    }

    /// What the app needs in order to emit `app_installed` / `app_launched`
    /// without reaching into the store itself.
    public struct LaunchFacts: Sendable {
        public let isNewInstall: Bool
        public let channel: InstallChannel
        public let daysSinceInstall: DayBucket
    }

    private static func launchFacts(
        store: TelemetryStore,
        isNewInstall: Bool,
        channel: InstallChannel
    ) -> LaunchFacts {
        let now = Date()
        let stored = (try? store.metadata(TelemetryContext.Keys.firstLaunch)) ?? nil
        let firstLaunch: Date
        if let stored, let seconds = TimeInterval(stored) {
            firstLaunch = Date(timeIntervalSince1970: seconds)
        } else {
            firstLaunch = now
            try? store.setMetadata(
                TelemetryContext.Keys.firstLaunch, String(now.timeIntervalSince1970)
            )
        }
        try? store.setMetadata(TelemetryContext.Keys.lastLaunch, String(now.timeIntervalSince1970))

        let days = Int(now.timeIntervalSince(firstLaunch) / 86_400)
        return LaunchFacts(
            isNewInstall: isNewInstall,
            channel: channel,
            daysSinceInstall: DayBucket(days: max(0, days))
        )
    }
}
