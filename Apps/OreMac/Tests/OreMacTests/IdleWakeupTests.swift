import AppKit
import Foundation
import OreCore
import OreProtocol
import Testing

@testable import OreMac

/// A quiet ORE should be asleep: no once-a-second timers, no environment
/// pushes that change nothing, no key monitors between gestures. These pin the
/// decisions that keep it that way.
struct NarrationTickerTests {
    @Test func tickerStopsWhenThereIsNothingToDo() {
        #expect(!NarrationEngine.tickerIsNeeded(
            hasQueuedSpeech: false,
            isMidUtterance: false,
            isAudible: false,
            hasQuietWaiters: false,
            hasPendingToolBatch: false
        ))
    }

    @Test func anyOutstandingWorkKeepsTheTickerRunning() {
        let cases: [(Bool, Bool, Bool, Bool, Bool)] = [
            (true, false, false, false, false),
            (false, true, false, false, false),
            (false, false, true, false, false),
            (false, false, false, true, false),
            (false, false, false, false, true),
        ]
        for (queued, mid, audible, waiters, batch) in cases {
            #expect(NarrationEngine.tickerIsNeeded(
                hasQueuedSpeech: queued,
                isMidUtterance: mid,
                isAudible: audible,
                hasQuietWaiters: waiters,
                hasPendingToolBatch: batch
            ))
        }
    }
}

struct ReviewRefreshPolicyTests {
    @Test func noPollingWhileTheWindowIsNotKey() {
        #expect(ReviewRefreshPolicy.commentPollInterval(isWindowKey: false, isAgentBusy: true) == nil)
        #expect(ReviewRefreshPolicy.commentPollInterval(isWindowKey: false, isAgentBusy: false) == nil)
    }

    @Test func pollsQuicklyOnlyWhileAnAgentIsMidTurn() {
        #expect(ReviewRefreshPolicy.commentPollInterval(isWindowKey: true, isAgentBusy: true) == .seconds(1))
        #expect(ReviewRefreshPolicy.commentPollInterval(isWindowKey: true, isAgentBusy: false) == .seconds(5))
    }

    @Test func onlyAnOpenTurnCountsAsBusy() {
        #expect(ReviewRefreshPolicy.isAgentBusy(.thinking))
        #expect(ReviewRefreshPolicy.isAgentBusy(.requesting))
        #expect(ReviewRefreshPolicy.isAgentBusy(.runningTool))
        #expect(!ReviewRefreshPolicy.isAgentBusy(.idle))
        #expect(!ReviewRefreshPolicy.isAgentBusy(.awaitingInput))
        #expect(!ReviewRefreshPolicy.isAgentBusy(.interrupted))
        #expect(!ReviewRefreshPolicy.isAgentBusy(.failed))
    }
}

struct DreamEnvironmentChangeTests {
    private let base = Date(timeIntervalSince1970: 2_000_000_000)

    /// Defaults from an empty suite, so the test doesn't read the developer's
    /// real Dream Mode settings.
    private func settings(enabled: Bool = true) -> DreamSettings {
        let suite = "ore.tests.idleWakeup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = DreamSettingsStore.load(defaults: defaults)
        settings.enabled = enabled
        // Always inside quiet hours, independent of the machine's time zone.
        settings.quietHoursStartMinutes = 0
        settings.quietHoursEndMinutes = 0
        return settings
    }

    @Test func tickingClockAloneIsNotAChange() {
        let settings = settings()
        let first = DreamEnvironmentChangeKey(
            settings: settings,
            environment: DreamEnvironmentSnapshot(secondsSinceInput: 5, now: base)
        )
        let later = DreamEnvironmentChangeKey(
            settings: settings,
            environment: DreamEnvironmentSnapshot(secondsSinceInput: 35, now: base.addingTimeInterval(30))
        )
        #expect(first == later)
    }

    @Test func crossingTheIdleThresholdIsAChange() {
        let settings = settings()
        let threshold = TimeInterval(settings.idleMinutes * 60)
        let active = DreamEnvironmentChangeKey(
            settings: settings,
            environment: DreamEnvironmentSnapshot(secondsSinceInput: threshold - 1, now: base)
        )
        let idle = DreamEnvironmentChangeKey(
            settings: settings,
            environment: DreamEnvironmentSnapshot(secondsSinceInput: threshold + 1, now: base)
        )
        #expect(active != idle)
    }

    @Test func powerThermalSleepAndEnablementAreChanges() {
        let settings = settings()
        let environment = DreamEnvironmentSnapshot(secondsSinceInput: 5, now: base)
        let key = DreamEnvironmentChangeKey(settings: settings, environment: environment)

        var unplugged = environment
        unplugged.isOnACPower = false
        var warm = environment
        warm.thermalPressure = true
        var sleeping = environment
        sleeping.isSleepImminent = true

        #expect(key != DreamEnvironmentChangeKey(settings: settings, environment: unplugged))
        #expect(key != DreamEnvironmentChangeKey(settings: settings, environment: warm))
        #expect(key != DreamEnvironmentChangeKey(settings: settings, environment: sleeping))
        #expect(key != DreamEnvironmentChangeKey(
            settings: self.settings(enabled: false), environment: environment
        ))
    }

    @Test func unchangedPushesWaitForTheBackstop() {
        let key = DreamEnvironmentChangeKey(
            settings: settings(),
            environment: DreamEnvironmentSnapshot(secondsSinceInput: 5, now: base)
        )
        let backstop = DreamEnvironmentMonitor.unchangedPushBackstop

        #expect(!DreamEnvironmentMonitor.shouldPush(
            key: key, lastKey: key, lastPushedAt: base, now: base.addingTimeInterval(30), force: false
        ))
        #expect(DreamEnvironmentMonitor.shouldPush(
            key: key, lastKey: key, lastPushedAt: base, now: base.addingTimeInterval(backstop), force: false
        ))
        #expect(DreamEnvironmentMonitor.shouldPush(
            key: key, lastKey: key, lastPushedAt: base, now: base, force: true
        ))
        #expect(DreamEnvironmentMonitor.shouldPush(
            key: key, lastKey: nil, lastPushedAt: .distantPast, now: base, force: false
        ))
    }

    @Test func eligibleEnvironmentKeepsAdvancingTheSchedulerUntilARunStarts() {
        let settings = settings()
        let environment = DreamEnvironmentSnapshot(
            secondsSinceInput: TimeInterval(settings.idleMinutes * 60 + 60), now: base
        )
        let key = DreamEnvironmentChangeKey(settings: settings, environment: environment)
        let (watching, initialActions) = DreamScheduler.step(
            state: .init(phase: .armed), settings: settings, environment: environment
        )
        #expect(watching.phase == .watching)
        #expect(initialActions.isEmpty)

        var nextEnvironment = environment
        nextEnvironment.now = base.addingTimeInterval(DreamEnvironmentMonitor.tickInterval)
        let nextKey = DreamEnvironmentChangeKey(settings: settings, environment: nextEnvironment)
        #expect(nextKey == key)
        let shouldAdvance = DreamEnvironmentMonitor.shouldPush(
            key: nextKey, lastKey: key, lastPushedAt: base,
            now: nextEnvironment.now, force: false, isDreaming: false
        )
        #expect(shouldAdvance)
        if shouldAdvance {
            let (dreaming, actions) = DreamScheduler.step(
                state: watching, settings: settings, environment: nextEnvironment
            )
            #expect(dreaming.phase == .dreaming)
            #expect(actions == [.startRun(manual: false)])
        }
        #expect(!DreamEnvironmentMonitor.shouldPush(
            key: nextKey, lastKey: key, lastPushedAt: base,
            now: nextEnvironment.now, force: false, isDreaming: true
        ))
    }
}

struct VoiceHotkeyInputMonitorTests {
    private let chord: NSEvent.ModifierFlags = [.shift, .option]

    @Test func keyAndClickMonitorsOnlyWhileTheyCanMatter() {
        #expect(!VoiceHotkeyMonitor.needsInputMonitors(
            isRunning: true, isChordDown: false, isAssistantEngaged: false
        ))
        #expect(VoiceHotkeyMonitor.needsInputMonitors(
            isRunning: true, isChordDown: true, isAssistantEngaged: false
        ))
        #expect(VoiceHotkeyMonitor.needsInputMonitors(
            isRunning: true, isChordDown: false, isAssistantEngaged: true
        ))
        #expect(!VoiceHotkeyMonitor.needsInputMonitors(
            isRunning: false, isChordDown: true, isAssistantEngaged: true
        ))
    }

    @Test func chordIsDownFromExactChordUntilFullRelease() {
        var recognizer = VoiceChordRecognizer()
        _ = recognizer.modifiersChanged(to: .shift)
        let partial = recognizer.isChordDown
        _ = recognizer.modifiersChanged(to: chord)
        let held = recognizer.isChordDown
        // A key mid-chord aborts the gesture, but the chord is still held and
        // later input must still be seen until release.
        _ = recognizer.otherInputArrived()
        let abortedButHeld = recognizer.isChordDown
        _ = recognizer.modifiersChanged(to: [])
        let released = recognizer.isChordDown

        #expect(!partial)
        #expect(held)
        #expect(abortedButHeld)
        #expect(!released)
    }
}
