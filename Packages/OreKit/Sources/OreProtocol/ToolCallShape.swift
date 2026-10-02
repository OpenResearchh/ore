import Foundation

/// Harnesses disagree on what a Read is called and which JSON key holds the
/// path. Claude says `Read` / `file_path`; Cursor maps at its translator;
/// Antigravity says `view_file` / `AbsolutePath` and `run_command` /
/// `CommandLine`. The transcript, narration, and permission card all need one
/// shape, so this is the place that agrees.
public enum ToolCallShape {
    /// Claude-style name the rest of ORE already knows how to draw.
    /// Unmapped names are returned as-is so a later chip can still humanize
    /// them rather than inventing a Claude verb that is a lie.
    public static func canonicalName(_ tool: String) -> String {
        switch collapsing(tool) {
        case "viewfile", "readfile": return "Read"
        case "writetofile", "writefile", "createfile": return "Write"
        case "replacefilecontent", "multireplacefilecontent", "sedfile", "editfile":
            return "Edit"
        case "notebookedit", "notebookexecution": return "NotebookEdit"
        case "runcommand": return "Bash"
        case "commandstatus", "sendcommandinput": return "BashOutput"
        case "grepsearch", "searchdirectory", "codesearch": return "Grep"
        case "findbyname", "findfile": return "Glob"
        case "listdir", "listdirectory": return "LS"
        case "searchweb": return "WebSearch"
        case "readurlcontent", "openbrowserurl", "openurl", "readbrowserpage":
            return "WebFetch"
        case "definesubagent", "invokesubagent", "managesubagents",
             "browsersubagent":
            return "Task"
        case "skilllookup": return "Skill"
        case "deletefile": return "Delete"
        case "managetask": return "TodoWrite"
        case "wait", "wait5seconds": return "Wait"
        case "generateimage": return "GenerateImage"
        case "capturebrowserscreenshot": return "Screenshot"
        case "deleteknowledge": return "Memory"
        case "readresource", "listresources": return "Resource"
        case "manageinbox": return "Inbox"
        case "runworkflow": return "Workflow"
        case "schedule": return "Schedule"
        case "sendmessage": return "Message"
        case "askquestion": return "Question"
        default: return tool
        }
    }

    /// Copies harness-specific keys onto `file_path` / `command` / `pattern`
    /// and so on. Original keys stay — a permission response hands the input
    /// back to the CLI verbatim.
    public static func normalized(_ input: JSONValue, tool: String) -> JSONValue {
        let payload = ToolWebActivity.unwrapped(input) ?? input
        guard var dictionary = payload.objectValue else { return payload }
        mergeNestedArguments(into: &dictionary)
        copy(["AbsolutePath", "absolute_path", "absolutePath", "Path", "FilePath",
              "filePath", "TargetFile", "target_file", "targetFile",
              "AbsoluteFilePath", "TargetDirectory", "target_directory",
              "targetDirectory", "DirectoryPath", "directory_path",
              "directoryPath", "Directory"],
             onto: "file_path", in: &dictionary)
        if dictionary["path"] == nil, let path = dictionary["file_path"] {
            dictionary["path"] = path
        }
        copy(["CommandLine", "command_line", "commandLine", "Command", "cmd"],
             onto: "command", in: &dictionary)
        copy(["Pattern", "GlobPattern", "glob_pattern", "globPattern",
              "FilePattern", "file_pattern"],
             onto: "pattern", in: &dictionary)
        copy(["Query", "SearchQuery", "search_query", "searchQuery", "q"],
             onto: "query", in: &dictionary)
        copy(["Url", "URL", "Uri", "URI", "TargetUrl", "target_url", "targetUrl",
              "PageUrl", "page_url", "pageUrl"],
             onto: "url", in: &dictionary)
        copy(["Contents", "Content", "Code", "contents"],
             onto: "content", in: &dictionary)
        copy(["OldString", "oldString", "old_str"],
             onto: "old_string", in: &dictionary)
        copy(["NewString", "newString", "Replacement", "ReplacementContent",
              "replacement"],
             onto: "new_string", in: &dictionary)
        copy(["Prompt", "InitialPrompt", "initial_prompt", "Instruction",
              "instructions", "Task"],
             onto: "prompt", in: &dictionary)
        copy(["Description", "Name", "Title", "Role", "Summary"],
             onto: "description", in: &dictionary)
        copy(["Selector", "selector", "Element", "element",
              "ElementDescription", "element_description"],
             onto: "selector", in: &dictionary)
        copy(["WaitMs", "wait_ms", "waitMs", "DurationMs", "duration_ms"],
             onto: "wait_ms", in: &dictionary)
        copy(["ServerName", "server_name", "serverName", "McpServer",
              "mcp_server", "Server"],
             onto: "server", in: &dictionary)
        copy(["ToolName", "tool_name", "mcp_tool", "McpTool"],
             onto: "mcp_tool", in: &dictionary)
        copy(["Javascript", "JavaScript", "Script", "script", "Code"],
             onto: "script", in: &dictionary)
        copy(["Key", "key", "Keys"],
             onto: "key", in: &dictionary)
        copy(["Text", "text", "Value", "InputText", "input_text", "TypedText"],
             onto: "text", in: &dictionary)
        copy(["Question", "question"],
             onto: "question", in: &dictionary)

        let name = canonicalName(tool)
        switch name {
        case "Grep", "Glob":
            if dictionary["pattern"] == nil {
                copy(["Name", "name"], onto: "pattern", in: &dictionary)
            }
            if dictionary["pattern"] == nil, let query = dictionary["query"] {
                dictionary["pattern"] = query
            }
        case "WebSearch":
            if dictionary["query"] == nil, let pattern = dictionary["pattern"] {
                dictionary["query"] = pattern
            }
        case "Task":
            return SubagentBrief.normalized(.object(dictionary))
        default:
            break
        }
        return .object(dictionary)
    }

    /// Path a file-shaped call acts on, after aliasing.
    public static func filePath(in input: JSONValue?) -> String? {
        guard let input else { return nil }
        let payload = normalized(input, tool: "Read")
        for key in ["file_path", "path"] {
            if let value = nonEmpty(payload[key]?.stringValue) { return value }
        }
        return payload[0]?["path"]?.stringValue.flatMap(nonEmpty)
    }

    /// Antigravity failed `view_file`s bury the path in a cortex permission
    /// dump: `… invalid_args failed to read file: stat /tmp/a.swift: no such
    /// file or directory`. The chip still needs the file name.
    public static func filePath(inError text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if let path = match(#"stat (/[^:\n]+)"#, in: text) { return path }
        if let path = match(#"failed to read file:\s+(/[^:\n]+)"#, in: text) {
            return path
        }
        return match(#"(/[^\s:]+\.\w{1,8})"#, in: text)
    }

    /// Drops the `declaring permissions: cortex tool view_file: convert…`
    /// preamble so expanding a failed Read is the Unix reason, not the CLI's
    /// internal conversion log.
    public static func sanitizedError(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let lower = trimmed.lowercased()
        for marker in ["failed to read file:", "failed to write file:", "failed to edit file:"] {
            if let range = trimmed.range(of: marker, options: .caseInsensitive) {
                var rest = String(trimmed[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if rest.lowercased().hasPrefix("stat ") {
                    rest = String(rest.dropFirst(5))
                }
                if let path = filePath(inError: trimmed),
                   lower.contains("no such file") {
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    return "No such file or directory: \(name)"
                }
                return rest
            }
        }
        if lower.contains("declaring permissions") || lower.contains("cortex tool") {
            if let last = trimmed.split(separator: ":").last.map(String.init) {
                let value = last.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return trimmed
    }

    /// Subject a thinking chip should name, pulled from the harness payload
    /// rather than the tool's snake_case identifier.
    public static func chipSubject(
        tool: String,
        input: JSONValue?,
        fallback: String? = nil
    ) -> String? {
        let payload = input.map { normalized($0, tool: tool) }
        if let path = filePath(in: payload) {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        if let command = nonEmpty(payload?["command"]?.stringValue) {
            return compact(firstLine(command), limit: 64)
        }
        if let pattern = nonEmpty(payload?["pattern"]?.stringValue) {
            return compact(pattern, limit: 64)
        }
        if let query = nonEmpty(payload?["query"]?.stringValue) {
            return compact(query, limit: 64)
        }
        if let url = nonEmpty(payload?["url"]?.stringValue) {
            return ToolWebActivity.compactURL(url) ?? compact(url, limit: 56)
        }
        if let selector = nonEmpty(payload?["selector"]?.stringValue) {
            return compact(selector, limit: 56)
        }
        if let prompt = nonEmpty(payload?["prompt"]?.stringValue) {
            return compact(prompt, limit: 64)
        }
        if let question = nonEmpty(payload?["question"]?.stringValue) {
            return compact(question, limit: 64)
        }
        if let key = nonEmpty(payload?["key"]?.stringValue) {
            return compact(key, limit: 32)
        }
        if let text = nonEmpty(payload?["text"]?.stringValue) {
            return compact(text, limit: 56)
        }
        if let script = nonEmpty(payload?["script"]?.stringValue) {
            return compact(firstLine(script), limit: 56)
        }
        if let mcp = nonEmpty(payload?["mcp_tool"]?.stringValue) {
            if let server = nonEmpty(payload?["server"]?.stringValue) {
                return "\(mcp) · \(server)"
            }
            return mcp
        }
        if let wait = waitLabel(from: payload, tool: tool) { return wait }
        if let pixels = pixelLabel(from: payload) { return pixels }
        if let description = nonEmpty(payload?["description"]?.stringValue),
           !looksLikeToolCodename(description) {
            return compact(description, limit: 64)
        }
        return usableFallback(fallback, tool: tool)
    }

    /// Short verb for a chip when the rest of ORE has no dedicated matcher.
    public static func chipTitle(_ tool: String) -> String {
        switch canonicalName(tool) {
        case "Read": return "Read"
        case "Write": return "Write"
        case "Edit", "NotebookEdit": return "Edit"
        case "Bash": return "Bash"
        case "BashOutput": return "Output"
        case "Grep", "WebSearch": return "Search"
        case "Glob": return "Find"
        case "LS": return "List"
        case "WebFetch": return "Fetch"
        case "Task": return "Subagent"
        case "Skill": return "Skill"
        case "Delete": return "Delete"
        case "TodoWrite": return "Updated plan"
        case "Wait": return "Wait"
        case "GenerateImage": return "Image"
        case "Screenshot": return "Screenshot"
        case "Memory": return "Memory"
        case "Resource": return "Resource"
        case "Inbox": return "Inbox"
        case "Workflow": return "Workflow"
        case "Schedule": return "Schedule"
        case "Message": return "Message"
        case "Question": return "Question"
        default:
            return humanTitle(tool, dropping: ["browser"])
        }
    }

    /// Canonical Claude-style name, or `mcp__server__tool` when Antigravity
    /// wraps an MCP call as `call_mcp_tool`.
    public static func resolvedName(_ tool: String, input: JSONValue) -> String {
        if collapsing(tool) == "callmcptool",
           let mcp = namespacedMCPName(from: input) {
            return mcp
        }
        return canonicalName(tool)
    }

    /// `call_mcp_tool` plus ServerName/ToolName → `mcp__server__tool`, so the
    /// existing MCP chip path can name the actual call.
    public static func namespacedMCPName(from input: JSONValue) -> String? {
        let payload = normalized(input, tool: "call_mcp_tool")
        let server = nonEmpty(payload["server"]?.stringValue)
        let tool = nonEmpty(payload["mcp_tool"]?.stringValue)
            ?? nonEmpty(payload["name"]?.stringValue)
        guard let server, let tool else { return nil }
        return "mcp__\(server)__\(tool)"
    }

    public static func isBrowser(_ tool: String) -> Bool {
        let key = collapsing(tool)
        if ["openbrowserurl", "readbrowserpage", "readurlcontent"].contains(key) {
            return false
        }
        return key.contains("browser")
    }

    public static func isWait(_ tool: String) -> Bool {
        collapsing(tool).hasPrefix("wait")
            || canonicalName(tool) == "Wait"
    }

    public static func isGenerateImage(_ tool: String) -> Bool {
        collapsing(tool).contains("generateimage")
            || canonicalName(tool) == "GenerateImage"
    }

    /// Built-in harness tools already have their own chip. Matching them as
    /// MCP would steal Glob/Grep/Bash and turn them into a puzzle piece.
    public static func isHarnessPrimitive(_ tool: String) -> Bool {
        if isBrowser(tool) { return true }
        switch collapsing(canonicalName(tool)) {
        case "read", "write", "edit", "multiedit", "notebookedit",
             "bash", "bashoutput", "killshell", "killbash",
             "grep", "glob", "ls", "delete", "readlints",
             "webfetch", "websearch", "task", "agent",
             "todowrite", "todoread", "createplan", "exitplanmode",
             "wait", "generateimage", "screenshot", "memory",
             "resource", "inbox", "workflow", "schedule", "message", "question":
            return true
        default:
            break
        }
        switch collapsing(tool) {
        case "callmcptool", "askpermission", "askcustompermission",
             "listpermissions", "finish", "compaction", "error",
             "shell", "list", "remove":
            return true
        default:
            return false
        }
    }

    /// Internal bookkeeping Antigravity emits as a "tool" — not worth a chip.
    public static func isHidden(_ tool: String) -> Bool {
        switch collapsing(tool) {
        case "finish", "compaction", "error": return true
        default: return false
        }
    }

    public static func looksLikeToolCodename(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        return value.contains("_")
            && !value.contains(".")
            && !value.contains(" ")
            && !value.contains("/")
    }

    // MARK: - Internals

    private static func mergeNestedArguments(into dictionary: inout [String: JSONValue]) {
        let nested = dictionary["Arguments"]?.objectValue
            ?? dictionary["arguments"]?.objectValue
            ?? dictionary["params"]?.objectValue
        guard let nested else { return }
        for (key, value) in nested where dictionary[key] == nil {
            dictionary[key] = value
        }
    }

    private static func copy(
        _ aliases: [String],
        onto canonical: String,
        in dictionary: inout [String: JSONValue]
    ) {
        if nonEmpty(dictionary[canonical]?.stringValue) != nil { return }
        if dictionary[canonical]?.intValue != nil { return }
        for key in aliases {
            if let value = nonEmpty(dictionary[key]?.stringValue) {
                dictionary[canonical] = .string(value)
                return
            }
            if let number = dictionary[key]?.intValue {
                dictionary[canonical] = .integer(number)
                return
            }
        }
    }

    public static func waitLabel(from input: JSONValue?, tool: String) -> String? {
        let payload = input.map { normalized($0, tool: tool) }
        if let ms = payload?["wait_ms"]?.intValue
            ?? payload?["WaitMs"]?.intValue
            ?? payload?["duration_seconds"]?.intValue.map({ $0 * 1000 }) {
            if ms >= 1000 { return "\(ms / 1000)s" }
            if ms > 0 { return "\(ms)ms" }
        }
        if collapsing(tool) == "wait5seconds" { return "5s" }
        return nil
    }

    private static func pixelLabel(from input: JSONValue?) -> String? {
        let x = input?["PixelX"]?.intValue
            ?? input?["pixel_x"]?.intValue
            ?? input?["pixelX"]?.intValue
        let y = input?["PixelY"]?.intValue
            ?? input?["pixel_y"]?.intValue
            ?? input?["pixelY"]?.intValue
        guard let x, let y else { return nil }
        return "\(x), \(y)"
    }

    private static func humanTitle(_ tool: String, dropping prefixes: [String]) -> String {
        var words = splitWords(ToolWebActivity.toolKey(tool))
        if let first = words.first, prefixes.contains(first.lowercased()), words.count > 1 {
            words.removeFirst()
        }
        guard let head = words.first else { return "Tool" }
        let title = head.prefix(1).uppercased() + head.dropFirst().lowercased()
        let tail = words.dropFirst().map { $0.lowercased() }
        return ([title] + tail).joined(separator: " ")
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

    private static func collapsing(_ tool: String) -> String {
        ToolWebActivity.toolKey(tool)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
    }

    private static func compact(_ text: String, limit: Int) -> String {
        let value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard value.count > limit else { return value }
        let head = value.prefix(limit)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func usableFallback(_ text: String?, tool: String) -> String? {
        guard let value = nonEmpty(text) else { return nil }
        if looksLikeToolCodename(value) { return nil }
        if value.caseInsensitiveCompare(tool) == .orderedSame { return nil }
        if value.caseInsensitiveCompare(canonicalName(tool)) == .orderedSame { return nil }
        if value.caseInsensitiveCompare(chipTitle(tool)) == .orderedSame { return nil }
        return compact(value, limit: 64)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[capture])
    }
}
