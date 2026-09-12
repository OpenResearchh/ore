import AppKit
import SwiftUI

/// ORE's bundled application icon, used anywhere the product itself is the
/// subject. Reading it from NSApplication keeps development, release, and any
/// future alternate icon in sync with the Dock automatically.
struct OreAppIcon: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("ORE")
    }
}

/// The real mark for something outside ORE.
///
/// A button that hands the worktree to Finder was drawn with `folder` — the
/// generic SF Symbol for *a* folder, which is what every other folder in the
/// app uses. It said "some directory", not "Finder", and sat next to a Cursor
/// button that did show its real logo, so the row read as one branded control
/// and one unfinished one.
///
/// For anything installed locally the honest answer is already on the machine:
/// ask the system for the app's own icon. It is exact, it matches whichever
/// macOS the user is on, and it needs no asset in the repository. Services with
/// no local app — GitHub — fall back to a bundled mark.
struct AppMark: View {
    enum Target {
        case finder
        case cursor
        case terminal
        /// Any app by absolute path, for callers that resolved one themselves.
        case application(URL)
    }

    let target: Target
    var size: CGFloat = 16
    var isMuted = false

    var body: some View {
        Group {
            if let icon = AppIcons.icon(for: target) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                // The app isn't installed, or the system declined to draw it.
                // A recognisable placeholder beats an empty gap.
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size * 0.82, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .saturation(isMuted ? 0 : 1)
        .opacity(isMuted ? 0.72 : 1)
        .accessibilityHidden(true)
    }

    private var fallbackSymbol: String {
        switch target {
        case .finder: "folder"
        case .cursor: "cursorarrow.rays"
        case .terminal: "terminal"
        case .application: "app"
        }
    }
}

@MainActor
enum AppIcons {
    /// `NSWorkspace.icon(forFile:)` hits the disk, and these are drawn in list
    /// rows and toolbars that re-render constantly.
    ///
    /// `NSImage?`, so an app that is *not* there is remembered too. With
    /// successes cached and misses not, the uninstalled case — the common one
    /// — repeated a `stat` on every redraw, which during streaming is many
    /// times a second.
    private static var cache: [String: NSImage?] = [:]

    static func icon(for target: AppMark.Target) -> NSImage? {
        guard let url = url(for: target) else { return nil }
        if let cached = cache[url.path] { return cached }
        guard FileManager.default.fileExists(atPath: url.path) else {
            cache[url.path] = NSImage?.none
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[url.path] = icon
        return icon
    }

    /// Drops what was looked up, so apps installed or removed while ORE was
    /// in the background are noticed on activation.
    static func forget() {
        cache.removeAll()
    }

    private static func url(for target: AppMark.Target) -> URL? {
        switch target {
        case .finder:
            // Finder is not in /Applications and has no discoverable bundle id
            // through `urlForApplication` on every release; the CoreServices
            // path is the stable one.
            URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        case .cursor:
            ExternalTools.cursorApplicationURL
        case .terminal:
            URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        case .application(let url):
            url
        }
    }
}

/// Copies something, and says so.
///
/// The clipboard is invisible: nothing on screen changes when a copy succeeds,
/// so the only feedback available is the button itself. Every inline copy in
/// ORE goes through this, rather than each one deciding separately whether to
/// acknowledge — most of them didn't, which made them indistinguishable from
/// buttons that had failed.
///
/// Copies that live in a *menu* deliberately do not use this: the menu closes
/// on click, so there is nothing left to animate.
struct CopyButton: View {
    let value: String
    /// `nil` draws the icon alone, for toolbars and dense rows.
    var label: String? = nil
    var size: CGFloat = 16
    var help: String = "Copy"

    @State private var copied = false

    /// Long enough to notice, short enough that a second copy isn't blocked
    /// behind a stale tick.
    private static let holdsTickFor = Duration.seconds(1.4)

    var body: some View {
        Button {
            ExternalTools.copyPath(value)
            copied = true
            Task {
                try? await Task.sleep(for: Self.holdsTickFor)
                copied = false
            }
        } label: {
            if let label {
                Label(
                    copied ? "Copied" : label,
                    systemImage: copied ? "checkmark" : "document.on.document"
                )
                .foregroundStyle(copied ? AnyShapeStyle(Color.green) : AnyShapeStyle(.primary))
                .contentTransition(.symbolEffect(.replace))
            } else {
                Image(systemName: copied ? "checkmark" : "document.on.document")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(copied ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                    .frame(width: size, height: size)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .animation(.easeOut(duration: 0.15), value: copied)
        .help(copied ? "Copied" : help)
    }
}

/// The worktree path, in the window's bottom bar.
struct CopyPathButton: View {
    let path: String
    var size: CGFloat = 16

    var body: some View {
        CopyButton(value: path, size: size, help: "Copy the worktree path")
            .buttonStyle(.plain)
    }
}

/// Marks for services that have no app on this Mac.
///
/// GitHub is referenced all over ORE — cloning, issues, pull requests, sign-in,
/// the updater — and was drawn with whichever SF Symbol each screen happened to
/// reach for. One mark, in one place, so those screens stop inventing their own.
struct ServiceMark: View {
    enum Service {
        case gitHub
    }

    let service: Service
    var size: CGFloat = 16
    /// GitHub's mark is a solid silhouette; on a dark background it has to be
    /// drawn light, and it carries no colour of its own either way.
    var tint: Color = .primary

    var body: some View {
        Group {
            switch service {
            case .gitHub: gitHubMark
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(tint)
        .accessibilityHidden(true)
    }

    /// Drawn rather than bundled: the Octocat silhouette is a single path, and
    /// a shape scales cleanly to any size without a second asset to ship,
    /// attribute and keep in step with the harness marks.
    private var gitHubMark: some View {
        GitHubShape()
            .fill(style: FillStyle(eoFill: true))
    }
}

/// GitHub's mark, normalized to a 16×16 box.
private struct GitHubShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 16
        var path = Path()
        // The standard 16×16 Octocat path GitHub publishes for its own UI.
        path.move(to: CGPoint(x: 8, y: 0))
        path.addCurve(
            to: CGPoint(x: 0, y: 8),
            control1: CGPoint(x: 3.58, y: 0),
            control2: CGPoint(x: 0, y: 3.58)
        )
        path.addCurve(
            to: CGPoint(x: 5.47, y: 15.59),
            control1: CGPoint(x: 0, y: 11.54),
            control2: CGPoint(x: 2.29, y: 14.53)
        )
        path.addCurve(
            to: CGPoint(x: 5.94, y: 15.23),
            control1: CGPoint(x: 5.87, y: 15.66),
            control2: CGPoint(x: 5.94, y: 15.42)
        )
        path.addCurve(
            to: CGPoint(x: 5.93, y: 13.9),
            control1: CGPoint(x: 5.94, y: 15.05),
            control2: CGPoint(x: 5.93, y: 14.58)
        )
        path.addCurve(
            to: CGPoint(x: 3.63, y: 13.07),
            control1: CGPoint(x: 3.73, y: 14.33),
            control2: CGPoint(x: 3.27, y: 13.4)
        )
        path.addCurve(
            to: CGPoint(x: 2.69, y: 11.79),
            control1: CGPoint(x: 3.43, y: 12.55),
            control2: CGPoint(x: 3.15, y: 12.42)
        )
        path.addCurve(
            to: CGPoint(x: 3.72, y: 11.94),
            control1: CGPoint(x: 2.22, y: 11.47),
            control2: CGPoint(x: 2.73, y: 11.47)
        )
        path.addCurve(
            to: CGPoint(x: 6.03, y: 12.53),
            control1: CGPoint(x: 4.4, y: 13.09),
            control2: CGPoint(x: 5.47, y: 12.77)
        )
        path.addCurve(
            to: CGPoint(x: 6.66, y: 11.49),
            control1: CGPoint(x: 6.09, y: 12.09),
            control2: CGPoint(x: 6.27, y: 11.79)
        )
        path.addCurve(
            to: CGPoint(x: 3.62, y: 8.13),
            control1: CGPoint(x: 4.46, y: 11.25),
            control2: CGPoint(x: 3.19, y: 10.31)
        )
        path.addCurve(
            to: CGPoint(x: 4.32, y: 6.29),
            control1: CGPoint(x: 3.62, y: 7.38),
            control2: CGPoint(x: 3.86, y: 6.77)
        )
        path.addCurve(
            to: CGPoint(x: 4.38, y: 4.28),
            control1: CGPoint(x: 4.25, y: 6.11),
            control2: CGPoint(x: 4.04, y: 5.4)
        )
        path.addCurve(
            to: CGPoint(x: 6.65, y: 5.35),
            control1: CGPoint(x: 4.38, y: 4.28),
            control2: CGPoint(x: 5.06, y: 4.07)
        )
        path.addCurve(
            to: CGPoint(x: 9.35, y: 5.35),
            control1: CGPoint(x: 7.53, y: 5.11),
            control2: CGPoint(x: 8.47, y: 5.11)
        )
        path.addCurve(
            to: CGPoint(x: 11.62, y: 4.28),
            control1: CGPoint(x: 10.94, y: 4.07),
            control2: CGPoint(x: 11.62, y: 4.28)
        )
        path.addCurve(
            to: CGPoint(x: 11.68, y: 6.29),
            control1: CGPoint(x: 11.96, y: 5.4),
            control2: CGPoint(x: 11.75, y: 6.11)
        )
        path.addCurve(
            to: CGPoint(x: 12.38, y: 8.13),
            control1: CGPoint(x: 12.14, y: 6.77),
            control2: CGPoint(x: 12.38, y: 7.38)
        )
        path.addCurve(
            to: CGPoint(x: 9.33, y: 11.49),
            control1: CGPoint(x: 12.38, y: 10.32),
            control2: CGPoint(x: 11.11, y: 11.24)
        )
        path.addCurve(
            to: CGPoint(x: 10.06, y: 13.24),
            control1: CGPoint(x: 9.79, y: 11.89),
            control2: CGPoint(x: 10.06, y: 12.47)
        )
        path.addCurve(
            to: CGPoint(x: 10.05, y: 15.23),
            control1: CGPoint(x: 10.06, y: 14.35),
            control2: CGPoint(x: 10.05, y: 15.1)
        )
        path.addCurve(
            to: CGPoint(x: 10.53, y: 15.59),
            control1: CGPoint(x: 10.05, y: 15.42),
            control2: CGPoint(x: 10.12, y: 15.66)
        )
        path.addCurve(
            to: CGPoint(x: 16, y: 8),
            control1: CGPoint(x: 13.71, y: 14.53),
            control2: CGPoint(x: 16, y: 11.53)
        )
        path.addCurve(
            to: CGPoint(x: 8, y: 0),
            control1: CGPoint(x: 16, y: 3.58),
            control2: CGPoint(x: 12.42, y: 0)
        )
        path.closeSubpath()
        return path.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}
