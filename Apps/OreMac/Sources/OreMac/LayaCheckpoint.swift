import CryptoKit
import Foundation
import OrePersistence

/// On-disk English Laya snapshot and the Hugging Face tree that fills it.
///
/// A `config.json` by itself is not a checkpoint — the first install wrote
/// an empty marker and Settings treated that as "already downloaded".
enum LayaCheckpoint {
    static let repoID = "convaiinnovations/laya"
    /// Immutable Hugging Face snapshot. The runner imports Python helpers from
    /// this checkout, so never follow mutable branches here.
    static let revision = "fe2b7719c095b82cdb2bfeedefc1fee30e506c21"

    static let trustedExecutableHashes: [String: String] = [
        "email_utils.py": "1b1c0a6e23251ac8cae81e723bc98a31ca5483522c742937e263c2ecee42f343",
        "rl_agent_api.py": "be3b46819c9999c3ef88e0f2ecf6d3ab1cdfed1d9a8b466fc89811e34d44031b",
        "rl_common.py": "8d83611d480c971d640a7b7d3aa2f2219c5e8455e9cc2329fd073681bd8be23e",
    ]

    static var cacheDirectory: URL {
        OreHome.directory.appending(path: "models/laya/en", directoryHint: .isDirectory)
    }

    static var configURL: URL {
        cacheDirectory.appending(path: "config.json")
    }

    /// `~/ore/models/laya` — venv, serve script, and language snapshots.
    static var runtimeRoot: URL {
        OreHome.directory.appending(path: "models/laya", directoryHint: .isDirectory)
    }

    static var venvPython: URL {
        runtimeRoot.appending(path: ".venv/bin/python")
    }

    static var serveScript: URL {
        runtimeRoot.appending(path: "laya_serve.py")
    }

    /// Prefer the typed-decisions head when the snapshot includes it.
    static var modelDirectory: URL {
        let typed = cacheDirectory.appending(path: "typed-decisions", directoryHint: .isDirectory)
        let typedWeights = typed.appending(path: "model.safetensors")
        if FileManager.default.fileExists(atPath: typedWeights.path) { return typed }
        return cacheDirectory
    }

    struct RemoteFile: Equatable, Sendable {
        var path: String
        var size: Int64
    }

    struct TreeListing: Equatable, Sendable {
        var files: [RemoteFile]
        var directories: [String]
    }

    static func shouldDownload(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix(".") { return false }
        switch name.lowercased() {
        case "readme.md", "readme", "license", "license.md", "notice", "notice.md":
            return false
        default:
            return true
        }
    }

    static func isWeightFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        switch ext {
        case "safetensors", "bin", "onnx", "pt", "pth", "gguf",
             "mlmodel", "mlpackage", "weights":
            return true
        default:
            return name.contains("model") && ext != "json" && ext != "md"
        }
    }

    static func weightsArePresent(in directory: URL = cacheDirectory) -> Bool {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            if isWeightFile(url.lastPathComponent) { return true }
            if (values?.fileSize ?? 0) > 50_000, url.pathExtension.lowercased() != "json" {
                return true
            }
        }
        return false
    }

    static func verifyTrustedExecutableFiles(in directory: URL = cacheDirectory) throws {
        for (path, expected) in trustedExecutableHashes {
            let url = directory.appending(path: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LayaInstallError.untrustedExecutable(path: path, reason: "missing")
            }
            let actual = try sha256Hex(of: url)
            guard actual == expected else {
                throw LayaInstallError.untrustedExecutable(path: path, reason: "SHA-256 mismatch")
            }
        }
    }

    /// Hugging Face `/tree/` JSON: an array of file/dir entries.
    static func parseTree(_ data: Data) throws -> TreeListing {
        let object = try JSONSerialization.jsonObject(with: data)
        if let error = (object as? [String: Any])?["error"] as? String, !error.isEmpty {
            throw LayaInstallError.listing(error)
        }
        guard let rows = object as? [[String: Any]] else {
            throw LayaInstallError.listing("Unexpected Hugging Face listing.")
        }
        var files: [RemoteFile] = []
        var directories: [String] = []
        for row in rows {
            let path = row["path"] as? String ?? ""
            guard !path.isEmpty else { continue }
            switch row["type"] as? String {
            case "directory":
                directories.append(path)
            case "file":
                let lfs = row["lfs"] as? [String: Any]
                let size = int64(lfs?["size"]) ?? int64(row["size"]) ?? 0
                files.append(RemoteFile(path: path, size: size))
            default:
                continue
            }
        }
        return TreeListing(files: files, directories: directories)
    }

    static func treeURL(directory: String = "", recursive: Bool = false) -> URL {
        var url = URL(string: "https://huggingface.co/api/models/\(repoID)/tree/\(revision)")!
        if !directory.isEmpty {
            for part in directory.split(separator: "/") {
                url.append(path: String(part))
            }
        }
        guard recursive else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        return components?.url ?? url
    }

    static func resolveURL(_ path: String) -> URL {
        var url = URL(string: "https://huggingface.co/\(repoID)/resolve/\(revision)")!
        for part in path.split(separator: "/") {
            url.append(path: String(part))
        }
        return url
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? Int64 { return number }
        if let number = value as? Int { return Int64(number) }
        if let number = value as? NSNumber { return number.int64Value }
        if let number = value as? Double { return Int64(number) }
        return nil
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum LayaInstallError: LocalizedError, Equatable {
    case listing(String)
    case emptySnapshot
    case http(path: String, status: Int)
    case untrustedExecutable(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .listing(let message):
            return "Couldn't list the Laya checkpoint. \(message)"
        case .emptySnapshot:
            return "The Laya repository listed no model files to download."
        case .http(let path, let status):
            return "Couldn't download \(path) (HTTP \(status))."
        case .untrustedExecutable(let path, let reason):
            return "The pinned Laya runner file \(path) could not be trusted: \(reason)."
        }
    }
}
