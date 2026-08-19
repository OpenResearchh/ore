import Foundation
import Testing

@testable import OreCore
@testable import OrePersistence
@testable import OreProtocol

#if canImport(Darwin)
import Darwin
#endif

/// The assistant's action lane, exercised the way the MCP-server process uses
/// it: real socket, real NDJSON, real policy — no shortcuts through the actor.
struct AssistantBridgeTests {
    @Test func autoActionsRunWithoutConfirmationAndAreAudited() async throws {
        let fixture = try await GitFixture.initialized()
        let harness = try await BridgeHarness(fixture: fixture)
        defer { Task { await harness.shutdown() } }

        let workspaceID = try await harness.makeWorkspace(named: "auto-test")

        // OpenWorkspace is in the auto tier: no confirmation event, immediate
        // success, and a UI action on the event stream.
        let response = try harness.callBridge(
            tool: "OpenWorkspace",
            arguments: ["workspaceID": .string(workspaceID.rawValue)]
        )
        #expect(response.ok)

        let event = await harness.recorder.waitFor {
            if case .assistantUIAction = $0 { return true }
            return false
        }
        #expect(event != nil)

        let audit = try await harness.store.assistantActions()
        #expect(audit.first?.tool == "OpenWorkspace")
        #expect(audit.first?.decision == "auto")
    }

    @Test func decliningAConfirmationDeniesTheActionAndTellsTheModel() async throws {
        let fixture = try await GitFixture.initialized()
        let harness = try await BridgeHarness(fixture: fixture)
        defer { Task { await harness.shutdown() } }

        let workspaceID = try await harness.makeWorkspace(named: "deny-test")

        // Commit is in the confirm tier. Answer the confirmation with a deny
        // from a parallel task while the bridge call blocks on it.
        async let call = harness.callBridgeAsync(
            tool: "Commit",
            arguments: [
                "workspaceID": .string(workspaceID.rawValue),
                "message": .string("should not land"),
            ]
        )

        guard case .assistantConfirmationRequested(let confirmation)? =
            await harness.recorder.waitFor(matching: {
                if case .assistantConfirmationRequested = $0 { return true }
                return false
            })
        else {
            Issue.record("no confirmation was requested")
            return
        }
        #expect(confirmation.actionClass == .commit)
        await harness.client.send(.resolveAssistantConfirmation(confirmation.id, .deny))

        let response = try await call
        #expect(!response.ok)
        #expect(response.error?.contains("declined") == true)

        let audit = try await harness.store.assistantActions()
        #expect(audit.first?.decision == "denied")
    }

    @Test func aTaskGrantCoversTheSecondActionWithoutAsking() async throws {
        let fixture = try await GitFixture.initialized()
        let harness = try await BridgeHarness(fixture: fixture)
        defer { Task { await harness.shutdown() } }

        let workspaceID = try await harness.makeWorkspace(named: "grant-test")
        let worktree = try await harness.worktreePath(of: workspaceID)

        // First commit: confirm with "allow for this task".
        try "one\n".write(
            to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8
        )
        async let first = harness.callBridgeAsync(
            tool: "Commit",
            arguments: [
                "workspaceID": .string(workspaceID.rawValue),
                "message": .string("first"),
            ]
        )
        guard case .assistantConfirmationRequested(let confirmation)? =
            await harness.recorder.waitFor(matching: {
                if case .assistantConfirmationRequested = $0 { return true }
                return false
            })
        else {
            Issue.record("no confirmation was requested")
            return
        }
        await harness.client.send(
            .resolveAssistantConfirmation(confirmation.id, .allow(.task))
        )
        let firstResponse = try await first
        #expect(firstResponse.ok)

        // Second commit inside the grant window: no confirmation, just done.
        try "two\n".write(
            to: worktree.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8
        )
        let second = try harness.callBridge(
            tool: "Commit",
            arguments: [
                "workspaceID": .string(workspaceID.rawValue),
                "message": .string("second"),
            ]
        )
        #expect(second.ok)

        let audit = try await harness.store.assistantActions()
        #expect(audit.first?.decision == "granted:task")
        #expect(audit.count { $0.tool == "Commit" } == 2)
    }

    @Test func aTaskGrantDoesNotCoverADifferentWorkspace() async throws {
        let fixture = try await GitFixture.initialized()
        let harness = try await BridgeHarness(fixture: fixture)
        defer { Task { await harness.shutdown() } }

        let first = try await harness.makeWorkspace(named: "grant-a")
        let second = try await harness.makeWorkspace(named: "grant-b")
        let ids = Set((try await harness.store.workspaces()).map(\.workspaceID))
        #expect(ids.count == 2)
        let otherID = ids.first { $0 != first } ?? second
        let firstTree = try await harness.worktreePath(of: first)
        try "one\n".write(
            to: firstTree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8
        )

        async let allowed = harness.callBridgeAsync(
            tool: "Commit",
            arguments: [
                "workspaceID": .string(first.rawValue),
                "message": .string("first"),
            ]
        )
        guard case .assistantConfirmationRequested(let confirmation)? =
            await harness.recorder.waitFor(matching: {
                if case .assistantConfirmationRequested = $0 { return true }
                return false
            })
        else {
            Issue.record("no confirmation was requested")
            return
        }
        await harness.client.send(
            .resolveAssistantConfirmation(confirmation.id, .allow(.task))
        )
        #expect(try await allowed.ok)

        let secondTree = try await harness.worktreePath(of: otherID)
        try "two\n".write(
            to: secondTree.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8
        )
        async let other = harness.callBridgeAsync(
            tool: "Commit",
            arguments: [
                "workspaceID": .string(otherID.rawValue),
                "message": .string("other"),
            ]
        )
        guard case .assistantConfirmationRequested(let next)? =
            await harness.recorder.waitFor(matching: {
                if case .assistantConfirmationRequested(let confirmation) = $0 {
                    return confirmation.workspaceID == otherID
                }
                return false
            })
        else {
            Issue.record("the other workspace was not asked")
            return
        }
        await harness.client.send(.resolveAssistantConfirmation(next.id, .deny))
        let response = try await other
        #expect(!response.ok)
    }

    @Test func anAlwaysGrantIsRememberedInMemoryImmediately() async throws {
        let fixture = try await GitFixture.initialized()
        let harness = try await BridgeHarness(fixture: fixture)
        defer { Task { await harness.shutdown() } }

        let workspaceID = try await harness.makeWorkspace(named: "always-test")
        let worktree = try await harness.worktreePath(of: workspaceID)
        try "one\n".write(
            to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8
        )

        async let first = harness.callBridgeAsync(
            tool: "Commit",
            arguments: [
                "workspaceID": .string(workspaceID.rawValue),
                "message": .string("first"),
            ]
        )
        guard case .assistantConfirmationRequested(let confirmation)? =
            await harness.recorder.waitFor(matching: {
                if case .assistantConfirmationRequested = $0 { return true }
                return false
            })
        else {
            Issue.record("no confirmation was requested")
            return
        }
        await harness.client.send(
            .resolveAssistantConfirmation(confirmation.id, .allow(.always))
        )
        #expect(try await first.ok)

        try "two\n".write(
            to: worktree.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8
        )
        let second = try harness.callBridge(
            tool: "Commit",
            arguments: [
                "workspaceID": .string(workspaceID.rawValue),
                "message": .string("second"),
            ]
        )
        #expect(second.ok)
        let audit = try await harness.store.assistantActions()
        #expect(audit.contains { $0.decision == "granted:always" })
    }

    @Test func longHomesDoNotBindABareSocketInTmp() {
        let deep = URL(
            fileURLWithPath: "/" + String(repeating: "deep/", count: 30) + "ore.sqlite"
        )
        let url = AssistantBridgeLocator.socketURL(forDatabase: deep)
        #expect(url.path.utf8.count < 104)
        #expect(!url.path.hasPrefix("/tmp/ore-bridge-") || url.path.hasSuffix("/bridge.sock"))
        #expect(url.lastPathComponent == "bridge.sock" || url.lastPathComponent == ".bridge.sock")
    }

    @Test func unknownActionsAreDenied() async throws {
        let fixture = try await GitFixture.initialized()
        let harness = try await BridgeHarness(fixture: fixture)
        defer { Task { await harness.shutdown() } }

        let response = try harness.callBridge(tool: "MergePullRequest", arguments: [:])
        #expect(!response.ok)
    }
}

/// A running core with its bridge up, plus a raw socket client — the same
/// wire the assistant's MCP server uses.
private final class BridgeHarness: @unchecked Sendable {
    let store: OreStore
    let client: InProcessCoreClient
    let recorder: CoreEventRecorder
    let socketURL: URL

    init(fixture: GitFixture) async throws {
        let databasePath = fixture.root.appendingPathComponent("ore.sqlite")
        store = try OreStore(path: databasePath)
        client = InProcessCoreClient(
            store: store,
            harnessRegistry: HarnessRegistry(harnesses: []),
            worktreeRoot: fixture.worktreeRoot
        )
        recorder = CoreEventRecorder(client)
        socketURL = AssistantBridgeLocator.socketURL(forDatabase: databasePath)
        self.fixture = fixture
        try await client.start()
    }

    private let fixture: GitFixture

    func shutdown() async {
        await client.shutdown()
    }

    func makeWorkspace(named name: String) async throws -> WorkspaceID {
        await client.send(.addRepository(path: fixture.repository.path))
        await client.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path, name: name
        )))
        guard case .workspaceAdded(let summary)? = await recorder.waitFor(matching: {
            if case .workspaceAdded = $0 { return true }
            return false
        }) else {
            throw HarnessError.noWorkspace
        }
        return summary.id
    }

    func worktreePath(of id: WorkspaceID) async throws -> URL {
        guard let record = try await store.workspace(id) else { throw HarnessError.noWorkspace }
        return URL(fileURLWithPath: record.worktreePath)
    }

    /// Async wrapper so a test can block on the response while it answers the
    /// confirmation on the main flow.
    func callBridgeAsync(
        tool: String, arguments: [String: JSONValue]
    ) async throws -> AssistantBridgeResponse {
        let harness = self
        return try await Task.detached {
            try harness.callBridge(tool: tool, arguments: arguments)
        }.value
    }

    func callBridge(
        tool: String, arguments: [String: JSONValue]
    ) throws -> AssistantBridgeResponse {
        let request = AssistantBridgeRequest(
            id: UUID().uuidString.lowercased(), tool: tool, arguments: .object(arguments)
        )
        var payload = try JSONEncoder().encode(request)
        payload.append(UInt8(ascii: "\n"))

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HarnessError.socket }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = socketURL.path.withCString { path in
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                strcpy(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), path)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, size)
            }
        }
        guard connected == 0 else { throw HarnessError.connect(errno) }

        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let written = payload.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == payload.count else { throw HarnessError.socket }

        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = read(descriptor, &scratch, scratch.count)
            guard count > 0 else { throw HarnessError.socket }
            buffer.append(contentsOf: scratch[0..<count])
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex..<newline])
                return try JSONDecoder().decode(AssistantBridgeResponse.self, from: line)
            }
        }
    }

    enum HarnessError: Error {
        case noWorkspace
        case socket
        case connect(Int32)
    }
}
