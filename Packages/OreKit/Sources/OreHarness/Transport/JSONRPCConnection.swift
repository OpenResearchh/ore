import Foundation
import OreProtocol
import OreSupport

/// A JSON-RPC 2.0 peer over a child process's stdio.
///
/// Bidirectional: we send requests and the server sends requests back (approval
/// prompts, user input). Both directions must be answered, and a request we
/// leave unanswered blocks the agent forever, so responses are tracked rather
/// than fired and forgotten.
public actor JSONRPCConnection {
    public struct Request: Sendable {
        public var id: JSONValue
        public var method: String
        public var params: JSONValue?
    }

    public struct Notification: Sendable {
        public var method: String
        public var params: JSONValue?
    }

    /// Inbound traffic that isn't a reply to something we sent.
    public enum Incoming: Sendable {
        case notification(Notification)
        case request(Request)
        /// The peer closed its output. Terminal.
        case closed
    }

    public nonisolated let incoming: AsyncStream<Incoming>
    private nonisolated let continuation: AsyncStream<Incoming>.Continuation

    private let process: ChildProcess
    private var nextRequestID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var readerTask: Task<Void, Never>?
    private var isClosed = false

    public init(process: ChildProcess) {
        self.process = process
        let (stream, continuation) = AsyncStream<Incoming>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.incoming = stream
        self.continuation = continuation
    }

    public func start() {
        guard readerTask == nil else { return }
        readerTask = Task { [weak self, process] in
            for await line in process.stdoutChunks.lines() {
                guard !line.isEmpty else { continue }
                await self?.receive(line)
            }
            await self?.handleClosed()
        }
    }

    public func stop() async {
        guard !isClosed else { return }
        isClosed = true
        readerTask?.cancel()
        failAllPending(reason: "the connection was closed")
        continuation.finish()
    }

    // MARK: - Sending

    @discardableResult
    public func send(
        method: String,
        params: JSONValue? = nil,
        timeout: Duration = .seconds(120)
    ) async throws -> JSONValue {
        guard !isClosed else { throw HarnessError.sessionEnded }

        nextRequestID += 1
        let id = nextRequestID
        var payload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .integer(id),
            "method": .string(method),
        ]
        if let params { payload["params"] = params }
        try write(.object(payload))

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.timeOut(id: id, method: method)
            }
        }
    }

    public func notify(method: String, params: JSONValue? = nil) throws {
        var payload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params { payload["params"] = params }
        try write(.object(payload))
    }

    /// Answers a request the server made of us.
    public func respond(to id: JSONValue, result: JSONValue) throws {
        try write(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result,
        ]))
    }

    public func respond(to id: JSONValue, error message: String, code: Int = -32000) throws {
        try write(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .integer(code), "message": .string(message)]),
        ]))
    }

    // MARK: - Receiving

    private func receive(_ line: String) {
        guard let data = line.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return }

        if let method = message["method"]?.stringValue {
            if let id = message["id"], !id.isNull {
                continuation.yield(.request(Request(
                    id: id, method: method, params: message["params"]
                )))
            } else {
                continuation.yield(.notification(Notification(
                    method: method, params: message["params"]
                )))
            }
            return
        }

        // A reply to one of ours.
        guard let id = message["id"]?.intValue,
              let waiting = pending.removeValue(forKey: id)
        else { return }

        if let error = message["error"] {
            let text = ProviderErrorCopy.unwrap(
                error["message"]?.stringValue ?? error.description
            )
            waiting.resume(throwing: HarnessError.transportFailure(text))
        } else {
            waiting.resume(returning: message["result"] ?? .null)
        }
    }

    private func handleClosed() {
        guard !isClosed else { return }
        isClosed = true
        failAllPending(reason: "the agent closed its output stream")
        continuation.yield(.closed)
        continuation.finish()
    }

    private func timeOut(id: Int, method: String) {
        guard let waiting = pending.removeValue(forKey: id) else { return }
        waiting.resume(throwing: HarnessError.transportFailure("`\(method)` timed out"))
    }

    private func failAllPending(reason: String) {
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting {
            continuation.resume(throwing: HarnessError.transportFailure(reason))
        }
    }

    private func write(_ value: JSONValue) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let line = String(data: data, encoding: .utf8) else {
            throw HarnessError.transportFailure("could not encode a JSON-RPC message")
        }
        process.writeLine(line)
    }
}
