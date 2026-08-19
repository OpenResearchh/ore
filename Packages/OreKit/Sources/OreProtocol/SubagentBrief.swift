import Foundation

/// What a spawned subagent was actually asked to do.
///
/// Every harness that delegates hands the child two things: a short label and
/// the real brief. Claude Code's `Task` tool calls them `description` — 3–5
/// words, by its own spec — and `prompt`. Cursor spells the same pair
/// differently. Codex has no subagent item type at all, so delegation can only
/// reach us as an MCP tool with whatever argument names that server chose.
///
/// The label alone tells a reader that *an* agent was created but never what
/// for, which is the one thing worth knowing when a turn fans out. So this is
/// the single place that agrees on which keys carry the brief, and turns that
/// brief into one line short enough to sit under a transcript row.
public enum SubagentBrief {
    /// Longest purpose line the transcript will show before eliding.
    private static let maximumLength = 160
    /// Below this a "line" is a fragment — a heading, a bare noun — and the
    /// terse label reads better than it does.
    private static let minimumLength = 12

    /// Canonical key → the aliases seen in the wild. First present wins.
    private static let aliases: [(canonical: String, others: [String])] = [
        ("prompt", ["instructions", "task", "goal"]),
        ("description", ["title", "summary", "name"]),
        ("subagent_type", ["subagentType", "agent_type", "agentType", "mode"]),
    ]

    /// Whether a tool call is a handoff to another agent.
    public static func isSubagentTool(_ name: String) -> Bool {
        let value = name.lowercased()
        if value == "task" || value == "agent" { return true }
        if value.contains("subagent") { return true }
        if value.hasSuffix("_task") || value.hasSuffix("_agent") { return true }
        return value == "delegate" || value == "spawn_agent"
    }

    /// Copies whichever alias a harness used onto the canonical key.
    ///
    /// Translators call this so the transcript can read `prompt` /
    /// `description` / `subagent_type` without knowing which CLI produced the
    /// row. The original keys are left in place — a permission response hands
    /// the input back to the CLI verbatim, so nothing may be removed.
    public static func normalized(_ input: JSONValue) -> JSONValue {
        guard var dictionary = input.objectValue else { return input }
        for (canonical, others) in aliases where dictionary[canonical]?.stringValue == nil {
            guard let value = others.lazy.compactMap({ dictionary[$0]?.stringValue })
                .first(where: { !$0.isEmpty })
            else { continue }
            dictionary[canonical] = .string(value)
        }
        return .object(dictionary)
    }

    public static func agentType(from input: JSONValue) -> String? {
        nonEmpty(input["subagent_type"]?.stringValue)
    }

    /// The full instruction handed to the child, for the expanded row.
    public static func brief(from input: JSONValue) -> String? {
        nonEmpty(input["prompt"]?.stringValue)
    }

    public static func label(from input: JSONValue) -> String? {
        nonEmpty(input["description"]?.stringValue)
    }

    /// One readable line saying why the agent exists.
    ///
    /// Taken verbatim from the brief rather than summarized by a model: it has
    /// to be on screen the instant the row appears, and the opening sentence of
    /// an agent prompt is almost always the ask. `distinctFrom` is the chip
    /// already on the row — when the brief only restates it, there is nothing
    /// to add and this returns nil rather than printing the same words twice.
    public static func purpose(from input: JSONValue, distinctFrom chip: String? = nil) -> String? {
        let candidate = brief(from: input).flatMap(openingSentence) ?? label(from: input)
        guard let line = candidate.flatMap(truncated), !line.isEmpty else { return nil }
        if let chip, restates(line, chip) { return nil }
        return line
    }

    // MARK: - Extraction

    private static func openingSentence(of prompt: String) -> String? {
        for raw in prompt.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = strippingScope(strippingMarkup(String(raw)))
            guard line.count >= minimumLength else { continue }
            return firstSentence(of: line)
        }
        return nil
    }

    /// Drops the markdown a prompt may open with and flattens inline emphasis,
    /// so a brief that starts with "## Goal" or "- Find the…" still reads as
    /// prose on one line.
    private static func strippingMarkup(_ line: String) -> String {
        var value = line.trimmingCharacters(in: .whitespaces)
        while let first = value.first, first == "#" || first == ">" {
            value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        for bullet in ["- ", "* ", "+ "] where value.hasPrefix(bullet) {
            value = String(value.dropFirst(bullet.count))
            break
        }
        // Ordered-list markers: "1. ", "12) ".
        let digits = value.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 2 {
            let rest = value.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                value = String(rest.dropFirst(2))
            }
        }
        value = value
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        return collapsingWhitespace(value)
    }

    /// Removes a leading "In this repo (/long/path)," clause.
    ///
    /// Prompts written for a subagent routinely open by telling it where to
    /// work. The reader of the transcript already knows — they are looking at
    /// that workspace — so the clause costs a line's worth of space and says
    /// nothing.
    private static func strippingScope(_ line: String) -> String {
        guard line.lowercased().hasPrefix("in ") else { return line }
        let head = line.prefix(96)
        guard let comma = head.firstIndex(of: ",") else { return line }
        let clause = line[..<comma].lowercased()
        guard clause.contains("/") || clause.contains("repo") || clause.contains("codebase")
        else { return line }
        let rest = line[line.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        guard rest.count >= minimumLength else { return line }
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    /// The first sentence, ignoring boundaries too early to be one — "e.g." and
    /// friends end a clause, not the ask.
    private static func firstSentence(of line: String) -> String {
        var index = line.startIndex
        while let boundary = line[index...].firstIndex(where: { $0 == "." || $0 == "?" || $0 == "!" }) {
            let after = line.index(after: boundary)
            let sentence = String(line[..<after])
            if after == line.endIndex { return sentence }
            let isBreak = line[after] == " "
            if isBreak, sentence.count >= 24 { return sentence }
            index = after
        }
        return line
    }

    private static func truncated(_ line: String) -> String? {
        let value = collapsingWhitespace(line)
        guard !value.isEmpty else { return nil }
        guard value.count > maximumLength else { return value }
        let head = value.prefix(maximumLength)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Whether the purpose line only says what the chip already said.
    private static func restates(_ line: String, _ chip: String) -> Bool {
        let a = comparable(line)
        let b = comparable(chip)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    private static func comparable(_ text: String) -> String {
        collapsingWhitespace(text)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }
}
