import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps this Mac reachable while a phone or iPad is driving it — including
/// clamshell, lid closed, no window visible.
///
/// Idle-sleep assertions are not enough: a MacBook with the lid shut still
/// sleeps unless the system-sleep assertion is held. We take both, and we
/// only do it while a paired client is connected and (by default) the
/// adapter is in.
@MainActor
enum RemoteControlSleep {
    static let requireACKey = "ore.remote.requireACPower"

    private static var assertionIDs: [IOPMAssertionID] = []
    private static var activity: NSObjectProtocol?
    private static var isEnabled = false
    private static var powerSource: CFRunLoopSource?
    private static var wakeObserver: NSObjectProtocol?

    static var isOnACPower: Bool {
        DreamEnvironmentMonitor.isOnACPower()
    }

    /// While remote control is on, hold system-sleep so a closed lid still
    /// answers the LAN. Client count is only for the Settings badge.
    static func update(enabled: Bool) {
        isEnabled = enabled
        if enabled {
            watchPower()
        } else {
            unwatchPower()
        }
        apply()
    }

    /// Plug/unplug must re-evaluate the assertion; start() used to snapshot
    /// AC once and never look again.
    fileprivate static func apply() {
        if isEnabled && allowsAssertion { take() } else { release() }
    }

    private static let powerCallback: IOPowerSourceCallbackType = { _ in
        DispatchQueue.main.async {
            Task { @MainActor in RemoteControlSleep.apply() }
        }
    }

    private static func watchPower() {
        if powerSource == nil,
           let source = IOPSNotificationCreateRunLoopSource(powerCallback, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { RemoteControlSleep.apply() }
            }
        }
    }

    private static func unwatchPower() {
        if let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private static var allowsAssertion: Bool {
        if UserDefaults.standard.object(forKey: requireACKey) as? Bool == false {
            return true
        }
        return isOnACPower
    }

    private static func take() {
        guard assertionIDs.isEmpty else { return }
        let names = [
            kIOPMAssertionTypePreventSystemSleep,
            kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionTypePreventUserIdleDisplaySleep,
        ]
        for name in names {
            var id: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithName(
                name as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "ORE Remote Control" as CFString,
                &id
            )
            if status == kIOReturnSuccess { assertionIDs.append(id) }
        }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [
                .idleSystemSleepDisabled,
                .idleDisplaySleepDisabled,
                .suddenTerminationDisabled,
                .automaticTerminationDisabled,
            ],
            reason: "ORE remote control"
        )
    }

    private static func release() {
        for id in assertionIDs { IOPMAssertionRelease(id) }
        assertionIDs = []
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
