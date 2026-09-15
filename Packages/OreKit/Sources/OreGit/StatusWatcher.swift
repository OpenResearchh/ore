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
///
/// Idle cost matters as much as latency: a user keeps many worktrees open for
/// hours, so the backstop is slow, build and dependency output is filtered out
/// before it can wake us, and line counting only runs when it can have changed.
public actor StatusWatcher {
    public nonisolated let worktreeURL: URL
    public nonisolated let updates: AsyncStream<GitStatusSnapshot>

    private nonisolated let continuation: AsyncStream<GitStatusSnapshot>.Continuation
    private let git: GitClient
    private let debounce: Duration
    private let pollInterval: Duration
    private var backgroundPollingEnabled: Bool

    private var fileSystemWatcher: FileSystemWatcher?
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var lastSnapshotFingerprint: Int?
    private var lastPorcelain: String?
    private var pendingLineCount = false
    private var isStopped = false
    /// Bumped on every relevant filesystem event. A read remembers the value
    /// it started under, so a snapshot is only reused while nothing has
    /// touched the tree since that read began.
    private var changeCounter: UInt64 = 0
    /// The index and HEAD files. A commit or stage made just before a caller
    /// asks can beat its FSEvents delivery; their modification times can't.
    private var gitStateFiles: [URL] = []
    private var latestRead: (
        snapshot: GitStatusSnapshot,
        at: ContinuousClock.Instant,
        changeCounter: UInt64,
        gitState: [Date?]
    )?

    /// The backstop poll. Where FSEvents reports changes it only has to catch
    /// what they miss, so it can be slow. Without them, as on Linux, it is the
    /// only way a change is ever noticed.
    #if canImport(CoreServices)
    public static let defaultPollInterval: Duration = .seconds(60)
    #else
    public static let defaultPollInterval: Duration = .seconds(10)
    #endif

    public init(
        git: GitClient,
        worktreeURL: URL,
        debounce: Duration = .milliseconds(300),
        pollInterval: Duration = StatusWatcher.defaultPollInterval,
        backgroundPollingEnabled: Bool = true
    ) {
        self.git = git
        self.worktreeURL = worktreeURL
        self.debounce = debounce
        self.pollInterval = pollInterval
        self.backgroundPollingEnabled = backgroundPollingEnabled

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
        guard !isStopped else { return }
        gitStateFiles = [index, head].compactMap { $0 }
        let paths = Set([
            worktreeURL.path,
            head?.deletingLastPathComponent().path,
            index?.deletingLastPathComponent().path,
        ].compactMap { $0 })
        let filter = StatusEventFilter(
            worktree: worktreeURL,
            gitDirectories: [head, index].compactMap { $0?.deletingLastPathComponent() }
        )
        // Filtered on the FSEvents queue, so a build writing thousands of files
        // into `.build` never even hops onto the actor.
        let watcher = FileSystemWatcher(paths: Array(paths)) { [weak self] changedPaths in
            let relevance = changedPaths.map(filter.relevance(of:)) ?? .workingFiles
            guard relevance != .ignored else { return }
            Task { await self?.scheduleRefresh(countLines: relevance == .workingFiles) }
        }
        watcher.start()
        fileSystemWatcher = watcher

        startPolling()
        await refreshNow()
    }

    /// Visibility only controls the periodic backstop. Filesystem events and
    /// explicit refreshes remain available while the host app is hidden.
    public func setBackgroundPollingEnabled(_ enabled: Bool) async {
        guard backgroundPollingEnabled != enabled else { return }
        backgroundPollingEnabled = enabled
        pollTask?.cancel()
        pollTask = nil
        guard enabled, !isStopped, fileSystemWatcher != nil else { return }
        startPolling()
        await refreshNow()
    }

    private func startPolling() {
        guard backgroundPollingEnabled, !isStopped, pollTask == nil else { return }
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled else { return }
                // This is the backstop for missed filesystem events. Working
                // contents can change while porcelain stays identical, so a
                // poll must also recover their latest line counts.
                await self?.refreshNow()
            }
        }
    }

    public func stop() {
        isStopped = true
        fileSystemWatcher?.stop()
        fileSystemWatcher = nil
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        continuation.finish()
    }

    /// Forces a read, ignoring the debounce. Called at turn boundaries, where
    /// the user is about to look at the diff and a 300ms lag is visible.
    public func refreshNow() async {
        await refresh(countLines: true)
    }

    /// Reads status, plus line counts when `countLines` is set or the status
    /// itself moved.
    ///
    /// Porcelain v2 already encodes HEAD, upstream divergence and the index
    /// blob of every changed file, so an unchanged output means only working
    /// file contents can differ — and those change only when a working file is
    /// written, which is when callers pass `countLines`. Metadata-only events
    /// skip the two `git diff --numstat` runs a dirty tree would otherwise cost
    /// on every reading; the slow poll recounts in case file events were lost.
    private func refresh(countLines: Bool) async {
        guard !isStopped else { return }
        generation += 1
        let currentGeneration = generation
        let startedUnder = changeCounter
        let gitState = gitStateStamp()

        guard let output = try? await git.run(
            ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal"],
            in: worktreeURL
        ) else { return }

        // A snapshot older than one already published is stale by definition.
        guard currentGeneration >= generation else { return }
        let porcelain = output.standardOutput
        if !countLines, porcelain == lastPorcelain { return }

        var snapshot = GitStatusParser.parse(porcelain, generation: currentGeneration)
        await annotateLineCounts(&snapshot)
        lastPorcelain = porcelain
        remember(snapshot, startedUnder: startedUnder, gitState: gitState)

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
        let startedUnder = changeCounter
        let gitState = gitStateStamp()
        guard let output = try? await git.run(
            ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal"],
            in: worktreeURL
        ) else { return nil }
        var snapshot = GitStatusParser.parse(output.standardOutput, generation: generation)
        await annotateLineCounts(&snapshot)
        remember(snapshot, startedUnder: startedUnder, gitState: gitState)
        return snapshot
    }

    /// The last full read when it is provably current — no filesystem event
    /// since it began, and younger than `maxAge` as a backstop for changes
    /// FSEvents is slow to report or misses — otherwise a live read. Saves
    /// three git processes on the git-action refreshes that follow a publish.
    ///
    /// Without FSEvents nothing proves the tree unchanged, so every call
    /// reads live.
    public func recentSnapshot(maxAge: Duration = .seconds(5)) async -> GitStatusSnapshot? {
        guard !isStopped else { return nil }
        #if canImport(CoreServices)
        if let latestRead, latestRead.changeCounter == changeCounter,
           latestRead.at.duration(to: .now) <= maxAge,
           latestRead.gitState == gitStateStamp() {
            return latestRead.snapshot
        }
        #endif
        return await currentSnapshot()
    }

    private func remember(
        _ snapshot: GitStatusSnapshot, startedUnder counter: UInt64, gitState: [Date?]
    ) {
        // An overlapping read that began before a newer event must not
        // replace one that began after it.
        if let latestRead, latestRead.changeCounter > counter { return }
        latestRead = (snapshot, .now, counter, gitState)
    }

    /// Modification times of the index and HEAD, taken when a read starts.
    private func gitStateStamp() -> [Date?] {
        gitStateFiles.map { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
    }

    private func scheduleRefresh(countLines: Bool) {
        guard !isStopped else { return }
        changeCounter &+= 1
        // Debouncing cancels the earlier task, so what it needed carries over.
        pendingLineCount = pendingLineCount || countLines
        refreshTask?.cancel()
        refreshTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.runScheduledRefresh()
        }
    }

    private func runScheduledRefresh() async {
        let countLines = pendingLineCount
        pendingLineCount = false
        await refresh(countLines: countLines)
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

/// Decides whether a batch of filesystem events can have changed the status.
///
/// During a build the worktree sees thousands of writes into output and
/// dependency directories that git (almost always) ignores, and git's own
/// bookkeeping — loose objects, reflogs, `FETCH_HEAD` — churns on every fetch
/// and commit. None of that moves `git status`; HEAD, the index, refs and
/// ordinary files do, and those still get through.
struct StatusEventFilter: Sendable {
    enum Relevance: Int, Comparable, Sendable {
        case ignored
        /// Only git metadata moved: status can change, but line counts can't
        /// without the porcelain changing too.
        case gitMetadata
        /// A working file was written, so line counts may have changed.
        case workingFiles

        static func < (lhs: Relevance, rhs: Relevance) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Matched against every component below the worktree root, so a nested
    /// `packages/app/node_modules` is ignored too. Never matched against the
    /// root's own path — a worktree living under `~/target/` must still work.
    static let ignoredDirectoryNames: Set<String> = [
        ".build", "node_modules", "DerivedData", ".next", "dist", "target", "__pycache__",
    ]

    /// Top-level git-directory entries that change without changing status.
    /// `worktrees` holds the *other* linked worktrees' HEADs and indexes.
    static let ignoredGitEntries: Set<String> = [
        "objects", "logs", "worktrees", "FETCH_HEAD",
    ]

    var worktreePaths: [String]
    var gitDirectoryPaths: [String]

    func relevance(of paths: [String]) -> Relevance {
        var result = Relevance.ignored
        for path in paths {
            result = max(result, relevance(of: path))
            if result == .workingFiles { break }
        }
        return result
    }

    func relevance(of path: String) -> Relevance {
        // Git directories first: the main worktree's `.git` sits inside it.
        for gitDirectory in gitDirectoryPaths {
            if let components = Self.components(of: path, under: gitDirectory) {
                return Self.gitRelevance(components)
            }
        }
        for worktree in worktreePaths {
            guard let components = Self.components(of: path, under: worktree) else { continue }
            if components.first == ".git" {
                return Self.gitRelevance(Array(components.dropFirst()))
            }
            return components.contains(where: Self.ignoredDirectoryNames.contains)
                ? .ignored
                : .workingFiles
        }
        // Outside every root we know: react rather than risk a stale status.
        return .workingFiles
    }

    private static func gitRelevance(_ components: [String]) -> Relevance {
        guard let first = components.first else { return .gitMetadata }
        return ignoredGitEntries.contains(first) ? .ignored : .gitMetadata
    }

    private static func components(of path: String, under root: String) -> [String]? {
        let root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        if path == root { return [] }
        guard path.hasPrefix(root + "/") else { return nil }
        return path.dropFirst(root.count + 1)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }
}

extension StatusEventFilter {
    /// FSEvents reports resolved paths (`/private/var/...`) while callers hold
    /// whatever URL they were given, so both spellings are matched.
    init(worktree: URL, gitDirectories: [URL]) {
        func spellings(_ url: URL) -> [String] {
            let resolved = url.resolvingSymlinksInPath().path
            return url.path == resolved ? [url.path] : [url.path, resolved]
        }
        self.init(
            worktreePaths: spellings(worktree),
            gitDirectoryPaths: gitDirectories.flatMap(spellings)
        )
    }
}

/// Filesystem change notifications.
///
/// FSEvents on Apple platforms; a coarse timer elsewhere, which is enough
/// because the poll backstop is doing the real work on those platforms.
///
/// `onChange` gets the changed paths, or nil when FSEvents lost the detail
/// (dropped events, a required rescan) and anything may have moved.
final class FileSystemWatcher: @unchecked Sendable {
    private let paths: [String]
    private let onChange: @Sendable ([String]?) -> Void

    #if canImport(CoreServices)
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "ore.git.fsevents")
    #endif

    init(paths: [String], onChange: @escaping @Sendable ([String]?) -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    func start() {
        #if canImport(CoreServices)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            let lostDetail = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
            )
            if (0..<count).contains(where: { eventFlags[$0] & lostDetail != 0 }) {
                watcher.onChange(nil)
                return
            }
            // `UseCFTypes` makes `eventPaths` a CFArray of CFString.
            let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            watcher.onChange((array as NSArray) as? [String])
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
            // FSEvents' own coalescing, ahead of ours. NoDefer still delivers
            // the first event of a burst at once; the rest wait out the second.
            1.0,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagUseCFTypes
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
