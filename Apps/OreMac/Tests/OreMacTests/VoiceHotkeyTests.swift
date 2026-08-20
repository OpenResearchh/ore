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

    @Test func holdingBeginsAndEndsDictation() {
        var recognizer = VoiceChordRecognizer()
        _ = recognizer.modifiersChanged(to: chord, at: start)
        let began = recognizer.holdThresholdReached()
        let ended = recognizer.modifiersChanged(to: [], at: start.advanced(by: .seconds(4)))
        #expect(began == .beginHold)
        #expect(ended == .endHold)
    }

    /// A hold that already started must not also report a tap on release.
    @Test func aHoldNeverAlsoReportsATap() {
        var recognizer = VoiceChordRecognizer()
        _ = recognizer.modifiersChanged(to: chord, at: start)
        _ = recognizer.holdThresholdReached()
        let ended = recognizer.modifiersChanged(to: [], at: start.advanced(by: afterHold))
        #expect(ended == .endHold)
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

    /// If a key arrives after dictation already started, close it cleanly rather
    /// than leaving the microphone open.
    @Test func aKeyPressDuringAHoldEndsIt() {
        var recognizer = VoiceChordRecognizer()
        _ = recognizer.modifiersChanged(to: chord, at: start)
        _ = recognizer.holdThresholdReached()
        let interrupted = recognizer.otherInputArrived()
        let released = recognizer.modifiersChanged(to: [], at: start.advanced(by: afterHold))
        #expect(interrupted == .endHold)
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

    @Test func addingAThirdModifierDuringAHoldEndsIt() {
        var recognizer = VoiceChordRecognizer()
        _ = recognizer.modifiersChanged(to: chord, at: start)
        _ = recognizer.holdThresholdReached()
        let joined = recognizer.modifiersChanged(to: [.shift, .option, .command], at: start)
        #expect(joined == .endHold)
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

    /// The timer is only worth arming while a hold is still possible.
    @Test func armedOnlyWhileAHoldCouldStillBegin() {
        var recognizer = VoiceChordRecognizer()
        #expect(!recognizer.isArmed)
        _ = recognizer.modifiersChanged(to: chord, at: start)
        #expect(recognizer.isArmed)
        _ = recognizer.holdThresholdReached()
        #expect(!recognizer.isArmed)  // already holding
        _ = recognizer.modifiersChanged(to: [], at: start.advanced(by: afterHold))
        #expect(!recognizer.isArmed)
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
