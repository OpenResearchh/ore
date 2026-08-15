# OreKit

The headless core of ORE. No AppKit, no SwiftUI, no external package
dependencies — the Mac app talks to it through `CoreCommand`/`CoreEvent`, and
that boundary is what keeps a hosted version of ORE possible later.

```
OreProtocol   Codable commands, events and identifiers — the API boundary
OreHarness    CLI drivers: spawn the user's agent CLI, speak its protocol
ore-cli       Test rig: drive the whole core from a terminal
```

## Status: M0 (harness proof)

Claude Code is driven end to end. Verified against `claude` 2.1.154 on a live
subscription: streaming text and thinking, tool calls and results, permission
requests answered both ways, interrupt mid-turn, and `--resume` / `--fork-session`.

Not built yet: the Codex and cursor-agent drivers, git/worktree management,
persistence, and the Mac app.

## Try it

```sh
swift build

# Which agent CLIs are installed, their versions, and login state.
.build/debug/ore-cli doctor

# A real session in a scratch directory.
.build/debug/ore-cli chat --dir /tmp/scratch --prompt "what does this repo do?"
```

While chatting: `/interrupt`, `/mode plan`, `/allow`, `/deny`, `/quit`.

## Subscription auth

ORE never handles API keys. Each harness is the user's own installed CLI, run as
a child process, carrying its own subscription credentials. Provider keys are
scrubbed from the child environment (`ShellEnvironment.providerCredentialKeys`)
so a key sitting in someone's shell profile can't silently move a session onto
metered billing — `SessionConfiguration.allowAPIKeyFallback` is the only way
past that, and it defaults to off.

The environment itself comes from a login-shell probe. An app launched from
Finder inherits a `PATH` with none of the version managers developers install
their CLIs with, which is where most "works in my terminal" bugs come from.

## Golden transcripts

`Tests/OreKitTests/Fixtures/*.jsonl` are recordings of real CLI sessions.
Tests replay them through the translator and assert on the normalized events, so
the suite needs no CLI, no network and no subscription.

After upgrading `claude`, re-record and re-run:

```sh
python3 Scripts/record-fixtures.py all
swift test
```

A protocol change then surfaces as a failing diff rather than as a regression a
user finds first. Fixtures are recorded with `--setting-sources ""` so they
don't encode one machine's settings or plugins.

Outbound payloads (`ClaudeControlPayload`) are tested separately: a recording
proves we read the CLI correctly and says nothing about what we write back. That
gap is not hypothetical — a permission `allow` missing its `updatedInput` field
is rejected by the CLI as a *tool* error, so the approved edit silently doesn't
happen.

## Notes on the CLI contract

Things the CLI's `--help` doesn't tell you, learned by driving it:

- `--output-format stream-json` with `--print` **requires** `--verbose`, or the
  process exits immediately. It appears to work without it only when the user's
  own settings happen to enable verbose.
- A permission `allow` must include `updatedInput`; it is not optional.
- The reply to a `can_use_tool` control request must echo the CLI's
  `request_id` verbatim — it is a bare UUID, and the CLI blocks forever on a
  mismatch.
- An interrupted turn arrives as `result` with `subtype: error_during_execution`
  and a `terminal_reason` that varies (`aborted_streaming`, `interrupted`, …).
  The reliable marker is the `[Request interrupted by user]` text the CLI injects.
- `system/init` can arrive more than once in a session (late-loading MCP
  servers), with the same session id.

`OreKit` is written to compile on Linux — no Apple-only API — so CI can keep the
cloud path open. That has not been exercised on a Linux toolchain yet.
