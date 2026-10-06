import Foundation
import OreProtocol

/// Live window chrome Laya is allowed to choose from. Options are the
/// commands that would actually do something right now — a hidden review
/// pane still offers "show review", a chip already on Ask omits Ask.
struct ChromeAvailability: Equatable, Sendable {
    var showsSidebar: Bool
    var showsReview: Bool
    var showsTerminal: Bool
    var chatTabCount: Int
    var isMuted: Bool
    var permissionMode: PermissionMode = .default
    var effort: ReasoningEffort = .high
    var fastMode: Bool = false
    var supportsFast: Bool = true

    var availableCommands: [ChromeCommand] {
        var commands: [ChromeCommand] = [
            showsSidebar ? .sidebarHide : .sidebarShow,
            .sidebarToggle,
            showsReview ? .reviewHide : .reviewShow,
            .reviewToggle,
            .workspaceReview,
            .gitCommit,
            .gitShip,
            showsTerminal ? .terminalCollapse : .terminalOpen,
            .terminalToggle,
            .findInTranscript,
            .chatTabCreate,
            .chatHistory,
        ]
        if chatTabCount > 1 {
            commands.append(.chatTabNext)
            commands.append(.chatTabPrevious)
        }
        commands.append(contentsOf: [
            .attachFiles,
            .openModelChooser,
            .openEffortChooser,
            .composerSend,
        ])
        if permissionMode != .default { commands.append(.permissionAsk) }
        if permissionMode != .acceptEdits { commands.append(.permissionAcceptEdits) }
        if permissionMode != .plan { commands.append(.permissionPlan) }
        if permissionMode != .bypassPermissions { commands.append(.permissionBypass) }
        if supportsFast {
            commands.append(fastMode ? .composerStandard : .composerFast)
        }
        for option in [ChromeCommand.effortLow, .effortMedium, .effortHigh, .effortXhigh]
        where option.reasoningEffort != effort {
            commands.append(option)
        }
        commands.append(isMuted ? .assistantUnmute : .assistantMute)
        commands.append(.assistantMuteToggle)
        return commands
    }

    /// Panes and mute only. A 30-option choice is why "close the terminal"
    /// lost to Review / Commit / Fast. Live Laya uses this smaller set.
    /// Both show and hide stay available so a repeat "close" after the pane
    /// is already gone still maps to hide (a no-op) instead of reopen.
    var paneCommands: [ChromeCommand] {
        var commands: [ChromeCommand] = [
            .sidebarHide, .sidebarShow, .sidebarToggle,
            .reviewHide, .reviewShow, .reviewToggle,
            .terminalCollapse, .terminalOpen, .terminalToggle,
            .chatTabCreate,
        ]
        if chatTabCount > 1 {
            commands.append(.chatTabNext)
            commands.append(.chatTabPrevious)
        }
        commands.append(.assistantMute)
        commands.append(.assistantUnmute)
        commands.append(.assistantMuteToggle)
        return commands
    }

    /// The tree can choose controls that are outside the old flat live catalog
    /// (Settings, Finder, named files). Keep those available, but still remove
    /// controls whose current UI state explicitly makes them inapplicable.
    var treeCommands: Set<ChromeCommand> {
        var commands = LayaChromeTree.commands
        if chatTabCount <= 1 {
            commands.remove(.chatTabNext)
            commands.remove(.chatTabPrevious)
        }
        commands.remove(isMuted ? .assistantMute : .assistantUnmute)
        switch permissionMode {
        case .default:
            commands.remove(.permissionAsk)
        case .acceptEdits:
            commands.remove(.permissionAcceptEdits)
        case .plan:
            commands.remove(.permissionPlan)
        case .bypassPermissions:
            commands.remove(.permissionBypass)
        }
        for command in [ChromeCommand.effortLow, .effortMedium, .effortHigh, .effortXhigh]
        where command.reasoningEffort == effort {
            commands.remove(command)
        }
        if !supportsFast {
            commands.remove(.composerFast)
            commands.remove(.composerStandard)
        } else if fastMode {
            commands.remove(.composerFast)
        } else {
            commands.remove(.composerStandard)
        }
        return commands
    }


    @MainActor
    static func snapshot(
        tabCount: Int,
        muted: Bool,
        permissionMode: PermissionMode = .default,
        effort: ReasoningEffort = .high,
        fastMode: Bool = false,
        supportsFast: Bool = true
    ) -> ChromeAvailability {
        ChromeAvailability(
            showsSidebar: ChromeLayout.showsSidebar,
            showsReview: ChromeLayout.showsReview,
            showsTerminal: ChromeLayout.showsTerminal,
            chatTabCount: tabCount,
            isMuted: muted,
            permissionMode: permissionMode,
            effort: effort,
            fastMode: fastMode,
            supportsFast: supportsFast
        )
    }
}

extension ChromeCommand {
    var reasoningEffort: ReasoningEffort? {
        switch self {
        case .effortLow: .low
        case .effortMedium: .medium
        case .effortHigh: .high
        case .effortXhigh: .xhigh
        default: nil
        }
    }

    var permissionMode: PermissionMode? {
        switch self {
        case .permissionAsk: .default
        case .permissionAcceptEdits: .acceptEdits
        case .permissionPlan: .plan
        case .permissionBypass: .bypassPermissions
        default: nil
        }
    }

    /// Effect of the control, plus the ways people describe it. Laya matches
    /// meaning against this text — not a keyword list the speaker has to hit.
    var layaCriterion: String {
        switch self {
        case .sidebarShow:
            "bringing back the left workspace list, file list, left sidebar, or left side bar"
        case .sidebarHide:
            "closing, shutting, hiding, or tucking away the left workspace list, file list, left sidebar, or left side bar"
        case .sidebarToggle:
            "flipping the left workspace or file list between shown and hidden"
        case .reviewShow:
            "bringing back the right inspector, right sidebar, right side bar, or review pane — not the Review toolbar button"
        case .reviewHide:
            "closing, shutting, or hiding the right inspector, right sidebar, right side bar, or review pane — not the Review toolbar button"
        case .reviewToggle:
            "flipping the right inspector between shown and hidden"
        case .terminalOpen:
            "bringing up the bottom terminal dock or shell, not a file named terminal"
        case .terminalCollapse:
            "closing, shutting, hiding, or not wanting to see the bottom terminal dock or shell"
        case .terminalToggle:
            "flipping the bottom terminal dock between shown and hidden"
        case .chatTabCreate:
            "starting a fresh conversation tab — the plus button, a new chat, another tab"
        case .chatTabNext:
            "moving to the next conversation tab"
        case .chatTabPrevious:
            "moving to the previous or last conversation tab"
        case .chatHistory:
            "opening past chats, closed tabs, or checkpoint history — the clock"
        case .assistantMute:
            "silencing spoken narration or the assistant voice — mute, quiet, speaker off"
        case .assistantUnmute:
            "turning spoken narration back on — unmute, speak, speaker on"
        case .assistantMuteToggle:
            "flipping narration between muted and unmuted"
        case .workspaceReview:
            "starting an AI review of the current diff — the Review toolbar button, not the right-hand pane"
        case .gitCommit:
            "committing outstanding files, staging the work, or clicking the Commit toolbar button"
        case .gitShip:
            "opening a pull request, shipping the branch, or pushing this work up"
        case .findInTranscript:
            "searching or finding text in this conversation — the magnifying glass"
        case .attachFiles:
            "adding, attaching, or picking files — the paperclip"
        case .openModelChooser:
            "changing which model or agent is selected — the model chip"
        case .openEffortChooser:
            "opening the reasoning-effort picker, without naming a specific level"
        case .composerSend:
            "submitting the composer, sending this message, or hitting the send arrow"
        case .permissionAsk:
            "switching permission mode to Ask, so the agent checks before acting"
        case .permissionAcceptEdits:
            "switching permission mode to Accept Edits, auto-approving file edits"
        case .permissionPlan:
            "switching permission mode to Plan, research-only, no mutations"
        case .permissionBypass:
            "switching permission mode to Bypass, skip permission prompts"
        case .composerStandard:
            "switching composer speed to Standard, not Fast"
        case .composerFast:
            "switching composer speed to Fast"
        case .effortLow:
            "setting reasoning effort to Low"
        case .effortMedium:
            "setting reasoning effort to Medium"
        case .effortHigh:
            "setting reasoning effort to High"
        case .effortXhigh:
            "setting reasoning effort to Extra High or xhigh"
        default:
            label
        }
    }
}

/// Frozen System One questions for the chrome residual. Atomic on purpose:
/// combine the answers in Swift, do not ask Laya to plan.
enum LayaChromeQuestions {
    static let isChrome = "is_chrome"
    static let action = "action"
    static let hasWork = "has_work"
    static let none = "none"

    static func request(transcript: String, available: [ChromeCommand]) -> SystemOneRequest {
        var criteria = [
            none: "coding work, or talk that is not commanding any on-screen control",
        ]
        for command in available {
            criteria[command.rawValue] = command.layaCriterion
        }
        return SystemOneRequest(
            state: ["message": transcript],
            questions: [
                isChrome: SystemOneQuestion(
                    kind: .noul,
                    instructions: "Is the speaker telling the app to hide, show, close, or shut a pane — left sidebar, right sidebar, or terminal — in any wording, including I don't want to see it? Coding talk that only mentions those things is not.",
                    criteria: [:]
                ),
                action: SystemOneQuestion(
                    kind: .choice,
                    instructions: "Match the speaker's meaning, not their exact words. Which control's effect did they describe?",
                    criteria: criteria
                ),
                hasWork: SystemOneQuestion(
                    kind: .noul,
                    instructions: "After any pane command, does leftover speech ask an agent to write, fix, or change code — not another pane to close?",
                    criteria: [:]
                ),
            ],
            model: LayaRuntime.model
        )
    }
}

/// How a System One answer becomes a chrome verdict. A named-control noul
/// plus a choice, or a paraphrase with a confident choice.
enum LayaChromePolicy {
    static let threshold = 0.50
    /// A paraphrase often scores low on the named-control noul and high on
    /// the action choice. Believe the choice when it is this sure.
    static let confidentAction = 0.70

    struct Verdict: Equatable, Sendable {
        var command: ChromeCommand?
        var hasWork: Bool
        var isChrome: Bool
    }

    static func verdict(
        from response: SystemOneResponse,
        available: [ChromeCommand]
    ) -> Verdict {
        let allowed = Set(available)
        let isChrome = (response.answers[LayaChromeQuestions.isChrome]?.noul ?? 0) >= threshold
        let hasWork = (response.answers[LayaChromeQuestions.hasWork]?.noul ?? 0) >= threshold
        let action = response.answers[LayaChromeQuestions.action]
        let strength = action?.probabilities?.values.max() ?? action?.confidence ?? 1
        var command: ChromeCommand?
        if strength >= threshold, let raw = action?.choice, raw != LayaChromeQuestions.none {
            let parsed = ChromeCommand(rawValue: raw)
            if let parsed, allowed.contains(parsed), isChrome || strength >= confidentAction {
                command = parsed
            }
        }
        return Verdict(command: command, hasWork: hasWork, isChrome: isChrome)
    }
}

/// Alias catalog first when it is on; otherwise every tick is a Laya ask.
enum VoiceDecision {
    /// Local BERT on MPS is ~1s idle and several seconds while the mic holds
    /// the GPU. Aborting earlier hangs up the socket (broken pipe) and the
    /// live loop then treats silence as "none".
    static let liveBudget: Duration = .seconds(12)
    static let commitBudget: Duration = .seconds(12)
    /// Wait for confirmed speech to settle before spending a Laya call —
    /// unless the speaker already ended a clause, in which case ask now.
    static let liveDebounce: Duration = .milliseconds(250)
    static let punctuatedDebounce: Duration = .zero

    static func refine(
        spoken: String,
        available: ChromeAvailability,
        engine: (any DecisionEngine)?,
        budget: Duration = commitBudget,
        usingAliases: Bool = VoiceActionGate.aliasesEnabled
    ) async -> VoiceChromeIntents {
        let aliases = VoiceActionGate.consume(spoken, usingAliases: usingAliases)
        if usingAliases, !aliases.actions.isEmpty { return aliases }
        guard let engine else { return aliases }

        let parts = clauses(in: spoken)
        guard !parts.isEmpty else {
            var empty = VoiceChromeIntents(actions: [], rewritten: "", changes: [])
            empty.fromModel = false
            return empty
        }

        let deadline = ContinuousClock.now + budget
        var actions: [ChromeCommand] = []
        var changes: [VoiceChange] = []
        var assistant: [String] = []
        var spokenFile: String?
        var spokenFiles: [String] = []
        var toggleOn: Bool?
        var fromModel = false
        let availableCommands = available.treeCommands

        for (index, clause) in parts.enumerated() {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else {
                if !fromModel {
                    return aliases
                }
                assistant.append(contentsOf: parts[index...])
                break
            }
            let step = await walk(
                hop: LayaChromeTree.root,
                leftover: clause,
                engine: engine,
                available: availableCommands,
                budget: remaining
            )
            if !step.answered {
                if !fromModel { return aliases }
                assistant.append(clause)
                continue
            }
            fromModel = true
            if let command = step.command {
                actions.append(command)
                if command == .openNamedFile {
                    spokenFile = Self.spokenFileName(in: clause)
                    if let spokenFile { spokenFiles.append(spokenFile) }
                }
                if Self.isSettingsToggle(command) {
                    toggleOn = Self.toggleSense(in: clause)
                }
                changes.append(VoiceChange(
                    kind: .chrome,
                    label: command.label,
                    consumed: clause,
                    detail: command.rawValue
                ))
            } else if step.hasWork {
                assistant.append(clause)
            }
        }

        var intents = VoiceChromeIntents(
            actions: actions,
            rewritten: assistant.joined(separator: " "),
            changes: changes,
            fromModel: fromModel,
            spokenFile: spokenFile,
            spokenFiles: spokenFiles,
            toggleOn: toggleOn
        )
        if intents.rewritten.isEmpty, actions.isEmpty, fromModel {
            intents.rewritten = ""
        }
        return intents
    }

    struct WalkStep: Equatable, Sendable {
        var command: ChromeCommand? = nil
        var hasWork: Bool = false
        var answered: Bool = true
    }

    static func walk(
        hop: LayaHop,
        leftover: String,
        engine: any DecisionEngine,
        available: Set<ChromeCommand>? = nil,
        budget: Duration
    ) async -> WalkStep {
        let started = ContinuousClock.now
        var criteria: [String: String] = [:]
        for option in hop.options {
            criteria[option.id] = option.criterion
        }
        let request = SystemOneRequest(
            state: ["message": leftover],
            questions: [
                hop.id: SystemOneQuestion(
                    kind: .choice,
                    instructions: hop.prompt,
                    criteria: criteria
                ),
            ],
            model: LayaRuntime.model
        )
        guard let response = await firstFinished(
            budget: budget,
            work: { await engine.decide(request) }
        ), let answer = response.answers[hop.id] else {
            return WalkStep(answered: false)
        }
        let choice = answer.choice ?? ""
        let option = hop.options.first { $0.id == choice }

        if option?.leaf == .assistant {
            return WalkStep(hasWork: true)
        }
        if option?.leaf == .drop || LayaChromeTree.skipIDs.contains(choice) {
            if option?.children == nil {
                return WalkStep()
            }
        }
        if let children = option?.children {
            let remaining = budget - (ContinuousClock.now - started)
            guard remaining > .zero else { return WalkStep(answered: false) }
            return await walk(
                hop: children,
                leftover: leftover,
                engine: engine,
                available: available,
                budget: remaining
            )
        }
        if let option, let command = LayaChromeTree.command(for: option.id), option.leaf == .click {
            if let available, !available.contains(command) { return WalkStep() }
            return WalkStep(command: command)
        }
        if let command = ChromeCommand(rawValue: choice), option?.children == nil,
           !LayaChromeTree.skipIDs.contains(choice) {
            if let available, !available.contains(command) { return WalkStep() }
            return WalkStep(command: command)
        }
        return WalkStep()
    }

    /// Filename-safe clause split: do not cut on the dot in CONTRIBUTING.md.
    static func clauses(in spoken: String) -> [String] {
        var rest = VoiceIntentExtractor.tidy(spoken)
        var parts: [String] = []
        while !rest.isEmpty {
            if let cut = firstClauseCut(in: rest) {
                let head = VoiceIntentExtractor.tidy(String(rest[..<cut]))
                rest = VoiceIntentExtractor.tidy(String(rest[cut...]))
                if head.count > 3 { parts.append(contentsOf: extraVerbSplits(head)) }
            } else {
                if rest.count > 3 { parts.append(contentsOf: extraVerbSplits(rest)) }
                break
            }
        }
        return parts.filter { $0.count > 3 }
    }

    /// "shut the left side bar close the right one" has two chrome verbs
    /// without and/then. Split on a later chrome verb so each hop sees one.
    static func extraVerbSplits(_ chunk: String) -> [String] {
        let verbs = try? NSRegularExpression(
            pattern: #"\b(?:close|shut|hide|collapse|open|show|tuck|turn on|turn off|reveal|enable|disable)\b"#,
            options: .caseInsensitive
        )
        let ns = chunk as NSString
        let range = NSRange(location: 0, length: ns.length)
        let hits = verbs?.matches(in: chunk, range: range) ?? []
        guard hits.count > 1 else { return [chunk] }
        var out: [String] = []
        var start = 0
        for hit in hits.dropFirst() {
            let piece = ns.substring(with: NSRange(location: start, length: hit.range.location - start))
                .trimmingCharacters(in: .whitespaces)
            if piece.count > 3 { out.append(piece) }
            start = hit.range.location
        }
        let last = ns.substring(from: start).trimmingCharacters(in: .whitespaces)
        if last.count > 3 { out.append(last) }
        return out.isEmpty ? [chunk] : out
    }

    static func spokenFileName(in clause: String) -> String? {
        if let match = clause.range(of: #"[\w./-]+\.\w+"#, options: .regularExpression) {
            return String(clause[match])
        }
        let trimmed = clause.replacingOccurrences(
            of: #"^open\s+(the\s+file\s+)?"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let name = VoiceIntentExtractor.tidy(trimmed)
        return name.isEmpty ? nil : name
    }

    static func isSettingsToggle(_ command: ChromeCommand) -> Bool {
        switch command {
        case .settingsLiquidGlass, .settingsDreamEnable, .settingsHoldToTalk,
             .settingsSilenceSend, .settingsLaunchAtLogin, .settingsQuitAsk,
             .settingsNarration, .settingsGreet, .settingsFleetNarration,
             .settingsAnalytics, .settingsNotifyORE, .settingsNotifyTurn,
             .settingsSound:
            true
        default:
            false
        }
    }

    static func toggleSense(in clause: String) -> Bool? {
        let lower = clause.lowercased()
        if lower.range(of: #"\b(turn off|disable)\b"#, options: .regularExpression) != nil {
            return false
        }
        if lower.range(of: #"\b(turn on|enable|use)\b"#, options: .regularExpression) != nil {
            return true
        }
        return nil
    }

    static func apply(_ verdict: LayaChromePolicy.Verdict, to spoken: String) -> VoiceChromeIntents {
        guard let command = verdict.command else {
            // No click: coding leftover stays, more pane talk does not.
            let rewritten = verdict.hasWork ? spoken : ""
            return VoiceChromeIntents(actions: [], rewritten: rewritten, changes: [])
        }
        let rewritten = remainder(spoken: spoken, hasWork: verdict.hasWork)
        let change = VoiceChange(
            kind: .chrome,
            label: command.label,
            consumed: rewritten.isEmpty ? spoken : prefix(of: spoken, before: rewritten),
            detail: command.rawValue
        )
        return VoiceChromeIntents(
            actions: [command],
            rewritten: rewritten,
            changes: [change]
        )
    }

    /// After a pane click, keep the next clause for another Laya ask — even
    /// when that leftover is more chrome, not coding. `hasWork` only decides
    /// whether a no-click leftover is an assistant prompt. A paraphrase with
    /// no clause boundary is dropped rather than sent whole.
    static func remainder(spoken: String, hasWork: Bool) -> String {
        _ = hasWork
        guard let start = firstClauseCut(in: spoken) else { return "" }
        return VoiceIntentExtractor.tidy(String(spoken[start...]))
    }

    /// Earliest of {and/then/also/plus, sentence punctuation}. Consecutive
    /// conjunctions collapse so "and then also shut" leftover is "shut…".
    static func firstClauseCut(in spoken: String) -> String.Index? {
        let tokens = VoiceLexer.tokenize(spoken)
        let wordBoundaries: Set<String> = ["and", "then", "also", "plus"]
        var wordCut: String.Index?
        if let idx = tokens.firstIndex(where: { wordBoundaries.contains($0.text) }) {
            var end = idx
            while end + 1 < tokens.count, wordBoundaries.contains(tokens[end + 1].text) {
                end += 1
            }
            if end + 1 < tokens.count {
                wordCut = tokens[end + 1].range.lowerBound
            }
        }
        var punctCut: String.Index?
        if let range = spoken.range(of: #"[.?!;:](?:\s+|$)"#, options: .regularExpression),
           range.upperBound < spoken.endIndex {
            var after = range.upperBound
            while after < spoken.endIndex, spoken[after].isWhitespace {
                after = spoken.index(after: after)
            }
            if after < spoken.endIndex { punctCut = after }
        }
        switch (wordCut, punctCut) {
        case let (word?, punct?):
            return word < punct ? word : punct
        case (let word?, nil):
            return word
        case (nil, let punct?):
            return punct
        default:
            return nil
        }
    }

    private static func prefix(of spoken: String, before remainder: String) -> String {
        guard !remainder.isEmpty, spoken.hasSuffix(remainder) else { return spoken }
        let cut = spoken.index(spoken.endIndex, offsetBy: -remainder.count)
        return VoiceIntentExtractor.tidy(String(spoken[..<cut]))
    }

    /// The live path cannot wait on a hung model. Whichever of {answer,
    /// budget} lands first wins; a late decide is abandoned.
    private static func firstFinished(
        budget: Duration,
        work: @escaping @Sendable () async -> SystemOneResponse?
    ) async -> SystemOneResponse? {
        await withTaskGroup(of: SystemOneResponse?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// How long to wait before asking Laya on a growing transcript.
///
/// A time-only wait makes a finished clause feel laggy. Punctuation (and the
/// conjunctions that start the next clause) means the previous thought is
/// already complete — ask immediately.
enum LiveChromeDebounce {
    static func delay(for spoken: String) -> Duration {
        isPunctuated(spoken) ? VoiceDecision.punctuatedDebounce : VoiceDecision.liveDebounce
    }

    static func isPunctuated(_ spoken: String) -> Bool {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let last = trimmed.last, ".?!,;:…".contains(last) { return true }
        guard let word = VoiceLexer.tokenize(trimmed).last?.text else { return false }
        return clauseEnds.contains(word)
    }

    private static let clauseEnds: Set<String> = [
        "and", "then", "also", "plus", "please",
    ]
}
