import Foundation
import OreProtocol
import OreSupport

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The transport half of the assistant's action lane: a Unix-domain socket the
/// assistant's MCP-server process connects to, speaking one NDJSON request per
/// line and getting one NDJSON response back.
///
/// A socket rather than the `.context`-file pattern the review tools use
/// because actions are request/response: "create a workspace" has to come back
/// with the workspace it created, or an error the model can act on. Owner-only
/// permissions (0600) are the access control — anything that can write to this
/// socket is already running as the user.
///
/// Policy does not live here. This class moves bytes; the handler — the app's
/// `InProcessCoreClient` — decides what is allowed.
public final class AssistantBridgeServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AssistantBridgeRequest) async -> AssistantBridgeResponse

    private let socketURL: URL
    private let handler: Handler
    private let listenDescriptor = Lockbox<Int32>(-1)
    private let isRunning = Lockbox<Bool>(false)

    public init(socketURL: URL, handler: @escaping Handler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    public func start() throws {
        // A stale socket from a crashed app would make bind fail forever.
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path
        )
        unlink(socketURL.path)

        let descriptor = UnixStreamSocket.open()
        guard descriptor >= 0 else {
            throw BridgeError.socketFailed(errno)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bound: Bool = socketURL.path.withCString { path in
            guard strlen(path) < capacity else { return false }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                _ = strcpy(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), path)
            }
            return true
        }
        guard bound else {
            close(descriptor)
            throw BridgeError.pathTooLong(socketURL.path)
        }

        // Restrict the create-mode before bind so the socket is never world
        // readable in the window before chmod.
        let previous = umask(0o077)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, size)
            }
        }
        umask(previous)
        guard bindResult == 0 else {
            close(descriptor)
            throw BridgeError.bindFailed(errno)
        }
        chmod(socketURL.path, 0o600)
        guard listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw BridgeError.listenFailed(errno)
        }

        listenDescriptor.set(descriptor)
        isRunning.set(true)

        // Blocking accept gets its own thread, not a slot in the cooperative
        // pool — it can sit in `accept(2)` for hours.
        let thread = Thread { [weak self] in self?.acceptLoop(descriptor) }
        thread.name = "ore.assistant-bridge.accept"
        thread.start()
    }

    public func stop() {
        isRunning.set(false)
        let descriptor = listenDescriptor.get()
        if descriptor >= 0 { close(descriptor) }
        listenDescriptor.set(-1)
        unlink(socketURL.path)
    }

    private func acceptLoop(_ descriptor: Int32) {
        while isRunning.get() {
            let connection = accept(descriptor, nil, nil)
            guard connection >= 0 else {
                // stop() closed the descriptor, or accept failed hard; either
                // way this loop is done.
                return
            }
            let thread = Thread { [weak self] in self?.serve(connection) }
            thread.name = "ore.assistant-bridge.connection"
            thread.start()
        }
    }

    /// One connection, possibly several requests over its lifetime. Each line
    /// in is a request; each line out is its response — the confirmation flow
    /// means a response can be minutes behind its request, so the connection
    /// stays open while the handler waits.
    private func serve(_ connection: Int32) {
        defer { close(connection) }
        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 16_384)

        while isRunning.get() {
            let count = read(connection, &scratch, scratch.count)
            guard count > 0 else { return }
            buffer.append(contentsOf: scratch[0..<count])

            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty else { continue }

                let response = respond(to: Data(line))
                guard let payload = try? JSONEncoder().encode(response) else { continue }
                var out = payload
                out.append(UInt8(ascii: "\n"))
                let written = out.withUnsafeBytes { bytes in
                    write(connection, bytes.baseAddress, bytes.count)
                }
                guard written == out.count else { return }
            }
        }
    }

    /// Bridges the blocking connection thread to the async handler. The thread
    /// has nothing else to do until the answer exists, so parking it on a
    /// semaphore is exactly right.
    private func respond(to line: Data) -> AssistantBridgeResponse {
        guard let request = try? JSONDecoder().decode(AssistantBridgeRequest.self, from: line)
        else {
            return AssistantBridgeResponse(
                id: "unknown", ok: false, error: "Malformed bridge request."
            )
        }

        let box = Lockbox<AssistantBridgeResponse?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        let handler = handler
        Task {
            box.set(await handler(request))
            semaphore.signal()
        }
        semaphore.wait()
        return box.get() ?? AssistantBridgeResponse(
            id: request.id, ok: false, error: "The app dropped the request."
        )
    }

    public enum BridgeError: Error, CustomStringConvertible {
        case socketFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case pathTooLong(String)

        public var description: String {
            switch self {
            case .socketFailed(let code): "socket() failed (errno \(code))."
            case .bindFailed(let code): "bind() failed (errno \(code))."
            case .listenFailed(let code): "listen() failed (errno \(code))."
            case .pathTooLong(let path): "Socket path too long: \(path)"
            }
        }
    }
}
