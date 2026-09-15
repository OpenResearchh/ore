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
        /// The ask the panel was sized for — and the only one the card may
        /// draw. The view used to re-derive this from the model, which is how
        /// ✕ came to do nothing: dismissing hides an ask from `evaluate()`'s
        /// choice, but the card kept rendering the newest ask regardless, so
        /// with a second one pending behind it the same card stayed put.
        var item: TabNeedsYou?
    }

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private weak var model: AppModel?
    private var controller: VoiceAssistantController?
    private let display = DisplayState()
    /// Cards the user waved away with ✕ — the ask itself stays pending (in
    /// the app's own card and the menu bar); only this surface goes quiet.
    private var dismissedNeedsYouIDs: Set<String> = []

    private nonisolated static let pillSize = NSSize(width: 380, height: 56)
    private nonisolated static let actionWidth: CGFloat = 460

    /// Whether the panel is up (or fading up), and the size it was last given.
    /// `evaluate()` runs for every word of a narration line; when neither has
    /// changed there is nothing to resize, re-shadow or fade in.
    private var isShown = false
    private var shownSize: NSSize?

    /// The panel's size for what it has to show. Questions carry a full
    /// prompt plus an options row and need the taller card; permissions stay
    /// one line.
    nonisolated static func panelSize(voiceActive: Bool, actions: Bool, isQuestion: Bool) -> NSSize {
        let actionHeight: CGFloat = isQuestion ? 128 : 76
        if voiceActive && actions {
            return NSSize(width: actionWidth, height: 64 + actionHeight)
        }
        return actions ? NSSize(width: actionWidth, height: actionHeight) : pillSize
    }

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
            _ = model.narration.currentSpokenText
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
              let item = HUDCardChoice.next(from: model.tabNeedsYou, dismissed: dismissedNeedsYouIDs)
        else { return nil }
        let voiceActive = (controller?.phase ?? .idle) != .idle
        guard voiceActive || !NSApp.isActive else { return nil }
        return item
    }

    private func evaluate() {
        // A dismissal only outlives the ask it was aimed at. Keeping ids for
        // asks that have since been answered would silently pre-dismiss a
        // later card that happened to reuse one — and grow forever.
        if let model {
            dismissedNeedsYouIDs = HUDCardChoice.pruned(
                dismissedNeedsYouIDs, against: model.tabNeedsYou
            )
        }
        let voiceActive = HUDVoiceSource.current(
            isAssistantActive: (controller?.phase ?? .idle) != .idle,
            narrationText: model?.narration.currentSpokenText
        ) != .none
        let actionable = actionableNeedsYou
        let actions = actionable != nil
        display.showsVoiceRow = voiceActive
        display.showsActions = actions
        display.item = actionable
        guard voiceActive || actions else {
            hide()
            return
        }

        hideTask?.cancel()
        hideTask = nil
        let panel = panel ?? makePanel()
        let isQuestion = if case .question = actionable { true } else { false }
        let size = Self.panelSize(voiceActive: voiceActive, actions: actions, isQuestion: isQuestion)
        let sizeChanged = size != shownSize
        if sizeChanged { panel.setContentSize(size) }
        // Buttons need the mouse; the voice-only pill must stay a ghost so
        // it never blocks clicks in the app underneath it.
        if panel.ignoresMouseEvents != !actions { panel.ignoresMouseEvents = !actions }
        position(panel, size: size)
        let wasShown = isShown && panel.isVisible
        isShown = true
        shownSize = size
        if !wasShown { panel.orderFrontRegardless() }
        // The shadow is derived from the rendered shape; recompute it when the
        // pill grows into the card layout (or back) so it hugs the new outline.
        if sizeChanged || !wasShown { panel.invalidateShadow() }
        guard !wasShown else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        // Already fading or gone: another fade would only restart the timer.
        guard let panel, isShown else { return }
        isShown = false
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
        // The HUD is a piece of ORE floating over someone else's app, and ORE
        // is smoked glass now: pinned to dark so it matches the main window
        // instead of whatever the host app's appearance is — which also keeps
        // the accent-tinted Allow readable instead of washing out on a light
        // page (white-on-pale-gray, as it did over Safari).
        panel.appearance = NSAppearance(named: .darkAqua)
        // The window server draws the shadow from the panel's opaque shape —
        // the pill and card get the same native hug the system's HUDs have,
        // which a SwiftUI .shadow can't wrap around an AppKit backdrop.
        panel.hasShadow = true
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
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 84)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
}

/// True glass for a panel floating over *other apps*.
///
/// SwiftUI's `glassEffect` samples in-window content, and this panel is a clear
/// window with nothing behind its views — over Safari it had nothing to
/// refract, which is why the pill read as a flat grey blob rather than glass.
/// The fix is AppKit's sandwich: an `NSVisualEffectView` in behind-window mode
/// pulls the screen underneath into the window, and on macOS 26 an
/// `NSGlassEffectView` in front of it bends that image with real lensing — the
/// same construction as the system's own floating overlays. Before 26 the
/// visual-effect layer alone carries the translucency.
private struct HUDGlassBackdrop: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true

        let visual = NSVisualEffectView()
        // Same smoke as the main window's glass floor, not the popover stock —
        // one material family everywhere ORE shows glass.
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.autoresizingMask = [.width, .height]
        visual.frame = container.bounds
        container.addSubview(visual)

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.autoresizingMask = [.width, .height]
            glass.frame = container.bounds
            container.addSubview(glass)
        }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        container.layer?.cornerRadius = cornerRadius
        if #available(macOS 26.0, *) {
            for case let glass as NSGlassEffectView in container.subviews {
                glass.cornerRadius = cornerRadius
            }
        }
    }
}

/// Which pending ask the floating card shows, and how long a ✕ lasts.
///
/// ✕ is "not now, on this surface" rather than an answer: the ask stays
/// pending in the app and the menu bar, and the HUD moves on to whatever else
/// is waiting. Both halves live here so the panel and the card it draws can
/// only ever agree about which ask is on screen.
enum HUDCardChoice {
    /// The newest ask the user hasn't waved away, or `nil` when they have
    /// dealt with — or dismissed — all of them.
    static func next(from items: [TabNeedsYou], dismissed: Set<String>) -> TabNeedsYou? {
        items.last { !dismissed.contains($0.id) }
    }

    /// A dismissal only outlives the ask it was aimed at. Keeping ids for asks
    /// that have since been answered would grow without bound, and would
    /// silently pre-dismiss any later card that reused one.
    static func pruned(_ dismissed: Set<String>, against items: [TabNeedsYou]) -> Set<String> {
        dismissed.intersection(Set(items.map(\.id)))
    }
}

/// Whose voice the pill is carrying.
///
/// The assistant's own conversation drives the controller's phases, and the
/// pill used to follow those alone. Everything else that speaks — a tab's
/// narration, a fleet announcement — goes through the narration engine without
/// touching them, which is how a tab could talk out loud with no pill and no
/// captions anywhere on screen.
enum HUDVoiceSource: Equatable {
    case none
    case assistant
    case narration

    static func current(isAssistantActive: Bool, narrationText: String?) -> HUDVoiceSource {
        if isAssistantActive { return .assistant }
        return narrationText == nil ? .none : .narration
    }
}

private struct AssistantHUDView: View {
    var controller: VoiceAssistantController
    var model: AppModel?
    var display: AssistantVoiceHUD.DisplayState

    var body: some View {
        // A single GlassEffectContainer so the pill, the answer card, and the
        // glass buttons on it render as one pane of liquid glass — blending and
        // morphing together as rows appear — rather than stacked sheets each
        // blurring the one beneath. This is what turns the HUD from "material
        // panels" into the coherent glass Apple's own overlays use.
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 10) { stack }
            } else {
                stack
            }
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: display.showsActions)
        .animation(.easeOut(duration: 0.2), value: controller.phase)
    }

    private var stack: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            if display.showsVoiceRow {
                voicePill
            }
            // `display.item`, not `model.tabNeedsYou.last`: the panel already
            // chose which ask to show and sized itself for it.
            if display.showsActions, let model, let item = display.item {
                NeedsYouActionCard(item: item, model: model) {
                    AssistantVoiceHUD.shared.dismissNeedsYouCard(item.id)
                }
                .id(item.id)
            }
        }
    }

    private var voicePill: some View {
        HStack(spacing: 12) {
            Image(systemName: voiceIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            WaveformBars(mode: waveform, level: { controller.audioLevel })
                .frame(width: 34, height: 20)

            // A closure, read in the transcript's own body: partial results
            // arrive many times a second, and reading them here re-ran the
            // whole pill — and the action card under it — for each one.
            StreamingTranscript(text: { transcript }, placeholder: placeholder)
                .foregroundStyle(micIsOpen ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)

            // Narration from a tab doesn't always say where it came from —
            // only fleet announcements name their place — so the pill does.
            if isNarrating, let place = narratingPlace {
                Text(place)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 92, alignment: .trailing)
            }

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
        .background { HUDGlassBackdrop(cornerRadius: 22) }
    }

    private var micIsOpen: Bool {
        controller.phase == .listening || controller.phase == .answering
    }

    /// The tab whose narration is playing, by the name its tab shows.
    private var narratingPlace: String? {
        guard let model, let id = model.narration.speakingChatID else { return nil }
        return model.chatIndex.summary(for: id)?.title
    }

    /// A tab or the fleet is speaking while the assistant itself is idle.
    private var isNarrating: Bool {
        HUDVoiceSource.current(
            isAssistantActive: controller.phase != .idle,
            narrationText: model?.narration.currentSpokenText
        ) == .narration
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
        case .thinking: "sparkles"
        case .idle: isNarrating ? "speaker.wave.2.fill" : "sparkles"
        }
    }

    private var waveform: WaveformBars.Mode {
        switch controller.phase {
        case .listening, .answering: .listening
        case .speaking: .speaking
        case .armed, .thinking: .thinking
        case .idle: isNarrating ? .speaking : .thinking
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
        case .armed, .thinking:
            ""
        case .idle:
            // The same word-by-word prefix the assistant's own speech streams:
            // the engine reports it for whichever utterance is playing.
            isNarrating
                ? (model?.narration.spokenPrefix ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
        }
    }

    private var placeholder: String {
        switch controller.phase {
        case .armed: "Armed — release ⇧⌥ to speak"
        case .listening: "Listening…"
        case .answering: controller.answerPlaceholder
        case .thinking: "Thinking…"
        // Shown only while nothing has been voiced yet — the transcript
        // replaces it the moment a word is audible, because progress is
        // counted from samples actually played. That gap is the voice
        // rendering the line: a lead-in pause, the model's first inference and
        // a pre-roll cushion that grows on a loaded machine. Calling it
        // "Speaking…" made a working synthesiser look like a wedged one.
        case .speaking: "Preparing to speak…"
        case .idle: isNarrating ? "Preparing to speak…" : ""
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
                let content = PermissionPresentation(request: payload.request)
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(content.action)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        // The command or path, not the agent's account of it —
                        // the same act the in-app card shows.
                        if let target = content.target {
                            HStack(spacing: 6) {
                                Text(target)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let more = content.hiddenLineSummary {
                                    Text(more)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    permissionButtons(payload, content: content)
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
        .background { HUDGlassBackdrop(cornerRadius: 16) }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(OreTheme.glassControlFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Hide this card — the question stays pending in ORE")
    }

    @ViewBuilder
    private func permissionButtons(
        _ payload: TabNeedsYou.Permission,
        content: PermissionPresentation
    ) -> some View {
        // This card is one 460pt row. When the command does not fit in it,
        // the only honest affordance is one that shows the rest — approving
        // from here would be approving a prefix. Deny stays: refusing
        // something you cannot read is never the unsafe direction.
        if content.isAbbreviated {
            Button("Review…") {
                model.reveal(workspaceID: payload.workspaceID, chatID: payload.chatID)
            }
            .buttonStyle(HUDActionButtonStyle(prominent: true))
            .help("The full command doesn't fit here — open ORE to read it before allowing")
        } else {
            Button("Allow") {
                model.resolvePermission(
                    payload.request.id, decision: .allow,
                    for: payload.workspaceID, chatID: payload.chatID
                )
            }
            .buttonStyle(HUDActionButtonStyle(prominent: true))
        }

        Button("Deny") {
            model.resolvePermission(
                payload.request.id,
                decision: .deny(reason: "The user denied this from the assistant pill."),
                for: payload.workspaceID, chatID: payload.chatID
            )
        }
        .buttonStyle(HUDActionButtonStyle())

        // A standing grant is a broader Allow. If the one-off cannot be
        // approved from here, neither can the rule.
        if !payload.request.suggestions.isEmpty, !content.isAbbreviated {
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
                    .background(OreTheme.glassControlFill, in: Circle())
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
                    .background(OreTheme.glassControlFill, in: Circle())
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

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .frame(height: 26)

        if #available(macOS 26.0, *) {
            // Real glass buttons, resting on the glass card and blending with it
            // through the HUD's GlassEffectContainer: the prominent action takes
            // an accent tint, the rest stay clear so one answer leads.
            label
                .glassEffect(
                    prominent
                        ? .regular.tint(Color.accentColor).interactive()
                        : .regular.interactive(),
                    in: .capsule
                )
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        } else {
            label
                .background(
                    prominent
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(OreTheme.glassControlFill),
                    in: Capsule()
                )
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
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
    var text: @MainActor () -> String
    var placeholder: String

    /// A trailing anchor rather than the last word: scrolling to the word
    /// itself would stop as soon as it fit, leaving the tail hard against the
    /// edge mid-animation.
    private static let tailID = "tail"

    private static func words(in text: String) -> [(id: Int, text: String)] {
        // Any whitespace, not just spaces: a recognizer's partial results and a
        // narration line can both carry a newline, and one long "word" the
        // width of the pill would freeze the scroll.
        text.split(whereSeparator: \.isWhitespace)
            .enumerated().map { ($0.offset, String($0.element)) }
    }

    var body: some View {
        let text = text()
        if #available(macOS 15.0, *) {
            // The scroll view holds the tail against the trailing edge as the
            // line grows, in the same pass as the growth. The fallback below
            // started a fresh 0.25 s scroll animation for every partial result,
            // each one cutting off the last mid-flight.
            strip(text)
                .defaultScrollAnchor(.trailing, for: .sizeChanges)
        } else {
            ScrollViewReader { proxy in
                strip(text)
                    .onChange(of: text) { _, _ in
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(Self.tailID, anchor: .trailing)
                        }
                    }
            }
        }
    }

    private func strip(_ text: String) -> some View {
        let words = Self.words(in: text)
        return ScrollView(.horizontal, showsIndicators: false) {
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
            .background(Capsule().fill(OreTheme.glassControlFill))
            .overlay(Capsule().stroke(OreTheme.glassControlStroke, lineWidth: 1))
            .transition(.opacity)
    }
}

/// Five bars that breathe with the microphone while listening, ride a steady
/// wave while the assistant speaks, and settle into a slow pulse while it
/// works.
/// Shared with the new-workspace composer, which listens the same way the
/// assistant pill does and should look like it.
struct WaveformBars: View {
    /// Listening swings wide and scales with loudness; speaking is a steady
    /// mid-tempo wave (there is no output meter to ride); thinking is one
    /// slow, gentle swell — alive, but clearly not hearing.
    typealias Mode = WaveformBarsView.Style

    var mode: Mode
    /// Microphone loudness, 0…1. A closure read in this body rather than a
    /// value the caller reads: otherwise the whole pill re-renders on every
    /// mic tick just to hand the bars a number.
    var level: (@MainActor () -> Double)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The motion itself runs on the render server (`WaveformBarsView`).
        WaveformBarsLayer(
            style: mode,
            level: mode == .listening ? (level?() ?? 0) : 0,
            isAnimated: !reduceMotion
        )
    }
}
