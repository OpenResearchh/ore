import Foundation
import OreProtocol

/// When the Assistant's own agent is dead in the water, pick another harness.
///
/// Project tabs stay put: a rate-limited Claude on kailash is that project's
/// conversation. The Assistant is the product's voice, so a dry provider must
/// not mute it while another signed-in CLI can still answer.
public enum AssistantFailoverPolicy {
    /// Late events from the abandoned session arrive for a beat after the
    /// switch. Treating them as the *new* harness failing would bounce
    /// Claude → Codex → Cursor in one turn.
    public static let cooldown = Duration.milliseconds(1_500)

    public enum Reason: Equatable, Sendable {
        case rateLimited
        case providerFailed
    }

    public static func reason(for event: AgentEvent) -> Reason? {
        switch event {
        case .rateLimit(let report) where report.status == .exhausted:
            return .rateLimited
        case .sessionError(let error):
            switch error.kind {
            case .rateLimited:
                return .rateLimited
            case .notInstalled, .notAuthenticated, .protocolMismatch,
                 .processFailed, .transport:
                return .providerFailed
            case .unknown:
                return ProviderErrorCopy.looksLikeRateLimit(error.message)
                    ? .rateLimited : nil
            }
        case .turnCompleted(let result) where result.outcome == .failed:
            let message = [result.errorMessage, result.summary]
                .compactMap { $0 }
                .joined(separator: " ")
            if ProviderErrorCopy.looksLikeRateLimit(message) { return .rateLimited }
            return .providerFailed
        default:
            return nil
        }
    }

    public static func spokenHandoff(_ reason: Reason) -> String {
        switch reason {
        case .rateLimited:
            "I've hit my provider's rate limit — switching to another agent to keep answering."
        case .providerFailed:
            "That agent failed — switching to another one to keep answering."
        }
    }

    /// First ready harness that still has the Assistant's lean profile, skipping
    /// the one that just failed. Experimental CLIs (Cursor) are last so a
    /// quota on Claude does not jump straight to the least-proven option.
    static func nextHarness(
        current: HarnessKind?,
        excluding: Set<HarnessKind>,
        probes: [HarnessProbeResult],
        profile: (HarnessKind) -> AssistantManager.ModelProfile?
    ) -> (harness: HarnessKind, profile: AssistantManager.ModelProfile)? {
        let ready = probes.filter { probe in
            probe.isReady
                && probe.kind != current
                && !excluding.contains(probe.kind)
        }
        let ordered = ready.filter { !$0.kind.isExperimental }
            + ready.filter(\.kind.isExperimental)
        for probe in ordered {
            if let profile = profile(probe.kind) {
                return (probe.kind, profile)
            }
        }
        return nil
    }
}
