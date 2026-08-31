import Foundation
import Testing

@testable import OreCore
@testable import OreGit
@testable import OreHarness
@testable import OrePersistence
@testable import OreProtocol

struct AssistantFailoverPolicyTests {
    @Test func exhaustedRateLimitAndQuotaErrorsAreRateLimited() {
        #expect(AssistantFailoverPolicy.reason(for: .rateLimit(
            RateLimitReport(status: .exhausted)
        )) == .rateLimited)
        #expect(AssistantFailoverPolicy.reason(for: .sessionError(SessionError(
            kind: .rateLimited, message: "usage limit reached"
        ))) == .rateLimited)
        #expect(AssistantFailoverPolicy.reason(for: .turnCompleted(TurnResult(
            turnID: TurnID(rawValue: "t"),
            outcome: .failed,
            errorMessage: "Error: 429 Too Many Requests"
        ))) == .rateLimited)
    }

    @Test func warningsAndSuccessfulTurnsDoNotFailover() {
        #expect(AssistantFailoverPolicy.reason(for: .rateLimit(
            RateLimitReport(status: .warning)
        )) == nil)
        #expect(AssistantFailoverPolicy.reason(for: .turnCompleted(TurnResult(
            turnID: TurnID(rawValue: "t"), outcome: .completed
        ))) == nil)
        #expect(AssistantFailoverPolicy.reason(for: .turnCompleted(TurnResult(
            turnID: TurnID(rawValue: "t"), outcome: .interrupted
        ))) == nil)
    }

    @Test func aDeadCLIIsAProviderFailure() {
        #expect(AssistantFailoverPolicy.reason(for: .sessionError(SessionError(
            kind: .processFailed, message: "exited 1"
        ))) == .providerFailed)
        #expect(AssistantFailoverPolicy.reason(for: .sessionError(SessionError(
            kind: .transport, message: "broken pipe"
        ))) == .providerFailed)
        #expect(AssistantFailoverPolicy.reason(for: .turnCompleted(TurnResult(
            turnID: TurnID(rawValue: "t"), outcome: .failed, errorMessage: "crash"
        ))) == .providerFailed)
    }

    @Test func unknownCopyOnlyFailsOverWhenItLooksLikeAQuota() {
        #expect(AssistantFailoverPolicy.reason(for: .sessionError(SessionError(
            kind: .unknown, message: "something odd"
        ))) == nil)
        #expect(AssistantFailoverPolicy.reason(for: .sessionError(SessionError(
            kind: .unknown, message: "You've hit your session limit"
        ))) == .rateLimited)
    }

    @Test func nextHarnessSkipsTheFailedOneAndLeavesCursorLast() {
        let probes = [
            HarnessProbeResult(
                kind: .cursorAgent, executablePath: "/fake/agent", authState: .authenticated
            ),
            HarnessProbeResult(
                kind: .claudeCode, executablePath: "/fake/claude", authState: .authenticated
            ),
            HarnessProbeResult(
                kind: .codex, executablePath: "/fake/codex", authState: .authenticated
            ),
        ]
        let profile: (HarnessKind) -> AssistantManager.ModelProfile? = {
            AssistantManager.modelProfile(for: $0)
        }
        let next = AssistantFailoverPolicy.nextHarness(
            current: .claudeCode,
            excluding: [],
            probes: probes,
            profile: profile
        )
        #expect(next?.harness == .codex)

        let afterCodex = AssistantFailoverPolicy.nextHarness(
            current: .codex,
            excluding: [.claudeCode],
            probes: probes,
            profile: profile
        )
        #expect(afterCodex?.harness == .cursorAgent)
    }

    @Test func nextHarnessIsNilWhenNothingElseIsReady() {
        let probes = [
            HarnessProbeResult(
                kind: .claudeCode, executablePath: "/fake/claude", authState: .authenticated
            ),
            HarnessProbeResult(
                kind: .codex, executablePath: "/fake/codex", authState: .notAuthenticated
            ),
        ]
        #expect(AssistantFailoverPolicy.nextHarness(
            current: .claudeCode,
            excluding: [],
            probes: probes,
            profile: { AssistantManager.modelProfile(for: $0) }
        ) == nil)
    }
}

/// The Assistant's own agent, not a project tab, moves when its CLI dries up.
struct AssistantFailoverIntegrationTests {
    @Test func anExhaustedAssistantMovesToAnotherReadyHarnessAndRetries() async throws {
        let fixture = try await makeFixture()
        let claude = FakeHarness(
            kind: .claudeCode,
            models: [AgentModel(id: "claude-haiku-4-5-20251001", displayName: "Haiku")]
        )
        let codex = FakeHarness(
            kind: .codex,
            models: [AgentModel(id: "gpt-5.6-luna", displayName: "Luna")]
        )
        let (client, store, recorder) = try makeClient(
            fixture: fixture, harnesses: [claude, codex]
        )
        defer { Task { await client.shutdown() } }
        try await client.start()
        try await waitForProbes(recorder, count: 2)

        let assistant = try #require(try await store.assistantWorkspace())
        let chat = try #require(
            try await store.chats(workspaceID: assistant.workspaceID).first
        )
        #expect(chat.harness == HarnessKind.claudeCode.rawValue)

        await client.send(.sendMessage(SendMessageRequest(
            workspaceID: assistant.workspaceID,
            chatID: chat.chatID,
            text: "What's on the fleet?"
        )))
        #expect(await waitUntil { claude.latestSession != nil })
        claude.latestSession?.emit(.rateLimit(RateLimitReport(status: .exhausted)))

        #expect(await waitUntil {
            (try? await store.chat(chat.chatID))?.harness == HarnessKind.codex.rawValue
        })
        #expect(try await store.chat(chat.chatID)?.model == "gpt-5.6-luna")
        #expect(await waitUntil { codex.latestSession != nil })
        let retried = await waitUntil {
            let texts = await (codex.latestSession?.messageTexts() ?? [])
            return texts.contains { $0.contains("What's on the fleet?") }
        }
        #expect(retried)
        #expect(try await store.chatTransitions(chatID: chat.chatID).map(\.kind)
            == [.harnessChanged])
    }

    @Test func aSessionErrorAlsoMovesTheAssistant() async throws {
        let fixture = try await makeFixture()
        let claude = FakeHarness(
            kind: .claudeCode,
            models: [AgentModel(id: "claude-haiku-4-5-20251001", displayName: "Haiku")]
        )
        let codex = FakeHarness(
            kind: .codex,
            models: [AgentModel(id: "gpt-5.6-luna", displayName: "Luna")]
        )
        let (client, store, recorder) = try makeClient(
            fixture: fixture, harnesses: [claude, codex]
        )
        defer { Task { await client.shutdown() } }
        try await client.start()
        try await waitForProbes(recorder, count: 2)

        let assistant = try #require(try await store.assistantWorkspace())
        let chat = try #require(
            try await store.chats(workspaceID: assistant.workspaceID).first
        )
        await client.send(.sendMessage(SendMessageRequest(
            workspaceID: assistant.workspaceID,
            chatID: chat.chatID,
            text: "Summarize the fleet"
        )))
        #expect(await waitUntil { claude.latestSession != nil })
        claude.latestSession?.emit(.sessionError(SessionError(
            kind: .processFailed, message: "claude exited 1"
        )))

        #expect(await waitUntil {
            (try? await store.chat(chat.chatID))?.harness == HarnessKind.codex.rawValue
        })
    }

    @Test func aProjectTabDoesNotMoveWhenItIsRateLimited() async throws {
        let fixture = try await makeFixture()
        let claude = FakeHarness(
            kind: .claudeCode,
            models: [AgentModel(id: "claude-haiku-4-5-20251001", displayName: "Haiku")]
        )
        let codex = FakeHarness(
            kind: .codex,
            models: [AgentModel(id: "gpt-5.6-luna", displayName: "Luna")]
        )
        let (client, store, recorder) = try makeClient(
            fixture: fixture, harnesses: [claude, codex]
        )
        defer { Task { await client.shutdown() } }
        try await client.start()
        try await waitForProbes(recorder, count: 2)

        await client.send(.addRepository(path: fixture.repository.path))
        await client.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path, name: "project"
        )))
        _ = await recorder.waitFor {
            if case .workspaceAdded(let summary) = $0 { return summary.name == "project" }
            return false
        }
        let project = try #require(try await store.workspaces().first)
        let projectChat = try #require(
            try await store.chats(workspaceID: project.workspaceID).first
        )
        let projectHarness = projectChat.harness

        await client.send(.sendMessage(SendMessageRequest(
            workspaceID: project.workspaceID,
            chatID: projectChat.chatID,
            text: "keep going"
        )))
        #expect(await waitUntil {
            claude.allSessions.count + codex.allSessions.count > 0
        })
        claude.latestSession?.emit(.rateLimit(RateLimitReport(status: .exhausted)))
        try? await Task.sleep(for: .milliseconds(400))
        #expect(try await store.chat(projectChat.chatID)?.harness == projectHarness)
    }

    @Test func duplicateLimitEventsDoNotBouncePastTheFirstAlternate() async throws {
        let fixture = try await makeFixture()
        let claude = FakeHarness(
            kind: .claudeCode,
            models: [AgentModel(id: "claude-haiku-4-5-20251001", displayName: "Haiku")]
        )
        let codex = FakeHarness(
            kind: .codex,
            models: [AgentModel(id: "gpt-5.6-luna", displayName: "Luna")]
        )
        let cursor = FakeHarness(
            kind: .cursorAgent,
            models: [AgentModel(id: "composer-2.5", displayName: "Composer")]
        )
        let (client, store, recorder) = try makeClient(
            fixture: fixture,
            harnesses: [claude, codex, cursor],
            enabledExperimental: [.cursorAgent]
        )
        defer { Task { await client.shutdown() } }
        try await client.start()
        try await waitForProbes(recorder, count: 3)

        let assistant = try #require(try await store.assistantWorkspace())
        let chat = try #require(
            try await store.chats(workspaceID: assistant.workspaceID).first
        )
        await client.send(.sendMessage(SendMessageRequest(
            workspaceID: assistant.workspaceID,
            chatID: chat.chatID,
            text: "status"
        )))
        #expect(await waitUntil { claude.latestSession != nil })
        let session = try #require(claude.latestSession)
        session.emit(.rateLimit(RateLimitReport(status: .exhausted)))
        session.emit(.sessionError(SessionError(
            kind: .rateLimited, message: "quota"
        )))
        session.emit(.turnCompleted(TurnResult(
            turnID: TurnID.generate(), outcome: .failed, errorMessage: "429"
        )))

        #expect(await waitUntil {
            (try? await store.chat(chat.chatID))?.harness == HarnessKind.codex.rawValue
        })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(try await store.chat(chat.chatID)?.harness == HarnessKind.codex.rawValue)
    }

    @Test func withNoAlternateTheAssistantStaysPut() async throws {
        let fixture = try await makeFixture()
        let claude = FakeHarness(
            kind: .claudeCode,
            models: [AgentModel(id: "claude-haiku-4-5-20251001", displayName: "Haiku")]
        )
        let (client, store, recorder) = try makeClient(
            fixture: fixture, harnesses: [claude]
        )
        defer { Task { await client.shutdown() } }
        try await client.start()
        try await waitForProbes(recorder, count: 1)

        let assistant = try #require(try await store.assistantWorkspace())
        let chat = try #require(
            try await store.chats(workspaceID: assistant.workspaceID).first
        )
        await client.send(.sendMessage(SendMessageRequest(
            workspaceID: assistant.workspaceID,
            chatID: chat.chatID,
            text: "hello"
        )))
        #expect(await waitUntil { claude.latestSession != nil })
        claude.latestSession?.emit(.rateLimit(RateLimitReport(status: .exhausted)))
        try? await Task.sleep(for: .milliseconds(400))
        #expect(try await store.chat(chat.chatID)?.harness == HarnessKind.claudeCode.rawValue)
        #expect(try await store.chatTransitions(chatID: chat.chatID).isEmpty)
    }

    private func makeFixture() async throws -> GitFixture {
        try await GitFixture.initialized()
    }

    private func makeClient(
        fixture: GitFixture,
        harnesses: [FakeHarness],
        enabledExperimental: Set<HarnessKind> = []
    ) throws -> (InProcessCoreClient, OreStore, CoreEventRecorder) {
        let databasePath = fixture.root.appendingPathComponent("ore.sqlite")
        let store = try OreStore(path: databasePath)
        let client = InProcessCoreClient(
            store: store,
            harnessRegistry: HarnessRegistry(
                harnesses: harnesses,
                enabledExperimental: enabledExperimental
            ),
            worktreeRoot: fixture.worktreeRoot
        )
        return (client, store, CoreEventRecorder(client))
    }

    private func waitForProbes(_ recorder: CoreEventRecorder, count: Int) async throws {
        let event = await recorder.waitFor {
            if case .harnessProbeCompleted(let probes) = $0 {
                return probes.count >= count
            }
            return false
        }
        #expect(event != nil, "expected \(count) harness probes")
    }
}
