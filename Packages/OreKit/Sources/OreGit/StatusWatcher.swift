import Foundation
import OreProtocol
import OreSupport

#if canImport(CoreServices)
import CoreServices
#endif

/// Watches one worktree and republishes its git status as it changes.
///
/// An agent editing files produces bursts of filesystem events — a hundred
/// writes in a second while it rewrites a module — and running `git status` per
/// event would spend more time in git than the agent spends working. Events are
/// therefore debounced, and a slow poll runs underneath as a backstop: FSEvents
/// misses changes made inside a container, over a network mount, or by a process
/// that manipulates the index directly.
public actor StatusWatcher {
    public nonisolated let worktreeURL: URL
    public nonisolated let updates: AsyncStream<GitStatusSnapshot>

    private nonisolated let continuation: AsyncStream<GitStatusSnapshot>.Continuation
    private let git: GitClient
    private let debounce: Duration
    private let pollInterval: Duration

    private var fileSystemWatcher: FileSystemWatcher?
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var lastSnapshotFingerprint: Int?
    private var isStopped = false

    public init(
        git: GitClient,
        worktreeURL: URL,
        debounce: Duration = .milliseconds(300),
        pollInterval: Duration = .seconds(10)
    ) {
        self.git = git
        self.worktreeURL = worktreeURL
        self.debounce = debounce
        self.pollInterval = pollInterval

        let (stream, continuation) = AsyncStream<GitStatusSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        self.updates = stream
        self.continuation = continuation
    }

    public func start() async {
        guard !isStopped, fileSystemWatcher == nil else { return }

        // The worktree for file edits, plus `.git` for index and HEAD moves —
        // a commit changes the status without touching a single tracked file.
        let head = try? await git.gitPath("HEAD", in: worktreeURL)
        let index = try? await git.gitPath("index", in: worktreeURL)
        let paths = Set([
            worktreeURL.path,
            head?.deletingLastPathComponent().path,
            index?.deletingLastPathComponent().path,
        ].compactMap { $0 })
        let watcher = FileSystemWatcher(paths: Array(paths)) { [weak self] in
            Task { await self?.scheduleRefresh() }
        }
        watcher.start()
        fileSystemWatcher = watcher

        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled else { return }
                await self?.refreshNow()
            }
        }

        await refreshNow()
    }

    public func stop() {
        isStopped = true
        fileSystemWatcher?.stop()
        fileSystemWatcher = nil
        pollTask?.cancel()
        refreshTask?.cancel()
        continuation.finish()
    }

    /// Forces a read, ignoring the debounce. Called at turn boundaries, where
    /// the user is about to look at the diff and a 300ms lag is visible.
    public func refreshNow() async {
        guard !isStopped else { return }
        generation += 1
        let currentGeneration = generation

        guard let output = try? await git.run(
            ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal"],
            in: worktreeURL
        ) else { return }

        var snapshot = GitStatusParser.parse(output.standardOutput, generation: currentGeneration)
        // A snapshot older than one already published is stale by definition.
        guard currentGeneration >= generation else { return }

        await annotateLineCounts(&snapshot)

        // Publishing an identical snapshot would wake the UI for nothing; an
        // agent that reads files without writing generates a lot of events.
        let fingerprint = snapshot.fingerprint
        guard fingerprint != lastSnapshotFingerprint else { return }
        lastSnapshotFingerprint = fingerprint
        continuation.yield(snapshot)
    }

    /// Reads the working tree's current status on demand and returns it.
    ///
    /// Unlike `refreshNow`, this does not go through the published stream or its
    /// change-detection dedup — a caller that needs the *current* state (the
    /// git-action resolver) must get an answer even when nothing changed since
    /// the last publish, which the deduped stream would swallow.
    public func currentSnapshot() async -> GitStatusSnapshot? {
        guard !isStopped else { return nil }
        guard let output = try? await git.run(
            ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal"],
            in: worktreeURL
        ) else { return nil }
        var snapshot = GitStatusParser.parse(output.standardOutput, generation: generation)
        await annotateLineCounts(&snapshot)
        return snapshot
    }

    private func scheduleRefresh() {
        guard !isStopped else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.refreshNow()
        }
    }

    /// Adds insertion/deletion counts, which `git status` doesn't provide.
    /// Staged and unstaged are read separately so the ship panel can show each
    /// side without double-counting a partially staged file.
    private func annotateLineCounts(_ snapshot: inout GitStatusSnapshot) async {
        guard !snapshot.files.isEmpty else { return }
        async let stagedOutput = git.run(
            ["diff", "--numstat", "-z", "--cached", "HEAD", "--"],
            in: worktreeURL
        )
        async let unstagedOutput = git.run(
            ["diff", "--numstat", "-z", "--"],
            in: worktreeURL
        )
        let stagedCounts = (try? await stagedOutput).map { NumstatParser.parse($0.standardOutput) } ?? [:]
        let unstagedCounts = (try? await unstagedOutput).map { NumstatParser.parse($0.standardOutput) } ?? [:]
        snapshot.applyLineCounts(staged: stagedCounts, unstaged: unstagedCounts)
    }
}

extension GitStatusSnapshot {
    /// Cheap equality proxy for change detection.
    var fingerprint: Int {
        var hasher = Hasher()
        hasher.combine(branch)
        hasher.combine(aheadOfUpstream)
        hasher.combine(behindUpstream)
        for file in files {
            hasher.combine(file.path)
            hasher.combine(file.status)
            hasher.combine(file.isStaged)
            hasher.combine(file.isUnstaged)
            hasher.combine(file.insertions)
            hasher.combine(file.deletions)
        }
        return hasher.finalize()
    }

    mutating func applyLineCounts(
        staged: [String: NumstatParser.Entry],
        unstaged: [String: NumstatParser.Entry]
    ) {
        for index in files.indices {
            let path = files[index].path
            let stagedEntry = staged[path]
            let unstagedEntry = unstaged[path]
            let plus = (stagedEntry?.insertions ?? 0) + (unstagedEntry?.insertions ?? 0)
            let minus = (stagedEntry?.deletions ?? 0) + (unstagedEntry?.deletions ?? 0)
            if plus > 0 || minus > 0 {
                files[index].insertions = plus
                files[index].deletions = minus
            }
            files[index].isBinary = stagedEntry?.isBinary == true || unstagedEntry?.isBinary == true
        }
        stagedFileCount = files.filter(\.isStaged).count
        unstagedFileCount = files.filter(\.isUnstaged).count
        stagedInsertions = files.filter(\.isStaged).reduce(0) { $0 + (staged[$1.path]?.insertions ?? 0) }
        stagedDeletions = files.filter(\.isStaged).reduce(0) { $0 + (staged[$1.path]?.deletions ?? 0) }
        unstagedInsertions = files.filter(\.isUnstaged).reduce(0) { $0 + (unstaged[$1.path]?.insertions ?? 0) }
        unstagedDeletions = files.filter(\.isUnstaged).reduce(0) { $0 + (unstaged[$1.path]?.deletions ?? 0) }
    }
}

enum NumstatParser {
    struct Entry {
        var insertions: Int
        var deletions: Int
        var isBinary: Bool
    }

    /// `--numstat -z` emits `ins\tdel\t` then the path as a separate NUL field;
    /// for renames it emits two paths.
    static func parse(_ output: String) -> [String: Entry] {
        var result: [String: Entry] = [:]
        var fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        if fields.last?.isEmpty == true { fields.removeLast() }

        var index = 0
        while index < fields.count {
            let record = fields[index]
            index += 1
            let parts = record.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }

            // A binary file reports "-" for both counts.
            let isBinary = parts[0] == "-"
            let entry = Entry(
                insertions: Int(parts[0]) ?? 0,
                deletions: Int(parts[1]) ?? 0,
                isBinary: isBinary
            )

            if parts.count >= 3, !parts[2].isEmpty {
                result[parts[2]] = entry
            } else {
                // Rename: the source path comes first, then the destination.
                // The destination is the one the user sees.
                index += 1
                if index < fields.count {
                    result[fields[index]] = entry
                    index += 1
                }
            }
        }
        return result
    }
}

/// Filesystem change notifications.
///
/// FSEvents on Apple platforms; a coarse timer elsewhere, which is enough
/// because the poll backstop is doing the real work on those platforms.
final class FileSystemWatcher: @unchecked Sendable {
    private let paths: [String]
    private let onChange: @Sendable () -> Void

    #if canImport(CoreServices)
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "ore.git.fsevents")
    #endif

    init(paths: [String], onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    func start() {
        #if canImport(CoreServices)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange()
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,  // FSEvents' own coalescing, ahead of ours
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            )
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
        #endif
    }

    func stop() {
        #if canImport(CoreServices)
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        #endif
    }

    deinit {
        stop()
    }
}
