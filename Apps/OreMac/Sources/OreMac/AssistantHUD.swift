import AppKit
import SwiftUI

/// The floating assistant pill.
///
/// Two jobs on one borderless, non-activating panel that appears over
/// whatever app the user is in without taking focus:
/// - While the hold-to-talk mic is open: a waveform that breathes with the
///   voice and one line of what the recognizer is hearing.
/// - When a tab is blocked on the user and they're away from ORE (or mid
///   voice session): the ask itself, with clickable Allow / Deny / options —
///   the spoken "quick check" and the buttons to answer it live in one place.
@MainActor
final class AssistantVoiceHUD {
    static let shared = AssistantVoiceHUD()

    /// What the SwiftUI content should currently render. Written only by
    /// `evaluate()` so the panel's size and the view's rows can never
    /// disagree.
    @Observable
    final class DisplayState {
        var showsVoiceRow = false
        var showsActions = false
    }

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private weak var model: AppModel?
    private var controller: VoiceAssistantController?
    private let display = DisplayState()
    /// Cards the user waved away with ✕ — the ask itself stays pending (in
    /// the app's own card and the menu bar); only this surface goes quiet.
    private var dismissedNeedsYouIDs: Set<String> = []

    private static let pillSize = NSSize(width: 380, height: 56)
    private static let actionWidth: CGFloat = 460

    func dismissNeedsYouCard(_ id: String) {
        dismissedNeedsYouIDs.insert(id)
        evaluate()
    }

    private init() {}

    /// Called once from `AppModel.start()`; the HUD then follows the model's
    /// needs-you list and the voice phase on its own.
    func bind(model: AppModel) {
        self.model = model
        controller = model.voiceAssistant
        armObservation()
        for name in [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in AssistantVoiceHUD.shared.evaluate() }
            }
        }
        evaluate()
    }

    func phaseChanged(_ controller: VoiceAssistantController) {
        self.controller = controller
        evaluate()
    }

    /// Re-arms after every change: `withObservationTracking` is one-shot.
    private func armObservation() {
        guard let model, let controller else { return }
        withObservationTracking {
            _ = model.tabNeedsYou
            _ = controller.phase
        } onChange: {
            Task { @MainActor in
                AssistantVoiceHUD.shared.evaluate()
                AssistantVoiceHUD.shared.armObservation()
            }
        }
    }

    /// The needs-you item worth surfacing on the pill right now. In-app, the
    /// transcript's own card is the answer surface; the pill takes over when
    /// the user is somewhere else or mid voice session.
    private var actionableNeedsYou: TabNeedsYou? {
        guard let model,
              let item = model.tabNeedsYou.last(where: { !dismissedNeedsYouIDs.contains($0.id) })
        else { return nil }
        let voiceActive = (controller?.phase ?? .idle) != .idle
        guard voiceActive || !NSApp.isActive else { return nil }
        return item
    }

    private func evaluate() {
        let voiceActive = (controller?.phase ?? .idle) != .idle
        let actionable = actionableNeedsYou
        let actions = actionable != nil
        display.showsVoiceRow = voiceActive
        display.showsActions = actions
        guard voiceActive || actions else {
            hide()
            return
        }

        hideTask?.cancel()
        hideTask = nil
        let panel = panel ?? makePanel()
        // Questions carry a full prompt plus an options row and need the
        // taller card; permissions stay one line.
        let isQuestion = if case .question = actionable { true } else { false }
        let actionHeight: CGFloat = isQuestion ? 128 : 76
        let size = voiceActive && actions
            ? NSSize(width: Self.actionWidth, height: 64 + actionHeight)
            : actions
            ? NSSize(width: Self.actionWidth, height: actionHeight)
            : Self.pillSize
        panel.setContentSize(size)
        // Buttons need the mouse; the voice-only pill must stay a ghost so
        // it never blocks clicks in the app underneath it.
        panel.ignoresMouseEvents = !actions
        position(panel, size: size)
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

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.pillSize),
            // Non-activating is the load-bearing bit: the pill can appear over
            // Safari without Safari losing the keyboard — and its buttons
            // still take clicks without activating ORE.
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
        panel.contentView = NSHostingView(rootView: AssistantHUDView(
            controller: controller ?? VoiceAssistantController(),
            model: model,
            display: display
        ))
        self.panel = panel
        return panel
    }

    /// Bottom-centre of whichever screen the user is working on — the mouse's
    /// screen, not ORE's, since the whole point is being somewhere else.
    private func position(_ panel: NSPanel, size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 84
        ))
    }
}

private struct AssistantHUDView: View {
    var controller: VoiceAssistantController
    var model: AppModel?
    var display: AssistantVoiceHUD.DisplayState

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            if display.showsVoiceRow {
                voicePill
            }
            if display.showsActions, let model, let item = model.tabNeedsYou.last {
                NeedsYouActionCard(item: item, model: model) {
                    AssistantVoiceHUD.shared.dismissNeedsYouCard(item.id)
                }
            }
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: display.showsActions)
        .animation(.easeOut(duration: 0.2), value: controller.phase)
    }

    private var voicePill: some View {
        HStack(spacing: 12) {
            Image(systemName: voiceIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            WaveformBars(mode: waveform)
                .frame(width: 34, height: 20)

            StreamingTranscript(text: transcript, placeholder: placeholder)
                .foregroundStyle(micIsOpen ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)

            if controller.phase == .listening {
                Text(listeningCaption)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 92, alignment: .trailing)
            }

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
    }

    private var micIsOpen: Bool {
        controller.phase == .listening || controller.phase == .answering
    }

    /// "Say the phrase" normally; the near-miss correction when the user is
    /// trying and the recognizer keeps almost hearing it.
    private var listeningCaption: String {
        guard controller.usesFinishPhrase else { return "Release to send" }
        if let hint = controller.finishHint { return hint }
        return "Say “\(controller.finishPhraseSpoken)” to send"
    }

    private var voiceIcon: String {
        switch controller.phase {
        case .armed: "mic"
        case .listening, .answering: "mic.fill"
        case .speaking: "speaker.wave.2.fill"
        case .thinking, .idle: "sparkles"
        }
    }

    private var waveform: WaveformBars.Mode {
        switch controller.phase {
        case .listening, .answering: .listening(controller.audioLevel)
        case .speaking: .speaking
        case .armed, .thinking, .idle: .thinking
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
        case .armed, .thinking, .idle:
            ""
        }
    }

    private var placeholder: String {
        switch controller.phase {
        case .armed: "Armed — release ⇧⌥ to speak"
        case .listening: "Listening…"
        case .answering: controller.answerPlaceholder
        case .thinking: "Thinking…"
        case .speaking: "Speaking…"
        case .idle: ""
        }
    }
}

/// The ask, answerable in place: what a blocked tab wants, with the same
/// Allow / Deny / standing options the in-app card offers — so the spoken
/// "quick check" can be settled with one click from any app. Questions get
/// two rows: the full prompt, then the options — a one-line squeeze
/// truncated both into uselessness. ✕ quiets this card only; the ask stays
/// pending in the app and the menu bar.
private struct NeedsYouActionCard: View {
    let item: TabNeedsYou
    let model: AppModel
    let onDismiss: () -> Void

    var body: some View {
        Group {
            switch item {
            case .permission(let payload):
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(payload.request.displayName ?? payload.request.toolName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if let summary = payload.request.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    permissionButtons(payload)
                    dismissButton
                }
                .frame(width: 460 - 16, height: 56)

            case .question(let payload):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(payload.question.prompt)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        dismissButton
                    }
                    HStack(spacing: 8) {
                        questionButtons(payload)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.vertical, 10)
                .frame(width: 460 - 16)

            case .plan(let payload):
                HStack(spacing: 10) {
                    Image(systemName: "checklist")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Plan ready")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(item.headline)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Button("Approve") {
                        model.respondToPlan(
                            chatID: payload.chatID,
                            workspaceID: payload.workspaceID,
                            approve: true
                        )
                    }
                    .buttonStyle(HUDActionButtonStyle(prominent: true))
                    Button("Reject") {
                        model.respondToPlan(
                            chatID: payload.chatID,
                            workspaceID: payload.workspaceID,
                            approve: false
                        )
                    }
                    .buttonStyle(HUDActionButtonStyle())
                    dismissButton
                }
                .frame(width: 460 - 16, height: 56)
            }
        }
        .padding(.horizontal, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Color.primary.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Hide this card — the question stays pending in ORE")
    }

    @ViewBuilder
    private func permissionButtons(_ payload: TabNeedsYou.Permission) -> some View {
        Button("Allow") {
            model.resolvePermission(
                payload.request.id, decision: .allow,
                for: payload.workspaceID, chatID: payload.chatID
            )
        }
        .buttonStyle(HUDActionButtonStyle(prominent: true))

        Button("Deny") {
            model.resolvePermission(
                payload.request.id,
                decision: .deny(reason: "The user denied this from the assistant pill."),
                for: payload.workspaceID, chatID: payload.chatID
            )
        }
        .buttonStyle(HUDActionButtonStyle())

        if !payload.request.suggestions.isEmpty {
            Menu {
                ForEach(
                    Array(payload.request.suggestions.enumerated()), id: \.offset
                ) { _, suggestion in
                    Button(suggestion.title) {
                        model.resolvePermission(
                            payload.request.id,
                            decision: .allowWithSuggestion(suggestion.raw),
                            for: payload.workspaceID, chatID: payload.chatID
                        )
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Standing approvals offered by the agent")
        }
    }

    /// Up to two options inline; the rest — and only-freeform questions —
    /// hand off to the app, where typing is possible.
    @ViewBuilder
    private func questionButtons(_ payload: TabNeedsYou.Question) -> some View {
        ForEach(Array(payload.question.options.prefix(2).enumerated()), id: \.offset) { _, option in
            Button(option.label) {
                model.answerQuestion(
                    payload.question.id, answer: option.label,
                    for: payload.workspaceID, chatID: payload.chatID
                )
            }
            .buttonStyle(HUDActionButtonStyle())
            .frame(maxWidth: 190)
            .help(option.label)
        }
        if payload.question.options.count > 2 {
            Menu {
                ForEach(
                    Array(payload.question.options.dropFirst(2).enumerated()), id: \.offset
                ) { _, option in
                    Button(option.label) {
                        model.answerQuestion(
                            payload.question.id, answer: option.label,
                            for: payload.workspaceID, chatID: payload.chatID
                        )
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// Compact pill buttons sized for the HUD — the in-app button styles are a
/// row taller than this panel wants.
private struct HUDActionButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.08)),
                in: Capsule()
            )
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The transcript, revealed a word at a time and scrolled to keep the newest
/// word in view.
///
/// Replaces a static "…last nine words", which showed a finished sentence with
/// an ellipsis bolted on and looked identical whether the assistant was
/// mid-word or done. The scroll is programmatic only — the panel ignores mouse
/// events while voice-only, so there is nothing for a user to drag.
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
            // No `scrollDisabled`: the voice-only panel already ignores mouse
            // events, so there is no gesture to suppress — and the modifier
            // has a habit of taking `scrollTo` down with it.
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
        TimelineView(.animation(minimumInterval: OreTheme.decorativeAnimationInterval)) { context in
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
