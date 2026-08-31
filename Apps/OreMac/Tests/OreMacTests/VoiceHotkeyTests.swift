import AppKit
import Testing
@testable import OreMac

/// ⇧⌥ is unbound on macOS but is a very common prefix — ⇧⌥← selects by word, and
/// Option/Shift-Option type alternate characters — so these guards are the whole
/// feature. A gesture that fires while the user is selecting text would be worse
/// than no shortcut at all.
///
/// `#expect` cannot call a mutating method, hence the local bindings.
struct VoiceChordRecognizerTests {
    private let chord: NSEvent.ModifierFlags = [.shift, .option]
    private let start = ContinuousClock.now
    private var beforeHold: Duration { VoiceChordRecognizer.holdThreshold - .milliseconds(100) }
    private var afterHold: Duration { VoiceChordRecognizer.holdThreshold + .milliseconds(100) }

    // MARK: Tap

    @Test func aCleanTapToggles() {
        var recognizer = VoiceChordRecognizer()
        let building = recognizer.modifiersChanged(to: .shift, at: start)
        let armed = recognizer.modifiersChanged(to: chord, at: start)
        let released = recognizer.modifiersChanged(to: [], at: start.advanced(by: beforeHold))
        #expect(building == nil)
        #expect(armed == nil)
        #expect(released == .toggle)
    }

    @Test func tappingTwiceTogglesTwice() {
        var recognizer = VoiceChordRecognizer()
        var toggles = 0
        for step in 0..<2 {
            let base = start.advanced(by: .seconds(step))
            _ = recognizer.modifiersChanged(to: chord, at: base)
            if recognizer.modifiersChanged(to: [], at: base.advanced(by: .milliseconds(80)))
                == .toggle { toggles += 1 }
        }
        #expect(toggles == 2)
    }

    @Test func releasingOneModifierBeforeTheOtherStillTaps() {
        var recognizer = VoiceChordRecognizer()
        _ = recognizer.modifiersChanged(to: chord, at: start)
        // Shift lifts a moment before Option.
        let midway = recognizer.modifiersChanged(to: .option, at: start.advanced(by: .milliseconds(60)))
        let released = recognizer.modifiersChanged(to: [], at: start.advanced(by: .milliseconds(80)))
        #expect(midway == nil)
        #expect(released == .toggle)
    }

    // MARK: Hold

    @Test func holdingArmsAndReleaseActivatesHandsFreeListening() {
        var recognizer = VoiceChordRecognizer()
        _ = recognizer.modifiersChanged(to: chord, at: start)
        let armed = recognizer.holdThresholdReached()
        let activated = recognizer.modifiersChanged(to: [], at: start.advanced(by: .seconds(2)))
        #expect(armed == .armed)
        #expect(activated == .activated)
    }

    /// A hold that already started must not also report a tap on release.
    @Test func aHoldNeverAlsoReportsATap() {
        var recognizer = VoiceChordRecognizer()
        _ = recognizer.modifiersChanged(to: chord, at: start)
        _ = recognizer.holdThresholdReached()
        let ended = recognizer.modifiersChanged(to: [], at: start.advanced(by: afterHold))
        #expect(ended == .activated)
    }

    /// The reason the threshold is generous: resting on ⇧⌥ before pressing an
    /// arrow to select by word must not open the microphone.
    @Test func aKeyPressCancelsAPendingHold() {
        var recognizer = VoiceChordRecognizer()
        _ = recognizer.modifiersChanged(to: chord, at: start)
        let cancelled = recognizer.otherInputArrived()  // ⇧⌥←
        let began = recognizer.holdThresholdReached()
        let released = recognizer.modifiersChanged(to: [], at: start.advanced(by: afterHold))
        #expect(cancelled == nil)
        #expect(began == nil)
        #expect(released == nil)
    }

    /// Input before release means this was a shortcut, not a voice activation.
    @Test func aKeyPressWhileArmedCancelsActivation() {
        var recognizer = VoiceChordRecognizer()
        _ = recognizer.modifiersChanged(to: chord, at: start)
        _ = recognizer.holdThresholdReached()
        let interrupted = recognizer.otherInputArrived()
        let released = recognizer.modifiersChanged(to: [], at: start.advanced(by: afterHold))
        #expect(interrupted == .cancelled)
        #expect(released == nil)
    }

    @Test func holdingTooBrieflyIsATapNotAHold() {
        var recognizer = VoiceChordRecognizer()
        _ = recognizer.modifiersChanged(to: chord, at: start)
        let released = recognizer.modifiersChanged(to: [], at: start.advanced(by: beforeHold))
        #expect(released == .toggle)
    }

    /// Held long, then released without the timer ever having fired: neither a
    /// tap nor a dangling hold.
    @Test func aLongHoldThatNeverBeganDoesNothingOnRelease() {
        var recognizer = VoiceChordRecognizer()
        _ = recognizer.modifiersChanged(to: chord, at: start)
        let released = recognizer.modifiersChanged(to: [], at: start.advanced(by: afterHold))
        #expect(released == nil)
    }

    // MARK: Cancellation

    @Test func clickingWhileHeldCancelsTheGesture() {
        var recognizer = VoiceChordRecognizer()
        _ = recognizer.modifiersChanged(to: chord, at: start)
        _ = recognizer.otherInputArrived()
        let released = recognizer.modifiersChanged(to: [], at: start.advanced(by: beforeHold))
        #expect(released == nil)
    }

    @Test func addingAThirdModifierCancelsTheGesture() {
        var recognizer = VoiceChordRecognizer()
        _ = recognizer.modifiersChanged(to: chord, at: start)
        let joined = recognizer.modifiersChanged(to: [.shift, .option, .command], at: start)
        let released = recognizer.modifiersChanged(to: [], at: start.advanced(by: beforeHold))
        #expect(joined == nil)
        #expect(released == nil)
    }

    @Test func addingAThirdModifierWhileArmedCancelsIt() {
        var recognizer = VoiceChordRecognizer()
        _ = recognizer.modifiersChanged(to: chord, at: start)
        _ = recognizer.holdThresholdReached()
        let joined = recognizer.modifiersChanged(to: [.shift, .option, .command], at: start)
        #expect(joined == .cancelled)
    }

    @Test func otherShortcutsNeverArmTheGesture() {
        var recognizer = VoiceChordRecognizer()
        var events: [VoiceChordEvent] = []
        for flags in [NSEvent.ModifierFlags.command, .option, .shift, [.command, .shift]] {
            if let armed = recognizer.modifiersChanged(to: flags, at: start) { events.append(armed) }
            if let released = recognizer.modifiersChanged(
                to: [], at: start.advanced(by: .milliseconds(50))
            ) { events.append(released) }
        }
        #expect(events.isEmpty)
    }

    @Test func aCancelledGestureDoesNotBlockTheNextOne() {
        var recognizer = VoiceChordRecognizer()
        _ = recognizer.modifiersChanged(to: chord, at: start)
        _ = recognizer.otherInputArrived()
        let cancelled = recognizer.modifiersChanged(to: [], at: start.advanced(by: beforeHold))

        let later = start.advanced(by: .seconds(3))
        _ = recognizer.modifiersChanged(to: chord, at: later)
        let toggled = recognizer.modifiersChanged(to: [], at: later.advanced(by: .milliseconds(70)))
        #expect(cancelled == nil)
        #expect(toggled == .toggle)
    }

    @Test func thresholdMatchesThePromisedOneToTwoSecondHold() {
        #expect(VoiceChordRecognizer.holdThreshold >= .seconds(1))
        #expect(VoiceChordRecognizer.holdThreshold <= .seconds(2))
    }

    @Test func releasingModifiersOneAtATimeDoesNotFalseActivate() {
        var recognizer = VoiceChordRecognizer()
        _ = recognizer.modifiersChanged(to: chord, at: start)
        _ = recognizer.holdThresholdReached()
        let oneReleased = recognizer.modifiersChanged(
            to: .option, at: start.advanced(by: .milliseconds(1_300))
        )
        #expect(recognizer.isAwaitingRelease)
        let allReleased = recognizer.modifiersChanged(
            to: [], at: start.advanced(by: .milliseconds(1_350))
        )
        #expect(oneReleased == nil)
        #expect(allReleased == .activated)
        #expect(!recognizer.isAwaitingRelease)
    }

    @Test func armedGestureTimesOutWithoutActivating() {
        var recognizer = VoiceChordRecognizer()
        _ = recognizer.modifiersChanged(to: chord, at: start)
        _ = recognizer.holdThresholdReached()
        let timeout = recognizer.releaseTimedOut()
        let release = recognizer.modifiersChanged(to: [], at: start.advanced(by: .seconds(5)))
        #expect(timeout == .cancelled)
        #expect(release == nil)
    }

    /// The threshold timer only runs while a hold can still be armed.
    @Test func pendingAndAwaitingReleaseTrackSeparateGestureStages() {
        var recognizer = VoiceChordRecognizer()
        #expect(!recognizer.isPending)
        #expect(!recognizer.isAwaitingRelease)
        _ = recognizer.modifiersChanged(to: chord, at: start)
        #expect(recognizer.isPending)
        _ = recognizer.holdThresholdReached()
        #expect(!recognizer.isPending)
        #expect(recognizer.isAwaitingRelease)
        _ = recognizer.modifiersChanged(to: [], at: start.advanced(by: afterHold))
        #expect(!recognizer.isPending)
        #expect(!recognizer.isAwaitingRelease)
    }
}

/// Hold-to-talk vs hands-free vs composer: the chord recognizer is shared;
/// only the command mapping differs. Tests pin that table so a settings
/// toggle cannot silently mix send-on-release with finish-phrase listening.
struct VoiceHoldRoutingTests {
    @Test func handsFreeArmsThenStartsOnRelease() {
        #expect(kinds(.armed, .handsFree) == [.arm])
        #expect(kinds(.activated, .handsFree) == [.start])
        #expect(kinds(.cancelled, .handsFree) == [.disarm])
    }

    @Test func holdToTalkOpensTheMicAtTheThresholdAndSendsOnRelease() {
        #expect(kinds(.armed, .holdToTalk) == [.arm, .start])
        #expect(kinds(.activated, .holdToTalk) == [.stop])
        #expect(kinds(.cancelled, .holdToTalk) == [.cancel])
    }

    @Test func composerHoldDictatesUntilReleaseOrCancel() {
        #expect(kinds(.armed, .composer) == [.start])
        #expect(kinds(.activated, .composer) == [.stop])
        #expect(kinds(.cancelled, .composer) == [.stop])
    }

    @Test func aTapNeverBecomesAHoldCommand() {
        for mode: VoiceHoldMode in [.handsFree, .holdToTalk, .composer] {
            #expect(VoiceHoldRouting.commands(for: .toggle, mode: mode).isEmpty)
        }
    }

    @Test func assistantModesNeverTargetTheComposer() {
        for event: VoiceChordEvent in [.armed, .activated, .cancelled] {
            for mode: VoiceHoldMode in [.handsFree, .holdToTalk] {
                for command in VoiceHoldRouting.commands(for: event, mode: mode) {
                    #expect(command.target == .assistant)
                }
            }
        }
    }

    @Test func composerModeNeverTargetsTheAssistant() {
        for event: VoiceChordEvent in [.armed, .activated, .cancelled] {
            for command in VoiceHoldRouting.commands(for: event, mode: .composer) {
                #expect(command.target == .composer)
            }
        }
    }

    private func kinds(
        _ event: VoiceChordEvent,
        _ mode: VoiceHoldMode
    ) -> [VoiceCommand.Kind] {
        VoiceHoldRouting.commands(for: event, mode: mode).map(\.kind)
    }
}

/// Escape stops the assistant mid-thought. It is only claimed while the HUD is
/// up, and only bare — with a modifier it belongs to whatever app the user is
/// actually in.
@MainActor
struct VoiceCancelKeyTests {
    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code
        )
    }

    @Test func bareEscapeCancels() throws {
        let escape = try #require(key(53))
        #expect(VoiceHotkeyMonitor.isCancelKey(escape))
    }

    @Test func modifiedEscapeBelongsToSomeoneElse() throws {
        for flags in [NSEvent.ModifierFlags.command, .option, .shift, .control] {
            let event = try #require(key(53, flags))
            #expect(!VoiceHotkeyMonitor.isCancelKey(event))
        }
    }

    @Test func otherKeysDoNotCancel() throws {
        // Return, in particular: it is how a dictated prompt gets sent.
        for code: UInt16 in [36, 49, 0, 12] {
            let event = try #require(key(code))
            #expect(!VoiceHotkeyMonitor.isCancelKey(event))
        }
    }
}
