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
/// Auth is the trick that makes it work *now*, while the repo is private: it
/// shells out to `gh` when the CLI is signed in (which it is, since ORE
/// drives it), and falls back to the public REST endpoint so the same code
/// keeps working once the repo is public or for a user without `gh`.
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
        case failed(String)
    }

    private(set) var available: Available?
    private(set) var isChecking = false
    private(set) var phase: Phase = .idle
    /// `Later` hides the popup for this session; the menu item stays so the
    /// user can still install without another launch.
    private(set) var dismissed = false

    /// `owner/repo` this build updates from.
    nonisolated static let repository = "OpenResearchh/ore"

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    var isInstalling: Bool {
        phase == .downloading || phase == .installing
    }

    /// The in-window prompt: shown when a newer release is waiting, while an
    /// install is in flight, or after a failed attempt the user hasn't dismissed.
    var showsPrompt: Bool {
        available != nil && (!dismissed || isInstalling || isFailed)
    }

    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// Looks up the latest release and records it when it's newer than this
    /// build. Safe to call on launch and from the menu; failures are silent —
    /// an update check that can't reach GitHub shouldn't nag.
    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        guard let release = await Self.latestRelease(repository: Self.repository) else { return }
        guard Self.isNewer(release.version, than: currentVersion) else {
            available = nil
            return
        }
        if available != release {
            dismissed = false
            phase = .idle
        }
        available = release
    }

    func dismiss() {
        dismissed = true
        if case .failed = phase { phase = .idle }
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
        phase = .downloading
        Task {
            do {
                let replacement = try await Self.prepareReplacement(from: available)
                phase = .installing
                try Self.scheduleReplaceAndRelaunch(
                    from: replacement,
                    replacing: Self.installDestination(currentBundle: Bundle.main.bundleURL)
                )
                NSApp.terminate(nil)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
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

    /// Uses the signed-in `gh` CLI so the check works against a private repo.
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

    /// Downloads and unpacks the release into a staging copy of `ORE.app`.
    private nonisolated static func prepareReplacement(from release: Available) async throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        guard let archive = await downloadInstaller(release, into: work) else {
            throw GitHubUpdateError.downloadFailed
        }
        return try await unpackApp(from: archive, into: work)
    }

    private nonisolated static func downloadInstaller(_ release: Available, into directory: URL) async -> URL? {
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

    /// Hands off to a detached script so the swap happens after this process
    /// has actually quit — replacing a running bundle in-place is racy.
    private nonisolated static func scheduleReplaceAndRelaunch(from newApp: URL, replacing dest: URL) throws {
        let src = shellQuote(newApp.path)
        let dst = shellQuote(dest.path)
        let staging = shellQuote(newApp.deletingLastPathComponent().path)
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-relaunch-\(UUID().uuidString).sh")
        let script = """
        #!/bin/bash
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/sleep 0.3
        /bin/rm -rf \(dst)
        /usr/bin/ditto \(src) \(dst)
        /usr/bin/xattr -dr com.apple.quarantine \(dst) || true
        /usr/bin/open \(dst)
        /bin/rm -rf \(staging)
        /bin/rm -f \(shellQuote(scriptURL.path))
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            "nohup /bin/bash \(shellQuote(scriptURL.path)) >/dev/null 2>&1 &",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitHubUpdateError.relaunchFailed }
    }

    nonisolated static func shellQuote(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private nonisolated static func download(_ url: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            URLSession.shared.downloadTask(with: url) { temp, response, _ in
                guard let temp,
                      let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    continuation.resume(returning: nil)
                    return
                }
                // Move to a stably-named file so Finder shows the real installer
                // name rather than a `CFNetworkDownload_xxxx.tmp` scratch file.
                let name = url.lastPathComponent.isEmpty ? "ORE-update.dmg" : url.lastPathComponent
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(name)
                try? FileManager.default.removeItem(at: destination)
                do {
                    try FileManager.default.moveItem(at: temp, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(returning: nil)
                }
            }.resume()
        }
    }

    private nonisolated static func run(_ launchPath: String, _ arguments: [String]) async -> Data? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            let handle = pipe.fileHandleForReading
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }
            let data = handle.readDataToEndOfFile()
            process.waitUntilExit()
            continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
        }
    }

    private nonisolated static func runStatus(_ launchPath: String, _ arguments: [String]) async -> Int32? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }
            process.waitUntilExit()
            continuation.resume(returning: process.terminationStatus)
        }
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
        if updater.showsPrompt, let available = updater.available {
            ZStack {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())

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
                        Button("Later") { updater.dismiss() }
                            .buttonStyle(OreSecondaryButtonStyle())
                            .keyboardShortcut(.cancelAction)
                            .disabled(updater.isInstalling)

                        Button(actionTitle(for: available)) { updater.install() }
                            .buttonStyle(OrePrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction)
                            .disabled(updater.isInstalling)
                    }
                }
                .frame(width: 420, alignment: .leading)
                .oreCard(padding: OreTheme.Space.lg, radius: 16)
            }
            .transition(.opacity)
            .animation(.smooth(duration: 0.25), value: updater.showsPrompt)
        }
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
            return "Installing and restarting…"
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
        default: return "Update to \(version)"
        }
    }
}
