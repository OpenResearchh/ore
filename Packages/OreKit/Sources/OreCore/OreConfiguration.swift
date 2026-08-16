import Foundation
import OreProtocol

/// `ore.toml` — per-repository configuration, checked into the repository.
///
/// Checked in rather than stored in app preferences, deliberately: the setup a
/// project needs to run is a property of the project, and every teammate who
/// opens the repo should get it without being told. It's also the only place
/// that can legitimately name gitignored files to copy, because the repo is
/// what knows which ones matter.
public struct OreConfiguration: Sendable, Hashable, Codable {
    public struct Scripts: Sendable, Hashable, Codable {
        /// Run once after a worktree is created: install dependencies, prepare
        /// a database. The difference between a fresh worktree that works and
        /// one that doesn't.
        public var setup: String?
        /// The dev server or watcher, started with ⌘R.
        public var run: String?
        /// Run before archiving: stop containers, free ports.
        public var archive: String?

        public init(setup: String? = nil, run: String? = nil, archive: String? = nil) {
            self.setup = setup
            self.run = run
            self.archive = archive
        }
    }

    public var scripts: Scripts
    /// Gitignored files to copy from the main checkout into each new worktree.
    public var filesToCopy: [String]
    public var defaultHarness: HarnessKind?
    public var defaultModel: String?
    /// Branch name prefix; `ore` by default, so branches are recognizable.
    public var branchPrefix: String

    public init(
        scripts: Scripts = Scripts(),
        filesToCopy: [String] = [],
        defaultHarness: HarnessKind? = nil,
        defaultModel: String? = nil,
        branchPrefix: String = "ore"
    ) {
        self.scripts = scripts
        self.filesToCopy = filesToCopy
        self.defaultHarness = defaultHarness
        self.defaultModel = defaultModel
        self.branchPrefix = branchPrefix
    }

    public static let fileName = "ore.toml"

    /// Loads `ore.toml` from a repository. A missing or malformed file yields
    /// defaults: a config error must not stop someone opening their project.
    public static func load(repositoryPath: URL) -> OreConfiguration {
        let url = repositoryPath.appendingPathComponent(fileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return OreConfiguration()
        }
        return parse(text)
    }

    /// A deliberately small TOML reader.
    ///
    /// `ore.toml` uses tables, strings and string arrays and nothing else, so a
    /// full TOML dependency would be a lot of surface area for a file this
    /// shape. Anything unrecognized is skipped rather than rejected — a config
    /// written for a newer ORE must still open in an older one.
    public static func parse(_ text: String) -> OreConfiguration {
        var configuration = OreConfiguration()
        var table = ""

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)[...]

        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                table = String(trimmed.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                continue
            }

            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<separator]
                .trimmingCharacters(in: .whitespaces)
            var rawValue = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)

            // An array may run across several lines.
            if rawValue.hasPrefix("["), !rawValue.hasSuffix("]") {
                while let next = lines.first {
                    lines = lines.dropFirst()
                    rawValue += " " + next.trimmingCharacters(in: .whitespaces)
                    if rawValue.hasSuffix("]") { break }
                }
            }

            apply(table: table, key: key, rawValue: rawValue, to: &configuration)
        }
        return configuration
    }

    private static func apply(
        table: String,
        key: String,
        rawValue: String,
        to configuration: inout OreConfiguration
    ) {
        switch (table, key) {
        case ("scripts", "setup"): configuration.scripts.setup = unquote(rawValue)
        case ("scripts", "run"): configuration.scripts.run = unquote(rawValue)
        case ("scripts", "archive"): configuration.scripts.archive = unquote(rawValue)
        case ("files", "copy"): configuration.filesToCopy = parseArray(rawValue)
        case ("", "branch_prefix"), ("workspace", "branch_prefix"):
            configuration.branchPrefix = unquote(rawValue) ?? "ore"
        case ("agent", "harness"), ("", "harness"):
            configuration.defaultHarness = unquote(rawValue).flatMap(HarnessKind.init(rawValue:))
        case ("agent", "model"), ("", "model"):
            configuration.defaultModel = unquote(rawValue)
        default:
            break
        }
    }

    private static func unquote(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespaces)

        if text.hasPrefix("\"\"\""), text.hasSuffix("\"\"\""), text.count >= 6 {
            return String(text.dropFirst(3).dropLast(3))
        }

        // A quoted value ends at its closing quote; anything after it is a
        // comment. Scanning for the close rather than requiring the line to
        // end with a quote is what makes `setup = "make"  # builds` work,
        // while leaving a `#` *inside* the quotes alone.
        for quote in ["\"", "'"] where text.hasPrefix(quote) {
            var body = ""
            var escaped = false
            for character in text.dropFirst() {
                if escaped {
                    body.append(character)
                    escaped = false
                } else if character == "\\" {
                    body.append(character)
                    escaped = true
                } else if String(character) == quote {
                    return unescape(body)
                } else {
                    body.append(character)
                }
            }
            // Unterminated quote: take what we have rather than dropping it.
            return unescape(body)
        }

        // Bare value: a `#` starts a comment.
        var bare = text
        if let hash = bare.firstIndex(of: "#") {
            bare = String(bare[bare.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
        }
        return bare.isEmpty ? nil : bare
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func parseArray(_ value: String) -> [String] {
        var text = value.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("[") else { return unquote(text).map { [$0] } ?? [] }
        text = String(text.dropFirst())
        if text.hasSuffix("]") { text = String(text.dropLast()) }

        return text
            .split(separator: ",")
            .compactMap { unquote(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Serializes back to TOML, for the "create ore.toml" affordance.
    public func toTOML() -> String {
        var lines: [String] = [
            "# ORE workspace configuration — check this in so your team gets it too.",
            "",
        ]

        if branchPrefix != "ore" {
            lines.append("branch_prefix = \(quote(branchPrefix))")
            lines.append("")
        }

        if scripts.setup != nil || scripts.run != nil || scripts.archive != nil {
            lines.append("[scripts]")
            if let setup = scripts.setup { lines.append("setup = \(quote(setup))") }
            if let run = scripts.run { lines.append("run = \(quote(run))") }
            if let archive = scripts.archive { lines.append("archive = \(quote(archive))") }
            lines.append("")
        }

        if !filesToCopy.isEmpty {
            lines.append("[files]")
            lines.append("copy = [" + filesToCopy.map(quote).joined(separator: ", ") + "]")
            lines.append("")
        }

        if defaultHarness != nil || defaultModel != nil {
            lines.append("[agent]")
            if let harness = defaultHarness { lines.append("harness = \(quote(harness.rawValue))") }
            if let model = defaultModel { lines.append("model = \(quote(model))") }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
