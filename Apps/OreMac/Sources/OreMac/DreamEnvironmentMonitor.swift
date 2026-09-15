import AppKit
import CoreGraphics
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import OreCore
import OreProtocol

/// UserDefaults keys for Dream Mode. Read at push-time, never from a hot
/// SwiftUI body that would re-decode JSON every display cycle.
enum DreamSettingsStore {
    static let enabled = "ore.dreams.enabled"
    static let quietStart = "ore.dreams.quietHours.start"
    static let quietEnd = "ore.dreams.quietHours.end"
    static let idleMinutes = "ore.dreams.idleMinutes"
    static let requireACPower = "ore.dreams.requireACPower"
    static let preventSleep = "ore.dreams.preventSleep"
    static let nightTokenCap = "ore.dreams.nightTokenCap"
    static let headroomFraction = "ore.dreams.headroomFraction"
    static let copySecrets = "ore.dreams.copySecrets"
    static let excludedRepos = "ore.dreams.repos.excluded"

    static func load(defaults: UserDefaults = .standard) -> DreamSettings {
        let harness = HarnessKind(rawValue: defaults.string(forKey: AppModel.DefaultKey.newChatHarness) ?? "")
            ?? .claudeCode
        let model = defaults.string(forKey: AppModel.DefaultKey.newChatModel)
        return DreamSettings(
            enabled: defaults.object(forKey: enabled) as? Bool ?? false,
            quietHoursStartMinutes: defaults.object(forKey: quietStart) as? Int ?? 60,
            quietHoursEndMinutes: defaults.object(forKey: quietEnd) as? Int ?? 7 * 60,
            idleMinutes: defaults.object(forKey: idleMinutes) as? Int ?? 20,
            requireACPower: defaults.object(forKey: requireACPower) as? Bool ?? true,
            preventSleep: defaults.object(forKey: preventSleep) as? Bool ?? false,
            nightTokenCap: defaults.object(forKey: nightTokenCap) as? Int ?? 50_000,
            headroomFraction: defaults.object(forKey: headroomFraction) as? Double ?? 0.25,
            copySecrets: defaults.object(forKey: copySecrets) as? Bool ?? false,
            excludedRepoPaths: defaults.stringArray(forKey: excludedRepos) ?? [],
            defaultHarness: harness,
            defaultModel: model?.isEmpty == true ? nil : model
        )
    }
}

/// The facts `DreamScheduler.step` actually branches on, reduced from a raw
/// snapshot. The snapshot itself changes every tick (`now`, and the seconds
/// since input), so comparing it would never skip anything; these only change
/// when the scheduler could decide something different.
struct DreamEnvironmentChangeKey: Equatable, Sendable {
    var isEnabled: Bool
    var isInQuietHours: Bool
    var isIdle: Bool
    var isOnACPower: Bool
    var thermalPressure: Bool
    var isSleepImminent: Bool
    var canStartRun: Bool

    init(settings: DreamSettings, environment: DreamEnvironmentSnapshot) {
        isEnabled = settings.enabled
        isInQuietHours = DreamPlanner.isInQuietHours(
            environment.now,
            startMinutes: settings.quietHoursStartMinutes,
            endMinutes: settings.quietHoursEndMinutes
        )
        isIdle = DreamPlanner.isIdle(environment: environment, idleMinutes: settings.idleMinutes)
        isOnACPower = environment.isOnACPower
        thermalPressure = environment.thermalPressure
        isSleepImminent = environment.isSleepImminent
        canStartRun = isEnabled && isInQuietHours && isIdle
            && (!settings.requireACPower || isOnACPower)
            && !thermalPressure && !isSleepImminent
    }
}

/// Pushes idle / AC / thermal / will-sleep into the core, and holds an idle-sleep
/// assertion when the user opted in and the Mac is on AC.
@MainActor
final class DreamEnvironmentMonitor {
    private let client: any CoreClient
    private var timer: Timer?
    private var assertionID: IOPMAssertionID = 0
    private var assertionHeld = false
    private var sleepObservers: [NSObjectProtocol] = []
    /// Last known dream-run activity. The 30s timer and sleep observers must
    /// use this rather than defaulting to false, or a manual dream outside
    /// quiet hours drops the keep-awake assertion on the next tick.
    var isDreaming = false
    /// What the scheduler last saw, and when. Every push costs the core a
    /// scheduler step plus inbox maintenance (DB writes), so a tick whose
    /// scheduler-relevant facts are unchanged is skipped.
    private var lastPushedKey: DreamEnvironmentChangeKey?
    private var lastPushedAt = Date.distantPast

    /// A push goes out at least this often even when nothing changed, so the
    /// inbox maintenance riding on it (resurfacing snoozed findings, expiring
    /// stale ones) still happens on a quiet machine.
    nonisolated static let unchangedPushBackstop: TimeInterval = 10 * 60
    nonisolated static let tickInterval: TimeInterval = 30

    var isRunning: Bool { timer != nil }

    init(client: any CoreClient) {
        self.client = client
    }

    /// Idempotent. The owner starts this only while Dream Mode is on and
    /// stops it when it goes off; nothing here needs to run otherwise.
    func start() {
        guard timer == nil else { return }
        push(isSleepImminent: false, force: true)
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.push(isSleepImminent: false)
            }
        }
        // Idle minutes and quiet-hour edges don't need second precision; the
        // slack lets the system batch this wakeup with others.
        timer.tolerance = 10
        // Default mode, not `.common`: nothing here is urgent enough to run in
        // the middle of a scroll, a menu or a window drag. A tick that lands
        // during event tracking just waits for the gesture to end.
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.push(isSleepImminent: true)
                }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.push(isSleepImminent: false, force: true)
                }
            },
        ]
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in sleepObservers { center.removeObserver(observer) }
        sleepObservers = []
        lastPushedKey = nil
        lastPushedAt = .distantPast
        releaseAssertion()
    }

    /// Sends the environment to the core unless nothing the scheduler acts on
    /// has changed since the last push (and the backstop hasn't elapsed).
    /// `force` is for moments that must always reach the core: start, and
    /// sleep/wake transitions.
    func push(isSleepImminent: Bool, force: Bool = false) {
        let settings = DreamSettingsStore.load()
        let environment = DreamEnvironmentSnapshot(
            secondsSinceInput: Self.secondsSinceInput(),
            lastSeenAt: {
                let raw = UserDefaults.standard.double(forKey: AppModel.lastSeenKey)
                return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
            }(),
            now: Date(),
            isOnACPower: Self.isOnACPower(),
            thermalPressure: SystemLoadProbe.shared.isUnderPressure,
            isSleepImminent: isSleepImminent
        )
        let key = DreamEnvironmentChangeKey(settings: settings, environment: environment)
        if Self.shouldPush(
            key: key,
            lastKey: lastPushedKey,
            lastPushedAt: lastPushedAt,
            now: environment.now,
            force: force,
            isDreaming: isDreaming
        ) {
            lastPushedKey = key
            lastPushedAt = environment.now
            Task { await client.send(.updateDreamEnvironment(environment)) }
        }
        refreshAssertion(settings: settings, environment: environment)
    }

    nonisolated static func shouldPush(
        key: DreamEnvironmentChangeKey,
        lastKey: DreamEnvironmentChangeKey?,
        lastPushedAt: Date,
        now: Date,
        force: Bool,
        isDreaming: Bool = false
    ) -> Bool {
        if force || key != lastKey { return true }
        // The scheduler advances one phase per push: entering quiet hours
        // can move armed -> watching without starting a run. Keep its normal
        // cadence while eligible so watching -> dreaming is not postponed
        // until the ten-minute backstop. An active run or an ineligible Mac
        // can still skip unchanged snapshots.
        if key.canStartRun, !isDreaming { return true }
        return now.timeIntervalSince(lastPushedAt) >= unchangedPushBackstop
    }

    /// Re-evaluate the sleep assertion from the stored dreaming flag without
    /// pushing a new environment snapshot.
    func refreshAssertion() {
        let settings = DreamSettingsStore.load()
        let environment = DreamEnvironmentSnapshot(
            secondsSinceInput: Self.secondsSinceInput(),
            now: Date(),
            isOnACPower: Self.isOnACPower(),
            thermalPressure: SystemLoadProbe.shared.isUnderPressure
        )
        refreshAssertion(settings: settings, environment: environment)
    }

    private func refreshAssertion(settings: DreamSettings, environment: DreamEnvironmentSnapshot) {
        let hold = DreamScheduler.shouldHoldSleepAssertion(
            settings: settings,
            environment: environment,
            isDreaming: isDreaming
        )
        if hold { takeAssertion() } else { releaseAssertion() }
    }

    var currentSleepStatus: DreamSleepStatus {
        let settings = DreamSettingsStore.load()
        let environment = DreamEnvironmentSnapshot(
            secondsSinceInput: Self.secondsSinceInput(),
            now: Date(),
            isOnACPower: Self.isOnACPower(),
            thermalPressure: SystemLoadProbe.shared.isUnderPressure
        )
        return DreamScheduler.sleepStatus(
            settings: settings,
            environment: environment,
            isDreaming: isDreaming
        )
    }

    private func takeAssertion() {
        guard !assertionHeld else { return }
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "ORE Dream Mode" as CFString,
            &id
        )
        if status == kIOReturnSuccess {
            assertionID = id
            assertionHeld = true
        }
    }

    private func releaseAssertion() {
        guard assertionHeld else { return }
        IOPMAssertionRelease(assertionID)
        assertionHeld = false
        assertionID = 0
    }

    static func secondsSinceInput() -> TimeInterval {
        let anyEvent = CGEventType(rawValue: UInt32.max) ?? .mouseMoved
        return CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyEvent
        )
    }

    static func isOnACPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              !list.isEmpty
        else {
            // Desktops and VMs often have no sources listed. Treat as AC so
            // dreaming is not silently disabled on a studio Mac.
            return true
        }
        for source in list {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }
            if let state = info[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSACPowerValue
            }
        }
        return true
    }
}
