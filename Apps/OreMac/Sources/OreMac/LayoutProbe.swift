import SwiftUI

/// Where the chrome that must always be reachable actually landed.
///
/// Layout bugs here don't crash; they push the Settings gear or the composer
/// past the bottom of a smaller Mac's window, and nobody notices on the large
/// display the app was tuned on. `LayoutMatrixTests` renders the real views
/// across Mac screen sizes and checks every probed frame lies inside the
/// window. Off unless a test turns it on, so shipping builds lay out exactly
/// as they would without it.
@MainActor
enum LayoutProbe {
    static var isRecording = false
    private(set) static var frames: [String: CGRect] = [:]

    static func reset() { frames = [:] }

    fileprivate static func record(_ id: String, _ frame: CGRect) {
        frames[id] = frame
    }
}

extension View {
    /// Names this view for `LayoutMatrixTests`. A no-op outside tests.
    func layoutProbe(_ id: String) -> some View {
        modifier(LayoutProbeModifier(id: id))
    }
}

private struct LayoutProbeModifier: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        if LayoutProbe.isRecording {
            content.background(GeometryReader { proxy in
                let frame = proxy.frame(in: .global)
                Color.clear
                    .onAppear { LayoutProbe.record(id, frame) }
                    .onChange(of: frame) { _, new in LayoutProbe.record(id, new) }
            })
        } else {
            content
        }
    }
}

/// The main window's size floor and first-launch size, named so that
/// `LayoutMatrixTests` holds them against every Mac's screen.
enum WindowMetrics {
    /// The content area the window may not shrink below. Sized so the whole
    /// window fits the smallest screen a supported Mac offers — a 13" Air on
    /// "Larger Text" leaves 1024×546 under the menu bar and above the Dock —
    /// because a floor taller than the screen clips the window's bottom edge,
    /// composer and all, with no way to scroll to it.
    static let minimumContent = CGSize(width: 1_000, height: 480)
    /// Fits every Mac at its default display setting, 13" Pro included.
    static let defaultWindow = CGSize(width: 1_200, height: 700)
    /// What the title bar and unified toolbar add above the content.
    static let toolbarHeight: CGFloat = 52

    static var minimumWindow: CGSize {
        CGSize(width: minimumContent.width, height: minimumContent.height + toolbarHeight)
    }
}
