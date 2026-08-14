import Foundation
import OreProtocol
import OreSupport

/// A driver for one agent CLI.
///
/// The shape is identical for all three harnesses: spawn the user's installed
/// CLI as a child process rooted in the worktree, speak its machine protocol
/// over stdio, and never touch an API key — the CLI carries the user's
/// subscription credentials itself.
public protocol AgentHarness: Sendable {
    var kind: HarnessKind { get }
    var capabilities: HarnessCapabilities { get }
    /// Whether ORE may open a short, isolated metadata session (for example,
    /// generating a chat title) without disturbing the primary conversation.
    var supportsAuxiliarySessions: Bool { get }

    /// Onboarding doctor: is the CLI installed, which version, is it logged in.
    /// Must never spend a model request.
    func probe() async -> HarnessProbeResult

    /// Models the installed CLI currently offers to this account. Discovery is
    /// metadata-only and must never spend a model request.
    func discoverModels() async -> [AgentModel]

    func makeSession(_ configuration: SessionConfiguration) async throws -> any AgentSession
}

public extension AgentHarness {
    func discoverModels() async -> [AgentModel] { [] }
    var supportsAuxiliarySessions: Bool { true }
}

/// One live conversation with an agent CLI.
///
/// Conforming types are actors: a session owns a child process, a pending
/// permission table and a delta assembler, all of which are mutated from the
/// reader task and the UI concurrently.
public protocol AgentSession: Actor {
    nonisolated var id: SessionID { get }
    nonisolated var harness: HarnessKind { get }
    nonisolated var capabilities: HarnessCapabilities { get }

    /// The normalized event stream. Finishes when the session ends.
    ///
    /// Non-isolated so a consumer can start iterating before `start()` returns
    /// and therefore cannot miss the first events.
    nonisolated var events: AsyncStream<AgentEvent> { get }

    /// The id the CLI uses for this conversation. Nil until the CLI reports it.
    var providerSessionID: String? { get }

    /// Spawns the process and begins reading. Returns once the process is
    /// running, not once it is ready — readiness arrives as `.sessionStarted`.
    func start() async throws

    func send(_ message: UserMessage) async throws
    func interrupt() async throws
    func setPermissionMode(_ mode: PermissionMode) async throws
    /// Changes the model used by the next turn when the harness can do so
    /// without replacing its provider session.
    func setModel(_ model: String?) async throws
    func resolvePermission(_ id: PermissionRequestID, with decision: PermissionDecision) async throws
    func answerQuestion(_ id: QuestionID, answer: String) async throws

    /// Ends the session and terminates the child process. Idempotent.
    func stop() async
}

public extension AgentSession {
    func setModel(_ model: String?) async throws {
        throw HarnessError.unsupportedCapability("runtime model changes")
    }
}

/// A message from the user to the agent.
public struct UserMessage: Sendable, Codable, Hashable {
    public var text: String
    /// Paths (relative to the worktree) the agent should read. Attachments live
    /// on disk under `.context/`, so we reference them rather than inlining.
    public var attachmentPaths: [String]
    public var reasoningEffort: ReasoningEffort?
    public var serviceTier: String?

    public init(
        text: String,
        attachmentPaths: [String] = [],
        reasoningEffort: ReasoningEffort? = nil,
        serviceTier: String? = nil
    ) {
        self.text = text
        self.attachmentPaths = attachmentPaths
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
    }

    /// The text as the CLI should receive it, with attachment references
    /// appended as an explicit list the agent can act on.
    public var renderedText: String {
        guard !attachmentPaths.isEmpty else { return text }
        let list = attachmentPaths.map { "- \($0)" }.joined(separator: "\n")
        return "\(text)\n\nAttached files:\n\(list)"
    }
}

public enum HarnessError: Error, Sendable, CustomStringConvertible {
    case executableNotFound(HarnessKind, searchedPath: String)
    case notAuthenticated(HarnessKind, hint: String)
    case sessionNotStarted
    case sessionEnded
    case unsupportedCapability(String)
    case transportFailure(String)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .executableNotFound(let kind, let path):
            return "\(kind.displayName) CLI (`\(kind.defaultExecutableName)`) was not found on PATH: \(path)"
        case .notAuthenticated(let kind, let hint):
            return "\(kind.displayName) is not signed in. \(hint)"
        case .sessionNotStarted:
            return "The session has not been started."
        case .sessionEnded:
            return "The session has ended."
        case .unsupportedCapability(let name):
            return "This harness does not support \(name)."
        case .transportFailure(let message):
            return "Transport failure: \(message)"
        case .launchFailed(let message):
            return "Failed to launch the agent CLI: \(message)"
        }
    }
}
