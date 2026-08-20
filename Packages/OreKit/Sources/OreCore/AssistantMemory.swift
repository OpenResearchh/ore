import Foundation

/// File-backed memory for the assistant home (`~/ore/assistant`).
///
/// The model owns the contents; this is the sandbox and the index hygiene so
/// a Write never wanders outside `memory/` and `MEMORY.md` stays current.
public enum AssistantMemory {
    public static let indexName = "MEMORY.md"
    public static let directoryName = "memory"

    /// Relative paths the assistant is allowed to read or write.
    public static func list(home: URL) -> [(path: String, title: String)] {
        var files: [(String, String)] = [(indexName, "Memory index")]
        let directory = home.appendingPathComponent(directoryName, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension.lowercased() == "md" {
            let path = "\(directoryName)/\(url.lastPathComponent)"
            files.append((path, title(of: url) ?? url.deletingPathExtension().lastPathComponent))
        }
        return files
    }

    public static func readIndex(home: URL) -> String {
        let url = home.appendingPathComponent(indexName)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    public static func read(home: URL, path: String) throws -> String {
        let url = try resolvedURL(home: home, path: path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    public static func write(
        home: URL,
        path: String,
        contents: String,
        append: Bool
    ) throws {
        let url = try resolvedURL(home: home, path: path, creating: true)
        if append, FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            var extra = contents
            if !extra.hasPrefix("\n") { extra = "\n" + extra }
            try handle.write(contentsOf: Data(extra.utf8))
        } else {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        if path != indexName {
            try refreshIndexLine(home: home, path: path)
        }
    }

    public static func listingText(home: URL) -> String {
        let files = list(home: home)
        guard !files.isEmpty else { return "No memory files yet." }
        return files.map { "- \($0.path) — \($0.title)" }.joined(separator: "\n")
    }

    // MARK: - Sandbox

    /// `MEMORY.md` or `memory/<file>.md`. Anything else is refused.
    static func resolvedURL(home: URL, path: String, creating: Bool = false) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed == indexName {
            return home.appendingPathComponent(indexName)
        }
        let prefix = "\(directoryName)/"
        guard trimmed.hasPrefix(prefix),
              trimmed.lowercased().hasSuffix(".md"),
              !trimmed.contains(".."),
              trimmed.dropFirst(prefix.count).contains(where: { $0 == "/" }) == false
        else {
            throw AssistantMemoryError.forbidden(path)
        }
        let directory = home.appendingPathComponent(directoryName, isDirectory: true)
        if creating {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent(String(trimmed.dropFirst(prefix.count)))
    }

    private static func refreshIndexLine(home: URL, path: String) throws {
        let indexURL = home.appendingPathComponent(indexName)
        var body = (try? String(contentsOf: indexURL, encoding: .utf8)) ?? "# Memory index\n\n"
        let needle = "](\(path))"
        if body.contains(needle) { return }
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        if !body.hasSuffix("\n") { body += "\n" }
        body += "- [\(name)](\(path))\n"
        try body.write(to: indexURL, atomically: true, encoding: .utf8)
    }

    private static func title(of url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

enum AssistantMemoryError: Error, CustomStringConvertible {
    case forbidden(String)

    var description: String {
        switch self {
        case .forbidden(let path):
            "Memory path must be MEMORY.md or memory/<file>.md — not \(path)."
        }
    }
}
