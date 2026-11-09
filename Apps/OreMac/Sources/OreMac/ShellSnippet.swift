import Foundation

/// A fenced shell block in an agent reply that the reader can run themselves.
///
/// Agents write "try this" constantly. Without a Run control the loop breaks
/// at copy-paste; with one, the click is the consent, and the output lands
/// under the block instead of disappearing into a terminal tab.
enum ShellSnippet {
    static let languages: Set<String> = [
        "bash", "sh", "zsh", "shell", "console", "terminal", "fish",
    ]

    static func isRunnable(_ language: String?) -> Bool {
        guard let language else { return false }
        return languages.contains(language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func id(for command: String, worktree: String = "") -> String {
        var hasher = Hasher()
        hasher.combine(command)
        hasher.combine(worktree)
        return String(UInt64(bitPattern: Int64(hasher.finalize())), radix: 16)
    }

    static func runURL(command: String, worktree: String = "") -> URL {
        let identifier = id(for: command, worktree: worktree)
        SnippetRunCache.register(command, id: identifier)
        var components = URLComponents()
        components.scheme = "ore-run"
        components.host = "snippet"
        components.queryItems = [URLQueryItem(name: "id", value: identifier)]
        return components.url!
    }

    /// A login shell in the worktree, the same bargain the terminal pane makes.
    nonisolated static func execute(_ command: String, worktree: String) -> SnippetRunResult {
        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: worktree, isDirectory: true)
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-lc", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return SnippetRunResult(status: .failed, output: error.localizedDescription, exitCode: -1)
        }

        // Drain stdout while the process runs. Waiting first lets a chatty
        // command fill the pipe and deadlock.
        let collected = PipeDrain()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            collected.data = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }

        let deadline = DispatchTime.now() + .seconds(60)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        _ = drained.wait(timeout: .now() + .seconds(2))

        let data = collected.data
        var text = String(decoding: data, as: UTF8.self)
        if text.utf8.count > 32_768 {
            text = String(decoding: text.utf8.prefix(32_768), as: UTF8.self) + "\n… truncated"
        }
        if process.terminationStatus == 15, text.isEmpty {
            text = "Timed out after 60 seconds."
        }
        let failed = process.terminationStatus != 0
        return SnippetRunResult(
            status: failed ? .failed : .succeeded,
            output: text,
            exitCode: process.terminationStatus
        )
    }
}

private final class PipeDrain: @unchecked Sendable {
    var data = Data()
}

struct SnippetRunResult: Sendable, Equatable {
    enum Status: Sendable {
        case running
        case succeeded
        case failed
    }

    var status: Status
    var output: String
    var exitCode: Int32
}

/// Commands and their latest run, shared with the markdown renderer (which
/// draws off the main actor) and the click handler (which starts the process).
enum SnippetRunCache: Sendable {
    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var commands: [String: String] = [:]
        var results: [String: SnippetRunResult] = [:]
        var generation = 0
    }

    private static let store = Store()

    static let didChange = Notification.Name("ore.snippetRunDidChange")

    static func register(_ command: String, id: String) {
        store.lock.lock()
        store.commands[id] = command
        store.lock.unlock()
    }

    static func command(id: String) -> String? {
        store.lock.lock()
        defer { store.lock.unlock() }
        return store.commands[id]
    }

    static func result(id: String) -> SnippetRunResult? {
        store.lock.lock()
        defer { store.lock.unlock() }
        return store.results[id]
    }

    static var revision: Int {
        store.lock.lock()
        defer { store.lock.unlock() }
        return store.generation
    }

    static func set(_ result: SnippetRunResult, id: String) {
        store.lock.lock()
        store.results[id] = result
        store.generation &+= 1
        store.lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChange, object: id)
        }
    }

    @MainActor
    static func run(id: String, in worktree: String) {
        guard let command = command(id: id), !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        if result(id: id)?.status == .running { return }
        set(SnippetRunResult(status: .running, output: "", exitCode: 0), id: id)
        Task.detached(priority: .userInitiated) {
            let finished = ShellSnippet.execute(command, worktree: worktree)
            set(finished, id: id)
        }
    }
}
