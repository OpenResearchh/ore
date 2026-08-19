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
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            WaveformBars(
                level: micIsOpen ? controller.audioLevel : nil
            )
            .frame(width: 34, height: 20)

            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(micIsOpen ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
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

    private var label: String {
        switch controller.phase {
        case .listening:
            let transcript = controller.liveTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return transcript.isEmpty ? "Listening…" : tail(of: transcript)
        case .answering:
            let transcript = controller.liveTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return transcript.isEmpty ? "Yes or no?" : tail(of: transcript)
        case .thinking:
            return "Thinking…"
        case .idle:
            return ""
        }
    }

    /// The last few words only: the pill shows "what it's hearing right now",
    /// the Assistant window keeps the full record.
    private func tail(of transcript: String, words: Int = 9) -> String {
        let parts = transcript.split(separator: " ")
        guard parts.count > words else { return transcript }
        return "…" + parts.suffix(words).joined(separator: " ")
    }
}

/// Five bars that breathe with the microphone while listening, and settle
/// into a slow synchronized pulse while the assistant works.
private struct WaveformBars: View {
    /// 0…1 microphone loudness, or nil when not listening (thinking pulse).
    var level: Double?

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
        if let level {
            // Each bar rides its own phase of the same wave; loudness scales
            // the whole figure so silence reads as a flat quiet line.
            let wave = sin(time * 9 + Double(index) * 1.7) * 0.5 + 0.5
            let energy = 0.15 + min(max(level, 0), 1) * 0.85
            return 4 + CGFloat(wave * energy) * 16
        }
        // Thinking: one slow, gentle swell — alive, but clearly not hearing.
        let swell = sin(time * 2.4 + Double(index) * 0.35) * 0.5 + 0.5
        return 4 + CGFloat(swell) * 5
    }
}
