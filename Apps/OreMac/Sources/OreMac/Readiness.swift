import Foundation
import OreGit
import OreProtocol

/// What a new user still needs before ORE can do anything useful for them.
///
/// Every signal here already existed — harness probes, `gh` status, the
/// repository list — but they were scattered across the welcome screen,
/// Settings → Agents, a banner or two, and a `doctor` command you could only
/// reach from a terminal. A user who was stuck had to know where to look.
///
/// This aggregates them and, more importantly, *orders* them. The UI shows
/// one thing at a time: the highest-priority unmet step. Six half-finished
/// setup tasks presented at once is the same problem as a settings screen
/// with ten controls — the user has to work out what matters. Ordering is the
/// feature.
///
/// Deliberately a pure value computed from inputs, with no reference to
/// `AppModel`, so the whole priority ladder is unit-testable without a window
/// or a running core.
struct ReadinessStep: Identifiable, Equatable {
    enum Status: Equatable {
        /// Nothing to do.
        case satisfied
        /// Blocking or worth prompting for.
        case unmet
        /// Not probed yet. Deliberately distinct from `unmet`: telling
        /// somebody to install an agent they already have, because the probe
        /// has not returned, is worse than staying quiet for a second.
        case unknown
    }

    /// What the user should do about it. The view turns this into a button;
    /// keeping it as data rather than a closure is what lets the ladder be
    /// tested.
    enum Action: Equatable {
        case none
        /// Sign-in and install steps end in a terminal, so hand over the
        /// exact command rather than describing it.
        case copyCommand(String)
        case openSettings(String)
        case addProject
        case newWorkspace
        case openURL(String)
    }

    let id: String
    let title: String
    /// Why this matters, in one sentence, in the user's terms.
    let detail: String
    let status: Status
    let action: Action
    let actionTitle: String?
    /// Blocking steps make ORE unusable. Non-blocking ones are worth
    /// surfacing once the user is working, but must never stand between them
    /// and their first turn.
    let isBlocking: Bool
}

struct Readiness: Equatable {
    /// In priority order, most important first.
    let steps: [ReadinessStep]

    /// The one thing to show.
    ///
    /// Blocking steps are walked in order first, so a missing agent is never
    /// buried under "connect GitHub". Crucially, a blocking step that is
    /// still `.unknown` *stops* the walk rather than being skipped: while the
    /// harness probe is in flight we do not yet know whether the user can run
    /// an agent at all, and advising them to add a project in the meantime is
    /// advice we might immediately have to retract. Half a second of silence
    /// beats a card that changes its mind on launch.
    var nextStep: ReadinessStep? {
        for step in steps where step.isBlocking {
            switch step.status {
            case .unknown: return nil
            case .unmet: return step
            case .satisfied: continue
            }
        }
        return steps.first { $0.status == .unmet }
    }

    var relevantSteps: [ReadinessStep] { steps.filter { $0.status != .unknown } }
    var satisfiedCount: Int { steps.count { $0.status == .satisfied } }

    /// True once nothing is blocking. Non-blocking steps may still be open —
    /// the card should get out of the way as soon as the user can work, not
    /// wait for a perfect score.
    var isReady: Bool { !steps.contains { $0.isBlocking && $0.status == .unmet } }
}

// MARK: - Evaluation

extension Readiness {
    /// Builds the ladder. Inputs are plain values so tests can drive every
    /// rung without a core, a network, or a real machine.
    static func evaluate(
        harnesses: [HarnessProbeResult],
        hasProbedHarnesses: Bool,
        repositoryCount: Int,
        workspaceCount: Int,
        github: GitHubClient.Status?,
        hasGitIdentity: Bool?
    ) -> Readiness {
        Readiness(steps: [
            agentStep(harnesses: harnesses, hasProbed: hasProbedHarnesses),
            projectStep(repositoryCount: repositoryCount),
            workspaceStep(workspaceCount: workspaceCount, repositoryCount: repositoryCount),
            gitIdentityStep(hasGitIdentity: hasGitIdentity),
            githubStep(github: github),
        ])
    }

    /// Rung 1, and the only one that is truly fatal: with no agent there is
    /// no product.
    ///
    /// "Installed but not signed in" and "not installed at all" are split
    /// deliberately — they are the two most common ways to be stuck and they
    /// have completely different fixes. Collapsing them into "no agent
    /// available" is what makes setup feel opaque.
    private static func agentStep(harnesses: [HarnessProbeResult], hasProbed: Bool) -> ReadinessStep {
        if !hasProbed {
            return ReadinessStep(
                id: "agent", title: "Checking for coding agents…",
                detail: "Looking for Claude Code, Codex and cursor-agent on your PATH.",
                status: .unknown, action: .none, actionTitle: nil, isBlocking: true
            )
        }

        if let ready = harnesses.first(where: \.isReady) {
            return ReadinessStep(
                id: "agent", title: "\(ready.kind.displayName) is ready",
                detail: "ORE runs the agent CLIs you already have, on your existing subscription.",
                status: .satisfied, action: .none, actionTitle: nil, isBlocking: true
            )
        }

        // Installed but signed out is the better problem to have: it is one
        // command away, so say which one.
        if let installed = harnesses.first(where: { $0.isInstalled && $0.authState == .notAuthenticated }) {
            return ReadinessStep(
                id: "agent",
                title: "Sign in to \(installed.kind.displayName)",
                detail: "It's installed but not signed in. ORE uses your own subscription — it never handles API keys.",
                status: .unmet,
                action: .copyCommand(HarnessSetup.signInCommand(for: installed.kind)),
                actionTitle: "Copy sign-in command",
                isBlocking: true
            )
        }

        return ReadinessStep(
            id: "agent",
            title: "Install a coding agent",
            detail: "ORE drives Claude Code, Codex or cursor-agent. Install one and sign in with the plan you already pay for.",
            status: .unmet,
            action: .copyCommand(HarnessSetup.installCommand(for: .claudeCode)),
            actionTitle: "Copy install command",
            isBlocking: true
        )
    }

    private static func projectStep(repositoryCount: Int) -> ReadinessStep {
        ReadinessStep(
            id: "project",
            title: repositoryCount > 0 ? "Project added" : "Add a project",
            detail: "Point ORE at a git repository — one you already have, or clone one from GitHub.",
            status: repositoryCount > 0 ? .satisfied : .unmet,
            action: .addProject,
            actionTitle: "Add project…",
            isBlocking: true
        )
    }

    /// The activation moment. Only offered once there is something to work
    /// on — prompting somebody to start a workspace before they have added a
    /// repository is a dead end.
    private static func workspaceStep(workspaceCount: Int, repositoryCount: Int) -> ReadinessStep {
        let status: ReadinessStep.Status =
            workspaceCount > 0 ? .satisfied : (repositoryCount > 0 ? .unmet : .unknown)
        return ReadinessStep(
            id: "workspace",
            title: workspaceCount > 0 ? "First workspace created" : "Start your first workspace",
            detail: "Each workspace runs an agent in its own git worktree, so several can work at once without colliding.",
            status: status,
            action: .newWorkspace,
            actionTitle: "New workspace",
            isBlocking: false
        )
    }

    /// Not blocking: an agent can happily edit files without it. It only
    /// bites at commit time, which is far enough from first launch that
    /// putting it above "start a workspace" would be wrong.
    private static func gitIdentityStep(hasGitIdentity: Bool?) -> ReadinessStep {
        guard let hasGitIdentity else {
            return ReadinessStep(
                id: "git", title: "Checking git…", detail: "",
                status: .unknown, action: .none, actionTitle: nil, isBlocking: false
            )
        }
        return ReadinessStep(
            id: "git",
            title: hasGitIdentity ? "Git identity configured" : "Set your git identity",
            detail: "Commits ORE makes on your behalf need a name and email.",
            status: hasGitIdentity ? .satisfied : .unmet,
            action: .copyCommand(
                #"git config --global user.name "Your Name" && git config --global user.email "you@example.com""#
            ),
            actionTitle: "Copy command",
            isBlocking: false
        )
    }

    /// Last, and never blocking: `gh` is only needed to open pull requests,
    /// which is the end of the workflow, not the start.
    private static func githubStep(github: GitHubClient.Status?) -> ReadinessStep {
        guard let github else {
            return ReadinessStep(
                id: "github", title: "Checking GitHub…", detail: "",
                status: .unknown, action: .none, actionTitle: nil, isBlocking: false
            )
        }
        if github.isInstalled && github.isAuthenticated {
            return ReadinessStep(
                id: "github", title: "GitHub connected",
                detail: "ORE can open and merge pull requests for you.",
                status: .satisfied, action: .none, actionTitle: nil, isBlocking: false
            )
        }
        if github.isInstalled {
            return ReadinessStep(
                id: "github", title: "Connect GitHub",
                detail: "Needed to open pull requests from ORE. Everything else works without it.",
                status: .unmet, action: .copyCommand("gh auth login"),
                actionTitle: "Copy command", isBlocking: false
            )
        }
        return ReadinessStep(
            id: "github", title: "Install the GitHub CLI",
            detail: "Needed to open pull requests from ORE. Everything else works without it.",
            status: .unmet, action: .copyCommand("brew install gh"),
            actionTitle: "Copy command", isBlocking: false
        )
    }
}

// MARK: - Probes

extension Readiness {
    /// Whether git has a name and an email to commit with.
    ///
    /// Checked without `--global` on purpose: a repository-local identity,
    /// or one supplied by an includeIf in the user's gitconfig, is just as
    /// valid, and telling somebody to set a global identity they have
    /// deliberately avoided setting would be wrong.
    static func probeGitIdentity() async -> Bool {
        // Sequential rather than `async let`: `&&` takes an autoclosure, so
        // an `async let` cannot be read across it, and two local `git config`
        // reads are not worth the concurrency anyway.
        let name = await gitConfig("user.name")
        let email = await gitConfig("user.email")
        return !(name ?? "").isEmpty && !(email ?? "").isEmpty
    }

    private static func gitConfig(_ key: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["git", "config", "--get", key]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let value = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: value.isEmpty ? nil : value)
            }
        }
    }
}

// MARK: - Per-harness setup commands

/// The sign-in and install commands, in one place.
///
/// These used to be inline in the welcome screen as
/// `kind == .claudeCode ? "claude /login" : "codex login"`, which quietly
/// told every cursor-agent user to run `codex login`. A `switch` over the
/// enum means adding a harness cannot silently inherit another one's
/// instructions.
enum HarnessSetup {
    static func signInCommand(for kind: HarnessKind) -> String {
        switch kind {
        case .claudeCode: "claude /login"
        case .codex: "codex login"
        case .cursorAgent: "cursor-agent login"
        }
    }

    static func installCommand(for kind: HarnessKind) -> String {
        switch kind {
        case .claudeCode: "npm install -g @anthropic-ai/claude-code"
        case .codex: "npm install -g @openai/codex"
        case .cursorAgent: "curl https://cursor.com/install -fsS | bash"
        }
    }
}
