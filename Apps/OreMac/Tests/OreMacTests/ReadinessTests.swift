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
        auth: HarnessProbeResult.AuthState = .authenticated,
        diagnostic: String? = nil,
        unlaunchable: Bool? = nil,
        shadowed: [String]? = nil,
        enabled: Bool? = nil
    ) -> HarnessProbeResult {
        HarnessProbeResult(
            kind: kind,
            executablePath: installed ? "/usr/local/bin/\(kind.defaultExecutableName)" : nil,
            version: installed ? "1.0.0" : nil,
            authState: auth,
            isEnabled: enabled,
            diagnostic: diagnostic,
            isUnlaunchable: unlaunchable,
            shadowedPaths: shadowed
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

    /// One source of truth for each vendor's installer. These were written
    /// out twice — here and as `HarnessKind.nativeInstallerURL` in OreProtocol
    /// — and had already drifted, so the same install could be handed to a
    /// user in three cosmetically different forms depending on the screen.
    @Test("Install commands are built from the one list of installer URLs")
    func installCommandsUseTheSharedInstallerURLs() {
        for kind in [HarnessKind.claudeCode, .codex, .cursorAgent] {
            #expect(
                HarnessSetup.installCommand(for: kind).contains(kind.nativeInstallerURL),
                "\(kind) install command does not use its installer URL"
            )
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

    /// The bug: a quarantined or non-executable CLI probes as "no usable
    /// agent", so the ladder told the user to install something ORE could see
    /// on their disk. The fix has to name the path and offer a reinstall.
    @Test("A CLI that won't launch is never described as missing")
    func unlaunchableAgentIsNotCalledMissing() throws {
        let readiness = evaluate(harnesses: [
            probe(
                .claudeCode,
                auth: .unknown,
                diagnostic: "macOS blocked it: “claude” cannot be opened because it is from an unidentified developer.",
                unlaunchable: true
            )
        ])

        let step = try #require(readiness.nextStep)
        #expect(step.id == "agent")
        #expect(step.title != "Install a coding agent")
        #expect(step.detail.contains("/usr/local/bin/claude"), "the path ORE can name must be named")
        #expect(step.detail.contains("unidentified developer"), "the probe's diagnostic carries the reason")
        // Reinstalling is the one action that fixes every cause of this.
        #expect(step.action == .copyCommand(HarnessSetup.installCommand(for: .claudeCode)))
        #expect(!readiness.isReady)
    }

    /// The shape every real producer writes: `HarnessDiagnostic.unlaunchable`
    /// says "Found at <path> but could not be launched: <reason>". The card
    /// used to open with its own version of that same sentence, so the user
    /// read the path twice and the failure twice.
    @Test("The card does not restate a diagnostic that already names the path")
    func unlaunchableDetailDoesNotRepeatItself() throws {
        let readiness = evaluate(harnesses: [
            probe(
                .claudeCode,
                auth: .notAuthenticated,
                diagnostic: "Found at /usr/local/bin/claude but could not be launched: "
                    + "dyld: Library not loaded: libnode.dylib",
                unlaunchable: true
            )
        ])

        let step = try #require(readiness.nextStep)
        let occurrences = step.detail.components(separatedBy: "/usr/local/bin/claude").count - 1
        #expect(occurrences == 1, "the path is named once: \(step.detail)")
        #expect(step.detail.contains("libnode"), "the CLI's own reason survives")
        #expect(step.detail.hasSuffix("Reinstalling replaces the copy that won't start."))
    }

    /// Sign-in is normally the better problem to have, but not for a binary
    /// that cannot start: `codex login` would fail the same way every other
    /// launch of it does.
    @Test("An unlaunchable CLI is never handed a sign-in command")
    func unlaunchableAgentSkipsSignIn() {
        let readiness = evaluate(harnesses: [
            probe(.codex, auth: .notAuthenticated, unlaunchable: true)
        ])
        #expect(readiness.nextStep?.action != .copyCommand("codex login"))
        #expect(readiness.nextStep?.action == .copyCommand(HarnessSetup.installCommand(for: .codex)))
    }

    /// A working agent one command away beats a broken one that needs a
    /// reinstall, so the launchable harness still wins the rung.
    @Test("A signed-out but runnable agent outranks an unlaunchable one")
    func runnableSignedOutWinsOverUnlaunchable() {
        let readiness = evaluate(harnesses: [
            probe(.claudeCode, auth: .unknown, unlaunchable: true),
            probe(.codex, auth: .notAuthenticated),
        ])
        #expect(readiness.nextStep?.title == "Sign in to Codex")
    }

    /// The winning copy usually works, so this warning must never be the
    /// thing standing between a new user and their first turn.
    @Test("A shadowed second copy never outranks getting started")
    func shadowedCopyIsNotBlocking() throws {
        let readiness = evaluate(harnesses: [
            probe(.claudeCode, shadowed: ["/opt/homebrew/bin/claude"])
        ])
        #expect(readiness.nextStep?.id == "project", "setup still comes first")

        let shadowed = try #require(readiness.steps.first { $0.id == "harness-shadowed" })
        #expect(!shadowed.isBlocking)
        #expect(shadowed.status == .unmet)
        #expect(readiness.isReady == false, "blocked by the project rung, not by this one")
    }

    /// Named paths are the whole point: the user cannot remove the right copy
    /// without knowing which one PATH is currently reaching.
    @Test("The shadowed-copy warning names both installs")
    func shadowedCopyNamesBothPaths() throws {
        let readiness = evaluate(
            harnesses: [probe(.claudeCode, shadowed: ["/opt/homebrew/bin/claude"])],
            repositories: 1,
            workspaces: 1
        )
        // Only reached once nothing else is open — and it never blocks.
        #expect(readiness.isReady)
        let step = try #require(readiness.nextStep)
        #expect(step.id == "harness-shadowed")
        #expect(step.detail.contains("/usr/local/bin/claude"))
        #expect(step.detail.contains("/opt/homebrew/bin/claude"))
    }

    /// `HarnessRegistry.probeAll` marks cursor-agent disabled on every machine
    /// that has not opted into it, so this is the ordinary shape of the probe,
    /// not an exotic one. Reinstalling a CLI ORE still refuses to run leaves
    /// the user exactly as stuck, with a fresh copy of the same binary.
    @Test("A gated-off integration that won't launch is not offered a reinstall")
    func disabledUnlaunchableAgentFallsBackToInstall() {
        let readiness = evaluate(harnesses: [
            probe(.cursorAgent, auth: .notAuthenticated, unlaunchable: true, enabled: false)
        ])
        #expect(readiness.nextStep?.title == "Install a coding agent")
        #expect(
            readiness.nextStep?.action == .copyCommand(HarnessSetup.installCommand(for: .claudeCode))
        )
    }

    /// The last agent-rung predicate that disagreed with `isReady`. Signing
    /// into an integration ORE refuses to run leaves the user exactly where
    /// they started, while the install rung below would have got them working.
    @Test("A signed-out gated-off integration is not offered a sign-in")
    func disabledSignedOutAgentFallsBackToInstall() {
        let readiness = evaluate(harnesses: [
            probe(.cursorAgent, auth: .notAuthenticated, enabled: false)
        ])
        #expect(readiness.nextStep?.title == "Install a coding agent")
        #expect(readiness.nextStep?.action != .copyCommand("cursor-agent login"))
    }

    /// Same rule for the duplicate-install warning: ORE runs neither copy of a
    /// gated-off CLI, so which one PATH reaches is not a problem the user has.
    @Test("Duplicate copies of a gated-off integration stay unmentioned")
    func disabledHarnessKeepsShadowRungSilent() {
        let readiness = evaluate(
            harnesses: [
                probe(.claudeCode),
                probe(.cursorAgent, shadowed: ["/opt/homebrew/bin/agent"], enabled: false),
            ],
            repositories: 1,
            workspaces: 1
        )
        let shadowed = readiness.steps.first { $0.id == "harness-shadowed" }
        #expect(shadowed?.status == .unknown)
        #expect(readiness.nextStep == nil)
    }

    /// Nothing shadowed is not an achievement, so the rung stays out of the
    /// checklist rather than handing out a tick on every machine.
    @Test("With one copy installed the shadow rung says nothing at all")
    func singleCopyKeepsShadowRungSilent() {
        let readiness = evaluate(
            harnesses: [probe(.claudeCode)], repositories: 1, workspaces: 1
        )
        let shadowed = readiness.steps.first { $0.id == "harness-shadowed" }
        #expect(shadowed?.status == .unknown)
        #expect(!readiness.relevantSteps.contains { $0.id == "harness-shadowed" })
        #expect(readiness.nextStep == nil)
    }

    /// Same rule as every other rung: an answer we do not have yet is not an
    /// answer to act on.
    @Test("Nothing is claimed about duplicate installs before the probe returns")
    func quietBeforeProbeForShadowedCopies() {
        let readiness = evaluate(harnesses: [], hasProbed: false)
        #expect(!readiness.relevantSteps.contains { $0.id == "harness-shadowed" })
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
