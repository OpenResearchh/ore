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

    static var isOnACPower: Bool {
        DreamEnvironmentMonitor.isOnACPower()
    }

    /// While remote control is on, hold system-sleep so a closed lid still
    /// answers the LAN. Client count is only for the Settings badge.
    static func update(enabled: Bool) {
        if enabled && allowsAssertion { take() } else { release() }
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
