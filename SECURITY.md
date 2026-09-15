# Security

## Is this really ORE?

Start with the honest part, because it is the part most projects fudge:

**ORE is not notarized by Apple, and nothing below changes that.** Notarization
requires a $99/year Apple Developer ID, which this project does not have yet.
Gatekeeper only trusts Apple's own signature, so if you download the DMG,
macOS will block it on first launch and you will have to go to **System
Settings → Privacy & Security → Open Anyway**. That is expected. On macOS 15
and later, right-click → Open no longer works around it.

What we can give you is **provenance**: cryptographic proof that a download
came from this repository, built from a specific commit, and has not been
modified since. That is a different guarantee from "Apple vouches for it", and
it is worth more to anyone who actually checks.

### Verifying a download

Artifacts built by
[the release workflow](.github/workflows/release.yml) are signed by GitHub's
build attestation service (backed by [Sigstore](https://sigstore.dev), with
the signature recorded in a public transparency log). That covers the zip, the
dmg and `SHA256SUMS`. If you have the `gh` CLI:

```sh
gh attestation verify ORE-<version>.zip -R OpenResearchh/ore
```

A pass tells you the file was produced by this repository's release workflow,
from a named commit, and is byte-identical to what that build produced. There
is no key for us to lose or leak, and no key for you to fetch.

**Not every release is attested.** An attestation can only be produced where
the artifact is built, so a release cut from a maintainer's Mac with
`Apps/OreMac/Scripts/certify-release.sh` has none — `gh attestation verify` will fail on
it, and that is the correct answer rather than a problem with your setup.
Those releases say **not attested** in their own release notes. A Developer ID
signature, when there is one, is not a substitute: it says who signed the
file, not what it was built from.

Every release ships `SHA256SUMS`:

```sh
shasum -a 256 -c SHA256SUMS
```

That only proves the download was not corrupted in transit. `install.sh`
checks it for you and refuses to install if the file is missing or does not
match. Where an attestation exists it is the meaningful check.

Release tags are lightweight and **not** GPG-signed, so GitHub shows no
Verified badge; the attestation is what ties an artifact to a commit.

### The strongest option

The source is public. If you want certainty rather than a chain of trust,
build it yourself:

```sh
git clone https://github.com/OpenResearchh/ore && cd ore/Apps/OreMac
./Scripts/bundle.sh release
```

### Why `curl | sh` is the default install

Piping a script to a shell deserves suspicion, so here is the reasoning.

macOS applies the `com.apple.quarantine` attribute to files downloaded by a
browser, and Gatekeeper blocks quarantined apps that lack an Apple Developer
ID signature. `curl` does not set that attribute, so an app installed this way
launches normally. This is the only way to give you a frictionless install
without the $99 fee.

The script is short, does exactly what it says, and you should read it before
running it — it is [`install.sh`](install.sh) in this repository, and the URL
on the website is a rewrite to this same file, so the two cannot drift apart.
It never uses `sudo`.

## What ORE does on your machine

ORE is deliberately **not sandboxed**: it creates git worktrees anywhere on
disk and spawns the agent CLIs you have already installed. Things worth
knowing:

- It runs `claude`, `codex` and `cursor-agent` as **you**, with your
  permissions. ORE does not sandbox them beyond the permission mode you pick
  per workspace.
- Provider API keys are scrubbed from the environment handed to child
  processes, so an agent CLI uses its own stored credentials rather than
  inheriting yours.
- ORE never stores a GitHub token. All GitHub access goes through the `gh`
  CLI you authenticated yourself.
- Everything ORE persists is local. Under `~/ore/` (or `$ORE_HOME`):
  - the database `ore.sqlite`
  - the worktrees in `workspaces/`
  - new and cloned projects in `repositories/`
  - the assistant's own workspace in `assistant/`, including its bridge socket
    `assistant/.bridge.sock` (in `$TMPDIR` when that path is too long for a
    socket)
  - cached scientist profiles and portraits in `scientists/`
  - agent CLI discovery results in `harness-cache.json`
  - the in-app updater's log, `update.log`
  - the anonymous analytics queue `telemetry.sqlite` and the
    `install-channel` marker

  Outside it: neural voice model weights in `~/.cache/fluidaudio`, synthesized
  narration phrases in `~/Library/Caches/dev.ore.OreMac`, and preferences in
  the `dev.ore.OreMac` defaults domain.

For what ORE reports about usage, see [PRIVACY.md](PRIVACY.md).

## Reporting a vulnerability

Email <security@openresearchh.com> rather than opening a public issue. Please
include what you did, what happened, and how bad you think it is. We will
acknowledge within 72 hours.

Especially interested in: anything that lets an agent escape the permission
mode it was given, anything that exfiltrates code or credentials, and anything
that lets a malicious repository run code at clone or index time.
