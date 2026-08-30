import Foundation

/// A cheap answer to "is this Mac already working hard?", used to decide
/// whether the neural narration voice is worth its cores right now.
///
/// Two signals, both nearly free: the thermal state (macOS's own judgment of
/// sustained load) and the CPU busy fraction from `host_statistics` tick
/// deltas, sampled at most every few seconds. No timers — callers ask at the
/// moment they're about to spend, which for narration is once per utterance.
@MainActor
final class SystemLoadProbe {
    static let shared = SystemLoadProbe()

    /// Above this busy fraction the machine is saturated enough that adding
    /// a 100M-parameter TTS pass would make everything else — including the
    /// agents the user is actually waiting on — visibly slower.
    private let busyThreshold: Double

    private var lastTicks: (busy: Double, total: Double)?
    private var cachedFraction = 0.0
    private var sampledAt: ContinuousClock.Instant?
    private static let sampleInterval: Duration = .seconds(4)

    init(busyThreshold: Double = 0.8) {
        self.busyThreshold = busyThreshold
        // Prime the tick baseline so the first real reading has a delta to
        // measure instead of reporting since-boot averages.
        _ = cpuBusyFraction()
    }

    /// Whether heavy work should defer. Thermal pressure wins outright — the
    /// OS is already throttling — and a saturated CPU counts even when cool.
    var isUnderPressure: Bool {
        if ProcessInfo.processInfo.thermalState.rawValue
            >= ProcessInfo.ThermalState.serious.rawValue {
            return true
        }
        return cpuBusyFraction() > busyThreshold
    }

    /// Busy fraction across all cores since the previous sample, cached for a
    /// few seconds so back-to-back utterances don't re-read host statistics.
    func cpuBusyFraction() -> Double {
        if let sampledAt, sampledAt.duration(to: .now) < Self.sampleInterval {
            return cachedFraction
        }
        sampledAt = .now
        guard let ticks = Self.readTicks() else { return cachedFraction }
        defer { lastTicks = ticks }
        guard let last = lastTicks else { return cachedFraction }
        let total = ticks.total - last.total
        guard total > 0 else { return cachedFraction }
        cachedFraction = max(0, min(1, (ticks.busy - last.busy) / total))
        return cachedFraction
    }

    private static func readTicks() -> (busy: Double, total: Double)? {
        var size = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride
                / MemoryLayout<integer_t>.stride
        )
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = Double(info.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3)
        let busy = user + system + nice
        return (busy: busy, total: busy + idle)
    }
}
