import Foundation

/// What a fetch or web-search tool is acting on.
///
/// Claude Code spells this `WebFetch`/`WebSearch` with `url`/`query`. Cursor
/// uses `webfetch`/`websearch` and sometimes `targetUrl`. Codex has no
/// `webFetch` item — search *and* opening a page arrive as `webSearch`, with
/// the URL nested under `action` for `open_page` / `find_in_page`. MCP servers
/// add another layer: the visible name is the server, and the URL sits in
/// `arguments` under `url`, `urls`, `href`, or a JSON string.
///
/// The transcript chip only needs a verb and a subject, so this is the one
/// place that agrees on which keys carry them. Translators copy the canonical
/// `url` / `query` onto the tool input; the UI reads the same keys without
/// knowing which CLI produced the row.
public struct ToolWebActivity: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case fetch
        case search
    }

    public var kind: Kind
    /// The URL or query, as the harness sent it. Nil when the call is clearly
    /// a web tool but the payload has not named a target yet.
    public var subject: String?

    public init(kind: Kind, subject: String?) {
        self.kind = kind
        self.subject = Self.nonEmpty(subject)
    }

    /// Host + path, no scheme — short enough to sit on a thinking chip.
    public var chipLabel: String? {
        guard let subject else { return nil }
        switch kind {
        case .fetch: return Self.compactURL(subject)
        case .search: return Self.compactQuery(subject)
        }
    }

    /// Whether this tool name is a web fetch or web search, regardless of args.
    public static func classify(
        tool: String,
        input: JSONValue?,
        fallback: String? = nil
    ) -> ToolWebActivity? {
        let key = toolKey(tool)
        let looksFetch = isFetchName(key)
        let looksSearch = isSearchName(key)
        guard looksFetch || looksSearch else { return nil }

        let payload = unwrapped(input)
        let url = url(from: payload)
        let query = query(from: payload)
        let opensPage = actionType(from: payload).map(isPageAction) ?? false
        let fallbackSubject = usableFallback(fallback, tool: tool)

        if looksFetch || opensPage {
            // Cursor's `web` tool maps to WebFetch; when the payload is only
            // a query it is a search, not a page fetch.
            if !opensPage, url == nil, query != nil {
                return ToolWebActivity(kind: .search, subject: query ?? fallbackSubject)
            }
            return ToolWebActivity(kind: .fetch, subject: url ?? fallbackSubject)
        }
        // Codex (and some MCP browsers) reuse the search item to open a page.
        // A URL with no query is a fetch even when the tool is named webSearch.
        if url != nil, query == nil {
            return ToolWebActivity(kind: .fetch, subject: url ?? fallbackSubject)
        }
        return ToolWebActivity(kind: .search, subject: query ?? url ?? fallbackSubject)
    }

    /// Copies `url` / `query` onto the canonical keys so the transcript can
    /// read one shape. Original keys stay — a permission response hands the
    /// input back to the CLI verbatim.
    public static func normalized(_ input: JSONValue) -> JSONValue {
        let payload = unwrapped(input) ?? input
        guard var dictionary = payload.objectValue else { return payload }
        if nonEmpty(dictionary["url"]?.stringValue) == nil, let url = url(from: payload) {
            dictionary["url"] = .string(url)
        }
        if nonEmpty(dictionary["query"]?.stringValue) == nil, let query = query(from: payload) {
            dictionary["query"] = .string(query)
        }
        return .object(dictionary)
    }

    public static func url(from input: JSONValue?) -> String? {
        let payload = unwrapped(input)
        return firstString(in: payload, keys: urlKeys)
            ?? string(fromArray: payload?["urls"] ?? payload?["links"])
    }

    public static func query(from input: JSONValue?) -> String? {
        firstString(in: unwrapped(input), keys: queryKeys)
    }

    /// `https://www.github.com/org/repo` → `github.com/org/repo`.
    public static func compactURL(_ raw: String, limit: Int = 56) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        for scheme in ["https://", "http://"] where value.lowercased().hasPrefix(scheme) {
            value = String(value.dropFirst(scheme.count))
        }
        if value.lowercased().hasPrefix("www.") {
            value = String(value.dropFirst(4))
        }
        if value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        guard !value.isEmpty else { return nil }
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 1)) + "…"
    }

    public static func compactQuery(_ raw: String, limit: Int = 56) -> String? {
        let value = collapsingWhitespace(raw)
        guard !value.isEmpty else { return nil }
        guard value.count > limit else { return value }
        let head = value.prefix(limit)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The host a spoken line can name: "docs.python.org", not the path.
    public static func spokenHost(_ raw: String) -> String? {
        let compact = compactURL(raw, limit: 80) ?? raw
        let host = compact.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init)
        return nonEmpty(host)
    }

    // MARK: - Names

    /// Last path of an MCP- or namespaced tool: `mcp__exa__web_fetch` → `web_fetch`.
    public static func toolKey(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let mcpParts = value.split(separator: "__", omittingEmptySubsequences: true)
        if mcpParts.count >= 3 {
            value = mcpParts.dropFirst(2).joined(separator: "__")
        } else if value.contains(":"),
                  let colon = value.split(separator: ":", omittingEmptySubsequences: true).last {
            value = String(colon)
        } else if value.contains("/"),
                  let slash = value.split(separator: "/", omittingEmptySubsequences: true).last {
            value = String(slash)
        }
        return value.lowercased()
    }

    public static func isFetchName(_ key: String) -> Bool {
        let value = key.lowercased()
        if value.contains("search") && !value.contains("fetch") { return false }
        if value.contains("fetch") { return true }
        if value.contains("browse") || value.contains("browser") {
            // Page-level fetch/open, not clicks, screenshots, or DOM probes.
            return value.contains("url") || value.contains("page")
                || value.contains("navigate") || value.contains("open")
                || value.contains("fetch") || value.contains("read")
        }
        if value.contains("open_page") || value.contains("openpage") { return true }
        if value.contains("open_url") || value.contains("openurl") { return true }
        if value.contains("read_url") || value.contains("readurl") { return true }
        if value == "web" || value.hasSuffix(".web") { return true }
        if value.contains("http_get") || value.contains("httpget") { return true }
        return false
    }

    public static func isSearchName(_ key: String) -> Bool {
        let value = key.lowercased()
        if value.contains("websearch") || value.contains("web_search") { return true }
        if value.contains("search") && (value.contains("web") || value.contains("internet")) {
            return true
        }
        return false
    }

    // MARK: - Extraction

    private static let urlKeys = [
        "url", "uri", "href", "link",
        "target_url", "targetUrl", "targetURL",
        "page_url", "pageUrl", "pageURL",
        "website", "web_url", "webUrl",
        "location", "address",
    ]

    private static let queryKeys = [
        "query", "q", "search", "search_query", "searchQuery",
        "keywords", "question",
    ]

    private static let nestedKeys = [
        "action", "request", "params", "arguments", "input", "data", "payload",
    ]

    /// Arguments sometimes arrive as a JSON string rather than an object.
    public static func unwrapped(_ input: JSONValue?) -> JSONValue? {
        guard let input else { return nil }
        if input.objectValue != nil { return input }
        if let items = input.arrayValue {
            return items.first { $0.objectValue != nil } ?? input
        }
        guard let raw = input.stringValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return parsed
    }

    private static func actionType(from input: JSONValue?) -> String? {
        nonEmpty(input?["action"]?["type"]?.stringValue)
            ?? nonEmpty(input?["actionType"]?.stringValue)
    }

    private static func isPageAction(_ type: String) -> Bool {
        let value = type.lowercased()
        return value == "open_page" || value == "openpage" || value == "open"
            || value == "find_in_page" || value == "findinpage"
            || value == "fetch" || value == "navigate"
    }

    private static func firstString(
        in input: JSONValue?,
        keys: [String],
        depth: Int = 0
    ) -> String? {
        guard let input, depth < 4 else { return nil }
        let payload = unwrapped(input) ?? input
        if let object = payload.objectValue {
            for key in keys {
                if let value = nonEmpty(object[key]?.stringValue) {
                    return value
                }
                if let nested = string(fromArray: object[key]) {
                    return nested
                }
            }
            for key in nestedKeys {
                if let child = firstString(in: object[key], keys: keys, depth: depth + 1) {
                    return child
                }
            }
            return nil
        }
        return string(fromArray: payload)
    }

    private static func string(fromArray value: JSONValue?) -> String? {
        guard let value else { return nil }
        if value.stringValue != nil,
           let unwrapped = unwrapped(value),
           unwrapped.objectValue != nil || unwrapped.arrayValue != nil,
           let text = firstString(in: unwrapped, keys: urlKeys + queryKeys, depth: 3) {
            return text
        }
        if let text = nonEmpty(value.stringValue) { return text }
        guard let items = value.arrayValue else { return nil }
        for item in items {
            if item.stringValue != nil,
               let unwrapped = unwrapped(item),
               unwrapped.objectValue != nil || unwrapped.arrayValue != nil,
               let text = firstString(in: unwrapped, keys: urlKeys + queryKeys, depth: 3) {
                return text
            }
            if let text = nonEmpty(item.stringValue) { return text }
            if let text = firstString(in: item, keys: urlKeys + queryKeys, depth: 3) {
                return text
            }
        }
        return nil
    }

    private static func looksLikeURL(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("https://") || text.hasPrefix("http://") || text.hasPrefix("www.")
    }

    /// Row text is often the tool name (`WebFetch`) or the MCP server (`codex`).
    /// Those are not a URL or a query, and showing them as the chip is how a
    /// Fetch row ends up with a pill that says nothing.
    private static func usableFallback(_ text: String?, tool: String) -> String? {
        guard let value = nonEmpty(text) else { return nil }
        let lower = value.lowercased()
        if lower == tool.lowercased() || lower == toolKey(tool) { return nil }
        if ["fetch", "search", "web", "webfetch", "websearch", "web fetch", "web search"]
            .contains(lower) {
            return nil
        }
        if looksLikeURL(value) { return value }
        // A server name is a single token with no space or dot.
        if !value.contains("."), !value.contains(" "), !value.contains("/") {
            return nil
        }
        return value
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }
}
