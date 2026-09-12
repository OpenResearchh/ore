import Foundation
import OreProtocol

/// What a permission card says, derived once so the chat pane, the assistant
/// window and the tests all read a request the same way.
///
/// The card used to show the tool's codename over the agent's own prose — the
/// word "Bash" above "Search arXiv API for PerCo SD paper" — and never the
/// command it was about to run. You cannot answer that: it names the machinery
/// and the motive but not the act. This splits a request into the two things a
/// person needs before they can say yes: the kind of action, and the exact
/// thing it acts on.
struct PermissionPresentation: Equatable {
    /// A standing grant the harness offered, shortened to fit on a button.
    struct Grant: Equatable {
        var label: String
        /// The untruncated offer, for the tooltip and for VoiceOver.
        var full: String
        var kind: PermissionSuggestion.Kind
        var raw: JSONValue
    }

    /// The kind of action, in plain words: "Run a command", "Write a file".
    var action: String
    /// The tool that will run it, when the action no longer says so. Kept for
    /// the audit read — which of ORE's tools, or which MCP server, is asking.
    var toolLabel: String?
    /// The literal thing being acted on: the command, the path, the URL. Shown
    /// monospaced, because it is text the agent wrote and not prose about it.
    var target: String?
    /// The agent's own account of why, kept only when it says more than the
    /// target already does.
    var detail: String?
    var grants: [Grant]

    /// Whether a one-line rendering of `target` necessarily hides part of it.
    ///
    /// This is the difference between approving a command and approving the
    /// first forty characters of one. `curl … | sh` and a `git status` with a
    /// destructive second line look identical once a row has clipped them,
    /// and unlike a *grant* label — where clipping only ever narrows what is
    /// being agreed to — clipping a command hides what will actually run.
    /// Surfaces that cannot show the whole thing must not offer Allow.
    var isAbbreviated: Bool
    /// Lines of `target` a single-line rendering does not show, for a
    /// "+N more lines" affordance.
    var hiddenLineCount: Int

    init(request: PermissionRequest) {
        let tool = request.toolName
        let subject = Self.subject(tool: tool, input: request.input)
        let named = Self.actionName(tool: tool)

        let summary = request.summary.flatMap(Self.nonEmpty)
        let shown = subject ?? summary

        if let named {
            action = named
            toolLabel = Self.toolLabel(tool)
        } else {
            // An unknown tool, or one from an MCP server. Nothing here is worth
            // guessing a verb for, so fall back to what the harness called it
            // and keep the summary in the target slot — no worse than before.
            action = request.displayName.flatMap(Self.nonEmpty)
                ?? Self.toolLabel(tool)
                ?? tool
            toolLabel = nil
        }
        target = shown

        // The agent's description repeats the target for several tools (Task
        // sends the same string as both). Only keep it when it adds something.
        if let summary, summary.caseInsensitiveCompare(shown ?? "") != .orderedSame {
            detail = summary
        } else {
            detail = nil
        }

        grants = request.suggestions.map {
            Grant(
                label: Self.clip($0.title, to: Self.grantLabelLimit),
                full: $0.title,
                kind: $0.kind,
                raw: $0.raw
            )
        }

        let lines = (shown ?? "").components(separatedBy: .newlines)
        hiddenLineCount = max(0, lines.count - 1)
        isAbbreviated = hiddenLineCount > 0
            || (shown?.count ?? 0) > Self.inlineTargetLimit
    }

    /// What a single row can show without clipping. Matches the width the
    /// HUD card and the notification body get.
    static let inlineTargetLimit = 80

    /// "+3 more lines", or nil when nothing is hidden.
    var hiddenLineSummary: String? {
        guard hiddenLineCount > 0 else { return nil }
        return "+\(hiddenLineCount) more line\(hiddenLineCount == 1 ? "" : "s")"
    }

    /// Long enough to carry a rule's shape, short enough that the button never
    /// wins a layout argument with Allow.
    static let grantLabelLimit = 44

    /// Collapses whitespace and clips from the end.
    ///
    /// Clipping the tail of a permission rule only ever hides detail that
    /// *narrows* it — `Bash(curl -s "https://…` covers no more than the label
    /// suggests — so the half the user reads is never an understatement of
    /// what they are granting. The full text stays on the tooltip.
    static func clip(_ text: String, to limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The plain-words verb for the tools ORE knows. `nil` means "no idea" and
    /// sends the caller down the fallback path.
    private static func actionName(tool: String) -> String? {
        switch tool {
        case "Bash": return "Run a command"
        case "BashOutput": return "Read command output"
        case "KillShell", "KillBash": return "Stop a running command"
        case "Read": return "Read a file"
        case "Write": return "Write a file"
        case "Edit", "MultiEdit": return "Edit a file"
        case "NotebookEdit": return "Edit a notebook"
        case "Glob": return "Find files"
        case "Grep": return "Search file contents"
        case "WebFetch": return "Fetch a web page"
        case "WebSearch": return "Search the web"
        case "Task", "Agent": return "Run a subagent"
        case "ExitPlanMode": return "Start on the plan"
        case "CreatePlan": return "Save the plan"
        default: return nil
        }
    }

    /// The thing the tool acts on, pulled straight out of the call.
    ///
    /// Bash deliberately reads `command` and not `description`: the description
    /// is the agent's summary of its own intent, and approving on intent alone
    /// is how a card ends up asking about "searching arXiv" when the thing that
    /// will actually run is a `curl` to a host nobody named.
    private static func subject(tool: String, input: JSONValue) -> String? {
        func field(_ key: String) -> String? { input[key]?.stringValue.flatMap(nonEmpty) }
        switch tool {
        case "Bash": return field("command")
        case "BashOutput", "KillShell", "KillBash": return field("shell_id") ?? field("bash_id")
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "LS", "Delete", "ReadLints":
            return field("file_path") ?? field("path") ?? field("notebook_path")
        case "Glob", "Grep":
            guard let pattern = field("pattern") else { return field("path") }
            guard let path = field("path") else { return pattern }
            return "\(pattern) in \(path)"
        case "WebFetch": return field("url")
        case "WebSearch": return field("query")
        case "Task", "Agent": return field("description")
        case "ExitPlanMode", "CreatePlan": return field("name") ?? field("title")
        default: return nil
        }
    }

    /// `mcp__ore__PostDiffComment` reads as "PostDiffComment · ore".
    private static func toolLabel(_ tool: String) -> String? {
        let parts = tool.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return nonEmpty(tool) }
        let name = parts.dropFirst(2).joined(separator: "__")
        return "\(name) · \(parts[1])"
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
