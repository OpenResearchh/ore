# OreKit

The headless core of [ORE](../../README.md): no AppKit, no SwiftUI. The Mac app
talks to it only through `CoreCommand` / `CoreEvent`, so everything below that
boundary builds and tests on Linux as well as macOS.

```
OreProtocol     Codable commands, events and identifiers — the API boundary
OreSupport      child processes, login-shell environment, Unix sockets
OreHarness      agent CLI drivers: Claude Code, Codex, cursor-agent
OreGit          worktrees, status watching, diffs, checkpoints, the gh CLI
OrePersistence  SQLite (GRDB): workspaces, transcripts, review state, search
OreTelemetry    the anonymous usage events described in PRIVACY.md
OreCore         one engine per workspace, plus the in-process client
ore-cli         drives the whole core from a terminal; also ORE's MCP server
```

The only external dependency is [GRDB.swift](https://github.com/groue/GRDB.swift).

## Build and test

```sh
swift build
swift test      # offline: no agent CLI, no network, no subscription
```

Requires a Swift 6 toolchain. CI runs the suite on macOS and in the
`swift:6.3` Linux container (which needs `libsqlite3-dev`). On Linux the
FSEvents status watcher is compiled out and falls back to polling.

## ore-cli

```sh
.build/debug/ore-cli doctor                      # installed CLIs, versions, login state
.build/debug/ore-cli chat --dir /tmp/scratch     # an interactive session
.build/debug/ore-cli add-repo ~/code/my-project
.build/debug/ore-cli new --repo ~/code/my-project --name "fix the login bug"
.build/debug/ore-cli say --workspace <id> --text "add a test for the parser"
.build/debug/ore-cli diff --workspace <id>
.build/debug/ore-cli git-action --workspace <id>
```

Run `ore-cli` with no arguments for the full list: `repos`, `workspaces`,
`new-project`, `turns`, `revert`, `archive`, `delete`, `search`, `record`,
`replay` and `mcp-server`. `--workspace` accepts a unique prefix of the ID and
can be omitted when there is only one workspace. State goes to `$ORE_HOME`
(default `~/ore`), the same place the app uses.

While chatting: `/interrupt`, `/mode plan`, `/allow`, `/deny`, `/quit`.

## Subscription auth

ORE never handles API keys. Each harness is the user's own installed CLI, run as
a child process with its own subscription credentials. Provider keys are
scrubbed from the child environment (`ShellEnvironment.providerCredentialKeys`)
so a key in someone's shell profile can't silently move a session onto metered
billing. `SessionConfiguration.allowAPIKeyFallback` is the only way past that,
and it defaults to off.

The environment itself comes from a login-shell probe. An app launched from
Finder inherits a `PATH` with none of the version managers developers install
their CLIs with, which is where most "works in my terminal" bugs come from.

## Golden transcripts

`Tests/OreKitTests/Fixtures/*.jsonl` are recordings of real CLI sessions. Tests
replay them through the translators and assert on the normalized events. After
upgrading a CLI, re-record and re-run:

```sh
python3 Scripts/record-fixtures.py all          # Claude Code
python3 Scripts/record-codex-fixtures.py all    # Codex
swift test
```

A protocol change then surfaces as a failing test rather than as a regression a
user finds first. Each scenario costs one short model request on the signed-in
subscription. The recorders strip the account, connected MCP servers and home
directory before writing, because the fixtures are committed — check the diff
before committing a new recording anyway.

Outbound payloads (`ClaudeControlPayload`) are tested separately: a recording
proves we read the CLI correctly and says nothing about what we write back.

## Notes on the CLI contract

Things the CLIs' `--help` doesn't tell you, learned by driving them:

- **Claude Code** `--output-format stream-json` with `--print` requires
  `--verbose`, or the process exits immediately. It appears to work without it
  only when the user's own settings happen to enable verbose.
- A permission `allow` must include `updatedInput`. Omitting it is rejected as a
  *tool* error, so an approved edit silently doesn't happen.
- The reply to a `can_use_tool` control request must echo the CLI's
  `request_id` verbatim — a bare UUID — or the CLI blocks forever.
- An interrupted turn arrives as `result` with `subtype: error_during_execution`
  and a `terminal_reason` that varies (`aborted_streaming`, `interrupted`, …).
  The reliable marker is the `[Request interrupted by user]` text the CLI
  injects.
- `system/init` can arrive more than once in a session as MCP servers finish
  connecting, with the same session ID.
- **Codex** announces its thread twice — as the reply to `thread/start` and
  again as a notification. Reporting both reads as two sessions.
- Codex approval decisions use two vocabularies: `accept`/`decline` for the
  item-scoped methods, `approved`/`denied` for the legacy ones.
