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
        gitIdentity: Bool? = true
    ) -> Readiness {
        Readiness.evaluate(
            harnesses: harnesses,
            hasProbedHarnesses: hasProbed,
            repositoryCount: repositories,
            workspaceCount: workspaces,
            github: github,
            hasGitIdentity: gitIdentity
        )
    }

    @Test("A fresh machine is told to install an agent first")
    func freshMachine() {
        let readiness = evaluate(harnesses: [probe(.claudeCode, installed: false, auth: .unknown)])
        #expect(readiness.nextStep?.id == "agent")
        #expect(readiness.nextStep?.action == .copyCommand("npm install -g @anthropic-ai/claude-code"))
        #expect(!readiness.isReady)
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

    @Test("A fully set-up machine has nothing to say")
    func everythingDone() {
        let readiness = evaluate(
            harnesses: [probe(.claudeCode)], repositories: 2, workspaces: 3
        )
        #expect(readiness.isReady)
        #expect(readiness.nextStep == nil)
        #expect(readiness.satisfiedCount == 5)
    }
}
