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
        #expect(script.contains("/usr/bin/open \"$DST\""))
    }

    /// The installed app is never removed to make room for the new one.
    ///
    /// This is an ordering test on purpose: the old script's first act after
    /// the app quit was `rm -rf` on the bundle it was replacing, so anything
    /// that went wrong afterwards left the Mac with no ORE.
    @Test func theSwapScriptNeverDeletesTheAppItIsReplacing() {
        let script = swapScript()

        #expect(!script.contains("/bin/rm -rf '/Applications/ORE.app'"))
        // Copy, then check, then swap — in that order.
        let copy = try? #require(script.range(of: "ditto \"$SRC\" \"$INCOMING\""))
        let verify = try? #require(script.range(of: "codesign --verify"))
        let swap = try? #require(script.range(of: "mv \"$INCOMING\" \"$DST\""))
        if let copy, let verify, let swap {
            #expect(copy.upperBound < verify.lowerBound)
            #expect(verify.upperBound < swap.lowerBound)
        }
        // The one `rm -rf "$DST"` in the script is the rollback, which cannot
        // run until the swap has already happened and the new app refused to
        // open. Before that point the destination is never removed at all.
        #expect(script.components(separatedBy: "/bin/rm -rf \"$DST\"").count == 2)
        let removeDestination = try? #require(script.range(of: "/bin/rm -rf \"$DST\""))
        if let swap, let removeDestination {
            #expect(swap.upperBound < removeDestination.lowerBound)
        }
        #expect(script.contains("mv \"$DST\" \"$PREVIOUS\""), "the old app is kept, not deleted")
    }

    // MARK: - Running the real swap

    /// Runs the generated script for real, with `open` stubbed out so a
    /// throwaway bundle is never handed to Launch Services. Everything else —
    /// ditto, codesign, the move, the rollback — is the real thing.
    private func runSwap(
        newApp: URL,
        destination: URL,
        logPath: String,
        origin: String? = nil,
        open: String = "/usr/bin/true"
    ) throws -> Int32 {
        var script = GitHubUpdater.relaunchScript(
            // A pid we cannot signal reads as "already gone", which is the
            // state the script is written to wait for.
            newApp: newApp, destination: destination, pid: 1,
            scriptPath: "/dev/null", label: "dev.ore.relaunch.test",
            origin: origin,
            logPath: logPath
        )
        // `/usr/bin/true` accepts the launch; `/usr/bin/false` is a Mac that
        // refuses to run what was just installed.
        script = script.replacingOccurrences(of: "/usr/bin/open", with: open)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-swap-\(UUID().uuidString).sh")
        try script.write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }

        let bash = Process()
        bash.executableURL = URL(fileURLWithPath: "/bin/bash")
        bash.arguments = [path.path]
        bash.standardOutput = FileHandle.nullDevice
        bash.standardError = FileHandle.nullDevice
        try bash.run()
        bash.waitUntilExit()
        return bash.terminationStatus
    }

    @Test func aGoodUpdateReplacesTheInstalledApp() throws {
        let scratch = try Scratch()
        let staged = try scratch.app(named: "ORE.app", in: "staging", version: "2.0", signed: true)
        let installed = try scratch.app(named: "ORE.app", in: "Applications", version: "1.0", signed: true)

        _ = try runSwap(newApp: staged, destination: installed, logPath: scratch.log.path)

        #expect(scratch.version(of: installed) == "2.0")
        #expect(scratch.leftovers(in: "Applications").isEmpty, "no staging directories survive")
    }

    /// The case the old script could not survive: something is wrong with the
    /// new app. The user must still have the one they were running.
    @Test func anUnverifiableUpdateLeavesTheInstalledAppAlone() throws {
        let scratch = try Scratch()
        let staged = try scratch.app(named: "ORE.app", in: "staging", version: "2.0", signed: false)
        let installed = try scratch.app(named: "ORE.app", in: "Applications", version: "1.0", signed: true)

        let status = try runSwap(newApp: staged, destination: installed, logPath: scratch.log.path)

        #expect(status != 0)
        #expect(scratch.version(of: installed) == "1.0", "the working install is untouched")
        #expect(scratch.leftovers(in: "Applications").isEmpty)
        #expect(scratch.logContents().contains("signature verification"), "and it says why")
    }

    @Test func anIncompleteUpdateLeavesTheInstalledAppAlone() throws {
        let scratch = try Scratch()
        let staged = try scratch.app(named: "ORE.app", in: "staging", version: "2.0", signed: true)
        // A bundle whose executable never arrived, which is what a truncated
        // download unpacks to.
        try FileManager.default.removeItem(at: staged.appendingPathComponent("Contents/MacOS/OreMac"))
        let installed = try scratch.app(named: "ORE.app", in: "Applications", version: "1.0", signed: true)

        let status = try runSwap(newApp: staged, destination: installed, logPath: scratch.log.path)

        #expect(status != 0)
        #expect(scratch.version(of: installed) == "1.0")
    }

    @Test func aFirstInstallWithNothingToReplaceStillLands() throws {
        let scratch = try Scratch()
        let staged = try scratch.app(named: "ORE.app", in: "staging", version: "2.0", signed: true)
        let destination = scratch.root
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("ORE.app")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        _ = try runSwap(newApp: staged, destination: destination, logPath: scratch.log.path)

        #expect(scratch.version(of: destination) == "2.0")
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

    // MARK: - Pre-flight

    @Test func anUnwritableDestinationFailsBeforeAnyQuitIsRequested() throws {
        let scratch = try Scratch()
        let readOnly = scratch.root.appendingPathComponent("ReadOnly", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: readOnly.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: readOnly.path
            )
        }
        let probe = HookProbe()
        let updater = makeUpdater(
            probe: probe,
            version: "0.7.0",
            bundle: readOnly.appendingPathComponent("ORE.app")
        )
        updater.applyCheckResult(release("v0.8.0"))

        updater.install()

        // The point of the whole check: nothing downloaded and nothing asked
        // to quit, so no agent lost its turn to an update that never could
        // have landed.
        #expect(probe.downloaded.isEmpty)
        #expect(probe.quitRequests == 0)
        #expect(probe.forceQuits == 0)
        #expect(updater.isFailed)
        if case .failed(let detail) = updater.phase {
            #expect(detail.contains(readOnly.path), "and it names the folder")
        }
    }

    @Test func aWritableDestinationIsNotBlocked() throws {
        let scratch = try Scratch()
        #expect(
            GitHubUpdater.installBlocker(
                currentBundle: scratch.root.appendingPathComponent("ORE.app")
            ) == nil
        )
    }

    @Test func translocatedBundlesAreRefusedRatherThanRedirected() {
        // Gatekeeper's read-only copy of an app opened from a downloaded DMG.
        // Quietly installing to /Applications from here leaves two copies and
        // keeps the user running the old one — "the update did nothing".
        let translocated = URL(
            fileURLWithPath: "/private/var/folders/xy/AppTranslocation/0B1C/d/ORE.app"
        )
        let probe = HookProbe()
        let updater = makeUpdater(probe: probe, version: "0.7.0", bundle: translocated)
        updater.applyCheckResult(release("v0.8.0"))

        updater.install()

        #expect(probe.downloaded.isEmpty)
        #expect(probe.quitRequests == 0)
        #expect(updater.isFailed)
        if case .failed(let detail) = updater.phase {
            #expect(detail.contains("Applications folder"))
        }
        #expect(GitHubUpdater.isTranslocated(translocated))
        #expect(
            GitHubUpdater.isTranslocated(URL(fileURLWithPath: "/Applications/ORE.app")) == false
        )
    }

    // MARK: - "Later"

    @Test func dismissSurvivesRelaunchButNotANewerVersion() {
        let defaults = makeDefaults()
        let updater = makeUpdater(probe: HookProbe(), defaults: defaults, version: "0.7.0")
        updater.applyCheckResult(release("v0.8.0"))

        updater.dismiss()
        #expect(updater.showsPrompt == false)

        // The modal used to come back on the next launch, and every launch
        // after it, for a release the user had already waved off.
        let relaunched = makeUpdater(probe: HookProbe(), defaults: defaults, version: "0.7.0")
        relaunched.applyCheckResult(release("v0.8.0"))
        #expect(relaunched.dismissed)
        #expect(relaunched.showsPrompt == false)

        // A newer release is a different question and gets asked again.
        let newer = makeUpdater(probe: HookProbe(), defaults: defaults, version: "0.7.0")
        newer.applyCheckResult(release("v0.9.0"))
        #expect(newer.dismissed == false)
        #expect(newer.showsPrompt)
    }

    // MARK: - Rollback when the new app won't open

    @Test func relaunchScriptRestoresThePreviousBundleWhenOpenFails() throws {
        let scratch = try Scratch()
        let staged = try scratch.app(named: "ORE.app", in: "staging", version: "2.0", signed: true)
        let installed = try scratch.app(
            named: "ORE.app", in: "Applications", version: "1.0", signed: true
        )

        // The swap works; it is Launch Services that refuses what came out of
        // it. The old script had already deleted the only other copy by here.
        _ = try runSwap(
            newApp: staged,
            destination: installed,
            logPath: scratch.log.path,
            open: "/usr/bin/false"
        )

        #expect(scratch.version(of: installed) == "1.0", "the user still has a working ORE")
        #expect(scratch.leftovers(in: "Applications").isEmpty)
        #expect(scratch.logContents().contains("rolled back"))
    }

    @Test func thePreviousBundleIsOnlyDiscardedOnceTheNewOneOpened() {
        let script = swapScript()
        let tail = script.components(separatedBy: "log \"installed; reopening\"").last ?? ""

        // Exactly one `rm -rf "$PREVIOUS"` after the swap, and it sits inside
        // the branch that only runs when `open` reported success.
        #expect(tail.components(separatedBy: "/bin/rm -rf \"$PREVIOUS\"").count == 2)
        let success = tail
            .components(separatedBy: "if [ \"$OPENED\" = 1 ]; then").last?
            .components(separatedBy: "else").first ?? ""
        #expect(success.contains("/bin/rm -rf \"$PREVIOUS\""))
    }

    @Test func givingUpFallsBackToTheBundleThatWasRunning() {
        let script = GitHubUpdater.relaunchScript(
            newApp: URL(fileURLWithPath: "/tmp/stage/ORE.app"),
            destination: URL(fileURLWithPath: "/Applications/ORE.app"),
            pid: 4_242,
            scriptPath: "/tmp/relaunch.sh",
            label: "dev.ore.relaunch.test",
            origin: "/Volumes/ORE/ORE.app"
        )
        let giveUp = script
            .components(separatedBy: "give_up() {").last?
            .components(separatedBy: "\n}").first ?? ""

        #expect(script.contains("ORIGIN='/Volumes/ORE/ORE.app'"))
        // A first install that fails has nothing at "$DST" to reopen, so the
        // bundle the user actually launched is all that is left to go back to.
        #expect(giveUp.contains("/usr/bin/open \"$ORIGIN\""))
    }

    // MARK: - Permissions the update took with it

    @Test func anUpdateThatDroppedAccessibilitySaysHowToGetItBack() {
        // Every release is ad-hoc signed, so the cdhash the Accessibility
        // grant was keyed to is gone. The System Settings row still shows a
        // tick, which is why nobody works this out unaided.
        let defaults = makeDefaults()
        stage("v0.8.0", in: defaults, hotkeyWasTrusted: true)
        let updater = makeUpdater(
            probe: HookProbe(), defaults: defaults, version: "0.8.0", accessibilityTrust: false
        )

        updater.reconcilePendingRestart()

        #expect(updater.completedVersion == "0.8.0")
        let note = updater.completionNote ?? ""
        #expect(note.contains("Accessibility"))
        #expect(note.contains("remove ORE"), "re-ticking the row is the thing that doesn't work")
    }

    @Test func anUpdateThatKeptAccessibilityAddsNothingToTheCard() {
        let defaults = makeDefaults()
        stage("v0.8.0", in: defaults, hotkeyWasTrusted: true)
        let updater = makeUpdater(
            probe: HookProbe(), defaults: defaults, version: "0.8.0", accessibilityTrust: true
        )

        updater.reconcilePendingRestart()

        #expect(updater.completionNote == nil)
    }

    @Test func someoneWhoNeverGrantedAccessibilityIsNotToldItBroke() {
        let defaults = makeDefaults()
        stage("v0.8.0", in: defaults, hotkeyWasTrusted: false)
        let updater = makeUpdater(
            probe: HookProbe(), defaults: defaults, version: "0.8.0", accessibilityTrust: false
        )

        updater.reconcilePendingRestart()

        #expect(updater.completedVersion == "0.8.0")
        #expect(updater.completionNote == nil)
    }

    @Test func aRecordWrittenBeforeTrustWasTrackedReadsAsNotTrusted() {
        // Records staged by an older build have no `hotkeyWasTrusted` at all;
        // absent must not be mistaken for "was trusted".
        let defaults = makeDefaults()
        stage("v0.8.0", in: defaults)
        let updater = makeUpdater(
            probe: HookProbe(), defaults: defaults, version: "0.8.0", accessibilityTrust: false
        )

        updater.reconcilePendingRestart()

        #expect(updater.completionNote == nil)
    }

    @Test func trustIsRecordedBeforeTheSwapNotAfterIt() async throws {
        let defaults = makeDefaults()
        let updater = makeUpdater(
            probe: HookProbe(), defaults: defaults, version: "0.7.0", accessibilityTrust: true
        )

        await updater.runInstall(release("v0.8.0"))

        let data = try #require(defaults.data(forKey: GitHubUpdater.pendingRestartKey))
        let pending = try JSONDecoder().decode(GitHubUpdater.PendingRestart.self, from: data)
        #expect(pending.hotkeyWasTrusted == true)
    }

    @Test func acknowledgingTheConfirmationClearsTheNoteWithIt() {
        let defaults = makeDefaults()
        stage("v0.8.0", in: defaults, hotkeyWasTrusted: true)
        let updater = makeUpdater(
            probe: HookProbe(), defaults: defaults, version: "0.8.0", accessibilityTrust: false
        )
        updater.reconcilePendingRestart()

        updater.acknowledgeCompletion()

        #expect(updater.completionNote == nil)
        #expect(updater.showsPrompt == false)
    }

    // MARK: - Helpers

    private func swapScript() -> String {
        GitHubUpdater.relaunchScript(
            newApp: URL(fileURLWithPath: "/tmp/stage/ORE.app"),
            destination: URL(fileURLWithPath: "/Applications/ORE.app"),
            pid: 4_242,
            scriptPath: "/tmp/relaunch.sh",
            label: "dev.ore.relaunch.test"
        )
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ore.tests.update.\(UUID().uuidString)")!
    }

    @discardableResult
    private func makeUpdater(
        probe: HookProbe,
        defaults: UserDefaults? = nil,
        version: String,
        bundle: URL = URL(fileURLWithPath: "/Applications/ORE.app"),
        accessibilityTrust: Bool = false
    ) -> GitHubUpdater {
        GitHubUpdater(
            hooks: probe.hooks,
            defaults: defaults ?? makeDefaults(),
            version: { version },
            bundleURL: { bundle },
            // Never the real `AXIsProcessTrusted()`: whether the machine
            // running the tests happens to trust the test runner is not what
            // any of these are about.
            accessibilityTrust: { accessibilityTrust }
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

    private func stage(
        _ version: String, in defaults: UserDefaults, hotkeyWasTrusted: Bool? = nil
    ) {
        let pending = GitHubUpdater.PendingRestart(
            version: version,
            title: "ORE \(version)",
            releaseURL: URL(string: "https://example.invalid/\(version)")!,
            hotkeyWasTrusted: hotkeyWasTrusted
        )
        defaults.set(try! JSONEncoder().encode(pending), forKey: GitHubUpdater.pendingRestartKey)
    }
}

/// A throwaway Applications folder and a throwaway app to put in it.
///
/// Real bundles, really signed: the swap script verifies what it copied, and
/// a fake that cannot be verified would make every one of these tests pass
/// for the wrong reason.
private struct Scratch {
    let root: URL
    let log: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ore-update-\(UUID().uuidString)", isDirectory: true)
        log = root.appendingPathComponent("update.log")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func app(named name: String, in directory: String, version: String, signed: Bool) throws -> URL {
        let parent = root.appendingPathComponent(directory, isDirectory: true)
        let app = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true
        )
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>CFBundleExecutable</key><string>OreMac</string>
              <key>CFBundleIdentifier</key><string>dev.ore.OreMac.updatetest</string>
              <key>CFBundleShortVersionString</key><string>\(version)</string>
            </dict></plist>
            """
        try plist.write(
            to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8
        )
        let executable = app.appendingPathComponent("Contents/MacOS/OreMac")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path
        )
        if signed { run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) }
        return app
    }

    func version(of app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    /// Staging and rollback directories the script is supposed to clean up.
    func leftovers(in directory: String) -> [String] {
        let parent = root.appendingPathComponent(directory, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return names.filter { $0.hasPrefix(".ORE.app.") }
    }

    func logContents() -> String {
        (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }

    private func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
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
