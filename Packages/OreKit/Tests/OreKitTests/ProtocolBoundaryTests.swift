import Foundation
import Testing

@testable import OreProtocol

/// `CoreCommand`/`CoreEvent` are the seam a hosted version of ORE would run
/// across. If anything on either side stops round-tripping through JSON, that
/// option quietly closes — so it's asserted here rather than assumed.
struct ProtocolBoundaryTests {
    private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    @Test func everyAgentEventCaseRoundTrips() throws {
        let turnID = TurnID(rawValue: "turn-1")
        let events: [AgentEvent] = [
            .sessionStarted(SessionStarted(
                sessionID: SessionID(rawValue: "s"), providerSessionID: "p",
                harness: .claudeCode, model: "opus", workingDirectory: "/tmp",
                availableTools: ["Bash"], harnessVersion: "2.1.154"
            )),
            .statusChanged(.runningTool),
            .turnStarted(TurnStarted(turnID: turnID, model: "opus")),
            .textDelta(BlockDelta(turnID: turnID, blockID: "b", text: "hi")),
            .thinkingDelta(BlockDelta(turnID: turnID, blockID: "b", text: "hmm")),
            .blockCompleted(BlockCompleted(
                turnID: turnID, blockID: "b", kind: .text, text: "hi"
            )),
            .toolCall(ToolCall(
                turnID: turnID, id: "t1", name: "Bash",
                displayName: "git status", input: ["command": "git status"]
            )),
            .toolResult(ToolResult(
                turnID: turnID, toolCallID: "t1", isError: false, text: "clean"
            )),
            .planUpdated(PlanUpdate(
                turnID: turnID, content: .todos([TodoItem(text: "ship", status: .pending)])
            )),
            .planUpdated(PlanUpdate(
                turnID: turnID, content: .proposal(markdown: "# plan", permissionRequestID: "r1")
            )),
            .permissionRequest(PermissionRequest(
                turnID: turnID, id: "r1", toolCallID: "t1", toolName: "Write",
                input: ["file_path": "/tmp/a.txt"],
                suggestions: [PermissionSuggestion(
                    kind: .setMode, title: "Accept edits", raw: ["type": "setMode"]
                )]
            )),
            .permissionResolved(PermissionResolution(
                id: "r1", decision: .allow(updatedInput: ["command": "git status -s"])
            )),
            .permissionResolved(PermissionResolution(id: "r1", decision: .deny(reason: "no"))),
            .question(AgentQuestion(
                turnID: turnID, id: "q1", prompt: "Which branch?",
                options: [AgentQuestion.Option(label: "master")]
            )),
            .usage(UsageReport(turnID: turnID, inputTokens: 3, outputTokens: 5, contextWindow: 200_000)),
            .rateLimit(RateLimitReport(status: .allowed, window: "five_hour")),
            .turnCompleted(TurnResult(turnID: turnID, outcome: .completed, summary: "done")),
            .sessionError(SessionError(kind: .notAuthenticated, message: "sign in")),
            .sessionEnded(SessionEnded(
                sessionID: SessionID(rawValue: "s"), exitCode: 0, wasUnexpected: false
            )),
        ]

        for event in events {
            #expect(try roundTrip(event) == event)
        }
    }

    @Test func coreEventSnapshotRoundTrips() throws {
        let snapshot = CoreSnapshot(
            workspaces: [WorkspaceSummary(
                id: WorkspaceID(rawValue: "w1"),
                name: "belgrade",
                repositoryPath: "/repo",
                worktreePath: "/Users/x/ore/workspaces/repo/belgrade",
                branch: "ore/belgrade",
                baseBranch: "master",
                stackedOn: WorkspaceID(rawValue: "w0"),
                harness: .claudeCode,
                status: .awaitingInput,
                hasUnread: true,
                gitStatus: GitStatusSummary(
                    changedFileCount: 3, insertions: 40, deletions: 2,
                    hasUncommittedChanges: true, generation: 7
                ),
                baseSync: BaseSyncStatus(
                    defaultBranch: "master",
                    localDefaultBehindOrigin: 2,
                    workspaceBehindOrigin: 4,
                    wouldConflict: true
                )
            )],
            chats: [ChatSummary(
                id: ChatID(rawValue: "chat-1"),
                workspaceID: WorkspaceID(rawValue: "w1"),
                title: "Implementation",
                harness: .codex,
                model: "gpt-5.3-codex",
                draftText: "remember the edge case"
            )],
            harnesses: [HarnessProbeResult(
                kind: .claudeCode, executablePath: "/usr/local/bin/claude",
                version: "2.1.154", authState: .authenticated
            )]
        )

        let decoded = try JSONDecoder().decode(
            CoreSnapshot.self, from: try JSONEncoder().encode(snapshot)
        )
        #expect(decoded.workspaces == snapshot.workspaces)
        #expect(decoded.chats == snapshot.chats)
        #expect(decoded.harnesses == snapshot.harnesses)
    }

    @Test func chatCommandsRoundTripWithTheirRoutingIdentity() throws {
        let workspaceID = WorkspaceID(rawValue: "w1")
        let chatID = ChatID(rawValue: "c1")
        let commands: [CoreCommand] = [
            .sendMessage(SendMessageRequest(
                workspaceID: workspaceID,
                chatID: chatID,
                text: "Move quickly",
                reasoningEffort: .low,
                serviceTier: "fast"
            )),
            .createChat(CreateChatRequest(
                workspaceID: workspaceID, title: "Review", harness: .codex, model: "gpt-5"
            )),
            .switchChatHarness(workspaceID, chatID, harness: .claudeCode, model: "opus"),
            .setChatModel(workspaceID, chatID, model: "sonnet"),
            .renameChat(workspaceID, chatID, title: "Broken Symmetry", userInitiated: true),
            .setChatDraft(workspaceID, chatID, text: "draft"),
            .resolveChatPermission(workspaceID, chatID, "permission", .allow),
            .revertChatToCheckpoint(workspaceID, chatID, "turn"),
            .resolveConflict(workspaceID, path: "Sources/App.swift", side: "ours"),
            .resolveConflictHunk(workspaceID, path: "Sources/App.swift", startLine: 12, side: "theirs"),
            .rerunFailedChecks(workspaceID),
            .pullDefaultBranch(workspaceID),
            .continueAfterMerge(workspaceID),
        ]
        for command in commands {
            let data = try JSONEncoder().encode(command)
            _ = try JSONDecoder().decode(CoreCommand.self, from: data)
        }
    }

    @Test func modelCatalogEventsRoundTripWithProviderMetadata() throws {
        let event = CoreEvent.modelCatalogUpdated(.codex, [AgentModel(
            id: "gpt-example",
            displayName: "GPT Example",
            description: "A discovered model",
            isDefault: true,
            supportedReasoningEfforts: ["low", "high"],
            supportedServiceTiers: ["fast"]
        )])
        let decoded = try JSONDecoder().decode(
            CoreEvent.self, from: JSONEncoder().encode(event)
        )
        guard case .modelCatalogUpdated(let harness, let models) = decoded else {
            Issue.record("decoded the wrong core event")
            return
        }
        #expect(harness == .codex)
        #expect(models.first?.id == "gpt-example")
        #expect(models.first?.supportedReasoningEfforts == ["low", "high"])
        #expect(models.first?.supportedServiceTiers == ["fast"])
    }

    @Test func jsonValuePreservesIntegersExactly() throws {
        // Tool inputs are handed straight back to the CLI when a permission is
        // allowed; turning `5` into `5.0` would corrupt the call being approved.
        let input: JSONValue = [
            "count": 5,
            "ratio": .number(0.5),
            "flag": true,
            "name": "Bash",
            "nested": ["items": [1, 2, 3]],
            "missing": nil,
        ]
        let encoded = try JSONEncoder().encode(input)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("\"count\":5"))
        #expect(!text.contains("5.0"))
        #expect(try roundTrip(input) == input)
    }

    @Test func createWorkspaceSeedsRoundTrip() throws {
        let seeds: [CreateWorkspaceRequest.Seed] = [
            .defaultBranch,
            .branch("release/1.0"),
            .workspace(WorkspaceID(rawValue: "w1")),
            .githubIssue(number: 42),
            .githubPullRequest(number: 7),
        ]
        for seed in seeds {
            let request = CreateWorkspaceRequest(
                repositoryPath: "/repo", name: "x", seed: seed
            )
            let decoded = try JSONDecoder().decode(
                CreateWorkspaceRequest.self, from: try JSONEncoder().encode(request)
            )
            #expect(decoded.name == request.name)
        }
    }
}
