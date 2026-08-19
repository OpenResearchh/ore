import AppIntents
import Foundation
import OreProtocol

// ORE's App Intents: the assistant and the fleet, reachable from Siri,
// Shortcuts, and Spotlight. Each intent is a thin adapter over the same
// AppModel paths the UI uses — the action policy, audit log, and confirmation
// flow all still apply, so "ask ORE to push it" through Spotlight is exactly
// as safe as saying it out loud.

struct AskOREIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask ORE"
    static let description = IntentDescription(
        "Ask ORE's assistant about your projects, or tell it to do something across them.",
        categoryName: "Assistant"
    )
    /// The menu bar presence is enough; answering must not fling a window at
    /// the user mid-Shortcut.
    static let openAppWhenRun = false

    @Parameter(title: "Request", requestValueDialog: "What should ORE do?")
    var request: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask ORE to \(\.$request)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let model = AppModel.running() else { throw OreIntentError.notRunning }
        let reply = await model.askAssistant(request)
        return .result(value: reply, dialog: IntentDialog(stringLiteral: reply))
    }
}

struct WorkspaceStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Workspace Status"
    static let description = IntentDescription(
        "What your ORE agents are doing right now, and which of them need you.",
        categoryName: "Assistant"
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let model = AppModel.running() else { throw OreIntentError.notRunning }
        let summary = Self.summary(of: model.sortedWorkspaces)
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }

    /// One breath of status, composed locally — no model turn, so it is
    /// instant. Detail lives in the app; this answers "do I need to look?"
    static func summary(of workspaces: [WorkspaceSummary]) -> String {
        guard !workspaces.isEmpty else { return "No workspaces yet." }

        let needing = workspaces.filter(\.needsAttention)
        let working = workspaces.filter {
            switch $0.status {
            case .requesting, .thinking, .runningTool: !$0.needsAttention
            default: false
            }
        }

        var parts: [String] = []
        if !needing.isEmpty {
            let names = needing.prefix(3).map(\.name).joined(separator: ", ")
            let overflow = needing.count > 3 ? " and \(needing.count - 3) more" : ""
            parts.append("\(names)\(overflow) need\(needing.count == 1 ? "s" : "") you")
        }
        if !working.isEmpty {
            let names = working.prefix(3).map(\.name).joined(separator: ", ")
            parts.append("\(names) \(working.count == 1 ? "is" : "are") working")
        }
        if parts.isEmpty {
            return "All \(workspaces.count) workspace\(workspaces.count == 1 ? " is" : "s are") idle."
        }
        return parts.joined(separator: "; ") + "."
    }
}

struct CreateWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Create ORE Workspace"
    static let description = IntentDescription(
        "Create a new workspace — an isolated worktree with its own agent — optionally starting it on a task.",
        categoryName: "Workspaces"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Repository", description: "Repository name; optional when you have exactly one.")
    var repository: String?

    @Parameter(title: "Name", description: "Workspace name; omit for an auto-generated one.")
    var name: String?

    @Parameter(title: "First task", description: "A prompt to start the workspace's agent on.")
    var prompt: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Create a workspace in \(\.$repository)") {
            \.$name
            \.$prompt
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.running() else { throw OreIntentError.notRunning }
        let repositories = model.repositories
        guard !repositories.isEmpty else { throw OreIntentError.noRepositories }

        let path: String
        if let repository, !repository.isEmpty {
            guard let match = repositories.first(where: {
                ($0 as NSString).lastPathComponent
                    .caseInsensitiveCompare(repository) == .orderedSame || $0 == repository
            }) else {
                throw OreIntentError.unknownRepository(repository)
            }
            path = match
        } else if repositories.count == 1 {
            path = repositories[0]
        } else {
            throw OreIntentError.repositoryAmbiguous
        }

        model.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: path,
            name: name ?? "",
            initialPrompt: prompt?.isEmpty == false ? prompt : nil
        ))
        let started = prompt?.isEmpty == false ? " Its agent is starting on your task." : ""
        return .result(dialog: IntentDialog(
            stringLiteral: "Creating the workspace.\(started)"
        ))
    }
}

enum OreIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case noRepositories
    case unknownRepository(String)
    case repositoryAmbiguous

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning:
            "ORE isn't running yet — open it once and try again."
        case .noRepositories:
            "No repositories are set up in ORE yet."
        case .unknownRepository(let name):
            "ORE has no repository called \(name)."
        case .repositoryAmbiguous:
            "You have several repositories — say which one."
        }
    }
}

/// What Siri and Spotlight can be asked without setting anything up.
struct OreAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskOREIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Tell \(.applicationName) to",
            ],
            shortTitle: "Ask ORE",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: WorkspaceStatusIntent(),
            phrases: [
                "\(.applicationName) status",
                "What's happening in \(.applicationName)",
            ],
            shortTitle: "Status",
            systemImageName: "square.stack.3d.up"
        )
    }
}
