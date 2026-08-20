import AppKit
import SwiftUI

/// The floating "the assistant can hear you" pill.
///
/// Shown while the hold-to-talk mic is open and until the reply lands, on a
/// borderless non-activating panel — it appears over whatever app the user is
/// in without taking focus from it, which is the voice mode's whole contract.
/// Deliberately small and contained: a waveform that breathes with the voice,
/// and one line of what the recognizer is hearing.
@MainActor
final class AssistantVoiceHUD {
    static let shared = AssistantVoiceHUD()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private static let size = NSSize(width: 380, height: 56)

    private init() {}

    func phaseChanged(_ controller: VoiceAssistantController) {
        if controller.phase == .idle {
            hide()
        } else {
            show(controller)
        }
    }

    private func show(_ controller: VoiceAssistantController) {
        hideTask?.cancel()
        hideTask = nil
        let panel = panel ?? makePanel(controller)
        position(panel)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel else { return }
        hideTask?.cancel()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func makePanel(_ controller: VoiceAssistantController) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            // Non-activating is the load-bearing bit: the pill can appear over
            // Safari without Safari losing the keyboard.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.alphaValue = 0
        panel.contentView = NSHostingView(rootView: AssistantHUDView(controller: controller))
        self.panel = panel
        return panel
    }

    /// Bottom-centre of whichever screen the user is working on — the mouse's
    /// screen, not ORE's, since the whole point is being somewhere else.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - Self.size.width / 2,
            y: frame.minY + 84
        ))
    }
}

private struct AssistantHUDView: View {
    var controller: VoiceAssistantController

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: controller.phase == .speaking ? "speaker.wave.2.fill" : "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            WaveformBars(mode: waveform)
                .frame(width: 34, height: 20)

            StreamingTranscript(text: transcript, placeholder: placeholder)
                .foregroundStyle(micIsOpen ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)

            // Only promised when the key can actually be seen: without
            // Accessibility the monitors are blind outside ORE, and the pill's
            // whole point is being somewhere else.
            if controller.canInterrupt, VoiceHotkeyMonitor.shared.isGlobal {
                InterruptHint()
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 380 - 16, height: 44)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .frame(width: 380, height: 56)
        .animation(.easeOut(duration: 0.2), value: controller.phase)
    }

    private var micIsOpen: Bool {
        controller.phase == .listening || controller.phase == .answering
    }

    private var waveform: WaveformBars.Mode {
        switch controller.phase {
        case .listening, .answering: .listening(controller.audioLevel)
        case .speaking: .speaking
        case .thinking, .idle: .thinking
        }
    }

    /// The line the pill streams. Listening and speaking are the same shape —
    /// words arriving one at a time — which is the point: the user sees the
    /// assistant talk exactly the way they see it listen.
    private var transcript: String {
        switch controller.phase {
        case .listening, .answering:
            controller.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        case .speaking:
            controller.spokenSoFar.trimmingCharacters(in: .whitespacesAndNewlines)
        case .thinking, .idle:
            ""
        }
    }

    private var placeholder: String {
        switch controller.phase {
        case .listening: "Listening…"
        case .answering: "Yes or no?"
        case .thinking: "Thinking…"
        case .speaking: "Speaking…"
        case .idle: ""
        }
    }
}

/// The transcript, revealed a word at a time and scrolled to keep the newest
/// word in view.
///
/// Replaces a static "…last nine words", which showed a finished sentence with
/// an ellipsis bolted on and looked identical whether the assistant was
/// mid-word or done. The scroll is programmatic only — the panel ignores mouse
/// events, so there is nothing for a user to drag.
private struct StreamingTranscript: View {
    var text: String
    var placeholder: String

    /// A trailing anchor rather than the last word: scrolling to the word
    /// itself would stop as soon as it fit, leaving the tail hard against the
    /// edge mid-animation.
    private static let tailID = "tail"

    private var words: [(id: Int, text: String)] {
        // Any whitespace, not just spaces: a recognizer's partial results and a
        // narration line can both carry a newline, and one long "word" the
        // width of the pill would freeze the scroll.
        text.split(whereSeparator: \.isWhitespace)
            .enumerated().map { ($0.offset, String($0.element)) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    if words.isEmpty {
                        Text(placeholder)
                    } else {
                        ForEach(words, id: \.id) { word in
                            Text(word.text).transition(.opacity)
                        }
                    }
                    Color.clear.frame(width: 1, height: 1).id(Self.tailID)
                }
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .animation(.easeOut(duration: 0.18), value: text)
            }
            // No `scrollDisabled`: the panel already ignores mouse events, so
            // there is no gesture to suppress — and the modifier has a habit of
            // taking `scrollTo` down with it.
            .frame(height: 18)
            .onChange(of: text) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.tailID, anchor: .trailing)
                }
            }
        }
    }
}

/// "esc" as a key cap, shown only while there is a turn or an utterance to
/// stop — an affordance the user can't otherwise discover, since the pill is
/// the only thing on screen.
private struct InterruptHint: View {
    var body: some View {
        Text("esc")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 1))
            .transition(.opacity)
    }
}

/// Five bars that breathe with the microphone while listening, ride a steady
/// wave while the assistant speaks, and settle into a slow pulse while it
/// works.
private struct WaveformBars: View {
    enum Mode: Equatable {
        /// 0…1 microphone loudness.
        case listening(Double)
        case thinking
        case speaking
    }

    var mode: Mode

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3.5, height: height(bar: index, time: time))
                }
            }
            .frame(height: 20, alignment: .center)
        }
    }

    private func height(bar index: Int, time: TimeInterval) -> CGFloat {
        switch mode {
        case .listening(let level):
            // Each bar rides its own phase of the same wave; loudness scales
            // the whole figure so silence reads as a flat quiet line.
            let wave = sin(time * 9 + Double(index) * 1.7) * 0.5 + 0.5
            let energy = 0.15 + min(max(level, 0), 1) * 0.85
            return 4 + CGFloat(wave * energy) * 16
        case .speaking:
            // No output meter to ride, so a steady mid-tempo wave stands in:
            // busier than thinking, calmer than a voice hitting the mic.
            let wave = sin(time * 6 + Double(index) * 1.3) * 0.5 + 0.5
            return 4 + CGFloat(wave) * 11
        case .thinking:
            // One slow, gentle swell — alive, but clearly not hearing.
            let swell = sin(time * 2.4 + Double(index) * 0.35) * 0.5 + 0.5
            return 4 + CGFloat(swell) * 5
        }
    }
}
