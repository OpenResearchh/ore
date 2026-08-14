import AppKit
import SwiftUI

/// A lightweight update check against the project's GitHub Releases.
///
/// Sparkle (`Updater`) is the real path, but it stays disabled until a build is
/// signed and pointed at an appcast — which is every build we hand each other
/// today. This fills that gap: it asks GitHub for the latest release, and if
/// this build is behind, offers to download and open it.
///
/// Auth is the trick that makes it work *now*, while the repo is private: it
/// shells out to `gh api` when the CLI is signed in (which it is, since ORE
/// drives it), and falls back to the public REST endpoint so the same code
/// keeps working once the repo is public or for a user without `gh`.
@MainActor
@Observable
final class GitHubUpdater {
    struct Available: Equatable {
        var version: String
        var title: String
        var releaseURL: URL
        /// The installable asset (`.dmg`/`.zip`), when the release ships one.
        var downloadURL: URL?
    }

    private(set) var available: Available?
    private(set) var isChecking = false
    private(set) var isInstalling = false

    /// `owner/repo` this build updates from.
    static let repository = "OpenResearchh/ore"

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
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
        available = release
    }

    /// Downloads the release's installer and opens it (drag-to-Applications),
    /// or opens the release page when there's no asset to download.
    func install() {
        guard let available else { return }
        guard let download = available.downloadURL else {
            NSWorkspace.shared.open(available.releaseURL)
            return
        }
        isInstalling = true
        Task {
            defer { isInstalling = false }
            if let local = await Self.download(download) {
                NSWorkspace.shared.open(local)
            } else {
                NSWorkspace.shared.open(available.releaseURL)
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

    private nonisolated static func parse(_ object: [String: Any]) -> Available? {
        guard let tag = object["tag_name"] as? String,
              let urlString = object["html_url"] as? String,
              let releaseURL = URL(string: urlString)
        else { return nil }

        var download: URL?
        if let assets = object["assets"] as? [[String: Any]] {
            // Prefer a disk image, then a zip; both install by opening.
            let preferred = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
                ?? assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
            download = (preferred?["browser_download_url"] as? String).flatMap(URL.init(string:))
        }
        return Available(
            version: tag,
            title: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag,
            releaseURL: releaseURL,
            downloadURL: download
        )
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

/// The "Update Available" menu item, shown only for a build that isn't wired to
/// Sparkle and actually has a newer GitHub release waiting.
struct GitHubUpdateCommand: View {
    @Environment(GitHubUpdater.self) private var updater

    var body: some View {
        if let available = updater.available {
            Button(updater.isInstalling
                ? "Downloading \(available.version)…"
                : "Update to \(available.version)…") {
                updater.install()
            }
            .disabled(updater.isInstalling)
        }
    }
}
