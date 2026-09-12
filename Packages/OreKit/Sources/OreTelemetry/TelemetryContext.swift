import Foundation

/// The properties attached to every event, assembled once at launch.
///
/// Call sites never supply these. That is deliberate: it means the per-event
/// property lists in `TelemetryEvent` stay short enough to audit at a glance,
/// and it makes it impossible to forget one.
public struct TelemetryContext: Sendable {
    /// A random UUID, minted once and kept in `~/ore/`.
    ///
    /// Not in UserDefaults and not in the app bundle: `~/ore` is the app's own
    /// state directory, so the ID survives deleting and reinstalling the app.
    /// Without that, every reinstall would look like a brand-new user, which
    /// inflates install counts and quietly destroys retention numbers.
    ///
    /// This is the entire identity system. There is no login, no email and no
    /// device fingerprint behind it.
    public let installID: String
    public let appVersion: String
    public let build: String
    public let osVersion: String
    public let arch: String
    public let installChannel: InstallChannel
    public let sessionID: String

    public init(
        installID: String,
        appVersion: String,
        build: String,
        osVersion: String,
        arch: String,
        installChannel: InstallChannel,
        sessionID: String = UUID().uuidString
    ) {
        self.installID = installID
        self.appVersion = appVersion
        self.build = build
        self.osVersion = osVersion
        self.arch = arch
        self.installChannel = installChannel
        self.sessionID = sessionID
    }

    /// Reads (or mints) the install ID and reads the channel marker written by
    /// install.sh or the Homebrew cask.
    public static func resolve(
        bundle: Bundle = .main,
        home: URL,
        store: TelemetryStore
    ) -> (context: TelemetryContext, isNewInstall: Bool) {
        var isNew = false
        let existing = try? store.metadata(Keys.installID)
        let installID: String
        if let existing, !existing.isEmpty {
            installID = existing
        } else {
            installID = UUID().uuidString
            try? store.setMetadata(Keys.installID, installID)
            isNew = true
        }

        let marker = try? String(
            contentsOf: home.appendingPathComponent("install-channel"),
            encoding: .utf8
        )

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let context = TelemetryContext(
            installID: installID,
            appVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
            build: bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0",
            osVersion: "\(os.majorVersion).\(os.minorVersion)",
            arch: machineArchitecture(),
            installChannel: InstallChannel(marker: marker)
        )
        return (context, isNew)
    }

    /// Reported so we can see, from real data rather than a guess, whether
    /// shipping a universal binary for Intel is worth doing. The app is
    /// arm64-only today and install.sh refuses to install it on x86_64.
    private static func machineArchitecture() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return machine.isEmpty ? "unknown" : machine
    }

    enum Keys {
        static let installID = "installID"
        static let lastLaunch = "lastLaunchAt"
        static let firstLaunch = "firstLaunchAt"
    }
}

// MARK: - Payload

/// Turns an event plus context into the flat property bag PostHog ingests.
enum TelemetryPayload {
    /// Keys PostHog reads as instructions rather than as data.
    ///
    /// `$ip: null` is what stops the server storing the address the batch
    /// arrived from, and `$geoip_disable` stops it deriving a location from
    /// it. PRIVACY.md promises the IP is not retained, and until these were
    /// here nothing in the payload made that true — the default is to keep it.
    static let ipSuppression: [String: JSONLeaf] = [
        "$ip": .null,
        "$geoip_disable": .bool(true),
    ]

    static func properties(
        for event: TelemetryEvent,
        context: TelemetryContext,
        distinctID: String
    ) -> [String: JSONLeaf] {
        var properties: [String: JSONLeaf] = [
            "distinct_id": .string(distinctID),
            "app_version": .string(context.appVersion),
            "build": .string(context.build),
            "os_version": .string(context.osVersion),
            "arch": .string(context.arch),
            "install_channel": .string(context.installChannel.telemetryToken),
            "session_id": .string(context.sessionID),
        ]
        properties.merge(ipSuppression) { current, _ in current }

        for (key, value) in event.properties {
            switch value {
            case .flag(let flag): properties[key] = .bool(flag)
            case .count(let count): properties[key] = .int(count)
            case .tag(let tag): properties[key] = .string(tag.rawValue)
            }
        }

        return properties
    }
}

/// The only shapes a property can take on the wire.
enum JSONLeaf: Codable, Sendable, Hashable {
    case string(String)
    case int(Int)
    case bool(Bool)
    /// Only ever `$ip`, which PostHog reads as "do not record the address".
    case null

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else { self = .string(try container.decode(String.self)) }
    }
}
