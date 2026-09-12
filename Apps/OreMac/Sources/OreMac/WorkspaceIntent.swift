import Foundation
import OreProtocol

/// What the user asked for, read out of one sentence of ordinary speech.
///
/// Creating a workspace used to mean answering nine questions — repository
/// source, repository, identity, agent, model, starting branch, first message.
/// Almost every one of those has a right answer the machine can work out, and
/// the few that don't can be said out loud in passing: "take ore, use Claude
/// Code, and branch from release". This is the reading of that sentence.
///
/// The goal text is deliberately left whole. It would be easy to strip the
/// configuration clauses back out of it, and tempting — "branch from release"
/// is not a task. But the agent reads the first message to learn what it is
/// for, and a sentence with words silently removed is a worse brief than one
/// with a few redundant ones. Configuration is lifted out as *metadata*; the
/// instruction is passed on exactly as spoken.
struct WorkspaceIntent: Equatable {
    /// Exactly what the user said, whitespace-normalized. Becomes the agent's
    /// first message.
    var goal: String
    /// A repository named in the instruction — "the ore repo", or just "ore"
    /// when ORE already knows a project by that name. A hint, not a
    /// resolution: `WorkspaceInference` decides what it matches.
    var repositoryHint: String?
    var harness: HarnessKind?
    var model: String?
    /// In the casing the user typed. Branch names are case-sensitive, and
    /// `Release/2.0` is not `release/2.0`.
    var baseBranch: String?
    /// Whether the user said anything to actually work on.
    ///
    /// "Use Claude Code with Opus and branch from release." configures nothing
    /// into existence — there is no task in it, and starting an agent on it
    /// would waste a turn asking the user what they meant.
    var hasGoal: Bool
}

extension WorkspaceIntent {
    /// Reads an instruction. Never fails: anything unrecognized is simply the
    /// goal, which is the common case and the one that must not be mangled.
    ///
    /// The catalogues are passed in rather than looked up, so the whole
    /// reading is a pure function of its inputs — and so "with Opus" resolves
    /// against the models this machine actually has.
    static func read(
        _ instruction: String,
        harnesses: [HarnessKind] = HarnessKind.allCases,
        models: [(id: String, displayName: String)] = [],
        repositoryNames: [String] = []
    ) -> WorkspaceIntent {
        let goal = instruction
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = goal.lowercased()

        let harness = harness(in: lowered, among: harnesses)
        let spent = Set(harness.map(aliases(for:)) ?? [])
        let model = model(in: lowered, among: models, spent: spent)
        let branch = baseBranch(in: goal)
        let repository = repositoryHint(in: lowered, known: repositoryNames)

        return WorkspaceIntent(
            goal: goal,
            repositoryHint: repository,
            harness: harness,
            model: model,
            baseBranch: branch,
            hasGoal: hasGoal(
                lowered,
                spentOn: [branch, repository].compactMap { $0 }
                    + (harness.map(aliases(for:)) ?? [])
                    + (model.map { [$0] } ?? [])
            )
        )
    }

    // MARK: - Agent

    /// "use Claude Code", "with codex", "using cursor agent".
    ///
    /// A bare alias needs a word in front of it that makes it a choice of
    /// agent. "cursor", "claude" and "codex" are all ordinary English in a
    /// sentence about code — "fix the text cursor jumping to the end" was
    /// silently switching the user onto cursor-agent — so the product's
    /// full names stand alone and the single words do not.
    private static func harness(in lowered: String, among harnesses: [HarnessKind]) -> HarnessKind? {
        for kind in harnesses {
            for alias in standaloneAliases(for: kind) where contains(word: alias, in: lowered) {
                return kind
            }
        }

        let words = lowered.split(separator: " ")
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
        for kind in harnesses {
            for alias in bareAliases(for: kind) {
                guard let index = words.firstIndex(of: alias), index > 0 else { continue }
                if harnessLeads.contains(words[index - 1]) { return kind }
                // "use the claude agent", "switch to the codex one".
                if index > 1, words[index - 1] == "the",
                   harnessLeads.contains(words[index - 2]) { return kind }
            }
        }
        return nil
    }

    /// Words that turn the next name into a choice of agent rather than a
    /// noun in the task. "to" covers "switch to codex".
    private static let harnessLeads: Set<String> = [
        "use", "uses", "using", "with", "via", "by", "to", "on", "ask", "run",
    ]

    /// Names that are the product and nothing else.
    private static func standaloneAliases(for kind: HarnessKind) -> [String] {
        switch kind {
        case .claudeCode: return ["claude code", "claude-code"]
        case .codex: return []
        case .cursorAgent: return ["cursor agent", "cursor-agent"]
        }
    }

    /// Names that are also ordinary words, and need an intent phrase.
    private static func bareAliases(for kind: HarnessKind) -> [String] {
        switch kind {
        case .claudeCode: return ["claude"]
        case .codex: return ["codex"]
        case .cursorAgent: return ["cursor"]
        }
    }

    private static func aliases(for kind: HarnessKind) -> [String] {
        standaloneAliases(for: kind) + bareAliases(for: kind)
    }

    // MARK: - Model

    /// Matched against the live catalogue rather than a hard-coded list, so a
    /// model released next month is sayable the day the harness reports it.
    ///
    /// Short names ("opus") are only honoured when exactly one model answers
    /// to them: on a machine offering two Opus versions, "opus" is a question,
    /// not an instruction, and the default is the better answer.
    ///
    /// A word already read as the agent is spent. Codex publishes a model
    /// called GPT-5 Codex, so "use codex with gpt-5" otherwise read the agent
    /// name a second time and started the wrong model.
    private static func model(
        in lowered: String,
        among models: [(id: String, displayName: String)],
        spent: Set<String>
    ) -> String? {
        // Full names are unambiguous by construction and are tried first:
        // with GPT-5 and GPT-5 Codex both installed, the word "gpt-5" is a
        // shared fragment of one but the whole name of the other.
        for entry in models.sorted(by: { $0.id.count > $1.id.count }) {
            for name in [entry.id.lowercased(), entry.displayName.lowercased()].sorted(by: {
                $0.count > $1.count
            }) where !spent.contains(name) && contains(word: name, in: lowered) {
                return entry.id
            }
        }

        var owners: [String: Set<String>] = [:]
        for entry in models {
            for alias in aliases(forModel: entry) where !spent.contains(alias) {
                owners[alias, default: []].insert(entry.id)
            }
        }
        // Longest first: "claude opus 4.8" must win over bare "opus".
        for alias in owners.keys.sorted(by: { $0.count > $1.count }) {
            guard let ids = owners[alias], ids.count == 1,
                  contains(word: alias, in: lowered)
            else { continue }
            return ids.first
        }
        return nil
    }

    /// The distinctive words of a model's name: "Claude Opus 4.8" is asked
    /// for as "opus". The vendor is not distinctive — every Claude model
    /// shares it — and neither is a bare version number.
    private static func aliases(forModel entry: (id: String, displayName: String)) -> [String] {
        entry.displayName.lowercased().split(separator: " ").map(String.init)
            .filter { word in
                word.count > 2 && !modelVendors.contains(word)
                    && !word.allSatisfy { $0.isNumber || $0 == "." }
            }
    }

    private static let modelVendors: Set<String> = ["claude", "openai", "anthropic", "google"]

    // MARK: - Branch

    private static let branchLeads = [
        "branch from", "branching from", "branch off", "based on", "based off",
        "starting from", "start from", "off of", "from branch",
    ]

    /// Figures of speech that follow a branch lead without naming a branch.
    /// "Start from scratch" is the whole reason this exists: it means the
    /// opposite of starting from a branch, and a repository that happens to
    /// have a `scratch` branch must not make it come true.
    private static let notABranch: Set<String> = [
        "branch", "scratch", "zero", "nothing", "here", "there", "now",
        "it", "this", "that", "today", "scratch.", "square",
    ]

    /// "branch from release", "based on the main branch".
    ///
    /// Read out of the original text, not the lowercased copy: git branch
    /// names are case-sensitive, and `Release/2.0` and `release/2.0` are two
    /// different branches — one of which does not exist.
    private static func baseBranch(in goal: String) -> String? {
        for lead in branchLeads {
            guard let range = goal.range(of: lead + " ", options: [.caseInsensitive]) else {
                continue
            }
            let rest = goal[range.upperBound...]
            guard let name = firstName(in: rest, dropping: ["the"]) else { continue }
            return notABranch.contains(name.lowercased()) ? nil : name
        }
        return nil
    }

    // MARK: - Repository

    private static let repositoryLeads = ["repo", "repository", "project"]

    /// Words that lead into a repository name rather than being one.
    private static let repositoryFiller: Set<String> = [
        "the", "a", "an", "this", "that", "my", "our",
        "in", "on", "at", "for", "with", "to", "from", "of",
        "open", "take", "use", "using", "work", "into", "inside",
    ]

    /// "the ore repo", "repo ore", or a bare "ore" when ORE already knows a
    /// project by that name.
    ///
    /// A bare word is only a repository if it *is* one. Treating any proper
    /// noun as a project name would send "investigate the Sparkle updater"
    /// hunting for a Sparkle repository that was never mentioned.
    ///
    /// The keyword reading is tried first but does not win outright. "update
    /// the project readme in ore" puts "readme" next to "project", and that
    /// word is not a project — while "ore", two words later, is one. A
    /// keyword hint therefore only stands when nothing in the sentence names
    /// a project ORE actually has.
    private static func repositoryHint(in lowered: String, known: [String]) -> String? {
        let words = lowered.split(separator: " ")
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
        let namesByLength = known.map { $0.lowercased() }
            .filter { $0.count >= 3 && !commonWords.contains($0) }
            .sorted { $0.count > $1.count }

        let keyworded = keyworded(words)
        if let keyworded, namesByLength.contains(keyworded) { return keyworded }

        // A project ORE actually has, mentioned by name.
        for name in namesByLength where words.contains(name) { return name }

        // A name ORE has never heard of, but the user clearly meant one. Kept
        // rather than dropped, so `WorkspaceInference` asks instead of
        // quietly falling back to whatever is on screen.
        return keyworded
    }

    /// The "… repo" / "repo …" patterns, for projects ORE has never seen.
    private static func keyworded(_ words: [String]) -> String? {
        for (index, word) in words.enumerated() where repositoryLeads.contains(word) {
            if index > 0 {
                let before = words[index - 1]
                if !before.isEmpty, !repositoryFiller.contains(before) { return before }
            }
            if index + 1 < words.count {
                let after = words[index + 1]
                if !after.isEmpty, !["and", "then", "to", "is"].contains(after) { return after }
            }
        }
        return nil
    }

    /// Repository names too ordinary to recognize in a sentence. A project
    /// called "app" must not claim every instruction containing the word.
    private static let commonWords: Set<String> = [
        "app", "web", "api", "src", "lib", "dev", "test", "tests", "code", "docs", "www",
    ]

    // MARK: - Is there a task in here at all?

    /// True when a word remains that is neither grammar nor something already
    /// read as configuration.
    private static func hasGoal(_ lowered: String, spentOn values: [String]) -> Bool {
        var ignored = configurationWords
        for value in values {
            // Split on punctuation too: a model matched as `claude-opus-4-8`
            // was asked for as "opus", and that word is now spent.
            for word in value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                ignored.insert(String(word))
            }
        }
        let remaining = lowered
            .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
            .filter { !ignored.contains($0) }
        return !remaining.isEmpty
    }

    /// Grammar that carries a configuration aside but never a task.
    private static let configurationWords: Set<String> = [
        "use", "using", "with", "and", "the", "a", "an", "on", "in", "from", "off", "of",
        "branch", "branching", "based", "start", "starting", "model", "agent", "repo",
        "repository", "project", "code", "please", "it",
    ]

    // MARK: - Shared

    /// The first bare word, skipping filler, in the casing it was written in.
    /// Stops at punctuation so "branch from release, then run the tests"
    /// takes only "release" — but not at `/`, which is inside a branch name.
    private static func firstName(in text: Substring, dropping filler: [String]) -> String? {
        for token in text.split(separator: " ") {
            let word = token.trimmingCharacters(in: .punctuationCharacters)
            if word.isEmpty || filler.contains(word.lowercased()) { continue }
            return word
        }
        return nil
    }

    /// Whole-word containment.
    ///
    /// Hyphens, dots and slashes count as part of a word, not as boundaries:
    /// `claude-code-config.json` is a filename, and reading it as a request
    /// for Claude Code would silently switch the user's agent.
    private static func contains(word: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: word, range: searchStart..<text.endIndex) {
            let before = range.lowerBound == text.startIndex
                ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if isBoundary(before) && isBoundary(after) { return true }
            guard range.upperBound < text.endIndex else { return false }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }

    private static func isBoundary(_ character: Character?) -> Bool {
        guard let character else { return true }
        if character.isLetter || character.isNumber { return false }
        return !"-_./".contains(character)
    }
}
