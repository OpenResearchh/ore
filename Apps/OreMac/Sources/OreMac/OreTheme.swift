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

    /// The whole app's type scale. Thirteen ad-hoc font sizes had crept in;
    /// everything now maps to one of these four so hierarchy reads the same
    /// everywhere. `caption` is metadata and badges, `body` is the default row
    /// and control text, `title` is prose and section titles, `display` is the
    /// one headline an empty state gets.
    enum Font {
        static let caption: CGFloat = 11
        static let body: CGFloat = 13
        static let title: CGFloat = 15
        static let display: CGFloat = 20
    }

    /// Chrome row heights. The tab strip and toolbars share one compact height
    /// so the content, not the frame around it, is what fills the window.
    enum RowHeight {
        static let bar: CGFloat = 34
        static let row: CGFloat = 30
    }

    static let cardRadius: CGFloat = 18
    static let controlRadius: CGFloat = 12
    static let contentMaxWidth: CGFloat = 920

    static let hairline = Color.primary.opacity(0.075)
    static let subduedFill = Color.primary.opacity(0.045)
    static let selectedFill = Color.accentColor.opacity(0.11)

    enum Status {
        static let running = Color.blue
        static let needsYou = Color.orange
        static let failed = Color.red
        static let unread = Color.green
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

    private static let glassRadius: CGFloat = 20

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .padding(padding)
                .glassEffect(.regular, in: .rect(cornerRadius: Self.glassRadius))
                .overlay { busyBorder(cornerRadius: Self.glassRadius) }
        } else {
            content
                .modifier(OreCard(padding: padding, radius: OreTheme.cardRadius))
                .overlay { busyBorder(cornerRadius: OreTheme.cardRadius) }
        }
    }

    @ViewBuilder
    private func busyBorder(cornerRadius: CGFloat) -> some View {
        if isBusy {
            OreComposerBusyBorder(cornerRadius: cornerRadius, reduceMotion: reduceMotion)
                .allowsHitTesting(false)
        }
    }
}

/// A flowing accent highlight that sweeps around the composer's edge while the
/// agent works. With reduced motion it settles into a steady accent outline.
struct OreComposerBusyBorder: View {
    let cornerRadius: CGFloat
    let reduceMotion: Bool
    @State private var angle: Double = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if reduceMotion {
                shape.strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5)
            } else {
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
                    .onAppear {
                        withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                            angle = 360
                        }
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
            content.glassEffect(.regular, in: .rect(cornerRadius: 24))
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
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
        } else {
            content.background(
                isSelected ? OreTheme.selectedFill : isHovered ? OreTheme.subduedFill : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
    }
}

struct OrePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, OreTheme.Space.md)
                .frame(minHeight: 44)
                .opacity(isEnabled ? 1 : 0.55)
                .glassEffect(
                    .regular.tint(Color.accentColor).interactive(),
                    in: .capsule
                )
        } else {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, OreTheme.Space.md)
                .frame(minHeight: 44)
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
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(OreTheme.subduedFill, in: Capsule())
                .overlay { Capsule().stroke(OreTheme.hairline) }
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
        }
    }
}

/// Small icon/chip controls still need tactile feedback even when their visual
/// surface is intentionally quiet. This is shared by composer controls and
/// custom tabs so pressing never feels like clicking static text.
struct OrePressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
        reduceMotion: Bool = false
    ) -> some View {
        modifier(OreComposerSurface(padding: padding, isBusy: isBusy, reduceMotion: reduceMotion))
    }

    func oreNavigationSurface() -> some View {
        modifier(OreNavigationSurface())
    }

    func oreNavigationSelection(isSelected: Bool, isHovered: Bool) -> some View {
        modifier(OreNavigationSelection(isSelected: isSelected, isHovered: isHovered))
    }
}
