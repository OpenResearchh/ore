import Foundation
import OreGit
import OreProtocol
import Testing

@testable import OreMac

/// The priority ladder is the whole feature, so it gets tested rather than
/// eyeballed. Most of these assert an *ordering* decision, not a value.
@Suite("Onboarding surfaces the right next step")
struct ReadinessTests {
    private func probe(
        _ kind: HarnessKind,
        installed: Bool = true,
        auth: HarnessProbeResult.AuthState = .authenticated
    ) -> HarnessProbeResult {
        HarnessProbeResult(
            kind: kind,
            executablePath: installed ? "/usr/local/bin/\(kind.defaultExecutableName)" : nil,
            version: installed ? "1.0.0" : nil,
            authState: auth
        )
    }

    private func evaluate(
        harnesses: [HarnessProbeResult] = [],
        hasProbed: Bool = true,
        repositories: Int = 0,
        workspaces: Int = 0,
        github: GitHubClient.Status? = GitHubClient.Status(isInstalled: true, isAuthenticated: true),
        git: GitAvailability? = .ready(version: "git version 2.39.5"),
        gitIdentity: Bool? = true
    ) -> Readiness {
        Readiness.evaluate(
            harnesses: harnesses,
            hasProbedHarnesses: hasProbed,
            repositoryCount: repositories,
            workspaceCount: workspaces,
            github: github,
            git: git,
            hasGitIdentity: gitIdentity
        )
    }

    @Test("A fresh machine is told to install an agent first")
    func freshMachine() {
        let readiness = evaluate(harnesses: [probe(.claudeCode, installed: false, auth: .unknown)])
        #expect(readiness.nextStep?.id == "agent")
        #expect(readiness.nextStep?.action == .copyCommand("curl -fsSL https://claude.ai/install.sh | bash"))
        #expect(!readiness.isReady)
    }

    /// Rung 1 is the only fatal one, and a Mac that has never been set up for
    /// development has no Node — so an `npm install -g` here is a command that
    /// fails for exactly the user it exists to help. Asserted for every
    /// harness, because the ladder is not the only caller.
    @Test("No install command depends on a toolchain the user may not have")
    func installCommandsBootstrapThemselves() {
        for kind in [HarnessKind.claudeCode, .codex, .cursorAgent] {
            let command = HarnessSetup.installCommand(for: kind)
            #expect(!command.contains("npm"), "\(kind) install command requires npm: \(command)")
            #expect(!command.contains("brew"), "\(kind) install command requires Homebrew: \(command)")
            #expect(command.hasPrefix("curl "), "\(kind) install command is not self-bootstrapping: \(command)")
        }
    }

    /// The two ways of having no usable agent need different fixes, and
    /// collapsing them is what makes setup feel opaque.
    @Test("Installed-but-signed-out asks for sign-in, not install")
    func signedOutAgent() {
        let readiness = evaluate(harnesses: [probe(.codex, auth: .notAuthenticated)])
        #expect(readiness.nextStep?.id == "agent")
        #expect(readiness.nextStep?.title == "Sign in to Codex")
        #expect(readiness.nextStep?.action == .copyCommand("codex login"))
    }

    /// The bug this replaced: the old inline expression told every
    /// cursor-agent user to run `codex login`.
    @Test("Each harness gets its own sign-in command")
    func perHarnessCommands() {
        #expect(HarnessSetup.signInCommand(for: .claudeCode) == "claude auth login")
        #expect(HarnessSetup.signInCommand(for: .codex) == "codex login")
        #expect(HarnessSetup.signInCommand(for: .cursorAgent) == "cursor-agent login")

        let readiness = evaluate(harnesses: [probe(.cursorAgent, auth: .notAuthenticated)])
        #expect(readiness.nextStep?.action == .copyCommand("cursor-agent login"))
    }

    @Test("With an agent ready, the next step is adding a project")
    func agentReadyThenProject() {
        let readiness = evaluate(harnesses: [probe(.claudeCode)])
        #expect(readiness.nextStep?.id == "project")
        #expect(readiness.nextStep?.action == .addProject)
    }

    @Test("With a project added, the next step is the first workspace")
    func projectThenWorkspace() {
        let readiness = evaluate(harnesses: [probe(.claudeCode)], repositories: 1)
        #expect(readiness.nextStep?.id == "workspace")
    }

    /// Offering "start your first workspace" to somebody with no repository
    /// is a dead end, so that rung stays hidden until it can succeed.
    @Test("The workspace step stays hidden until there is a project")
    func workspaceStepWaitsForProject() {
        let readiness = evaluate(harnesses: [probe(.claudeCode)])
        let workspace = readiness.steps.first { $0.id == "workspace" }
        #expect(workspace?.status == .unknown)
        #expect(!readiness.relevantSteps.contains { $0.id == "workspace" })
    }

    /// A missing agent must never be buried under a notification prompt.
    @Test("Blocking steps outrank non-blocking ones regardless of order")
    func blockingWins() {
        let readiness = evaluate(
            harnesses: [probe(.claudeCode, installed: false, auth: .unknown)],
            github: GitHubClient.Status(isInstalled: false, isAuthenticated: false),
            gitIdentity: false
        )
        #expect(readiness.nextStep?.id == "agent")
    }

    /// Ready means "can work", not "perfect score" — the card has to get out
    /// of the way as soon as the user can actually do something.
    @Test("Ready once nothing blocks, even with optional steps open")
    func readyIgnoresOptionalSteps() {
        let readiness = evaluate(
            harnesses: [probe(.claudeCode)],
            repositories: 1,
            workspaces: 1,
            github: GitHubClient.Status(isInstalled: false, isAuthenticated: false),
            gitIdentity: false
        )
        #expect(readiness.isReady)
        // But the optional work is still offered.
        #expect(readiness.nextStep?.id == "git")
    }

    /// Telling somebody to install an agent they already have, because a
    /// probe has not returned yet, is worse than saying nothing.
    @Test("Nothing is claimed before the probe returns")
    func quietBeforeProbe() {
        let readiness = evaluate(harnesses: [], hasProbed: false)
        #expect(readiness.nextStep == nil, "must not prompt before we know what is installed")
        #expect(readiness.steps.first?.status == .unknown)
    }

    /// The rung that was missing. ORE drives git directly for every worktree,
    /// diff and commit, so this is blocking — and it has to outrank "add a
    /// project", because adding one is itself a git operation.
    @Test("A Mac with only the developer-tools stub is blocked on git, not on a project")
    func commandLineToolsMissingBlocksFirst() {
        let readiness = evaluate(
            harnesses: [probe(.claudeCode)],
            git: .commandLineToolsMissing
        )
        #expect(readiness.nextStep?.id == "git-available")
        #expect(readiness.nextStep?.action == .copyCommand("xcode-select --install"))
        #expect(!readiness.isReady)
    }

    @Test("No git on PATH is blocking too")
    func gitNotFoundBlocks() {
        let readiness = evaluate(harnesses: [probe(.claudeCode)], git: .notFound)
        #expect(readiness.nextStep?.id == "git-available")
        #expect(!readiness.isReady)
    }

    /// Same rule as rung 1: an answer we do not have yet is not an answer to
    /// act on. The ladder stays quiet rather than retracting itself a moment
    /// later.
    @Test("Nothing is claimed about git before its probe returns")
    func quietBeforeGitProbe() {
        let readiness = evaluate(harnesses: [probe(.claudeCode)], git: nil)
        #expect(readiness.nextStep == nil)
        #expect(!readiness.relevantSteps.contains { $0.id == "git-available" })
    }

    /// git found but refusing to answer is not evidence that it is missing,
    /// and "install git" to somebody who has it is exactly the retraction the
    /// ladder is built to avoid. It goes quiet and lets the next rung through.
    @Test("An unreadable git never tells the user to install one")
    func unknownGitDoesNotAccuse() {
        let readiness = evaluate(harnesses: [probe(.claudeCode)], git: .unknown)
        #expect(readiness.nextStep?.id == "project")
        #expect(!readiness.relevantSteps.contains { $0.id == "git-available" })
    }

    /// The identity rung presumes git runs. When it does not, the probe hands
    /// back nil and this rung must stay silent rather than send the user to
    /// fix the wrong thing.
    @Test("An unknown identity keeps the identity rung silent")
    func unknownIdentityIsSilent() {
        let readiness = evaluate(
            harnesses: [probe(.claudeCode)],
            git: .commandLineToolsMissing,
            gitIdentity: nil
        )
        let identity = readiness.steps.first { $0.id == "git" }
        #expect(identity?.status == .unknown)
        #expect(!readiness.relevantSteps.contains { $0.id == "git" })
    }

    /// The welcome screen's only content comes from `nextStep`, which is nil
    /// while a blocking rung is still `.unknown` — so before the probe answers
    /// there was nothing on screen at all, permanently if the probe hung.
    @Test("The pre-probe rung is renderable, so the welcome screen is never empty")
    func unknownBlockingStepIsRenderableBeforeProbe() throws {
        let readiness = evaluate(harnesses: [], hasProbed: false)
        #expect(readiness.nextStep == nil)

        let first = try #require(readiness.steps.first)
        #expect(first.status == .unknown)
        #expect(first.isBlocking)
        #expect(!first.title.isEmpty)

        #expect(NextStepCard.fallbackStep(for: readiness) == first)
    }

    @Test("A fully set-up machine has nothing to say")
    func everythingDone() {
        let readiness = evaluate(
            harnesses: [probe(.claudeCode)], repositories: 2, workspaces: 3
        )
        #expect(readiness.isReady)
        #expect(readiness.nextStep == nil)
        #expect(readiness.satisfiedCount == 6)
    }
}
