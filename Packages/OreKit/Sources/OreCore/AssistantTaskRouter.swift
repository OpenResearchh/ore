import Foundation
import OreProtocol

/// Pure destination picker for the Assistant's middle-manager loop.
///
/// The model still writes the brief and calls the action tool; this is the
/// fail-closed recommendation it should follow (and that eval fixtures pin).
/// Two remaining candidates become one named clarification instead of a guess.
enum AssistantTaskRouter {
    enum Action: String, Equatable {
        case sendExistingTab
        case createChat
        case createWorkspace
        case assistantChat
        case clarify
    }

    enum Confidence: String, Equatable {
        case high, medium, low
    }

    struct Tab: Equatable {
        var id: ChatID
        var title: String
        var status: AgentStatus
        var isClosed: Bool
        var isFocused: Bool
        var pendingInput: Bool
    }

    struct Workspace: Equatable {
        var id: WorkspaceID
        var name: String
        var repo: String
        var dirtyFileCount: Int
        var tabs: [Tab]
    }

    struct Snapshot: Equatable {
        var assistantWorkspaceID: WorkspaceID
        var focusedWorkspaceID: WorkspaceID?
        var focusedChatID: ChatID?
        var workspaces: [Workspace]
    }

    struct Decision: Equatable {
        var action: Action
        var workspaceID: WorkspaceID?
        var chatID: ChatID?
        var confidence: Confidence
        var question: String?
        var reason: String
    }

    static func route(utterance: String, snapshot: Snapshot) -> Decision {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        let matchedWorkspaces = snapshot.workspaces.filter { mentions($0.name, in: lowered) }
        let matchedRepos = snapshot.workspaces.filter { mentions($0.repo, in: lowered) }
        let named = uniqueByID(matchedWorkspaces + matchedRepos)
        let matchedTabs: [(Workspace, Tab)] = snapshot.workspaces.flatMap { workspace in
            workspace.tabs
                .filter { mentions($0.title, in: lowered) }
                .map { (workspace, $0) }
        }

        if wantsNewWorkspace(lowered) {
            if named.count > 1 {
                return clarify(
                    named.map(\.name),
                    reason: "Several repositories match a new-worktree request."
                )
            }
            let workspace = named.first ?? focusedWorkspace(in: snapshot)
            return Decision(
                action: .createWorkspace,
                workspaceID: workspace?.id,
                confidence: named.count == 1 || workspace != nil ? .high : .medium,
                reason: "Asked for a new worktree or isolated branch."
            )
        }

        if wantsNewTab(lowered) {
            if named.count > 1 {
                return clarify(named.map(\.name), reason: "Several workspaces match a new-tab request.")
            }
            let workspace = named.first ?? focusedWorkspace(in: snapshot)
            guard let workspace else {
                return Decision(
                    action: .clarify,
                    confidence: .low,
                    question: "Which workspace should the new tab go in?",
                    reason: "Asked for a new tab without naming a place."
                )
            }
            return Decision(
                action: .createChat,
                workspaceID: workspace.id,
                confidence: .high,
                reason: "Asked for a fresh tab on this worktree."
            )
        }

        if matchedTabs.count > 1 {
            let labels = matchedTabs.map { "\"\($0.1.title)\" on \($0.0.name)" }
            return clarify(labels, reason: "Several tabs match the gist.")
        }

        if let (workspace, tab) = matchedTabs.first {
            if tab.isClosed || !tabIsHealthy(tab) {
                return Decision(
                    action: .createChat,
                    workspaceID: workspace.id,
                    confidence: .high,
                    reason: tab.isClosed
                        ? "That tab is closed — a new tab keeps the work off a retired conversation."
                        : "That tab is blocked or failed — a new tab keeps this request moving."
                )
            }
            return Decision(
                action: .sendExistingTab,
                workspaceID: workspace.id,
                chatID: tab.id,
                confidence: .high,
                reason: "Named tab is healthy and already carrying this work."
            )
        }

        if named.count > 1 {
            return clarify(named.map(\.name), reason: "Several workspaces match the name.")
        }

        if let workspace = named.first {
            return destination(in: workspace, utterance: lowered, snapshot: snapshot)
        }

        if isAssistantOnly(lowered) {
            return Decision(
                action: .assistantChat,
                workspaceID: snapshot.assistantWorkspaceID,
                confidence: .high,
                reason: "This is a conversation with the assistant, not repository work."
            )
        }

        if looksLikeRepoWork(lowered), let workspace = focusedWorkspace(in: snapshot)
            ?? (snapshot.workspaces.count == 1 ? snapshot.workspaces.first : nil) {
            return destination(in: workspace, utterance: lowered, snapshot: snapshot)
        }

        if looksLikeRepoWork(lowered) {
            return Decision(
                action: .clarify,
                confidence: .low,
                question: "Which project should that go to?",
                reason: "Repository work with no named or focused workspace."
            )
        }

        return Decision(
            action: .assistantChat,
            workspaceID: snapshot.assistantWorkspaceID,
            confidence: .medium,
            reason: "No project named; keep this in the assistant's own chat."
        )
    }

    /// Wire format the RouteTask tool returns to the model.
    static func render(_ decision: Decision) -> String {
        var lines = [
            "action: \(decision.action.rawValue)",
            "confidence: \(decision.confidence.rawValue)",
            "reason: \(decision.reason)",
        ]
        if let workspaceID = decision.workspaceID {
            lines.insert("workspaceID: \(workspaceID.rawValue)", at: 1)
        }
        if let chatID = decision.chatID {
            lines.insert("chatID: \(chatID.rawValue)", at: 2)
        }
        if let question = decision.question {
            lines.append("question: \(question)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Place

    private static func destination(
        in workspace: Workspace,
        utterance: String,
        snapshot: Snapshot
    ) -> Decision {
        if wantsIsolation(utterance), workspace.dirtyFileCount > 0 {
            return Decision(
                action: .createWorkspace,
                workspaceID: workspace.id,
                confidence: .high,
                reason: "Asked for isolation and this worktree is dirty."
            )
        }

        let open = workspace.tabs.filter { !$0.isClosed }
        let focused = workspace.tabs.first(where: { $0.isFocused })
            ?? snapshot.focusedChatID.flatMap { id in workspace.tabs.first { $0.id == id } }

        if let tab = focused, !tab.isClosed {
            if !tabIsHealthy(tab) {
                return Decision(
                    action: .createChat,
                    workspaceID: workspace.id,
                    confidence: .high,
                    reason: "The focused tab is blocked or failed; open a new tab on the same worktree."
                )
            }
            return Decision(
                action: .sendExistingTab,
                workspaceID: workspace.id,
                chatID: tab.id,
                confidence: open.count == 1 ? .high : .medium,
                reason: "Continue on the focused tab of this worktree."
            )
        }

        if open.count == 1, let tab = open.first, tabIsHealthy(tab) {
            return Decision(
                action: .sendExistingTab,
                workspaceID: workspace.id,
                chatID: tab.id,
                confidence: .high,
                reason: "This worktree has a single healthy open tab."
            )
        }

        if open.count > 1 {
            return Decision(
                action: .clarify,
                workspaceID: workspace.id,
                confidence: .low,
                question: "On \(workspace.name), "
                    + open.map { "\"\($0.title)\"" }.joined(separator: ", or ")
                    + "?",
                reason: "Several open tabs and none uniquely named."
            )
        }

        return Decision(
            action: .createChat,
            workspaceID: workspace.id,
            confidence: .medium,
            reason: "No healthy open tab on this worktree."
        )
    }

    private static func focusedWorkspace(in snapshot: Snapshot) -> Workspace? {
        snapshot.workspaces.first { $0.id == snapshot.focusedWorkspaceID }
    }

    private static func tabIsHealthy(_ tab: Tab) -> Bool {
        if tab.isClosed || tab.pendingInput { return false }
        switch tab.status {
        case .failed, .interrupted, .awaitingInput: return false
        case .idle, .thinking, .requesting, .runningTool: return true
        }
    }

    private static func clarify(_ names: [String], reason: String) -> Decision {
        let listed = names.joined(separator: ", or ")
        return Decision(
            action: .clarify,
            confidence: .low,
            question: names.count == 2
                ? "\(names[0]), or \(names[1])?"
                : "Which of these: \(listed)?",
            reason: reason
        )
    }

    // MARK: - Language

    private static func wantsNewWorkspace(_ text: String) -> Bool {
        containsAny(text, [
            "new workspace", "new worktree", "own branch", "its own branch",
            "own worktree", "from that pr", "from the pr", "from that issue",
            "isolated", "isolation", "clean worktree",
        ])
    }

    private static func wantsNewTab(_ text: String) -> Bool {
        containsAny(text, [
            "new tab", "start over", "clean slate", "fresh tab",
            "don't use that thread", "dont use that thread",
            "new conversation",
        ])
    }

    private static func wantsIsolation(_ text: String) -> Bool {
        containsAny(text, ["isolation", "isolated", "don't mix", "dont mix", "separate worktree"])
    }

    private static func isAssistantOnly(_ text: String) -> Bool {
        containsAny(text, [
            "remember", "prefer", "preference", "mute", "don't remind",
            "dont remind", "what were we doing", "what was i doing",
            "what were we", "shipping saga",
        ])
    }

    private static func looksLikeRepoWork(_ text: String) -> Bool {
        containsAny(text, [
            "fix", "test", "commit", "push", "pull request", "branch",
            "implement", "refactor", "diff", "bug", "deploy", "review",
            "file", "build", "typecheck",
        ])
    }

    private static func mentions(_ name: String, in utterance: String) -> Bool {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        if utterance.contains(needle) { return true }
        // Any distinctive word is enough: "the auth thing" must hit both
        // "Auth API" and "Auth UI" so two candidates clarify instead of the
        // shorter title winning.
        let nameWords = words(in: needle).filter { $0.count >= 3 }
        guard !nameWords.isEmpty else { return false }
        let hay = Set(words(in: utterance))
        return nameWords.contains { hay.contains($0) }
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func uniqueByID(_ workspaces: [Workspace]) -> [Workspace] {
        var seen: Set<WorkspaceID> = []
        return workspaces.filter { seen.insert($0.id).inserted }
    }
}
