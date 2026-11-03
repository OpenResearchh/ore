import Foundation

/// Grep over a worktree's files. ⌘P finds names; this finds the line.
struct WorkspaceContentHit: Equatable, Identifiable, Sendable {
    var path: String
    var line: Int
    var text: String
    var id: String { "\(path):\(line):\(text)" }
}

enum WorkspaceContentSearch: Sendable {
    static let skipDirectoryNames = WorkspaceFileScanner.default.skipRecursionNames.union([".git"])

    static func search(query: String, in worktree: String, limit: Int = 80) -> [WorkspaceContentHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let hits = ripgrep(query: trimmed, worktree: worktree, limit: limit) {
            return hits
        }
        return grep(query: trimmed, worktree: worktree, limit: limit)
    }

    /// `path:line:text`, which both rg and grep print with `-n`.
    static func parseLine(_ raw: String) -> WorkspaceContentHit? {
        let line = raw.trimmingCharacters(in: .newlines)
        guard !line.isEmpty else { return nil }
        let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 3, let number = Int(parts[1]), number > 0 else { return nil }
        let path = String(parts[0])
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
        return WorkspaceContentHit(
            path: path,
            line: number,
            text: String(parts[2]).trimmingCharacters(in: .whitespaces)
        )
    }

    private static func ripgrep(query: String, worktree: String, limit: Int) -> [WorkspaceContentHit]? {
        guard let executable = ripgrepExecutable() else { return nil }
        var arguments = [
            "--ignore-case", "--no-heading", "--line-number", "--color", "never",
            "--max-count", "8", "--max-filesize", "1M",
            "--hidden", "--glob", "!.git",
        ]
        for name in skipDirectoryNames where name != ".git" {
            arguments.append(contentsOf: ["--glob", "!\(name)"])
        }
        arguments.append(contentsOf: ["--", query, "."])
        return run(executable: executable, arguments: arguments, worktree: worktree, limit: limit)
    }

    private static func grep(query: String, worktree: String, limit: Int) -> [WorkspaceContentHit] {
        var arguments = ["-R", "-n", "-I", "-i", "--exclude-dir=.git"]
        for name in skipDirectoryNames where name != ".git" {
            arguments.append("--exclude-dir=\(name)")
        }
        arguments.append(contentsOf: ["--", query, "."])
        return run(
            executable: "/usr/bin/grep",
            arguments: arguments,
            worktree: worktree,
            limit: limit
        ) ?? []
    }

    private static func ripgrepExecutable() -> String? {
        for candidate in ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func run(
        executable: String,
        arguments: [String],
        worktree: String,
        limit: Int
    ) -> [WorkspaceContentHit]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: worktree, isDirectory: true)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // rg exits 1 when there are no matches; that's still a successful search.
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var hits: [WorkspaceContentHit] = []
        hits.reserveCapacity(min(limit, 32))
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let hit = parseLine(String(raw)) else { continue }
            hits.append(hit)
            if hits.count >= limit { break }
        }
        return hits
    }
}
