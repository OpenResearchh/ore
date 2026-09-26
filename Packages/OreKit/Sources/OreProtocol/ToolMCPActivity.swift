import Foundation

/// A thinking-chip label for MCP tools, Claude `Skill`, and other named
/// calls that are not Read/Edit/Bash.
///
/// Claude namespaces them `mcp__github__get_issue`. Codex sends the bare tool
/// plus a `server` field, and used to put that server (`github`, `ore`) on
/// the chip — the one thing that does not say which issue, file, or commit.
/// Arguments spell the subject as `filePath`, `issue_number`, `title`,
/// `message`, `path`, `skill`, …
public struct ToolMCPActivity: Equatable, Sendable {
    public var title: String
    public var subject: String?
    public var filePath: String?
    public var icon: String
    public var tintName: String

    public init(title: String, subject: String?, filePath: String? = nil, icon: String, tintName: String) {
        self.title = title
        self.subject = Self.nonEmpty(subject)
        self.filePath = Self.nonEmpty(filePath)
        self.icon = icon
        self.tintName = tintName
    }

    public var chipLabel: String? {
        subject.flatMap { Self.compact($0) }
    }

    /// A permission-card verb, when we know one.
    public var action: String {
        Self.actionName(forTitle: title)
    }

    public static func classify(
        tool: String,
        input: JSONValue?,
        fallback: String? = nil
    ) -> ToolMCPActivity? {
        let key = ToolWebActivity.toolKey(tool)
        if isHarnessPrimitive(key) { return nil }

        let payload = ToolWebActivity.unwrapped(input) ?? input
        let namespaced = isNamespaced(tool)
        let kind = presentation(for: key)
        let extracted = subject(for: key, from: payload)
        let fallbackSubject = usableFallback(fallback, tool: tool, title: kind.title)
        let subject = extracted ?? fallbackSubject

        guard namespaced || isKnown(key) || subject != nil else { return nil }

        return ToolMCPActivity(
            title: kind.title,
            subject: subject,
            filePath: filePath(from: payload),
            icon: kind.icon,
            tintName: kind.tintName
        )
    }

    public static func actionName(for tool: String) -> String? {
        let key = ToolWebActivity.toolKey(tool)
        guard isKnown(key) else { return nil }
        return actionName(forTitle: presentation(for: key).title)
    }

    // MARK: - Titles

    private struct Kind {
        var title: String
        var icon: String
        var tintName: String
    }

    private static func presentation(for key: String) -> Kind {
        let value = collapsing(key)
        if value == "skill" {
            return Kind(title: "Skill", icon: "wand.and.stars", tintName: "purple")
        }
        if matches(value, ["postdiffcomment", "adddiffcomment"]) {
            return Kind(title: "Comment", icon: "text.bubble", tintName: "orange")
        }
        if matches(value, ["postdreamfinding"]) {
            return Kind(title: "Finding", icon: "moon.stars", tintName: "purple")
        }
        if value == "commit" {
            return Kind(title: "Commit", icon: "plus.square.on.square", tintName: "green")
        }
        if value == "push" {
            return Kind(title: "Push", icon: "square.and.arrow.up", tintName: "blue")
        }
        if contains(value, ["pullrequest", "pull_request", "pullrequests"]) {
            if value.contains("merge") {
                return Kind(title: "Merge", icon: "arrow.triangle.merge", tintName: "purple")
            }
            return Kind(title: "Pull request", icon: "arrow.triangle.pull", tintName: "purple")
        }
        if matches(value, ["createissue", "getissue", "listissues", "updateissue", "addissuecomment"])
            || (value.contains("issue") && !value.contains("permission")) {
            return Kind(title: "Issue", icon: "exclamationmark.circle", tintName: "orange")
        }
        if contains(value, ["memory"]) {
            return Kind(title: "Memory", icon: "brain", tintName: "purple")
        }
        if matches(value, ["getworkspacediff", "getdiffcomments"]) {
            return Kind(title: "Diff", icon: "doc.plaintext", tintName: "blue")
        }
        if value.contains("conflict") {
            return Kind(title: "Conflict", icon: "arrow.triangle.swap", tintName: "orange")
        }
        return Kind(title: humanize(key), icon: "puzzlepiece.extension", tintName: "secondary")
    }

    private static func actionName(forTitle title: String) -> String {
        switch title {
        case "Skill": return "Use a skill"
        case "Comment": return "Post a comment"
        case "Finding": return "Post a finding"
        case "Commit": return "Create a commit"
        case "Push": return "Push a branch"
        case "Pull request": return "Open a pull request"
        case "Merge": return "Merge a pull request"
        case "Issue": return "Work on an issue"
        case "Memory": return "Update memory"
        case "Diff": return "Read the diff"
        case "Conflict": return "Resolve a conflict"
        default: return title
        }
    }

    private static func isKnown(_ key: String) -> Bool {
        let value = collapsing(key)
        if value == "skill" { return true }
        if matches(value, [
            "postdiffcomment", "adddiffcomment", "postdreamfinding",
            "commit", "push", "createpullrequest", "mergepullrequest",
            "writememory", "readmemory", "deletememory", "listmemory",
            "getworkspacediff", "getdiffcomments",
            "createissue", "getissue", "listissues", "updateissue",
            "getpullrequest", "listpullrequests", "createorupdatefile", "pushfiles",
        ]) {
            return true
        }
        return value.contains("pullrequest") || value.contains("issue") || value.contains("memory")
    }

    /// Built-in harness tools already have their own chip. Matching them here
    /// would steal Glob/Grep/Bash and turn them into a puzzle piece.
    private static func isHarnessPrimitive(_ key: String) -> Bool {
        let value = key.lowercased()
        switch value {
        case "bash", "shell", "read", "write", "edit", "multiedit", "notebookedit",
             "glob", "grep", "ls", "list", "delete", "remove", "readlints",
             "webfetch", "websearch", "task", "agent", "todowrite", "todoread",
             "createplan", "exitplanmode", "bashoutput", "killshell", "killbash":
            return true
        default:
            return false
        }
    }

    private static func isNamespaced(_ tool: String) -> Bool {
        let value = tool.lowercased()
        return value.hasPrefix("mcp__") || value.hasPrefix("mcp:")
    }

    // MARK: - Subject

    private static func subject(for key: String, from input: JSONValue?) -> String? {
        let github = githubRef(from: input)
        let value = collapsing(key)

        if value == "skill" {
            return field(input, "skill") ?? field(input, "command") ?? field(input, "name")
        }
        if matches(value, ["postdiffcomment", "adddiffcomment"]) {
            return fileName(from: input) ?? github
        }
        if matches(value, ["postdreamfinding"]) {
            return field(input, "title")
        }
        if value == "commit" {
            return firstLine(field(input, "message"))
        }
        if contains(value, ["pullrequest"]) || contains(value, ["issue"]) {
            return github
                ?? field(input, "title")
                ?? field(input, "query")
                ?? field(input, "q")
        }
        if contains(value, ["memory"]) {
            return fileName(from: input)
        }
        if value == "createworkspace" || value == "createproject" || value == "renameworkspace" {
            return field(input, "name") ?? field(input, "repository")
        }
        if value == "createchat" || value == "renamechat" {
            return field(input, "name") ?? field(input, "title")
        }

        // Sequential, not a `??` chain: Swift 6.1 on CI timed out type-checking
        // ten optional-coalesces of `field` in one expression.
        if let github { return github }
        if let title = field(input, "title") { return title }
        if let message = firstLine(field(input, "message")) { return message }
        if let question = field(input, "question") { return question }
        if let query = field(input, "query") ?? field(input, "q") { return query }
        if let skill = field(input, "skill") { return skill }
        if let name = field(input, "name") { return name }
        if let file = fileName(from: input) { return file }
        return field(input, "pattern")
    }

    private static func githubRef(from input: JSONValue?) -> String? {
        let owner = field(input, "owner")
        let repo = field(input, "repo") ?? field(input, "repository")
        let combined: String?
        if let owner, let repo, !repo.contains("/") {
            combined = "\(owner)/\(repo)"
        } else {
            combined = repo ?? owner
        }
        let number = field(input, "issue_number")
            ?? field(input, "issueNumber")
        let pull = field(input, "pull_number")
            ?? field(input, "pullNumber")
            ?? field(input, "number")
        let issue = number ?? pull
        if let combined, let issue { return "\(combined)#\(issue)" }
        if let issue { return "#\(issue)" }
        return combined
    }

    private static func filePath(from input: JSONValue?) -> String? {
        field(input, "filePath")
            ?? field(input, "file_path")
            ?? field(input, "path")
            ?? field(input, "notebook_path")
    }

    private static func fileName(from input: JSONValue?) -> String? {
        filePath(from: input).map { ($0 as NSString).lastPathComponent }
    }

    private static func field(_ input: JSONValue?, _ key: String) -> String? {
        guard let value = input?[key] else { return nil }
        if let text = nonEmpty(value.stringValue) { return text }
        if let number = value.intValue { return String(number) }
        return nil
    }

    private static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        return compact(line, limit: 72)
    }

    private static func usableFallback(_ text: String?, tool: String, title: String) -> String? {
        guard let value = nonEmpty(text) else { return nil }
        let lower = value.lowercased()
        if lower == tool.lowercased() || lower == ToolWebActivity.toolKey(tool) { return nil }
        if lower == title.lowercased() { return nil }
        if ["fetch", "search", "skill", "comment", "commit"].contains(lower) { return nil }
        // A server name is a single token with no space or dot.
        if !value.contains("."), !value.contains(" "), !value.contains("/"), !value.contains("#") {
            return nil
        }
        return value
    }

    // MARK: - Strings

    private static func humanize(_ key: String) -> String {
        var words = splitWords(key)
        let drop: Set<String> = ["get", "list", "create", "update", "delete", "post", "add", "open"]
        if words.count > 1, drop.contains(words[0].lowercased()) {
            words.removeFirst()
        }
        guard let first = words.first else { return "Tool" }
        let head = first.prefix(1).uppercased() + first.dropFirst().lowercased()
        let tail = words.dropFirst().map { $0.lowercased() }
        return ([head] + tail).joined(separator: " ")
    }

    private static func splitWords(_ key: String) -> [String] {
        let replaced = key.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        var words: [String] = []
        var current = ""
        for character in replaced {
            if character.isWhitespace {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }
            if character.isUppercase, !current.isEmpty, current.last?.isUppercase == false {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.filter { !$0.isEmpty }
    }

    private static func collapsing(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func matches(_ collapsed: String, _ options: [String]) -> Bool {
        options.contains { collapsing($0) == collapsed }
    }

    private static func contains(_ collapsed: String, _ needles: [String]) -> Bool {
        needles.contains { collapsed.contains(collapsing($0)) }
    }

    private static func compact(_ text: String, limit: Int = 56) -> String? {
        let value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !value.isEmpty else { return nil }
        guard value.count > limit else { return value }
        let head = value.prefix(limit)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }
}
