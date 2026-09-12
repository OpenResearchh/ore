import Foundation
import Testing

@testable import OreTelemetry

/// The privacy promise, as tests rather than as a paragraph in a README.
///
/// PRIVACY.md claims ORE never reports prompt text, agent output, diffs, file
/// paths, repository names, branch names or commit messages. These tests are
/// what make that claim true after the person who wrote it has moved on: they
/// take every event ORE can emit, build it from values chosen to be as
/// hostile as the type system permits, and assert nothing sensitive survives
/// into a payload.
@Suite("Telemetry payloads carry nothing sensitive")
struct TelemetryPayloadTests {
    /// Substrings that must never appear in a serialized batch. Each is
    /// planted somewhere in `auditCatalogue`'s inputs.
    static let forbidden = [
        "/Users/", "secret-startup", "feature/fix", "fix-the-thing",
        ".swift", "git@", "https://github.com/",
    ]

    private func context() -> TelemetryContext {
        TelemetryContext(
            installID: "install-uuid",
            appVersion: "0.7.2",
            build: "1",
            osVersion: "26.0",
            arch: "arm64",
            installChannel: .installScript,
            sessionID: "session-uuid"
        )
    }

    private func payload(_ event: TelemetryEvent) -> [String: JSONLeaf] {
        TelemetryPayload.properties(
            for: event,
            context: context(),
            distinctID: "install-uuid"
        )
    }

    private func serialize(_ event: TelemetryEvent) throws -> String {
        String(decoding: try JSONEncoder.telemetry.encode(payload(event)), as: UTF8.self)
    }

    /// Decoded back out of the encoded bytes rather than read off the
    /// dictionary, so this sees exactly what the server would.
    private func serializedKeys(_ event: TelemetryEvent) throws -> Set<String> {
        let data = try JSONEncoder.telemetry.encode(payload(event))
        let decoded = try JSONDecoder().decode([String: JSONLeaf].self, from: data)
        return Set(decoded.keys)
    }

    @Test("No hostile input survives into any payload")
    func noSensitiveSubstrings() throws {
        for event in TelemetryEvent.auditCatalogue {
            let json = try serialize(event)
            for needle in Self.forbidden {
                #expect(
                    !json.contains(needle),
                    "event \(event.name) leaked \(needle) — payload was \(json)"
                )
            }
        }
    }

    /// Asserted against the encoded bytes, not `event.properties`, because
    /// the client attaches context and PostHog directives afterwards — a leak
    /// added there would never show up in the per-event dictionary.
    @Test("Every key in a serialized payload is on the allowlist")
    func onlyAllowlistedKeys() throws {
        for event in TelemetryEvent.auditCatalogue {
            for key in try serializedKeys(event) {
                #expect(
                    TelemetryEvent.allowedPayloadKeys.contains(key),
                    "event \(event.name) emitted un-allowlisted key \(key)"
                )
            }
        }
    }

    /// PRIVACY.md says "your IP address is not retained". That is only true
    /// if these two directives reach PostHog, so every payload carries them.
    @Test("Every payload tells the server not to keep the IP or derive a location")
    func ipIsSuppressedOnEveryEvent() throws {
        for event in TelemetryEvent.auditCatalogue {
            let properties = payload(event)
            #expect(properties["$ip"] == .null, "event \(event.name) did not suppress the IP")
            #expect(properties["$geoip_disable"] == .bool(true))
            // `.null` has to survive encoding as a JSON null; an omitted key
            // means PostHog falls back to recording the address.
            #expect(try serialize(event).contains("\"$ip\":null"))
        }
    }

    /// The compiler is the enforcement mechanism here. Adding a case to
    /// `TelemetryEvent` makes this switch non-exhaustive, so the build breaks
    /// until someone adds the new event to `auditCatalogue` and thereby runs
    /// it through every assertion above.
    @Test("The audit catalogue covers every event case")
    func catalogueIsExhaustive() {
        let names = Set(TelemetryEvent.auditCatalogue.map(\.name))
        for event in TelemetryEvent.auditCatalogue {
            switch event {
            case .appInstalled, .appLaunched, .workspaceCreated, .turnCompleted,
                .pullRequestCreated, .telemetryOptOut:
                continue
            }
        }
        #expect(names.count == 6, "a new event case needs adding to auditCatalogue")
    }

    /// PRIVACY.md enumerates the events by name. Someone adding a case will
    /// see this fail and know the document is now wrong.
    @Test("The documented event list is the event list")
    func documentedEventsMatchTheCode() {
        #expect(
            Set(TelemetryEvent.auditCatalogue.map(\.name)) == [
                "app_installed", "app_launched", "workspace_created",
                "turn_completed", "pull_request_created", "telemetry_opt_out",
            ],
            "PRIVACY.md, README.md and the website list these by name — update them too"
        )
    }

    /// The one door an unbounded external string can walk through. Model
    /// identifiers come from the harness CLIs, so their content is not ours
    /// to control; they must always collapse to a known token.
    @Test("Model identifiers collapse to a closed vocabulary")
    func modelTagsAreClosed() {
        #expect(ModelTag(rawModel: "claude-sonnet-4-5-20250929") == .sonnet)
        #expect(ModelTag(rawModel: "gpt-5-codex") == .gpt)
        #expect(ModelTag(rawModel: nil) == .other)

        let hostile = "/Users/tushar/code/secret-startup"
        let tag = ModelTag(rawModel: hostile)
        #expect(tag == .other)
        #expect(!tag.telemetryToken.contains("secret"))
        #expect(!tag.telemetryToken.contains("/"))
    }

    /// ORE has no account system, and the install UUID is the whole identity.
    /// The payload used to carry a GitHub login and user ID for a Settings →
    /// Account feature that was never built; this is what keeps it gone.
    @Test("Nothing in a payload identifies a person")
    func thereIsNoIdentityField() throws {
        for event in TelemetryEvent.auditCatalogue {
            let properties = payload(event)
            #expect(properties["github_login"] == nil)
            #expect(properties["$user_id"] == nil)
            #expect(properties["distinct_id"] == .string("install-uuid"))
        }
    }

    @Test("Duration and day buckets are coarse enough to not fingerprint")
    func bucketBoundaries() {
        #expect(DurationBucket(seconds: 0) == .under5s)
        #expect(DurationBucket(seconds: 4.9) == .under5s)
        #expect(DurationBucket(seconds: 5) == .to15s)
        #expect(DurationBucket(seconds: 3_600) == .over15m)

        #expect(DayBucket(days: 0) == .sameDay)
        #expect(DayBucket(days: 1) == .nextDay)
        #expect(DayBucket(days: 6) == .firstWeek)
        #expect(DayBucket(days: 7) == .firstMonth)
        #expect(DayBucket(days: 400) == .beyond)
    }
}
