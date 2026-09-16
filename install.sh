#!/bin/sh
# ORE installer.
#
#   curl -fsSL https://openresearchh.com/ore/install.sh | sh
#
# Why this exists rather than a DMG: ORE is signed ad-hoc, not with an Apple
# Developer ID. Gatekeeper blocks ad-hoc signed apps that carry the
# com.apple.quarantine xattr, and since macOS 15 the old right-click → Open
# escape hatch no longer clears it — the user has to go digging in System
# Settings. But quarantine is applied by the *downloader*, and curl does not
# set it. An app installed by this script therefore launches with no prompt at
# all. That is the whole trick.
#
# Deliberately POSIX sh with no jq and no python3. Neither is guaranteed on a
# bare macOS install, and a dependency check is a worse first impression than
# a few lines of sed.
#
# Everything lives inside main(), called on the last line. A script piped into
# sh is executed as it arrives, so a connection that drops halfway through
# would otherwise run the first half — which, in an installer, is the half
# that removes things. Nothing runs until the whole file has been read.
#
# Testing hooks:
#   ORE_MANIFEST       URL (file:// works) of the release manifest to use
#   ORE_VERSION        install this version instead of the published latest
#   ORE_INSTALL_DIR    install here instead of /Applications or ~/Applications
#   ORE_REPO           GitHub owner/name to install from
#   ORE_DOWNLOAD_BASE  base URL release assets are downloaded from
#   ORE_HOME           where the install channel marker is written (~/ore)
set -eu

main() {
  REPO="${ORE_REPO:-OpenResearchh/ore}"
  DOWNLOAD_BASE="${ORE_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download}"
  MANIFEST_URL="${ORE_MANIFEST:-https://github.com/$REPO/releases/latest/download/RELEASE}"
  MIN_MACOS_MAJOR=14

  TMP=""
  STAGED=""
  PREVIOUS=""
  # An interrupt has to stop the script, not just run cleanup and carry on
  # with a staged app that cleanup has already deleted. Exiting fires EXIT.
  trap cleanup EXIT
  # SIGHUP too: closing the terminal window mid-install is exactly the moment
  # the destination is a rename away from holding nothing.
  trap 'exit 130' INT TERM HUP

  check_platform
  resolve_release
  download
  unpack
  choose_destination
  quit_running
  install_app
  finish
}

say()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

cleanup() {
  # First, because it is the only step that can put back something the user
  # had. install_app moves the existing bundle aside and then renames the new
  # one into place; an exit between those two renames — an interrupt, a closed
  # terminal — leaves the destination empty and the working install stranded
  # under a dot-prefixed name Finder hides. The next run picks a new $$, so
  # nothing would ever reclaim it. Guarded on the destination still being
  # empty: if the swap did complete, $PREVIOUS is the old version and putting
  # it back would be a downgrade.
  if [ -n "${PREVIOUS:-}" ] && [ -d "$PREVIOUS" ] && [ ! -e "${dest:-}" ]; then
    mv "$PREVIOUS" "$dest" 2>/dev/null || true
  fi
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
  # A staging copy left inside /Applications is confusing rubbish; the real
  # install is either in place by now or was never touched.
  [ -n "${STAGED:-}" ] && [ -d "$STAGED" ] && rm -rf "$STAGED"
  return 0
}

# ---------------------------------------------------------------- platform

check_platform() {
  [ "$(uname -s)" = "Darwin" ] || die "ORE is a macOS app; this is $(uname -s)."

  macos_version="$(sw_vers -productVersion 2>/dev/null || echo 0)"
  macos_major="${macos_version%%.*}"
  if [ "$macos_major" -lt "$MIN_MACOS_MAJOR" ] 2>/dev/null; then
    die "ORE needs macOS $MIN_MACOS_MAJOR (Sonoma) or later; this is $macos_version."
  fi

  # ORE currently ships an arm64-only build. Installing it on an Intel Mac
  # produces an app that cannot launch at all, which is a far worse outcome
  # than refusing here with an explanation.
  #
  # `uname -m` alone is not the machine: under Rosetta 2 it reports x86_64 on
  # an Apple Silicon Mac, so a translated shell — an x86_64 copy of Terminal,
  # `arch -x86_64 zsh`, a session inherited from an Intel toolchain — got told
  # its M-series Mac was an Intel one and was left with no route in but the
  # DMG, the one channel with the Gatekeeper problem. sysctl.proc_translated
  # is the signal that survives translation; hw.optional.arm64 is masked by it.
  arch="$(uname -m)"
  if [ "$arch" != "arm64" ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" != "1" ]; then
    die "ORE currently requires Apple Silicon (M1 or later); this Mac is $arch.
    Intel support is not built yet. Follow https://github.com/$REPO for news."
  fi
}

# ---------------------------------------------------------------- release

# One fixed-name file names every other file.
#
# This used to read the GitHub API's latest-release JSON: unauthenticated and
# rate-limited, so a shared office IP could turn the install into a 403. Worse,
# the zip and the checksums were two separate lookups, and a release published
# between them paired one version's app with another's checksums. The manifest
# pins a version in a single fetch and everything after it is addressed by
# that version.
resolve_release() {
  TMP="$(mktemp -d)"

  if [ -n "${ORE_VERSION:-}" ]; then
    version="$ORE_VERSION"
    say "==> Installing ORE $version"
  else
    say "==> Looking up the latest release"
    curl -fsSL "$MANIFEST_URL" -o "$TMP/RELEASE" \
      || die "could not fetch the release manifest from $MANIFEST_URL"
    version="$(manifest_value version)"
    [ -n "$version" ] || die "the release manifest names no version."
    say "    $version"
  fi

  tag="v${version#v}"
  version="${version#v}"
  zip_name="ORE-$version.zip"
  zip_url="$DOWNLOAD_BASE/$tag/$zip_name"
  sums_url="$DOWNLOAD_BASE/$tag/SHA256SUMS"
}

manifest_value() {
  sed -n "s/^$1=//p" "$TMP/RELEASE" | head -1
}

# ---------------------------------------------------------------- download

download() {
  say "==> Downloading"
  curl -fSL --progress-bar "$zip_url" -o "$TMP/$zip_name" \
    || die "could not download $zip_name from $zip_url"

  # Fail closed. The checksum only proves the transfer wasn't corrupted — TLS
  # to GitHub already covers tampering — but "couldn't check" and "checked and
  # fine" are not the same outcome, and a missing SHA256SUMS means the release
  # is malformed. Skipping the check on a download error is how a truncated
  # file gets installed.
  #
  # For real provenance:
  #   gh attestation verify <zip> -R OpenResearchh/ore
  say "==> Verifying checksum"
  curl -fsSL "$sums_url" -o "$TMP/SHA256SUMS" \
    || die "could not download SHA256SUMS for $version — refusing to install unverified."
  grep " $zip_name\$" "$TMP/SHA256SUMS" > "$TMP/expected.txt" \
    || die "SHA256SUMS for $version does not list $zip_name — refusing to install."
  ( cd "$TMP" && shasum -a 256 -c expected.txt >/dev/null ) \
    || die "checksum mismatch for $zip_name — refusing to install."
}

# ---------------------------------------------------------------- unpack

unpack() {
  say "==> Unpacking"
  /usr/bin/ditto -x -k "$TMP/$zip_name" "$TMP/unpacked" || die "could not unpack $zip_name."
  app_src="$TMP/unpacked/ORE.app"
  [ -d "$app_src" ] || die "the archive did not contain ORE.app."

  # Belt and braces. curl should not have set this, but a proxy, a corporate
  # MDM, or a future change to how the file arrives could.
  xattr -dr com.apple.quarantine "$app_src" 2>/dev/null || true
}

# ---------------------------------------------------------------- destination

choose_destination() {
  # Never sudo. A root-owned /Applications/ORE.app cannot be replaced by the
  # in-app updater — which runs as the user — so the app would silently stop
  # being able to update itself, forever. An unwritable /Applications means
  # ~/Applications is the correct answer, not escalation.
  if [ -n "${ORE_INSTALL_DIR:-}" ]; then
    dest_dir="$ORE_INSTALL_DIR"
    mkdir -p "$dest_dir"
  elif [ -w /Applications ]; then
    dest_dir="/Applications"
  else
    dest_dir="$HOME/Applications"
    mkdir -p "$dest_dir"
  fi
  dest="$dest_dir/ORE.app"
}

# ---------------------------------------------------------------- quit running

quit_running() {
  # Only the copy being replaced. A build running from somewhere else — a
  # checkout, a second install, ORE itself running this script — has nothing
  # to do with this destination, and quitting it is both surprising and, for
  # an app whose whole job is long-running agent work, expensive.
  running_from_destination() {
    for pid in $(pgrep -x OreMac 2>/dev/null); do
      case "$(ps -p "$pid" -o comm= 2>/dev/null)" in
        "$dest"/*) return 0 ;;
      esac
    done
    return 1
  }

  running_from_destination || return 0
  say "==> Quitting the running copy of ORE"
  osascript -e "tell application \"$dest\" to quit" >/dev/null 2>&1 || true
  waited=0
  while running_from_destination && [ "$waited" -lt 25 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if running_from_destination; then
    for pid in $(pgrep -x OreMac 2>/dev/null); do
      case "$(ps -p "$pid" -o comm= 2>/dev/null)" in
        "$dest"/*) kill "$pid" 2>/dev/null || true ;;
      esac
    done
    sleep 3
  fi
  running_from_destination && die "ORE is still running; quit it and re-run."
  return 0
}

# ---------------------------------------------------------------- install

# The existing app is not removed until the new one is in place and verified.
#
# The old order was `rm -rf "$dest"` and then ditto, which meant a full disk,
# a permissions problem or a machine going to sleep took away the working
# install and left nothing behind. Everything now happens on the destination
# volume — a copy across volumes is what makes the final move slow enough to
# be interruptible — and the previous bundle is kept until the new one has
# been checked.
install_app() {
  say "==> Installing to $dest_dir"
  STAGED="$dest_dir/.ORE.app.incoming.$$"
  rm -rf "$STAGED"

  # ditto, not mv or cp: it is the only one of the three that reliably
  # preserves extended attributes and resource forks across filesystems, and
  # the app's signature lives in exactly those. It is also what the in-app
  # updater uses.
  /usr/bin/ditto "$app_src" "$STAGED" || die "could not copy ORE.app into $dest_dir."
  [ -x "$STAGED/Contents/MacOS/OreMac" ] \
    || die "the copy in $dest_dir is incomplete — leaving the existing install alone."
  codesign --verify --deep --strict "$STAGED" 2>/dev/null \
    || die "the copied app fails signature verification — leaving the existing install alone."

  # PREVIOUS rather than a function-scoped name: POSIX sh has no `local`, but
  # the point is that `cleanup` reads it, so it is declared in main() with the
  # other two and named like them.
  if [ -e "$dest" ]; then
    PREVIOUS="$dest_dir/.ORE.app.previous.$$"
    rm -rf "$PREVIOUS"
    mv "$dest" "$PREVIOUS" || die "could not move the existing ORE.app aside."
  fi

  if ! mv "$STAGED" "$dest"; then
    # Put back what was there. A failed install that leaves the Mac without
    # the app it started with is the one outcome worth this much code.
    # PREVIOUS is deliberately left set: if this restore is the one that
    # failed, $dest is still empty and cleanup gets a second attempt at it.
    # If it succeeded, cleanup's own `[ ! -e "$dest" ]` guard skips.
    [ -n "$PREVIOUS" ] && mv "$PREVIOUS" "$dest" 2>/dev/null
    die "could not move the new ORE.app into place; the previous install was restored."
  fi
  STAGED=""
  # Cleared before the delete, not after: from here on $dest holds the *new*
  # app, and a cleanup that put $PREVIOUS back would be a silent downgrade.
  old="$PREVIOUS"
  PREVIOUS=""
  [ -n "$old" ] && rm -rf "$old"

  # Tells telemetry which channel the install came from, so we can see whether
  # curl, Homebrew or the DMG actually carries adoption.
  #
  # Deliberately outside the bundle. Writing into Contents/Resources after
  # codesign breaks the signature seal ("a sealed resource is missing or
  # invalid"), and the updater replaces the whole bundle on every update, so
  # an in-bundle marker would be destroyed the first time the user upgraded.
  # ~/ore is the app's own state directory and survives both.
  ore_home="${ORE_HOME:-$HOME/ore}"
  mkdir -p "$ore_home" 2>/dev/null || true
  printf 'install.sh' > "$ore_home/install-channel" 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------- done

finish() {
  say ""
  say "ORE $version installed to $dest"

  # Homebrew installs to /Applications and this script prefers it but falls
  # back to ~/Applications, so curl-then-brew (or the reverse) leaves two
  # copies and no warning. Two ORE.apps means the Dock, Spotlight and the
  # in-app updater can each be pointing at a different one. Checked in
  # finish() rather than choose_destination() so it also covers an explicit
  # ORE_INSTALL_DIR.
  for other in "/Applications/ORE.app" "$HOME/Applications/ORE.app"; do
    if [ -e "$other" ] && [ "$other" != "$dest" ]; then
      say ""
      say "Note: another copy of ORE is at $other."
      say "      Two copies update independently. Remove that one with:"
      say "        rm -rf '$other'"
    fi
  done

  # Outside the ORE_INSTALL_DIR guard: telemetry is on by default and this is
  # the disclosure. A test install is still an install, and the sentence costs
  # one line.
  say ""
  say "What ORE measures, and how to turn it off:"
  say "  https://github.com/$REPO/blob/master/PRIVACY.md"

  if [ -z "${ORE_INSTALL_DIR:-}" ]; then
    open "$dest" 2>/dev/null || say "Open it with: open '$dest'"
    say ""
    say "Docs and source: https://github.com/$REPO"
  fi
}

main "$@"
