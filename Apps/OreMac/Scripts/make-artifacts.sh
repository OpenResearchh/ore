#!/bin/bash
# Packages every release artifact from one ORE.app.
#
#   ./Scripts/make-artifacts.sh [debug|release] [--no-build]
#       → .build/dist/ORE-<version>.zip
#       → .build/dist/ORE-<version>.dmg
#       → .build/dist/SHA256SUMS
#       → .build/dist/RELEASE
#
# The subdirectory is not cosmetic. SwiftPM owns `.build/release`, and macOS
# filesystems are case-insensitive by default, so a `RELEASE` manifest written
# beside it resolves to that directory: the redirection fails and the release
# goes out missing the one asset install.sh cannot proceed without.
#
# Three artifacts, one build. Everything here comes from the same $APP, so the
# zip and the dmg contain the same bytes by construction.
#
# `--no-build` packages the bundle already in .build. That is how the signed
# route gets here: release.sh has to notarize and staple the app *before* it
# is archived, so it builds, staples, and then calls this to package the very
# bundle it stapled. Both routes therefore emit the same set of files with the
# same names — which is the whole contract install.sh and the cask rely on.
#
# The zip is the one install.sh downloads: curl never sets the quarantine
# xattr, so an app unpacked from it launches without the Gatekeeper prompt a
# browser download would earn.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="release"
BUILD=1
for argument in "$@"; do
  case "$argument" in
    debug|release) CONFIGURATION="$argument" ;;
    --no-build) BUILD=0 ;;
    *) echo "usage: $0 [debug|release] [--no-build]" >&2; exit 2 ;;
  esac
done

APP="$ROOT/.build/ORE.app"
OUT="$ROOT/.build/dist"

if [[ "$BUILD" -eq 1 ]]; then
  "$ROOT/Scripts/bundle.sh" "$CONFIGURATION"
elif [[ ! -d "$APP" ]]; then
  echo "error: --no-build needs an existing $APP" >&2
  exit 1
fi

# The signature is checked here as well as in bundle.sh, because --no-build
# means something happened to the bundle in between: notarization, stapling,
# and whatever else a future step adds. Archiving a bundle whose seal is
# already broken produces a download that fails on every user's Mac.
echo "==> Verifying the bundle"
codesign --verify --deep --strict --verbose=2 "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "0.1.0")"

mkdir -p "$OUT"

ZIP="$OUT/ORE-$VERSION.zip"
DMG="$OUT/ORE-$VERSION.dmg"
SUMS="$OUT/SHA256SUMS"
MANIFEST="$OUT/RELEASE"

echo "==> Zipping ORE-$VERSION.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"

echo "==> Building ORE-$VERSION.dmg"
STAGE_ROOT="$(mktemp -d)"
trap 'rm -rf "$STAGE_ROOT"' EXIT
STAGE="$STAGE_ROOT/ORE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/ORE.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "ORE" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null

# Checksums are relative to .build so `shasum -c SHA256SUMS` works from a
# directory holding just the downloaded assets, which is what install.sh does.
echo "==> Checksums"
(cd "$OUT" && shasum -a 256 "ORE-$VERSION.zip" "ORE-$VERSION.dmg" > "$(basename "$SUMS")")

# The one asset whose name never changes.
#
# install.sh used to ask the GitHub API for the latest release and read the
# asset URLs out of the JSON: unauthenticated, rate-limited, and — because it
# was two requests — able to pair one release's zip with another's checksums
# during a publish. A fixed-name manifest pins the version in a single fetch,
# and every file after it is addressed by that version.
echo "==> Manifest"
{
  echo "version=$VERSION"
  echo "zip=ORE-$VERSION.zip"
  echo "dmg=ORE-$VERSION.dmg"
  echo "sums=SHA256SUMS"
} > "$MANIFEST"

# Say it only if it is true. A failed redirection above does not stop bash from
# reaching this point, and a release that reports four files while shipping
# three fails on the user's machine instead of on ours.
for artifact in "$ZIP" "$DMG" "$SUMS" "$MANIFEST"; do
  if [[ ! -f "$artifact" ]]; then
    echo "error: $artifact was not written" >&2
    exit 1
  fi
done

echo
echo "Wrote:"
echo "    $ZIP"
echo "    $DMG"
echo "    $SUMS"
echo "    $MANIFEST"
