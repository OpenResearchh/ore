import Foundation
import Testing

import OreSupport
@testable import OreCore
@testable import OrePersistence
@testable import OreProtocol

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The assistant's action lane, exercised the way the MCP-server process uses
/// it: real socket, real NDJSON, real policy — no shortcuts through the actor.
///
/// Serialized: each test owns a listen socket and several git processes. Running
/// them in parallel on a 2-core CI runner exhausts fds (`socket`) and starves
/// `workspaceAdded` waits (`noWorkspace`).
@Suite(.serialized)
struct AssistantBridgeTests {
    @Test func autoActionsRunWithoutConfirmationAndAreAudited() async throws {
        try await BridgeHarness.run { harness in

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
    }

    @Test func decliningAConfirmationDeniesTheActionAndTellsTheModel() async throws {
        try await BridgeHarness.run { harness in

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
    }

    @Test func aTaskGrantCoversTheSecondActionWithoutAsking() async throws {
        try await BridgeHarness.run { harness in

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
    }

    @Test func aTaskGrantDoesNotCoverADifferentWorkspace() async throws {
        try await BridgeHarness.run { harness in

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
    }

    @Test func anAlwaysGrantIsRememberedInMemoryImmediately() async throws {
        try await BridgeHarness.run { harness in

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
    }

    /// On 2026-09-19 one "Always" let the assistant permanently delete
    /// workspaces for the rest of the session without a word. A delete must
    /// ask every time — including under a grant stored before this rule.
    @Test func aPermanentDeleteAsksEvenUnderAStoredAlways() async throws {
        try await BridgeHarness.run { harness in
            let workspaceID = try await harness.makeWorkspace(named: "delete-always")
            await harness.client.send(.archiveWorkspace(workspaceID))
            _ = await harness.recorder.waitFor(matching: {
                if case .workspaceUpdated(let summary) = $0 { return summary.isArchived }
                return false
            })
            try await harness.store.saveAssistantGrant(AssistantActionClass.deleteWorkspace.rawValue)

            async let deleted = harness.callBridgeAsync(
                tool: "DeleteWorkspace",
                arguments: ["workspaceID": .string(workspaceID.rawValue)]
            )
            guard case .assistantConfirmationRequested(let confirmation)? =
                await harness.recorder.waitFor(timeout: .seconds(10), matching: {
                    if case .assistantConfirmationRequested = $0 { return true }
                    return false
                })
            else {
                Issue.record("the delete ran without asking")
                return
            }
            #expect(confirmation.actionClass == .deleteWorkspace)
            // Answering "always" again allows this one delete and no more.
            await harness.client.send(
                .resolveAssistantConfirmation(confirmation.id, .allow(.always))
            )
            #expect(try await deleted.ok)
            let audit = try await harness.store.assistantActions()
            #expect(!audit.contains { $0.decision == "granted:always" })
        }
    }

    @Test func onlyPermanentDeletesRefuseStandingGrants() {
        for actionClass in AssistantActionClass.allCases {
            #expect(actionClass.allowsStandingGrant == (actionClass != .deleteWorkspace))
        }
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
        try await BridgeHarness.run { harness in

            let response = try harness.callBridge(tool: "TeleportWorkspace", arguments: [:])
            #expect(!response.ok)
        }
    }

    @Test func workspaceOrganizationActionsMatchTheSidebarWithoutConfirmation() async throws {
        try await BridgeHarness.run { harness in
            let workspaceID = try await harness.makeWorkspace(named: "before")

            let renamed = try harness.callBridge(
                tool: "RenameWorkspace",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "name": .string("after"),
                ]
            )
            #expect(renamed.ok)
            #expect(try await harness.store.workspace(workspaceID)?.name == "after")

            let pinned = try harness.callBridge(
                tool: "SetWorkspacePinned",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "pinned": .bool(true),
                ]
            )
            #expect(pinned.ok)
            #expect(try await harness.store.workspace(workspaceID)?.isPinned == true)

            let actions = try await harness.store.assistantActions()
            #expect(actions.first { $0.tool == "RenameWorkspace" }?.decision == "auto")
            #expect(actions.first { $0.tool == "SetWorkspacePinned" }?.decision == "auto")
        }
    }

    @Test func destructiveParityActionsStillRequireTheUser() async throws {
        try await BridgeHarness.run { harness in
            let workspaceID = try await harness.makeWorkspace(named: "protected")
            async let call = harness.callBridgeAsync(
                tool: "MergePullRequest",
                arguments: ["workspaceID": .string(workspaceID.rawValue)]
            )

            guard case .assistantConfirmationRequested(let confirmation)? =
                await harness.recorder.waitFor(matching: {
                    if case .assistantConfirmationRequested = $0 { return true }
                    return false
                })
            else {
                Issue.record("merge did not request confirmation")
                return
            }
            #expect(confirmation.actionClass == .changeGitHistory)
            await harness.client.send(.resolveAssistantConfirmation(confirmation.id, .deny))
            let response = try await call
            #expect(!response.ok)
        }
    }

    @Test func diffReviewStateActionsAreScopedToAWorkspace() async throws {
        try await BridgeHarness.run { harness in
            let workspaceID = try await harness.makeWorkspace(named: "review")
            let comment = try harness.callBridge(
                tool: "AddDiffComment",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "path": .string("main.swift"),
                    "startLine": .integer(7),
                    "body": .string("Keep this branch explicit."),
                ]
            )
            #expect(comment.ok)
            let pending = try await harness.client.pendingDiffComments(workspaceID: workspaceID)
            #expect(pending.count == 1)
            #expect(pending.first?.filePath == "main.swift")

            let viewed = try harness.callBridge(
                tool: "MarkFileViewed",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "path": .string("main.swift"),
                    "contentHash": .string("hash-1"),
                ]
            )
            #expect(viewed.ok)
            #expect(try await harness.store.viewedFiles(workspaceID: workspaceID)["main.swift"] == "hash-1")
        }
    }

    @Test func listHarnessesRunsWithoutConfirmation() async throws {
        try await BridgeHarness.run { harness in

            // The test registry has no harnesses, so probes stay empty — the tool
            // still answers (auto tier, no confirmation event) rather than asking
            // or failing.
            let response = try harness.callBridge(tool: "ListHarnesses", arguments: [:])
            #expect(response.ok)
            #expect(response.result?.contains("probed") == true)

            let audit = try await harness.store.assistantActions()
            #expect(audit.first?.tool == "ListHarnesses")
            #expect(audit.first?.decision == "auto")
        }
    }

    @Test func creatingAWorkspaceOnAnUnreadyHarnessFailsHelpfully() async throws {
        try await BridgeHarness.run { harness in

            await harness.client.send(.addRepository(path: harness.fixture.repository.path))
            let response = try harness.callBridge(
                tool: "CreateWorkspace",
                arguments: [
                    "repository": .string(harness.fixture.repository.path),
                    "harness": .string("codex"),
                ]
            )
            #expect(!response.ok)
            #expect(response.error?.contains("isn't ready") == true)
        }
    }

    @Test func setChatModelRunsWithoutConfirmation() async throws {
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "model-test")
            let chats = try await harness.store.chats(workspaceID: workspaceID)
            let chatID = try #require(chats.first?.chatID)

            let response = try harness.callBridge(
                tool: "SetChatModel",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "chatID": .string(chatID.rawValue),
                    "model": .string("claude-opus-4-6"),
                ]
            )
            #expect(response.ok)
            #expect(response.result?.contains("claude-opus-4-6") == true)

            let audit = try await harness.store.assistantActions()
            #expect(audit.first?.tool == "SetChatModel")
            #expect(audit.first?.decision == "auto")
        }
    }

    @Test func createChatPassesModelModeAndEffort() async throws {
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "chat-config")
            let response = try harness.callBridge(
                tool: "CreateChat",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "title": .string("Plan pass"),
                    "permissionMode": .string("plan"),
                    "effort": .string("high"),
                ]
            )
            #expect(response.ok)
            let chats = try await harness.store.chats(workspaceID: workspaceID)
            let created = try #require(chats.first { $0.title == "Plan pass" })
            #expect(created.permissionMode == PermissionMode.plan.rawValue)
            #expect(created.reasoningEffort == ReasoningEffort.high.rawValue)
        }
    }

    @Test func archiveSuccessPublishesTheCommittedWorkspaceState() async throws {
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "bridge archive")
            let checkpoint = await harness.recorder.checkpoint()
            let request = AssistantBridgeRequest(
                id: UUID().uuidString.lowercased(),
                tool: "ArchiveWorkspace",
                arguments: .object(["workspaceID": .string(workspaceID.rawValue)])
            )
            // The transport has its own socket tests. Start at the app-side
            // handler here so this regression isolates action completion -> event
            // propagation instead of depending on Unix-socket availability.
            async let call = harness.client.handleAssistantRequest(request)
            guard case .assistantConfirmationRequested(let confirmation)? =
                await harness.recorder.waitFor(after: checkpoint, matching: {
                    if case .assistantConfirmationRequested = $0 { return true }
                    return false
                })
            else {
                Issue.record("no archive confirmation")
                return
            }
            await harness.client.send(
                .resolveAssistantConfirmation(confirmation.id, .allow(.once))
            )

            let response = await call
            #expect(response.ok)
            let event = await harness.recorder.waitFor(after: checkpoint) {
                if case .workspaceUpdated(let summary) = $0 {
                    return summary.id == workspaceID && summary.isArchived
                }
                return false
            }
            #expect(event != nil)
            #expect(try await harness.store.workspace(workspaceID)?.isArchived == true)
        }
    }

    @Test func failedAssistantArchiveLeavesTheWorkspaceListUntouched() async throws {
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "archive failure")
            let missing = WorkspaceID(rawValue: workspaceID.rawValue + "-missing")
            let checkpoint = await harness.recorder.checkpoint()
            let request = AssistantBridgeRequest(
                id: UUID().uuidString.lowercased(),
                tool: "ArchiveWorkspace",
                arguments: .object(["workspaceID": .string(missing.rawValue)])
            )
            async let call = harness.client.handleAssistantRequest(request)
            guard case .assistantConfirmationRequested(let confirmation)? =
                await harness.recorder.waitFor(after: checkpoint, matching: {
                    if case .assistantConfirmationRequested = $0 { return true }
                    return false
                })
            else {
                Issue.record("no archive confirmation")
                return
            }
            await harness.client.send(
                .resolveAssistantConfirmation(confirmation.id, .allow(.once))
            )

            let response = await call
            #expect(!response.ok)
            #expect(response.error?.contains(missing.rawValue) == true)
            #expect(try await harness.store.workspace(workspaceID)?.isArchived == false)
            let events = await harness.recorder.all(after: checkpoint)
            #expect(!events.contains { event in
                switch event {
                case .workspaceAdded, .workspaceUpdated, .workspaceRemoved:
                    true
                default:
                    false
                }
            })
        }
    }

    @Test func assistantCloseAndReopenPublishTheirFinalListState() async throws {
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "chat list")
            let chatID = try #require(
                try await harness.store.chats(workspaceID: workspaceID).first?.chatID
            )

            var checkpoint = await harness.recorder.checkpoint()
            let closed = await harness.client.handleAssistantRequest(AssistantBridgeRequest(
                id: UUID().uuidString.lowercased(),
                tool: "CloseChat",
                arguments: .object([
                    "workspaceID": .string(workspaceID.rawValue),
                    "chatID": .string(chatID.rawValue),
                ])
            ))
            #expect(closed.ok)
            let closeEvent = await harness.recorder.waitFor(after: checkpoint) { event in
                if case .chatUpdated(let chat) = event {
                    return chat.id == chatID && chat.isClosed
                }
                return false
            }
            #expect(closeEvent != nil)

            checkpoint = await harness.recorder.checkpoint()
            let reopened = await harness.client.handleAssistantRequest(AssistantBridgeRequest(
                id: UUID().uuidString.lowercased(),
                tool: "ReopenChat",
                arguments: .object([
                    "workspaceID": .string(workspaceID.rawValue),
                    "chatID": .string(chatID.rawValue),
                ])
            ))
            #expect(reopened.ok)
            let reopenEvent = await harness.recorder.waitFor(after: checkpoint) { event in
                if case .chatUpdated(let chat) = event {
                    return chat.id == chatID && !chat.isClosed
                }
                return false
            }
            #expect(reopenEvent != nil)
        }
    }

    @Test func setComposerDraftStagesTextWithoutConfirmation() async throws {
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "composer-draft")
            let chatID = try #require(
                try await harness.store.chats(workspaceID: workspaceID).first?.chatID
            )
            let checkpoint = await harness.recorder.checkpoint()

            let response = try harness.callBridge(
                tool: "SetComposerDraft",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "chatID": .string(chatID.rawValue),
                    "text": .string("Draft this for me"),
                ]
            )
            #expect(response.ok)

            let event = await harness.recorder.waitFor(after: checkpoint) {
                if case .assistantUIAction(.setComposerDraft(_, let id, let text, let append)) = $0 {
                    return id == chatID && text == "Draft this for me" && append == false
                }
                return false
            }
            #expect(event != nil)

            let audit = try await harness.store.assistantActions()
            #expect(audit.first?.tool == "SetComposerDraft")
            #expect(audit.first?.decision == "auto")
        }
    }

    @Test func setComposerDraftRefusesAClosedTab() async throws {
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "closed-composer")
            let chatID = try #require(
                try await harness.store.chats(workspaceID: workspaceID).first?.chatID
            )
            let closed = await harness.client.handleAssistantRequest(AssistantBridgeRequest(
                id: UUID().uuidString.lowercased(),
                tool: "CloseChat",
                arguments: .object([
                    "workspaceID": .string(workspaceID.rawValue),
                    "chatID": .string(chatID.rawValue),
                ])
            ))
            #expect(closed.ok)

            let response = try harness.callBridge(
                tool: "SetComposerDraft",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "chatID": .string(chatID.rawValue),
                    "text": .string("into a closed tab"),
                ]
            )
            #expect(!response.ok)
            #expect(response.error?.contains("closed") == true)
        }
    }

    @Test func tagComposerFileValidatesTheFileExists() async throws {
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "composer-tag")
            let chatID = try #require(
                try await harness.store.chats(workspaceID: workspaceID).first?.chatID
            )
            let worktree = try await harness.worktreePath(of: workspaceID)
            try "print(1)\n".write(
                to: worktree.appendingPathComponent("main.swift"),
                atomically: true, encoding: .utf8
            )
            let checkpoint = await harness.recorder.checkpoint()

            let tagged = try harness.callBridge(
                tool: "TagComposerFile",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "chatID": .string(chatID.rawValue),
                    "path": .string("main.swift"),
                ]
            )
            #expect(tagged.ok)
            #expect(tagged.result?.contains("main.swift") == true)

            let event = await harness.recorder.waitFor(after: checkpoint) {
                if case .assistantUIAction(.tagComposerFile(_, let id, let path, let name)) = $0 {
                    return id == chatID && path == "main.swift" && name == "main.swift"
                }
                return false
            }
            #expect(event != nil)

            // A file that isn't there fails loudly rather than tagging a ghost.
            let missing = try harness.callBridge(
                tool: "TagComposerFile",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "chatID": .string(chatID.rawValue),
                    "path": .string("does-not-exist.txt"),
                ]
            )
            #expect(!missing.ok)
            #expect(missing.error?.contains("No file") == true)
        }
    }

    @Test func tagComposerFileRefusesToEscapeTheWorktree() async throws {
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "composer-escape")
            let chatID = try #require(
                try await harness.store.chats(workspaceID: workspaceID).first?.chatID
            )

            let response = try harness.callBridge(
                tool: "TagComposerFile",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "chatID": .string(chatID.rawValue),
                    "path": .string("../../etc/hosts"),
                ]
            )
            #expect(!response.ok)
            #expect(response.error?.contains("outside the workspace") == true)
        }
    }

    @Test func clearComposerTagsRunsWithoutConfirmation() async throws {
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "composer-clear")
            let chatID = try #require(
                try await harness.store.chats(workspaceID: workspaceID).first?.chatID
            )
            let checkpoint = await harness.recorder.checkpoint()

            let response = try harness.callBridge(
                tool: "ClearComposerTags",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "chatID": .string(chatID.rawValue),
                    "clearDraft": .bool(true),
                ]
            )
            #expect(response.ok)

            let event = await harness.recorder.waitFor(after: checkpoint) {
                if case .assistantUIAction(.clearComposerTags(_, let id, let clearDraft)) = $0 {
                    return id == chatID && clearDraft == true
                }
                return false
            }
            #expect(event != nil)

            let audit = try await harness.store.assistantActions()
            #expect(audit.first?.tool == "ClearComposerTags")
            #expect(audit.first?.decision == "auto")
        }
    }

    @Test func openFileValidatesTheFileExists() async throws {
        try await BridgeHarness.run { harness in
            let workspaceID = try await harness.makeWorkspace(named: "open-file")
            let worktree = try await harness.worktreePath(of: workspaceID)
            try "hello\n".write(
                to: worktree.appendingPathComponent("readme.md"), atomically: true, encoding: .utf8
            )

            let missing = try harness.callBridge(
                tool: "OpenFile",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "path": .string("nope.swift"),
                ]
            )
            #expect(!missing.ok)

            let checkpoint = await harness.recorder.checkpoint()
            let opened = try harness.callBridge(
                tool: "OpenFile",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "path": .string("readme.md"),
                    "mode": .string("diff"),
                ]
            )
            #expect(opened.ok)
            let event = await harness.recorder.waitFor(after: checkpoint) {
                if case .assistantUIAction(.openFile(_, let path, let mode, let line)) = $0 {
                    return path == "readme.md" && mode == "diff" && line == nil
                }
                return false
            }
            #expect(event != nil)
        }
    }

    @Test func closeFileRunsWithoutConfirmation() async throws {
        try await BridgeHarness.run { harness in
            let workspaceID = try await harness.makeWorkspace(named: "close-file")
            let checkpoint = await harness.recorder.checkpoint()
            let response = try harness.callBridge(
                tool: "CloseFile",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "path": .string("readme.md"),
                ]
            )
            #expect(response.ok)
            let event = await harness.recorder.waitFor(after: checkpoint) {
                if case .assistantUIAction(.closeFile(_, let path)) = $0 {
                    return path == "readme.md"
                }
                return false
            }
            #expect(event != nil)
        }
    }

    @Test func respondToPlanRefusesWhenNoneIsPending() async throws {
        try await BridgeHarness.run { harness in
            let workspaceID = try await harness.makeWorkspace(named: "no-plan")
            let chatID = try #require(
                try await harness.store.chats(workspaceID: workspaceID).first?.chatID
            )
            let response = try harness.callBridge(
                tool: "RespondToPlan",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "chatID": .string(chatID.rawValue),
                    "approve": .bool(true),
                ]
            )
            #expect(!response.ok)
            #expect(response.error?.contains("plan") == true)
        }
    }

    @Test func retryLastTurnRefusesWhenThereIsNoPrompt() async throws {
        try await BridgeHarness.run { harness in
            let workspaceID = try await harness.makeWorkspace(named: "no-retry")
            let chatID = try #require(
                try await harness.store.chats(workspaceID: workspaceID).first?.chatID
            )
            let response = try harness.callBridge(
                tool: "RetryLastTurn",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "chatID": .string(chatID.rawValue),
                ]
            )
            #expect(!response.ok)
            #expect(response.error?.contains("prompt") == true)
        }
    }

    @Test func addRepositoryRegistersALocalGitRepo() async throws {
        try await BridgeHarness.run { harness in
            let extra = try await GitFixture.initialized()
            let before = try await harness.store.repositories().count
            let response = try harness.callBridge(
                tool: "AddRepository",
                arguments: ["path": .string(extra.repository.path)]
            )
            #expect(response.ok)
            #expect(try await harness.store.repositories().count == before + 1)
        }
    }

    @Test func createProjectMakesAndRegistersANewRepositoryWithoutConfirmation() async throws {
        try await BridgeHarness.run { harness in
            let projects = harness.fixture.root
                .appendingPathComponent("projects", isDirectory: true)
            let before = try await harness.store.repositories().count

            let response = try harness.callBridge(
                tool: "CreateProject",
                arguments: [
                    "name": .string("LACE"),
                    "parentDirectory": .string(projects.path),
                    "createWorkspace": .bool(false),
                ]
            )

            #expect(response.ok)
            #expect(response.result?.contains("LACE") == true)
            #expect(try await harness.store.repositories().count == before + 1)
            #expect(FileManager.default.fileExists(
                atPath: projects.appendingPathComponent("LACE/.git").path
            ))

            // Auto tier: the user is not asked to confirm starting the project
            // they just asked for, but it is still audited.
            let audit = try await harness.store.assistantActions()
            #expect(audit.first?.tool == "CreateProject")
            #expect(audit.first?.decision == "auto")
        }
    }

    @Test func createProjectWithoutANameFailsHelpfully() async throws {
        try await BridgeHarness.run { harness in
            let response = try harness.callBridge(
                tool: "CreateProject", arguments: ["name": .string("  ")]
            )
            #expect(!response.ok)
            #expect(response.error?.contains("name") == true)
        }
    }

    @Test func getAppStateRunsWithoutConfirmation() async throws {
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "state-test")
            let response = try harness.callBridge(tool: "GetAppState", arguments: [:])
            #expect(response.ok)
            #expect(response.result?.contains("[ORE app state]") == true)
            #expect(response.result?.contains("state-test") == true)

            // The repository each workspace belongs to, so the assistant can tell
            // two tabs on one project apart from two separate projects — the
            // distinction every cross-project routing decision rests on.
            let record = try #require(try await harness.store.workspace(workspaceID))
            let repository = URL(fileURLWithPath: record.repositoryPath).lastPathComponent
            #expect(response.result?.contains("repo \(repository)") == true)
            #expect(response.result?.contains("turns=") == true)
        }
    }

    @Test func appStateReportsAStagedComposerDraft() async throws {
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "draft-state")
            let chatID = try #require(
                try await harness.store.chats(workspaceID: workspaceID).first?.chatID
            )
            let checkpoint = await harness.recorder.checkpoint()
            await harness.client.send(
                .setChatDraft(workspaceID, chatID, text: "half a thought")
            )
            _ = await harness.recorder.waitFor(after: checkpoint) {
                if case .chatUpdated(let chat) = $0 {
                    return chat.id == chatID && chat.draftText == "half a thought"
                }
                return false
            }

            let response = try harness.callBridge(tool: "GetAppState", arguments: [:])
            #expect(response.ok)
            #expect(response.result?.contains("draft=\"half a thought\"") == true)
        }
    }

    @Test func sendPromptToProjectRefusesToGuessAmongSeveralTabs() async throws {
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "route-test")
            let second = try harness.callBridge(
                tool: "CreateChat",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "title": .string("Second tab"),
                ]
            )
            #expect(second.ok)

            let guessed = try harness.callBridge(
                tool: "SendPromptToProject",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "text": .string("continue the work"),
                ]
            )
            #expect(!guessed.ok)
            #expect(guessed.error?.contains("chatID") == true)

            let chats = try await harness.store.chats(workspaceID: workspaceID)
            let secondID = try #require(chats.first { $0.title == "Second tab" }?.chatID)
            let named = try harness.callBridge(
                tool: "SendPromptToProject",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "chatID": .string(secondID.rawValue),
                    "text": .string("continue the work"),
                ]
            )
            #expect(named.ok)
        }
    }

    @Test func routeTaskNamesTheFocusedTabForUnplacedRepoWork() async throws {
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "kailash")
            let chats = try await harness.store.chats(workspaceID: workspaceID)
            let chatID = try #require(chats.first?.chatID)

            let response = try harness.callBridge(
                tool: "RouteTask",
                arguments: ["utterance": .string("Fix the flaky test")]
            )
            #expect(response.ok)
            let body = try #require(response.result)
            #expect(body.contains("action: sendExistingTab"))
            #expect(body.contains("workspaceID: \(workspaceID.rawValue)"))
            #expect(body.contains("chatID: \(chatID.rawValue)"))
        }
    }

    @Test func createWorkspaceBesideADirtyTreeAsksFirst() async throws {
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "dirty-sibling")
            let worktree = try await harness.worktreePath(of: workspaceID)
            try "uncommitted\n".write(
                to: worktree.appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8
            )

            async let call = harness.callBridgeAsync(
                tool: "CreateWorkspace",
                arguments: [
                    "repository": .string(harness.fixture.repository.path),
                    "name": .string("clean-sibling"),
                    "seed": .string("workspace"),
                    "seedRef": .string(workspaceID.rawValue),
                ]
            )
            guard case .assistantConfirmationRequested(let confirmation)? =
                await harness.recorder.waitFor(matching: {
                    if case .assistantConfirmationRequested = $0 { return true }
                    return false
                })
            else {
                Issue.record("CreateWorkspace did not confirm beside a dirty worktree")
                return
            }
            #expect(confirmation.actionClass == .createWorkspace)
            #expect(confirmation.summary.contains("uncommitted"))
            await harness.client.send(.resolveAssistantConfirmation(confirmation.id, .deny))
            let response = try await call
            #expect(!response.ok)
            #expect(response.error?.contains("declined") == true)
        }
    }

    @Test func createWorkspaceOnARepoThatAlreadyHasAWorktreeReusesIt() async throws {
        try await BridgeHarness.run { harness in

            _ = try await harness.makeWorkspace(named: "existing")
            let before = try await harness.store.workspaces().map(\.id)

            let response = try harness.callBridge(
                tool: "CreateWorkspace",
                arguments: [
                    "repository": .string(harness.fixture.repository.path),
                    "name": .string("looks-new"),
                ]
            )
            #expect(response.ok)
            #expect(response.result?.contains("Reused existing workspace") == true)
            #expect(response.result?.contains("existing") == true)
            #expect(try await harness.store.workspaces().map(\.id) == before)
        }
    }

    @Test func createWorkspaceWithAnIsolationSeedStillForks() async throws {
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "parent")
            let response = try harness.callBridge(
                tool: "CreateWorkspace",
                arguments: [
                    "repository": .string(harness.fixture.repository.path),
                    "name": .string("stacked"),
                    "seed": .string("workspace"),
                    "seedRef": .string(workspaceID.rawValue),
                ]
            )
            #expect(response.ok)
            #expect(response.result?.contains("Created workspace") == true)
            #expect(response.result?.contains("stacked") == true)
            let names = try await harness.store.workspaces().map(\.name)
            #expect(names.contains("parent"))
            #expect(names.contains("stacked"))
            #expect(names.count == 2)
        }
    }

    @Test func bypassModeAsksForConfirmation() async throws {
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "bypass-test")
            let chats = try await harness.store.chats(workspaceID: workspaceID)
            let chatID = try #require(chats.first?.chatID)

            async let call = harness.callBridgeAsync(
                tool: "SetChatPermissionMode",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "chatID": .string(chatID.rawValue),
                    "mode": .string("bypassPermissions"),
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
            #expect(confirmation.actionClass == .autoAllowTab)
            #expect(confirmation.chatID == chatID)
            await harness.client.send(.resolveAssistantConfirmation(confirmation.id, .deny))
            let response = try await call
            #expect(!response.ok)
        }
    }

    @Test func aNewBypassTabAsksForConfirmation() async throws {
        // Opening a tab with every permission check off is the same grant as
        // switching one to it, and its prompt would start running at once.
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "bypass-chat-test")
            let before = try await harness.store.chats(workspaceID: workspaceID).count

            async let call = harness.callBridgeAsync(
                tool: "CreateChat",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "permissionMode": .string("bypassPermissions"),
                    "prompt": .string("clean up the repository"),
                ]
            )
            guard case .assistantConfirmationRequested(let confirmation)? =
                await harness.recorder.waitFor(matching: {
                    if case .assistantConfirmationRequested = $0 { return true }
                    return false
                })
            else {
                Issue.record("a bypass tab must ask before it opens")
                return
            }
            #expect(confirmation.actionClass == .autoAllowTab)
            await harness.client.send(.resolveAssistantConfirmation(confirmation.id, .deny))
            let response = try await call
            #expect(!response.ok)
            let after = try await harness.store.chats(workspaceID: workspaceID).count
            #expect(after == before)
        }
    }

    @Test func acceptEditsModeDoesNotAsk() async throws {
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "edits-test")
            let chats = try await harness.store.chats(workspaceID: workspaceID)
            let chatID = try #require(chats.first?.chatID)

            let response = try harness.callBridge(
                tool: "SetChatPermissionMode",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "chatID": .string(chatID.rawValue),
                    "mode": .string("acceptEdits"),
                ]
            )
            #expect(response.ok)
        }
    }

    @Test func aStalePermissionIDCannotReportFalseSuccess() async throws {
        try await BridgeHarness.run { harness in

            let workspaceID = try await harness.makeWorkspace(named: "permission-test")
            let chats = try await harness.store.chats(workspaceID: workspaceID)
            let chatID = try #require(chats.first?.chatID)
            async let call = harness.callBridgeAsync(
                tool: "ResolveChatPermission",
                arguments: [
                    "workspaceID": .string(workspaceID.rawValue),
                    "chatID": .string(chatID.rawValue),
                    "permissionID": .string("stale-permission"),
                    "allow": .bool(true),
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
                .resolveAssistantConfirmation(confirmation.id, .allow(.once))
            )

            let response = try await call
            #expect(!response.ok)
            #expect(response.error?.contains("not pending") == true)
        }
    }
}

/// A running core with its bridge up, plus a raw socket client — the same
/// wire the assistant's MCP server uses.
private final class BridgeHarness: @unchecked Sendable {
    let store: OreStore
    let client: InProcessCoreClient
    let recorder: CoreEventRecorder
    let socketURL: URL

    static func run(_ body: (BridgeHarness) async throws -> Void) async throws {
        let fixture = try await GitFixture.initialized()
        let harness = try await BridgeHarness(fixture: fixture)
        do {
            try await body(harness)
        } catch {
            await harness.shutdown()
            throw error
        }
        await harness.shutdown()
    }

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

    let fixture: GitFixture

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

        let descriptor = UnixStreamSocket.open()
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
