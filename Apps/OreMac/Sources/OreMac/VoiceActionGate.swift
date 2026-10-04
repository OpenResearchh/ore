import Foundation

/// A window-chrome command peeled out of dictation. Named actions only —
/// never a click at a coordinate. Each case maps onto an `AppModel` or
/// `ChromeLayout` method the menus and shortcuts already call.
enum ChromeCommand: String, Sendable, Equatable, Hashable {
    case sidebarShow
    case sidebarHide
    case sidebarToggle
    case reviewShow
    case reviewHide
    case reviewToggle
    case terminalOpen
    case terminalCollapse
    case terminalToggle
    case chatTabCreate
    case chatTabNext
    case chatTabPrevious
    case chatHistory
    case assistantMute
    case assistantUnmute
    case assistantMuteToggle
    case workspaceReview
    case gitCommit
    case gitShip
    case findInTranscript
    case attachFiles
    case openModelChooser
    case openEffortChooser
    case composerSend
    case permissionAsk
    case permissionAcceptEdits
    case permissionPlan
    case permissionBypass
    case composerStandard
    case composerFast
    case effortLow
    case effortMedium
    case effortHigh
    case effortXhigh
    case openSettings
    case closeSettings
    case openFilePalette
    case openNamedFile
    case revealInFinder
    case openFinder
    case terminalTabCreate
    case terminalTabClose
    case terminalTabNext
    case terminalTabPrevious
    case terminalRun
    case reviewAllFiles
    case reviewChanges
    case reviewRequests
    case settingsLiquidGlass
    case settingsDreamEnable
    case settingsHoldToTalk
    case settingsLaya
    case settingsSilenceSend
    case settingsLaunchAtLogin
    case settingsQuitAsk
    case settingsNarration
    case settingsGreet
    case settingsFleetNarration
    case settingsAnalytics
    case settingsNotifyORE
    case settingsNotifyTurn
    case settingsSound
    case settingsDefaultModel
    case settingsDefaultAgent

    var label: String {
        switch self {
        case .sidebarShow: "Show Sidebar"
        case .sidebarHide: "Hide Sidebar"
        case .sidebarToggle: "Sidebar"
        case .reviewShow: "Show Review Pane"
        case .reviewHide: "Hide Review Pane"
        case .reviewToggle: "Review Pane"
        case .terminalOpen: "Terminal"
        case .terminalCollapse: "Hide Terminal"
        case .terminalToggle: "Terminal"
        case .chatTabCreate: "New Tab"
        case .chatTabNext: "Next Tab"
        case .chatTabPrevious: "Previous Tab"
        case .chatHistory: "History"
        case .assistantMute: "Mute"
        case .assistantUnmute: "Unmute"
        case .assistantMuteToggle: "Mute"
        case .workspaceReview: "Review"
        case .gitCommit: "Commit"
        case .gitShip: "Create Pull Request"
        case .findInTranscript: "Find"
        case .attachFiles: "Attach Files"
        case .openModelChooser: "Model"
        case .openEffortChooser: "Effort"
        case .composerSend: "Send"
        case .permissionAsk: "Ask"
        case .permissionAcceptEdits: "Accept Edits"
        case .permissionPlan: "Plan"
        case .permissionBypass: "Bypass"
        case .composerStandard: "Standard"
        case .composerFast: "Fast"
        case .effortLow: "Low"
        case .effortMedium: "Medium"
        case .effortHigh: "High"
        case .effortXhigh: "Extra High"
        case .openSettings: "Settings"
        case .closeSettings: "Close Settings"
        case .openFilePalette: "Open File"
        case .openNamedFile: "Open File"
        case .revealInFinder: "Reveal in Finder"
        case .openFinder: "Finder"
        case .terminalTabCreate: "New Terminal"
        case .terminalTabClose: "Close Terminal Tab"
        case .terminalTabNext: "Next Terminal Tab"
        case .terminalTabPrevious: "Previous Terminal Tab"
        case .terminalRun: "Run"
        case .reviewAllFiles: "All Files"
        case .reviewChanges: "Changes"
        case .reviewRequests: "Requests"
        case .settingsLiquidGlass: "Liquid Glass"
        case .settingsDreamEnable: "Dream Mode"
        case .settingsHoldToTalk: "Hold to Talk"
        case .settingsLaya: "Laya"
        case .settingsSilenceSend: "Send After Silence"
        case .settingsLaunchAtLogin: "Open at Login"
        case .settingsQuitAsk: "Ask Before Quitting"
        case .settingsNarration: "Spoken Narration"
        case .settingsGreet: "Greet at Launch"
        case .settingsFleetNarration: "Fleet Narration"
        case .settingsAnalytics: "Analytics"
        case .settingsNotifyORE: "Notify in ORE"
        case .settingsNotifyTurn: "Notify on Turn"
        case .settingsSound: "Completion Sounds"
        case .settingsDefaultModel: "Default Model"
        case .settingsDefaultAgent: "Default Agent"
        }
    }
}

/// Chrome the dictation consumed, plus the leftover words that should still
/// go to the composer-settings extractor or the agent.
struct VoiceChromeIntents: Equatable, Sendable {
    var actions: [ChromeCommand]
    var rewritten: String
    var changes: [VoiceChange]
    /// True only when Laya actually answered. A timeout must not look like
    /// "none" or we never retry the same words.
    var fromModel: Bool = false
    /// Spoken filename for ⌘P / openNamedFile.
    var spokenFile: String? = nil
    /// On/off for a Settings toggle, when the clause said turn on/off.
    var toggleOn: Bool? = nil

    static let empty = VoiceChromeIntents(actions: [], rewritten: "", changes: [])
}

/// Sliding-window gate that strips UI-chrome commands out of speech.
///
/// This is the live brain for sidebar / review / terminal / tabs / mute. It is
/// not a Llama and not a second assistant: alias match against a closed
/// catalog, same shape as `VoiceIntentExtractor`, fast enough to run on every
/// confirmed partial. Generative models stay where they already are — the
/// commit-time `VoiceIntentRefiner` — and coding work stays with the agent.
///
/// Volatile hypotheses never reach `consume`. The caller passes confirmed
/// text (or the whole utterance at send). A match only fires when the alias
/// is complete *and* at a clause boundary, so "open the" cannot click and
/// "open the terminal pane file" is left for the file tagger.
enum VoiceActionGate {
    /// Catalog matching. Off while Laya is the live chrome brain so every
    /// new word is a System One question instead of an instant alias click.
    static let aliasesEnabled = false

    static func consume(
        _ spoken: String,
        usingAliases: Bool = aliasesEnabled
    ) -> VoiceChromeIntents {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return VoiceChromeIntents(actions: [], rewritten: "", changes: [])
        }
        guard usingAliases else {
            return VoiceChromeIntents(actions: [], rewritten: trimmed, changes: [])
        }

        let tokens = VoiceLexer.tokenize(trimmed)
        guard !tokens.isEmpty else {
            return VoiceChromeIntents(actions: [], rewritten: trimmed, changes: [])
        }

        var claimed: [Range<Int>] = []
        var hits: [(command: ChromeCommand, span: Range<Int>, label: String)] = []

        for start in 0..<tokens.count {
            if claimed.contains(where: { $0.contains(start) }) { continue }
            guard let hit = bestMatch(at: start, in: tokens) else { continue }
            guard !claimed.contains(where: { $0.overlaps(hit.span) }) else { continue }
            claimed.append(hit.span)
            hits.append(hit)
        }

        guard !hits.isEmpty else {
            return VoiceChromeIntents(actions: [], rewritten: trimmed, changes: [])
        }

        hits.sort { $0.span.lowerBound < $1.span.lowerBound }
        let rewritten = emptiness(
            VoiceIntentExtractor.strippingClauses(
                hits.map(\.span),
                from: trimmed,
                tokens: tokens
            )
        )
        let changes = hits.map { hit in
            VoiceChange(
                kind: .chrome,
                label: hit.label,
                consumed: text(of: hit.span, in: trimmed, tokens: tokens),
                detail: hit.command.rawValue
            )
        }
        return VoiceChromeIntents(
            actions: hits.map(\.command),
            rewritten: rewritten,
            changes: changes
        )
    }

    // MARK: - Matching

    private struct Entry {
        var command: ChromeCommand
        var alias: [String]
        var label: String
    }

    /// Longest aliases first so "new chat tab" wins over "new tab" when both
    /// would start at the same token.
    private static let catalog: [Entry] = entries.sorted {
        $0.alias.count > $1.alias.count
    }

    private static func bestMatch(
        at start: Int,
        in tokens: [VoiceToken]
    ) -> (command: ChromeCommand, span: Range<Int>, label: String)? {
        for entry in catalog {
            guard let span = match(entry.alias, at: start, in: tokens) else { continue }
            guard hasBoundary(after: span, in: tokens) else { continue }
            return (entry.command, span, entry.label)
        }
        return nil
    }

    /// Alias words in order, articles allowed between them ("hide the sidebar").
    private static func match(
        _ alias: [String],
        at start: Int,
        in tokens: [VoiceToken]
    ) -> Range<Int>? {
        guard start < tokens.count, VoiceLexer.tokensMatch(tokens[start].text, alias[0])
        else { return nil }
        var aliasIndex = 1
        var position = start + 1
        var fillers = 0
        while aliasIndex < alias.count {
            guard position < tokens.count else { return nil }
            if VoiceLexer.tokensMatch(tokens[position].text, alias[aliasIndex]) {
                aliasIndex += 1
                position += 1
                fillers = 0
                continue
            }
            guard fillers < 2, articles.contains(tokens[position].text) else { return nil }
            fillers += 1
            position += 1
        }
        return start..<position
    }

    /// Complete phrases only: end of the utterance, a conjunction, or another
    /// chrome verb so "close it close the terminal shut the terminal" still
    /// peels. "open the terminal pane file" stays intact because "pane" is
    /// not a boundary.
    private static func hasBoundary(after span: Range<Int>, in tokens: [VoiceToken]) -> Bool {
        guard span.upperBound < tokens.count else { return true }
        return boundaries.contains(tokens[span.upperBound].text)
    }

    private static func text(
        of span: Range<Int>,
        in spoken: String,
        tokens: [VoiceToken]
    ) -> String {
        let lower = tokens[span.lowerBound].range.lowerBound
        let upper = tokens[span.upperBound - 1].range.upperBound
        return String(spoken[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "please collapse the sidebar" and "could you hide the sidebar"
    /// must not start an assistant turn on the leftover wrapper.
    private static func emptiness(_ rewritten: String) -> String {
        var tokens = VoiceLexer.tokenize(rewritten)
        while let first = tokens.first, wrappers.contains(first.text) {
            tokens.removeFirst()
        }
        while let last = tokens.last, leftover.contains(last.text) {
            tokens.removeLast()
        }
        guard !tokens.isEmpty else { return "" }
        if tokens.allSatisfy({ leftover.contains($0.text) }) { return "" }
        let lower = tokens[0].range.lowerBound
        let upper = tokens[tokens.count - 1].range.upperBound
        return VoiceIntentExtractor.tidy(String(rewritten[lower..<upper]))
    }

    private static let articles: Set<String> = [
        "the", "a", "an", "my", "our", "that", "this", "those", "these",
    ]
    /// End of a chrome clause: conjunctions, or another chrome verb so
    /// stacked "close the terminal shut the terminal" still peels.
    private static let boundaries: Set<String> = [
        "and", "then", "also", "plus", "please", "now",
        "close", "shut", "hide", "collapse", "open", "show", "dismiss",
        "tuck", "bring",
    ]
    /// Leading/trailing glue around a chrome clause. Not a coding request.
    private static let wrappers: Set<String> = [
        "please", "just", "now", "okay", "ok", "hey", "hi", "hello", "um", "uh",
        "like", "well", "so", "can", "could", "would", "will", "should",
        "may", "might", "wanna", "want", "need", "go", "ahead", "try",
        "to", "you", "i", "we", "me", "us", "let", "lets", "and", "then",
        "also", "plus", "for", "thanks", "thank", "quickly",
    ]
    private static let leftover: Set<String> = wrappers.union([
        "yeah", "yup", "yes", "yep", "right", "there", "well",
    ])

    // MARK: - Catalog

    private static let entries: [Entry] = {
        var result: [Entry] = []
        func add(_ command: ChromeCommand, _ alias: [String], label: String? = nil) {
            result.append(Entry(command: command, alias: alias, label: label ?? command.label))
        }

        add(.sidebarHide, ["hide", "sidebar"])
        add(.sidebarHide, ["collapse", "sidebar"])
        add(.sidebarHide, ["close", "sidebar"])
        add(.sidebarHide, ["shut", "sidebar"])
        add(.sidebarHide, ["hide", "side", "bar"])
        add(.sidebarHide, ["collapse", "side", "bar"])
        add(.sidebarHide, ["close", "side", "bar"])
        add(.sidebarHide, ["shut", "side", "bar"])
        add(.sidebarHide, ["hide", "left", "sidebar"])
        add(.sidebarHide, ["close", "left", "sidebar"])
        add(.sidebarHide, ["shut", "left", "sidebar"])
        add(.sidebarHide, ["hide", "left", "side", "bar"])
        add(.sidebarHide, ["close", "left", "side", "bar"])
        add(.sidebarHide, ["shut", "left", "side", "bar"])
        add(.sidebarHide, ["hide", "left", "panel"])
        add(.sidebarHide, ["close", "left", "panel"])
        add(.sidebarHide, ["shut", "left", "panel"])
        add(.sidebarHide, ["collapse", "left", "panel"])
        add(.sidebarHide, ["hide", "left", "pane"])
        add(.sidebarHide, ["close", "left", "pane"])
        add(.sidebarHide, ["shut", "left", "pane"])
        add(.sidebarHide, ["collapse", "left", "pane"])
        add(.sidebarHide, ["collapse", "left", "sidebar"])
        add(.sidebarHide, ["collapse", "left", "side", "bar"])
        add(.sidebarHide, ["dismiss", "sidebar"])
        add(.sidebarHide, ["dismiss", "side", "bar"])
        add(.sidebarShow, ["show", "sidebar"])
        add(.sidebarShow, ["expand", "sidebar"])
        add(.sidebarShow, ["open", "sidebar"])
        add(.sidebarShow, ["show", "side", "bar"])
        add(.sidebarShow, ["expand", "side", "bar"])
        add(.sidebarShow, ["show", "left", "sidebar"])
        add(.sidebarShow, ["open", "left", "sidebar"])
        add(.sidebarShow, ["show", "left", "panel"])
        add(.sidebarShow, ["open", "left", "panel"])
        add(.sidebarShow, ["show", "left", "pane"])
        add(.sidebarShow, ["open", "left", "pane"])
        add(.sidebarToggle, ["toggle", "sidebar"])
        add(.sidebarToggle, ["toggle", "side", "bar"])

        add(.reviewHide, ["hide", "review", "pane"])
        add(.reviewHide, ["collapse", "review", "pane"])
        add(.reviewHide, ["hide", "review"])
        add(.reviewHide, ["collapse", "review"])
        add(.reviewHide, ["hide", "inspector"])
        add(.reviewHide, ["hide", "right", "panel"])
        add(.reviewHide, ["hide", "right", "pane"])
        add(.reviewHide, ["close", "right", "panel"])
        add(.reviewHide, ["close", "right", "sidebar"])
        add(.reviewHide, ["close", "right", "side", "bar"])
        add(.reviewHide, ["shut", "right", "sidebar"])
        add(.reviewHide, ["shut", "right", "side", "bar"])
        add(.reviewHide, ["hide", "right", "sidebar"])
        add(.reviewHide, ["hide", "right", "side", "bar"])
        add(.reviewHide, ["close", "right", "one"])
        add(.reviewHide, ["close", "right", "1"])
        add(.reviewHide, ["shut", "right", "one"])
        add(.reviewHide, ["shut", "right", "1"])
        add(.reviewShow, ["show", "review", "pane"])
        add(.reviewShow, ["expand", "review", "pane"])
        add(.reviewShow, ["show", "review"])
        add(.reviewShow, ["open", "review"])
        add(.reviewShow, ["show", "inspector"])
        add(.reviewShow, ["show", "right", "panel"])
        add(.reviewShow, ["open", "right", "panel"])
        add(.reviewToggle, ["toggle", "review"])
        add(.reviewToggle, ["toggle", "inspector"])

        add(.terminalOpen, ["open", "terminal"])
        add(.terminalOpen, ["show", "terminal"])
        add(.terminalOpen, ["bring", "up", "terminal"])
        add(.terminalCollapse, ["hide", "terminal"])
        add(.terminalCollapse, ["collapse", "terminal"])
        add(.terminalCollapse, ["close", "terminal"])
        add(.terminalCollapse, ["shut", "terminal"])
        add(.terminalCollapse, ["dont", "want", "see", "terminal"])
        add(.terminalCollapse, ["dont", "want", "to", "see", "terminal"])
        add(.terminalCollapse, ["dont", "see", "terminal"])
        add(.terminalToggle, ["toggle", "terminal"])

        add(.chatTabCreate, ["new", "chat", "tab"])
        add(.chatTabCreate, ["open", "new", "tab"])
        add(.chatTabCreate, ["create", "new", "tab"])
        add(.chatTabCreate, ["new", "tab"])
        add(.chatTabNext, ["next", "chat", "tab"])
        add(.chatTabNext, ["next", "tab"])
        add(.chatTabPrevious, ["previous", "chat", "tab"])
        add(.chatTabPrevious, ["previous", "tab"])
        add(.chatTabPrevious, ["last", "tab"])

        add(.assistantMute, ["mute", "assistant"])
        add(.assistantUnmute, ["unmute", "assistant"])
        add(.assistantMute, ["mute", "narration"])
        add(.assistantUnmute, ["unmute", "narration"])
        add(.assistantMuteToggle, ["toggle", "mute"])

        return result
    }()
}

/// Which words live chrome should look at this tick.
enum LiveChromeSpeech {
    /// Confirmed speech when the analyzer has it; otherwise the live
    /// transcript. `SFSpeechRecognizer` leaves confirmed empty until send.
    static func source(confirmed: String, transcript: String) -> String {
        let confirmedText = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !confirmedText.isEmpty { return confirmedText }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Residual speech Laya should see: everything after chrome the catalog
/// already took. Empty means don't call the model this tick.
enum LiveChromeAsk {
    static func residual(
        in spoken: String,
        usingAliases: Bool = VoiceActionGate.aliasesEnabled
    ) -> String {
        VoiceActionGate.consume(spoken, usingAliases: usingAliases).rewritten
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// New leftover words since the last Laya ask. After a click, that is
    /// the remainder — not the whole utterance Laya already acted on.
    static func question(
        spoken: String,
        lastResidual: String,
        chrome: VoiceChromeIntents = .empty,
        actedOn: String = ""
    ) -> String? {
        let leftover: String
        if chrome.actions.isEmpty {
            leftover = residual(in: spoken)
        } else {
            leftover = HUDVoiceRemainder.text(
                spoken: spoken, chrome: chrome, actedOn: actedOn
            )
        }
        guard !leftover.isEmpty, leftover != lastResidual else { return nil }
        return leftover
    }
}

/// Hold-to-talk and hands-free share this: aliases fire as speech grows,
/// each command at most once per session.
struct LiveChromeReducer: Equatable {
    private(set) var executed: Set<ChromeCommand> = []
    private(set) var seen = ""

    mutating func consumeAliases(
        _ spoken: String,
        usingAliases: Bool = VoiceActionGate.aliasesEnabled
    ) -> VoiceChromeIntents {
        let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != seen else { return .empty }
        let intents = VoiceActionGate.consume(text, usingAliases: usingAliases)
        guard !intents.actions.isEmpty else { return .empty }
        seen = text
        let fresh = intents.actions.filter { executed.insert($0).inserted }
        guard !fresh.isEmpty else { return .empty }
        return VoiceChromeIntents(
            actions: fresh,
            rewritten: intents.rewritten,
            changes: intents.changes.filter { change in
                fresh.contains { $0.rawValue == change.detail }
            }
        )
    }
}
