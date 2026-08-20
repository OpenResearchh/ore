import AppKit
import ApplicationServices
import Observation

/// Drives dictation from the ⇧⌥ chord, with a different gesture depending on
/// where the user is:
///
///   * **In ORE — tap to toggle.** Press and release; press again to stop.
///   * **Anywhere else — hold to talk.** Dictation runs while the chord is held
///     and stops on release, so the microphone can never be left open in an app
///     the user has walked away from.
///
/// macOS binds no action to a bare ⇧⌥, but it is a heavily used *prefix* —
/// ⇧⌥← selects by word, and Option/Shift-Option type alternate characters. A
/// naive "fired on release" would go off constantly, so a gesture only counts
/// when the flags reached exactly ⇧⌥ from nothing, no key or mouse button went
/// down while they were held, and no third modifier joined.
enum VoiceChordEvent: Equatable {
    /// A quick press and release — toggles dictation on, or off.
    case toggle
    /// The chord has been held past the threshold: dictate until it is released.
    case beginHold
    case endHold
}

/// Recognizes the two ⇧⌥ gestures: a tap and a hold.
///
/// A hold cannot be detected from key events alone — nothing arrives while the
/// user simply keeps the keys down — so the owner drives `holdThresholdReached()`
/// from a timer it arms whenever `isArmed` becomes true.
struct VoiceChordRecognizer {
    /// Held longer than this and it is a hold, not a tap. Deliberately generous:
    /// ⇧⌥ is a text-selection prefix (⇧⌥← selects by word), so resting on it for
    /// a moment before pressing an arrow must not open the microphone.
    static let holdThreshold = Duration.milliseconds(600)
    static let chord: NSEvent.ModifierFlags = [.shift, .option]

    private var armedAt: ContinuousClock.Instant?
    private var aborted = false
    private var holding = false

    /// True while a hold could still begin, which is when a timer is worth arming.
    var isArmed: Bool { armedAt != nil && !aborted && !holding }

    /// A key or click while the chord is down means the user was typing a real
    /// shortcut — ⇧⌥← and friends — not reaching for dictation.
    mutating func otherInputArrived() -> VoiceChordEvent? {
        guard armedAt != nil else { return nil }
        aborted = true
        guard holding else { return nil }
        holding = false
        return .endHold
    }

    mutating func holdThresholdReached() -> VoiceChordEvent? {
        guard isArmed else { return nil }
        holding = true
        return .beginHold
    }

    mutating func modifiersChanged(
        to flags: NSEvent.ModifierFlags,
        at instant: ContinuousClock.Instant = .now
    ) -> VoiceChordEvent? {
        if flags == Self.chord {
            if armedAt == nil {
                armedAt = instant
                aborted = false
                holding = false
            }
            return nil
        }

        if flags.isEmpty {
            let wasHolding = holding
            let startedAt = armedAt
            let wasAborted = aborted
            armedAt = nil
            aborted = false
            holding = false

            if wasHolding { return .endHold }
            guard let startedAt, !wasAborted else { return nil }
            return instant - startedAt <= Self.holdThreshold ? .toggle : nil
        }

        // A third modifier joined the chord — that is a different gesture.
        if !flags.isSubset(of: Self.chord) {
            aborted = true
            if holding {
                holding = false
                return .endHold
            }
        }
        return nil
    }
}

/// What a voice surface should do, with an id so an identical repeat still
/// lands. `target` is which surface: the on-screen composer (tap to dictate)
/// or the global assistant (hold to talk).
struct VoiceCommand: Equatable {
    enum Kind: Equatable {
        case toggle
        case start
        case stop
        /// Park whatever is being dictated in the draft without sending —
        /// used when the assistant takes the microphone over mid-dictation.
        case commit
        /// Stop now: drop the utterance, the turn, or the speech, depending on
        /// where the exchange had got to.
        case cancel
    }
    enum Target: Equatable { case composer, assistant }
    var id: Int
    var kind: Kind
    var target: Target = .composer
}

@MainActor
@Observable
final class VoiceHotkeyMonitor {
    static let shared = VoiceHotkeyMonitor()

    /// The latest gesture. Views watch this rather than being called back, so
    /// the gesture stays decoupled from whichever composer is on screen.
    private(set) var command: VoiceCommand?
    /// Direct delivery for app-level consumers (the assistant), which must
    /// keep hearing gestures when no window — and so no observing view —
    /// exists.
    var onCommand: (@MainActor (VoiceCommand) -> Void)?
    /// Whether a voice exchange is actually on screen. Escape is only claimed
    /// while the HUD is up: the rest of the time it belongs to whatever app the
    /// user is in, and publishing a command per keystroke would churn every
    /// view observing `command` for nothing.
    var isAssistantEngaged: (@MainActor () -> Bool)?
    /// Whether macOS lets us see events from other apps. Without it the tap
    /// still works while ORE is frontmost.
    private(set) var isTrusted = false

    private var monitors: [Any] = []
    private var recognizer = VoiceChordRecognizer()
    private var isRunning = false
    private var holdTimer: Task<Void, Never>?
    /// Only send `.stop` for a hold we actually started, so releasing the chord
    /// can never cancel a dictation the user began by tapping.
    private var holdIsDictating = false
    /// Where the current hold's words are going, fixed at `beginHold` so the
    /// release always lands on the surface that started listening.
    private var holdTarget: VoiceCommand.Target = .assistant
    private var sequence = 0

    /// Pre-assistant behavior: holding the chord outside ORE dictated into the
    /// focused composer (pulling ORE frontmost). Off by default now that hold
    /// belongs to the assistant; the Settings toggle brings it back.
    static let legacyHoldDictationKey = "ore.voice.holdDictatesComposer"

    private var legacyHoldDictation: Bool {
        UserDefaults.standard.bool(forKey: Self.legacyHoldDictationKey)
    }

    private init() {}

    var isGlobal: Bool { isTrusted }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshTrust()

        // Local monitors see events aimed at ORE; global monitors see everything
        // else and need Accessibility. Both are required for full coverage.
        let watched: NSEvent.EventTypeMask = [
            .flagsChanged, .keyDown,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]

        let local = NSEvent.addLocalMonitorForEvents(
            matching: watched,
            handler: { event in
                MainActor.assumeIsolated { VoiceHotkeyMonitor.shared.handle(event) }
                return event  // observe only; never swallow the event
            }
        )
        if let local { monitors.append(local) }

        let global = NSEvent.addGlobalMonitorForEvents(
            matching: watched,
            handler: { event in
                MainActor.assumeIsolated { VoiceHotkeyMonitor.shared.handle(event) }
            }
        )
        if let global { monitors.append(global) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        isRunning = false
        holdTimer?.cancel()
        holdTimer = nil
        holdIsDictating = false
        recognizer = VoiceChordRecognizer()
    }

    @discardableResult
    func refreshTrust() -> Bool {
        isTrusted = AXIsProcessTrusted()
        return isTrusted
    }

    /// Opens the system prompt that adds ORE to Accessibility. Returns whether
    /// permission was already granted.
    @discardableResult
    func requestAccessibility() -> Bool {
        // Spelled out rather than using `kAXTrustedCheckOptionPrompt`: that
        // symbol imports as a mutable global, which strict concurrency rejects.
        // The key's value is API and does not change.
        let granted = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
        isTrusted = granted
        return granted
    }

    // MARK: - Gesture

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            emit(recognizer.modifiersChanged(to: flags))
            armHoldTimerIfNeeded()
        default:
            holdTimer?.cancel()
            holdTimer = nil
            // Escape is only *observed*, never swallowed — the monitors can't
            // consume events anyway, so it still does whatever it does in the
            // app the user is looking at. Stopping the assistant is additive.
            if Self.isCancelKey(event), isAssistantEngaged?() == true {
                // It also wins over the hold it interrupts. Escape mid-sentence
                // means "forget it", so releasing the chord afterwards must not
                // still send the words the user just abandoned.
                _ = recognizer.otherInputArrived()
                holdIsDictating = false
                publish(.cancel, target: .assistant)
                return
            }
            emit(recognizer.otherInputArrived())
        }
    }

    /// Bare Escape. With a modifier it is someone else's shortcut.
    nonisolated static func isCancelKey(_ event: NSEvent) -> Bool {
        let escape: UInt16 = 53
        return event.type == .keyDown
            && event.keyCode == escape
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
    }

    /// Nothing is delivered while keys are merely held down, so a hold has to be
    /// noticed on a timer rather than an event.
    private func armHoldTimerIfNeeded() {
        holdTimer?.cancel()
        guard recognizer.isArmed else {
            holdTimer = nil
            return
        }
        holdTimer = Task { [weak self] in
            try? await Task.sleep(for: VoiceChordRecognizer.holdThreshold)
            guard !Task.isCancelled, let self else { return }
            self.emit(self.recognizer.holdThresholdReached())
        }
    }

    private func emit(_ event: VoiceChordEvent?) {
        switch event {
        case .toggle:
            // In ORE a tap toggles composer dictation. Outside it, a stray tap
            // must not quietly open the microphone in an app the user is busy
            // typing in.
            guard NSApp.isActive else { return }
            publish(.toggle, target: .composer)

        case .beginHold:
            if legacyHoldDictation {
                // The old behavior: hold outside ORE dictates into the focused
                // composer, pulling the app frontmost. In-app it stays inert
                // (the chord is a text-selection prefix there).
                guard !NSApp.isActive else { return }
                NSApp.activate(ignoringOtherApps: true)
                holdTarget = .composer
            } else {
                // Hold is the assistant, everywhere — and the assistant is
                // headless, so the user's focus stays exactly where it is.
                holdTarget = .assistant
            }
            holdIsDictating = true
            publish(.start, target: holdTarget)

        case .endHold:
            guard holdIsDictating else { return }
            holdIsDictating = false
            publish(.stop, target: holdTarget)

        case nil:
            break
        }
    }

    /// Lets the assistant ask the visible composer to park an in-flight
    /// dictation in its draft before the assistant takes the microphone.
    func requestComposerCommit() {
        publish(.commit, target: .composer)
    }

    private func publish(_ kind: VoiceCommand.Kind, target: VoiceCommand.Target) {
        sequence += 1
        let published = VoiceCommand(id: sequence, kind: kind, target: target)
        command = published
        onCommand?(published)
    }
}
