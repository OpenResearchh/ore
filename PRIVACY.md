# Privacy

ORE runs coding agents against your source code. That means it sees everything
you would least want leaked, so the rule this document exists to state is
simple:

**ORE never sends your code, your prompts, or what the agents say anywhere.**

Two honest qualifications to that, both covered in detail below. The coding
agent you choose is a separate program with its own account and its own
privacy policy, and it sends your prompts and code to its provider — that is
how it works, and it is outside ORE. And if you dictate, macOS may transcribe
the audio on Apple's servers rather than on your Mac.

ORE itself collects a small amount of anonymous usage data so we can tell
whether the product is any good. This page is the complete description of it.
If you would rather send nothing, **Settings → Privacy → turn off "Share
anonymous usage data"**, and ORE goes silent immediately.

## What is never collected

Not sampled, not hashed, not truncated. There is no code path that sends any
of these anywhere:

- Prompt text, or anything you type into ORE
- Anything an agent says, thinks, or writes
- Diffs, patches, or file contents
- File paths and file names
- Repository names, branch names, commit messages, PR titles
- Your API keys or the credentials of any agent CLI
- Your IP address is not retained
- Any device fingerprint

This is enforced by the type system, not by good intentions. Every event is a
case of a closed Swift enum, and no property can hold a free-form string —
values must be a number, a flag, or a token from a fixed vocabulary. There is
literally no way to pass a file path into a telemetry payload without changing
the type definitions.

You do not have to take our word for it. The whole surface is one file:

- [`TelemetryEvent.swift`](Packages/OreKit/Sources/OreTelemetry/TelemetryEvent.swift) — every event that exists
- [`TelemetryPayloadTests.swift`](Packages/OreKit/Tests/OreKitTests/TelemetryPayloadTests.swift) — tests that build every event from deliberately hostile values (a fake home directory path, a branch name, a commit message) and assert none of it survives into a payload

And in the app: **Settings → Privacy → Show pending events** prints the exact
rows queued on your machine, before they are sent.

## What is collected

Six events. That is the entire list, and it is the same list the code can
produce — a test asserts these exact names against `TelemetryEvent`, so this
table cannot drift from reality without the build failing.

| Event | When | Properties |
|---|---|---|
| `app_installed` | Once ever, on first run | how you installed (curl, Homebrew, DMG) |
| `app_launched` | Each launch | cold or post-update, how long since you installed (bucketed) |
| `workspace_created` | You start a workspace | which agent, whether it was your first |
| `turn_completed` | An agent finishes a turn | which agent, model family, succeeded/failed/interrupted, roughly how long (bucketed), whether it was your first |
| `pull_request_created` | A PR you opened from ORE appears | whether it was your first |
| `telemetry_opt_out` | You turn this off | nothing — see "Turning it off" |

Every event also carries: ORE's version, your macOS version, your Mac's
architecture, how you installed ORE, a random session ID, and your install ID.

Every event also carries two instructions for the analytics server: do not
store the IP address this arrived from, and do not look up a location from
it. That is what makes "your IP address is not retained", above, true.

Durations and counts are always reported as **buckets** ("1–5 minutes"), never
exact values. Precise numbers are a fingerprinting surface; buckets answer the
same product questions with far less identifying signal.

## Who you are, as far as ORE is concerned

A random UUID, generated on your machine the first time you run ORE and stored
in `~/ore/`. That is the whole identity system. There is no account, no email
address, and no login.

The ID lives in `~/ore/` rather than inside the app so that reinstalling ORE
does not make you look like a brand-new person. Delete that directory and you
are a new, equally anonymous user.

There is no identifying field anywhere in this system. ORE uses the `gh` CLI
you have already authenticated to clone repositories and open pull requests,
and it never reads your token, your username, or your GitHub user ID into
analytics.

## What other programs do

ORE drives coding agents that you install and sign in to yourself — Claude
Code, Codex, cursor-agent. Each is a separate program with its own account,
and each sends your prompts and the code it reads to its own provider. That
is what a coding agent is; ORE is not a party to it and cannot make promises
about it. Read the privacy policy of whichever you use.

Dictation goes through macOS's speech recognition. ORE asks for the on-device
model and uses it whenever this Mac offers one, but when it does not, macOS
falls back to Apple's speech service and the audio is transcribed on Apple's
servers. ORE never receives, stores, or forwards the audio either way.

Everything else is local: agent output, narration summaries, the assistant,
and your whole workspace history live in `~/ore/` on this Mac.

## Other network requests

ORE makes a few requests of its own. None of them carries your code, your
prompts, or anything that identifies you:

- **App updates.** ORE asks GitHub's Releases API for the latest version —
  through your signed-in `gh` CLI when there is one, anonymously otherwise.
- **Agent CLI updates.** To tell you when Claude Code, Codex or cursor-agent is
  out of date, ORE looks up the latest version of that package on the npm
  registry or Homebrew's formulae API, depending on how it was installed.
- **Scientist profiles.** Workspaces are named after scientists. ORE fetches
  that person's Wikipedia summary to show alongside the name and caches it on
  disk; the request contains only the scientist's name.
- **HTML previews.** A page you open in the review pane's Preview loads
  whatever it references — stylesheets, scripts, images — the way a browser
  would, including from the internet. Links you click open in your browser.
- **Voice models.** When ORE uses its neural narration voice, the FluidAudio
  library downloads the model weights once and caches them under
  `~/Library/Caches`.

## Where it goes

[PostHog](https://posthog.com) (US region), which is open source and processes
the data on our behalf. Nothing is sold, and there are no advertising or
third-party trackers in ORE.

## Turning it off

**Settings → Privacy → Share anonymous usage data.** ORE deletes everything
still queued on your machine, sends a single `telemetry_opt_out` event so the
denominator for every other number stays honest, and then stops. The queued
backlog is deleted, not uploaded on the way out — a test asserts exactly
that. Nothing is recorded afterwards, including across relaunches.

Analytics is also off automatically, with no action from you, when:

- you are running a debug or locally-built copy of ORE (so contributors and
  forks never report into our project)
- `ORE_TELEMETRY=0` is set in the environment

## Deleting your data

Copy your install ID from **Settings → Privacy** and email it to
<privacy@openresearchh.com>. Since that ID is all we hold, it is enough for us
to find and delete everything associated with you.

## Changes

This file is versioned in the repository, so `git log PRIVACY.md` is the
complete and honest history of what ORE has ever collected.
