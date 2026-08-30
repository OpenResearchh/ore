import Foundation

/// File-backed memory for the assistant home (`~/ore/assistant`).
///
/// The model owns the contents; this is the sandbox, the index hygiene so
/// `MEMORY.md` stays true, and the recall digest that puts the facts which
/// shape *every* answer in front of the model without costing it a tool call.
public enum AssistantMemory {
    public static let indexName = "MEMORY.md"
    public static let directoryName = "memory"

    /// A memory file may not grow past this. Two reasons, both about the
    /// prompt rather than the disk: a file the model appends to forever
    /// eventually crowds out everything else in the recall digest, and a
    /// runaway loop that writes on every turn should fail loudly and early
    /// rather than quietly fill the home.
    public static let maxFileBytes = 64 * 1024

    /// Files whose contents ride along in the system prompt, in this order.
    ///
    /// These are the facts that should colour every answer — how the user
    /// likes things done, how their projects depend on each other, what
    /// they are working on and why. Everything else stays behind
    /// `ReadMemory`: the assistant runs on a lean model, and a lean model
    /// that has to *choose* to look something up mostly doesn't. A
    /// preference the user stated last week and the assistant then ignored
    /// is indistinguishable, from their side, from never having recorded it.
    public static let recallPaths = [
        "\(directoryName)/preferences.md",
        "\(directoryName)/relations.md",
        "\(directoryName)/projects.md",
    ]

    /// How many characters of memory the system prompt will carry.
    public static let defaultRecallBudget = 8_000
    /// The index is the map to everything not recalled in full, so it gets a
    /// reserved share of the budget rather than competing for it.
    static let indexBudget = 3_000

    /// Relative paths the assistant is allowed to read or write.
    public static func list(home: URL) -> [(path: String, title: String)] {
        var files: [(String, String)] = [(indexName, "Memory index")]
        for url in topicFileURLs(home: home) {
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
        // Whether to append is decided by the file *existing*, never by its
        // measured size: a stat that fails returns zero bytes, and treating
        // that as "nothing there yet" would turn an append into a silent
        // truncating overwrite of the memory it was meant to add to.
        let extending = append && FileManager.default.fileExists(atPath: url.path)
        var extra = contents
        if extending, !extra.hasPrefix("\n") { extra = "\n" + extra }
        guard fileSize(at: url) + extra.utf8.count <= maxFileBytes else {
            throw AssistantMemoryError.tooLarge(path, maxFileBytes)
        }

        if extending {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(extra.utf8))
        } else {
            try extra.write(to: url, atomically: true, encoding: .utf8)
        }
        if path != indexName {
            try refreshIndex(home: home)
        }
    }

    /// Removes a topic file and the index line pointing at it.
    ///
    /// The prompt tells the assistant to retire facts that have gone stale
    /// rather than pile up contradictions; without this it could only ever
    /// overwrite a file with a tombstone, leaving the index advertising a
    /// topic that no longer has anything to say.
    ///
    /// Erasing is safe because it isn't final: the assistant home is a git
    /// repository, and `WorkspaceEngine.captureCheckpoint` snapshots the whole
    /// worktree into `refs/ore/ckpt/` before every turn — so a file deleted in
    /// one turn is still in the checkpoint taken at the start of it.
    public static func delete(home: URL, path: String) throws {
        let trimmed = normalized(path)
        guard trimmed != indexName else { throw AssistantMemoryError.protected(indexName) }
        let url = try resolvedURL(home: home, path: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AssistantMemoryError.missing(trimmed)
        }
        try FileManager.default.removeItem(at: url)
        try refreshIndex(home: home)
    }

    public static func listingText(home: URL) -> String {
        let files = list(home: home)
        guard !files.isEmpty else { return "No memory files yet." }
        return files.map { "- \($0.path) — \($0.title)" }.joined(separator: "\n")
    }

    // MARK: - Recall

    /// The memory block the assistant's system prompt carries: the index, plus
    /// the full text of the recall files that actually have something in them.
    ///
    /// A recall file still holding its seed is skipped: "Nothing recorded yet."
    /// spends prompt budget to say what the index already implies. The index
    /// itself is always carried when it exists, seeded or not — on a first-run
    /// home it is the one thing worth saying, because it names the topics the
    /// assistant is expected to fill in.
    public static func recallDigest(home: URL, budget: Int = defaultRecallBudget) -> String {
        var sections: [String] = []
        // Every section but the first also costs the "\n\n" it is joined with,
        // and each carries a header naming the file. Both are counted, so the
        // returned digest is never larger than the caller asked for.
        let joiner = 2
        var remaining = budget

        let index = readIndex(home: home).trimmingCharacters(in: .whitespacesAndNewlines)
        let indexHeader = "MEMORY.md — the index of everything you know:\n\n"
        let clippedIndex = clip(index, to: min(indexBudget, remaining) - indexHeader.count)
        if !clippedIndex.isEmpty {
            let section = indexHeader + clippedIndex
            remaining -= section.count
            sections.append(section)
        }

        for path in recallPaths {
            let header = "\(path):\n\n"
            // Not worth a section that would be all header and ellipsis.
            guard remaining - joiner - header.count > 80 else { break }
            guard let body = try? read(home: home, path: path) else { continue }
            let facts = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !facts.isEmpty, !isSeedOnly(facts) else { continue }
            let section = header + clip(facts, to: remaining - joiner - header.count)
            remaining -= section.count + joiner
            sections.append(section)
        }

        guard !sections.isEmpty else { return "" }
        return sections.joined(separator: "\n\n")
    }

    /// A file that still says only "Nothing recorded yet." holds no facts.
    /// Recalling it would spend prompt budget to tell the model something the
    /// index already implies.
    /// Only the file's own title is stripped, not every heading: a file whose
    /// facts are written as `## Uses Codex for Rust` is a file with facts in
    /// it, and dropping it from the digest would lose exactly the memory this
    /// is here to carry.
    static func isSeedOnly(_ text: String) -> Bool {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        while let first = lines.first,
              first.trimmingCharacters(in: .whitespaces).isEmpty
                  || first.trimmingCharacters(in: .whitespaces).hasPrefix("# ") {
            lines = lines.dropFirst()
        }
        let body = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return body.isEmpty || body == "nothing recorded yet."
    }

    /// Truncates on a line boundary and says so, because a fact cut mid-clause
    /// is worse than a fact the model knows to go and read in full.
    static func clip(_ text: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        let marker = "\n… (clipped — ReadMemory for the rest)"
        // Below the marker's own length there is no room to both truncate and
        // say so, and appending it anyway would return *more* than the caller
        // budgeted for — the one thing a budget must never do.
        guard limit > marker.count else { return String(text.prefix(limit)) }
        let room = limit - marker.count
        var head = String(text.prefix(room))
        if let lastBreak = head.lastIndex(of: "\n"), !head[head.startIndex..<lastBreak].isEmpty {
            head = String(head[head.startIndex..<lastBreak])
        }
        return head + marker
    }

    // MARK: - Sandbox

    /// `MEMORY.md` or `memory/<file>.md`. Anything else is refused.
    static func resolvedURL(home: URL, path: String, creating: Bool = false) throws -> URL {
        let trimmed = normalized(path)
        if trimmed == indexName {
            let url = home.appendingPathComponent(indexName)
            try assertInside(home: home, url: url)
            return url
        }
        let prefix = "\(directoryName)/"
        let name = String(trimmed.dropFirst(prefix.count))
        guard trimmed.hasPrefix(prefix),
              trimmed.lowercased().hasSuffix(".md"),
              !trimmed.contains(".."),
              // A leading dot hides the file from `list`, so a fact written
              // there would be invisible to every later session.
              !name.hasPrefix("."),
              name.count > 3,
              name.unicodeScalars.allSatisfy(safeNameScalars.contains)
        else {
            throw AssistantMemoryError.forbidden(path)
        }
        let directory = home.appendingPathComponent(directoryName, isDirectory: true)
        if creating {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let url = directory.appendingPathComponent(name)
        try assertInside(home: home, url: url)
        return url
    }

    /// Deliberately narrower than the filesystem allows. Every memory file is
    /// addressed from `MEMORY.md` as a markdown link, so a name containing
    /// `)`, a space, or anything needing percent-escaping would round-trip
    /// through the index as a *different* path — and the index reconciler
    /// would then re-add a line for it on every write, forever.
    private static let safeNameScalars: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.")
        return set
    }()

    /// The path rules above are about spelling; this is about where the bytes
    /// actually land. A symlink at `memory/notes.md` passes every spelling
    /// check and still reads and writes the user's dotfiles.
    private static func assertInside(home: URL, url: URL) throws {
        // Refused whatever it points at, including nothing: a dangling link
        // resolves to itself, so "is it inside the home" cannot be asked of it
        // honestly, and a link the assistant did not create is not a memory
        // file in any case.
        guard !isSymlink(at: url) else {
            throw AssistantMemoryError.forbidden(url.lastPathComponent)
        }
        let root = home.resolvingSymlinksInPath().standardizedFileURL.path
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            throw AssistantMemoryError.forbidden(url.lastPathComponent)
        }
    }

    private static func normalized(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Index hygiene

    /// Reconciles `MEMORY.md` with what is actually on disk: adds a line for
    /// every topic file that has none, drops lines pointing at files that are
    /// gone, and leaves everything else — prose, ordering, and the hand-written
    /// hook after each link — exactly as the assistant wrote it.
    ///
    /// Rewriting the whole index instead would be simpler and much worse: the
    /// hooks are the part a future session reads to decide what to open, and
    /// they are the one thing this code cannot regenerate.
    ///
    /// The two questions are deliberately asymmetric. *Is this file already
    /// linked?* is asked generously — any mention at all counts, so a file
    /// named in a sentence never gets a duplicate line. *May this line be
    /// removed?* is asked strictly — only a line that is nothing but one entry
    /// qualifies, so a sentence mentioning a file that does not exist yet, or
    /// a line linking two files, is left alone rather than deleted along with
    /// the prose around it.
    static func refreshIndex(home: URL) throws {
        let directory = home.appendingPathComponent(directoryName, isDirectory: true)
        // Without a memory directory there is nothing to reconcile against,
        // and treating that as "every file is gone" would empty a good index.
        guard FileManager.default.fileExists(atPath: directory.path) else { return }

        let onDisk = topicFileURLs(home: home)
        // Case-folded: the assistant may spell a path in either case and most
        // Mac volumes will resolve it, so an exact compare would read a live
        // entry as dangling and delete the hook next to it.
        let present = Set(onDisk.map { "\(directoryName)/\($0.lastPathComponent)".lowercased() })

        let indexURL = home.appendingPathComponent(indexName)
        let body = (try? String(contentsOf: indexURL, encoding: .utf8)) ?? "# Memory index\n"
        var lines: [String] = []
        var linked = Set<String>()
        var lastEntry: Int?
        for line in body.components(separatedBy: "\n") {
            let targets = entryTargets(in: line)
            if let only = targets.first, targets.count == 1, isBareEntryLine(line) {
                guard present.contains(only) else { continue }
                lastEntry = lines.count
            }
            linked.formUnion(targets)
            lines.append(line)
        }

        let additions = onDisk.compactMap { url -> String? in
            let path = "\(directoryName)/\(url.lastPathComponent)"
            guard !linked.contains(path.lowercased()) else { return nil }
            let name = title(of: url) ?? url.deletingPathExtension().lastPathComponent
            return "- [\(name)](\(path))"
        }

        if !additions.isEmpty {
            if let lastEntry {
                lines.insert(contentsOf: additions, at: lastEntry + 1)
            } else {
                while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                    lines.removeLast()
                }
                if !lines.isEmpty { lines.append("") }
                lines.append(contentsOf: additions)
            }
        }

        var text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        guard text != body else { return }
        try text.write(to: indexURL, atomically: true, encoding: .utf8)
    }

    /// Every `memory/<file>.md` this line links to, case-folded for comparison.
    static func entryTargets(in line: String) -> [String] {
        var targets: [String] = []
        var cursor = line.startIndex
        while let open = line.range(of: "](", range: cursor..<line.endIndex) {
            cursor = open.upperBound
            guard let close = line.range(of: ")", range: cursor..<line.endIndex) else { break }
            let target = String(line[cursor..<close.lowerBound]).lowercased()
            if target.hasPrefix("\(directoryName)/"), target.hasSuffix(".md") {
                targets.append(target)
            }
            cursor = close.upperBound
        }
        return targets
    }

    /// A line this code could have written itself: a list item that is one
    /// link and, optionally, a hook after it. Anything else is the assistant's
    /// prose, and prose is never deleted to keep the index tidy.
    static func isBareEntryLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ["), let close = trimmed.range(of: ")") else { return false }
        let tail = trimmed[close.upperBound...].trimmingCharacters(in: .whitespaces)
        return tail.isEmpty || tail.hasPrefix("—") || tail.hasPrefix("-") || tail.hasPrefix(":")
    }

    private static func topicFileURLs(home: URL) -> [URL] {
        let directory = home.appendingPathComponent(directoryName, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return entries
            .filter { $0.pathExtension.lowercased() == "md" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `attributesOfItem` rather than `URL.resourceValues`, because the latter
    /// supports a narrower key set on corelibs-Foundation and this must be
    /// right on Linux too.
    private static func fileSize(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// True for a symlink at this exact path, following nothing —
    /// `attributesOfItem` is lstat-shaped, so this also catches a dangling
    /// link, which `resolvingSymlinksInPath` leaves looking local.
    private static func isSymlink(at url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
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
    case protected(String)
    case missing(String)
    case tooLarge(String, Int)

    var description: String {
        switch self {
        case .forbidden(let path):
            "Memory path must be MEMORY.md or memory/<file>.md — not \(path)."
        case .protected(let path):
            "\(path) is the index and cannot be deleted. Edit it with WriteMemory instead."
        case .missing(let path):
            "There is no memory file at \(path)."
        case .tooLarge(let path, let limit):
            "\(path) would exceed the \(limit / 1024) KB memory limit. "
                + "Rewrite it with only what still matters, or split the topic."
        }
    }
}
