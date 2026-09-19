# Onboarding hardening

Everything between "I decided to install ORE" and "my first agent turn
finished", audited as a whole.

Six auditors covered one dimension each — install and first launch, CLI
dependency discovery, on-device model loading, updates and version skew, the
first-run readiness ladder, and macOS permissions. Every finding was then put
to an adversarial verifier that re-read the cited code and was asked to refute
it; the ones below are what survived, with citations corrected where the
original was wrong. 67 confirmed, 16 of them major.

This file is the working record. Units marked **done** have landed; the rest
are in priority order and are meant to be picked up as written.

## Landed

| Unit | What changed |
|---|---|
| 15 | `install.sh`: interrupt-safe rollback, Rosetta false-negative, duplicate-copy warning, telemetry disclosed on every install |
| 18 | Install commands no longer require npm — a fresh Mac has no Node, and rung 1 is the fatal one. Settings offers a per-harness install command. Note this supersedes the unit's own `hasNPM` step: all three vendors ship a self-bootstrapping installer, so there is nothing left to branch on |
| 8 | A **git** rung on the ladder, above "add a project". Detects the Xcode CLT stub *without launching it* (launching it is what pops the system install modal). Both git probes moved into `OreGit` so they resolve through the login-shell PATH |
| 5 | `addRepository` rejects a non-repository folder, and a repository with no commits, at add time instead of at first workspace |
| 9 | A binary found under the generic name `agent` must identify itself as cursor-agent; Codex's auth-file fallback reports `.unknown` rather than `.authenticated` |
| 17 | Folder/volume usage strings in `Info.plist`; "Operation not permitted" git failures name macOS privacy; `worktree prune` before `worktree add` |
| C2/C3 | Release notes lead with the Gatekeeper warning and the privacy link; the Homebrew cask discloses telemetry in `caveats` |

## How this was produced, and what that leaves open

All of it was written without a Swift compiler: the app is macOS-only and the
environment had no toolchain, so the shell, plist, cask and release-workflow
changes were exercised directly and the Swift was checked by reading —
signatures against call sites, new enum cases against every switch, and
`Packages/` against the Linux build.

CI has now built and tested the lot. Exactly one thing did not compile: a
`public` method given an internal typealias and an internal default-argument
value, added by hand after the review passes had finished and therefore seen
by none of them. Nothing the agents wrote failed to build.

What passing CI does **not** cover, and what is therefore still unverified:

- **Every new piece of SwiftUI has compiled but nobody has looked at it.**
  The HUD failure pill (a long denial message in a fixed-height pill), the
  Settings login-item, notification and shadowed-copy rows, the composer's
  voice error row, and the failed-update card. Layout, truncation and overflow
  are unchecked.

  The sidebar narration notice came off this list the way the list predicted
  it would. Its message shared a row with the Download and dismiss buttons, so
  in a 230 pt column the sentence had about a third of the width to wrap in
  and ran to six lines — and the height `safeAreaInset` reserved for it was
  one. The notice and the control bar below it were laid out past the bottom
  of the window, taking the settings gear with them. Now: prose on its own
  full-width row, controls under it, `lineLimit(3)`, and the vendor detail
  left to Settings. Still nobody has looked at it.
- **The disk-space floors are judgement calls.** 1 GB for a CLI update, 1.2 GB
  for the neural voice, neither measured against a real install. Both refuse
  work a tighter machine might have completed.
- **`isUnknownSubcommand` is a heuristic.** Bounded to self-update plans for
  harnesses whose `update` subcommand is unconfirmed — never Claude Code — so
  a false positive costs one extra run of the vendor installer.
- ~~**`.unsupported` over-claims for corrupt weights.**~~ Fixed, and it was
  not hypothetical: a fetch died leaving `mimi_decoder.mlmodelc` holding only
  `analytics/` and `weights/`, CoreML refused it with "Compile the model with
  Xcode", and an M-series Mac on macOS 26 was told it could not run the neural
  voice — permanently, since `.unsupported` carries no retry and FluidAudio
  saw a directory already in place. The two are indeed indistinguishable from
  the error, so the error is no longer what decides: the weights on disk are.
  A `.mlmodelc` with no `coremldata.bin` is one CoreML will refuse, which
  makes it a broken download (`.failed`, retryable) rather than a broken Mac,
  and `install()` removes those directories before fetching so the download
  has something to replace.
- **Two new costs on the startup path are unprofiled**: the PATH walk for
  shadowed copies now runs on every probe of every harness, and an activation
  re-probe discards the login-shell PATH cache. The re-probe is bounded to
  users with no ready agent, which is the case it exists for.
- **The vendor cache check is one-directional by design.** A missing
  `~/.cache/fluidaudio` proves nothing is cached; its presence proves only that
  some backend downloaded something. Verified against FluidAudio at the
  revision `Package.resolved` pins. There is now a second check alongside it
  that runs the other way and is equally sound: a `.mlmodelc` without its
  manifest is not "possibly incomplete" but "will be refused", so it retires
  the install flag too.

- **Window sizing was tuned on a large display.** The default 1320x820 was
  wider and taller than a 13" MacBook Air's 1280x800, so a first launch there
  put the composer and the sidebar's controls below the bottom of the screen;
  it is now 1200x740. The root's `minHeight` came down from 650 to 560 for a
  related reason: a minimum on the root of a `WindowGroup` constrains the
  content view rather than the window, and a window shorter than the floor
  gets the overflow clipped off both ends at once. Unmeasured on a real 13".

---

# ORE Onboarding Repair Plan

67 verified findings → **26 work units**. Sequential, one engineer. Units 1–20 are pure wins; 21–26 need a decision or carry risk. Non-code items at the end.

Test conventions assumed: `@Test`/`#expect`, `Packages/OreKit/Tests/OreKitTests/*`, `Apps/OreMac/Tests/OreMacTests/*`. Shell-installer tests go in `packaging/test-install.sh` (already a harness).

---

## PART A — PURE WINS (small, safe, clearly right)

### 1. Welcome screen never renders empty — S
**Merges:** `empty-welcome-screen-with-no-recourse`, `blank-welcome-while-probing`, `blank-welcome-when-core-start-throws`

**Files:** `Apps/OreMac/Sources/OreMac/NextStepCard.swift`, `Apps/OreMac/Sources/OreMac/AppModel.swift`

- `NextStepCard.body` (:28): when `readiness.nextStep == nil`, fall back to the first `.unknown && isBlocking` step and render it — existing title "Checking for coding agents…" + detail + a `ProgressView()` in place of `actionRow`. This makes the already-written dead copy reachable.
- `AppModel.swift:337`: replace `try? await client.start()` with `do { … } catch { show(.error("ORE couldn't finish starting up: \(error.localizedDescription)")) }`. Keep `isLoaded = true` in both paths.

**Test** (`ReadinessTests.swift`): `@Test func unknownBlockingStepIsRenderableBeforeProbe()` — assert `Readiness.evaluate(hasProbedHarnesses: false, …).steps.first` has `status == .unknown`, `isBlocking`, non-empty `title`, and that the new `NextStepCard.fallbackStep(for:)` helper (extract it as a `static func` so it is testable without SwiftUI) returns it.

---

### 2. First launch is silent — S
**Merges:** `first-launch-speaks-out-loud`, `first-launch-talks-over-the-next-step`

**Files:** `Apps/OreMac/Sources/OreMac/AppModel.swift`

- `prepareLaunchBriefing()` (:529): add `guard !sortedWorkspaces.isEmpty else { return }` at the top. Do **not** write `lastSeenKey` in that guard — a bogus timestamp corrupts the first real briefing.
- `:549`: change `?? true` to `?? false` so a never-seen machine is not treated as a long absence (belt and braces for a user whose fleet is non-empty on first launch, e.g. restored `~/ore`).

**Test** (`LaunchBriefingTests.swift`): `@Test func firstLaunchWithEmptyFleetProducesNoBriefing()` and `@Test func missingLastSeenIsNotALongAbsence()` — assert the absence classifier returns `false` for `nil`.

---

### 3. A store that won't open stops the app instead of faking one — M
**Merges:** `database-failure-shows-raw-error-and-silently-loses-work`, `no-schema-version-silent-inmemory-store`

**Files:** `Apps/OreMac/Sources/OreMac/OreMacApp.swift`

- `:166-172`: stop substituting `try! OreStore()`. Keep `launchFailure` set; build the message as `"\(error)\n\nORE's database lives at \(OreStore.defaultURL.path)"`.
- `RootView` (:595-597, :751-758): when `launchFailure != nil`, return the `ContentUnavailableView` for the **whole window** — no `NavigationSplitView`, no sidebar. Add a "Reveal in Finder" button (`NSWorkspace.shared.selectFile(OreStore.defaultURL.path, inFileViewerRootedAtPath: "")`).
- `CommandGroup(replacing: .newItem)` (:257-268): `.disabled(launchFailure != nil)` on both `⌘N` and `⇧⌘N`.

User sees: one screen, the path, a reveal button, and no way to do work that will evaporate.

**Test** (`OreMacTests/` new `LaunchFailurePresentationTests.swift`): `@Test func launchFailureMessageNamesTheStorePath()` — assert the message builder contains `OreStore.defaultURL.path`. Plus `@Test func newWorkspaceCommandsAreDisabledOnLaunchFailure()` against the extracted `commandsEnabled(launchFailure:)` predicate.

---

### 4. PATH is re-probed when the user comes back — S
**Merges:** `path-snapshot-never-invalidated`, `login-shell-path-cached-for-process-lifetime`, `no-reprobe-on-activation`

**Files:** `Packages/OreKit/Sources/OreSupport/ShellEnvironment.swift`, `Packages/OreKit/Sources/OreCore/InProcessCoreClient.swift`, `Apps/OreMac/Sources/OreMac/AppDelegate.swift`, `Apps/OreMac/Sources/OreMac/AppModel.swift`

- `ShellEnvironment`: add `public static func invalidateCache() { cache.invalidate() }` (the `Cache.invalidate()` already exists and is only called from tests).
- `InProcessCoreClient` `.probeHarnesses` case (:304): call `ShellEnvironment.invalidateCache()` first, off the main actor, so an explicit Refresh re-probes the login shell.
- `AppDelegate.applicationDidBecomeActive` (:37-41): add a throttled `model.refreshHarnesses()` (skip if the last refresh was < 20s ago) beside `ExternalTools.refreshDiscoveredApps()`. Add `private var lastActivationProbe: Date?` to `AppModel`.

This is the unit that makes "copy install command → install in Terminal → cmd-tab back" actually work.

**Test** (`ShellEnvironmentTests.swift`): `@Test func invalidateCacheForcesRecompute()` — resolve, invalidate, resolve, assert the compute closure ran twice. (`OreMacTests/`) `@Test func activationProbeIsThrottled()` against an extracted `shouldReprobe(now:last:)`.

---

### 5. A folder that is not a git repo is rejected at add time — S  ·  **LANDED**
**Merges:** `non-repo-folder-accepted-as-project`, `add-repository-accepts-any-directory`, unborn-HEAD half of `worktree-failures-are-raw-git-with-no-recovery`

**Files:** `Packages/OreKit/Sources/OreCore/InProcessCoreClient.swift`

In `addRepository(path:)` (:602), after `canonicalRepositoryURL`:
```
guard let git = try? gitClient(for: root.path),
      (try? await git.topLevel()) != nil
else { throw GitError.notARepository(path: root.path) }
guard (try? await git.resolve("HEAD")) != nil
else { throw GitError.commandFailed(... "has no commits yet — make an initial commit first.") }
```
Leave `canonicalRepositoryURL` alone — `createWorkspace` shares it for symlink canonicalization. `GitError.notARepository` is already declared (GitClient.swift:765/781) with zero throw sites and already renders as "`<path>` is not a git repository." through `send(_:)`.

**Test** (`CoreClientTests.swift`): `@Test func addRepositoryRejectsANonRepositoryFolder()` and `@Test func addRepositoryRejectsARepositoryWithNoCommits()` — both using `GitFixture`, asserting the throw and that `store.repositories()` stays empty.

---

### 6. "Add from this Mac…" exists on the screen the card sends you to — S
**Merges:** `no-way-to-add-a-local-repo-from-the-onboarding-cta`, `add-repository-selects-the-wrong-project-on-a-slow-store`

**Files:** `Apps/OreMac/Sources/OreMac/NewWorkspaceComposer.swift`, `Apps/OreMac/Sources/OreMac/NewWorkspaceSheet.swift`

- Composer Choose menu (:283-286, the unconditional Section): add `Button("Add from this Mac…", action: onAddLocal)`. New `var onAddLocal: () -> Void` on the composer, passed from `NewWorkspaceSheet.swift:65-80` and wired to the existing `chooseRepository()`.
- `chooseRepository()` (:305-321): delete the `Task.sleep(400ms)` and the `?? model.repositories.first` fallback. Poll `refreshRepositories()` up to ~5s until a repository matches, comparing **resolved** paths (`url.resolvingSymlinksInPath().path`) against the stored path, because the core canonicalizes. On success set both `repositoryPath` and `repositoryOverride`; on timeout leave the selection untouched and show the sheet's existing inline error.

**Test** (`WorkspaceLaunchPlanTests.swift` or new `RepositorySelectionTests.swift`): `@Test func selectionMatchesTheCanonicalizedRootAndNeverFallsBackToAnUnrelatedRepo()` against an extracted `static func select(added:in:) -> String?` helper.

---

### 7. "Agent not found" in chat offers the install command — S
**Merges:** `no-agent-installed-yields-endless-retry`

**Files:** `Apps/OreMac/Sources/OreMac/ChatState.swift`, `Apps/OreMac/Sources/OreMac/ChatPane.swift`

- `ChatState.ProminentError`: add `var needsInstall: Bool`, set from a new `Self.looksLikeMissingCLI(_:)` matching `"was not found on path"`. It must take precedence over `needsSignIn`/`isUsageLimit` (same pattern as `needsCLIUpgrade`).
- `ProminentErrorBanner` (ChatPane.swift:4313-4373): when `needsInstall`, title it "**\(kind.displayName) isn't installed**", body "ORE couldn't find its CLI on your PATH.", and reuse the existing copy-command button (:4346-4359) with `HarnessSetup.installCommand(for: kind)`. The harness kind is already in scope at :2855-2860. Keep Retry as the secondary.

**Test** (`ChatStateTests.swift`): `@Test func missingCLIErrorAsksForInstallNotSignIn()` — build a `ProminentError` from `"Claude Code CLI (`claude`) was not found on PATH: /usr/bin:/bin"` and `#expect(error.needsInstall && !error.needsSignIn)`.

---

### 8. git presence is a rung, and the CLT shim is not mistaken for git — M  ·  **LANDED**
**Merges:** `no-git-rung-in-readiness`, `clt-shim-not-distinguished`, `git-identity-probe-bypasses-path`, `no-git-rung-on-the-ladder`

**Files:** `Apps/OreMac/Sources/OreMac/Readiness.swift`, `Packages/OreKit/Sources/OreCore/AssistantManager.swift`, `Apps/OreMac/Sources/OreMac/AppModel.swift`

- New `Readiness.probeGit() async -> GitAvailability` (`enum { ok, missingTools, unknown }`): run `ShellEnvironment.locate("git")` with `ShellEnvironment.childEnvironment()` and args `["--version"]`, 5s bound. Non-zero exit, or output/stderr containing `"no developer tools were found"` / `"xcode-select"`, ⇒ `.missingTools`. Launch failure ⇒ `.unknown`.
- New **blocking** rung `gitStep` inserted before `projectStep` in `evaluate` (:106-112). `.missingTools` ⇒ title "Install Apple's command line tools", detail "ORE drives git directly; macOS ships a placeholder until the developer tools are installed.", `action: .copyCommand("xcode-select --install")`. `.unknown` ⇒ `.unknown` status (the ladder already stops there). `.ok` ⇒ `.satisfied`.
- `gitConfig` (:267-287): set `process.environment = ShellEnvironment.childEnvironment()` and resolve via `ShellEnvironment.locate("git")` instead of `/usr/bin/env`. `probeGitIdentity` returns `Bool?` — `nil` when git could not run, so the identity rung stays silent instead of accusing the user.
- `AssistantManager.runGit` (:220-228): drop the `?? "/usr/bin/git"` fallback and the `ProcessInfo.processInfo.environment` lookup; use `ShellEnvironment.locate("git")` + `childEnvironment()`, and return a failure rather than spawning the shim during `start()` (this is what pops the OS modal unattributed seconds after first launch).

Do **not** key anything on `GitError.gitNotFound` — unreachable on macOS.

**Test** (`ReadinessTests.swift`): `@Test func missingCommandLineToolsBlocksBeforeTheProjectRung()` — `#expect(readiness.nextStep?.id == "git")` and the action is `.copyCommand("xcode-select --install")`. `@Test func unknownGitKeepsTheIdentityRungSilent()`. (`OreKitTests/HarnessRepairTests.swift`) `@Test func assistantGitFailsRatherThanSpawningTheShim()`.

---

### 9. Probes stop claiming readiness they cannot back — M  ·  **PARTLY LANDED** (generic `agent` name, Codex auth file). The `CommandProbe.output` change that makes an unlaunchable CLI stop reading as ready is still open, and is the bigger half.
**Merges:** `unlaunchable-cli-reads-as-ready`, `codex-auth-from-file-existence`, `generic-agent-executable-name`, `ore-version-hardcoded-for-codex-handshake`

**Files:** `Packages/OreKit/Sources/OreHarness/ClaudeCode/ClaudeCodeHarness.swift`, `.../Codex/CodexHarness.swift`, `.../Codex/CodexSession.swift`, `.../CursorAgent/CursorAgentHarness.swift`

- `CommandProbe.output` (ClaudeCodeHarness.swift:221-233): change the return to `enum ProbeOutput { case text(String), empty, couldNotLaunch(String) }` (or `Result<String?, ProbeLaunchFailure>`). Capture stderr instead of discarding it (:229). Shared by all three harnesses.
- Each `probe()`: on `.couldNotLaunch(reason)` set `diagnostic: "Found at \(path) but could not be launched: \(reason)"` and `authState: .notAuthenticated` so `isReady` is false. `.empty` keeps today's `.unknown`.
- `CodexHarness.probeAuthState` (:137-150): the `~/.codex/auth.json`-exists fallback returns `.unknown`, not `.authenticated`. Keep `.notAuthenticated` when the file is absent.
- `CursorAgentHarness.probe`: when the resolved path came from the generic `"agent"` fallback (:27, :145-152), require the `--version` output (:68-70) to contain `"cursor"`; otherwise return the not-found result. Record the accepted path on the probe result so `makeSession` (:128) does not re-resolve to the impostor.
- `CodexSession.OreVersion.current` (:576-578): `Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"` — keep the literal as the fallback for `ore-cli` and tests.

**Test** (`OreKitTests/`): in `HarnessRepairTests.swift` `@Test func aBinaryThatCannotLaunchIsNotReady()`; in `ClaudeAuthStatusTests.swift` `@Test func codexAuthFileAloneIsUnknownNotAuthenticated()`; new `@Test func aGenericAgentBinaryIsRejectedWithoutACursorVersionString()`.

---

### 10. Sign-in can be cancelled and shows its URL — M
**Merges:** `harness-signin-hangs-forever`

**Files:** `Apps/OreMac/Sources/OreMac/AppModel.swift`, `Apps/OreMac/Sources/OreMac/SettingsView.swift`

- `authenticateHarness` (:3439-3455): use `ChildProcess` with captured stdout/stderr and `ShellEnvironment.childEnvironment()` (not `ProcessInfo.processInfo.environment`). Keep the process handle on `AppModel` so it can be terminated. Add a 180s deadline ⇒ `authenticationNotice = "Sign-in timed out. Run `\(HarnessSetup.signInCommand(for: kind))` in Terminal instead."`. Scan output for an `https://` URL and put it in `authenticationNotice` with a "Copy link" affordance.
- `SettingsView.swift:588-606`: while `authenticatingHarness == kind`, render "Waiting for browser…" **plus** a Cancel button calling a new `model.cancelHarnessAuthentication()`.

**Test** (`OreMacTests/` new `HarnessSignInTests.swift`): `@Test func signInTimeoutProducesATerminalFallbackNotice()` and `@Test func aPrintedURLIsExtractedFromLoginOutput()` against an extracted `static func firstURL(in:)`.

---

### 11. The updater checks before it kills your work, and "Later" sticks — M
**Merges:** `no-preflight-writability-check-before-quitting`, `update-modal-reappears-every-launch`, `update-log-never-surfaced`

**Files:** `Apps/OreMac/Sources/OreMac/GitHubUpdater.swift`

- Top of `install()` (:226, before `phase = .downloading`):
```
let parent = Self.installDestination(currentBundle: Bundle.main.bundleURL).deletingLastPathComponent()
guard FileManager.default.isWritableFile(atPath: parent.path) else {
    phase = .failed("ORE can't replace itself at \(parent.path) — that folder isn't writable by you. Reinstall from https://…, or move ORE to ~/Applications.")
    return
}
```
Parent-directory writability is the whole check; the swap is a rename in that directory.
- `dismiss()` (:212-216): persist the declined version to `UserDefaults` (`ore.update.dismissedVersion`), mirroring `AppModel.dismissHarnessUpdate` (AppModel.swift:3406-3410). Re-apply it in `applyCheckResult` (:200-210) — its existing version comparison already clears it when a newer release appears.
- `GitHubUpdatePrompt.card` (:959-976): when `updater.isFailed`, add a secondary "Show Log" button — `NSWorkspace.shared.selectFile(GitHubUpdater.defaultLogPath, inFileViewerRootedAtPath: "")`.

**Test** (`UpdateRestartTests.swift`): `@Test func anUnwritableDestinationFailsBeforeAnyQuitIsRequested()` — drive `install()` with stub hooks, `#expect(hooks.requestQuitCount == 0)` and `.failed` naming the path. `@Test func dismissSurvivesRelaunchButNotANewerVersion()`.

---

### 12. The relaunch script always leaves a working ORE — S
**Merges:** `no-os-compatibility-check-old-app-deleted`, `dmg-boot-update-can-orphan-the-running-app`, `translocated-dmg-app-updates-nowhere`

**Files:** `Apps/OreMac/Sources/OreMac/GitHubUpdater.swift` (script builder + `installDestination`)

- `installDestination` (:543-548): also match `"/AppTranslocation/"`. For that case **refuse**: `install()` sets `phase = .failed("Move ORE to your Applications folder to update — it's currently running from a read-only copy macOS made of the disk image.")`. Silently writing to `/Applications` from a translocated launch installs a copy the user did not ask for and still leaves them on the old one.
- Pass `Bundle.main.bundleURL.path` into `relaunchScript` as `ORIGIN` (quoted through the existing `shellQuote`). End `give_up` (:632-643) with `{ [ -e "$DST" ] && /usr/bin/open "$DST"; } || /usr/bin/open "$ORIGIN"`.
- Tail of the script (:695-696), make cleanup conditional:
```
if /usr/bin/open "$DST"; then /bin/rm -rf "$PREVIOUS"
else log "could not reopen $DST"; /bin/rm -rf "$DST"; /bin/mv "$PREVIOUS" "$DST"; /usr/bin/open "$DST"; fi
```
Skip the `LSMinimumSystemVersion` / `sw_vers` gate — a failed `open` is the general case and needs no release-policy guess.

**Test** (`UpdateRestartTests.swift`): `@Test func translocatedBundlesAreRefusedRatherThanRedirected()`; `@Test func relaunchScriptRestoresThePreviousBundleWhenOpenFails()` — assert on the generated script text that `rm -rf "$PREVIOUS"` occurs only inside the success branch and that `ORIGIN` appears in `give_up`.

---

### 13. Every denied permission has a route back — M
**Merges:** `accessibility-prompt-fires-only-once-no-fallback`, `global-hotkey-monitors-never-reinstalled-after-grant`, `notification-denial-is-invisible`, `launch-at-login-toggle-silently-snaps-back`

**Files:** new `Apps/OreMac/Sources/OreMac/SystemSettingsLink.swift`, `Apps/OreMac/Sources/OreMac/SettingsView.swift`, `Apps/OreMac/Sources/OreMac/VoiceHotkey.swift`, `Apps/OreMac/Sources/OreMac/AppDelegate.swift`

New `enum SystemSettingsLink { case microphone, speechRecognition, accessibility, filesAndFolders, notifications, loginItems; var url: URL; static func open(_:) }` — the repo currently contains **zero** `x-apple.systempreferences` URLs. Used by this unit and unit 14.

- `SettingsView.swift:403-405`: `if !hotkey.requestAccessibility() { SystemSettingsLink.open(.accessibility) }`.
- `AppDelegate.applicationDidBecomeActive`: call `VoiceHotkeyMonitor.shared.refreshTrust()`; on a `false → true` flip call `stop()` then `start()` so the global monitor is re-registered under the new trust (a monitor added while untrusted stays blind for the process lifetime; `start()` is `guard !isRunning`).
- Notifications card (`SettingsView.swift:337-344`): `.task` reading `UNUserNotificationCenter.current().notificationSettings()`; on `.denied` show one line plus an "Open Notification Settings" button. Relabel the toggle "Notify me in ORE" — it is an app preference, not a system grant.
- Launch-at-login setter (`SettingsView.swift:279-289`): read `SMAppService.mainApp.status` after `register()`; on `.requiresApproval` set a `@State` note under the toggle with a button calling `SMAppService.openSystemSettingsLoginItems()`.

**Test** (`VoiceHotkeyTests.swift`): `@Test func trustFlipRestartsTheGlobalMonitor()` against an extracted `shouldRestartMonitors(was:now:)`. (`OreMacTests/` new `SystemSettingsLinkTests.swift`): `@Test func everyPaneProducesAValidURL()`.

---

### 14. Voice failures are visible and actionable — M
**Merges:** `assistant-voice-errors-are-silently-swallowed`, `mic-error-invisible-when-draft-nonempty`, `no-escape-from-a-denied-permission`, `mic-and-speech-denial-dead-end`

**Files:** `Apps/OreMac/Sources/OreMac/VoiceInput.swift`, `Apps/OreMac/Sources/OreMac/VoiceAssistant.swift`, `Apps/OreMac/Sources/OreMac/AssistantHUD.swift`, `Apps/OreMac/Sources/OreMac/ChatPane.swift`

- `VoiceInput.run()` before :374: check `AVCaptureDevice.authorizationStatus(for: .audio)`; on `.denied`/`.restricted` emit a distinct status carrying `settingsLink: .microphone` and the message "Microphone access is off for ORE. Turn it on in System Settings ▸ Privacy & Security ▸ Microphone." Same shape for speech recognition at :520-529.
- `ChatPane.swift:1427`: render the error line whenever `if case .error = voice.status`, dropping the `draft.isEmpty` gate for the error case only. Add one shared "Open Privacy Settings" button in the mic control's error presentation (:2077) driven by the status's `settingsLink`.
- `VoiceAssistantController`: add `private(set) var failure: String?`, set from `voice.status` at `VoiceAssistant.swift:795`, cleared in `openMic()` (:763). Pass `playCue: true` at :796 so a failure is audible. Render `failure` in the HUD's `placeholder` (`AssistantHUD.swift:474+`) on `.idle`; existing auto-dismiss carries it away. No new `Phase` case.

**Test** (`VoiceInputTests.swift`): `@Test func deniedMicrophoneProducesASettingsLink()`. (`VoiceAssistantTests.swift`): `@Test func handsFreeFailureIsRetainedForTheHUD()`.

---

### 15. install.sh survives an interrupt and names a second copy — S  ·  **LANDED**
**Merges:** `install-interrupt-deletes-the-app`, `curl-and-brew-produce-two-copies`, `rosetta-arch-false-negative`, curl half of `brew-and-dmg-users-never-see-the-privacy-notice`

**Files:** `install.sh`

- `cleanup()` first line (:59): `[ -n "${previous:-}" ] && [ -d "$previous" ] && [ ! -e "$dest" ] && mv "$previous" "$dest"`. Clear `previous=""` after the successful `rm -rf "$previous"` (:254). `previous` is already a shell global — POSIX `sh` has no `local`.
- `check_platform` (:81): `if [ "$arch" != "arm64" ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" != "1" ]; then` — `sysctl.proc_translated` is the reliable Rosetta signal; do not use `hw.optional.arm64` (masked under translation).
- `finish()` after :274: loop `/Applications/ORE.app` and `$HOME/Applications/ORE.app`, and for any that is not `$dest`, `say "Note: another copy of ORE is at $other — remove it with: rm -rf '$other'"`. In `finish()`, not `choose_destination`, so it also covers `ORE_INSTALL_DIR`.
- Move the PRIVACY.md line (:280) **above** the `if [ -z "${ORE_INSTALL_DIR:-}" ]` guard (:276) so every curl install discloses telemetry.

**Test** (`packaging/test-install.sh`): a case that stages an existing `ORE.app`, forces the second `mv` to fail after `previous` is set, runs `cleanup`, and asserts `ORE.app` is back; a case asserting the duplicate-copy note is printed; a case asserting the privacy line prints with `ORE_INSTALL_DIR` set.

---

### 16. Harness CLI updates tell the truth — S
**Merges:** `self-update-oracle-mismatch-unclearable-card`, `brew-installed-harness-with-no-formula-gets-curl-installer`

**Files:** `Apps/OreMac/Sources/OreMac/AppModel.swift`, `Packages/OreKit/Sources/OreHarness/HarnessCLIUpdater.swift`

- `runHarnessCLIUpdate` (:3367-3372): snapshot `harnessUpdate(for: kind)?.installedVersion` before `client.updateHarnessCLI(kind)`. After it returns, if the installed version is unchanged **and** the status still advertises a newer one, leave `harnessCLIUpdate` populated with `error: "\(kind.displayName) reported success but is still on \(old). Its self-updater may be lagging the published version."` instead of `nil`. Implements the intent already documented at `InProcessCoreClient.swift:1785-1789`.
- `HarnessCLIUpdater.source(for:executablePath:)` (:64-66, :92-93): a Homebrew-prefix install whose `kind.brewFormula` is `nil` (today: `cursorAgent`) returns **unknown**, not `.nativeInstaller` — that routes it to the existing "ORE can't tell where \(CLI) was installed from." path (`HarnessUpdateChecker.swift:90-97`) and suppresses the card. No new `Plan` case (that would force every exhaustive switch to change).

**Test** (`HarnessCLIUpdaterTests.swift`): `@Test func brewInstallWithNoFormulaIsNotOfferedTheVendorScript()`. (`HarnessUpdatePromptingTests.swift`): `@Test func aNoOpUpdateKeepsTheCardWithAnExplanation()`.

---

### 17. git failures read like English — S  ·  **LANDED**
**Merges:** `tcc-denial-surfaces-as-raw-git-error`, `missing-folder-and-volume-usage-descriptions`, worktree-metadata half of `worktree-failures-are-raw-git-with-no-recovery`

**Files:** `Packages/OreKit/Sources/OreGit/GitClient.swift`, `Packages/OreKit/Sources/OreGit/WorktreeManager.swift`, `Apps/OreMac/Resources/Info.plist`

- `GitError.description` for `.commandFailed` (:774-778): when the message contains `"Operation not permitted"`, append "\n\nmacOS may be blocking ORE's access to this folder — check System Settings ▸ Privacy & Security ▸ Files and Folders." One site reaches every caller. No path heuristics.
- `WorktreeManager.create` (:86): `try? await git.runSerialized(["worktree", "prune"])` immediately before the `worktree add`, clearing stale registrations left by a folder deleted in Finder.
- `Info.plist`: add `NSDocumentsFolderUsageDescription`, `NSDesktopFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`, one sentence each ("ORE reads and writes the git repositories you point it at."). No code change.

**Test** (`WorktreeTests.swift`): `@Test func aStaleWorktreeRegistrationIsPrunedBeforeAdding()` — register a worktree, `rm -rf` its directory, create again at the same slug, expect success. (`OreKitTests/` `DiffAndStatusTests.swift` or new): `@Test func permissionDeniedGitErrorsMentionPrivacySettings()`.

---

### 18. The right install command, for the right agent, where you need it — S  ·  **LANDED**
**Merges:** `install-command-only-for-claude`, `install-command-assumes-npm`

**Files:** `Apps/OreMac/Sources/OreMac/SettingsView.swift`, `Apps/OreMac/Sources/OreMac/Readiness.swift`

- `SettingsView` per-harness pane: when `probe(for: selectedHarness)?.isInstalled != true`, show a copyable `HarnessSetup.installCommand(for: selectedHarness)` row next to the existing PATH diagnostic (:947-966). This is where a user goes to set up a *specific* agent and today gets no command at all.
- `Readiness.evaluate`: add a `hasNPM: Bool` input (computed **off** the main actor alongside the other probe inputs at :97-105 — `installCommand` is a synchronous helper called during view evaluation and must not spawn a shell). When `hasNPM == false`, `agentStep`'s install action offers `HarnessSetup.installCommand(for: .cursorAgent)` (the curl installer) and the detail names Node as the prerequisite for the npm route.

**Test** (`ReadinessTests.swift`): `@Test func withoutNPMTheInstallCommandDoesNotRequireNode()`.

---

### 19. Creating a workspace acknowledges the click — S
**Merges:** `no-progress-between-start-and-the-workspace`

**Files:** `Apps/OreMac/Sources/OreMac/NewWorkspaceSheet.swift`, `Apps/OreMac/Sources/OreMac/AppModel.swift`

Cheapest correct shape: make `AppModel.createWorkspace` (:1237-1249) `async` and awaited, so the sheet's existing `isCreating` spinner stays on screen until the core returns and `dismiss()` happens after. No new state, no placeholder row to leak on failure.

If the sheet must dismiss immediately instead, add `workspaceCreationsInFlight` to `AppModel`, render it as a dimmed row in `Sidebar.emptyState` (:349-359), and **decrement on `.commandFailed`** as well as `.workspaceAdded` or the placeholder outlives a failed create.

**Test** (`SidebarTests.swift`): `@Test func aFailedCreateClearsTheInFlightPlaceholder()` if the second shape is taken; otherwise (`OreMacTests/`) `@Test func theSheetStaysOpenUntilCreateReturns()`.

---

### 20. Speech/voice assets stop downloading unasked and can be retried — M
**Merges:** `speech-model-prewarmed-at-launch-without-consent`, `asset-reservation-failure-swallowed-and-faked`, `offline-reported-as-not-available-on-this-mac`, `neural-voice-stuck-in-not-installed`

**Files:** `Apps/OreMac/Sources/OreMac/VoiceInput.swift`, `Apps/OreMac/Sources/OreMac/NarrationVoice.swift`

- `DictationPrewarm.warm()` (:663-666): call `AssetInventory.assetInstallationRequest(supporting:)` first and **skip** `ensureInstalled` when it is non-nil — leaving the analyzer prepare (the point of the class) intact and letting the first mic press do the visible download. No unprompted fetch at launch, matching the policy the app already states for the neural voice.
- `:704-711`: move `reservedLocale = locale` **inside** the `do`, so a genuine `AssetInventory.reserve` failure is retried on the next press instead of being recorded as success for the process lifetime.
- `:531-536`: split the guard — a non-nil recognizer with `!isAvailable` says "Speech recognition is temporarily unavailable — check your connection and try again." rather than "isn't available on this Mac."
- `NarrationVoice.swift:848-854` (`.notInstalled` branch): add `Button("Download") { voice.install() }`. Do **not** relax `wasInstalledPreviously` in `loadNeuralVoiceIfNeeded` — that guard is what stops a 940 MB download starting unasked.

**Test** (`VoiceInputTests.swift`): `@Test func aFailedLocaleReservationIsRetriedOnTheNextAttempt()`; `@Test func transientUnavailabilityIsNotReportedAsUnsupportedHardware()`. (`NarrationTests.swift`): `@Test func notInstalledOffersADownloadAction()`.

---

## PART B — NEEDS A PRODUCT DECISION, OR RISKY

### 21. API-key authentication read as signed-in — M · **decision + risk**
**Merges:** `api-key-auth-reads-as-signed-out`

`CommandProbe.output` strips provider credentials unconditionally (`ClaudeCodeHarness.swift:227` → `ShellEnvironment.childEnvironment()`, `allowProviderCredentials` defaults false), so `ANTHROPIC_API_KEY` / Bedrock / Vertex users are permanently told to run `claude auth login`, which cannot help them.

**Decision:** the credential-stripping is a deliberate billing safeguard ("an override cannot route a subscription session onto metered billing"). Honouring the existing `allowAPIKeyFallback` toggle *in probes* means a probe can report ready on metered credentials.

**If yes:** thread it like `cursorAllowUnprompted` already is — add `allowAPIKeyFallback` to `HarnessRegistry.standard()` (:31-42), store on each harness, pass into `CommandProbe.output` → `childEnvironment(allowProviderCredentials:)`. One-lining `:227` does not work; `CommandProbe` has no access to the flag.
**Cheap half, do regardless (S):** relabel `SettingsView.swift:633` "Allow API-key fallback (restart required)" — the flag is read once in `OreMacApp.swift:161` at init, and the Cursor toggle two lines below already carries that suffix.

**Test:** `HarnessRepairTests.swift` `@Test func probesHonourTheAPIKeyFallbackFlag()`.

---

### 22. `ore.toml` `[agent] harness` — implement or delete — S · **decision**
**Merges:** `ore-toml-default-harness-ignored`

Parsed (`OreConfiguration.swift:121`), serialized (:214-216), written by Settings (`SettingsView.swift:1540-1554`), asserted by `CoreClientTests.swift:951` — and applied nowhere.

The proposed one-liner `configuration.defaultHarness ?? request.harness` is **backwards**: `CreateWorkspaceRequest.harness` is non-optional with a `.claudeCode` default (`CoreCommands.swift:182`, :195), so repo config would silently override an explicit user pick.

- **Implement:** make `request.harness` optional and resolve `request.harness ?? configuration.defaultHarness ?? .claudeCode` in `createWorkspace`; or resolve in `WorkspaceLaunchPlan.resolve` (:82-87) where "no user override" is knowable.
- **Delete:** remove the Settings row and the parse/serialize path. Cheapest honest option.

**Test:** `CoreClientTests.swift` `@Test func repoDefaultHarnessLosesToAnExplicitRequest()`.

---

### 23. Gate ⌘N / ⇧⌘N on readiness — S · **decision**
Part of `no-agent-installed-yields-endless-retry`. The menu items (`OreMacApp.swift:257-268`) carry no readiness gate while the welcome button does (:1020), so a user can consume a branch and a worktree before any agent exists. Gating is one `.disabled(!readiness.isReady)` — but it also removes the only route to the sheet for power users during a transient `.unknown` probe. Unit 7 already removes the dead end; take this only if you want the workspace never created.

---

### 24. Don't let ORE's own terminal kill the installer — S · **decision**, two-sided change
**Merges:** `self-update-from-ores-own-terminal`

`running_from_destination` (install.sh:186-193) matches the ORE hosting the shell the installer was typed into; `quit_running` then tears down that shell mid-run. Cheapest correct guard is app-side, not a `ps` ancestor walk (the installer is piped into `sh` and its ancestry has intervening processes):

- `Apps/OreMac/Sources/OreMac/TerminalPane.swift`: export `ORE_TERMINAL=1` into the child shell's environment.
- `install.sh:195`: `[ "${ORE_TERMINAL:-}" = 1 ] && die "This is ORE's own terminal — run the installer from Terminal.app instead."`

Decision: whether to advertise the terminal pane as unsuitable for self-update, or to make the installer detach. Nothing is damaged today (the death happens before `install_app`), so this is friction, not corruption.

---

### 25. Store version guard — S · **depends on Unit 3**
**Merges:** `no-guard-against-a-newer-database`

`Packages/OreKit/Sources/OrePersistence/OreStore.swift` after `migrate` (:63): read `PRAGMA user_version`, compare against a monotonic constant bumped with each migration in `Schema.swift`, throw a typed `OreStoreError.storeWrittenByANewerORE(found:expected:)` when the file's value is higher, then set it. `install.sh`'s `ORE_VERSION` (:25, :100-103) makes downgrade trivially reachable.

**Risk:** this error is only safe to show *after* Unit 3 — today the launch-failure path drops the user into a writable in-memory store, so adding a new throw would convert a mild downgrade into silent data loss.

**Test** (`PersistenceTests.swift`): `@Test func aStoreFromANewerOREIsRefusedRatherThanMigrated()`.

---

### 26. Long-tail diagnostics — S each, take as time allows
Batch these in one commit per file group. All low-risk, all low-impact.

| Finding | File | Change |
|---|---|---|
| `catalog-refresh-has-no-busy-state…` | `SettingsView.swift:572-575`, `AppModel.swift:3330` | `isRefreshing` flag → `ProgressView()` + disabled, matching the update button at :670-680. Leave `discoverModels`' return type alone — empty discoveries are already filtered (`InProcessCoreClient.swift:459-463`, :483-484). |
| `stale-pinned-model-id-silently-survives` | `InProcessCoreClient.swift:483-487` | Clear the saved default when the id is absent from a **non-empty** discovered catalog. Do **not** validate in `defaultModelID` — the catalog is empty before first discovery and a valid discovery-only pin would be dropped on every cold start. |
| `gh-status-is-only-an-exit-code` | `GitHubClient.swift:55-64` | Capture `gh auth status` stdout/stderr into `Status.diagnostic` so the card can name the connected host. Passing the origin host into `authenticate()` is a larger, separate change (`status()` is called with `OreHome.directory`, no repo in scope). |
| `exotic-shell-probe-flags` | `ShellEnvironment.swift:213-220` | Use the existing `loginShellPath` (:120-129) instead of reading `SHELL` directly, and derive flags from the same zsh/bash check `commandArguments(for:script:)` uses (:136-141) so an exotic shell gets one plain `-c`. **Land after Unit 4.** |
| `login-shell-probe-timeout-loses-version-managers` | `ShellEnvironment.swift` | Record a `probeFailed` flag when both attempts return nil; include it in `searchPathDescription` so the harness diagnostic says "your login shell did not answer; ORE is using a reduced PATH". |
| `alias-or-function-cli-invisible` | harness `probe()` diagnostics | On a `locate()` miss, one bounded `command -v -- <name>` through the login shell; if it answers with a non-file, append "— it exists in your shell as an alias or function, which ORE cannot launch". Do not change probe semantics. |
| `first-turn-races-the-setup-script` | `InProcessCoreClient.swift:824`, `AppModel.swift:2496` | Skip the initial-prompt send when approval was just yielded; have `approveRepositoryScripts` (:834-869) send the stashed prompt after `runScript` returns. On decline, yield a `commandFailed`-style notice from the core rather than only an app-layer `Banner`. |

**Tests:** `ShellEnvironmentTests.swift` `@Test func exoticShellsGetAPlainDashC()` and `@Test func aFailedProbeIsReportedInTheDiagnostic()`; `CoreClientTests.swift` `@Test func theFirstPromptWaitsForScriptApproval()`.

---

## PART C — CANNOT BE FIXED IN CODE

### C1. TCC grants reset on every update — needs notarization
`adhoc-signature-revokes-tcc-on-every-update`. `Apps/OreMac/Scripts/bundle.sh:139` sets `IDENTITY="-"` and `.github/workflows/release.yml:165-172` passes no `ORE_SIGNING_IDENTITY`, so every release is **ad-hoc signed**. Each update ships a new cdhash, macOS drops the TCC records keyed to the old one. No code change fixes this.

**Real fix:** a Developer ID certificate + hardened runtime + notarization, so the signing identity (not the cdhash) anchors the TCC records. That is an Apple Developer Program account and a release-process change, not a patch.

**Workaround in code (S, do it):** in `reconcilePendingRestart()` (`GitHubUpdater.swift:305`), when `completedVersion` is set and `VoiceHotkeyMonitor.shared.refreshTrust()` is false while the hotkey was enabled before, add one line to the post-update card: "This update reset ORE's Accessibility permission. Remove ORE from System Settings ▸ Privacy & Security ▸ Accessibility and add it back." Accessibility is the only genuinely durable trap — the row stays ticked while the process is untrusted. Notification authorization is keyed to the bundle identifier and survives; Microphone and Speech simply re-prompt.

### C2. DMG Gatekeeper refusal — needs notarization, plus a release-notes change  ·  **release-notes half LANDED**
`release-notes-never-mention-gatekeeper`. `.github/workflows/release.yml:236-245` creates the release with `--generate-notes` and no `--notes-file`, while `Apps/OreMac/Scripts/certify-release.sh:116-130` emits exactly the right Gatekeeper paragraph for the ad-hoc case. The two publishing channels disagree.

**Release-process fix (do now):** add a step after `gh release create` that appends the paragraph — `gh release edit "v$VERSION" --notes-file` with the generated notes plus the ad-hoc paragraph lifted from `certify-release.sh:119-122`, so the text lives in one place. Keeps `--generate-notes`.
**Real fix:** notarize + staple (the `release.sh:65-70` path already does this when an identity exists), after which the paragraph goes away.

### C3. Telemetry disclosure on the GUI channels — release-process / legal  ·  **cask caveats LANDED**
`brew-and-dmg-users-never-see-the-privacy-notice`. `TelemetryConsent.analyticsDefault = true` (`TelemetryFactory.swift:16-20`); the only disclosure is `install.sh:280` (unit 15 un-gates it). Homebrew and the DMG disclose nothing.

**Fix:** a `caveats` block in `packaging/homebrew/ore.rb` (three lines; Homebrew prints it after install) pointing at PRIVACY.md and `ORE_TELEMETRY=0`, and the same sentence in the release notes step from C2. Do **not** add an in-app first-run banner — it would fire on the channel that already disclosed. Whether opt-out-by-default is acceptable across all three channels is a product/legal call, not an engineering one.

### C4. Two copies from two channels
`curl-and-brew-produce-two-copies`. Unit 15 adds the warning from the curl side. The Homebrew side cannot see a `~/Applications` copy without a postflight check in `ore.rb`; adding one is a tap change, and `brew uninstall` will still only remove its own. The durable fix is a documented single recommended channel in `README.md` (currently Homebrew is listed first while `install.sh` is the one with the working self-updater story).

---

## Suggested commit order

`1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13 → 14 → 15 → 16 → 17 → 18 → 19 → 20`, then C1-workaround + C2 + C3 (release/packaging), then 21–26 as decided.

Hard dependencies: **25 after 3**; **26/`exotic-shell-probe-flags` after 4**; **4 before 8** (the git probe uses `childEnvironment()`); **9 before 18** (Settings install row reads `isInstalled`, which 9 makes honest).
---

## Appendix: the 67 verified findings

Each was confirmed against the code by a verifier whose instructions were to
refute it. `evidence` is the corrected citation where the original was wrong.

| Severity | Likelihood | Dimension | Finding |
|---|---|---|---|
| major | occasional | `cli-deps` | **clt-shim-not-distinguished** — The Xcode Command Line Tools shim is treated as a working git, and ORE trips the OS install modal at launch |
| major | occasional | `cli-deps` | **harness-signin-hangs-forever** — Settings' Sign in… can hang forever with no cancel and no output |
| major | occasional | `cli-deps` | **no-git-rung-in-readiness** — The readiness ladder never checks that git works |
| major | common | `cli-deps` | **no-reprobe-on-activation** — Coming back to ORE after installing a CLI changes nothing on screen |
| major | common | `cli-deps` | **path-snapshot-never-invalidated** — The login-shell PATH is snapshotted once per app run and can never be re-probed |
| major | occasional | `cli-deps` | **unlaunchable-cli-reads-as-ready** — A CLI that cannot be executed is reported as "ready" |
| major | occasional | `first-run-ux` | **no-agent-installed-yields-endless-retry** — A workspace created without any agent installed produces "The agent hit an error" with a Retry that can never succeed and no install action |
| major | common | `first-run-ux` | **no-way-to-add-a-local-repo-from-the-onboarding-cta** — "Add project…" opens the one-sentence composer, which offers no way to pick an existing folder on this Mac |
| major | common | `first-run-ux` | **non-repo-folder-accepted-as-project** — Any folder can be added as a "project"; it is only rejected later, as a raw git error, after the workspace has already been attempted |
| major | occasional | `install-launch` | **database-failure-shows-raw-error-and-silently-loses-work** — A store that won't open shows a raw error with no path or remedy, while the app stays usable on a store that evaporates |
| major | common | `neural-models` | **assistant-voice-errors-are-silently-swallowed** — Hands-free assistant discards every voice error: the hotkey just stops working with no message |
| major | common | `neural-models` | **no-escape-from-a-denied-permission** — Denied microphone or speech permission is a permanent dead end — no System Settings link anywhere |
| major | common | `permissions-env` | **add-repository-accepts-any-directory** — Adding a folder that isn't a readable git repo succeeds silently and creates a phantom project |
| major | occasional | `permissions-env` | **api-key-auth-reads-as-signed-out** — A user authenticated by ANTHROPIC_API_KEY is permanently stuck on readiness rung 1 |
| major | occasional | `updates` | **no-preflight-writability-check-before-quitting** — The app quits and kills every running agent before anything checks the install destination is writable |
| major | occasional | `updates` | **no-schema-version-silent-inmemory-store** — A store ORE cannot open drops the app into a throwaway in-memory database that still lets the user do real work |
| minor | occasional | `cli-deps` | **alias-or-function-cli-invisible** — A CLI provided by a shell alias or function is reported as "not found on PATH" with no hint |
| minor | common | `cli-deps` | **blank-welcome-while-probing** — While probes run the welcome screen shows nothing, and a hung probe leaves it blank forever |
| minor | occasional | `cli-deps` | **codex-auth-from-file-existence** — Codex is called signed in because a credentials file exists |
| minor | occasional | `cli-deps` | **exotic-shell-probe-flags** — The PATH probe ignores the shell-awareness the same file already implements |
| minor | rare | `cli-deps` | **generic-agent-executable-name** — Cursor's CLI is looked up under the generic name `agent`, and any binary of that name is adopted |
| minor | occasional | `cli-deps` | **gh-status-is-only-an-exit-code** — gh problems all collapse into "Connect GitHub", and Connect is hardcoded to github.com |
| minor | common | `cli-deps` | **git-identity-probe-bypasses-path** — The git-identity probe is the one launch that ignores the login-shell PATH |
| minor | common | `cli-deps` | **install-command-only-for-claude** — "CLI not found" never comes with an install command, and the welcome card only ever offers Claude Code's |
| minor | occasional | `cli-deps` | **login-shell-probe-timeout-loses-version-managers** — A background process started by an rc file silently kills the PATH probe |
| minor | occasional | `first-run-ux` | **add-repository-selects-the-wrong-project-on-a-slow-store** — After Add Repository…, a fixed 400ms sleep decides what the picker selects — a slow write silently selects a different project |
| minor | rare | `first-run-ux` | **blank-welcome-when-core-start-throws** — If core start() throws before the harness probe is spawned, the welcome screen is permanently blank — no card, no button, no error |
| minor | common | `first-run-ux` | **first-launch-talks-over-the-next-step** — The very first launch speaks a greeting aloud and covers the next-step card with a dimming overlay, alongside the notification permission dialog |
| minor | occasional | `first-run-ux` | **first-turn-races-the-setup-script** — On a repo with an ore.toml setup script, the first agent turn is sent while the approval dialog is still on screen — so the first build runs in an unprepared worktree |
| minor | occasional | `first-run-ux` | **install-command-assumes-npm** — The ladder's only blocking fix is an npm command, and nothing checks that npm exists |
| minor | occasional | `first-run-ux` | **no-git-rung-on-the-ladder** — git being absent or non-functional is not on the readiness ladder; the user is instead told to configure their git identity |
| minor | common | `first-run-ux` | **no-progress-between-start-and-the-workspace** — Nothing on screen acknowledges the click that creates the first workspace until the worktree is finished |
| minor | occasional | `first-run-ux` | **ore-toml-default-harness-ignored** — ore.toml's `[agent] harness` is written by Settings and parsed by the loader, but no code path ever applies it |
| minor | occasional | `first-run-ux` | **worktree-failures-are-raw-git-with-no-recovery** — Worktree creation failures reach the user as a raw git command line in a dismissible banner, with no retry and no repair action |
| minor | common | `install-launch` | **brew-and-dmg-users-never-see-the-privacy-notice** — Two of the three install channels enable analytics without ever showing the disclosure |
| minor | occasional | `install-launch` | **curl-and-brew-produce-two-copies** — Nothing detects an existing ORE.app in the other location, so curl-then-brew (or brew-then-curl) leaves two |
| minor | common | `install-launch` | **empty-welcome-screen-with-no-recourse** — The first-run window can show an inert welcome screen with no button, no card and no error |
| minor | common | `install-launch` | **first-launch-speaks-out-loud** — ORE speaks aloud on a brand-new user's very first launch, unprompted |
| minor | rare | `install-launch` | **install-interrupt-deletes-the-app** — Ctrl-C at the wrong moment leaves no ORE.app at all, only a hidden directory |
| minor | rare | `install-launch` | **no-guard-against-a-newer-database** — An older build silently opens a database written by a newer one |
| minor | common | `install-launch` | **release-notes-never-mention-gatekeeper** — CI-published releases carry no Gatekeeper warning, so the DMG on the Releases page is a trap |
| minor | occasional | `install-launch` | **rosetta-arch-false-negative** — install.sh refuses to run on an Apple Silicon Mac from an x86_64 shell |
| minor | occasional | `install-launch` | **self-update-from-ores-own-terminal** — Running the install command inside ORE's own terminal pane kills the installer mid-run |
| minor | occasional | `install-launch` | **translocated-dmg-app-updates-nowhere** — The "running from a disk image" check misses App Translocation, so an update from a DMG-launched app fails |
| minor | occasional | `neural-models` | **asset-reservation-failure-swallowed-and-faked** — A failed AssetInventory.reserve is caught, ignored, and then recorded as if it had succeeded |
| minor | occasional | `neural-models` | **catalog-refresh-has-no-busy-state-and-no-failure-signal** — Refresh can take ~35 s with no feedback, and a catalog that failed to load is indistinguishable from a real one |
| minor | common | `neural-models` | **mic-error-invisible-when-draft-nonempty** — The composer's only visible error channel is a placeholder that the error handler itself hides |
| minor | occasional | `neural-models` | **neural-voice-stuck-in-not-installed** — An interrupted first neural-voice download leaves the setting permanently stuck with no button to restart it |
| minor | occasional | `neural-models` | **offline-reported-as-not-available-on-this-mac** — No network is reported as "English speech recognition isn't available on this Mac", and every AFAssistant error as "busy" |
| minor | common | `neural-models` | **speech-model-prewarmed-at-launch-without-consent** — The speech model is fetched at app launch, silently, on whatever connection the user is on |
| minor | occasional | `neural-models` | **stale-pinned-model-id-silently-survives** — A pinned default model that no longer exists is still sent to the CLI, while Settings displays "Agent default" |
| minor | common | `permissions-env` | **accessibility-prompt-fires-only-once-no-fallback** — The "Allow…" button is a no-op for anyone who already dismissed the Accessibility prompt |
| minor | common | `permissions-env` | **adhoc-signature-revokes-tcc-on-every-update** — Every in-app update silently revokes Microphone, Speech, Accessibility and Notification grants |
| minor | common | `permissions-env` | **global-hotkey-monitors-never-reinstalled-after-grant** — Granting Accessibility does not make the global hotkey work until ORE is relaunched, and the button never stops saying "Allow…" |
| minor | common | `permissions-env` | **launch-at-login-toggle-silently-snaps-back** — "Start ORE at login" silently flips itself off when macOS needs the user to approve the login item |
| minor | occasional | `permissions-env` | **login-shell-path-cached-for-process-lifetime** — The login-shell PATH is probed once and never invalidated, so "Refresh" cannot find a CLI installed after launch |
| minor | common | `permissions-env` | **mic-and-speech-denial-dead-end** — A denied microphone or speech-recognition grant ends in placeholder text with no way back |
| minor | common | `permissions-env` | **missing-folder-and-volume-usage-descriptions** — Info.plist has no usage strings for Documents, Desktop or removable volumes, where developers keep repos |
| minor | common | `permissions-env` | **notification-denial-is-invisible** — Denied notifications are never detected, and Settings offers a toggle that cannot grant them |
| minor | occasional | `permissions-env` | **tcc-denial-surfaces-as-raw-git-error** — A denied folder permission surfaces as a raw git banner that never mentions macOS privacy |
| minor | occasional | `updates` | **brew-installed-harness-with-no-formula-gets-curl-installer** — A Homebrew-installed harness with no known formula is upgraded with `curl \| bash`, adding a second copy behind the brew one |
| minor | rare | `updates` | **dmg-boot-update-can-orphan-the-running-app** — Updating while running from a mounted DMG can leave the user with no ORE open and nothing reopened |
| minor | rare | `updates` | **no-os-compatibility-check-old-app-deleted** — The swap script deletes the old bundle even when the new one refuses to launch |
| minor | common | `updates` | **ore-version-hardcoded-for-codex-handshake** — ORE introduces itself to Codex as version 0.1.0 forever |
| minor | common | `updates` | **self-update-oracle-mismatch-unclearable-card** — For a native/self-updating CLI install, ORE checks npm but upgrades through the CLI, so the card can come back unchanged after a "successful" update |
| minor | occasional | `updates` | **update-log-never-surfaced** — The only record of why an update failed is a log file the UI never mentions |
| minor | common | `updates` | **update-modal-reappears-every-launch** — "Later" on the ORE update modal lasts only until the app is relaunched |
