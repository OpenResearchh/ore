import Foundation
import Testing

@testable import OreProtocol

/// The command ORE hands a user whose CLI update failed on permissions.
///
/// It has to repair the install that is actually on the machine. The version
/// this replaced derived one line from the harness's Homebrew formula
/// regardless of how the CLI got there, so a root-owned npm install was
/// answered with `brew install claude-code` — which installs a second copy
/// from a different channel and leaves the broken one still first on `PATH`.
struct HarnessRepairTests {
    // MARK: - Homebrew

    @Test func aHomebrewInstallIsRepairedInItsOwnPrefix() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .codex,
            method: .homebrew,
            executablePath: "/opt/homebrew/bin/codex",
            brewPrefix: "/opt/homebrew"
        ))

        #expect(repair.needsRoot)
        #expect(repair.script.contains("/opt/homebrew/Cellar/codex"))
        #expect(repair.script.contains("brew upgrade 'codex'"))
        // Not the whole prefix: it holds every other package the user has.
        #expect(!repair.script.contains("chown -R \"$(whoami)\" '/opt/homebrew'"))
        #expect(!repair.script.contains("npm"))
    }

    /// A path under a Homebrew prefix on a machine where `brew` is gone —
    /// a migrated Mac, or an Intel prefix on Apple Silicon. Telling that user
    /// to run `brew upgrade` is telling them to run a command they do not have.
    @Test func aHomebrewPathWithoutHomebrewFallsBackToSomethingRunnable() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .codex,
            method: .homebrew,
            executablePath: "/usr/local/bin/codex",
            brewPrefix: nil
        ))

        #expect(!repair.script.contains("brew upgrade"))
        #expect(repair.script.contains("npm install -g '@openai/codex'@latest"))
        #expect(!repair.needsRoot, "the fallback installs under the user's own account")
    }

    // MARK: - npm

    @Test func anNpmInstallIsRepairedNarrowlyAtItsOwnPrefix() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .claudeCode,
            method: .npm,
            executablePath: "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js",
            npmPrefix: "/usr/local"
        ))

        #expect(repair.needsRoot)
        #expect(repair.script.contains(
            "'/usr/local'/lib/node_modules/@anthropic-ai/claude-code"
        ))
        // The launcher too: the package directory alone leaves the symlink
        // root-owned and the next update fails the same way.
        #expect(repair.script.contains("'/usr/local'/bin/claude"))
        // And not every other global tool the user has installed.
        #expect(!repair.script.contains("chown -R \"$(whoami)\" '/usr/local'/lib/node_modules "))
        #expect(repair.script.contains("npm install -g '@anthropic-ai/claude-code'@latest"))
    }

    /// npm's prefix depends on the node manager, so where it was not asked,
    /// the command asks at paste time rather than guessing a literal path
    /// into a `sudo chown`.
    @Test func anUnknownNpmPrefixIsResolvedByTheShellNotGuessed() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .codex, method: .npm, executablePath: "/usr/local/bin/codex"
        ))

        #expect(repair.script.contains("$(npm config get prefix)"))
        #expect(!repair.script.contains("'/usr/local'"))
    }

    // MARK: - Native installs

    @Test func aNativeInstallIsRepairedWhereItLives() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .claudeCode,
            method: .nativeUserBin,
            executablePath: "/Users/me/.local/bin/claude"
        ))

        #expect(repair.needsRoot, "a sudo-installed file in your own bin needs root to take back")
        #expect(repair.script.contains("chown -R \"$(whoami)\" '/Users/me/.local/bin'"))
        #expect(repair.script.contains("'/Users/me/.local/bin/claude' update"))
        #expect(!repair.script.contains("brew"))
        #expect(!repair.script.contains("npm"))
        #expect(repair.reason.contains("/Users/me/.local/bin/claude"))
    }

    @Test func aSelfUpdatingInstallRepairsItsOwnDirectory() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .codex, method: .selfUpdate, executablePath: "/opt/tools/bin/codex"
        ))

        #expect(repair.script.contains("'/opt/tools/bin'"))
        #expect(repair.script.contains("'/opt/tools/bin/codex' update"))
    }

    // MARK: - Unknown installs

    /// With no idea what is on disk, the advice must not run anything as
    /// root: a privileged command aimed at a directory we guessed is the one
    /// mistake here with consequences.
    @Test func anUnclassifiedInstallIsRepairedWithoutRoot() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .claudeCode, method: .unknown, executablePath: nil
        ))

        #expect(!repair.needsRoot)
        #expect(!repair.script.contains("sudo"))
        #expect(repair.script.contains("npm config set prefix ~/.npm-global"))
    }

    /// The old copy is still on `PATH`, usually earlier, so a repair that
    /// installs a working binary somewhere the shell will not look has fixed
    /// nothing the user can see.
    @Test func aUserPrefixRepairAlsoPutsItselfOnThePath() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .codex, method: .unknown, executablePath: nil
        ))

        #expect(repair.script.contains("$HOME/.npm-global/bin:$PATH"))
    }

    @Test func cursorIsRepairedThroughItsOwnInstaller() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .cursorAgent, method: .unknown, executablePath: nil
        ))

        #expect(repair.script.contains("https://cursor.com/install"))
        #expect(!repair.needsRoot)
    }

    // MARK: - Every repair

    /// A shell remembers where it found a command. Without clearing that, the
    /// user runs the fix, runs the CLI, gets the old binary, and concludes the
    /// fix did nothing.
    @Test func everyRepairEndsByProvingItWorked() throws {
        let cases: [(HarnessKind, HarnessInstallMethod, String?)] = [
            (.codex, .homebrew, "/opt/homebrew/bin/codex"),
            (.claudeCode, .npm, "/usr/local/bin/claude"),
            (.claudeCode, .nativeUserBin, "/Users/me/.local/bin/claude"),
            (.codex, .unknown, nil),
            (.cursorAgent, .unknown, nil),
        ]
        for (kind, method, path) in cases {
            let repair = try #require(HarnessRepair.forPermissionFailure(
                kind: kind, method: method, executablePath: path, brewPrefix: "/opt/homebrew"
            ))
            #expect(repair.commands.contains("hash -r"), "\(kind) \(method)")
            #expect(
                repair.commands.last?.contains(kind.defaultExecutableName) == true,
                "\(kind) \(method) should end by running the CLI"
            )
        }
    }

    @Test func aPathWithAQuoteInItIsStillQuotedSafely() throws {
        let repair = try #require(HarnessRepair.forPermissionFailure(
            kind: .codex, method: .selfUpdate, executablePath: "/Users/o'brien/bin/codex"
        ))

        #expect(repair.script.contains("'/Users/o'\\''brien/bin'"))
    }
}
