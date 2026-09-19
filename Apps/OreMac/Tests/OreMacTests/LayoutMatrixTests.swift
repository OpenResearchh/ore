import AppKit
import SwiftUI
import Testing
import OreCore
import OrePersistence
import OreProtocol
@testable import OreMac

/// Every Mac ORE can run on, as the screen area a window actually gets.
///
/// Sizes are the points macOS offers in Displays settings — the default and
/// the "Larger Text" end, which is where layouts break — less the menu bar
/// (taller under a notch) and a Dock at the bottom.
struct MacDisplay: CustomTestStringConvertible, Sendable {
    let name: String
    let points: CGSize
    let hasNotch: Bool
    /// "Larger Text" and the like: a choice the user made, not what the Mac
    /// ships with. The first-launch size only has to fit the default.
    var isScaledUp = false

    static let dockHeight: CGFloat = 70

    var menuBarHeight: CGFloat { hasNotch ? 37 : 24 }

    /// The largest window frame the screen leaves room for.
    var visibleFrame: CGSize {
        CGSize(width: points.width, height: points.height - menuBarHeight - Self.dockHeight)
    }

    var testDescription: String {
        "\(name) (\(Int(points.width))×\(Int(points.height)))"
    }

    static let all: [MacDisplay] = [
        MacDisplay(name: "MacBook Air 13\" M1", points: CGSize(width: 1440, height: 900), hasNotch: false),
        MacDisplay(name: "MacBook Air 13\" M1, Larger Text", points: CGSize(width: 1024, height: 640), hasNotch: false, isScaledUp: true),
        MacDisplay(name: "MacBook Air 13\"", points: CGSize(width: 1470, height: 956), hasNotch: true),
        MacDisplay(name: "MacBook Air 13\", Larger Text", points: CGSize(width: 1024, height: 665), hasNotch: true, isScaledUp: true),
        MacDisplay(name: "MacBook Air 15\"", points: CGSize(width: 1710, height: 1112), hasNotch: true),
        MacDisplay(name: "MacBook Pro 13\"", points: CGSize(width: 1280, height: 800), hasNotch: false),
        MacDisplay(name: "MacBook Pro 14\"", points: CGSize(width: 1512, height: 982), hasNotch: true),
        MacDisplay(name: "MacBook Pro 14\", Larger Text", points: CGSize(width: 1147, height: 745), hasNotch: true, isScaledUp: true),
        MacDisplay(name: "MacBook Pro 16\"", points: CGSize(width: 1728, height: 1117), hasNotch: true),
        MacDisplay(name: "1080p display", points: CGSize(width: 1920, height: 1080), hasNotch: false),
        MacDisplay(name: "iMac 24\"", points: CGSize(width: 2240, height: 1260), hasNotch: false),
        MacDisplay(name: "Studio Display", points: CGSize(width: 2560, height: 1440), hasNotch: false),
    ]

    /// The window sizes worth rendering on this screen: at its floor
    /// (clamped to the screen, as macOS does), and filling the screen.
    var windowSizes: [CGSize] {
        let floor = CGSize(
            width: min(WindowMetrics.minimumWindow.width, visibleFrame.width),
            height: min(WindowMetrics.minimumWindow.height, visibleFrame.height)
        )
        return floor == visibleFrame ? [floor] : [floor, visibleFrame]
    }
}

/// What the window is showing, from a first launch to a busy fleet.
enum LayoutScene: String, CaseIterable, Sendable {
    case noProjects
    case oneWorkspace
    case manyWorkspaces
    case reviewHidden

    /// The chrome that must be fully on screen in this scene.
    var requiredProbes: Set<String> {
        switch self {
        case .noProjects: []
        case .oneWorkspace, .manyWorkspaces:
            ["composer", "status-bar", "sidebar-controls", "review-tabs"]
        case .reviewHidden:
            ["composer", "status-bar", "sidebar-controls"]
        }
    }

    var showsReview: Bool { self != .reviewHidden }

    var workspaces: [WorkspaceSummary] {
        func workspace(_ index: Int, _ name: String, repo: String) -> WorkspaceSummary {
            WorkspaceSummary(
                id: WorkspaceID(rawValue: "w\(index)"),
                name: name,
                repositoryPath: "/tmp/ore-layout/repositories/\(repo)",
                worktreePath: "/tmp/ore-layout/workspaces/\(repo)/\(index)",
                branch: "ore/\(index)",
                baseBranch: "main",
                harness: index.isMultiple(of: 2) ? .claudeCode : .codex,
                status: index == 1 ? .runningTool : .idle,
                hasUnread: index == 2,
                isPinned: index == 3,
                lastActivity: Date(timeIntervalSince1970: 1_800_000_000 - Double(index) * 600)
            )
        }
        switch self {
        case .noProjects:
            return []
        case .oneWorkspace, .reviewHidden:
            return [workspace(0, "Curie", repo: "lace")]
        case .manyWorkspaces:
            let repos = ["lace", "a-repository-with-a-very-long-descriptive-name", "ore"]
            return (0..<14).map { index in
                workspace(
                    index,
                    index == 0
                        ? "Investigate why the flaky integration suite times out on CI runners"
                        : "Workspace \(index)",
                    repo: repos[index % repos.count]
                )
            }
        }
    }
}

/// Renders the real window content at every Mac's sizes and checks that the
/// chrome a user needs — the composer, the status bar, the sidebar's Settings
/// bar, the review tabs — lands fully inside the window.
///
/// This is the bug class that shipped before: the sidebar notice needed six
/// lines where one had been reserved, and on a 13" screen the Settings gear
/// was laid out below the window. Nothing crashed and every other test passed.
///
/// Set `ORE_LAYOUT_SNAPSHOTS=/some/dir` to also write each render as a PNG,
/// for looking at rather than only asserting on. An offscreen render cannot
/// composite materials, so the sidebar shows blank and text that sits on
/// glass can come out dark; positions and sizes are exact.
@MainActor
@Suite(.serialized)
struct LayoutMatrixTests {
    @Test(arguments: MacDisplay.all)
    func theWindowFloorFitsOnScreen(_ display: MacDisplay) {
        let floor = WindowMetrics.minimumWindow
        #expect(
            floor.width <= display.visibleFrame.width
                && floor.height <= display.visibleFrame.height,
            "a \(Int(floor.width))×\(Int(floor.height)) minimum window cannot fit the \(Int(display.visibleFrame.width))×\(Int(display.visibleFrame.height)) the screen leaves"
        )
    }

    @Test(arguments: MacDisplay.all)
    func theFirstLaunchWindowFitsOnScreen(_ display: MacDisplay) {
        guard !display.isScaledUp else { return }
        let size = WindowMetrics.defaultWindow
        #expect(
            size.width <= display.visibleFrame.width
                && size.height <= display.visibleFrame.height,
            "the first-launch window runs under the Dock or off the screen"
        )
    }

    @Test(arguments: LayoutScene.allCases)
    func theChromeStaysInsideTheWindowOnEveryMac(_ scene: LayoutScene) throws {
        let sizes = Set(MacDisplay.all.flatMap(\.windowSizes).map(SizeKey.init))
            .sorted { ($0.width, $0.height) < ($1.width, $1.height) }
        for size in sizes {
            let render = try LayoutRender(scene: scene, size: size.cgSize)
            let label = "\(scene.rawValue) at \(Int(size.width))×\(Int(size.height))"

            #expect(
                render.minimumSize.width <= size.width + 0.5
                    && render.minimumSize.height <= size.height + 0.5,
                "\(label): content needs at least \(render.minimumSize)"
            )
            for probe in scene.requiredProbes.sorted() {
                guard let frame = render.probes[probe] else {
                    Issue.record("\(label): \(probe) was not laid out at all")
                    continue
                }
                #expect(
                    frame.width >= 1 && frame.height >= 1,
                    "\(label): \(probe) was crushed to \(frame.size)"
                )
                #expect(
                    render.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                    "\(label): \(probe) at \(frame) spills out of the \(render.bounds.size) window"
                )
            }
        }
    }
}

/// Hashable stand-in for `CGSize`, for de-duplicating sizes across displays.
private struct SizeKey: Hashable {
    let width: CGFloat
    let height: CGFloat
    init(_ size: CGSize) { width = size.width; height = size.height }
    var cgSize: CGSize { CGSize(width: width, height: height) }
}

/// One render of `RootView` in an offscreen window.
@MainActor
private struct LayoutRender {
    let bounds: CGRect
    let minimumSize: CGSize
    let probes: [String: CGRect]

    init(scene: LayoutScene, size: CGSize) throws {
        let defaults = UserDefaults.standard
        let previousReview = defaults.object(forKey: "ore.showsReview")
        defaults.set(scene.showsReview, forKey: "ore.showsReview")
        defer { defaults.set(previousReview, forKey: "ore.showsReview") }

        let model = AppModel(client: InProcessCoreClient(store: try OreStore()))
        model.apply(.snapshot(CoreSnapshot(workspaces: scene.workspaces, harnesses: [])))
        model.selectedWorkspaceID = scene.workspaces.first?.id

        LayoutProbe.isRecording = true
        LayoutProbe.reset()
        defer { LayoutProbe.isRecording = false }

        let root = RootView(
            isShowingNewWorkspace: .constant(false),
            isShowingPalette: .constant(false),
            isShowingFilePalette: .constant(false),
            launchFailure: nil,
            isShowingShortcuts: .constant(false)
        )
        .environment(model)
        .environment(Updater())
        .environment(GitHubUpdater())
        // Exactly as the window scene wraps it, so the floor measured here
        // is the one the real window enforces.
        .frame(
            minWidth: WindowMetrics.minimumContent.width,
            minHeight: WindowMetrics.minimumContent.height
        )

        let host = NSHostingView(rootView: root)
        host.sizingOptions = [.minSize]
        let window = UnconstrainedWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Text colours resolve against the app's appearance as well as the
        // window's; setting only the window left labels drawn for light mode.
        let dark = NSAppearance(named: .darkAqua)
        let previousAppearance = NSApp.appearance
        NSApp.appearance = dark
        defer { NSApp.appearance = previousAppearance }
        window.appearance = dark
        host.appearance = dark
        window.contentView = host
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        // Appearance callbacks and the geometry readers run on the next turns.
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()

        bounds = host.bounds
        minimumSize = window.contentMinSize
        probes = LayoutProbe.frames

        if let directory = ProcessInfo.processInfo.environment["ORE_LAYOUT_SNAPSHOTS"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent("\(scene.rawValue)-\(Int(size.width))x\(Int(size.height)).png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.contentView = nil
    }
}

/// A window that keeps the size it is given. A real one is clamped to the
/// screen it is on, which here is whatever Mac runs the tests.
private final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
