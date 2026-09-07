import Foundation
import Testing

@testable import OreCore
@testable import OrePersistence
@testable import OreProtocol

@Suite(.serialized)
struct AssistantExecutionOptionsTests {
    @Test func toolReturnsEveryHarnessModelCapabilityAndReadinessState() async throws {
        let claude = FakeHarness(
            kind: .claudeCode,
            capabilities: HarnessCapabilities(
                supportsPlanMode: true,
                supportsSteering: true,
                supportsInterrupt: true,
                supportsResume: true,
                supportsThinkingStream: true,
                supportsCustomTools: true,
                permissionModel: .interactiveCallback,
                usageGranularity: .live
            ),
            models: [AgentModel(
                id: "claude-opus-live", displayName: "Opus Live",
                description: "deep architecture and review", isDefault: true
            )]
        )
        let codex = FakeHarness(
            kind: .codex,
            capabilities: HarnessCapabilities(
                supportsPlanMode: true,
                supportsInterrupt: true,
                supportsResume: true,
                supportsSessionFork: true,
                supportsThinkingStream: true,
                supportsPartialMessages: true,
                supportsRuntimePermissionModeChange: true,
                supportsCustomTools: true,
                permissionModel: .interactiveCallback,
                usageGranularity: .perTurn
            ),
            models: [AgentModel(
                id: "gpt-5.6-sol", displayName: "GPT-5.6 sol",
                description: "agentic coding and long-running implementation",
                isDefault: true,
                supportedReasoningEfforts: ["medium", "high", "xhigh"],
                supportedServiceTiers: ["fast"]
            )]
        )
        let cursor = FakeHarness(
            kind: .cursorAgent,
            models: [AgentModel(id: "cursor-auto", displayName: "Auto")],
            probeResult: HarnessProbeResult(
                kind: .cursorAgent,
                executablePath: "/fake/cursor",
                version: "1.0",
                authState: .notAuthenticated,
                isEnabled: true,
                diagnostic: "Sign in from Cursor"
            )
        )
        let client = InProcessCoreClient(
            store: try OreStore(),
            harnessRegistry: HarnessRegistry(harnesses: [claude, codex, cursor])
        )
        await client.send(.probeHarnesses)

        let response = await executionOptions(
            client,
            task: "Implement a multi-file Swift feature with tests and careful review"
        )
        let result = try #require(response.result)

        #expect(response.ok)
        #expect(result.contains("Task: Implement a multi-file Swift feature"))
        #expect(result.contains("HARNESS claudeCode (Claude Code)"))
        #expect(result.contains("id=claude-opus-live"))
        #expect(result.contains("HARNESS codex (Codex)"))
        #expect(result.contains("id=gpt-5.6-sol"))
        #expect(result.contains("efforts=medium,high,xhigh"))
        #expect(result.contains("service-tiers=fast"))
        #expect(result.contains("custom-tools=yes"))
        #expect(result.contains("HARNESS cursorAgent (Cursor Agent)"))
        #expect(result.contains("authentication: notAuthenticated"))
        #expect(result.contains("usable-now: no"))
        #expect(result.contains("ORE has not keyword-scored or preselected a winner"))
    }

    @Test func exhaustedRateLimitExcludesHarnessUntilResetAndPreservesTabContext() async throws {
        let store = try OreStore()
        let codex = FakeHarness(
            kind: .codex,
            models: [AgentModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 sol")]
        )
        let client = InProcessCoreClient(
            store: store,
            harnessRegistry: HarnessRegistry(harnesses: [codex])
        )
        await client.send(.probeHarnesses)

        let workspaceID = WorkspaceID.generate()
        let chatID = ChatID.generate()
        try await store.addRepository(RepositoryRecord(
            path: "/tmp/selector.git", name: "Selector", defaultBranch: "main"
        ))
        try await store.saveWorkspace(WorkspaceRecord(
            id: workspaceID,
            name: "Selector",
            repositoryPath: "/tmp/selector.git",
            worktreePath: "/tmp/selector",
            branch: "feature/selector",
            baseBranch: "main",
            harness: .codex,
            model: "gpt-5.6-sol"
        ))
        try await store.saveChat(ChatRecord(
            id: chatID,
            workspaceID: workspaceID,
            title: "Implementation",
            harness: .codex,
            model: "gpt-5.6-sol",
            reasoningEffort: .high
        ))
        let reset = Date().addingTimeInterval(3_600)
        await client.recordHarnessRateLimit(
            chatID: chatID,
            event: .rateLimit(RateLimitReport(
                status: .exhausted, window: "five-hour", resetsAt: reset
            ))
        )

        let limited = await executionOptions(
            client,
            task: "Continue the implementation",
            workspaceID: workspaceID,
            chatID: chatID
        )
        let limitedText = try #require(limited.result)
        #expect(limitedText.contains("Current chat: id=\(chatID.rawValue)"))
        #expect(limitedText.contains("effort=high"))
        #expect(limitedText.contains("usable-now: no"))
        #expect(limitedText.contains("rate-limit: exhausted; window=five-hour"))
        #expect(limitedText.contains("source-chat=\(chatID.rawValue)"))

        await client.recordHarnessRateLimit(
            chatID: chatID,
            event: .rateLimit(RateLimitReport(
                status: .exhausted,
                window: "five-hour",
                resetsAt: Date().addingTimeInterval(-1)
            ))
        )
        let resetResponse = await executionOptions(
            client,
            task: "Continue after reset",
            workspaceID: workspaceID,
            chatID: chatID
        )
        let resetText = try #require(resetResponse.result)
        #expect(resetText.contains("usable-now: yes"))
        #expect(resetText.contains("rate-limit: not reported; capacity is unknown"))
    }

    @Test func executionRejectsAnExhaustedProviderAndAStaleModelID() async throws {
        let store = try OreStore()
        let codex = FakeHarness(
            kind: .codex,
            models: [AgentModel(id: "current-model", displayName: "Current")]
        )
        let client = InProcessCoreClient(
            store: store,
            harnessRegistry: HarnessRegistry(harnesses: [codex])
        )
        await client.send(.probeHarnesses)
        let workspaceID = WorkspaceID.generate()
        let chatID = ChatID.generate()
        try await store.addRepository(RepositoryRecord(
            path: "/tmp/quota-source.git", name: "Quota source", defaultBranch: "main"
        ))
        try await store.saveWorkspace(WorkspaceRecord(
            id: workspaceID,
            name: "Quota source",
            repositoryPath: "/tmp/quota-source.git",
            worktreePath: "/tmp/quota-source",
            branch: "main",
            baseBranch: "main",
            harness: .codex
        ))
        try await store.saveChat(ChatRecord(
            id: chatID,
            workspaceID: workspaceID,
            title: "Quota source",
            harness: .codex
        ))
        await client.recordHarnessRateLimit(
            chatID: chatID,
            event: .rateLimit(RateLimitReport(status: .exhausted))
        )

        let exhausted = await client.handleAssistantRequest(AssistantBridgeRequest(
            id: UUID().uuidString,
            tool: "CreateProject",
            arguments: .object([
                "name": .string("Will not be created"),
                "harness": .string("codex"),
                "model": .string("current-model"),
            ])
        ))
        #expect(!exhausted.ok)
        #expect(exhausted.error?.contains("rate limit is exhausted") == true)

        await client.recordHarnessRateLimit(
            chatID: chatID,
            event: .rateLimit(RateLimitReport(status: .allowed))
        )
        let stale = await client.handleAssistantRequest(AssistantBridgeRequest(
            id: UUID().uuidString,
            tool: "CreateProject",
            arguments: .object([
                "name": .string("Still not created"),
                "harness": .string("codex"),
                "model": .string("retired-model"),
            ])
        ))
        #expect(!stale.ok)
        #expect(stale.error?.contains("not in Codex's current catalog") == true)
        #expect(stale.error?.contains("current-model") == true)
    }

    private func executionOptions(
        _ client: InProcessCoreClient,
        task: String,
        workspaceID: WorkspaceID? = nil,
        chatID: ChatID? = nil
    ) async -> AssistantBridgeResponse {
        var arguments: [String: JSONValue] = ["task": .string(task)]
        if let workspaceID { arguments["workspaceID"] = .string(workspaceID.rawValue) }
        if let chatID { arguments["chatID"] = .string(chatID.rawValue) }
        return await client.handleAssistantRequest(AssistantBridgeRequest(
            id: UUID().uuidString,
            tool: "GetExecutionOptions",
            arguments: .object(arguments)
        ))
    }
}
