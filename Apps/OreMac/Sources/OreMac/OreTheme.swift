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
    static let cardRadius: CGFloat = 16
    static let contentMaxWidth: CGFloat = 720

    static let hairline = Color.primary.opacity(0.075)
    static let subduedFill = Color.primary.opacity(0.045)
    static let selectedFill = Color.accentColor.opacity(0.11)

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

    /// Diff / git status tints, kept semantic so they hold up in both appearances.
    static let added = Color.green
    static let removed = Color.red
    static let warning = Color.orange
}

struct OreCard: ViewModifier {
    var padding: CGFloat = OreTheme.Space.md
    var radius: CGFloat = OreTheme.cardRadius

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .stroke(OreTheme.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.045), radius: 4, y: 1)
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
            OreVoiceGlow(cornerRadius: cornerRadius, level: voiceGlow, energy: voiceEnergy)
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
                        minimumInterval: 1.0 / 30.0,
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

/// A selected document tab is navigation chrome, so it can adopt Liquid Glass
/// without turning the document or transcript itself into glass. Unselected
/// tabs stay visually quiet and only pick up a conventional hover fill.
struct OreNavigationSelection: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), isSelected {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: OreTheme.tabRadius))
        } else {
            content.background(
                isSelected ? OreTheme.selectedFill : isHovered ? OreTheme.subduedFill : .clear,
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
        voiceEnergy: Double = 0
    ) -> some View {
        modifier(OreComposerSurface(
            padding: padding,
            isBusy: isBusy,
            reduceMotion: reduceMotion,
            voiceGlow: voiceGlow,
            voiceEnergy: voiceEnergy
        ))
    }

    func oreNavigationSurface() -> some View {
        modifier(OreNavigationSurface())
    }

    func oreNavigationSelection(isSelected: Bool, isHovered: Bool) -> some View {
        modifier(OreNavigationSelection(isSelected: isSelected, isHovered: isHovered))
    }
}
