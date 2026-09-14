import AppKit
import SwiftUI

private enum GitHubUpdateError: LocalizedError, Sendable {
    case downloadFailed
    case noAppInArchive
    case copyFailed
    case relaunchFailed

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "Couldn't download the update. Check your network and try again."
        case .noAppInArchive:
            return "The installer didn't contain ORE.app."
        case .copyFailed:
            return "Couldn't unpack the new app."
        case .relaunchFailed:
            return "Couldn't start the installer."
        }
    }
}

/// A lightweight update check against the project's GitHub Releases.
///
/// Sparkle (`Updater`) is the real path, but it stays disabled until a build is
/// signed and pointed at an appcast — which is every build we hand each other
/// today. This fills that gap: it asks GitHub for the latest release, and if
/// this build is behind, offers to install it and restart.
///
/// It asks through `gh` when the CLI is signed in, so the check is not subject
/// to the anonymous API rate limit, and falls back to the public REST endpoint
/// for a user without `gh`.
@MainActor
@Observable
final class GitHubUpdater {
    struct Available: Equatable, Sendable {
        var version: String
        var title: String
        var releaseURL: URL
        /// The installable asset (`.dmg`/`.zip`), when the release ships one.
        var downloadURL: URL?
        var assetName: String?
        var assetID: Int?
    }

    enum Phase: Equatable, Sendable {
        case idle
        case downloading
        case installing
        /// Staged and scheduled; the only thing left is this process exiting.
        case restarting
        case failed(String)
    }

    /// What the swap script was asked to install, written to disk before the
    /// quit so the *next* launch can say whether it actually landed. Without
    /// it a restart is a memory wipe: the new build comes up with a fresh
    /// updater that has no idea an install was ever in flight.
    struct PendingRestart: Codable, Equatable, Sendable {
        var version: String
        var title: String
        var releaseURL: URL
    }

    /// The side effects of installing, injected so the lifecycle above them —
    /// download, stage, quit, reconcile — is testable without a network, a
    /// disk image, or a process that really exits.
    struct Hooks: Sendable {
        /// Downloads the release's installer asset; returns the archive on disk.
        var download: @Sendable (Available) async throws -> URL
        /// Unpacks the archive and schedules the post-quit swap script.
        var schedule: @Sendable (URL) async throws -> Void
        /// Asks the app to quit (the swap script is waiting on this pid).
        var requestQuit: @Sendable () -> Void
        /// Leaves without the graceful handshake, when the polite ask didn't take.
        var forceQuit: @Sendable () -> Void
        /// How the restart watchdog waits.
        var wait: @Sendable (Duration) async -> Void

        static let live = Hooks(
            download: { release in
                let work = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ore-update-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: work, withIntermediateDirectories: true
                )
                guard let archive = await downloadInstaller(release, into: work) else {
                    try? FileManager.default.removeItem(at: work)
                    try Task.checkCancellation()
                    throw GitHubUpdateError.downloadFailed
                }
                return archive
            },
            schedule: { archive in
                let work = archive.deletingLastPathComponent()
                let replacement = try await unpackApp(from: archive, into: work)
                try scheduleReplaceAndRelaunch(
                    from: replacement,
                    replacing: installDestination(currentBundle: Bundle.main.bundleURL)
                )
            },
            // `assumeIsolated`: only ever called from `finishInstall`, which
            // is main-actor isolated.
            requestQuit: { MainActor.assumeIsolated { NSApp.terminate(nil) } },
            forceQuit: {
                MainActor.assumeIsolated {
                    // `exit` skips `applicationWillTerminate`, so the one
                    // thing that handshake does which nothing else does —
                    // killing terminal shells, which have no session to close
                    // them — happens here instead. An orphaned shell survives
                    // the swap still holding the old bundle open.
                    TerminalRegistry.shared.closeAll()
                    exit(0)
                }
            },
            wait: { try? await Task.sleep(for: $0) }
        )
    }

    private(set) var available: Available?
    private(set) var isChecking = false
    private(set) var phase: Phase = .idle
    /// `Later` hides the popup for this session; the menu item stays so the
    /// user can still install without another launch.
    private(set) var dismissed = false
    /// Set on the first launch after an update landed, so the restart ends in
    /// a confirmation the user dismisses rather than in silence.
    private(set) var completedVersion: String?
    /// The in-flight install, kept so Cancel can actually stop the download
    /// rather than leaving the user trapped behind a disabled modal.
    private var installTask: Task<Void, Never>?

    private let hooks: Hooks
    private let defaults: UserDefaults
    private let version: @Sendable () -> String

    /// How long the app gets to quit on its own before the update stops being
    /// polite about it. Longer than `AppDelegate`'s shutdown deadline, so the
    /// graceful path always gets its full turn first.
    static let quitDeadline: Duration = .seconds(12)

    static let pendingRestartKey = "ore.update.pendingRestart"

    /// `owner/repo` this build updates from.
    nonisolated static let repository = "OpenResearchh/ore"

    init(
        hooks: Hooks = .live,
        defaults: UserDefaults = .standard,
        version: @escaping @Sendable () -> String = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "0.0.0"
        }
    ) {
        self.hooks = hooks
        self.defaults = defaults
        self.version = version
    }

    var currentVersion: String { version() }

    var isInstalling: Bool {
        switch phase {
        case .downloading, .installing, .restarting: return true
        case .idle, .failed: return false
        }
    }

    /// The in-window prompt: shown when a newer release is waiting, while an
    /// install is in flight, after a failed attempt the user hasn't dismissed,
    /// or to confirm the update that just landed.
    var showsPrompt: Bool {
        if completedVersion != nil { return true }
        return available != nil && (!dismissed || isInstalling || isFailed)
    }

    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// Looks up the latest release and records it when it's newer than this
    /// build. Safe to call on launch and from the menu; failures are silent —
    /// an update check that can't reach GitHub shouldn't nag.
    func check() async {
        guard !isChecking, !isInstalling else { return }
        isChecking = true
        defer { isChecking = false }

        guard let release = await Self.latestRelease(repository: Self.repository) else { return }
        guard Self.isNewer(release.version, than: currentVersion) else {
            available = nil
            return
        }
        applyCheckResult(release)
    }

    /// Records a newer release, split from `check()` for the network-free half.
    func applyCheckResult(_ release: Available) {
        // Compared by version, not by whole record: a check that lands after
        // `reconcilePendingRestart` reported a failed install fills in the
        // asset details for the retry without wiping the message explaining
        // why there is one.
        if available?.version != release.version {
            dismissed = false
            phase = .idle
        }
        available = release
    }

    func dismiss() {
        dismissed = true
        completedVersion = nil
        if case .failed = phase { phase = .idle }
    }

    /// Clears the "you're now on vX" confirmation shown after a restart.
    func acknowledgeCompletion() {
        completedVersion = nil
    }

    /// Downloads the release, replaces this app bundle, and relaunches.
    /// Opens the release page only when there is no installer asset to apply.
    func install() {
        guard let available, !isInstalling else { return }
        guard available.downloadURL != nil || available.assetName != nil else {
            NSWorkspace.shared.open(available.releaseURL)
            return
        }
        dismissed = false
        completedVersion = nil
        phase = .downloading
        installTask = Task { await runInstall(available) }
    }

    /// The install lifecycle, split out from `install()` so it can be driven
    /// with stub hooks.
    func runInstall(_ release: Available) async {
        do {
            let archive = try await hooks.download(release)
            try Task.checkCancellation()
            // Past here the swap is seconds away; `.installing` is also what
            // pins the prompt's buttons, so the cancellable window ends at
            // the download.
            phase = .installing
            try await hooks.schedule(archive)
            await finishInstall(release)
        } catch {
            phase = Task.isCancelled ? .idle : .failed(error.localizedDescription)
        }
    }

    /// Quits so the swap script — which is blocked on this pid — can finish.
    ///
    /// This is the step that used to strand the popup. The staged update was
    /// fine and the script was fine; the app simply never exited, so the swap
    /// never ran and the modal sat on its spinner until the user quit by
    /// hand. So the quit is now watched: if the graceful ask hasn't taken us
    /// down by the deadline, we leave the hard way, because a staged update
    /// with a live old process is the one state nothing can recover from.
    func finishInstall(_ release: Available) async {
        phase = .restarting
        recordPendingRestart(for: release)
        hooks.requestQuit()
        await hooks.wait(Self.quitDeadline)
        guard phase == .restarting else { return }
        hooks.forceQuit()
        // Only reached when `forceQuit` didn't (a test double, or a platform
        // that refused): say so instead of spinning, since quitting by hand
        // now finishes the same update.
        phase = .failed(
            "ORE couldn't quit to finish installing "
                + "\(Self.displayVersion(release.version)). Quit and reopen ORE to apply it."
        )
    }

    /// Stops an in-flight download and puts the prompt back to rest. Only the
    /// brief unpack-and-swap at the end is uncancellable.
    func cancelInstall() {
        guard phase == .downloading else { return }
        installTask?.cancel()
        installTask = nil
        phase = .idle
        dismissed = true
    }

    // MARK: - Restart handoff

    private func recordPendingRestart(for release: Available) {
        let pending = PendingRestart(
            version: release.version, title: release.title, releaseURL: release.releaseURL
        )
        guard let data = try? JSONEncoder().encode(pending) else { return }
        defaults.set(data, forKey: Self.pendingRestartKey)
        // The escalation above leaves through `exit`, which skips the normal
        // flush; an unwritten record is a restart nobody can account for.
        defaults.synchronize()
    }

    /// Settles the record the previous launch left behind. Call once at
    /// startup, before `check()`: an update that landed is acknowledged, and
    /// one that didn't is reported — rather than reappearing as a plain
    /// "update available" that hides the fact the last attempt went nowhere.
    func reconcilePendingRestart() {
        guard let data = defaults.data(forKey: Self.pendingRestartKey) else { return }
        defaults.removeObject(forKey: Self.pendingRestartKey)
        guard let pending = try? JSONDecoder().decode(PendingRestart.self, from: data) else {
            return
        }
        dismissed = false
        guard Self.isNewer(pending.version, than: currentVersion) else {
            // The running build, not the tag we asked for: they agree in the
            // normal case, and where they don't, what's actually running is
            // the honest thing to report.
            completedVersion = currentVersion
            available = nil
            phase = .idle
            return
        }
        // Still on the old build: the swap never ran. `check()` will fill the
        // asset details back in so "Try Again" is a real retry.
        available = Available(
            version: pending.version, title: pending.title, releaseURL: pending.releaseURL
        )
        phase = .failed(
            "ORE downloaded \(Self.displayVersion(pending.version)) but the install "
                + "didn't finish. Try again."
        )
    }

    // MARK: - Version comparison

    /// Semantic-ish comparison of dotted version strings, tolerant of a leading
    /// `v` and of differing component counts (`1.2` vs `1.2.0`). Non-numeric
    /// junk sorts as 0 so a malformed tag can't masquerade as newer.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = components(candidate)
        let rhs = components(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// `0.2.0` and `v0.2.0` both render as `v0.2.0` in the prompt.
    nonisolated static func displayVersion(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") { return trimmed }
        return "v\(trimmed)"
    }

    private static func components(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    // MARK: - GitHub access

    private nonisolated static func latestRelease(repository: String) async -> Available? {
        let path = "repos/\(repository)/releases/latest"
        var json = await ghAPI(path: path)
        if json == nil { json = await publicAPI(path: path) }
        guard let json, let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return nil }
        return parse(object)
    }

    nonisolated static func parse(_ object: [String: Any]) -> Available? {
        guard let tag = object["tag_name"] as? String,
              let urlString = object["html_url"] as? String,
              let releaseURL = URL(string: urlString)
        else { return nil }

        let asset = (object["assets"] as? [[String: Any]]).flatMap(preferredAsset(from:))
        return Available(
            version: tag,
            title: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag,
            releaseURL: releaseURL,
            downloadURL: asset?.url,
            assetName: asset?.name,
            assetID: asset?.id
        )
    }

    /// Disk image first, then a zip; both unpack to an `.app` we can swap in.
    nonisolated static func preferredAsset(
        from assets: [[String: Any]]
    ) -> (name: String, url: URL, id: Int?)? {
        let dmg = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
        let zip = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true }
        guard let chosen = dmg ?? zip,
              let name = chosen["name"] as? String,
              let urlString = chosen["browser_download_url"] as? String,
              let url = URL(string: urlString)
        else { return nil }
        return (name, url, intValue(chosen["id"]))
    }

    /// Uses the signed-in `gh` CLI, which is not subject to the anonymous rate limit.
    private nonisolated static func ghAPI(path: String) async -> Data? {
        guard let gh = executable(named: "gh") else { return nil }
        return await run(gh, ["api", path, "-H", "Accept: application/vnd.github+json"])
    }

    /// The public REST endpoint, for once the repo is public / no `gh`.
    private nonisolated static func publicAPI(path: String) async -> Data? {
        guard let url = URL(string: "https://api.github.com/\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return data
    }

    // MARK: - Download, unpack, replace

    private nonisolated static func downloadInstaller(_ release: Available, into directory: URL) async -> URL? {
        guard !Task.isCancelled else { return nil }
        if let gh = executable(named: "gh") {
            let pattern = release.assetName ?? "*.dmg"
            let status = await runStatus(gh, [
                "release", "download", release.version,
                "-R", Self.repository,
                "-p", pattern,
                "-D", directory.path,
                "--clobber",
            ])
            if status == 0, let found = firstInstaller(in: directory) {
                return found
            }
            guard !Task.isCancelled else { return nil }
            if let id = release.assetID {
                let name = release.assetName
                    ?? release.downloadURL?.lastPathComponent
                    ?? "ORE-update.dmg"
                let destination = directory.appendingPathComponent(name)
                let apiStatus = await runStatus(gh, [
                    "api",
                    "-H", "Accept: application/octet-stream",
                    "repos/\(Self.repository)/releases/assets/\(id)",
                    "--output", destination.path,
                ])
                if apiStatus == 0, FileManager.default.fileExists(atPath: destination.path) {
                    return destination
                }
            }
        }
        guard !Task.isCancelled else { return nil }
        if let url = release.downloadURL, let local = await download(url) {
            let dest = directory.appendingPathComponent(local.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: local, to: dest)
            return dest
        }
        return nil
    }

    private nonisolated static func firstInstaller(in directory: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return items.first { $0.pathExtension.lowercased() == "dmg" }
            ?? items.first { $0.pathExtension.lowercased() == "zip" }
    }

    private nonisolated static func unpackApp(from archive: URL, into work: URL) async throws -> URL {
        let staged = work.appendingPathComponent("ORE.app")
        if archive.pathExtension.lowercased() == "zip" {
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            let status = await runStatus("/usr/bin/ditto", ["-xk", archive.path, unpacked.path])
            guard status == 0 else { throw GitHubUpdateError.copyFailed }
            guard let app = appBundle(in: unpacked) else { throw GitHubUpdateError.noAppInArchive }
            guard await runStatus("/usr/bin/ditto", [app.path, staged.path]) == 0 else {
                throw GitHubUpdateError.copyFailed
            }
            return staged
        }

        guard let plist = await run("/usr/bin/hdiutil", [
            "attach", archive.path,
            "-nobrowse", "-readonly", "-plist",
        ]), let mount = mountPoint(fromPlist: plist) else {
            throw GitHubUpdateError.copyFailed
        }
        defer { _ = runSync("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"]) }
        guard let app = appBundle(in: mount) else { throw GitHubUpdateError.noAppInArchive }
        guard await runStatus("/usr/bin/ditto", [app.path, staged.path]) == 0 else {
            throw GitHubUpdateError.copyFailed
        }
        return staged
    }

    /// Reads the mount point `hdiutil attach -plist` reports.
    nonisolated static func mountPoint(fromPlist data: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]]
        else { return nil }
        for entity in entities {
            if let path = entity["mount-point"] as? String {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Prefers `ORE.app`, then any `.app`, looking at most two directories deep
    /// and skipping the Applications symlink a drag-to-install DMG includes.
    nonisolated static func appBundle(in directory: URL, depth: Int = 0) -> URL? {
        guard depth <= 2 else { return nil }
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let apps = items.filter { $0.pathExtension == "app" }
        if let ore = apps.first(where: { $0.lastPathComponent == "ORE.app" }) { return ore }
        if let any = apps.first { return any }

        for item in items where item.pathExtension != "app" {
            let isLink = (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            guard !isLink else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let nested = appBundle(in: item, depth: depth + 1) { return nested }
        }
        return nil
    }

    /// A build running off a mounted disk image can't replace itself there;
    /// land the new copy in Applications instead.
    nonisolated static func installDestination(currentBundle: URL) -> URL {
        if currentBundle.path.hasPrefix("/Volumes/") {
            return URL(fileURLWithPath: "/Applications/ORE.app")
        }
        return currentBundle
    }

    /// Hands off to a script running as its own launchd job so the swap
    /// happens after this process has actually quit — replacing a running
    /// bundle in-place is racy.
    ///
    /// `launchctl submit`, not `nohup … &`: a helper spawned into the app's
    /// own launchd session dies with the app, which is why past update
    /// attempts left a fully staged bundle and an orphaned script behind
    /// while `/Applications/ORE.app` stayed old. A submitted job runs under
    /// the user's launchd domain and outlives the app that scheduled it.
    private nonisolated static func scheduleReplaceAndRelaunch(from newApp: URL, replacing dest: URL) throws {
        let label = "dev.ore.relaunch.\(UUID().uuidString.prefix(8))"
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-relaunch-\(UUID().uuidString).sh")
        let script = relaunchScript(
            newApp: newApp,
            destination: dest,
            pid: ProcessInfo.processInfo.processIdentifier,
            scriptPath: scriptURL.path,
            label: String(label)
        )
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["submit", "-l", String(label), "--", "/bin/bash", scriptURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitHubUpdateError.relaunchFailed }
    }

    /// The swap script: wait out the app, replace the bundle, relaunch, clean
    /// up. `launchctl remove` SIGTERMs its own job, so it must be the last
    /// line — anything after it never runs.
    ///
    /// The wait is bounded and escalates. `while kill -0` alone made this
    /// script hostage to a quit that never completed: the app sat in
    /// terminate-later limbo, the script slept forever, and the update landed
    /// only whenever the user next quit by hand — which is exactly what "it
    /// upgraded, but only after I restarted it myself" looked like. The app
    /// has its own watchdog now; this is the backstop for the case where even
    /// that can't get the process out.
    ///
    /// The replacement never deletes the installed app before it has a
    /// working copy of the new one. It used to: `rm -rf` on the bundle and
    /// then `ditto`, which means a full disk, a sandbox refusal or a Mac
    /// going to sleep in between left the user with no ORE at all and a
    /// staged copy in a temporary directory they would never find. Now the
    /// new bundle is copied next to the destination, checked, and only then
    /// swapped in — with the old one kept aside until that has worked, and
    /// put back if it hasn't.
    nonisolated static func relaunchScript(
        newApp: URL,
        destination: URL,
        pid: Int32,
        scriptPath: String,
        label: String,
        logPath: String = defaultLogPath
    ) -> String {
        let src = shellQuote(newApp.path)
        let dst = shellQuote(destination.path)
        let destinationDirectory = shellQuote(destination.deletingLastPathComponent().path)
        let staging = shellQuote(newApp.deletingLastPathComponent().path)
        return """
        #!/bin/bash
        PID=\(pid)
        SRC=\(src)
        DST=\(dst)
        DEST_DIR=\(destinationDirectory)
        STAGING=\(staging)
        LOG=\(shellQuote(logPath))
        INCOMING="$DEST_DIR/.ORE.app.incoming.$$"
        PREVIOUS="$DEST_DIR/.ORE.app.previous.$$"

        /bin/mkdir -p "$(/usr/bin/dirname "$LOG")" 2>/dev/null
        log() { printf '%s %s\\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG" 2>/dev/null; }

        # Whatever went wrong, the user ends up with a working ORE: either the
        # one they had, or the new one. The log is the only evidence left of a
        # swap that happened after the app was gone.
        give_up() {
          log "update failed: $*"
          /bin/rm -rf "$INCOMING"
          if [ -d "$PREVIOUS" ] && [ ! -e "$DST" ]; then
            /bin/mv "$PREVIOUS" "$DST" && log "restored the previous ORE.app"
          fi
          /bin/rm -rf "$PREVIOUS"
          [ -e "$DST" ] && /usr/bin/open "$DST"
          /bin/rm -rf "$STAGING"
          /bin/rm -f \(shellQuote(scriptPath))
          /bin/launchctl remove \(shellQuote(label))
        }

        wait_for_exit() {
          deadline=$((SECONDS + $1))
          while /bin/kill -0 "$PID" 2>/dev/null; do
            if [ "$SECONDS" -ge "$deadline" ]; then return 1; fi
            /bin/sleep 0.2
          done
          return 0
        }
        wait_for_exit \(gracefulQuitSeconds) || /bin/kill -TERM "$PID" 2>/dev/null
        wait_for_exit \(terminateSeconds) || /bin/kill -KILL "$PID" 2>/dev/null
        wait_for_exit \(killSeconds)
        /bin/sleep 0.3

        log "installing $SRC into $DST"

        # On the destination volume, so the slow part is the copy and the
        # irreversible part is a rename.
        /bin/rm -rf "$INCOMING"
        if ! /usr/bin/ditto "$SRC" "$INCOMING"; then
          give_up "could not copy the new app into $DEST_DIR"
          exit 1
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$INCOMING" 2>/dev/null

        # An update that cannot be verified is not installed. A truncated
        # download, a half-unpacked archive or a broken seal all land here,
        # and all of them would otherwise replace a working app with one
        # macOS refuses to launch.
        if [ ! -x "$INCOMING/Contents/MacOS/OreMac" ]; then
          give_up "the copied app has no executable"
          exit 1
        fi
        if ! /usr/bin/codesign --verify --deep --strict "$INCOMING" 2>>"$LOG"; then
          give_up "the copied app failed signature verification"
          exit 1
        fi

        if [ -e "$DST" ]; then
          /bin/rm -rf "$PREVIOUS"
          if ! /bin/mv "$DST" "$PREVIOUS"; then
            give_up "could not move the installed app aside"
            exit 1
          fi
        fi
        if ! /bin/mv "$INCOMING" "$DST"; then
          give_up "could not move the new app into place"
          exit 1
        fi

        log "installed; reopening"
        /usr/bin/open "$DST" || log "could not reopen $DST"
        /bin/rm -rf "$PREVIOUS"
        /bin/rm -rf "$STAGING"
        /bin/rm -f \(shellQuote(scriptPath))
        /bin/launchctl remove \(shellQuote(label))
        """
    }

    /// Where the swap script writes what it did. Inside the app's own state
    /// directory, because by the time it runs there is no app to report to.
    nonisolated static var defaultLogPath: String {
        let home = ProcessInfo.processInfo.environment["ORE_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("ore", isDirectory: true).path
        return (home as NSString).appendingPathComponent("update.log")
    }

    /// How long the script gives each stage of getting the old app out: its
    /// own quit, then SIGTERM, then SIGKILL. The first is generous because a
    /// normal quit stops agents and flushes drafts.
    nonisolated static let gracefulQuitSeconds = 25
    nonisolated static let terminateSeconds = 10
    nonisolated static let killSeconds = 5

    nonisolated static func shellQuote(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private nonisolated static func download(_ url: URL) async -> URL? {
        // The async API is cancellation-aware, so Cancel actually stops the
        // transfer instead of letting it run to the 7-day resource timeout.
        guard let (temp, response) = try? await URLSession.shared.download(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        // Move to a stably-named file so Finder shows the real installer
        // name rather than a `CFNetworkDownload_xxxx.tmp` scratch file.
        let name = url.lastPathComponent.isEmpty ? "ORE-update.dmg" : url.lastPathComponent
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Waits for a child without ever waiting forever: exit is observed via
    /// the termination handler, a deadline terminates a wedged child, and
    /// task cancellation terminates it early. The old `waitUntilExit` had
    /// none of that — a child that never exited pinned the update (and the
    /// modal above it) for good.
    private nonisolated static func awaitExit(
        of process: Process,
        timeout: Duration
    ) async -> Int32? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(returning: nil)
                    return
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    if process.isRunning { process.terminate() }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private nonisolated static func run(
        _ launchPath: String,
        _ arguments: [String],
        timeout: Duration = .seconds(120)
    ) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // stderr goes nowhere rather than into a Pipe nobody drains — a
        // chatty child filling the 64KB buffer deadlocks against the wait.
        process.standardError = FileHandle.nullDevice
        let handle = pipe.fileHandleForReading
        // Drain stdout concurrently for the same reason.
        let reader = Task.detached { handle.readDataToEndOfFile() }
        let status = await awaitExit(of: process, timeout: timeout)
        let data = await reader.value
        return status == 0 ? data : nil
    }

    private nonisolated static func runStatus(
        _ launchPath: String,
        _ arguments: [String],
        timeout: Duration = .seconds(600)
    ) async -> Int32? {
        guard !Task.isCancelled else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await awaitExit(of: process, timeout: timeout)
    }

    /// Synchronous helper for cleanup that has to finish before we return
    /// (unmounting a DMG after the app has been copied out).
    private nonisolated static func runSync(_ launchPath: String, _ arguments: [String]) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return nil
        }
    }

    private nonisolated static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    /// Resolves a CLI by name across the usual install locations, since a GUI
    /// app launched from Finder doesn't inherit a shell's `PATH`.
    private nonisolated static func executable(named name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Modal prompt: Update installs and restarts; Later snoozes until next launch.
struct GitHubUpdatePrompt: View {
    @Environment(GitHubUpdater.self) private var updater

    var body: some View {
        if updater.showsPrompt {
            ZStack {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())

                if let completed = updater.completedVersion {
                    completionCard(completed)
                } else if let available = updater.available {
                    card(for: available)
                }
            }
            .transition(.opacity)
            .animation(.smooth(duration: 0.25), value: updater.showsPrompt)
        }
    }

    /// The first thing the new build shows after a successful restart: the
    /// update reported itself finished instead of just being gone.
    private func completionCard(_ version: String) -> some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.md) {
            HStack(spacing: OreTheme.Space.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("ORE is up to date")
                    .font(.system(size: OreTheme.Font.display, weight: .semibold))
            }

            Text("Updated to \(GitHubUpdater.displayVersion(version)).")
                .font(.system(size: OreTheme.Font.title))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { updater.acknowledgeCompletion() }
                    .buttonStyle(OrePrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 420, alignment: .leading)
        .oreCard(padding: OreTheme.Space.lg, radius: 16)
    }

    private func card(for available: GitHubUpdater.Available) -> some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.md) {
            HStack(spacing: OreTheme.Space.sm) {
                Image(systemName: updater.isInstalling
                    ? "arrow.down.circle"
                    : "arrow.down.app.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: OreTheme.Font.display, weight: .semibold))
            }

            Text(message(for: available))
                .font(.system(size: OreTheme.Font.title))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if updater.isInstalling {
                ProgressView()
                    .controlSize(.small)
            }

            HStack(spacing: OreTheme.Space.sm) {
                Spacer()
                // A download must stay escapable: this was the modal
                // that trapped the whole app when an install wedged.
                // Only the brief final swap disables the way out.
                Button(updater.phase == .downloading ? "Cancel" : "Later") {
                    if updater.phase == .downloading {
                        updater.cancelInstall()
                    } else {
                        updater.dismiss()
                    }
                }
                    .buttonStyle(OreSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(updater.phase == .installing || updater.phase == .restarting)

                Button(actionTitle(for: available)) { updater.install() }
                    .buttonStyle(OrePrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(updater.isInstalling)
            }
        }
        .frame(width: 420, alignment: .leading)
        .oreCard(padding: OreTheme.Space.lg, radius: 16)
    }

    private var title: String {
        if updater.isInstalling { return "Updating ORE" }
        if updater.isFailed { return "Update failed" }
        return "Update available"
    }

    private func message(for available: GitHubUpdater.Available) -> String {
        let version = GitHubUpdater.displayVersion(available.version)
        switch updater.phase {
        case .downloading:
            return "Downloading \(version)…"
        case .installing:
            return "Installing \(version)…"
        case .restarting:
            return "Restarting to finish installing \(version)…"
        case .failed(let detail):
            return detail
        case .idle:
            return "\(available.title.isEmpty ? "ORE" : available.title) is ready. The app will restart to finish installing."
        }
    }

    private func actionTitle(for available: GitHubUpdater.Available) -> String {
        switch updater.phase {
        case .downloading:
            return "Downloading…"
        case .installing:
            return "Installing…"
        case .restarting:
            return "Restarting…"
        case .failed:
            return "Try Again"
        case .idle:
            return "Update to \(GitHubUpdater.displayVersion(available.version))"
        }
    }
}

/// The "Update Available" menu item, shown only for a build that isn't wired to
/// Sparkle and actually has a newer GitHub release waiting.
struct GitHubUpdateCommand: View {
    @Environment(GitHubUpdater.self) private var updater

    var body: some View {
        if let available = updater.available {
            Button(menuTitle(for: available)) {
                updater.install()
            }
            .disabled(updater.isInstalling)
        }
    }

    private func menuTitle(for available: GitHubUpdater.Available) -> String {
        let version = GitHubUpdater.displayVersion(available.version)
        switch updater.phase {
        case .downloading: return "Downloading \(version)…"
        case .installing: return "Installing \(version)…"
        case .restarting: return "Restarting to finish \(version)…"
        default: return "Update to \(version)"
        }
    }
}
