import Foundation

/// Resolves the environment a GUI app must hand to child processes.
///
/// An app launched from Finder inherits a minimal `PATH` that contains none of
/// the version managers (nvm, mise, asdf, homebrew) developers install their
/// CLIs with. Every "works in Terminal, not in the app" bug traces back to
/// this, so we probe the user's login shell once and cache the result.
public enum ShellEnvironment {
    /// Environment variables that would silently redirect a subscription
    /// session onto metered API billing. Scrubbed unless the user explicitly
    /// opts into API-key auth.
    public static let providerCredentialKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_BEDROCK_BASE_URL",
        "ANTHROPIC_VERTEX_BASE_URL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "OPENAI_API_KEY",
        "OPENAI_BASE_URL",
        "OPENAI_API_BASE",
        "XAI_API_KEY",
        "CURSOR_API_KEY",
    ]

    private static let cache = Cache()

    /// Computes a value once, without holding its lock while computing.
    ///
    /// The login-shell probe can take seconds; holding a lock across it made
    /// every concurrent `childEnvironment()` contend on that lock (and made
    /// `invalidateCache()` block behind a probe). Now one caller computes with
    /// the lock released and the others sleep on the condition until it
    /// publishes — they still get the single computed value.
    final class Cache: @unchecked Sendable {
        private let condition = NSCondition()
        private var value: [String: String]?
        private var isComputing = false
        private var generation: UInt64 = 0

        func resolve(_ compute: () -> [String: String]) -> [String: String] {
            condition.lock()
            while value == nil, isComputing {
                condition.wait()
            }
            if let value {
                condition.unlock()
                return value
            }
            isComputing = true
            let startedGeneration = generation
            condition.unlock()

            let computed = compute()

            condition.lock()
            isComputing = false
            // An invalidation mid-probe means this reading may predate the
            // change; hand it to this caller but let the next one re-probe.
            if generation == startedGeneration { value = computed }
            condition.broadcast()
            condition.unlock()
            return computed
        }

        func invalidate() {
            condition.lock()
            defer { condition.unlock() }
            generation += 1
            value = nil
        }
    }

    /// The user's login-shell environment, probed once per app run.
    ///
    /// Falls back to the process environment if the probe fails or times out;
    /// a degraded `PATH` beats a hung launch. Either way the result is
    /// augmented with the directories and variables child CLIs assume exist.
    public static func loginShellEnvironment() -> [String: String] {
        cache.resolve { augmented(probeLoginShell() ?? ProcessInfo.processInfo.environment) }
    }

    /// Forgets the probed login-shell environment so the next read re-runs it.
    ///
    /// The cache is what makes `childEnvironment()` cheap, but it also meant
    /// the PATH ORE saw was frozen at launch: a user who followed ORE's own
    /// advice — copy the install command, run it in Terminal, come back —
    /// could not be told they had succeeded without quitting the app, because
    /// the new CLI's directory had not existed when the probe ran.
    ///
    /// `Cache.invalidate()` has existed all along; nothing outside the tests
    /// could reach it.
    public static func invalidateCache() {
        cache.invalidate()
    }

    /// Fires the login-shell probe off the caller's path so the first harness
    /// launch never pays the up-to-5s shell startup cost.
    public static func warm() {
        Thread.detachNewThread {
            _ = loginShellEnvironment()
        }
    }

    /// The environment to hand a harness child process: login-shell values,
    /// provider credentials removed, overrides applied last.
    public static func childEnvironment(
        overrides: [String: String] = [:],
        allowProviderCredentials: Bool = false
    ) -> [String: String] {
        var environment = loginShellEnvironment()
        for (key, value) in overrides {
            environment[key] = value
        }
        // Scrubbed last, so the flag is the single answer to "can this session
        // reach a metered API?" — an override can't route around it.
        if !allowProviderCredentials {
            for key in providerCredentialKeys {
                environment.removeValue(forKey: key)
            }
        }
        return environment
    }

    /// The shell to run a user's script through.
    ///
    /// `$SHELL` is the right answer when it's set and real, but it is routinely
    /// absent in a non-interactive context — a container, a launchd job, CI —
    /// and hardcoding zsh as the fallback meant that on any machine without it
    /// (every Linux image) the shell simply failed to launch. The candidates are
    /// tried in order of how much of the user's setup they carry.
    public static var loginShellPath: String {
        let candidates = [
            ProcessInfo.processInfo.environment["SHELL"],
            "/bin/zsh", "/bin/bash", "/bin/sh",
        ]
        for candidate in candidates.compactMap({ $0 }) where isExecutable(candidate) {
            return candidate
        }
        return "/bin/sh"
    }

    /// How to ask `shell` to run a one-off command.
    ///
    /// `-l` loads the user's profile, which is the point — but it is a bash/zsh
    /// extension, and passing it to a POSIX `sh` (dash, on most Linux images)
    /// makes the shell reject the whole invocation.
    public static func commandArguments(for shell: String, script: String) -> [String] {
        let name = (shell as NSString).lastPathComponent
        return (name == "zsh" || name == "bash")
            ? ["-lc", script]
            : ["-c", script]
    }

    /// Finds an executable on the resolved `PATH`.
    public static func locate(
        _ executable: String,
        in environment: [String: String]? = nil
    ) -> String? {
        let environment = environment ?? loginShellEnvironment()

        // An absolute or relative path is used as given.
        if executable.contains("/") {
            return isExecutable(executable) ? executable : nil
        }

        let searchPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in searchPath.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(executable)
                .path
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    public static var searchPathDescription: String {
        loginShellEnvironment()["PATH"] ?? "(no PATH)"
    }

    /// Backfills what a broken or minimal environment leaves out: the common
    /// tool directories on `PATH`, and the variables (`HOME`, `SHELL`, `TERM`)
    /// that CLIs and their lifecycle scripts assume are always present.
    private static func augmented(_ environment: [String: String]) -> [String: String] {
        var environment = environment

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = environment["PATH"] ?? ""
        var seen = Set(path.split(separator: ":", omittingEmptySubsequences: true).map(String.init))
        let required = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        for directory in required where !seen.contains(directory) {
            path = path.isEmpty ? directory : "\(path):\(directory)"
            seen.insert(directory)
        }
        environment["PATH"] = path

        if environment["HOME"]?.isEmpty != false { environment["HOME"] = home }
        if environment["SHELL"]?.isEmpty != false {
            environment["SHELL"] = loginShellPath
        }
        if environment["TERM"]?.isEmpty != false { environment["TERM"] = "xterm-256color" }
        return environment
    }

    private static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// Runs the login shell with a marker-delimited `env` dump.
    ///
    /// The markers matter: shell profiles print banners, version-manager
    /// notices and update nags, and parsing that noise as environment
    /// variables produces a corrupt environment rather than an obvious failure.
    private static func probeLoginShell() -> [String: String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard isExecutable(shell) else { return nil }

        // Interactive as well as login first: nvm and mise are commonly
        // initialized in .zshrc / .bashrc rather than the profile. If that
        // hangs or fails (a profile waiting on input), retry login-only, which
        // skips the interactive rc files entirely.
        return probe(shell: shell, flags: "-ilc") ?? probe(shell: shell, flags: "-lc")
    }

    private static func probe(shell: String, flags: String) -> [String: String]? {
        let begin = "__ORE_ENV_BEGIN__"
        let end = "__ORE_ENV_END__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = [flags, "printf '%s\\n' \(begin); env -0; printf '%s\\n' \(end)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // Announce ourselves so a profile can opt out of expensive work.
        var probeEnvironment = ProcessInfo.processInfo.environment
        probeEnvironment["ORE_ENV_PROBE"] = "1"
        process.environment = probeEnvironment

        do {
            try ProcessLaunch.run(process)
        } catch {
            return nil
        }

        // Read to EOF on a background thread so a shell that never exits
        // (a profile waiting on input) can be killed without deadlocking here.
        let output = Lockbox<Data>(Data())
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output.set(data)
            finished.signal()
        }

        if finished.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            return nil
        }
        ProcessLaunch.waitUntilExit(process)

        guard let text = String(data: output.get(), encoding: .utf8),
              let beginRange = text.range(of: begin + "\n"),
              let endRange = text.range(of: end, range: beginRange.upperBound..<text.endIndex)
        else { return nil }

        let body = String(text[beginRange.upperBound..<endRange.lowerBound])
        var environment: [String: String] = [:]
        // `env -0` separates entries with NUL, so values containing newlines
        // survive intact.
        for entry in body.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[entry.startIndex..<separator])
            let value = String(entry[entry.index(after: separator)...])
            guard !key.isEmpty else { continue }
            environment[key] = value
        }
        return environment.isEmpty ? nil : environment
    }
}

/// Minimal lock-guarded box, used where a value crosses a thread boundary
/// without an actor being available.
public final class Lockbox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) { self.value = value }

    public func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    @discardableResult
    public func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
