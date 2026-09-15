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
    }

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

    /// ORE's own colour: molten copper, the colour of ore being smelted.
    ///
    /// Until this existed the app had no brand colour at all — every tinted
    /// surface used `Color.accentColor`, which means it silently inherited
    /// whatever accent the user happened to pick in System Settings. ORE
    /// looked like a different product on every Mac.
    ///
    /// Copper rather than the usual blue or purple partly to stand out in a
    /// Dock full of cool-toned developer tools, and partly because it is the
    /// one warm hue that does not already mean something here: green is
    /// additions and passing CI, red is deletions and failure. Brand colour
    /// must never be mistaken for state, which is why nothing in `Status`
    /// below uses it.
    ///
    /// Lighter in dark mode: #B45309 is legible on white but goes muddy
    /// against a dark glass panel.
    static let brand = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.961, green: 0.620, blue: 0.043, alpha: 1)  // #F59E0B
            : NSColor(srgbRed: 0.706, green: 0.325, blue: 0.035, alpha: 1)  // #B45309
    })

    static let selectedFill = brand.opacity(0.13)
    /// A selected workspace should remain part of the sidebar, not turn into a
    /// primary-action button. A restrained brand edge carries identity while
    /// the neutral wash does the selection work.
    static let sidebarSelectedFill = Color.primary.opacity(0.09)
    static let selectedStroke = brand.opacity(0.32)

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
        // Full screen has no useful scene behind the window to refract. Hiding
        // the effect reveals the opaque content floor supplied by the caller,
        // avoiding a wallpaper-coloured haze across an entire display.
        isHidden = fullScreen
        material = .hudWindow
    }
}

/// The scroller answer every scroll surface in the app shares: overlay style, a
/// light knob (the window is always dark), autohide.
enum OreScrollerStyle {
    /// Debug A/B switch for the trackpad-to-momentum handoff hitch: responsive
    /// scrolling draws ahead of the main thread, which is usually smoother but
    /// has a known handoff stutter on some content. Off unless set with
    /// `defaults write <bundle id> ore.debug.disableResponsiveScrolling -bool YES`.
    static let responsiveScrollingDisabled =
        UserDefaults.standard.bool(forKey: "ore.debug.disableResponsiveScrolling")

    static func isStyled(_ scroll: NSScrollView) -> Bool {
        scroll.scrollerStyle == .overlay
            && scroll.scrollerKnobStyle == .light
            && scroll.autohidesScrollers
    }

    static func style(_ scroll: NSScrollView) {
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        if scroll.scrollerKnobStyle != .light { scroll.scrollerKnobStyle = .light }
        if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
    }
}

/// An NSScrollView that cannot fall back to the legacy scroller. AppKit re-sets
/// `scrollerStyle` on every scroll view when the system preference changes
/// (plugging in a mouse, "Show scroll bars: Always"); a view styled once in
/// `makeNSView` then grows an opaque track, and on the transcript the narrower
/// clip view invalidates every cached row height. Clamping the setter keeps the
/// overlay answer without anyone having to notice the change.
final class OreOverlayScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        super.scrollerStyle = .overlay
        scrollerKnobStyle = .light
        autohidesScrollers = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        super.scrollerStyle = .overlay
        scrollerKnobStyle = .light
        autohidesScrollers = true
    }

    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }

    override class var isCompatibleWithResponsiveScrolling: Bool {
        !OreScrollerStyle.responsiveScrollingDisabled
    }
}

/// SwiftUI owns the scroll views behind `List` and `ScrollView`, so they can't
/// be `OreOverlayScrollView`s. `.scrollIndicators(.hidden)` was the old escape
/// hatch, but it removed position feedback entirely, and `List` ignores it. This
/// probe sits in the scrolling view's `.background`, finds the backing
/// NSScrollView, and forces the shared overlay answer — again whenever the
/// system scroller preference changes.
struct OreScrollerOverlay: NSViewRepresentable {
    /// The scroll view found by the last search. Weak: when SwiftUI rebuilds
    /// its scroll view the old one goes away and the next update searches again.
    @MainActor
    final class Coordinator {
        weak var scrollView: NSScrollView?
    }

    /// Styles as soon as it lands in a window, so the first frame never shows
    /// the legacy track, and re-styles when the system preference flips.
    final class Probe: NSView {
        var coordinator: Coordinator?
        private var isObserving = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            restyle()
            if !isObserving {
                isObserving = true
                // Selector-based, so the center drops it when the probe goes.
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(preferredScrollerStyleChanged),
                    name: NSScroller.preferredScrollerStyleDidChangeNotification,
                    object: nil
                )
            }
        }

        @objc private func preferredScrollerStyleChanged(_ note: Notification) {
            // AppKit applies the new style to its scroll views after posting;
            // re-assert on the next turn.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.restyle() }
            }
        }

        func restyle() {
            guard let coordinator else { return }
            if OreScrollerOverlay.apply(near: self, coordinator: coordinator) { return }
            // The sibling scroll view may not be installed yet on the pass the
            // probe arrives in.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let coordinator = self.coordinator else { return }
                    _ = OreScrollerOverlay.apply(near: self, coordinator: coordinator)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.coordinator = context.coordinator
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        // The sidebar updates constantly, so the subview search only runs until
        // the scroll view is found; after that an update is three property reads.
        let coordinator = context.coordinator
        if let scroll = coordinator.scrollView, scroll.window != nil,
           OreScrollerStyle.isStyled(scroll) {
            return
        }
        probe.restyle()
    }

    /// Returns whether a scroll view was found and styled.
    @discardableResult
    fileprivate static func apply(near probe: NSView, coordinator: Coordinator) -> Bool {
        if let scroll = coordinator.scrollView, scroll.window != nil {
            OreScrollerStyle.style(scroll)
            return true
        }
        guard let window = probe.window else { return false }
        // The background probe is a sibling of the scroll view, not an
        // ancestor — climb a few levels, searching down at each. Prefer the
        // smallest scroll view whose frame holds the probe's centre, so a probe
        // on a nested ScrollView never styles its outer page instead.
        let centre = probe.convert(NSPoint(x: probe.bounds.midX, y: probe.bounds.midY), to: nil)
        var root: NSView? = probe.superview
        for _ in 0..<5 {
            guard let candidate = root else { break }
            var best: (scroll: NSScrollView, area: CGFloat)?
            collectScrollViews(in: candidate) { scroll in
                guard scroll.window === window else { return }
                let frame = scroll.convert(scroll.bounds, to: nil)
                guard frame.contains(centre) else { return }
                let area = frame.width * frame.height
                if best == nil || area < best!.area { best = (scroll, area) }
            }
            if let best {
                coordinator.scrollView = best.scroll
                OreScrollerStyle.style(best.scroll)
                return true
            }
            root = candidate.superview
        }
        return false
    }

    private static func collectScrollViews(in view: NSView, _ visit: (NSScrollView) -> Void) {
        if let scroll = view as? NSScrollView { visit(scroll) }
        for subview in view.subviews {
            collectScrollViews(in: subview, visit)
        }
    }
}

/// The name the List call sites were written against.
typealias OreListScrollerOverlay = OreScrollerOverlay

extension View {
    /// Overlay, light-knob, autohiding scrollers for a SwiftUI `ScrollView` or
    /// `List` — visible position feedback that never draws the legacy track.
    func oreOverlayScrollers() -> some View {
        scrollIndicators(.automatic)
            .background(OreScrollerOverlay())
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
    /// Set by a scrolling page that asked for flat cards; see `OreGlassDebug`.
    @Environment(\.oreFlatGlass) private var isFlat

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
        if isFlat {
            // A card riding a scroll view resamples the moving page behind it
            // on every frame. A flat paper fill costs one blend instead — the
            // look changes, so it only happens behind a debug switch.
            content
                .background {
                    ZStack {
                        shape.fill(OreTheme.Surface.content.opacity(0.6))
                        if let tint { shape.fill(tint) }
                    }
                }
                .overlay {
                    shape.strokeBorder(OreTheme.hairline, lineWidth: 1)
                        .allowsHitTesting(false)
                }
        } else if #available(macOS 26.0, *) {
            // The system's glass carries its own edge lighting, optical
            // response, *and depth*; hands off entirely. A manual `.shadow`
            // here silhouetted the view's rectangular frame — not the glass
            // shape — and printed square halos at the foot of every pane.
            content.glassEffect(glass, in: shape)
        } else if OreGlassDebug.groupsGlass {
            // The same stand-in, with the shadow cast by the material's shape
            // rather than by the whole composited view: SwiftUI no longer has
            // to render the content offscreen to find its silhouette on every
            // scroll frame.
            content
                .background {
                    shape.fill(.ultraThinMaterial)
                        .shadow(
                            color: .black.opacity(elevation.shadowOpacity),
                            radius: elevation.shadowRadius,
                            y: elevation.shadowY
                        )
                }
                .background { if let tint { shape.fill(tint) } }
                .overlay { specularRim(shape) }
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

/// Unmeasured glass costs over scrolling content, kept as A/B switches until
/// Instruments says which are worth their look. Read once at launch — never
/// from a body — and off unless set with
/// `defaults write <bundle id> ore.debug.<name> -bool YES`.
enum OreGlassDebug {
    /// Group sibling glass into one `GlassEffectContainer` on macOS 26, and on
    /// earlier releases cast the stand-in's shadow from its shape rather than
    /// from the composited view.
    static let groupsGlass = UserDefaults.standard.bool(forKey: "ore.debug.groupedGlass")
    /// Flat paper fills instead of glass for cards inside scroll views.
    static let flatScrollingCards = UserDefaults.standard.bool(forKey: "ore.debug.flatScrollingCards")
}

extension EnvironmentValues {
    /// Whether `OreGlassSurface` draws a flat fill instead of glass here.
    @Entry var oreFlatGlass = false
}

extension View {
    /// Wraps sibling glass surfaces in one `GlassEffectContainer` on macOS 26
    /// when `OreGlassDebug.groupsGlass` is on; otherwise returns the view as is.
    @ViewBuilder
    func oreGlassGroup() -> some View {
        if OreGlassDebug.groupsGlass {
            if #available(macOS 26.0, *) {
                GlassEffectContainer { self }
            } else {
                self
            }
        } else {
            self
        }
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
            // One fixed gradient, drawn and blurred once at full height and
            // strength. Loudness moves only a scale and an opacity, so the
            // animation between mic ticks never re-lays out or re-blurs.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: Color.blue.opacity(0.12), location: 0.45),
                    .init(color: Color.cyan.opacity(0.3), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 88)
            .blur(radius: 10)
            .scaleEffect(x: 1, y: (44 + 44 * energy) / 88, anchor: .bottom)
            .opacity(strength)
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
/// The sweep itself lives in CoreAnimation (`SweepingBorder`), so a busy
/// composer costs the main thread nothing per frame.
struct OreComposerBusyBorder: View {
    let cornerRadius: CGFloat
    let reduceMotion: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        if reduceMotion {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5)
        } else {
            SweepingBorder(cornerRadius: cornerRadius, isPaused: controlActiveState != .key)
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
                    ? .regular.tint(OreTheme.brand.opacity(0.25)).interactive()
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
                    .regular.tint(OreTheme.brand).interactive(),
                    in: .capsule
                )
        } else {
            configuration.label
                .font(.system(size: OreTheme.Font.body, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, OreTheme.Space.md)
                .frame(minHeight: OreTheme.RowHeight.button)
                .background(
                    OreTheme.brand.opacity(isEnabled ? 1 : 0.45),
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

    func oreNavigationSelection(isSelected: Bool, isHovered: Bool) -> some View {
        modifier(OreNavigationSelection(isSelected: isSelected, isHovered: isHovered))
    }
}
