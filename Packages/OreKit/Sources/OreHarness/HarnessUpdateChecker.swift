import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OreProtocol

/// Asks each agent CLI's install channel what version it is publishing.
///
/// The channel is the same one `HarnessCLIUpdater` would upgrade through — the
/// plan picks it, this reads it. That symmetry is the whole point: querying npm
/// for a Homebrew install would advertise versions `brew upgrade` cannot fetch
/// yet, and a card offering an upgrade that doesn't change the version is worse
/// than no card at all.
///
/// Every failure is silent and non-fatal. A harness whose channel is
/// unreachable reports `failure` and keeps working; nothing here can make an
/// installed CLI look broken.
public enum HarnessUpdateChecker {
    /// Where the "what's the latest?" answer comes from.
    public enum Source: Equatable, Sendable {
        case homebrew(token: String)
        case npm(package: String)
        /// Cursor publishes no version API; its install script names the build
        /// it is about to fetch, which is exactly what an upgrade would land.
        case cursorInstallScript
        case unknown

        public var url: URL? {
            switch self {
            case .homebrew(let token):
                return URL(string: "https://formulae.brew.sh/api/cask/\(token).json")
            case .npm(let package):
                return URL(string: "https://registry.npmjs.org/\(package)/latest")
            case .cursorInstallScript:
                // The same URL the update itself would fetch — read from the
                // one list rather than written out again here, so the oracle
                // cannot end up reporting a version from a different script
                // than the one `nativeInstaller` runs.
                return URL(string: HarnessKind.cursorAgent.nativeInstallerURL)
            case .unknown:
                return nil
            }
        }

        /// Homebrew splits packages across two API namespaces and both of ORE's
        /// harnesses currently ship as casks. Try the other one before giving up
        /// rather than pinning the feature to today's packaging.
        var fallbackURL: URL? {
            guard case .homebrew(let token) = self else { return nil }
            return URL(string: "https://formulae.brew.sh/api/formula/\(token).json")
        }
    }

    /// Fetches a URL's body, or nil for anything that isn't a 2xx.
    public typealias Fetcher = @Sendable (URL) async -> Data?

    /// - Parameter isBrewAvailable: passed straight through to the plan, so
    ///   the oracle and the upgrade can never disagree about whether this
    ///   machine has Homebrew.
    public static func source(
        for kind: HarnessKind,
        executablePath: String?,
        isBrewAvailable: Bool = HarnessCLIUpdater.brewIsAvailable()
    ) -> Source {
        switch HarnessCLIUpdater.plan(
            for: kind, executablePath: executablePath, isBrewAvailable: isBrewAvailable
        ) {
        case .brew(let formula):
            // Whatever token the plan resolved, including `claude-code@latest`:
            // reading the stable cask for a user on the @latest one reports a
            // release a week behind what their own `brew upgrade` would fetch.
            return .homebrew(token: formula)
        case .npm(let package):
            return .npm(package: package)
        case .selfUpdate:
            // `codex update` and `claude update` both pull from the same release
            // stream the npm package publishes, so npm is the version oracle
            // even when the upgrade itself goes through the CLI.
            return kind.npmPackage.map(Source.npm(package:)) ?? .unknown
        case .nativeInstaller:
            // A Homebrew install ORE has no formula for (today: cursor-agent)
            // falls through `plan` to the vendor's install script. Reading the
            // version from that script would advertise an upgrade that lands a
            // second copy in front of the brew one, so say ORE can't tell where
            // it came from — the honest answer, and the one that suppresses the
            // card rather than offering the wrong channel.
            //
            // Only while Homebrew is actually installed, though: once it is
            // gone the vendor's script is not a rival to a maintained copy,
            // it is the only channel left — and suppressing the card there
            // strands the user on whatever version the migration left behind.
            if let executablePath, HarnessCLIUpdater.isHomebrewPath(executablePath),
               isBrewAvailable {
                return .unknown
            }
            if kind == .cursorAgent { return .cursorInstallScript }
            return kind.npmPackage.map(Source.npm(package:)) ?? .unknown
        }
    }

    /// Compares one harness's installed version against its channel.
    public static func check(
        kind: HarnessKind,
        installedVersion: String?,
        executablePath: String?,
        fetch: Fetcher = Self.fetch,
        isBrewAvailable: Bool = HarnessCLIUpdater.brewIsAvailable()
    ) async -> HarnessUpdateStatus {
        let installed = HarnessVersion.normalize(installedVersion)
        let source = source(
            for: kind, executablePath: executablePath, isBrewAvailable: isBrewAvailable
        )
        let command = HarnessCLIUpdater.script(
            for: HarnessCLIUpdater.plan(
                for: kind, executablePath: executablePath, isBrewAvailable: isBrewAvailable
            )
        )

        guard installed != nil else {
            return HarnessUpdateStatus(
                kind: kind,
                updateCommand: command,
                failure: "\(kind.displayName) did not report a version."
            )
        }
        guard source != .unknown else {
            return HarnessUpdateStatus(
                kind: kind,
                installedVersion: installed,
                updateCommand: command,
                failure: "ORE can't tell where \(kind.displayName) was installed from."
            )
        }

        guard let latest = await latestVersion(from: source, fetch: fetch) else {
            return HarnessUpdateStatus(
                kind: kind,
                installedVersion: installed,
                updateCommand: command,
                failure: "Couldn't reach \(kind.displayName)'s update channel."
            )
        }
        return HarnessUpdateStatus(
            kind: kind,
            installedVersion: installed,
            latestVersion: latest,
            updateCommand: command
        )
    }

    public static func latestVersion(from source: Source, fetch: Fetcher = Self.fetch) async -> String? {
        guard let url = source.url else { return nil }
        switch source {
        case .homebrew:
            if let data = await fetch(url), let version = parseHomebrewVersion(data) { return version }
            guard let fallback = source.fallbackURL, let data = await fetch(fallback) else { return nil }
            return parseHomebrewVersion(data)
        case .npm:
            guard let data = await fetch(url) else { return nil }
            return parseNPMVersion(data)
        case .cursorInstallScript:
            guard let data = await fetch(url), let script = String(data: data, encoding: .utf8)
            else { return nil }
            return parseCursorInstallScript(script)
        case .unknown:
            return nil
        }
    }

    // MARK: - Parsing

    static func parseNPMVersion(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return HarnessVersion.normalize(object["version"] as? String)
    }

    /// Casks report a flat `version`; formulae nest it under `versions.stable`.
    /// A cask version can carry a build after a comma (`1.2.3,4567`) — the part
    /// before it is the one that matches what the CLI prints.
    static func parseHomebrewVersion(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let raw = (object["version"] as? String)
            ?? ((object["versions"] as? [String: Any])?["stable"] as? String)
        return HarnessVersion.normalize(raw?.split(separator: ",").first.map(String.init))
    }

    /// The installer unpacks into `…/versions/<build>/`, and names that build
    /// several times. Any occurrence is the version it would install.
    static func parseCursorInstallScript(_ script: String) -> String? {
        guard let range = script.range(of: "versions/[0-9][A-Za-z0-9._-]*", options: .regularExpression)
        else { return nil }
        return String(script[range].dropFirst("versions/".count))
    }

    // MARK: - Transport

    /// A short timeout on purpose: this runs in the background behind the app's
    /// own launch work, and a hung registry must never hold a probe open.
    private static let fetchTimeout: TimeInterval = 12

    public static let fetch: Fetcher = { url in
        var request = URLRequest(url: url, timeoutInterval: fetchTimeout)
        request.setValue("ore-harness-update-check", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return data
    }
}
