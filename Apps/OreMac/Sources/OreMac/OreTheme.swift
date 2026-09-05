import SwiftUI

/// ORE's visual grammar: quiet system materials, a strict spacing rhythm, and
/// one accent action at a time. All colours remain semantic so the exact same
/// hierarchy survives light mode, dark mode, increased contrast, and tinted
/// accent colours.
enum OreTheme {
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 48
        static let xxl: CGFloat = 96
    }

    /// Decorative motion (busy borders, tab dots, HUD waveform, sidebar ring).
    /// Matches the ~12 Hz mic-level cadence and is enough for a sweep without
    /// competing with typing on the main thread.
    static let decorativeAnimationInterval: TimeInterval = 1.0 / 12.0

    /// The whole app's type scale. Chrome uses `body`; the transcript uses
    /// `prose` so a long reply is readable without looking like UI copy.
    enum Font {
        static let caption: CGFloat = 11
        static let body: CGFloat = 13
        static let prose: CGFloat = 14
        static let title: CGFloat = 15
        static let display: CGFloat = 20
    }

    /// Chrome row heights. The tab strip and toolbars share one compact height
    /// so the content, not the frame around it, is what fills the window.
    enum RowHeight {
        static let bar: CGFloat = 34
        static let row: CGFloat = 30
        static let button: CGFloat = 28
    }

    /// One radius family: chips, controls, tabs, cards. Mixing 6–24 made every
    /// surface feel like it came from a different app.
    static let chipRadius: CGFloat = 6
    static let tabRadius: CGFloat = 8
    static let controlRadius: CGFloat = 10
    /// Selection pills and filter tabs — rounder than a control, squarer than
    /// a card, so a selected sidebar row reads as one solid pill.
    static let pillRadius: CGFloat = 11
    static let cardRadius: CGFloat = 16
    static let contentMaxWidth: CGFloat = 720

    static let hairline = Color.primary.opacity(0.075)
    static let subduedFill = Color.primary.opacity(0.045)
    /// A hair brighter than `subduedFill`: for small chips and controls that sit
    /// *on* a glass panel (HUD buttons, the ✕ dismiss, the esc hint), where the
    /// quieter wash would dissolve into the glass behind it.
    static let glassControlFill = Color.primary.opacity(0.08)
    static let glassControlStroke = Color.primary.opacity(0.10)
    static let selectedFill = Color.accentColor.opacity(0.11)
    /// The loud sibling of `selectedFill`: a solid accent pill with white
    /// content, for the one selection that should anchor the eye (the current
    /// sidebar row). Everything else keeps the quiet wash.
    static let selectedProminentFill = Color.accentColor

    /// Panel backgrounds. The transcript is the reading surface; everything
    /// around it recedes so the eye lands on the agent's reply, not on chrome.
    enum Surface {
        static var content: Color { Color(nsColor: .textBackgroundColor) }
        static var chrome: Color { Color(nsColor: .windowBackgroundColor) }
        static var well: Color { Color(nsColor: .controlBackgroundColor) }
    }

    enum Status {
        static let running = Color.blue
        static let needsYou = Color.orange
        static let failed = Color.red
        /// Unread is "look here", not "success" — green is reserved for diffs.
        static let unread = Color.accentColor
        static let interrupted = Color.yellow
    }

    /// Presence is "is anyone home", distinct from `Status.running`'s "work is
    /// happening" blue: green means an agent is live on this surface, gray
    /// means it is sitting idle. Used by the header presence line and the
    /// sidebar's connected pill.
    enum Presence {
        static let active = Color.green
        static let idle = Color.secondary
    }

    /// Diff / git status tints, kept semantic so they hold up in both appearances.
    static let added = Color.green
    static let removed = Color.red
    static let warning = Color.orange
}

/// The window's glass floor: the desktop wallpaper, blurred behind the window,
/// exactly the optical base the system gives a `NavigationSplitView` sidebar.
///
/// This is what was missing from the first Liquid Glass pass. Glass only reads
/// as glass when there is light behind it — the HUD and the menus refract, but
/// they were floating over an opaque white grid of panes, so the whole window
/// stayed matte. Laying this under the detail column turns the window into one
/// continuous glass environment (the way Tahoe's Music and Notes windows pick
/// up the wallpaper), and every material above it — `.bar` strips, `.thin`
/// inspector, the composer's `glassEffect` — starts compositing over real
/// light instead of flat paint.
///
/// AppKit, not SwiftUI: in-window materials can only sample in-window content,
/// and "the desktop behind the window" is strictly `NSVisualEffectView` in
/// behind-window blending.
struct OreWindowGlassBase: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = OreAdaptiveGlassView()
        view.blendingMode = .behindWindow
        // Dims with the window so an inactive ORE recedes like every other
        // wallpaper-tinted window on the desktop.
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The glass floor's AppKit view, choosing its material by how the window is
/// standing.
///
/// Windowed, it is `.hudWindow` — the most transparent material AppKit ships;
/// `.underWindowBackground` is the near-opaque sidebar stock, and the reference
/// design is a smoked-glass panel you can genuinely see the desktop through.
/// In full screen that bargain inverts: the window *is* the whole screen, the
/// only thing behind it is the space wallpaper, and deep transparency stops
/// being depth and starts being noise under the prose. So full screen eases
/// back to `.underWindowBackground` — still glass, but calm enough to read on.
///
/// Selector-based notification observers, deliberately: block observers on an
/// `@MainActor` NSView are a strict-concurrency argument nobody needs to have.
final class OreAdaptiveGlassView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        apply(fullScreen: window.styleMask.contains(.fullScreen))
        NotificationCenter.default.addObserver(
            self, selector: #selector(didEnterFullScreen),
            name: NSWindow.didEnterFullScreenNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(didExitFullScreen),
            name: NSWindow.didExitFullScreenNotification, object: window
        )
    }

    @objc private func didEnterFullScreen(_ note: Notification) {
        apply(fullScreen: true)
    }

    @objc private func didExitFullScreen(_ note: Notification) {
        apply(fullScreen: false)
    }

    private func apply(fullScreen: Bool) {
        material = fullScreen ? .underWindowBackground : .hudWindow
    }
}

/// macOS `List` ignores `.scrollIndicators(.hidden)`: it is NSTableView-backed,
/// and the modifier only reaches SwiftUI's own scrollers. With "Show scroll
/// bars: Always" set system-wide, every List kept drawing the opaque legacy
/// track — the one rectangle the glass window can't absorb. This probe sits in
/// a List's `.background`, finds the backing scroll view, and forces the same
/// overlay/light-knob answer every AppKit scroll surface in the app uses.
struct OreListScrollerOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        DispatchQueue.main.async { Self.apply(near: probe) }
        return probe
    }

    func updateNSView(_ probe: NSView, context: Context) {
        // Re-applied on SwiftUI updates: AppKit resets scroller style when the
        // system preference changes, and the List can rebuild its scroll view.
        DispatchQueue.main.async { Self.apply(near: probe) }
    }

    private static func apply(near probe: NSView) {
        // The background probe is a sibling of the list's scroll view, not an
        // ancestor — climb a few levels, searching down at each.
        var root: NSView? = probe.superview
        for _ in 0..<4 {
            guard let candidate = root else { return }
            if let scroll = firstTableScrollView(in: candidate) {
                scroll.scrollerStyle = .overlay
                scroll.scrollerKnobStyle = .light
                scroll.autohidesScrollers = true
                return
            }
            root = candidate.superview
        }
    }

    private static func firstTableScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView is NSTableView {
            return scroll
        }
        for subview in view.subviews {
            if let found = firstTableScrollView(in: subview) { return found }
        }
        return nil
    }
}

/// The shape a glass surface is cut to. Only the two the app actually uses, so
/// the specular rim can stay a concrete `strokeBorder` instead of going fully
/// generic over `InsettableShape` at every call site.
enum OreGlassShape: Equatable {
    case capsule
    case rect(cornerRadius: CGFloat)
}

/// How high a glass surface floats, and therefore how hard it shadows. A HUD
/// panel hovering over a *different* app has to sit convincingly above it, so it
/// casts more than a menu anchored to a control a few points below the composer.
/// Shared so every floating surface reads at a consistent, physically-plausible
/// depth rather than each site inventing its own shadow.
enum OreGlassElevation: Equatable {
    /// Anchored just above a control — slash / mention menus, the effort popover.
    case popover
    /// A detached panel over arbitrary content — the assistant HUD.
    case floating
    /// Resting on the app's own content — decision cards, settings tiles.
    case inset

    var shadowRadius: CGFloat {
        switch self {
        case .popover: 16
        case .floating: 20
        case .inset: 4
        }
    }

    var shadowY: CGFloat {
        switch self {
        case .popover: 6
        case .floating: 10
        case .inset: 1
        }
    }

    var shadowOpacity: Double {
        switch self {
        case .popover: 0.14
        case .floating: 0.22
        case .inset: 0.05
        }
    }
}

/// The one Liquid Glass grammar every floating and layered surface shares: the
/// assistant HUD, its answer cards, the composer's slash / mention menus, and
/// the in-app cards. Apple reserves Liquid Glass for this functional layer that
/// sits *over* content, which is exactly why the reading surfaces (transcript,
/// wells) stay deliberately opaque and are not routed through here.
///
/// macOS 26 supplies the true optics — blur, refraction, light picked up from
/// what's behind — through `glassEffect`, and they are left strictly alone: a
/// hand-painted highlight on real glass reads as a sticker. Earlier releases
/// get a hand-built stand-in — a blurred material under a specular rim — so the
/// same look reaches back to macOS 14. Only the elevation shadow is shared.
struct OreGlassSurface: ViewModifier {
    var shape: OreGlassShape
    var tint: Color? = nil
    var elevation: OreGlassElevation = .floating
    /// Let the glass respond to the pointer. For panels this stays off; buttons
    /// opt in so the press has the wet, springy give of a real glass control.
    var interactive: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        switch shape {
        case .capsule:
            decorate(content, shape: Capsule(style: .continuous))
        case .rect(let radius):
            decorate(content, shape: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    @ViewBuilder
    private func decorate<S: InsettableShape>(_ content: Content, shape: S) -> some View {
        if #available(macOS 26.0, *) {
            // The system's glass carries its own edge lighting, optical
            // response, *and depth*; hands off entirely. A manual `.shadow`
            // here silhouetted the view's rectangular frame — not the glass
            // shape — and printed square halos at the foot of every pane.
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background { if let tint { shape.fill(tint) } }
                .overlay { specularRim(shape) }
                // The hand-built stand-in has no depth of its own, so the
                // elevation shadow is still ours to draw.
                .shadow(
                    color: .black.opacity(elevation.shadowOpacity),
                    radius: elevation.shadowRadius,
                    y: elevation.shadowY
                )
        }
    }

    /// A thin edge that catches light on the top rim, fades to nothing, and
    /// settles into a hairline of definition along the bottom — the read that
    /// says "glass" more than the blur does.
    private func specularRim<S: InsettableShape>(_ shape: S) -> some View {
        shape.strokeBorder(
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(colorScheme == .dark ? 0.40 : 0.60), location: 0),
                    .init(color: .white.opacity(0.04), location: 0.35),
                    .init(color: OreTheme.hairline, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: 1
        )
        .allowsHitTesting(false)
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

/// An in-app card / tile. It sits on the app's own content, so it floats low
/// (`.inset`) and never carries a tint — but it is still cut from the same glass
/// as the HUD so a settings tile and a floating pill read as one material.
struct OreCard: ViewModifier {
    var padding: CGFloat = OreTheme.Space.md
    var radius: CGFloat = OreTheme.cardRadius

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .modifier(OreGlassSurface(shape: .rect(cornerRadius: radius), elevation: .inset))
    }
}

/// A single high-value functional surface. On macOS 26 the system provides
/// the optical response and accessibility adaptations; older releases retain
/// the existing material treatment.
struct OreComposerSurface: ViewModifier {
    var padding: CGFloat = 10
    /// While an agent runs, the surface draws an animated accent border so the
    /// composer itself is the progress indicator.
    var isBusy: Bool = false
    var reduceMotion: Bool = false
    /// While dictation is live, blue "clouds" drift along the bottom and sides
    /// of the surface. Takes precedence over the busy border so two animated
    /// edges never stack.
    var voiceGlow: OreVoiceGlowLevel = .off
    /// Smoothed microphone loudness, 0…1 — the clouds billow with the voice.
    var voiceEnergy: Double = 0
    /// When set, energy is read here so the parent composer body does not
    /// subscribe to ~12 Hz `audioLevel` ticks.
    var voiceInput: VoiceInputController? = nil

    private static let glassRadius: CGFloat = OreTheme.cardRadius

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .padding(padding)
                .background { glow(cornerRadius: Self.glassRadius) }
                .glassEffect(.regular, in: .rect(cornerRadius: Self.glassRadius))
                .overlay { busyBorder(cornerRadius: Self.glassRadius) }
                .overlay { glowStroke(cornerRadius: Self.glassRadius) }
        } else {
            content
                .modifier(OreCard(padding: padding, radius: OreTheme.cardRadius))
                .background { glow(cornerRadius: OreTheme.cardRadius) }
                .overlay { busyBorder(cornerRadius: OreTheme.cardRadius) }
                .overlay { glowStroke(cornerRadius: OreTheme.cardRadius) }
        }
    }

    @ViewBuilder
    private func busyBorder(cornerRadius: CGFloat) -> some View {
        if isBusy, voiceGlow == .off {
            OreComposerBusyBorder(cornerRadius: cornerRadius, reduceMotion: reduceMotion)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func glow(cornerRadius: CGFloat) -> some View {
        if voiceGlow != .off, !reduceMotion {
            ComposerVoiceGlowHost(
                cornerRadius: cornerRadius,
                level: voiceGlow,
                energy: voiceEnergy,
                voice: voiceInput
            )
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func glowStroke(cornerRadius: CGFloat) -> some View {
        if voiceGlow != .off {
            OreVoiceGlowStroke(
                cornerRadius: cornerRadius,
                level: voiceGlow,
                reduceMotion: reduceMotion
            )
            .allowsHitTesting(false)
        }
    }
}

/// How strongly the composer's voice glow renders: `subdued` while the mic is
/// still spinning up (permission, model download), `full` once listening.
enum OreVoiceGlowLevel {
    case off, subdued, full

    var intensity: Double {
        switch self {
        case .off: 0
        case .subdued: 0.5
        case .full: 1
        }
    }
}

/// A quiet blue glow pooled along the composer's bottom edge while dictation
/// is live, breathing with the speaker's voice: louder speech lifts and
/// brightens it, silence lets it settle. Deliberately simple — one gradient,
/// no texture — so it reads as state, not weather.
struct OreVoiceGlow: View {
    let cornerRadius: CGFloat
    let level: OreVoiceGlowLevel
    /// Smoothed microphone loudness, 0…1.
    var energy: Double = 0

    var body: some View {
        let strength = level.intensity * (0.55 + 0.45 * energy)
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: Color.blue.opacity(0.12 * strength), location: 0.45),
                    .init(color: Color.cyan.opacity(0.3 * strength), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 44 + 44 * energy)
            .blur(radius: 10)
        }
        // Strictly inside the composer: clip to the exact glass shape, inset a
        // hair so no fringe peeks past the border stroke.
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).inset(by: 0.5))
        .animation(.easeOut(duration: 0.25), value: energy)
        .animation(.easeOut(duration: 0.25), value: level.intensity)
        .allowsHitTesting(false)
    }
}

/// Reads `audioLevel` in its own body so the composer dock does not rebuild
/// on every mic tick.
private struct ComposerVoiceGlowHost: View {
    let cornerRadius: CGFloat
    let level: OreVoiceGlowLevel
    var energy: Double
    var voice: VoiceInputController?

    var body: some View {
        OreVoiceGlow(
            cornerRadius: cornerRadius,
            level: level,
            energy: voice?.audioLevel ?? energy
        )
    }
}

/// The crisp edge of the voice glow: a blue-to-cyan outline that fades toward
/// the top of the composer. Under Reduce Motion this is the entire effect.
struct OreVoiceGlowStroke: View {
    let cornerRadius: CGFloat
    let level: OreVoiceGlowLevel
    let reduceMotion: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceMotion {
            shape.strokeBorder(Color.blue.opacity(0.6 * level.intensity), lineWidth: 1.5)
        } else {
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.cyan, Color.blue],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.5
                )
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.25), location: 0.0),
                            .init(color: .white, location: 1.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(0.85 * level.intensity)
        }
    }
}

/// A flowing accent highlight that sweeps around the composer's edge while the
/// agent works. With reduced motion it settles into a steady accent outline.
struct OreComposerBusyBorder: View {
    let cornerRadius: CGFloat
    let reduceMotion: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if reduceMotion {
                shape.strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5)
            } else {
                TimelineView(
                    .animation(
                        minimumInterval: OreTheme.decorativeAnimationInterval,
                        paused: controlActiveState != .key
                    )
                ) { context in
                    let period = 2.4
                    let angle = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: period) / period * 360
                    shape
                        .strokeBorder(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    Color.accentColor.opacity(0.0),
                                    Color.accentColor.opacity(0.15),
                                    Color.accentColor.opacity(0.85),
                                    Color.accentColor.opacity(0.15),
                                    Color.accentColor.opacity(0.0),
                                ]),
                                center: .center,
                                angle: .degrees(angle)
                            ),
                            lineWidth: 1.75
                        )
                }
            }
        }
    }
}

/// Navigation is the other functional layer Apple calls out for Liquid Glass.
/// Keeping it to the outer rail avoids stacking glass on every row and badge.
struct OreNavigationSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: OreTheme.cardRadius))
        } else {
            content.background(.ultraThinMaterial)
        }
    }
}

/// Tabs are navigation chrome floating over the transcript, so every pill is
/// cut from Liquid Glass — not only the selected one. Transparent unselected
/// tabs read fine on a fixed bar, but this strip floats: rows scroll directly
/// beneath it, and label-through-label was the result. Each pill carrying its
/// own glass is also how the system's floating tab groups stay legible.
struct OreNavigationSelection: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // A whisper of accent in the selected pill's glass — the "you are
            // here" marker; strong enough to pick out at a glance, weak enough
            // that the one loud accent in the pane stays the primary action.
            content.glassEffect(
                isSelected
                    ? .regular.tint(Color.accentColor.opacity(0.25)).interactive()
                    : .regular.interactive(),
                in: .rect(cornerRadius: OreTheme.tabRadius)
            )
        } else {
            content.background(
                isSelected ? OreTheme.selectedFill
                    : isHovered ? OreTheme.subduedFill : Color.black.opacity(0.30),
                in: RoundedRectangle(cornerRadius: OreTheme.tabRadius)
            )
        }
    }
}

struct OrePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            configuration.label
                .font(.system(size: OreTheme.Font.body, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, OreTheme.Space.md)
                .frame(minHeight: OreTheme.RowHeight.button)
                .opacity(isEnabled ? 1 : 0.55)
                .glassEffect(
                    .regular.tint(Color.accentColor).interactive(),
                    in: .capsule
                )
        } else {
            configuration.label
                .font(.system(size: OreTheme.Font.body, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, OreTheme.Space.md)
                .frame(minHeight: OreTheme.RowHeight.button)
                .background(
                    Color.accentColor.opacity(isEnabled ? 1 : 0.45),
                    in: Capsule()
                )
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .brightness(configuration.isPressed ? -0.06 : 0)
                .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
        }
    }
}

struct OreSecondaryButtonStyle: ButtonStyle {
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            configuration.label
                .font(.system(size: OreTheme.Font.body, weight: .medium))
                .padding(.horizontal, 12)
                .frame(minHeight: OreTheme.RowHeight.button)
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            configuration.label
                .font(.system(size: OreTheme.Font.body, weight: .medium))
                .padding(.horizontal, 12)
                .frame(minHeight: OreTheme.RowHeight.button)
                .background(OreTheme.subduedFill, in: Capsule())
                .overlay { Capsule().stroke(OreTheme.hairline) }
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
        }
    }
}

/// The next git step is a verb, not a generic prominent button. Tone follows
/// the action: commit is warm, shipping is accent, merge is purple, danger
/// (failed CI, conflicts) is red, and a finished merge is green.
enum OreGitActionTone {
    case commit, publish, pullRequest, merge, danger, success, quiet

    var color: Color {
        switch self {
        case .commit: .orange
        case .publish: .blue
        case .pullRequest: .accentColor
        case .merge: .purple
        case .danger: .red
        case .success: .green
        case .quiet: .secondary
        }
    }
}

struct OreGitActionButtonStyle: ButtonStyle {
    var tone: OreGitActionTone = .pullRequest
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            configuration.label
                .font(.system(size: OreTheme.Font.body, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(minHeight: OreTheme.RowHeight.button)
                .opacity(isEnabled ? 1 : 0.55)
                .glassEffect(.regular.tint(tone.color).interactive(), in: .capsule)
        } else {
            configuration.label
                .font(.system(size: OreTheme.Font.body, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(minHeight: OreTheme.RowHeight.button)
                .background(tone.color.opacity(isEnabled ? 1 : 0.45), in: Capsule())
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .brightness(configuration.isPressed ? -0.06 : 0)
                .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
        }
    }
}

/// Small icon/chip controls still need tactile feedback even when their visual
/// surface is intentionally quiet. This is shared by composer controls and
/// custom tabs so pressing never feels like clicking static text.
struct OrePressableButtonStyle: ButtonStyle {
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A stable, local avatar so a commit list reads as people rather than a dump
/// of names. Colour is hashed from the name — no network, no GitHub fetch.
struct OreMonogram: View {
    let name: String
    var size: CGFloat = 22

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(tone)
            .frame(width: size, height: size)
            .background(tone.opacity(0.18), in: Circle())
            .accessibilityLabel(name)
    }

    private var initials: String {
        let parts = name.split(separator: " ").compactMap(\.first).prefix(2)
        if !parts.isEmpty { return String(parts) }
        return String(name.prefix(1)).uppercased()
    }

    private var tone: Color {
        // Skip green/red — those belong to diffs.
        let palette: [Color] = [.blue, .purple, .orange, .pink, .cyan, .indigo, .teal, .brown]
        let value = name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palette[abs(value) % palette.count]
    }
}

extension View {
    func oreCard(
        padding: CGFloat = OreTheme.Space.md,
        radius: CGFloat = OreTheme.cardRadius
    ) -> some View {
        modifier(OreCard(padding: padding, radius: radius))
    }

    func oreComposerSurface(
        padding: CGFloat = 10,
        isBusy: Bool = false,
        reduceMotion: Bool = false,
        voiceGlow: OreVoiceGlowLevel = .off,
        voiceEnergy: Double = 0,
        voiceInput: VoiceInputController? = nil
    ) -> some View {
        modifier(OreComposerSurface(
            padding: padding,
            isBusy: isBusy,
            reduceMotion: reduceMotion,
            voiceGlow: voiceGlow,
            voiceEnergy: voiceEnergy,
            voiceInput: voiceInput
        ))
    }

    /// A floating / layered Liquid Glass surface — the HUD pill, its answer
    /// cards, the composer's slash and mention menus. See `OreGlassSurface`.
    func oreGlassSurface(
        _ shape: OreGlassShape,
        tint: Color? = nil,
        elevation: OreGlassElevation = .floating,
        interactive: Bool = false
    ) -> some View {
        modifier(OreGlassSurface(
            shape: shape,
            tint: tint,
            elevation: elevation,
            interactive: interactive
        ))
    }

    func oreNavigationSurface() -> some View {
        modifier(OreNavigationSurface())
    }

    func oreNavigationSelection(isSelected: Bool, isHovered: Bool) -> some View {
        modifier(OreNavigationSelection(isSelected: isSelected, isHovered: isHovered))
    }
}
