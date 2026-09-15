import AppKit
import SwiftUI
import WebKit

/// An HTML file rendered as a page, for the review pane's Preview segment.
///
/// Loaded as a file URL with read access to the whole worktree, so relative
/// stylesheets and images resolve exactly as they would opened from disk. The
/// page is someone else's markup — an agent's, or a cloned repository's — so
/// it renders inert: its scripts don't run, and a content rule list blocks
/// every request that would leave the Mac, so a tracking pixel or a remote
/// script can't report that the file was opened. Clicking a link opens the
/// default browser instead of navigating the pane away from the file under
/// review. The web view uses a non-persistent data store, so a page can't
/// leave cookies or storage behind in the app.
struct HTMLFilePreview: NSViewRepresentable {
    let worktreePath: String
    let path: String
    /// Bumped whenever *anything* in the worktree changes, so it is a prompt
    /// to go and look at this file's stamp — not a reason to reload on its own.
    /// Reloading on the generation alone threw the reader back to the top of
    /// the page every time an agent touched an unrelated file.
    var generation: UInt64
    /// Rendered instead when the file is no longer in the worktree, such as
    /// a page deleted on this branch.
    var fallbackHTML: String?

    /// WebKit's content-blocker regex has no alternation, so one rule per
    /// scheme.
    static let remoteBlockRules = """
        [
          {"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^wss?://"}, "action": {"type": "block"}}
        ]
        """

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Page scripts only. The scroll position is still read and restored
        // with evaluateJavaScript, which this doesn't affect.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.setAccessibilityLabel("Preview of \((path as NSString).lastPathComponent)")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        let key = "\(worktreePath)|\(path)|\(fallbackHTML?.hashValue ?? 0)"
        // updateNSView fires for unrelated SwiftUI churn; reloading on each one
        // would reset the page's scroll position while the user reads it. The
        // generation is checked separately so an unchanged generation costs
        // nothing, and a changed one costs one `stat` rather than a reload.
        let isSameFile = coordinator.loadedKey == key
        if isSameFile, coordinator.loadedGeneration == generation { return }
        coordinator.loadedGeneration = generation

        let stamp = WorktreeFileStamp.read(root: worktreePath, relativePath: path)
        // The worktree moved, but not this file.
        if isSameFile, stamp == coordinator.loadedStamp { return }
        coordinator.loadedKey = key
        coordinator.loadedStamp = stamp

        let root = URL(fileURLWithPath: worktreePath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        coordinator.rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"

        let url = try? AppModel.safeFileURL(root: worktreePath, relativePath: path)
        let exists = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let fallbackHTML = fallbackHTML

        Task { @MainActor in
            // Nothing loads until the block list is in place, and if it can't
            // be, nothing loads at all: an empty pane beats an unguarded page.
            guard await coordinator.blockRemoteLoads(in: webView) else {
                webView.loadHTMLString("", baseURL: nil)
                return
            }
            // Same page, genuinely rewritten: put the reader back where they
            // were instead of at the top.
            coordinator.restoreScrollY = isSameFile
                ? (try? await webView.evaluateJavaScript("window.scrollY")) as? Double
                : nil
            if let url, exists {
                webView.loadFileURL(url, allowingReadAccessTo: root)
            } else {
                webView.loadHTMLString(fallbackHTML ?? "", baseURL: nil)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        /// Worktree, path and fallback — everything about *which* page this is.
        var loadedKey: String?
        /// The git generation the stamp below was read at, so an unchanged
        /// generation short-circuits before touching the filesystem.
        var loadedGeneration: UInt64?
        /// Size and modification date of the file as loaded, which is what
        /// actually decides whether a reload is needed.
        var loadedStamp: WorktreeFileStamp?
        /// Scroll offset to put back once the reloaded page has laid out.
        var restoreScrollY: Double?
        var rootPath = ""
        private var blocksRemoteLoads = false

        /// Installs the rule list that keeps the page from fetching anything
        /// off the Mac. False when it can't be compiled.
        func blockRemoteLoads(in webView: WKWebView) async -> Bool {
            if blocksRemoteLoads { return true }
            guard let store = WKContentRuleListStore.default() else { return false }
            let compiled = try? await store.compileContentRuleList(
                forIdentifier: "ore.htmlPreview.blockRemote",
                encodedContentRuleList: HTMLFilePreview.remoteBlockRules
            )
            guard let compiled else { return false }
            if !blocksRemoteLoads {
                webView.configuration.userContentController.add(compiled)
                blocksRemoteLoads = true
            }
            return true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let y = restoreScrollY, y > 0 else { return }
            restoreScrollY = nil
            webView.evaluateJavaScript("window.scrollTo(0, \(y))")
        }

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
            // Nothing off the Mac loads in the pane. A link the user clicked
            // opens in their browser; a frame, a redirect or a meta refresh
            // simply doesn't happen.
            if navigationAction.navigationType == .linkActivated {
                openExternally(url)
            }
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
