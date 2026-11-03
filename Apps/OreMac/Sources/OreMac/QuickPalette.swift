import SwiftUI

/// Shared shell for ORE's keyboard overlays (⌘K, ⌘P, and ⌘/).
///
/// These are transient controls floating over the workspace, which is exactly
/// where Liquid Glass belongs. They are hosted in the main window—not sheets—
/// so the native glass can sample and refract the live workspace underneath.
struct QuickPaletteChrome: ViewModifier {
    var cornerRadius: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .oreGlassSurface(
                .rect(cornerRadius: cornerRadius),
                tint: Color.black.opacity(0.10),
                elevation: .floating
            )
    }
}

extension View {
    func quickPaletteChrome(cornerRadius: CGFloat = 24) -> some View {
        modifier(QuickPaletteChrome(cornerRadius: cornerRadius))
    }
}

struct QuickPaletteDivider: View {
    var body: some View {
        LinearGradient(
            colors: [.clear, OreTheme.hairline, OreTheme.hairline, .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
        .padding(.horizontal, OreTheme.Space.sm)
    }
}

private struct QuickPaletteRowSurface: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), isSelected || isHovered {
            content.glassEffect(
                isSelected
                    ? .regular.tint(OreTheme.brand.opacity(0.22)).interactive()
                    : .regular.interactive(),
                in: .rect(cornerRadius: OreTheme.tabRadius)
            )
        } else {
            content
                .background(
                    isSelected ? OreTheme.selectedFill
                        : isHovered ? OreTheme.subduedFill : .clear,
                    in: RoundedRectangle(cornerRadius: OreTheme.tabRadius)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: OreTheme.tabRadius)
                        .stroke(isSelected ? OreTheme.selectedStroke : .clear, lineWidth: 1)
                }
        }
    }
}

struct QuickPaletteKeycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 20)
            // Key legends sit *inside* the glass panel; giving every one its
            // own refracting layer turns a shortcut list into a tray of gems.
            // A quiet specular control fill preserves the depth hierarchy.
            .background(OreTheme.glassControlFill, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(OreTheme.glassControlStroke, lineWidth: 1)
            }
    }
}

/// The row grammar shared by ORE's keyboard-first pickers.
///
/// A palette is scanned, not read: one strong title, one quiet piece of
/// context, and a stable selection treatment. Keeping this out of `List`
/// avoids macOS' table separators and oversized default rows, which fought
/// the app's compact glass chrome and made the selected target ambiguous.
struct QuickPaletteRow<Icon: View>: View {
    let title: String
    var detail: String?
    var trailing: String?
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                icon()
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: OreTheme.Font.body, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: OreTheme.Font.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: OreTheme.Space.sm)

                if let trailing, !trailing.isEmpty {
                    Text(trailing)
                        .font(.system(size: OreTheme.Font.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 42)
            .contentShape(RoundedRectangle(cornerRadius: OreTheme.tabRadius))
            .modifier(QuickPaletteRowSurface(isSelected: isSelected, isHovered: isHovered))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct QuickPaletteSectionHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
            if let count {
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .oreGlassSurface(.capsule, elevation: .inset)
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }
}

struct QuickPaletteFooter: View {
    var summary: String

    var body: some View {
        HStack(spacing: OreTheme.Space.md) {
            Text(summary)
            Spacer()
            hint("↑↓", "Navigate")
            hint("↩", "Open")
            hint("esc", "Close")
        }
        .font(.system(size: OreTheme.Font.caption))
        .foregroundStyle(.secondary)
        .padding(.horizontal, OreTheme.Space.md)
        .frame(height: 34)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            QuickPaletteKeycap(text: key)
            Text(label)
        }
    }
}

struct QuickPaletteEmptyState: View {
    let icon: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: OreTheme.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: OreTheme.Font.title, weight: .medium))
            if let detail {
                Text(detail)
                    .font(.system(size: OreTheme.Font.body))
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(OreTheme.Space.lg)
    }
}
