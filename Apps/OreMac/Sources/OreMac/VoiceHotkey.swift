import AppKit
import ApplicationServices
import Observation

/// Drives dictation from the ⇧⌥ chord, with a different gesture depending on
/// where the user is:
///
///   * **In ORE — tap to toggle.** Press and release; press again to stop.
///   * **Anywhere — hold to arm.** Wait for the cue, release, then talk
///     hands-free. A distinctive spoken phrase finishes the request.
///
/// macOS binds no action to a bare ⇧⌥, but it is a heavily used *prefix* —
/// ⇧⌥← selects by word, and Option/Shift-Option type alternate characters. A
/// naive "fired on release" would go off constantly, so a gesture only counts
/// when the flags reached exactly ⇧⌥ from nothing, no key or mouse button went
/// down while they were held, and no third modifier joined.
enum VoiceChordEvent: Equatable {
    /// A quick press and release — toggles dictation on, or off.
    case toggle
    /// The chord has been held past the threshold. Feedback should tell the
    /// user it is now safe to release, but the microphone is not open yet.
    case armed
    /// Both modifiers were released after arming: begin hands-free listening.
    case activated
    /// Another input/modifier or the release deadline invalidated the gesture.
    case cancelled
}

/// Recognizes the two ⇧⌥ gestures: a tap and a hold.
///
/// A hold cannot be detected from key events alone — nothing arrives while the
/// user simply keeps the keys down — so the owner drives `holdThresholdReached()`
/// from a timer it arms whenever `isPending` becomes true.
struct VoiceChordRecognizer {
    /// Held longer than this and it is a hold, not a tap. Deliberately generous:
    /// ⇧⌥ is a text-selection prefix (⇧⌥← selects by word), so resting on it for
    /// a moment before pressing an arrow must not open the microphone.
    static let holdThreshold = Duration.milliseconds(1_200)
    /// Once the cue has fired, a lost key-up must not leave an armed HUD around.
    static let releaseTimeout = Duration.seconds(3)
    static let chord: NSEvent.ModifierFlags = [.shift, .option]

    private var armedAt: ContinuousClock.Instant?
    private var aborted = false
    private var armed = false

    /// True while a hold could still begin, which is when a timer is worth arming.
    var isPending: Bool { armedAt != nil && !aborted && !armed }
    /// True from the moment the flags reach exactly the chord until they all
    /// lift — the only span in which a key or click can change the outcome.
    var isChordDown: Bool { armedAt != nil }
    var isAwaitingRelease: Bool { armedAt != nil && !aborted && armed }

    /// A key or click while the chord is down means the user was typing a real
    /// shortcut — ⇧⌥← and friends — not reaching for dictation.
    mutating func otherInputArrived() -> VoiceChordEvent? {
        guard armedAt != nil else { return nil }
        aborted = true
        guard armed else { return nil }
        armed = false
        return .cancelled
    }

    mutating func holdThresholdReached() -> VoiceChordEvent? {
        guard isPending else { return nil }
        armed = true
        return .armed
    }

    mutating func releaseTimedOut() -> VoiceChordEvent? {
        guard isAwaitingRelease else { return nil }
        aborted = true
        armed = false
        return .cancelled
    }

    mutating func modifiersChanged(
        to flags: NSEvent.ModifierFlags,
        at instant: ContinuousClock.Instant = .now
    ) -> VoiceChordEvent? {
        if flags == Self.chord {
            if armedAt == nil {
                armedAt = instant
                aborted = false
                armed = false
            }
            return nil
        }

        if flags.isEmpty {
            let wasArmed = armed
            let startedAt = armedAt
            let wasAborted = aborted
            armedAt = nil
            aborted = false
            armed = false

            if wasArmed, !wasAborted { return .activated }
            guard let startedAt, !wasAborted else { return nil }
            return instant - startedAt <= Self.holdThreshold ? .toggle : nil
        }

        // A third modifier joined the chord — that is a different gesture.
        if !flags.isSubset(of: Self.chord) {
            aborted = true
            if armed {
                armed = false
                return .cancelled
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
        /// The hold threshold was reached; show/play feedback while waiting
        /// for the modifiers to be released.
        case arm
        /// An armed gesture was invalidated before release.
        case disarm
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

/// Which hold-to-talk surface the ⇧⌥ chord is driving, and how release works.
enum VoiceHoldMode: Equatable {
    /// Hold arms, release opens a hands-free mic, a finish phrase sends.
    case handsFree
    /// Mic stays open only while the chord is held. Better with Bluetooth
    /// headphones, which otherwise sit on the telephony profile until a phrase.
    case holdToTalk
    /// Legacy: hold outside ORE dictates into the focused composer.
    case composer
}

/// Pure mapping from a chord event to the commands the surfaces should see.
/// Extracted so hold-to-talk vs hands-free cannot drift between the monitor
/// and its tests.
enum VoiceHoldRouting {
    static func commands(
        for event: VoiceChordEvent,
        mode: VoiceHoldMode
    ) -> [(kind: VoiceCommand.Kind, target: VoiceCommand.Target)] {
        let target: VoiceCommand.Target = mode == .composer ? .composer : .assistant
        switch event {
        case .toggle:
            return []
        case .armed:
            switch mode {
            case .composer:
                return [(.start, target)]
            case .handsFree:
                return [(.arm, target)]
            case .holdToTalk:
                return [(.arm, target), (.start, target)]
            }
        case .activated:
            switch mode {
            case .composer, .holdToTalk:
                return [(.stop, target)]
            case .handsFree:
                return [(.start, target)]
            }
        case .cancelled:
            switch mode {
            case .composer:
                return [(.stop, target)]
            case .handsFree:
                return [(.disarm, target)]
            case .holdToTalk:
                // Drop rather than send: release is the send gesture.
                return [(.cancel, target)]
            }
        }
    }
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

    /// Modifier changes only — always installed. Cheap: they fire when a
    /// modifier moves, not on every keystroke in every app.
    private var monitors: [Any] = []
    /// Key-down and mouse-down, installed only while a gesture or the
    /// assistant can use them. Watching them permanently woke ORE on every
    /// keystroke and click system-wide.
    private var inputMonitors: [Any] = []
    private var recognizer = VoiceChordRecognizer()
    private var isRunning = false
    private var holdTimer: Task<Void, Never>?
    private var releaseTimer: Task<Void, Never>?
    /// Only activate a gesture whose threshold cue was actually delivered.
    private var holdIsArmed = false
    /// Hold mode captured at arm so release/cancel cannot mix surfaces if the
    /// setting flips mid-gesture.
    private var holdModeInFlight: VoiceHoldMode = .handsFree
    private var sequence = 0

    /// Pre-assistant behavior: holding the chord outside ORE dictated into the
    /// focused composer (pulling ORE frontmost). Off by default now that hold
    /// belongs to the assistant; the Settings toggle brings it back.
    static let legacyHoldDictationKey = "ore.voice.holdDictatesComposer"
    /// Assistant mic stays open only while ⇧⌥ is held. Off by default; the
    /// hands-free finish phrase is the default send.
    static let holdToTalkKey = "ore.voice.holdToTalk"

    private var legacyHoldDictation: Bool {
        UserDefaults.standard.bool(forKey: Self.legacyHoldDictationKey)
    }

    private var holdMode: VoiceHoldMode {
        if legacyHoldDictation { return .composer }
        if UserDefaults.standard.bool(forKey: Self.holdToTalkKey) { return .holdToTalk }
        return .handsFree
    }

    private init() {}

    var isGlobal: Bool { isTrusted }

    /// Whether key and click events are worth watching: while the chord is
    /// down they cancel a gesture, and while the assistant is engaged Escape
    /// stops it. Any other time they can't change anything.
    nonisolated static func needsInputMonitors(
        isRunning: Bool,
        isChordDown: Bool,
        isAssistantEngaged: Bool
    ) -> Bool {
        isRunning && (isChordDown || isAssistantEngaged)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshTrust()
        monitors = Self.addMonitors(matching: .flagsChanged)
        observeAssistantEngagement()
        updateInputMonitors()
    }

    /// Local monitors see events aimed at ORE; global monitors see everything
    /// else and need Accessibility. Both are required for full coverage.
    private static func addMonitors(matching mask: NSEvent.EventTypeMask) -> [Any] {
        var added: [Any] = []
        let local = NSEvent.addLocalMonitorForEvents(
            matching: mask,
            handler: { event in
                MainActor.assumeIsolated { VoiceHotkeyMonitor.shared.handle(event) }
                return event  // observe only; never swallow the event
            }
        )
        if let local { added.append(local) }

        let global = NSEvent.addGlobalMonitorForEvents(
            matching: mask,
            handler: { event in
                MainActor.assumeIsolated { VoiceHotkeyMonitor.shared.handle(event) }
            }
        )
        if let global { added.append(global) }
        return added
    }

    /// Adds or removes the key/click monitors to match `needsInputMonitors`.
    private func updateInputMonitors() {
        let needed = Self.needsInputMonitors(
            isRunning: isRunning,
            isChordDown: recognizer.isChordDown,
            isAssistantEngaged: isAssistantEngaged?() == true
        )
        if needed, inputMonitors.isEmpty {
            inputMonitors = Self.addMonitors(matching: [
                .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            ])
        } else if !needed, !inputMonitors.isEmpty {
            inputMonitors.forEach(NSEvent.removeMonitor)
            inputMonitors.removeAll()
        }
    }

    /// The assistant can become engaged without a chord — a spoken
    /// interjection, say — and Escape has to work then too. Its phase is
    /// observable, so follow it rather than polling. Observation fires once
    /// per registration, hence the re-arm.
    private func observeAssistantEngagement() {
        guard isRunning else { return }
        withObservationTracking {
            _ = isAssistantEngaged?()
        } onChange: {
            Task { @MainActor in
                VoiceHotkeyMonitor.shared.updateInputMonitors()
                VoiceHotkeyMonitor.shared.observeAssistantEngagement()
            }
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        inputMonitors.forEach(NSEvent.removeMonitor)
        inputMonitors.removeAll()
        isRunning = false
        holdTimer?.cancel()
        holdTimer = nil
        releaseTimer?.cancel()
        releaseTimer = nil
        holdIsArmed = false
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
        // Last, after the gesture and any command it published have settled.
        defer { updateInputMonitors() }
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
                releaseTimer?.cancel()
                releaseTimer = nil
                holdIsArmed = false
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
        guard recognizer.isPending else {
            holdTimer = nil
            return
        }
        holdTimer = Task { [weak self] in
            try? await Task.sleep(for: VoiceChordRecognizer.holdThreshold)
            guard !Task.isCancelled, let self else { return }
            self.emit(self.recognizer.holdThresholdReached())
            self.armReleaseTimerIfNeeded()
        }
    }

    private func armReleaseTimerIfNeeded() {
        releaseTimer?.cancel()
        guard recognizer.isAwaitingRelease else {
            releaseTimer = nil
            return
        }
        // Hold-to-talk and composer dictation keep the chord down for the
        // whole utterance. The lost-keyup watchdog is only for hands-free,
        // where release is supposed to happen right after the threshold cue.
        if holdModeInFlight == .holdToTalk || holdModeInFlight == .composer {
            releaseTimer = nil
            return
        }
        releaseTimer = Task { [weak self] in
            try? await Task.sleep(for: VoiceChordRecognizer.releaseTimeout)
            guard !Task.isCancelled, let self else { return }
            self.emit(self.recognizer.releaseTimedOut())
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

        case .armed:
            let mode = holdMode
            if mode == .composer {
                // The old behavior: hold outside ORE dictates into the focused
                // composer, pulling the app frontmost. In-app it stays inert
                // (the chord is a text-selection prefix there).
                guard !NSApp.isActive else { return }
                NSApp.activate(ignoringOtherApps: true)
            }
            holdModeInFlight = mode
            holdIsArmed = true
            for command in VoiceHoldRouting.commands(for: .armed, mode: mode) {
                publish(command.kind, target: command.target)
            }

        case .activated:
            releaseTimer?.cancel()
            releaseTimer = nil
            guard holdIsArmed else { return }
            holdIsArmed = false
            for command in VoiceHoldRouting.commands(for: .activated, mode: holdModeInFlight) {
                publish(command.kind, target: command.target)
            }

        case .cancelled:
            releaseTimer?.cancel()
            releaseTimer = nil
            guard holdIsArmed else { return }
            holdIsArmed = false
            for command in VoiceHoldRouting.commands(for: .cancelled, mode: holdModeInFlight) {
                publish(command.kind, target: command.target)
            }

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
