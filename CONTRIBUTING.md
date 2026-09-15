# Contributing to ORE

Thanks for helping. This guide covers setup, the conventions the codebase
relies on, and how changes reach a release.

## Setup

- macOS with **Xcode 26** (the app needs the macOS 26 SDK; it runs on macOS 14+)
- At least one agent CLI signed in if you want to try real sessions — the test
  suites don't need one

```sh
cd Apps/OreMac && ./Scripts/bundle.sh && open .build/ORE.app
```

Use `ORE_HOME=/tmp/ore-dev` to keep a development instance's state away from
your real `~/ore`. If a running copy is already open, `open` just brings it to
the front, so quit it first or use `open -n`.

## Layout

- `Packages/OreKit` is the headless core. It **must not import AppKit or
  SwiftUI**, and it must keep compiling on Linux, which CI checks.
- `Apps/OreMac` is the app. It talks to the core only through `CoreCommand` /
  `CoreEvent` via `OreCore`.
- Both packages use Swift 6 language mode with strict concurrency.

## Tests

```sh
(cd Packages/OreKit && swift test)
(cd Apps/OreMac && xcrun --sdk macosx swift test)
./packaging/test-install.sh
```

All three are offline. Please add tests with your change. Some guidelines:

- **Agent protocol changes:** re-record the golden transcripts with
  `Packages/OreKit/Scripts/record-fixtures.py` (Claude Code) or
  `record-codex-fixtures.py` (Codex). Read the resulting diff before you commit
  it, because recordings can capture details of the machine that made them.
- **Git behaviour:** test it against a real temporary repository (see
  `GitFixture`), not a mock.
- **Telemetry:** any change to what is reported must update
  [PRIVACY.md](PRIVACY.md) in the same pull request. `TelemetryPayloadTests`
  enforces the allowed keys.

## Pull requests

- Keep each PR focused, and explain *why* in the description as well as what.
- Match the style of the surrounding code, including comment density. Comments
  explain decisions the code can't.
- UI changes: include a screenshot. `ORE_SNAPSHOT=/tmp/shot.png` renders the
  window to a PNG and exits.
- Make sure both suites pass locally. [CI](.github/workflows/orekit.yml) runs
  them on every pull request, and runs OreKit on Linux too.

## Releases

`master` is always releasable, but merging doesn't cut a release on its own.
To release, a maintainer adds `release:patch`, `release:minor` or
`release:major` to the pull request before merging it. When it lands, the
[release workflow](.github/workflows/release.yml) runs both suites, bumps the
version, builds and attests `ORE-<version>.zip`, `ORE-<version>.dmg`,
`SHA256SUMS` and the `RELEASE` manifest that `install.sh` reads, publishes the
GitHub Release, and updates the Homebrew cask. It can also be run by hand from
the Actions tab.

`Apps/OreMac/Scripts/certify-release.sh` cuts the same release from a Mac,
without attestations, for when Actions isn't available.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE), the same license that covers the project.

## Reporting security issues

Please don't open a public issue. Follow [SECURITY.md](SECURITY.md).
