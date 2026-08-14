import Foundation
import OreProtocol
import OreSupport

/// Everything a driver needs to launch one session.
public struct SessionConfiguration: Sendable {
    public struct MCPServer: Sendable {
        public var command: String
        public var arguments: [String]
        public init(command: String, arguments: [String]) {
            self.command = command
            self.arguments = arguments
        }
    }
    /// The git worktree the agent runs in. All of the agent's file access is
    /// rooted here, which is what makes N parallel agents safe.
    public var workingDirectory: URL
    public var model: String?
    public var permissionMode: PermissionMode
    public var resume: SessionRequest.ResumeMode
    /// Extra text appended to the CLI's own system prompt — how ORE tells the
    /// agent about the workspace's `.context` directory and review conventions.
    public var appendSystemPrompt: String?
    /// Escape hatch for users on a CLI version whose flags we don't model yet.
    public var extraArguments: [String]
    /// Additional environment for the child, merged over the sanitized login
    /// shell environment.
    public var environmentOverrides: [String: String]
    /// Explicit path to the CLI, bypassing `PATH` lookup. Set from settings
    /// when a user's version manager puts the binary somewhere we can't find.
    public var executablePath: String?
    /// Opt-in only. Default is subscription auth: any provider API key in the
    /// parent environment is scrubbed so a stray key never gets billed.
    public var allowAPIKeyFallback: Bool
    public var mcpServer: MCPServer?

    public init(
        workingDirectory: URL,
        model: String? = nil,
        permissionMode: PermissionMode = .default,
        resume: SessionRequest.ResumeMode = .fresh,
        appendSystemPrompt: String? = nil,
        extraArguments: [String] = [],
        environmentOverrides: [String: String] = [:],
        executablePath: String? = nil,
        allowAPIKeyFallback: Bool = false,
        mcpServer: MCPServer? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.model = model
        self.permissionMode = permissionMode
        self.resume = resume
        self.appendSystemPrompt = appendSystemPrompt
        self.extraArguments = extraArguments
        self.environmentOverrides = environmentOverrides
        self.executablePath = executablePath
        self.allowAPIKeyFallback = allowAPIKeyFallback
        self.mcpServer = mcpServer
    }
}
