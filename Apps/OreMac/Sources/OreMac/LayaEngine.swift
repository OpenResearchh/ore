import Foundation
import Observation
import OreSupport

/// On-device Laya lifecycle: download the English checkpoint onto this Mac,
/// then talk to it only through a loopback System One runner this process
/// starts from those files.
///
/// Weights are never fetched at launch. `prewarm()` only asks whether a
/// local runner is already answering — the same consent rule as the neural
/// voice and the speech model.
@MainActor
@Observable
final class LayaEngine {
    static let shared = LayaEngine()

    enum Readiness: Equatable {
        case unavailable
        case downloading(fraction: Double)
        /// Files are on disk; nothing is answering on loopback yet.
        case installed
        case ready
        case failed(String)

        var buttonTitle: String? {
            switch self {
            case .unavailable: "Download"
            case .failed: "Retry"
            case .installed: "Start"
            case .downloading, .ready: nil
            }
        }
    }

    private(set) var readiness: Readiness = .unavailable
    private var installTask: Task<Void, Never>?
    private var ensureTask: Task<Void, Never>?
    private let runnerToken: String
    private var http: SystemOneHTTPClient
    private var serverProcess: Process?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.httpAdditionalHeaders = [
            "User-Agent": "ORE-LayaEngine/1",
            "Accept": "application/json, */*",
        ]
        return URLSession(configuration: configuration)
    }()

    /// Whether `decide` will actually run. Aliases still work when this is false.
    var isAvailable: Bool {
        if case .ready = readiness { return true }
        return false
    }

    /// Sendable client for the residual gate. Nil when Laya should be skipped.
    var decisionClient: SystemOneHTTPClient? {
        isAvailable ? http : nil
    }

    static var cacheDirectory: URL { LayaCheckpoint.cacheDirectory }

    static func weightsArePresent() -> Bool {
        LayaCheckpoint.weightsArePresent()
    }

    init() {
        let token = UUID().uuidString
        runnerToken = token
        http = SystemOneHTTPClient(authToken: token)
        // Do not probe the network or the daemon here. First paint of
        // Settings will call `refresh()`, and dictation calls `prewarm()`.
        if Self.weightsArePresent() {
            readiness = .installed
        }
    }

    /// Dictation is about to start. Never downloads weights.
    func prewarm() {
        enqueueEnsure(installDependencies: false)
    }

    func refresh() {
        enqueueEnsure(installDependencies: false)
    }

    private func enqueueEnsure(installDependencies: Bool) {
        guard ensureTask == nil else { return }
        ensureTask = Task { [weak self] in
            await self?.ensureRunning(installDependencies: installDependencies)
            self?.ensureTask = nil
        }
    }

    func install() {
        guard installTask == nil else { return }
        installTask = Task { [weak self] in
            await self?.runInstall()
            self?.installTask = nil
        }
    }

    func cancelInstall() {
        installTask?.cancel()
        installTask = nil
        if case .downloading = readiness {
            readiness = Self.weightsArePresent() ? .installed : .unavailable
        }
    }

    private func ensureRunning(installDependencies: Bool) async {
        if case .downloading = readiness, !installDependencies { return }
        if await http.probe() {
            await applyDecidePing()
            return
        }
        guard Self.weightsArePresent() else {
            readiness = .unavailable
            return
        }
        let pythonReady = FileManager.default.isExecutableFile(atPath: LayaCheckpoint.venvPython.path)
        if !installDependencies, !pythonReady {
            readiness = .installed
            return
        }
        do {
            readiness = .downloading(fraction: 0.8)
            if installDependencies {
                try await ensurePythonEnvironment()
            }
            try await startServer()
            if await waitForProbe(seconds: 120) {
                await applyDecidePing()
            } else {
                readiness = .failed("Couldn't start the local Laya runner.")
            }
        } catch is CancellationError {
            readiness = Self.weightsArePresent() ? .installed : .unavailable
        } catch {
            readiness = .failed(error.localizedDescription)
        }
    }

    /// `/v1/models` is not enough — Ready means a System One question returned.
    private func applyDecidePing() async {
        if await http.pingDecide() {
            readiness = .ready
        } else {
            readiness = .failed("The runner is up but Laya is not answering questions.")
        }
    }

    private func runInstall() async {
        readiness = .downloading(fraction: 0)
        if await http.probe() {
            await applyDecidePing()
            return
        }
        if !Self.weightsArePresent() {
            do {
                try await downloadSnapshot()
            } catch is CancellationError {
                readiness = Self.weightsArePresent() ? .installed : .unavailable
                return
            } catch {
                readiness = .failed(error.localizedDescription)
                return
            }
        }
        await ensureRunning(installDependencies: true)
    }

    private func downloadSnapshot() async throws {
        let files = try await listSnapshot()
        let wanted = files.filter { LayaCheckpoint.shouldDownload($0.path) }
        guard !wanted.isEmpty else { throw LayaInstallError.emptySnapshot }

        try FileManager.default.createDirectory(
            at: LayaCheckpoint.cacheDirectory, withIntermediateDirectories: true
        )

        let total = max(wanted.reduce(Int64(0)) { $0 + max($1.size, 1) }, 1)
        var finished: Int64 = 0
        for (index, file) in wanted.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let destination = destinationURL(for: file.path)
            if alreadyHave(file, at: destination) {
                finished += max(file.size, 1)
                readiness = .downloading(fraction: Double(finished) / Double(total) * 0.7)
                continue
            }
            try await download(file, to: destination)
            finished += max(file.size, 1)
            let fraction = Double(finished) / Double(total) * 0.7
            readiness = .downloading(
                fraction: min(0.7, max(fraction, Double(index + 1) / Double(wanted.count) * 0.7))
            )
        }
        guard Self.weightsArePresent() else { throw LayaInstallError.emptySnapshot }
        try LayaCheckpoint.verifyTrustedExecutableFiles()
        readiness = .downloading(fraction: 0.7)
    }

    private func listSnapshot() async throws -> [LayaCheckpoint.RemoteFile] {
        let root = try await fetchTree(directory: "", recursive: true)
        if !root.files.isEmpty, root.directories.isEmpty || root.files.contains(where: { $0.path.contains("/") }) {
            return root.files
        }
        var directories = root.directories
        var files = root.files
        var seen = Set<String>([""])
        while let directory = directories.popLast() {
            if Task.isCancelled { throw CancellationError() }
            guard seen.insert(directory).inserted else { continue }
            let listing = try await fetchTree(directory: directory, recursive: false)
            files.append(contentsOf: listing.files)
            directories.append(contentsOf: listing.directories)
            if files.count > 200 {
                break
            }
        }
        return files
    }

    private func fetchTree(directory: String, recursive: Bool) async throws -> LayaCheckpoint.TreeListing {
        var request = URLRequest(url: LayaCheckpoint.treeURL(directory: directory, recursive: recursive))
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LayaInstallError.http(path: directory.isEmpty ? "listing" : directory, status: http.statusCode)
        }
        return try LayaCheckpoint.parseTree(data)
    }

    private func download(_ file: LayaCheckpoint.RemoteFile, to destination: URL) async throws {
        var request = URLRequest(url: LayaCheckpoint.resolveURL(file.path))
        request.timeoutInterval = 120
        let (location, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LayaInstallError.http(path: file.path, status: http.statusCode)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: location, to: destination)
    }

    private func destinationURL(for path: String) -> URL {
        var url = LayaCheckpoint.cacheDirectory
        for part in path.split(separator: "/") {
            url.append(path: String(part))
        }
        return url
    }

    private func alreadyHave(_ file: LayaCheckpoint.RemoteFile, at url: URL) -> Bool {
        guard file.size > 0 else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        return values?.isRegularFile == true && Int64(values?.fileSize ?? 0) == file.size
    }

    // MARK: - Local runner

    private static func venvCanImport() -> Bool {
        let python = LayaCheckpoint.venvPython.path
        guard FileManager.default.isExecutableFile(atPath: python) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", "import torch, transformers, safetensors, numpy"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try ProcessLaunch.run(process)
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func ensurePythonEnvironment() async throws {
        if Self.venvCanImport() { return }
        readiness = .downloading(fraction: 0.75)
        let root = LayaCheckpoint.runtimeRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment = ShellEnvironment.childEnvironment()
        guard let uv = ShellEnvironment.locate("uv", in: environment)
                ?? ["/opt/homebrew/bin/uv", "/usr/local/bin/uv"].first(where: {
                    FileManager.default.isExecutableFile(atPath: $0)
                })
        else {
            throw LayaInstallError.listing(
                "Laya needs uv (or a Python 3.12 venv with PyTorch) on this Mac."
            )
        }
        try await runDetached(
            executable: uv,
            arguments: ["venv", root.appending(path: ".venv").path, "--python", "3.12"],
            environment: environment
        )
        try await runDetached(
            executable: uv,
            arguments: [
                "pip", "install",
                "--python", LayaCheckpoint.venvPython.path,
                "torch", "transformers", "safetensors", "numpy",
            ],
            environment: environment
        )
        guard Self.venvCanImport() else {
            throw LayaInstallError.listing("The Laya Python environment is missing PyTorch.")
        }
    }

    private func startServer() async throws {
        if await http.probe() { return }
        if let running = serverProcess, running.isRunning { return }
        try LayaCheckpoint.verifyTrustedExecutableFiles()
        try installServeScript()
        let python = LayaCheckpoint.venvPython
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw LayaInstallError.listing("The Laya runner is not installed yet.")
        }
        let process = Process()
        process.executableURL = python
        process.arguments = [
            LayaCheckpoint.serveScript.path,
            "--model-dir", LayaCheckpoint.modelDirectory.path,
            "--host", "127.0.0.1",
            "--port", "11435",
            "--token", runnerToken,
        ]
        process.currentDirectoryURL = LayaCheckpoint.cacheDirectory
        process.environment = ShellEnvironment.childEnvironment()
        let logURL = LayaCheckpoint.runtimeRoot.appending(path: "serve.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: logURL) {
            try? log.seekToEnd()
            process.standardOutput = log
            process.standardError = log
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        try ProcessLaunch.run(process)
        serverProcess = process
        readiness = .downloading(fraction: 0.9)
    }

    private func installServeScript() throws {
        let destination = LayaCheckpoint.serveScript
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let bundled = Self.bundledServeScript() {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: bundled, to: destination)
            return
        }
        // Tests and `swift run` can miss the resource bundle; keep a copy next
        // to the checkpoint either way.
        if !FileManager.default.fileExists(atPath: destination.path) {
            throw LayaInstallError.listing("The Laya serve script is missing from the app bundle.")
        }
    }

    private static func bundledServeScript() -> URL? {
        let bundle = OreResourceBundle.bundle
        let names: [(String?, String)] = [("Laya", "laya_serve"), (nil, "laya_serve")]
        for (directory, name) in names {
            if let url = bundle.url(
                forResource: name, withExtension: "py", subdirectory: directory
            ) {
                return url
            }
        }
        return nil
    }

    private func waitForProbe(seconds: TimeInterval) async -> Bool {
        let steps = Int(seconds / 0.5)
        for _ in 0..<steps {
            if Task.isCancelled { return false }
            if await http.probe() { return true }
            if let process = serverProcess, !process.isRunning { return false }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return await http.probe()
    }

    private func runDetached(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try ProcessLaunch.run(process)
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: LayaInstallError.listing(
                                "Command failed (\(process.terminationStatus)): \(executable)"
                            )
                        )
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
