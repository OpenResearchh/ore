#!/bin/bash
# Exercises install.sh against a fake release served from the filesystem.
#
#   ./packaging/test-install.sh
#
# The installer is the one piece of ORE that runs before the app exists, on a
# Mac we have never seen, as the first thing a new user does. It also removes
# things. Both make it worth testing, and neither is testable from Swift — so
# this builds a throwaway release, points the installer at it with the hooks
# in its header, and checks what happens on the failures that matter: a
# missing manifest, missing or wrong checksums, a malformed archive.
#
# The rule every failing case checks is the same one: an install that was
# working before must still be working after.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0

ok()   { PASSED=$((PASSED + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  FAIL %s\n' "$1"; }

check() {
  local what="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$what"; else fail "$what"; fi
}

refute() {
  local what="$1"
  shift
  if "$@" >/dev/null 2>&1; then fail "$what"; else ok "$what"; fi
}

# A minimal but real app bundle: ad-hoc signed, because the installer verifies
# the signature of what it copied before it touches the existing install.
make_app() {
  local app="$1" marker="$2"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>OreMac</string>
  <key>CFBundleIdentifier</key><string>dev.ore.OreMac.test</string>
  <key>CFBundleShortVersionString</key><string>$marker</string>
</dict></plist>
PLIST
  printf '#!/bin/sh\necho %s\n' "$marker" > "$app/Contents/MacOS/OreMac"
  chmod +x "$app/Contents/MacOS/OreMac"
  codesign --force --sign - "$app" >/dev/null 2>&1
}

# A release directory laid out exactly like a GitHub release's assets.
make_release() {
  local version="$1"
  local dir="$WORK/releases/v$version"
  mkdir -p "$dir"
  make_app "$WORK/build/ORE.app" "$version"
  ( cd "$WORK/build" && /usr/bin/ditto -c -k --keepParent --sequesterRsrc ORE.app "$dir/ORE-$version.zip" )
  ( cd "$dir" && shasum -a 256 "ORE-$version.zip" > SHA256SUMS )
  printf 'version=%s\nzip=ORE-%s.zip\nsums=SHA256SUMS\n' "$version" "$version" > "$dir/RELEASE"
  cp "$dir/RELEASE" "$WORK/releases/RELEASE"
}

run_installer() {
  local install_dir="$1"
  shift
  env \
    ORE_MANIFEST="file://$WORK/releases/RELEASE" \
    ORE_DOWNLOAD_BASE="file://$WORK/releases" \
    ORE_INSTALL_DIR="$install_dir" \
    ORE_HOME="$WORK/home" \
    "$@" \
    sh "$INSTALLER"
}

installed_version() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$1/ORE.app/Contents/Info.plist" 2>/dev/null
}

# No stray staging directories may survive, successful run or not: they are
# inside the user's Applications folder.
no_leftovers() {
  [ -z "$(find "$1" -maxdepth 1 -name '.ORE.app.*' 2>/dev/null)" ]
}

echo "==> A first install"
make_release 1.0.0
DEST="$WORK/Applications"
run_installer "$DEST" >/dev/null 2>&1
check "installs the app" test -d "$DEST/ORE.app"
check "stamps the version" test "$(installed_version "$DEST")" = "1.0.0"
check "records the install channel" test "$(cat "$WORK/home/install-channel" 2>/dev/null)" = "install.sh"
check "leaves no staging directories" no_leftovers "$DEST"

echo "==> An upgrade over a working install"
make_release 1.1.0
run_installer "$DEST" >/dev/null 2>&1
check "replaces the app" test "$(installed_version "$DEST")" = "1.1.0"
check "leaves no staging directories" no_leftovers "$DEST"

echo "==> A destination whose path has spaces"
SPACED="$WORK/Applications with spaces"
run_installer "$SPACED" >/dev/null 2>&1
check "installs anyway" test "$(installed_version "$SPACED")" = "1.1.0"

echo "==> The checksums are missing"
make_release 1.2.0
rm -f "$WORK/releases/v1.2.0/SHA256SUMS"
refute "refuses to install" run_installer "$DEST"
check "keeps the working install" test "$(installed_version "$DEST")" = "1.1.0"
check "leaves no staging directories" no_leftovers "$DEST"

echo "==> The checksums do not match"
make_release 1.3.0
printf '%s  ORE-1.3.0.zip\n' "$(printf 0%.0s $(seq 64))" > "$WORK/releases/v1.3.0/SHA256SUMS"
refute "refuses to install" run_installer "$DEST"
check "keeps the working install" test "$(installed_version "$DEST")" = "1.1.0"

echo "==> The checksums do not list the app"
make_release 1.4.0
printf 'deadbeef  something-else.zip\n' > "$WORK/releases/v1.4.0/SHA256SUMS"
refute "refuses to install" run_installer "$DEST"
check "keeps the working install" test "$(installed_version "$DEST")" = "1.1.0"

echo "==> The download is missing"
make_release 1.5.0
rm -f "$WORK/releases/v1.5.0/ORE-1.5.0.zip"
refute "refuses to install" run_installer "$DEST"
check "keeps the working install" test "$(installed_version "$DEST")" = "1.1.0"

echo "==> The manifest is missing"
make_release 1.6.0
rm -f "$WORK/releases/RELEASE"
refute "refuses to install" run_installer "$DEST"
check "keeps the working install" test "$(installed_version "$DEST")" = "1.1.0"

echo "==> The archive does not contain ORE.app"
make_release 1.7.0
mkdir -p "$WORK/junk/NotOre.app"
printf 'x' > "$WORK/junk/NotOre.app/x"
( cd "$WORK/junk" && rm -f "$WORK/releases/v1.7.0/ORE-1.7.0.zip" \
  && /usr/bin/ditto -c -k --keepParent NotOre.app "$WORK/releases/v1.7.0/ORE-1.7.0.zip" )
( cd "$WORK/releases/v1.7.0" && shasum -a 256 "ORE-1.7.0.zip" > SHA256SUMS )
refute "refuses to install" run_installer "$DEST"
check "keeps the working install" test "$(installed_version "$DEST")" = "1.1.0"

echo "==> A specific version can be pinned"
make_release 1.8.0
make_release 1.9.0
run_installer "$DEST" ORE_VERSION=1.8.0 >/dev/null 2>&1
check "installs what was asked for, not the latest" \
  test "$(installed_version "$DEST")" = "1.8.0"

echo "==> An interrupt between the two renames still leaves a working install"
# install_app moves the existing bundle to .ORE.app.previous.$$ and then
# renames the new one into place. An exit in between — Ctrl-C, a closed
# terminal — used to leave the destination empty and the working copy stranded
# under a name Finder hides, which no later run would reclaim because each run
# picks a new $$.
#
# That window is two adjacent rename(2) calls, so it cannot be hit by timing a
# signal. Instead the real cleanup() is lifted out of install.sh and driven
# against the state install_app would have left behind, which is the thing the
# guard actually has to get right.
cleanup_in_state() {
  local dest="$1" previous="$2"
  ( eval "$(sed -n '/^cleanup() {/,/^}/p' "$INSTALLER")"
    TMP="" STAGED="" PREVIOUS="$previous" dest="$dest"
    cleanup )
}

STRANDED="$WORK/Stranded"
mkdir -p "$STRANDED"
make_app "$STRANDED/.ORE.app.previous.999" "0.9.0"
cleanup_in_state "$STRANDED/ORE.app" "$STRANDED/.ORE.app.previous.999"
check "puts the stranded bundle back" test -d "$STRANDED/ORE.app"
check "restores the version the user had" test "$(installed_version "$STRANDED")" = "0.9.0"
check "leaves no staging directories" no_leftovers "$STRANDED"

# The mirror case: once the swap has completed, $dest holds the *new* app and
# putting the old one back would be a silent downgrade.
SWAPPED="$WORK/Swapped"
mkdir -p "$SWAPPED"
make_app "$SWAPPED/ORE.app" "2.0.0"
make_app "$SWAPPED/.ORE.app.previous.999" "1.0.0"
cleanup_in_state "$SWAPPED/ORE.app" "$SWAPPED/.ORE.app.previous.999"
check "never downgrades an install that completed" \
  test "$(installed_version "$SWAPPED")" = "2.0.0"

echo "==> A second copy in the other Applications folder is called out"
# finish() looks in the two places an ORE can end up: /Applications, where
# Homebrew and this script both prefer to install, and ~/Applications, where
# this script falls back when /Applications is not writable. HOME is pointed
# at the work directory so the second of those is one of the installs the
# earlier cases made, rather than the tester's real home.
make_release 2.0.0
run_installer "$SPACED" HOME="$WORK" > "$WORK/dup.log" 2>&1
check "warns about the other copy" \
  grep -q "another copy of ORE is at $WORK/Applications/ORE.app" "$WORK/dup.log"
refute "does not warn about the one it just installed" \
  grep -q "another copy of ORE is at $SPACED/ORE.app" "$WORK/dup.log"

echo "==> Telemetry is disclosed on every install"
run_installer "$DEST" > "$WORK/privacy.log" 2>&1
check "names PRIVACY.md even with ORE_INSTALL_DIR set" \
  grep -q "PRIVACY.md" "$WORK/privacy.log"

echo "==> A truncated download of the script itself does nothing"
head -c 2000 "$INSTALLER" > "$WORK/partial.sh"
BEFORE="$(installed_version "$DEST")"
env ORE_INSTALL_DIR="$DEST" sh "$WORK/partial.sh" >/dev/null 2>&1
check "the install is untouched" test "$(installed_version "$DEST")" = "$BEFORE"

echo
printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
