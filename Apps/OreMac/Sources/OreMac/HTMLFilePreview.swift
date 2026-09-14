import AppKit
import SwiftUI
import WebKit

/// An HTML file rendered as a page, for the review pane's Preview segment.
///
/// Loaded as a file URL with read access to the whole worktree, so relative
/// stylesheets, scripts and images resolve exactly as they would opened from
/// disk. Clicking a link that leaves the worktree opens the default browser
/// instead of navigating the pane away from the file under review. The web
/// view uses a non-persistent data store, so a page an agent wrote can't leave
/// cookies or storage behind in the app.
struct HTMLFilePreview: NSViewRepresentable {
    let worktreePath: String
    let path: String
    /// Bumped whenever the worktree changes, so an agent rewriting the file —
    /// or the user saving it from the Source segment — reloads the page.
    var generation: UInt64
    /// Rendered instead when the file is no longer in the worktree, such as
    /// a page deleted on this branch.
    var fallbackHTML: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.setAccessibilityLabel("Preview of \((path as NSString).lastPathComponent)")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let key = "\(worktreePath)|\(path)|\(generation)|\(fallbackHTML?.hashValue ?? 0)"
        // updateNSView fires for unrelated SwiftUI churn; reloading on each
        // one would reset the page's scroll position while the user reads it.
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key

        let root = URL(fileURLWithPath: worktreePath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        context.coordinator.rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"

        if let url = try? AppModel.safeFileURL(root: worktreePath, relativePath: path),
           FileManager.default.fileExists(atPath: url.path) {
            webView.loadFileURL(url, allowingReadAccessTo: root)
        } else {
            webView.loadHTMLString(fallbackHTML ?? "", baseURL: nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedKey: String?
        var rootPath = ""

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if url.isFileURL {
                let target = url.standardizedFileURL.resolvingSymlinksInPath().path
                return target.hasPrefix(rootPath) ? .allow : .cancel
            }
            if ["about", "data", "blob"].contains(url.scheme ?? "") { return .allow }
            // An embedded frame (a map, a video) is part of the page; a click
            // on a link is the user leaving it.
            if navigationAction.navigationType != .linkActivated,
               navigationAction.targetFrame?.isMainFrame == false {
                return .allow
            }
            openExternally(url)
            return .cancel
        }

        /// `target="_blank"` asks for a new window, which a pane has no
        /// business opening.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url { openExternally(url) }
            return nil
        }

        private func openExternally(_ url: URL) {
            guard ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
