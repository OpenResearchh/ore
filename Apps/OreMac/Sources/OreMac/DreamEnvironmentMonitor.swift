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

    init(client: any CoreClient) {
        self.client = client
    }

    func start() {
        guard timer == nil else { return }
        push(isSleepImminent: false)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.push(isSleepImminent: false)
            }
        }
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
                    self?.push(isSleepImminent: false)
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
        releaseAssertion()
    }

    func push(isSleepImminent: Bool) {
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
        Task { await client.send(.updateDreamEnvironment(environment)) }
        refreshAssertion(settings: settings, environment: environment)
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
