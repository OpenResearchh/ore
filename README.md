# ORE

A native macOS app for running several coding agents in parallel, each in its
own git worktree, reviewed and steered through diffs and shipped as pull
requests without leaving the app.

Agents run on **your existing subscriptions**. ORE drives the CLIs you already
have installed and signed in — Claude Code on a Claude plan, Codex on a ChatGPT
plan — as your own local processes. It never handles API keys, and it scrubs any
provider key out of the child environment so a key in your shell profile can't
silently move a session onto metered billing.

```
Packages/OreKit/          the headless core (no AppKit, no SwiftUI)
├── OreProtocol           Codable commands and events — the API boundary
├── OreSupport            child processes, login-shell environment
├── OreHarness            agent CLI drivers: Claude Code, Codex, cursor-agent
├── OreGit                worktrees, status watching, diffs, checkpoints, gh
├── OrePersistence        SQLite via GRDB: transcripts, review state, search
├── OreCore               one engine per workspace + the in-process client
└── ore-cli               test rig: drives the whole core from a terminal

Apps/OreMac/              the Mac app — talks only to OreCore's boundary
```

## Install

```sh
brew install --cask openresearchh/tap/ore
```

or

```sh
curl -fsSL https://openresearchh.com/ore/install.sh | sh
```

macOS 14 Sonoma or later, Apple Silicon. Apache 2.0 licensed.

Both commands install an app that opens straight away. There is also a
[DMG](https://github.com/OpenResearchh/ore/releases/latest), but ORE is not
notarized by Apple yet, so macOS blocks the DMG on first open and you have to
go to **System Settings → Privacy & Security → Open Anyway**. Neither command
above has that problem, for different reasons: `curl` does not mark what it
downloads as quarantined, and Homebrew does but the cask clears the flag
after copying the app.

A release built by
[the workflow](.github/workflows/release.yml) carries a GitHub build
attestation, which you can check against the exact file you downloaded:

```sh
gh attestation verify ORE-<version>.zip -R OpenResearchh/ore
```

Releases cut locally with `Scripts/certify-release.sh` say **not attested** in
their own release notes, and that command will fail on them — there is nothing
to verify, because an attestation can only be produced where the artifact was
built. [SECURITY.md](SECURITY.md) explains what each one proves and what it
does not. Note that `spctl --assess` reporting *rejected* is the expected
result until there is a Developer ID; that is not a bug to fix.

## Privacy

ORE never sends your code, your prompts, or what the agents say anywhere. It
reports six anonymous usage events so we can tell whether it is any good — no
account, no email address, just a random ID, and no way to put a file path in
one without changing the types. Turn it off in **Settings → Privacy**, where
you can also read the exact rows queued on your Mac before they are sent.
Debug and locally built copies never report anything at all.

Two things ORE does not control. The agent CLI you choose is a separate
program on your own account, and it sends your prompts and code to its
provider — that is how it works. And macOS may transcribe dictation on
Apple's servers when this Mac has no on-device model. The complete account,
including every field in every event, is in [PRIVACY.md](PRIVACY.md).

## Try it

```sh
# The app
cd Apps/OreMac && ./Scripts/bundle.sh && open .build/ORE.app

# State lives in ~/ore; ORE_HOME points a second instance somewhere else
open .build/ORE.app --env ORE_HOME=/tmp/ore-scratch

# Or the whole core from a terminal, no UI
cd Packages/OreKit && swift build
.build/debug/ore-cli doctor
.build/debug/ore-cli add-repo ~/code/my-project
.build/debug/ore-cli new --repo ~/code/my-project --name "fix the login bug"
.build/debug/ore-cli say --workspace <id> --text "add a test for the parser"
.build/debug/ore-cli diff --workspace <id>
.build/debug/ore-cli git-action --workspace <id>
```

## What's built

**Workspaces.** Created from the default branch, a branch, a GitHub issue or PR,
or **stacked on another workspace** — the natural shape of sequential agent work.
Each gets a worktree at `~/ore/workspaces/<repo>/<slug>`, outside the repository
so it never shows up in the parent's watchers, searches or `.gitignore`.
Gitignored files named in `ore.toml` are copied in, and a `.context/` scratch
directory is created and excluded from git. Archiving preserves uncommitted work
on a ref; unarchiving puts it back.

**Agents.** Claude Code and Codex, both verified end to end against live CLIs:
streaming text and thinking, tool calls, permission prompts answered both ways,
interrupt mid-turn, resume, and fork. cursor-agent ships experimental behind a
flag with honestly reduced capabilities (see below). A `HarnessCapabilities`
record drives per-harness degradation, so a missing capability greys out a
control rather than breaking a screen.

**Review.** Live git status (FSEvents, debounced, with a 10s poll backstop and a
generation counter), unified diffs against the merge base including untracked
files, and **comment-on-diff** — a comment carries its file, line range and
surrounding code straight to the agent, which is far more precise than
describing the problem in prose.

**Checkpoints.** Snapshotted at turn boundaries into `refs/ore/ckpt/`, built
against a temporary index so your own index and HEAD are never touched.
Reverting restores the tree *and* forks the conversation back to the same
instant — files created after the checkpoint are removed, ignored files never
are.

**Shipping.** `SuggestedGitAction` computes the single next step to merge —
commit → push → PR → fix CI → merge — and is stack-aware: a PR targets its
parent branch, merging is withheld until lower PRs land, and a merged parent
triggers a retarget. Failing CI goes to the agent in one click rather than to a
browser tab.

**Search.** FTS5 over every transcript. With several agents running, "which
workspace was I doing the migration in?" stops being answerable from memory.

**Reading.** Agent replies render as markdown — headings, lists, task lists,
inline code, and fenced blocks with tree-sitter syntax highlighting. Diffs are
highlighted too. Anything without a bundled grammar falls back to a regex pass
rather than to nothing, because unhighlighted code in an app for reading code is
worse than approximate highlighting.

**Terminal.** A real shell per workspace, rooted in its worktree, with ⌘R
running the `run` script from `ore.toml` and any `localhost` URL the output
mentions turned into a button. The terminal is owned by a registry rather than
by the view hierarchy, so navigating away doesn't kill the process — a dev
server keeps running while you read the diff.

**Updates.** The in-app GitHub updater installs whatever is published as a
Release. It copies the new bundle in beside the old one, verifies its
signature, and only then swaps — the app you were running is kept until the
replacement is known to work, so a failed update leaves you where you started.

Master is the source of truth, and a release is explicit rather than a side
effect of merging. The
[release workflow](.github/workflows/release.yml) is the preferred route: it
runs both suites, builds, attests, publishes as a draft, and only promotes
after checking every asset downloads anonymously and the attestation verifies.
`Scripts/certify-release.sh` does the same from a Mac, without attestations:

```sh
cd Apps/OreMac && ./Scripts/certify-release.sh        # patch
cd Apps/OreMac && ./Scripts/certify-release.sh minor
```

Both routes produce the same four files — `ORE-<version>.zip`,
`ORE-<version>.dmg`, `SHA256SUMS`, and a fixed-name `RELEASE` manifest the
installer reads to pin a version in one request. `Scripts/release.sh` adds
Developer ID signing, notarization and stapling on top of the same bundle and
the same packaging code, once a certificate is available.

## Testing

1191 tests, all offline — no CLI, no network, no subscription:

```sh
cd Packages/OreKit && swift test                   # 536: core, drivers, git, persistence
cd Apps/OreMac    && xcrun --sdk macosx swift test # 655: app logic, rendering, policy
./packaging/test-install.sh                        #  22: the installer, end to end
```

Harness drivers are tested against **golden transcripts** recorded from live
CLIs. Re-record after upgrading a CLI and re-run; a protocol change then shows
up as a failing diff instead of as a broken transcript in front of a user:

```sh
python3 Scripts/record-fixtures.py all         # Claude Code
python3 Scripts/record-codex-fixtures.py all   # Codex
```

Outbound payloads are tested separately from the fixtures. A recording proves we
*read* a CLI correctly and says nothing about what we write back — and that gap
is not hypothetical (see below).

Git and orchestration are tested against real throwaway repositories rather than
a mocked `git`. The whole reason ORE shells out to the system binary is fidelity
with the user's actual git; a mock would test our idea of git and prove nothing.

The app can screenshot itself — `ORE_SNAPSHOT=/tmp/shot.png` renders the window
to a PNG and exits. It asks the window server for its own window, so it needs no
Screen Recording permission and works headlessly. Several rendering bugs in this
codebase were found by looking at that output rather than by reading the code.

## Things the CLIs' docs don't tell you

Learned by driving them, and each one cost a real bug:

- **Claude Code** `--output-format stream-json` with `--print` *requires*
  `--verbose`, or the process exits immediately. It appears to work without it
  only when the user's own settings happen to enable verbose.
- A permission `allow` must include `updatedInput`. Omitting it is rejected as a
  *tool* error, so an approved edit silently doesn't happen.
- The reply to a `can_use_tool` request must echo the CLI's `request_id`
  verbatim — a bare UUID, not the `req_`-prefixed id you might assume.
- An interrupted turn arrives as `error_during_execution` with a
  `terminal_reason` that varies; the reliable marker is the
  `[Request interrupted by user]` text the CLI injects.
- **Codex** announces its thread twice — as the reply to `thread/start` and
  again as a notification. Reporting both reads as two sessions.
- Codex approval decisions use two vocabularies: `accept`/`decline` for the
  item-scoped methods, `approved`/`denied` for the legacy ones.
- `system/init` (Claude) can arrive more than once per session as MCP servers
  finish connecting.

## Known gaps

- **cursor-agent is experimental.** The plan assumed an ACP mode with a real
  permission channel; the shipping CLI (2026.04) has none, so its only
  machine-readable interface streams output with no way to answer a prompt. It
  therefore declares `permissionModel: .none` and requires explicit opt-in to
  run unprompted, rather than quietly passing `--force`. It is also the one
  driver not verified against a live CLI — this machine has no Cursor login.
- **Syntax highlighting covers Swift and JSON via tree-sitter**; everything else
  takes the regex fallback. Several official grammars (JavaScript, Python) decide
  whether to compile their external scanner using a path relative to whoever is
  *consuming* the package, so consumed from elsewhere the scanner is skipped and
  the link fails. Vendoring generated parsers to work around that costs more than
  it returns.
- **Releases are unsigned here.** Artifacts are ad-hoc signed, which is why
  the two install commands above exist and why `spctl --assess` says
  *rejected*. `Scripts/release.sh` does Developer ID signing, notarization and
  stapling on top of the same bundle every other route uses, but this machine
  has no Developer ID, so that path is written and syntax-checked rather than
  executed. Everything below the signature — the bundle, the zip, the dmg, the
  checksums, the manifest — is shared, so switching routes cannot change what
  ships.
- **Local builds sign with a self-signed certificate, if you make one.** An
  ad-hoc signature has no certificate, so the app's only identity is the hash of
  its binary — and every rebuild changes it, silently dropping permissions you
  already granted (Screen Recording, the microphone). Run
  `Scripts/make-signing-identity.sh` once and debug bundles are signed with a
  stable certificate instead, so those grants stick. Release bundles stay
  ad-hoc: a self-signed certificate buys nothing on someone else's Mac.
- **Linux is audited, not compiled.** Building it needs a second Swift toolchain
  (~1.4 GB, since Xcode's toolchain can't consume the open-source Static Linux
  SDK) and this machine had under a gigabyte free. Instead the core was audited
  for Apple-only API and the real breakage found and fixed — Objective-C
  bridging (`as NSString`) in seven places, and POSIX calls needing an explicit
  `Glibc` import. The CI workflow builds and tests OreKit on Linux on every
  push, which is the durable check regardless. `StatusWatcher` compiles out its
  FSEvents path there and falls back to polling.
