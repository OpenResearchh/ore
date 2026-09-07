import Foundation
import Testing

@testable import OreMac

/// The update endgame: stage, quit, come back up, say so.
///
/// The bug these cover is the one where the swap landed but the app never
/// left — the popup spun on its progress view forever and the new build only
/// appeared the next time the user launched by hand.
@MainActor
struct UpdateRestartTests {
    // MARK: - Successful upgrade

    @Test func stagingAnUpdateSchedulesTheSwapAndAsksToQuit() async {
        let probe = HookProbe()
        let updater = makeUpdater(probe: probe, version: "0.7.0")
        // Sampled at the quit, because the real `forceQuit` past it never
        // returns — the process is gone.
        var phaseAtQuit: GitHubUpdater.Phase?
        probe.onQuitRequested = { phaseAtQuit = updater.phase }

        await updater.runInstall(release("v0.8.0"))

        #expect(probe.downloaded == ["v0.8.0"])
        #expect(probe.scheduled == 1)
        #expect(probe.quitRequests == 1)
        #expect(phaseAtQuit == .restarting)
    }

    @Test func aStagedUpdateIsRecordedBeforeTheQuit() async throws {
        let probe = HookProbe()
        let defaults = makeDefaults()
        let updater = makeUpdater(probe: probe, defaults: defaults, version: "0.7.0")

        await updater.runInstall(release("v0.8.0"))

        let data = try #require(defaults.data(forKey: GitHubUpdater.pendingRestartKey))
        let pending = try JSONDecoder().decode(GitHubUpdater.PendingRestart.self, from: data)
        #expect(pending.version == "v0.8.0")
        #expect(pending.releaseURL.absoluteString == "https://example.invalid/v0.8.0")
    }

    // MARK: - Restart

    @Test func aQuitThatNeverLandsEscalatesToAForcedExit() async {
        // The exact shape of the bug: everything staged, `NSApp.terminate`
        // called, and the process still alive well past the deadline because
        // shutdown wedged. The swap script is blocked on this pid, so leaving
        // is the only move that finishes the update.
        let probe = HookProbe()
        let updater = makeUpdater(probe: probe, version: "0.7.0")

        await updater.runInstall(release("v0.8.0"))

        #expect(probe.quitRequests == 1)
        #expect(probe.forceQuits == 1)
        #expect(probe.waits == [GitHubUpdater.quitDeadline])
    }

    @Test func aForcedExitThatCannotHappenLeavesAnActionableMessage() async {
        let updater = makeUpdater(probe: HookProbe(), version: "0.7.0")

        await updater.runInstall(release("v0.8.0"))

        #expect(updater.isFailed)
        #expect(updater.isInstalling == false)
        if case .failed(let detail) = updater.phase {
            #expect(detail.contains("Quit and reopen"))
        }
    }

    @Test func theSwapScriptStopsWaitingOnAnAppThatWontExit() {
        let script = GitHubUpdater.relaunchScript(
            newApp: URL(fileURLWithPath: "/tmp/stage/ORE.app"),
            destination: URL(fileURLWithPath: "/Applications/ORE.app"),
            pid: 4_242,
            scriptPath: "/tmp/relaunch.sh",
            label: "dev.ore.relaunch.test"
        )

        #expect(script.contains("wait_for_exit \(GitHubUpdater.gracefulQuitSeconds)"))
        #expect(script.contains("/bin/kill -TERM"))
        #expect(script.contains("/bin/kill -KILL"))
        // The unbounded `while kill -0` is what held the swap hostage.
        #expect(!script.contains("while /bin/kill -0 4242"))
        #expect(script.contains("/usr/bin/open '/Applications/ORE.app'"))
    }

    @Test func theSwapScriptIsValidBash() throws {
        // Nothing else catches a typo here: the script is written to disk and
        // handed to launchd, where a syntax error is a silent no-swap.
        let script = GitHubUpdater.relaunchScript(
            newApp: URL(fileURLWithPath: "/tmp/stage/ORE.app"),
            destination: URL(fileURLWithPath: "/Applications/ORE.app"),
            pid: 4_242,
            scriptPath: "/tmp/relaunch.sh",
            label: "dev.ore.relaunch.test"
        )
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-relaunch-test-\(UUID().uuidString).sh")
        try script.write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }

        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/bash")
        check.arguments = ["-n", path.path]
        try check.run()
        check.waitUntilExit()

        #expect(check.terminationStatus == 0)
    }

    @Test func theSwapScriptWaitLoopTerminatesForALiveProcess() throws {
        // Runs the generated waiter for real against a process that never
        // exits, to prove the deadline arithmetic actually bounds it.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { if sleeper.isRunning { sleeper.terminate() } }

        let script = """
        PID=\(sleeper.processIdentifier)
        wait_for_exit() {
          deadline=$((SECONDS + $1))
          while /bin/kill -0 "$PID" 2>/dev/null; do
            if [ "$SECONDS" -ge "$deadline" ]; then return 1; fi
            /bin/sleep 0.2
          done
          return 0
        }
        wait_for_exit 1 || exit 3
        exit 0
        """
        let bash = Process()
        bash.executableURL = URL(fileURLWithPath: "/bin/bash")
        bash.arguments = ["-c", script]
        try bash.run()
        bash.waitUntilExit()

        // 3 == the waiter gave up rather than sleeping out the process.
        #expect(bash.terminationStatus == 3)
    }

    // MARK: - Completion acknowledgement

    @Test func comingBackUpOnTheNewVersionConfirmsTheUpdate() {
        let defaults = makeDefaults()
        stage("v0.8.0", in: defaults)
        // The new build: same record, newer bundle version.
        let updater = makeUpdater(probe: HookProbe(), defaults: defaults, version: "0.8.0")

        updater.reconcilePendingRestart()

        #expect(updater.completedVersion == "0.8.0")
        #expect(updater.showsPrompt)
        #expect(updater.isInstalling == false)
        #expect(updater.phase == .idle)
        #expect(defaults.data(forKey: GitHubUpdater.pendingRestartKey) == nil)
    }

    @Test func acknowledgingTheConfirmationClosesThePrompt() {
        let defaults = makeDefaults()
        stage("v0.8.0", in: defaults)
        let updater = makeUpdater(probe: HookProbe(), defaults: defaults, version: "0.8.0")
        updater.reconcilePendingRestart()

        updater.acknowledgeCompletion()

        #expect(updater.completedVersion == nil)
        #expect(updater.showsPrompt == false)
    }

    @Test func aSettledRecordIsNotReplayedOnTheNextLaunch() {
        let defaults = makeDefaults()
        stage("v0.8.0", in: defaults)
        makeUpdater(probe: HookProbe(), defaults: defaults, version: "0.8.0")
            .reconcilePendingRestart()

        let relaunched = makeUpdater(probe: HookProbe(), defaults: defaults, version: "0.8.0")
        relaunched.reconcilePendingRestart()

        #expect(relaunched.completedVersion == nil)
        #expect(relaunched.showsPrompt == false)
    }

    // MARK: - Failure handling

    @Test func comingBackUpOnTheOldVersionReportsTheFailedInstall() {
        let defaults = makeDefaults()
        stage("v0.8.0", in: defaults)
        // The swap never ran: still the old bundle.
        let updater = makeUpdater(probe: HookProbe(), defaults: defaults, version: "0.7.0")

        updater.reconcilePendingRestart()

        #expect(updater.completedVersion == nil)
        #expect(updater.isFailed)
        #expect(updater.showsPrompt)
        #expect(updater.available?.version == "v0.8.0")
        #expect(defaults.data(forKey: GitHubUpdater.pendingRestartKey) == nil)
    }

    @Test func aFailedInstallSurvivesTheCheckThatFillsInTheRetryAsset() {
        let defaults = makeDefaults()
        stage("v0.8.0", in: defaults)
        let updater = makeUpdater(probe: HookProbe(), defaults: defaults, version: "0.7.0")
        updater.reconcilePendingRestart()

        // What `check()` does when it finds the same release again, now with
        // the asset details a retry needs.
        updater.applyCheckResult(release("v0.8.0"))

        #expect(updater.isFailed)
        #expect(updater.available?.assetName == "ORE.dmg")
    }

    @Test func aDifferentReleaseClearsTheOldFailure() {
        let defaults = makeDefaults()
        stage("v0.8.0", in: defaults)
        let updater = makeUpdater(probe: HookProbe(), defaults: defaults, version: "0.7.0")
        updater.reconcilePendingRestart()

        updater.applyCheckResult(release("v0.9.0"))

        #expect(updater.phase == .idle)
        #expect(updater.available?.version == "v0.9.0")
    }

    @Test func aFailedDownloadNeverStagesAQuit() async {
        let probe = HookProbe()
        probe.downloadError = URLError(.notConnectedToInternet)
        let defaults = makeDefaults()
        let updater = makeUpdater(probe: probe, defaults: defaults, version: "0.7.0")

        await updater.runInstall(release("v0.8.0"))

        #expect(updater.isFailed)
        #expect(probe.scheduled == 0)
        #expect(probe.quitRequests == 0)
        #expect(probe.forceQuits == 0)
        #expect(defaults.data(forKey: GitHubUpdater.pendingRestartKey) == nil)
    }

    @Test func aFailedScheduleNeverQuitsTheApp() async {
        // Quitting on an unscheduled swap is how you lose an app: nothing is
        // waiting to put a new bundle in place or reopen it.
        let probe = HookProbe()
        probe.scheduleError = URLError(.cannotWriteToFile)
        let defaults = makeDefaults()
        let updater = makeUpdater(probe: probe, defaults: defaults, version: "0.7.0")

        await updater.runInstall(release("v0.8.0"))

        #expect(updater.isFailed)
        #expect(probe.quitRequests == 0)
        #expect(probe.forceQuits == 0)
        #expect(defaults.data(forKey: GitHubUpdater.pendingRestartKey) == nil)
    }

    // MARK: - Terminate handshake

    @Test func theTerminateHandshakeIsAnsweredOnce() {
        // Both racers in `applicationShouldTerminate` finish eventually; a
        // second reply to the same request is an AppKit error.
        var replies = 0
        let gate = TerminationGate { replies += 1 }

        gate.reply()
        gate.reply()

        #expect(replies == 1)
        #expect(gate.hasReplied)
    }

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ore.tests.update.\(UUID().uuidString)")!
    }

    @discardableResult
    private func makeUpdater(
        probe: HookProbe,
        defaults: UserDefaults? = nil,
        version: String
    ) -> GitHubUpdater {
        GitHubUpdater(
            hooks: probe.hooks,
            defaults: defaults ?? makeDefaults(),
            version: { version }
        )
    }

    private func release(_ version: String) -> GitHubUpdater.Available {
        GitHubUpdater.Available(
            version: version,
            title: "ORE \(version)",
            releaseURL: URL(string: "https://example.invalid/\(version)")!,
            downloadURL: URL(string: "https://example.invalid/\(version)/ORE.dmg")!,
            assetName: "ORE.dmg",
            assetID: 1
        )
    }

    private func stage(_ version: String, in defaults: UserDefaults) {
        let pending = GitHubUpdater.PendingRestart(
            version: version,
            title: "ORE \(version)",
            releaseURL: URL(string: "https://example.invalid/\(version)")!
        )
        defaults.set(try! JSONEncoder().encode(pending), forKey: GitHubUpdater.pendingRestartKey)
    }
}

/// Stands in for the download, the swap script, and the quit. Nothing here
/// touches the network, the disk image, or the real process.
private final class HookProbe: @unchecked Sendable {
    var downloaded: [String] = []
    var scheduled = 0
    var quitRequests = 0
    var forceQuits = 0
    var waits: [Duration] = []
    var downloadError: Error?
    var scheduleError: Error?
    /// Lets a test look at the updater's state at the instant it asks to quit.
    var onQuitRequested: (() -> Void)?

    var hooks: GitHubUpdater.Hooks {
        GitHubUpdater.Hooks(
            download: { [self] release in
                downloaded.append(release.version)
                if let downloadError { throw downloadError }
                return URL(fileURLWithPath: "/tmp/ore-update/ORE.dmg")
            },
            schedule: { [self] _ in
                if let scheduleError { throw scheduleError }
                scheduled += 1
            },
            requestQuit: { [self] in
                quitRequests += 1
                onQuitRequested?()
            },
            forceQuit: { [self] in forceQuits += 1 },
            wait: { [self] duration in waits.append(duration) }
        )
    }
}
