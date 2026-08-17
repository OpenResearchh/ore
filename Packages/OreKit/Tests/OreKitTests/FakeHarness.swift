import Foundation
import OreHarness
import OreProtocol
import OreSupport

/// A harness that emits scripted events instead of running a CLI.
///
/// The orchestration layer's job is wiring — checkpoints before a turn, the
/// message queue, unread derivation, revert. Testing that against a real agent
/// would be slow, need a subscription, and make the outcome depend on what a
/// model decided to say. This makes the agent's behaviour an input.
final class FakeHarness: AgentHarness, @unchecked Sendable {
    let kind: HarnessKind
    var capabilities: HarnessCapabilities
    let supportsAuxiliarySessions = false

    /// Sessions handed out so far, so a test can drive them.
    private let sessions = Lockbox<[FakeSession]>([])

    /// Stands in for a CLI that can only take its permission mode as a launch
    /// argument: the session rejects the change and the engine has to make it
    /// real some other way.
    var rejectsPermissionModeChange = false

    init(
        kind: HarnessKind = .claudeCode,
        capabilities: HarnessCapabilities = HarnessCapabilities(
            supportsSteering: true,
            supportsInterrupt: true,
            supportsResume: true,
            supportsSessionFork: true,
            supportsRuntimePermissionModeChange: true,
            permissionModel: .interactiveCallback
        )
    ) {
        self.kind = kind
        self.capabilities = capabilities
    }

    func probe() async -> HarnessProbeResult {
        HarnessProbeResult(
            kind: kind, executablePath: "/fake/\(kind.rawValue)",
            version: "fake", authState: .authenticated
        )
    }

    func makeSession(_ configuration: SessionConfiguration) async throws -> any AgentSession {
        let session = FakeSession(
            id: SessionID.generate(), kind: kind,
            capabilities: capabilities, configuration: configuration,
            rejectsPermissionModeChange: rejectsPermissionModeChange
        )
        sessions.withLock { $0.append(session) }
        return session
    }

    var latestSession: FakeSession? {
        sessions.get().last
    }

    var allSessions: [FakeSession] { sessions.get() }
}

actor FakeSession: AgentSession {
    nonisolated let id: SessionID
    nonisolated let harness: HarnessKind
    nonisolated let capabilities: HarnessCapabilities
    nonisolated let events: AsyncStream<AgentEvent>
    nonisolated let configuration: SessionConfiguration

    private nonisolated let continuation: AsyncStream<AgentEvent>.Continuation

    private(set) var sentMessages: [UserMessage] = []
    private(set) var interruptCount = 0
    private(set) var permissionDecisions: [PermissionRequestID: PermissionDecision] = [:]
    private(set) var permissionMode: PermissionMode?
    private(set) var selectedModel: String?
    private(set) var isStopped = false
    var providerSessionID: String?

    private let rejectsPermissionModeChange: Bool

    init(
        id: SessionID,
        kind: HarnessKind,
        capabilities: HarnessCapabilities,
        configuration: SessionConfiguration,
        rejectsPermissionModeChange: Bool = false
    ) {
        self.id = id
        self.harness = kind
        self.capabilities = capabilities
        self.configuration = configuration
        self.rejectsPermissionModeChange = rejectsPermissionModeChange

        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.continuation = continuation
    }

    func start() async throws {
        providerSessionID = "provider-\(id.rawValue.prefix(6))"
        emit(.sessionStarted(SessionStarted(
            sessionID: id,
            providerSessionID: providerSessionID ?? "",
            harness: harness,
            model: configuration.model,
            workingDirectory: configuration.workingDirectory.path
        )))
    }

    func send(_ message: UserMessage) async throws {
        sentMessages.append(message)
    }

    func interrupt() async throws { interruptCount += 1 }

    func setPermissionMode(_ mode: PermissionMode) async throws {
        if rejectsPermissionModeChange {
            throw HarnessError.unsupportedCapability("permission mode changes")
        }
        permissionMode = mode
    }

    func setModel(_ model: String?) async throws { selectedModel = model }

    func resolvePermission(
        _ id: PermissionRequestID,
        with decision: PermissionDecision
    ) async throws {
        permissionDecisions[id] = decision
        emit(.permissionResolved(PermissionResolution(id: id, decision: decision)))
    }

    func answerQuestion(_ id: QuestionID, answer: String) async throws {
        sentMessages.append(UserMessage(text: answer))
    }

    func stop() async {
        isStopped = true
        continuation.finish()
    }

    // MARK: - Driving

    nonisolated func emit(_ event: AgentEvent) {
        continuation.yield(event)
    }

    /// A complete turn: text, then completion.
    nonisolated func runTurn(
        turnID: TurnID = TurnID.generate(),
        text: String = "done",
        outcome: TurnResult.Outcome = .completed
    ) {
        emit(.turnStarted(TurnStarted(turnID: turnID)))
        emit(.blockCompleted(BlockCompleted(
            turnID: turnID, blockID: BlockID(rawValue: "\(turnID.rawValue)#0"),
            kind: .text, text: text
        )))
        emit(.turnCompleted(TurnResult(turnID: turnID, outcome: outcome, summary: text)))
    }

    func messageTexts() -> [String] { sentMessages.map(\.renderedText) }
}
