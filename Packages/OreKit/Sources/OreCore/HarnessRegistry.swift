import Foundation
import OreHarness
import OreProtocol

/// The harnesses this build can drive.
///
/// Pluggable on purpose. Subscription auth is the product's biggest external
/// risk — a provider changing its terms could take a harness away overnight —
/// and a registry means that costs one entry rather than the product.
public struct HarnessRegistry: Sendable {
    private let harnesses: [HarnessKind: any AgentHarness]
    /// Experimental harnesses can still be gated by registry policy and expose
    /// reduced capabilities rather than pretending to be at parity.
    public let enabledExperimental: Set<HarnessKind>

    public init(
        harnesses: [any AgentHarness],
        enabledExperimental: Set<HarnessKind> = []
    ) {
        self.harnesses = Dictionary(
            harnesses.map { ($0.kind, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.enabledExperimental = enabledExperimental
    }

    /// Everything shipping today.
    ///
    /// `cursorAllowUnprompted` and `allowAPIKeyFallback` are passed rather than
    /// read from defaults so the core stays free of UI storage; only the app
    /// knows the user answered yes. `allowAPIKeyFallback` reaches the
    /// harnesses' *probes*, which strip provider credentials by default and so
    /// kept telling an API-key user to sign in to a CLI that is already
    /// authenticated; sessions have always taken it from
    /// `SessionConfiguration`.
    public static func standard(
        enabledExperimental: Set<HarnessKind> = [.cursorAgent],
        cursorAllowUnprompted: Bool = false,
        allowAPIKeyFallback: Bool = false
    ) -> HarnessRegistry {
        // Experimental harnesses are always registered so Settings can detect
        // an installed CLI. `harness(for:)` and `available` still honor an
        // explicitly restricted policy supplied by an embedding host.
        let harnesses: [any AgentHarness] = [
            ClaudeCodeHarness(allowAPIKeyFallback: allowAPIKeyFallback),
            CodexHarness(allowAPIKeyFallback: allowAPIKeyFallback),
            CursorAgentHarness(
                allowUnprompted: cursorAllowUnprompted,
                allowAPIKeyFallback: allowAPIKeyFallback
            ),
        ]
        return HarnessRegistry(
            harnesses: harnesses,
            enabledExperimental: enabledExperimental
        )
    }

    public func harness(for kind: HarnessKind) -> (any AgentHarness)? {
        guard !kind.isExperimental || enabledExperimental.contains(kind) else { return nil }
        return harnesses[kind]
    }

    public var available: [any AgentHarness] {
        harnesses.values
            .filter { !$0.kind.isExperimental || enabledExperimental.contains($0.kind) }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    /// Every integration ORE knows about, including one currently disabled by
    /// policy. Decision-support surfaces need to explain that a harness exists
    /// but is unavailable rather than silently omitting it from the fleet.
    public var registered: [any AgentHarness] {
        harnesses.values.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    /// Onboarding doctor: probes every harness at once, since each spawns a
    /// process and doing them in sequence is the difference between a snappy
    /// first run and a visibly slow one.
    public func probeAll() async -> [HarnessProbeResult] {
        await withTaskGroup(of: HarnessProbeResult.self) { group in
            for harness in harnesses.values {
                let isEnabled = !harness.kind.isExperimental
                    || enabledExperimental.contains(harness.kind)
                group.addTask {
                    var result = await harness.probe()
                    result.isEnabled = isEnabled
                    return result
                }
            }
            var results: [HarnessProbeResult] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.kind.rawValue < $1.kind.rawValue }
        }
    }

    /// Catalogs are fetched in parallel because each harness owns a separate
    /// local CLI process. One broken provider must not hide the others.
    public func discoverAllModels() async -> [(HarnessKind, [AgentModel])] {
        await discoverModels(for: Set(available.map(\.kind)))
    }

    /// Only the named harnesses, so launch can skip catalogs it already holds
    /// a fresh copy of — Codex's means starting a whole app-server.
    public func discoverModels(for kinds: Set<HarnessKind>) async -> [(HarnessKind, [AgentModel])] {
        await withTaskGroup(of: (HarnessKind, [AgentModel]).self) { group in
            for harness in available where kinds.contains(harness.kind) {
                group.addTask { (harness.kind, await harness.discoverModels()) }
            }
            var results: [(HarnessKind, [AgentModel])] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0.rawValue < $1.0.rawValue }
        }
    }
}
