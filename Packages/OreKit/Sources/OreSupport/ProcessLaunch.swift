import Foundation

/// Serializes `Process.run()` where the platform cannot.
///
/// swift-corelibs-foundation's `Process.run()` is not safe to call from
/// several threads at once: it mutates process-global signal handling and the
/// fd table between fork and exec, and concurrent launches segfault. Darwin
/// uses `posix_spawn` and is thread-safe, so it is left alone.
public enum ProcessLaunch {
    private static let lock = NSLock()

    public static func run(_ process: Process) throws {
        #if canImport(Darwin)
        try process.run()
        #else
        lock.lock()
        defer { lock.unlock() }
        try process.run()
        #endif
    }

    /// Linux `waitUntilExit` shares SIGCHLD state with `run()`. Keep them
    /// off each other's threads.
    public static func waitUntilExit(_ process: Process) {
        #if canImport(Darwin)
        process.waitUntilExit()
        #else
        lock.lock()
        defer { lock.unlock() }
        process.waitUntilExit()
        #endif
    }
}
