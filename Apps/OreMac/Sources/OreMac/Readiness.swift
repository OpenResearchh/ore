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
        git: GitAvailability?,
        hasGitIdentity: Bool?
    ) -> Readiness {
        Readiness(steps: [
            agentStep(harnesses: harnesses, hasProbed: hasProbedHarnesses),
            gitStep(git: git),
            projectStep(repositoryCount: repositoryCount),
            workspaceStep(workspaceCount: workspaceCount, repositoryCount: repositoryCount),
            gitIdentityStep(hasGitIdentity: hasGitIdentity),
            githubStep(github: github),
            shadowedHarnessStep(harnesses: harnesses, hasProbed: hasProbedHarnesses),
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
        // command away, so say which one. A CLI that will not launch is
        // excluded here even when it reports itself signed out, because
        // `claude auth login` fails the same way every other launch of it
        // does — the rung below is the one that can actually fix it.
        //
        // And a gated-off integration is excluded the same way `isReady` and
        // the two rungs around this one exclude it. `probeAll` marks
        // cursor-agent `isEnabled == false` on every machine that has not
        // opted into the experiment, so a user whose only agent is a
        // signed-out cursor-agent was being sent to `cursor-agent login` for
        // an integration ORE will not run whatever they do — where the
        // "install a coding agent" rung below would have got them working.
        if let installed = harnesses.first(where: {
            $0.isEnabled != false && $0.isLaunchable && $0.authState == .notAuthenticated
        }) {
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

        // Present but unrunnable — quarantined, not marked executable, a
        // broken symlink, a home on an unmounted volume. The probe reports it
        // as no usable agent, so it used to land on "Install a coding agent":
        // ORE telling somebody to install software it can see on their disk,
        // at a path it can name. Reinstalling is the fix that fits every one
        // of those causes, and the probe's `diagnostic` already says which one
        // it is, so hand both over instead of guessing on the user's behalf.
        //
        // Gated-off integrations are excluded the same way `isReady` excludes
        // them. `probeAll` marks cursor-agent `isEnabled == false` on every
        // machine that has not opted into it, so without this a quarantined
        // cursor-agent would outrank "install a coding agent" and hand the user
        // a reinstall that leaves ORE exactly as unable to run it as before.
        if let stuck = harnesses.first(where: {
            $0.isEnabled != false && $0.isUnlaunchable == true
        }) {
            let located = stuck.executablePath.map { "It's installed at \($0)" } ?? "It's installed"
            let explanation: String
            if let diagnostic = stuck.diagnostic, !diagnostic.isEmpty {
                // The probe's own sentence wins once it names the path. Every
                // producer writes "Found at <path> but could not be launched:
                // <reason>", so leading with ORE's version of the same thing
                // gave the user the path twice and the failure twice in one
                // three-sentence paragraph. ORE's sentence is what fills in
                // for a diagnostic that does not name the path, not a preamble
                // to one that does.
                if let path = stuck.executablePath, diagnostic.contains(path) {
                    explanation = diagnostic
                } else {
                    explanation = "\(located), but ORE can't launch it. \(diagnostic)"
                }
            } else {
                explanation = "\(located), but ORE can't launch it."
            }
            return ReadinessStep(
                id: "agent",
                title: "\(stuck.kind.displayName) won't run",
                detail: "\(explanation) Reinstalling replaces the copy that won't start.",
                status: .unmet,
                action: .copyCommand(HarnessSetup.installCommand(for: stuck.kind)),
                actionTitle: "Copy reinstall command",
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

    /// Rung 2, and blocking for the same reason as rung 1: ORE drives git
    /// directly for every worktree, diff and commit, so a Mac where git does
    /// not run cannot do anything the product is for.
    ///
    /// It was missing from the ladder entirely. The rung below asks whether
    /// git has a *name and email*, which presumes git runs — so a user with
    /// no working git was told to configure their identity, ran a `git config`
    /// that also failed, and only found the real problem when their first
    /// workspace died on a raw git error.
    ///
    /// Above `projectStep` because adding a repository is itself a git
    /// operation: sending somebody to pick a folder first only moves the
    /// failure later.
    private static func gitStep(git: GitAvailability?) -> ReadinessStep {
        guard let git else {
            return ReadinessStep(
                id: "git-available", title: "Checking git…",
                detail: "ORE runs git directly for worktrees, diffs and commits.",
                status: .unknown, action: .none, actionTitle: nil, isBlocking: true
            )
        }
        switch git {
        case .ready:
            return ReadinessStep(
                id: "git-available", title: "git is ready",
                detail: "ORE runs git directly for worktrees, diffs and commits.",
                status: .satisfied, action: .none, actionTitle: nil, isBlocking: true
            )
        case .commandLineToolsMissing:
            // The most common shape of this on a new Mac, and the one with a
            // one-command fix. Said plainly, because "git" being present but
            // non-functional is the opposite of what the user will assume.
            return ReadinessStep(
                id: "git-available",
                title: "Install Apple's command line tools",
                detail: "macOS ships a placeholder `git` until the developer tools are installed. ORE needs the real one.",
                status: .unmet,
                action: .copyCommand("xcode-select --install"),
                actionTitle: "Copy command",
                isBlocking: true
            )
        case .notFound:
            return ReadinessStep(
                id: "git-available",
                title: "Install git",
                detail: "ORE couldn't find git on your PATH. The command line tools include it.",
                status: .unmet,
                action: .copyCommand("xcode-select --install"),
                actionTitle: "Copy command",
                isBlocking: true
            )
        case .unknown:
            // Found, but would not answer. Saying "install git" to somebody
            // who has it would be the retraction this ladder exists to avoid,
            // so the rung goes quiet and lets the next one through.
            return ReadinessStep(
                id: "git-available", title: "git",
                detail: "", status: .unknown,
                action: .none, actionTitle: nil, isBlocking: false
            )
        }
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

    /// Last rung, and never blocking: when a CLI is installed twice from two
    /// channels the copy PATH picks usually works fine, so this must never
    /// stand between a new user and their first turn. It sits below even
    /// `github` because it is not a setup step at all — it is the explanation
    /// for "I updated it but ORE still shows the old version", which is a
    /// problem you can only have after you have been working for a while.
    ///
    /// Silent rather than `.satisfied` when nothing is shadowed, the same way
    /// `workspaceStep` stays quiet before there is a project: a checklist that
    /// hands out a tick for not having a pathological install teaches the user
    /// nothing, and the row would appear on every machine for no reason.
    ///
    /// Both paths get named because the fix is manual — ORE will not delete a
    /// binary for somebody — and the user cannot remove the right copy without
    /// knowing which one is currently winning.
    private static func shadowedHarnessStep(harnesses: [HarnessProbeResult], hasProbed: Bool) -> ReadinessStep {
        let quiet = ReadinessStep(
            id: "harness-shadowed", title: "Duplicate agent installs", detail: "",
            status: .unknown, action: .none, actionTitle: nil, isBlocking: false
        )
        // A gated-off integration is skipped for the same reason `isReady`
        // ignores one: ORE runs neither copy, so which of them PATH reaches is
        // not a problem the user has.
        guard hasProbed,
            let duplicated = harnesses.first(where: {
                $0.isEnabled != false && $0.executablePath != nil
                    && !($0.shadowedPaths ?? []).isEmpty
            }),
            let winner = duplicated.executablePath
        else { return quiet }

        let others = (duplicated.shadowedPaths ?? []).joined(separator: ", ")
        let executable = URL(fileURLWithPath: winner).lastPathComponent
        return ReadinessStep(
            id: "harness-shadowed",
            // Not "two copies": PATH can carry more than one loser, and a
            // headline that miscounts them is the kind of small wrongness that
            // makes a user stop trusting the rest of the card.
            title: "Duplicate \(duplicated.kind.displayName) installs",
            detail:
                "ORE runs \(winner). The same CLI is also installed at \(others), where PATH never "
                + "reaches it — so an update can land on the copy that isn't the one running. "
                + "Remove whichever you don't want.",
            status: .unmet,
            action: .copyCommand("which -a \(executable)"),
            actionTitle: "Copy command to list them",
            isBlocking: false
        )
    }
}

// MARK: - Probes

extension Readiness {
    /// Both git questions, answered together off the main actor.
    ///
    /// The implementations live in `OreGit` beside every other git launch in
    /// the product, so they resolve git through the probed login-shell PATH.
    /// The app's own copy used `/usr/bin/env git` and was the single launch
    /// that did not — on a Mac whose git comes from Homebrew or a version
    /// manager it answered about a different git than the one ORE commits
    /// with, and on a Mac with no developer tools it was what tripped the
    /// system install dialog.
    static func probeGit() async -> (GitAvailability, Bool?) {
        let availability = await GitAvailability.probe()
        // Only worth asking once git is known to run: `git config` on a
        // machine without git fails the same way an unset identity does, and
        // reporting that as "set your git identity" sends the user to fix the
        // wrong thing.
        guard availability.isReady else { return (availability, nil) }
        return (availability, await GitAvailability.probeIdentity())
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
        case .claudeCode: "claude auth login"
        case .codex: "codex login"
        case .cursorAgent: "cursor-agent login"
        }
    }

    /// Each vendor's installer that assumes nothing is already on the machine.
    ///
    /// These used to be `npm install -g …` for Claude Code and Codex, which is
    /// the one thing a first-run install command must not be: rung 1 of the
    /// ladder is the only truly fatal one, and a Mac that has never been set
    /// up for development has no Node. The user copied the command ORE handed
    /// them, pasted it into Terminal, and got `command not found: npm` — a
    /// dead end produced by ORE's own advice, at the exact moment it claims to
    /// be helping.
    ///
    /// All three vendors ship a shell installer that bootstraps itself, so the
    /// npm route is not worth keeping even as a fallback: it trades a
    /// guaranteed-working command for one that needs a prerequisite ORE would
    /// then also have to explain.
    ///
    /// Built from `HarnessKind.nativeInstallerURL` rather than spelled out
    /// again. The two lists had already drifted — this one piped Codex's
    /// script to `sh` while `HarnessCLIUpdater` and `HarnessRepair` both piped
    /// the same URL to `bash`, and wrote Cursor's curl flags in a different
    /// order — so a user could be handed three cosmetically different commands
    /// for one install depending on which screen they were looking at. One
    /// source of truth means a URL that changes cannot change in only two of
    /// the three places that state it.
    static func installCommand(for kind: HarnessKind) -> String {
        "curl -fsSL \(kind.nativeInstallerURL) | bash"
    }
}
