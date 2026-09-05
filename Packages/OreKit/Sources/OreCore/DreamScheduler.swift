import Foundation
import OreProtocol

/// Pure Sandman state machine. The client applies the actions; tests drive it
/// with synthetic `DreamEnvironmentSnapshot`s and never touch a harness.
public enum DreamScheduler {
    public enum Phase: String, Sendable, Equatable {
        case disabled
        case armed
        case watching
        case planning
        case dreaming
        case pausing
        case windingDown
    }

    public struct State: Sendable, Equatable {
        public var phase: Phase
        public var runID: DreamRunID?

        public init(phase: Phase = .disabled, runID: DreamRunID? = nil) {
            self.phase = phase
            self.runID = runID
        }
    }

    public enum Action: Sendable, Equatable {
        case startRun(manual: Bool)
        case pause
        case resume
        case windDown(reason: String)
        case abort(reason: String)
        case disable
        case arm
    }

    /// One evaluation of the environment against settings and the current
    /// phase. Manual starts never go through this — they call `startRun`
    /// directly.
    public static func step(
        state: State,
        settings: DreamSettings,
        environment: DreamEnvironmentSnapshot
    ) -> (State, [Action]) {
        if !settings.enabled {
            if state.phase == .disabled { return (state, []) }
            if state.phase == .dreaming || state.phase == .pausing || state.phase == .windingDown {
                return (State(phase: .windingDown, runID: state.runID), [.windDown(reason: "Dream Mode turned off")])
            }
            return (State(phase: .disabled), [.disable])
        }

        if environment.isSleepImminent {
            if state.phase == .dreaming || state.phase == .pausing {
                return (
                    State(phase: .windingDown, runID: state.runID),
                    [.windDown(reason: "Mac is going to sleep")]
                )
            }
            if state.phase == .watching || state.phase == .planning {
                return (State(phase: .armed), [])
            }
            return (state, [])
        }

        let inWindow = DreamPlanner.isInQuietHours(
            environment.now,
            startMinutes: settings.quietHoursStartMinutes,
            endMinutes: settings.quietHoursEndMinutes
        )
        let idle = DreamPlanner.isIdle(environment: environment, idleMinutes: settings.idleMinutes)
        let powerOK = !settings.requireACPower || environment.isOnACPower
        let thermalOK = !environment.thermalPressure

        switch state.phase {
        case .disabled:
            return (State(phase: .armed), [.arm])

        case .armed:
            guard inWindow else { return (state, []) }
            return (State(phase: .watching), [])

        case .watching:
            if !inWindow { return (State(phase: .armed), []) }
            guard idle, powerOK, thermalOK else { return (state, []) }
            return (State(phase: .dreaming, runID: state.runID), [.startRun(manual: false)])

        case .planning:
            return (State(phase: .dreaming, runID: state.runID), [.startRun(manual: false)])

        case .dreaming:
            if !idle {
                return (State(phase: .pausing, runID: state.runID), [.pause])
            }
            if !inWindow {
                return (State(phase: .windingDown, runID: state.runID), [.windDown(reason: "Quiet hours ended")])
            }
            if !powerOK {
                return (State(phase: .pausing, runID: state.runID), [.pause])
            }
            if !thermalOK {
                return (State(phase: .pausing, runID: state.runID), [.pause])
            }
            return (state, [])

        case .pausing:
            if idle, inWindow, powerOK, thermalOK {
                return (State(phase: .dreaming, runID: state.runID), [.resume])
            }
            if !inWindow {
                return (State(phase: .windingDown, runID: state.runID), [.windDown(reason: "Quiet hours ended")])
            }
            return (state, [])

        case .windingDown:
            return (State(phase: .armed), [.arm])
        }
    }

    public static func shouldHoldSleepAssertion(
        settings: DreamSettings,
        environment: DreamEnvironmentSnapshot,
        isDreaming: Bool
    ) -> Bool {
        guard settings.enabled, settings.preventSleep, environment.isOnACPower else {
            return false
        }
        if isDreaming { return true }
        return DreamPlanner.isInQuietHours(
            environment.now,
            startMinutes: settings.quietHoursStartMinutes,
            endMinutes: settings.quietHoursEndMinutes
        )
    }

    public static func sleepStatus(
        settings: DreamSettings,
        environment: DreamEnvironmentSnapshot,
        isDreaming: Bool
    ) -> DreamSleepStatus {
        guard settings.enabled else { return .disabled }
        if settings.preventSleep {
            if !environment.isOnACPower { return .keepAwakePausedOnBattery }
            if shouldHoldSleepAssertion(
                settings: settings, environment: environment, isDreaming: isDreaming
            ) {
                return .keepAwakeActive
            }
            return .opportunistic
        }
        return .macMaySleep
    }
}
