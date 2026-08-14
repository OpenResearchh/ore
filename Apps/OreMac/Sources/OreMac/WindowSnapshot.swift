import AppKit

/// Renders the app's own window to a PNG.
///
/// Screen capture needs the Screen Recording permission and captures whatever
/// happens to be on screen; this asks the window for its own contents instead,
/// which needs no permission and can't catch another app's pixels. That makes
/// it usable in CI and in a headless development loop, where the point is to
/// look at what the app actually drew rather than to trust that it compiled.
///
/// Set `ORE_SNAPSHOT=/path/to.png` to have the app snapshot itself once the UI
/// has settled and then exit.
enum WindowSnapshot {
    static var requestedPath: String? {
        ProcessInfo.processInfo.environment["ORE_SNAPSHOT"]
    }

    /// How long to let the app settle before snapshotting. Harness probes and
    /// the first git status read are async, so a snapshot taken immediately
    /// shows a correct but empty app.
    static var delay: Duration {
        let seconds = ProcessInfo.processInfo.environment["ORE_SNAPSHOT_DELAY"]
            .flatMap(Double.init) ?? 3.5
        return .milliseconds(Int(seconds * 1000))
    }

    @MainActor
    static func capture(to path: String) -> Bool {
        guard let window = (NSApp.keyWindow?.isVisible == true ? NSApp.keyWindow : nil)
            ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
        else { return false }

        guard let data = compositedImage(of: window) ?? cachedImage(of: window) else {
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            FileHandle.standardError.write(
                Data("could not write the snapshot: \(error)\n".utf8)
            )
            return false
        }
    }

    /// The window as the compositor actually drew it.
    ///
    /// This is the only way to see materials — the sidebar, sheets and toolbar
    /// are all `NSVisualEffectView`-backed, and vibrancy is composited by the
    /// window server rather than drawn by the view. Redrawing the hierarchy
    /// into a bitmap therefore shows those surfaces as blank, which reads as a
    /// broken app when the app is fine.
    @MainActor
    private static func compositedImage(of window: NSWindow) -> Data? {
        let windowID = CGWindowID(window.windowNumber)
        guard windowID > 0 else { return nil }

        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ), image.width > 1, image.height > 1 else { return nil }

        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(using: .png, properties: [:])
    }

    /// Fallback: ask the view hierarchy to redraw itself. Works without any
    /// window-server access, at the cost of losing material backgrounds.
    @MainActor
    private static func cachedImage(of window: NSWindow) -> Data? {
        guard let contentView = window.contentView else { return nil }
        let bounds = contentView.bounds
        guard bounds.width > 1, bounds.height > 1,
              let representation = contentView.bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }

        contentView.cacheDisplay(in: bounds, to: representation)
        return representation.representation(using: .png, properties: [:])
    }

    /// Snapshots after a delay and exits, so a script can launch the app, get a
    /// PNG, and move on.
    @MainActor
    static func scheduleIfRequested() {
        guard let path = requestedPath else { return }
        Task {
            try? await Task.sleep(for: delay)
            let succeeded = capture(to: path)
            let message = succeeded ? "snapshot: \(path)\n" : "snapshot failed\n"
            FileHandle.standardError.write(Data(message.utf8))
            NSApp.terminate(nil)
        }
    }
}
