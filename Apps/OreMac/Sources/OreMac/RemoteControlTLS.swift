import CryptoKit
import Foundation
import Network
import OreSupport
import Security

/// Local HTTPS for the remote-control listener.
///
/// Café Wi-Fi would otherwise carry the pairing token, transcripts, and
/// permission prompts in the clear. A self-signed identity stored under
/// `OreHome` is enough for Safari to encrypt the hop after the first
/// certificate warning. If a certificate cannot be issued, the listener
/// stays on TCP and pairing URLs omit LAN addresses.
enum RemoteControlTLS {
    private static let passphrase = "ore-remote"
    private static let identityName = "remote-control.p12"

    /// SHA-256 of the listener certificate, colon-separated hex. Shown in
    /// Settings so a Tailscale Safari warning can be compared; it is not a
    /// pin Safari will enforce.
    static func certificateFingerprint() -> String? {
        guard let identity = loadOrCreateIdentity() else { return nil }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate
        else { return nil }
        let der = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: der)
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func listenerParameters() -> (NWParameters, usesTLS: Bool) {
        if let identity = loadOrCreateIdentity(),
           let secIdentity = sec_identity_create(identity) {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(
                tls.securityProtocolOptions,
                secIdentity
            )
            sec_protocol_options_set_min_tls_protocol_version(
                tls.securityProtocolOptions,
                .TLSv12
            )
            let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            configure(parameters)
            return (parameters, true)
        }
        let parameters = NWParameters.tcp
        configure(parameters)
        return (parameters, false)
    }

    private static func configure(_ parameters: NWParameters) {
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
    }

    private static func identityURL() -> URL {
        OreHome.directory.appendingPathComponent(identityName)
    }

    private static func loadOrCreateIdentity() -> SecIdentity? {
        let url = identityURL()
        if let data = try? Data(contentsOf: url), let identity = importPKCS12(data) {
            return identity
        }
        guard generatePKCS12(at: url),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return importPKCS12(data)
    }

    private static func importPKCS12(_ data: Data) -> SecIdentity? {
        let options = [kSecImportExportPassphrase as String: passphrase] as CFDictionary
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
              let array = items as? [[String: Any]],
              let raw = array.first?[kSecImportItemIdentity as String]
        else { return nil }
        return (raw as! SecIdentity)
    }

    private static func generatePKCS12(at url: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let scratch = fm.temporaryDirectory.appendingPathComponent("ore-remote-tls-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            return false
        }
        defer { try? fm.removeItem(at: scratch) }
        let key = scratch.appendingPathComponent("key.pem")
        let cert = scratch.appendingPathComponent("cert.pem")
        let p12 = scratch.appendingPathComponent("identity.p12")
        guard run("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650", "-nodes",
            "-keyout", key.path, "-out", cert.path, "-subj", "/CN=ORE Remote",
        ]),
            run("/usr/bin/openssl", [
                "pkcs12", "-export", "-inkey", key.path, "-in", cert.path,
                "-out", p12.path, "-passout", "pass:\(passphrase)",
            ])
        else { return false }
        do {
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            try fm.copyItem(at: p12, to: url)
            return true
        } catch {
            return false
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// Bounds for the remote HTTP parser. Unauthenticated requests used to be
/// able to pass a negative `Content-Length` into `Data.prefix` / `index`,
/// which traps, and there was no cap on header or body size.
enum RemoteHTTPLimits {
    static let maxHeaderBytes = 32 * 1024
    static let maxBodyBytes = 64 * 1024
    static let maxSessions = 8
    static let idleTimeout: Duration = .seconds(30)
    static let maxLifetime: Duration = .seconds(120)

    /// Headers stop at `\r\n\r\n`. Bytes after that are body, so a legal
    /// request whose first packet includes a large body must not be treated
    /// as an oversized header block.
    static func headersTooLarge(_ buffer: Data) -> Bool {
        let needle = Data("\r\n\r\n".utf8)
        if let range = buffer.range(of: needle) {
            return buffer.distance(from: buffer.startIndex, to: range.lowerBound) > maxHeaderBytes
        }
        return buffer.count > maxHeaderBytes
    }

    enum ContentLength: Equatable {
        case missing
        case valid(Int)
        case invalid
    }

    static func contentLength(from headers: String) -> ContentLength {
        var found: ContentLength = .missing
        for raw in headers.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("content-length:") else { continue }
            let value = line.dropFirst("content-length:".count)
                .trimmingCharacters(in: .whitespaces)
            guard let length = Int(value), length >= 0, length <= maxBodyBytes else {
                return .invalid
            }
            found = .valid(length)
        }
        return found
    }
}
