import Testing
import OreProtocol

@testable import OreMac

/// What a permission card says before the user can answer it.
///
/// The regression this suite exists to hold: the card named the tool and the
/// agent's motive — "Bash" over "Search arXiv API for PerCo SD paper" — and
/// never the command. Approving on a motive is not approving anything.
struct PermissionPresentationTests {
    private func request(
        tool: String = "Bash",
        displayName: String? = nil,
        summary: String? = nil,
        input: JSONValue = .null,
        suggestions: [PermissionSuggestion] = []
    ) -> PermissionRequest {
        PermissionRequest(
            turnID: TurnID(rawValue: "turn"),
            id: PermissionRequestID(rawValue: "p1"),
            toolName: tool,
            displayName: displayName,
            summary: summary,
            input: input,
            suggestions: suggestions
        )
    }

    // MARK: - The act

    @Test func aCommandLeadsWithTheCommandAndNotTheAgentsDescription() {
        let content = PermissionPresentation(request: request(
            displayName: "Bash",
            summary: "Search arXiv API for PerCo SD paper",
            input: .object(["command": .string("curl -s https://export.arxiv.org/api/query")])
        ))
        #expect(content.action == "Run a command")
        #expect(content.target == "curl -s https://export.arxiv.org/api/query")
        // The reason survives, underneath the act rather than in place of it.
        #expect(content.detail == "Search arXiv API for PerCo SD paper")
    }

    @Test func theToolIsStillNamedForTheAuditRead() {
        #expect(PermissionPresentation(request: request()).toolLabel == "Bash")
    }

    @Test func aFileWriteNamesTheWholePath() {
        // The whole path, not the last component: the difference between
        // `src/Model.swift` and `/etc/hosts` is the entire decision.
        let content = PermissionPresentation(request: request(
            tool: "Write",
            input: .object(["file_path": .string("/etc/hosts")])
        ))
        #expect(content.action == "Write a file")
        #expect(content.target == "/etc/hosts")
    }

    @Test func eachKnownToolReadsAsAVerbRatherThanACodename() {
        let cases: [(String, JSONValue, String, String?)] = [
            ("Read", .object(["file_path": .string("a.swift")]), "Read a file", "a.swift"),
            ("Edit", .object(["file_path": .string("a.swift")]), "Edit a file", "a.swift"),
            ("WebFetch", .object(["url": .string("https://x.dev")]), "Fetch a web page", "https://x.dev"),
            ("WebSearch", .object(["query": .string("perco sd")]), "Search the web", "perco sd"),
            ("Grep", .object(["pattern": .string("TODO")]), "Search file contents", "TODO"),
            ("Task", .object(["description": .string("audit deps")]), "Run a subagent", "audit deps"),
        ]
        for (tool, input, action, target) in cases {
            let content = PermissionPresentation(request: request(tool: tool, input: input))
            #expect(content.action == action, "\(tool) should read as \(action)")
            #expect(content.target == target, "\(tool) should act on \(target ?? "nothing")")
        }
    }

    @Test func aGrepNamesWhereItWillSearch() {
        let content = PermissionPresentation(request: request(
            tool: "Grep",
            input: .object(["pattern": .string("TODO"), "path": .string("Sources")])
        ))
        #expect(content.target == "TODO in Sources")
    }

    @Test func aDescriptionThatOnlyRepeatsTheActIsNotShownTwice() {
        let content = PermissionPresentation(request: request(
            tool: "Task",
            summary: "audit deps",
            input: .object(["description": .string("audit deps")])
        ))
        #expect(content.target == "audit deps")
        #expect(content.detail == nil)
    }

    // MARK: - Tools ORE has no verb for

    @Test func anUnknownToolKeepsWhateverTheHarnessCalledIt() {
        let content = PermissionPresentation(request: request(
            tool: "Frobnicate",
            displayName: "Frobnicate a thing",
            summary: "the usual way"
        ))
        #expect(content.action == "Frobnicate a thing")
        #expect(content.target == "the usual way")
    }

    @Test func anUnknownToolWithoutADisplayNameUsesItsOwnName() {
        #expect(PermissionPresentation(request: request(tool: "Frobnicate")).action == "Frobnicate")
    }

    @Test func anMCPToolNamesItsServer() {
        let content = PermissionPresentation(request: request(tool: "mcp__ore__PostDiffComment"))
        #expect(content.action == "PostDiffComment · ore")
    }

    // MARK: - Standing grants

    private func rule(_ content: String) -> PermissionSuggestion {
        PermissionSuggestion(kind: .addRule, title: "Always allow Bash(\(content))", raw: .object([
            "type": .string("addRules"),
            "rules": .array([.object([
                "toolName": .string("Bash"),
                "ruleContent": .string(content),
            ])]),
        ]))
    }

    /// The offer that broke the card. At full width it pushed Allow and Deny
    /// out of the row; on a button it has to stop somewhere.
    @Test func aLongStandingGrantIsShortEnoughToSitOnAButton() {
        let long = #"curl -s "http://export.arxiv.org/api/query?search_query=all:%22PerCo%22&max_results=5""#
        let grant = PermissionPresentation(request: request(suggestions: [rule(long)])).grants[0]
        #expect(grant.label.count <= PermissionPresentation.grantLabelLimit)
        #expect(grant.label.hasPrefix("Always allow Bash(curl"))
        #expect(grant.label.hasSuffix("…"))
        // Clipped for the eye only — the tooltip and VoiceOver still get the
        // whole rule, and the payload handed back is untouched.
        #expect(grant.full == "Always allow Bash(\(long))")
        #expect(grant.raw["rules"]?[0]?["ruleContent"]?.stringValue == long)
    }

    @Test func aShortStandingGrantIsLeftAlone() {
        let grant = PermissionPresentation(request: request(suggestions: [rule("git status")])).grants[0]
        #expect(grant.label == "Always allow Bash(git status)")
    }

    /// A rule that reads as broader than it is would be a lie; a rule that
    /// reads as broad because its narrowing tail was clipped is merely
    /// cautious. Clipping only ever happens at the end, so it stays cautious.
    @Test func clippingOnlyEverDropsTheTail() {
        let clipped = PermissionPresentation.clip("Always allow Bash(git push --force origin main)", to: 24)
        #expect("Always allow Bash(git push --force origin main)".hasPrefix(String(clipped.dropLast())))
    }

    // MARK: - Commands a row cannot show

    /// The attack this flag exists to stop: a first line nobody would refuse,
    /// and the thing that actually matters on the second. Every surface that
    /// shows one line has to know it is showing one line.
    @Test func aBenignFirstLineWithADestructiveTailIsMarkedAbbreviated() {
        let content = PermissionPresentation(request: request(
            summary: "Check the build",
            input: .object(["command": .string("swift build\nrm -rf ~/Documents")])
        ))
        #expect(content.isAbbreviated)
        #expect(content.hiddenLineCount == 1)
        #expect(content.hiddenLineSummary == "+1 more line")
    }

    @Test func aCommandTooLongForARowIsAbbreviatedEvenOnOneLine() {
        let long = "curl -s " + String(repeating: "x", count: 200)
        let content = PermissionPresentation(request: request(
            input: .object(["command": .string(long)])
        ))
        #expect(content.isAbbreviated)
        // Nothing is on a second line, so there is no line count to offer.
        #expect(content.hiddenLineSummary == nil)
    }

    @Test func anOrdinaryCommandIsNotAbbreviated() {
        let content = PermissionPresentation(request: request(
            input: .object(["command": .string("git status")])
        ))
        #expect(!content.isAbbreviated)
        #expect(content.hiddenLineCount == 0)
    }

    @Test func aFilePathIsNotAbbreviated() {
        let content = PermissionPresentation(request: request(
            tool: "Read",
            input: .object(["file_path": .string("Sources/OreMac/AppModel.swift")])
        ))
        #expect(!content.isAbbreviated)
    }

    @Test func grantsKeepTheirKindSoTheCardKnowsWhichEarnsAChord() {
        let mode = PermissionSuggestion(kind: .setMode, title: "Switch to Accept Edits", raw: .object([
            "type": .string("setMode"),
        ]))
        let content = PermissionPresentation(request: request(suggestions: [mode, rule("git status")]))
        #expect(content.grants.map(\.kind) == [.setMode, .addRule])
    }
}
