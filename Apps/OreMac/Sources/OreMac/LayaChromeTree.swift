import Foundation

/// One small System One choice. Laya never sees the whole catalog at once.
struct LayaHop: Equatable, Sendable {
    var id: String
    var prompt: String
    var options: [LayaOption]
}

struct LayaOption: Equatable, Sendable {
    var id: String
    var criterion: String
    var children: LayaHop? = nil
    var leaf: LayaLeaf? = nil
}

enum LayaLeaf: Equatable, Sendable {
    case click
    case assistant
    case drop
}

/// Spoken chrome tree used by live voice and the HTML demo.
///
/// First hop peels named files so they never compete with the review file list.
/// Later hops stay small: region, then a handful of controls.
enum LayaChromeTree {
    static let skipIDs: Set<String> = ["none", "drop", "ui", "assistant"]

    static let root = fileGate
    static let commands: Set<ChromeCommand> = collectCommands(in: root)

    private static func opt(
        _ id: String,
        _ criterion: String,
        children: LayaHop? = nil,
        leaf: LayaLeaf? = nil
    ) -> LayaOption {
        LayaOption(id: id, criterion: criterion, children: children, leaf: leaf)
    }

    private static func hop(_ id: String, _ prompt: String, _ options: [LayaOption]) -> LayaHop {
        LayaHop(id: id, prompt: prompt, options: options)
    }

    private static func withNone(_ options: [LayaOption]) -> [LayaOption] {
        options + [opt("none", "not one of these controls — skip", leaf: .drop)]
    }

    static let fileGate = hop(
        "fileGate",
        "Does this clause open a named editor file or the command palette? Settings, terminal tabs, Finder, and coding work are other.",
        [
            opt(
                "named_file",
                "open a document by filename or extension (.md .swift .py .txt .toml .json) or ⌘P / command palette",
                children: paletteControl
            ),
            opt(
                "other",
                "not opening a named document: panes, Settings toggles, terminal, Finder, coding work, filler",
                children: target
            ),
        ]
    )

    static let paletteControl = hop(
        "paletteControl",
        "Open the empty ⌘P picker, or the file named in this clause?",
        withNone([
            opt("openFilePalette", "empty ⌘P / command palette, no filename spoken", leaf: .click),
            opt("openNamedFile", "open the specific file named in this clause", leaf: .click),
        ])
    )

    static let target = hop(
        "target",
        "This clause is one target. Settings toggles (Liquid Glass, Dream Mode), terminal tabs, Finder, mute, run, and effort chips are chrome. Agent work is write/fix/test/change/summarize code — not turning preferences on or off, not mute, not run the project.",
        [
            opt(
                "left_sidebar",
                "LEFT workspace list / left file list / left sidebar only — not the right side",
                children: leftControl
            ),
            opt(
                "right_review",
                "RIGHT sidebar / right side bar / right review pane / inspector: hide, show, All files, Changes, Requests — not the Review toolbar button, not a pull request",
                children: reviewScope
            ),
            opt(
                "terminal",
                "bottom terminal dock: hide/show, new tab, close tab, Run the project script",
                children: terminalScope
            ),
            opt(
                "titlebar",
                "window toolbar: Review button (start an AI review), Commit the files, Create Pull Request, Settings, ⌘P — not the right-pane tabs",
                children: titlebarControl
            ),
            opt(
                "tabs",
                "conversation tabs, new chat, find in this transcript, history clock — not the right All files tab",
                children: chatTabControl
            ),
            opt(
                "composer",
                "ask box: paperclip, model, effort High/Low, Ask/Plan, Fast, mute/unmute, send",
                children: composerControl
            ),
            opt(
                "file_palette",
                "empty ⌘P / command palette with no filename spoken",
                children: paletteControl
            ),
            opt(
                "settings",
                "Settings window or a preference: Liquid Glass, Dream Mode, hold to talk, narration, login, notifications, analytics, default model",
                children: settingsIntent
            ),
            opt(
                "finder",
                "macOS Finder — reveal or open a folder on disk, not an ORE pane",
                children: finderControl
            ),
            opt(
                "assistant",
                "write, fix, test, summarize, refactor, or change source code — not chrome, not mute, not run the project, not Settings, not Liquid Glass, not Finder",
                leaf: .assistant
            ),
            opt("none", "greeting, filler, or already done — drop it", leaf: .drop),
        ]
    )

    static let leftControl = hop(
        "leftControl",
        "Hide, show, or toggle the LEFT sidebar? Collapse/shut/close mean hide. Toggle only if they said toggle or switch.",
        [
            opt("sidebarHide", "hide / shut / close / collapse / tuck the left sidebar", leaf: .click),
            opt("sidebarShow", "show / open / expand / bring back the left sidebar", leaf: .click),
            opt("sidebarToggle", "they said toggle or switch the left sidebar — not collapse", leaf: .click),
        ]
    )

    static let reviewScope = hop(
        "reviewScope",
        "Hide/show the RIGHT pane, or a review tab (All files / Changes / Requests)? Not the toolbar Review button and not Create Pull Request.",
        [
            opt("visibility", "hide, show, shut, close, collapse, or toggle the right sidebar / review pane", children: reviewVisibility),
            opt("reviewAllFiles", "All files tab in the right review pane — not find in transcript", leaf: .click),
            opt("reviewChanges", "Changes tab in the right review pane", leaf: .click),
            opt("reviewRequests", "Requests tab in the right review pane — not create a pull request", leaf: .click),
        ]
    )

    static let reviewVisibility = hop(
        "reviewVisibility",
        "Hide, show, or toggle the right pane? Collapse/shut/close mean hide.",
        [
            opt("reviewHide", "hide / shut / close / collapse / tuck the right sidebar or review pane", leaf: .click),
            opt("reviewShow", "show / open / expand / bring back the right sidebar or review pane", leaf: .click),
            opt("reviewToggle", "they said toggle or switch — not collapse", leaf: .click),
        ]
    )

    static let terminalScope = hop(
        "terminalScope",
        "Whole terminal dock, a terminal tab, or Run? Close/shut the terminal (no word tab) is the dock. Run the project is Run.",
        withNone([
            opt(
                "dock",
                "the whole terminal pane: hide, show, shut, close the terminal, collapse, don't want to see it — they did not say tab",
                children: dockControl
            ),
            opt(
                "tab",
                "they said tab: new tab, plus, another shell, close this tab, next tab, previous tab",
                children: tabControl
            ),
            opt("terminalRun", "Run the project script / run the project — not coding work", leaf: .click),
            opt("revealInFinder", "reveal or open this folder in Finder from the terminal", leaf: .click),
        ])
    )

    static let dockControl = hop(
        "dockControl",
        "Which dock action?",
        withNone([
            opt("terminalCollapse", "hide / shut / don't want to see the dock", leaf: .click),
            opt("terminalOpen", "show the dock", leaf: .click),
            opt("terminalToggle", "toggle the dock", leaf: .click),
        ])
    )

    static let tabControl = hop(
        "tabControl",
        "Which terminal-tab action?",
        withNone([
            opt("terminalTabCreate", "new terminal tab / plus / another shell", leaf: .click),
            opt("terminalTabClose", "close this terminal tab only", leaf: .click),
            opt("terminalTabNext", "next terminal tab", leaf: .click),
            opt("terminalTabPrevious", "previous terminal tab", leaf: .click),
        ])
    )

    static let titlebarControl = hop(
        "titlebarControl",
        "Which titlebar control? Review starts an AI review. Commit commits files. Create Pull Request is git ship, not the Requests tab.",
        withNone([
            opt("workspaceReview", "Review toolbar button — start an AI review of the diff", leaf: .click),
            opt("gitCommit", "Commit toolbar button / commit the files / commit 47 files — not the git verb in coding talk", leaf: .click),
            opt("gitShip", "Create Pull Request / ship / open a PR", leaf: .click),
            opt("sidebarToggle", "titlebar sidebar toggle", leaf: .click),
            opt("openSettings", "open Settings", leaf: .click),
            opt("openFilePalette", "open the ⌘P file palette", leaf: .click),
        ])
    )

    static let chatTabControl = hop(
        "chatTabControl",
        "Which chat-tab control? Find searches this conversation, not the workspace file tree.",
        withNone([
            opt("chatTabCreate", "new conversation tab", leaf: .click),
            opt("chatTabNext", "next chat tab", leaf: .click),
            opt("chatTabPrevious", "previous chat tab", leaf: .click),
            opt("chatHistory", "history clock", leaf: .click),
            opt("findInTranscript", "find in this transcript / search this conversation", leaf: .click),
        ])
    )

    static let composerControl = hop(
        "composerControl",
        "Which composer control? Mute is here, not assistant work. Effort High is a chip, not Default Models.",
        withNone([
            opt("attachFiles", "paperclip / attach files", leaf: .click),
            opt("openModelChooser", "model chip", leaf: .click),
            opt("openEffortChooser", "effort picker", leaf: .click),
            opt("effortLow", "effort Low", leaf: .click),
            opt("effortMedium", "effort Medium", leaf: .click),
            opt("effortHigh", "effort High / set effort to high", leaf: .click),
            opt("effortXhigh", "effort Extra High", leaf: .click),
            opt("permissionAsk", "Ask", leaf: .click),
            opt("permissionAcceptEdits", "Accept Edits", leaf: .click),
            opt("permissionPlan", "Plan", leaf: .click),
            opt("permissionBypass", "Bypass", leaf: .click),
            opt("composerStandard", "Standard", leaf: .click),
            opt("composerFast", "Fast", leaf: .click),
            opt("composerSend", "send arrow", leaf: .click),
            opt("assistantMute", "mute the assistant / silence narration", leaf: .click),
            opt("assistantUnmute", "unmute", leaf: .click),
        ])
    )

    static let finderControl = hop(
        "finderControl",
        "Which Finder action?",
        withNone([
            opt("revealInFinder", "reveal the current file or folder in Finder", leaf: .click),
            opt("openFinder", "open Finder on the workspace", leaf: .click),
        ])
    )

    /// Card groups, not every General row at once.
    static let settingsIntent = hop(
        "settingsIntent",
        "Which Settings action? Turning a preference on or off is a group, not closing the window. A coding leftover like 'add a settings test' is not Settings.",
        [
            opt("openSettings", "open or show the Settings window itself", leaf: .click),
            opt("closeSettings", "dismiss the Settings window itself — not turning a toggle off", leaf: .click),
            opt("appearance", "Appearance: Liquid Glass, native materials, turn glass on or off", children: appearanceControl),
            opt("dreams", "Dream Mode: enable or disable overnight research", children: dreamsControl),
            opt("voice", "Voice: hold to talk, Laya, finish phrase, silence send", children: voiceControl),
            opt("login", "Start ORE at login, ask before quitting", children: loginControl),
            opt("narration", "Spoken narration, greet at launch, fleet announcements", children: narrationControl),
            opt("privacy", "Privacy: share anonymous usage data, analytics", children: privacyControl),
            opt("notifications", "Notifications in ORE, turn complete, sounds", children: notifyControl),
            opt("models", "Default Models: new-chat model — not composer effort", children: modelsControl),
            opt("none", "not Settings — skip", leaf: .drop),
        ]
    )

    static let appearanceControl = hop(
        "appearanceControl",
        "Which Appearance control?",
        withNone([
            opt("settingsLiquidGlass", "Use Liquid Glass — turn the glass material on or off", leaf: .click),
        ])
    )

    static let dreamsControl = hop(
        "dreamsControl",
        "Which Dreams control? Disable/turn off is the same Dream Mode toggle.",
        withNone([
            opt("settingsDreamEnable", "Enable or disable Dream Mode / turn Dream Mode on or off", leaf: .click),
        ])
    )

    static let voiceControl = hop(
        "voiceControl",
        "Which voice control?",
        withNone([
            opt("settingsHoldToTalk", "Hold ⇧⌥ to talk / hold to talk", leaf: .click),
            opt("settingsLaya", "Laya on-device decisions", leaf: .click),
            opt("settingsSilenceSend", "Send after silence", leaf: .click),
        ])
    )

    static let loginControl = hop(
        "loginControl",
        "Which login control?",
        withNone([
            opt("settingsLaunchAtLogin", "Start ORE at login / launch at login", leaf: .click),
            opt("settingsQuitAsk", "Ask before quitting with ⌘Q", leaf: .click),
        ])
    )

    static let narrationControl = hop(
        "narrationControl",
        "Which narration control?",
        withNone([
            opt("settingsNarration", "Allow spoken narration / turn on spoken narration", leaf: .click),
            opt("settingsGreet", "Greet me at launch", leaf: .click),
            opt("settingsFleetNarration", "Announce every workspace's milestones", leaf: .click),
        ])
    )

    static let privacyControl = hop(
        "privacyControl",
        "Which privacy control?",
        withNone([
            opt("settingsAnalytics", "Share anonymous usage data / analytics", leaf: .click),
        ])
    )

    static let notifyControl = hop(
        "notifyControl",
        "Which notification control?",
        withNone([
            opt("settingsNotifyORE", "Notify me in ORE", leaf: .click),
            opt("settingsNotifyTurn", "Notify when a turn completes", leaf: .click),
            opt("settingsSound", "Play completion sounds", leaf: .click),
        ])
    )

    static let modelsControl = hop(
        "modelsControl",
        "Which Default Models control? Not composer effort.",
        withNone([
            opt("settingsDefaultModel", "Default model for new chats", leaf: .click),
            opt("settingsDefaultAgent", "Default agent / harness", leaf: .click),
        ])
    )

    static func command(for optionID: String) -> ChromeCommand? {
        ChromeCommand(rawValue: optionID)
    }

    private static func collectCommands(in hop: LayaHop) -> Set<ChromeCommand> {
        var commands: Set<ChromeCommand> = []
        for option in hop.options {
            if option.leaf == .click, let command = command(for: option.id) {
                commands.insert(command)
            }
            if let children = option.children {
                commands.formUnion(collectCommands(in: children))
            }
        }
        return commands
    }
}
