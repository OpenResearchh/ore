import Foundation
import OreProtocol

/// Pure logic for spoken narration: what an agent event is worth saying out
/// loud, how tool calls coalesce into one phrase, and which queued utterances
/// a newer one displaces. Everything here is synchronous and value-typed so
/// the rules are testable without AVFoundation or a live agent; the audio
/// side lives in `NarrationEngine`.
///
/// The governing rule is freshness: narration describes what the agent is
/// doing *now*. Anything queued that a newer event makes stale is dropped,
/// never spoken.

// MARK: - Priorities

/// Higher raw value wins. `interrupt` preempts speech mid-word; `milestone`
/// waits its turn but survives; `progress` is a single replaceable slot.
enum NarrationPriority: Int, Comparable, Sendable {
    case progress = 0
    case milestone = 1
    case interrupt = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One thing to say. `kind` is what lets a newer utterance of the same kind
/// replace an older unspoken one instead of stacking behind it.
struct SpokenUtterance: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case toolActivity
        case digest
        case todo
        case planProposal
        case permission(PermissionRequestID)
        case question
        case turnCompleted
        case turnFailed
        case stopped
        case toolFailure
        case contextCompacted
        case rateLimit
        case sessionError

        /// Same-kind replacement ignores associated values: a second
        /// permission request replaces an unspoken first one — the newer ask
        /// is the one that matters.
        var replacementKey: String {
            switch self {
            case .toolActivity: "toolActivity"
            case .digest: "digest"
            case .todo: "todo"
            case .planProposal: "planProposal"
            case .permission: "permission"
            case .question: "question"
            case .turnCompleted: "turnCompleted"
            case .turnFailed: "turnFailed"
            case .stopped: "stopped"
            case .toolFailure: "toolFailure"
            case .contextCompacted: "contextCompacted"
            case .rateLimit: "rateLimit"
            case .sessionError: "sessionError"
            }
        }
    }

    var chatID: ChatID
    var priority: NarrationPriority
    var kind: Kind
    var text: String
}

// MARK: - Origin

/// Where an event happened, relative to what the user is looking at.
///
/// A single `isBackground` flag isn't enough to announce something usefully: a
/// chat is "background" both when it lives in another workspace and when it's
/// simply another tab of the workspace already on screen. Naming the workspace
/// in that second case tells the user what they can already see and omits the
/// only thing they need — which tab.
enum NarrationOrigin: Equatable, Sendable {
    /// The tab the user is looking at.
    case foreground
    /// Another tab in the workspace on screen.
    case otherTab(chatTitle: String)
    /// A different workspace. The chat title rides along only when it says
    /// more than the workspace name already does.
    case otherWorkspace(name: String, chatTitle: String?)

    var isBackground: Bool { self != .foreground }

    /// How to name this place out loud, or nil when it's what's on screen.
    var spokenLabel: String? {
        switch self {
        case .foreground:
            return nil
        case .otherTab(let title):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "another tab" : "the \(trimmed) tab"
        case .otherWorkspace(let name, let title):
            guard let title, !title.isEmpty else { return name }
            return "\(name), \(title)"
        }
    }

    /// The same place written rather than spoken, for notification bodies.
    var displayLabel: String? {
        switch self {
        case .foreground:
            return nil
        case .otherTab(let title):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Another tab" : trimmed
        case .otherWorkspace(let name, let title):
            guard let title, !title.isEmpty else { return name }
            return "\(name) — \(title)"
        }
    }
}

/// Pacing constants, in one place so tests and the engine agree.
enum NarrationPolicy {
    /// Minimum quiet time before another ambient progress utterance.
    static let progressGap: TimeInterval = 7
    /// Milestones queue politely but don't wait long.
    static let milestoneGap: TimeInterval = 1
    /// Tool calls buffer this long before the batch is phrased.
    static let toolFlushAge: TimeInterval = 4
    /// "A step failed" at most once per this window — agents retry a lot.
    static let toolFailureCooldown: TimeInterval = 30
    /// Hard cap on any single utterance; freshness beats completeness.
    static let utteranceLimit = 280
    /// The assistant answering a question the user asked out loud is not an
    /// ambient interjection — it is the reply, and clipping it at 280
    /// characters is what made every answer feel evasive. Still capped, because
    /// a runaway line can only be stopped, never skipped.
    ///
    /// Sized for the answer the assistant is now asked to give: covering each
    /// part of a multi-part question out loud runs past 900 characters often
    /// enough that the cap, not the model, was deciding where the answer
    /// stopped — and a clip ends in "there's more in the Assistant window",
    /// the exact deflection the spoken reply exists to avoid.
    static let assistantAnswerLimit = 1_400
}

// MARK: - Tool classification

/// What a tool call means when spoken. Mirrors the transcript's
/// `processPresentation` heuristics — the same names must classify the same
/// way in text and in speech.
struct ToolActivity: Equatable, Sendable {
    enum Class: Equatable, Sendable {
        case read
        case search
        case edit
        case write
        case delete
        case run
        case fetch
        case subagent
    }

    var kind: Class
    /// Base file name, command noun ("the tests"), or subagent description.
    var subject: String?
}

enum SpokenToolClass {
    /// nil means the call isn't worth a spoken phrase (checklist bookkeeping,
    /// lints, directory listings — transcript detail, spoken noise).
    static func classify(
        name: String,
        displayName: String?,
        input: JSONValue?
    ) -> ToolActivity? {
        let tool = name.lowercased()
        let key = (name + " " + (displayName ?? "")).lowercased()

        // Checklist bookkeeping narrates through the todo path, not per call.
        if ["taskcreate", "taskupdate", "tasklist", "taskget"].contains(where: tool.hasSuffix)
            || tool.contains("todo") {
            return nil
        }
        if SubagentBrief.isSubagentTool(tool) {
            // The short label is the better line for the ear when it exists —
            // already imperative, already a few words. The brief only stands in
            // when a harness omits it, so the phrase never collapses to the
            // bare "It's launching a subagent."
            let description = input.flatMap(SubagentBrief.label)
                ?? input.flatMap { SubagentBrief.purpose(from: $0) }
                ?? displayName
            return ToolActivity(kind: .subagent, subject: description)
        }
        // Lints and listings before the generic read/file matchers —
        // "ReadLints" contains "read" and would otherwise speak as a file read.
        if tool.contains("lint") { return nil }
        if tool == "ls" || tool == "list" || tool == "glob" { return nil }
        if tool == "delete" || tool == "remove" {
            return ToolActivity(kind: .delete, subject: spokenFileName(from: input))
        }
        if key.contains("edit") || key.contains("write") || key.contains("patch") {
            let changeKind = input?[0]?["kind"]?["type"]?.stringValue
                ?? input?["kind"]?["type"]?.stringValue
            let isWrite = key.contains("write") || changeKind == "add"
            return ToolActivity(
                kind: isWrite ? .write : .edit,
                subject: spokenFileName(from: input)
            )
        }
        if key.contains("bash") || key.contains("shell") || key.contains("command") || key.contains("exec") {
            let command = input?["command"]?.stringValue ?? input?["cmd"]?.stringValue ?? ""
            let lower = command.lowercased()
            if lower.contains("rg ") || lower.contains("grep ") || lower.contains("find ") {
                return ToolActivity(kind: .search, subject: nil)
            }
            if lower.contains("cat ") || lower.contains("head ") || lower.contains("tail ")
                || lower.contains("sed -n") {
                return ToolActivity(kind: .read, subject: nil)
            }
            return ToolActivity(kind: .run, subject: commandNoun(command))
        }
        if key.contains("read") || key.contains("file") {
            return ToolActivity(kind: .read, subject: spokenFileName(from: input))
        }
        if key.contains("web") || key.contains("fetch") || input?["url"]?.stringValue != nil {
            return ToolActivity(kind: .fetch, subject: nil)
        }
        if key.contains("search") || key.contains("grep") {
            return ToolActivity(kind: .search, subject: nil)
        }
        return nil
    }

    /// The file a call touches, as it should be spoken: base name, no
    /// extension — "ChatPane", not "slash Apps slash … ChatPane dot swift".
    static func spokenFileName(from input: JSONValue?) -> String? {
        let path = input?["file_path"]?.stringValue
            ?? input?["path"]?.stringValue
            ?? input?[0]?["path"]?.stringValue
        return path.map(spokenFileName(fromPath:))
    }

    static func spokenFileName(fromPath path: String) -> String {
        let base = (path as NSString).lastPathComponent
        let name = (base as NSString).deletingPathExtension
        return name.isEmpty ? base : name
    }

    /// A friendly noun for what a shell command is doing.
    static func commandNoun(_ command: String) -> String {
        let lower = command.lowercased()
        if lower.contains("test") { return "the tests" }
        if lower.contains("build") || lower.contains("xcodebuild") || lower.contains("make ") {
            return "a build"
        }
        if lower.hasPrefix("git ") || lower.contains("&& git ") || lower.contains("| git ") {
            return "a git command"
        }
        if lower.contains("install") { return "an install" }
        return "a command"
    }
}

// MARK: - Tool coalescing

/// Buffers tool calls so five reads become "Reading five files", not five
/// utterances. Flushes when the batch ages out, when the activity class
/// changes (a run of reads followed by an edit phrases the reads), or when
/// something higher priority needs to speak in the right order.
struct ToolActivityCoalescer: Sendable, Equatable {
    private(set) var pending: [ToolActivity] = []
    private var firstAt: Date?
    /// The last phrase produced *at variant 0*, so identical consecutive
    /// batches still dedupe even though what gets spoken rotates frames.
    private var lastPhrase: String?
    /// Advances on every phrase emitted, so a run of reads doesn't repeat one
    /// sentence. Deliberately survives `reset()`: a new turn picking up where
    /// the last left off is more varied than one restarting at frame zero.
    private var variant = 0

    /// Absorbs one call. Returns a phrase when this call forced a flush of
    /// the batch before it (class change), or when the call speaks alone
    /// (a subagent launch is a notable single event).
    mutating func absorb(_ activity: ToolActivity, at now: Date) -> String? {
        if activity.kind == .subagent {
            let flushed = flushAll()
            let launch = NarrationPhraser.phrase(for: [activity], variant: variant)
            if launch != nil {
                lastPhrase = NarrationPhraser.phrase(for: [activity], variant: 0)
                variant += 1
            }
            // The batch that preceded the launch is older news than the
            // launch itself; when both exist the launch wins.
            return launch ?? flushed
        }
        if let last = pending.last, last.kind != activity.kind {
            let flushed = flushAll()
            pending = [activity]
            firstAt = now
            return flushed
        }
        // Same file touched twice in one batch is still one mention.
        if !pending.contains(where: { $0 == activity }) {
            pending.append(activity)
        }
        if firstAt == nil { firstAt = now }
        return nil
    }

    /// The age-based flush, called on the engine's pump cadence.
    mutating func flushIfDue(at now: Date) -> String? {
        guard let firstAt, now.timeIntervalSince(firstAt) >= NarrationPolicy.toolFlushAge else {
            return nil
        }
        return flushAll()
    }

    /// Unconditional flush, for when a milestone or interrupt is about to
    /// speak and the batch should be phrased first or dropped.
    mutating func flushAll() -> String? {
        defer {
            pending = []
            firstAt = nil
        }
        // Dedupe on the stable variant-0 rendering, speak the rotating one.
        guard let key = NarrationPhraser.phrase(for: pending, variant: 0), key != lastPhrase,
              let spoken = NarrationPhraser.phrase(for: pending, variant: variant)
        else { return nil }
        lastPhrase = key
        variant += 1
        return spoken
    }

    mutating func reset() {
        pending = []
        firstAt = nil
        lastPhrase = nil
    }
}

// MARK: - Digest buffer

/// Accumulates the agent's thinking and prose between summarizer calls. The
/// summarizer sees a bounded tail, the recent tool phrases for grounding, and
/// what was last spoken so it can avoid repeating itself.
struct DigestBuffer: Sendable, Equatable {
    static let tailLimit = 1500
    static let triggerThreshold = 300
    static let activityLimit = 5

    private(set) var text = ""
    private(set) var newCharacters = 0
    private(set) var recentActivity: [String] = []
    private(set) var lastSpoken: String?
    /// Bumped on every clear. A summarizer result produced against an older
    /// generation is stale and must be dropped.
    private(set) var generation = 0

    mutating func append(_ delta: String) {
        text += delta
        newCharacters += delta.count
        if text.count > Self.tailLimit {
            text = String(text.suffix(Self.tailLimit))
        }
    }

    mutating func noteActivity(_ phrase: String) {
        recentActivity.append(phrase)
        if recentActivity.count > Self.activityLimit {
            recentActivity.removeFirst(recentActivity.count - Self.activityLimit)
        }
    }

    mutating func noteSpoken(_ sentence: String) {
        lastSpoken = sentence
    }

    var isTriggerReady: Bool { newCharacters >= Self.triggerThreshold }

    /// The summarizer's input. Consumes the "new" counter so one burst of
    /// thinking produces one call, not one per pump tick.
    mutating func snapshot() -> (prompt: String, generation: Int) {
        newCharacters = 0
        var lines: [String] = []
        if !recentActivity.isEmpty {
            lines.append("Recent tool activity:")
            lines.append(contentsOf: recentActivity.map { "- \($0)" })
            lines.append("")
        }
        if let lastSpoken {
            lines.append("Last spoken to the user: \"\(lastSpoken)\"")
            lines.append("")
        }
        lines.append("The agent's recent output and reasoning:")
        lines.append(text)
        return (lines.joined(separator: "\n"), generation)
    }

    /// Turn boundary: whatever was buffered belongs to a turn that no longer
    /// exists for narration purposes.
    mutating func clear() {
        text = ""
        newCharacters = 0
        recentActivity = []
        lastSpoken = nil
        generation += 1
    }
}

// MARK: - Phrasing

/// Every template sentence in one place: present tense, addressed to the
/// user, plain spoken language — no paths, no markdown, no code punctuation.
///
/// Two rules govern the wording, both of them about being *heard* rather than
/// read. First, every line takes a subject: "it's reading ChatPane", never the
/// headless "Reading ChatPane" — the latter is log-line grammar and sounds
/// like one read aloud. Second, no colons: a colon is a visual device, and in
/// speech it degrades to a pause the listener can't parse structure from, so
/// "Permission needed: git push" lands as two disconnected fragments.
///
/// `variant` rotates between equivalent frames so a run of the same event
/// class doesn't beat the same sentence into the listener. It's a parameter
/// rather than a random draw so the phrasing stays deterministic under test;
/// callers pass a counter they own.
enum NarrationPhraser {
    // Frame sets. `{}` is the subject clause. Order matters only in that
    // variant 0 is what the dedupe key and the tests pin to.
    private static let readFrames = [
        "Now it's reading {}.",
        "It's looking through {}.",
        "It's going through {}.",
        "It's checking {} now.",
        "It's taking a closer look at {}.",
        "Now it's reviewing {}.",
    ]
    private static let editFrames = [
        "Now it's editing {}.",
        "It's making changes to {}.",
        "It's reworking {}.",
        "It's updating {} now.",
        "Now it's refining {}.",
        "It's adjusting {}.",
    ]
    private static let writeFrames = [
        "It's writing {}.",
        "Now it's creating {}.",
        "It's putting together {}.",
        "Now it's adding {}.",
        "It's building out {}.",
    ]
    private static let deleteFrames = [
        "It's deleting {}.",
        "Now it's removing {}.",
        "It's clearing out {}.",
        "Now it's taking out {}.",
    ]
    private static let searchFrames = [
        "It's searching the codebase.",
        "Now it's digging through the code.",
        "It's hunting around the codebase.",
        "It's looking for the relevant code.",
        "Now it's tracing where that lives.",
        "It's scanning the project for that.",
    ]
    private static let fetchFrames = [
        "It's fetching something from the web.",
        "Now it's pulling something from the web.",
        "It's checking an external source.",
        "Now it's looking that up online.",
        "It's gathering the outside information it needs.",
    ]
    private static let runFrames = [
        "Now it's running {}.",
        "It's kicking off {}.",
        "It's trying {} now.",
        "Now it's checking with {}.",
        "It's putting {} through its paces.",
    ]
    private static let genericRunFrames = [
        "It's running a few commands.",
        "Now it's trying a few commands.",
        "It's checking things from the command line.",
        "Now it's running the next checks.",
        "It's putting a few commands to work.",
    ]
    private static let subagentFrames = [
        "It's launching a subagent to {}",
        "Now it's handing off to a subagent to {}",
        "It's asking another agent to {}",
        "Now it's bringing in another agent to {}",
        "It's delegating a focused pass to {}",
    ]

    /// One phrase for a batch of same-class activities.
    static func phrase(for activities: [ToolActivity], variant: Int = 0) -> String? {
        guard let first = activities.first else { return nil }
        let subjects = activities.compactMap(\.subject).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        let files = subjectClause(subjects, plural: "files")
        switch first.kind {
        case .read: return framed(readFrames, files, variant)
        case .edit: return framed(editFrames, files, variant)
        case .write: return framed(writeFrames, files, variant)
        case .delete: return framed(deleteFrames, files, variant)
        case .search: return pick(searchFrames, variant)
        case .fetch: return pick(fetchFrames, variant)
        case .run:
            guard subjects.count == 1 else { return pick(genericRunFrames, variant) }
            return framed(runFrames, subjects[0], variant)
        case .subagent:
            guard let description = subjects.first else { return "It's launching a subagent." }
            return framed(
                subagentFrames,
                sanitize(lowercasedLead(description), limit: 90),
                variant
            ).ensuringTerminalPunctuation()
        }
    }

    private static func pick(_ frames: [String], _ variant: Int) -> String {
        frames[abs(variant) % frames.count]
    }

    private static func framed(_ frames: [String], _ subject: String, _ variant: Int) -> String {
        pick(frames, variant).replacingOccurrences(of: "{}", with: subject)
    }

    /// What the batch is about, as a noun phrase a frame can wrap: a name, two
    /// names, or a count. Never a bare plural — "reading files" sounds like a
    /// category, "reading some files" like a thing happening.
    private static func subjectClause(_ subjects: [String], plural: String) -> String {
        switch subjects.count {
        case 0: return "some \(plural)"
        case 1: return subjects[0]
        case 2: return "\(subjects[0]) and \(subjects[1])"
        default: return "\(spokenCount(subjects.count)) \(plural)"
        }
    }

    /// Single-form on purpose: the interrupts are the lines the user acts on,
    /// and a consistent shape is easier to recognize mid-sentence than a
    /// varied one. "for X" rather than "to run X" because the underlying text
    /// may be a summary, a display name, or a bare tool name.
    static func permission(_ request: PermissionRequest) -> String {
        let what = request.summary ?? request.displayName ?? request.toolName
        return sanitize("It needs your permission for \(what).")
    }

    static func question(_ question: AgentQuestion) -> String {
        sanitize("It has a question for you. \(firstSentences(question.prompt, maxCharacters: 140))")
            .ensuringTerminalPunctuation()
    }

    static func planProposal(variant: Int = 0) -> String {
        pick([
            "It's got a plan ready for you to look at.",
            "There's a plan ready for your review.",
            "It has mapped out the approach for you.",
            "The proposed plan is ready when you are.",
            "It has an approach ready for you to check.",
        ], variant)
    }

    /// The plan interrupt with its crux attached — what the plan would do,
    /// then the nudge to go read the full text. Falls back to the plain line
    /// when the crux sanitizes away to nothing.
    static func planProposal(crux: String, variant: Int = 0) -> String {
        let spoken = sanitize(lowercasedLead(crux), limit: 200)
        guard !spoken.isEmpty else { return planProposal(variant: variant) }
        let lead = pick([
            "It's got a plan ready",
            "The proposed approach is ready",
            "It has mapped out a plan",
            "There's an approach ready to review",
            "The plan is ready",
        ], variant)
        return "\(lead) — \(spoken.ensuringTerminalPunctuation()) "
            + "Have a look when you're ready."
    }

    /// The agent's own spoken line for the turn (see `NarrationTag`). Already
    /// written for the ear by instruction, so it only gets hygiene — the same
    /// sanitize-and-punctuate every other dynamic line gets.
    static func spokenNarration(
        _ text: String?,
        limit: Int = NarrationPolicy.utteranceLimit
    ) -> String? {
        guard let text else { return nil }
        // Sanitize without clipping, so the cut can be chosen on a sentence
        // boundary below rather than wherever the character budget ran out.
        let spoken = sanitize(text, limit: .max)
        guard !spoken.isEmpty else { return nil }
        guard spoken.count > limit else { return spoken.ensuringTerminalPunctuation() }
        // `sanitize` marks a clip with an ellipsis, which is silent — the ear
        // just hears an answer stop mid-thought, which is exactly what a long
        // spoken answer must not do. Say that there is more instead.
        return sentenceClip(spoken, limit: limit)
            + " — there's more in the Assistant window."
    }

    /// The longest run of *whole sentences* that fits, so a clipped answer
    /// ends on a finished thought. A severed final clause is the thing that
    /// makes a long spoken reply sound like it failed rather than ran out —
    /// and the pointer that follows only reads as helpful after a complete one.
    ///
    /// Falls back to the word boundary when no sentence ends in budget, or
    /// when honouring the boundary would throw away most of the answer (one
    /// short opener followed by a very long sentence).
    private static func sentenceClip(_ text: String, limit: Int) -> String {
        let head = String(text.prefix(limit))
        if let end = head.lastIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            let whole = String(head[...end])
            if whole.count >= limit / 2 { return whole }
        }
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        return cut.trimmingCharacters(in: .whitespaces).ensuringTerminalPunctuation()
    }

    /// Only when the in-progress item actually changed; harnesses re-emit the
    /// whole checklist on every touch.
    static func todoPhrase(
        items: [TodoItem],
        previousInProgress: String?,
        variant: Int = 0
    ) -> (phrase: String?, currentInProgress: String?) {
        let current = items.first { $0.status == .inProgress }?.text
        guard let current, current != previousInProgress else {
            return (nil, current ?? previousInProgress)
        }
        let frames = [
            "Next up, {}.",
            "Now it's moving on to {}.",
            "On to {} now.",
            "It's turning to {} next.",
            "The next step is {}.",
            "Now it's focusing on {}.",
        ]
        let phrase = framed(frames, sanitize(lowercasedLead(current), limit: 120), variant)
        return (phrase, current)
    }

    /// Template fallback when the turn summary can't be spoken directly.
    static func completionFallback(duration: TimeInterval?, variant: Int = 0) -> String {
        guard let duration, duration >= 5 else {
            return pick([
                "All done.",
                "That's done.",
                "Finished.",
                "That one's wrapped up.",
                "It's ready.",
                "Done with that.",
            ], variant)
        }
        return framed(
            [
                "All done, that took about {}.",
                "Finished — about {}.",
                "That's wrapped up after about {}.",
                "It's ready, that took around {}.",
                "Done with that in about {}.",
            ],
            spokenDuration(duration),
            variant
        )
    }

    /// A short final summary speaks as-is; anything longer needs the
    /// summarizer, and this returns nil to say so.
    static func directSummary(_ summary: String?) -> String? {
        guard let summary else { return nil }
        let spoken = sanitize(summary, limit: 1000)
        guard !spoken.isEmpty, spoken.count <= 220 else { return nil }
        return spoken.ensuringTerminalPunctuation()
    }

    static func turnFailed(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "The turn failed." }
        return sanitize("The turn failed. \(firstSentences(message, maxCharacters: 160))")
            .ensuringTerminalPunctuation()
    }

    static func sessionError(_ error: SessionError) -> String {
        sanitize("Something went wrong with the session. \(firstSentences(error.message, maxCharacters: 160))")
            .ensuringTerminalPunctuation()
    }

    static func contextCompacted(variant: Int = 0) -> String {
        pick([
            "It just compacted the context to stay under the limit.",
            "It condensed the conversation so it can keep going.",
            "It made more context room and is continuing.",
            "It summarized the earlier context to keep working.",
        ], variant)
    }

    static func rateLimit(_ report: RateLimitReport) -> String? {
        switch report.status {
        case .warning:
            return "You're getting close to your usage limit."
        case .exhausted:
            if let resetsAt = report.resetsAt {
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                formatter.dateStyle = .none
                return "Usage limit reached. It resets at \(formatter.string(from: resetsAt))."
            }
            return "Usage limit reached."
        case .allowed, .unknown:
            return nil
        }
    }

    static func toolFailure(variant: Int = 0) -> String {
        pick([
            "Something failed there, but it's handling it.",
            "That attempt didn't work, so it's adjusting.",
            "It hit a snag and is working around it.",
            "That step failed, but it's trying another route.",
        ], variant)
    }

    static func stopped(variant: Int = 0) -> String {
        pick([
            "Okay, stopped.",
            "Stopped there.",
            "All right, it's stopped.",
            "Okay, that run is stopped.",
        ], variant)
    }

    /// Short, context-free lines worth rendering once after the neural model
    /// loads. Dynamic lines still populate the same cache on demand; this set
    /// only removes first-use latency from phrases that recur across projects.
    /// Keeping the list derived from the public phrasing functions prevents a
    /// bundled audio corpus from drifting away from what the UI can emit.
    static var neuralCacheCorpus: [String] {
        var result: [String] = []
        func append(_ phrase: String?) {
            guard let phrase, !result.contains(phrase) else { return }
            result.append(phrase)
        }

        for variant in 0..<6 {
            append(phrase(for: [ToolActivity(kind: .read, subject: nil)], variant: variant))
            append(phrase(for: [ToolActivity(kind: .edit, subject: nil)], variant: variant))
            append(phrase(for: [ToolActivity(kind: .write, subject: nil)], variant: variant))
            append(phrase(for: [ToolActivity(kind: .delete, subject: nil)], variant: variant))
            append(phrase(for: [ToolActivity(kind: .search, subject: nil)], variant: variant))
            append(phrase(for: [ToolActivity(kind: .fetch, subject: nil)], variant: variant))
            append(phrase(for: [ToolActivity(kind: .run, subject: nil)], variant: variant))
            append(completionFallback(duration: nil, variant: variant))
            append(toolFailure(variant: variant))
            append(stopped(variant: variant))
            append(contextCompacted(variant: variant))
        }
        for variant in 0..<5 { append(planProposal(variant: variant)) }
        append("You're getting close to your usage limit.")
        append("Usage limit reached.")
        return result
    }

    /// Background utterances say where they're coming from before what
    /// happened. A comma rather than a colon: the listener hears one sentence,
    /// not a label and then a fragment.
    static func prefixed(_ text: String, place: String) -> String {
        "Over in \(place), \(lowercasedLead(text))"
    }

    // MARK: Text hygiene

    /// Strips what reads fine but speaks terribly: code fences, backticks,
    /// markdown emphasis and links, bare URLs. Collapses whitespace and caps
    /// the length at a word boundary.
    static func sanitize(_ text: String, limit: Int = NarrationPolicy.utteranceLimit) -> String {
        var value = text
        value = value.replacingOccurrences(of: "```", with: " ")
        value = value.replacingOccurrences(of: "`", with: "")
        value = value.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"https?://\S+"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"[*_#>]+"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > limit else { return value }
        let head = String(value.prefix(limit))
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        return cut + "…"
    }

    /// The first sentence or two, for places where the full text is a
    /// paragraph written for reading.
    static func firstSentences(_ text: String, maxCharacters: Int) -> String {
        let flattened = text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > maxCharacters else { return flattened }
        var result = ""
        for sentence in flattened.split(separator: ".", omittingEmptySubsequences: true) {
            let candidate = result.isEmpty ? "\(sentence)." : "\(result) \(sentence)."
            if candidate.count > maxCharacters { break }
            result = candidate
        }
        if result.isEmpty {
            let head = String(flattened.prefix(maxCharacters))
            result = (head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head) + "…"
        }
        return result
    }

    static func spokenDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = Int((duration / 60).rounded())
        if minutes < 60 { return minutes == 1 ? "a minute" : "\(minutes) minutes" }
        let hours = minutes / 60
        return hours == 1 ? "an hour" : "\(hours) hours"
    }

    /// Small counts speak as words; TTS says "5 files" fine, but "five files"
    /// sounds like a person.
    static func spokenCount(_ count: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five",
                     "six", "seven", "eight", "nine", "ten"]
        return count < words.count ? words[count] : "\(count)"
    }

    private static func lowercasedLead(_ text: String) -> String {
        guard let first = text.first, first.isUppercase,
              // Keep acronyms and identifiers ("PR", "AppModel") capitalized.
              !(text.count > 1 && text[text.index(after: text.startIndex)].isUppercase)
        else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

private extension String {
    func ensuringTerminalPunctuation() -> String {
        guard let last = self.last else { return self }
        return [".", "!", "?", "…"].contains(String(last)) ? self : self + "."
    }
}

// MARK: - Queue policy

/// The ordered set of things waiting to be spoken, and the displacement rules
/// between them. Pure so preemption and replacement are testable; the engine
/// owns the synthesizer and just asks this what to say next.
struct NarrationQueue: Sendable, Equatable {
    private(set) var items: [SpokenUtterance] = []

    enum Effect: Equatable {
        /// Keep speaking whatever is playing; the new item waits its turn.
        case queued
        /// Stop the current utterance mid-word — the new item outranks it.
        case interruptCurrent
        /// The new item wasn't worth queueing (empty text).
        case dropped
    }

    mutating func enqueue(_ utterance: SpokenUtterance) -> Effect {
        guard !utterance.text.isEmpty else { return .dropped }
        switch utterance.priority {
        case .interrupt:
            // The user is blocked; whatever ambient narration this chat had
            // queued is now noise.
            items.removeAll {
                $0.chatID == utterance.chatID && $0.priority < .interrupt
            }
            replaceOrInsert(utterance)
            return .interruptCurrent
        case .milestone:
            // "It finished" makes "what it's doing" moot.
            items.removeAll {
                $0.chatID == utterance.chatID && $0.priority == .progress
            }
            replaceOrInsert(utterance)
            return .queued
        case .progress:
            // Latest-only slot: ambient narration never stacks.
            items.removeAll {
                $0.chatID == utterance.chatID && $0.priority == .progress
            }
            replaceOrInsert(utterance)
            return .queued
        }
    }

    /// Priority order, FIFO within a priority; an unspoken utterance of the
    /// same kind for the same chat is replaced in place — the newer text is
    /// the fresher truth.
    private mutating func replaceOrInsert(_ utterance: SpokenUtterance) {
        if let index = items.firstIndex(where: {
            $0.chatID == utterance.chatID
                && $0.kind.replacementKey == utterance.kind.replacementKey
        }) {
            items[index] = utterance
            return
        }
        let insertAt = items.firstIndex { $0.priority < utterance.priority } ?? items.count
        items.insert(utterance, at: insertAt)
    }

    mutating func next() -> SpokenUtterance? {
        guard !items.isEmpty else { return nil }
        return items.removeFirst()
    }

    var peek: SpokenUtterance? { items.first }

    /// A new user message makes everything this chat had queued — including a
    /// now-moot question — stale.
    mutating func dropAll(for chatID: ChatID) {
        items.removeAll { $0.chatID == chatID }
    }

    /// Tab-switch freshness: ambient narration for a chat the user just left.
    mutating func dropProgress(for chatID: ChatID) {
        items.removeAll { $0.chatID == chatID && $0.priority == .progress }
    }

    /// The mic opening makes all ambient narration stale — by the time it
    /// closes, the agent has moved on.
    mutating func dropAllProgress() {
        items.removeAll { $0.priority == .progress }
    }

    /// The user resolved the permission in the UI before we got to speak it.
    mutating func invalidatePermission(_ id: PermissionRequestID) {
        items.removeAll {
            if case .permission(let pending) = $0.kind { return pending == id }
            return false
        }
    }

    mutating func removeAll() {
        items.removeAll()
    }
}
