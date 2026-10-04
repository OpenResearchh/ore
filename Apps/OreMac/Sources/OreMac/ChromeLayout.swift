import Foundation
import Observation
import OreProtocol

/// One-shot composer clicks voice cannot reach through UserDefaults.
/// ChatPane observes `paneRequestID` and performs the matching control.
enum ChromePaneRequest: Equatable, Sendable {
    case find
    case attach
    case modelChooser
    case effortChooser
    case send
    case history
    case setFast(Bool)
    case setEffort(ReasoningEffort)
    case openFilePalette
    case terminalTabCreate
    case terminalTabClose
    case terminalTabNext
    case terminalTabPrevious
    case terminalRun
    case reviewTabAllFiles
    case reviewTabChanges
    case reviewTabRequests

    var isComposerControl: Bool {
        switch self {
        case .find, .attach, .modelChooser, .effortChooser, .send, .history,
             .setFast, .setEffort:
            true
        default:
            false
        }
    }

    var isFilePalette: Bool {
        self == .openFilePalette
    }

    var isReviewTab: Bool {
        switch self {
        case .reviewTabAllFiles, .reviewTabChanges, .reviewTabRequests:
            true
        default:
            false
        }
    }
}

/// Observable chrome flags the window, menus, and voice all mutate.
///
/// `@AppStorage` in the window did not refresh when voice wrote
/// `UserDefaults` directly, so spoken "hide the sidebar" stored the flag
/// and left the split view where it was. One store, observed by SwiftUI,
/// is the layout.
@MainActor
@Observable
final class ChromeLayoutStore {
    static let shared = ChromeLayoutStore()

    var showsSidebar: Bool {
        didSet { UserDefaults.standard.set(showsSidebar, forKey: ChromeLayout.sidebarKey) }
    }
    var showsReview: Bool {
        didSet { UserDefaults.standard.set(showsReview, forKey: ChromeLayout.reviewKey) }
    }
    var showsTerminal: Bool {
        didSet {
            UserDefaults.standard.set(
                showsTerminal ? "terminal" : "none",
                forKey: ChromeLayout.bottomPaneKey
            )
        }
    }
    private(set) var paneRequest: ChromePaneRequest?
    private(set) var paneRequestID = 0
    /// Spoken filename handed to ⌘P when voice opens a named file.
    var pendingFileQuery: String?
    /// Explicit on/off for a Settings toggle the clause named.
    var pendingToggleOn: Bool?

    private init() {
        showsSidebar = ChromeLayout.storedBool(ChromeLayout.sidebarKey, fallback: true)
        showsReview = ChromeLayout.storedBool(ChromeLayout.reviewKey, fallback: true)
        showsTerminal = UserDefaults.standard.string(forKey: ChromeLayout.bottomPaneKey) == "terminal"
    }

    func request(_ request: ChromePaneRequest) {
        paneRequest = request
        paneRequestID += 1
    }

    func consumePaneRequest() -> ChromePaneRequest? {
        let next = paneRequest
        paneRequest = nil
        return next
    }

    /// Chat, review, and the file palette each listen. Only the owner of
    /// this request should take it, or a composer listener swallows a
    /// review-tab click before the right pane sees it.
    func consumePaneRequest(where matches: (ChromePaneRequest) -> Bool) -> ChromePaneRequest? {
        guard let next = paneRequest, matches(next) else { return nil }
        paneRequest = nil
        return next
    }

    /// Tests restore UserDefaults, then this reloads so the singleton matches.
    func reloadFromDefaults() {
        showsSidebar = ChromeLayout.storedBool(ChromeLayout.sidebarKey, fallback: true)
        showsReview = ChromeLayout.storedBool(ChromeLayout.reviewKey, fallback: true)
        showsTerminal = UserDefaults.standard.string(forKey: ChromeLayout.bottomPaneKey) == "terminal"
        paneRequest = nil
    }
}

/// Programmatic writers for the window chrome flags.
///
/// Defaults match `RootView`: sidebar and review start visible, the terminal
/// dock starts collapsed. Writes go through `ChromeLayoutStore` so the
/// window actually moves.
enum ChromeLayout {
    static let sidebarKey = "ore.showsSidebar"
    static let reviewKey = "ore.showsReview"
    static let bottomPaneKey = "ore.bottomPane"

    @MainActor
    static var showsSidebar: Bool {
        get { ChromeLayoutStore.shared.showsSidebar }
        set { ChromeLayoutStore.shared.showsSidebar = newValue }
    }

    @MainActor
    static var showsReview: Bool {
        get { ChromeLayoutStore.shared.showsReview }
        set { ChromeLayoutStore.shared.showsReview = newValue }
    }

    @MainActor
    static var showsTerminal: Bool {
        get { ChromeLayoutStore.shared.showsTerminal }
        set { ChromeLayoutStore.shared.showsTerminal = newValue }
    }

    @MainActor
    static func request(_ request: ChromePaneRequest) {
        ChromeLayoutStore.shared.request(request)
    }

    static func storedBool(_ key: String, fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: key)
    }
}
