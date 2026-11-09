import AppKit
import Foundation

/// Live Tailscale state on this Mac, from the official CLI — not a guess
/// from `utun` addresses.
///
/// Café access for remote control is Tailscale on **both** this Mac and the
/// iPad, same account. ORE never talks to Tailscale's cloud; it only reads
/// the local `status` JSON so Settings can show the right QR.
struct TailscaleStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case missing
        case installed
        case needsLogin
        case stopped
        case connected(ipv4: String, magicDNS: String?, tailnet: String?)
    }

    var kind: Kind
    var appURL: URL?

    static let macDownloadURL = URL(string: "https://tailscale.com/download/mac")!
    static let iPadAppStoreURL = URL(string: "https://apps.apple.com/app/tailscale/id1475387142")!

    var isConnected: Bool {
        if case .connected = kind { return true }
        return false
    }

    var ipv4: String? {
        if case .connected(let ipv4, _, _) = kind { return ipv4 }
        return nil
    }

    var magicDNS: String? {
        if case .connected(_, let dns, _) = kind { return dns }
        return nil
    }

    /// Host the iPad should open: MagicDNS when the tailnet has it, else the
    /// 100.x address.
    var preferredHost: String? { magicDNS ?? ipv4 }

    @MainActor
    static func probe() async -> TailscaleStatus {
        let appURL = applicationURL()
        let executable = cliURL()?.path ?? appURL.map {
            $0.appendingPathComponent("Contents/MacOS/Tailscale").path
        }
        guard let executable, FileManager.default.isExecutableFile(atPath: executable) else {
            return TailscaleStatus(
                kind: appURL == nil ? .missing : .installed,
                appURL: appURL
            )
        }
        let data = await Task.detached(priority: .utility) {
            run(executable: executable, arguments: ["status", "--json"])
        }.value
        guard let data, let kind = parse(data) else {
            return TailscaleStatus(kind: .installed, appURL: appURL)
        }
        return TailscaleStatus(kind: kind, appURL: appURL)
    }

    /// `tailscale status --json` → the cases Settings can act on.
    static func parse(_ data: Data) -> Kind? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let backend = (object["BackendState"] as? String ?? "").lowercased()
        if backend == "needslogin" { return .needsLogin }
        if backend != "running" { return .stopped }

        let peer = object["Self"] as? [String: Any]
        let ips = peer?["TailscaleIPs"] as? [String] ?? []
        let ipv4 = ips.first { !$0.contains(":") }
        guard let ipv4 else { return .stopped }

        let tailnet = object["CurrentTailnet"] as? [String: Any]
        let magicEnabled = tailnet?["MagicDNSEnabled"] as? Bool ?? true
        let dns = magicEnabled ? sanitizedDNS(peer?["DNSName"] as? String) : nil
        let name = tailnet?["Name"] as? String
        return .connected(ipv4: ipv4, magicDNS: dns, tailnet: name)
    }

    static func sanitizedDNS(_ raw: String?) -> String? {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        while name.hasSuffix(".") { name.removeLast() }
        name = name.lowercased()
        guard name.contains("."), !name.contains(" ") else { return nil }
        return name
    }

    @MainActor
    static func openOrInstall() {
        if let app = applicationURL() {
            NSWorkspace.shared.open(app)
        } else {
            NSWorkspace.shared.open(macDownloadURL)
        }
    }

    @MainActor
    static func openIPadInstructions() {
        NSWorkspace.shared.open(iPadAppStoreURL)
    }

    @MainActor
    private static func applicationURL() -> URL? {
        let ids = ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"]
        for id in ids {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return url
            }
        }
        let bundled = URL(fileURLWithPath: "/Applications/Tailscale.app")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return nil
    }

    nonisolated private static func cliURL() -> URL? {
        for path in [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    nonisolated private static func run(executable: String, arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + .seconds(2)
        let timedOut = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
            if process.isRunning { process.terminate() }
            timedOut.signal()
        }
        process.waitUntilExit()
        timedOut.signal()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }
}
