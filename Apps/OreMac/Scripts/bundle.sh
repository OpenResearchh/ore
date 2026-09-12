#!/bin/bash
# Builds ORE.app.
#
# SwiftPM produces a bare executable; macOS needs a bundle with an Info.plist
# before the app gets a dock icon, a menu bar, or the ability to be the active
# application. This assembles one.
#
#   ./Scripts/bundle.sh [debug|release]   → .build/ORE.app
#
# This is the *only* place a bundle is assembled. The signed release route and
# the ad-hoc one used to build their own, differently, and the two drifted:
# one stamped the version, the other didn't; one copied the icon, the other
# didn't. Everything downstream — notarization, the zip, the dmg — now starts
# from what this produces, so the two routes can only differ in the signature.
#
# Environment:
#   ORE_VERSION            stamped into CFBundleShortVersionString
#   ORE_SIGNING_IDENTITY   a Developer ID; enables hardened runtime + timestamp
#   ORE_POSTHOG_KEY        analytics key, stamped into release builds only
#
# Notarization is not done here — that needs credentials and a network round
# trip, and belongs in release.sh.
set -euo pipefail

CONFIGURATION="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "Building OreMac ($CONFIGURATION)…"
swift build -c "$CONFIGURATION" --product OreMac
swift build --package-path "$ROOT/../../Packages/OreKit" -c "$CONFIGURATION" --product ore-cli

BINARY="$(swift build -c "$CONFIGURATION" --product OreMac --show-bin-path)/OreMac"
APP="$ROOT/.build/ORE.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/OreMac"
ORE_CLI_BIN="$(swift build --package-path "$ROOT/../../Packages/OreKit" -c "$CONFIGURATION" --show-bin-path)/ore-cli"
cp "$ORE_CLI_BIN" "$APP/Contents/MacOS/ore-cli"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Debug builds get their own bundle identity. TCC records permissions per
# (bundle id, code signature); a dev build sharing `dev.ore.OreMac` with the
# installed release app — but signed with a different certificate — makes the
# system invalidate the grant every time the two alternate, which shows up as
# the same "access your Documents folder" prompt on every debug run. A
# distinct, stable id keeps both permission records intact. (Side effect: the
# dev app keeps its own UserDefaults domain, so its layout/prefs are separate
# from the installed app's — workspaces and chats come from the core database
# and are shared as before.)
if [[ "$CONFIGURATION" == "debug" ]]; then
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier dev.ore.OreMac.debug" \
    -c "Set :CFBundleName ORE Dev" \
    "$APP/Contents/Info.plist"
fi

# The version is stamped rather than read back out of the checked-in plist, so
# a release cannot disagree with the tag it was cut for.
if [[ -n "${ORE_VERSION:-}" ]]; then
  /usr/bin/plutil -replace CFBundleShortVersionString -string "$ORE_VERSION" "$APP/Contents/Info.plist"
  /usr/bin/plutil -replace CFBundleVersion -string "$(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"
fi
if [[ -n "${ORE_APPCAST_URL:-}" ]]; then
  /usr/bin/plutil -replace SUFeedURL -string "$ORE_APPCAST_URL" "$APP/Contents/Info.plist"
fi

# Build-time configuration.
#
# The PostHog project key is public-by-design — it can only write events — but
# it is still kept out of the repository and stamped only into release builds.
# Both halves of that matter now the source is public: a contributor building
# from a clean clone must not report into our project, and neither must a
# fork. With the key absent the telemetry client returns a no-op, so silence
# is the default for everyone who is not us. See PRIVACY.md.
if [[ "$CONFIGURATION" == "release" && -n "${ORE_POSTHOG_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy \
    -c "Add :OREPostHogKey string ${ORE_POSTHOG_KEY}" "$APP/Contents/Info.plist"
  if [[ -n "${ORE_POSTHOG_ENDPOINT:-}" ]]; then
    /usr/libexec/PlistBuddy \
      -c "Add :OREPostHogEndpoint string ${ORE_POSTHOG_ENDPOINT}" "$APP/Contents/Info.plist"
  fi
fi

# App icon (referenced by CFBundleIconFile). Regenerate from the SVG on demand
# so a fresh checkout still gets one.
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  "$ROOT/Scripts/make-icon.sh" || echo "note: could not build the app icon."
fi
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# SwiftPM puts each target's resources in a sibling `.bundle`. The tree-sitter
# grammars ship their highlight queries that way, so an app without them
# silently loses syntax highlighting.
BIN_DIR="$(dirname "$BINARY")"
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -e "$bundle" ]] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# Frameworks (Sparkle) live in Contents/Frameworks, and the executable needs an
# rpath pointing there. SwiftPM links against them by @rpath but has no notion
# of an app bundle, so without this the app dies at launch on a missing dylib.
FRAMEWORKS=()
while IFS= read -r framework; do FRAMEWORKS+=("$framework"); done < <(
  find "$BIN_DIR" -maxdepth 1 -name '*.framework' -type d
)
if [[ ${#FRAMEWORKS[@]} -gt 0 ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  for framework in "${FRAMEWORKS[@]}"; do
    cp -R "$framework" "$APP/Contents/Frameworks/"
  done
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/OreMac" 2>/dev/null || true
fi

# Signature: without one, macOS refuses to grant the app the permissions it
# needs (notifications, and keeping its own preferences).
#
# An ad-hoc signature carries no certificate, so the app's only identity is the
# hash of its binary — which changes on every build, taking every permission
# already granted (Screen Recording, the microphone) with it. A debug build
# therefore prefers a stable local certificate when one exists;
# `Scripts/make-signing-identity.sh` creates it.
#
# Release builds stay ad-hoc deliberately. A self-signed certificate is no
# better than ad-hoc on anyone else's Mac — it only makes the Gatekeeper
# refusal less recognizable — and real signing belongs in a pipeline with
# Developer ID credentials.
#
# `ORE_SIGNING_IDENTITY` is the same variable release.sh uses, so flipping the
# whole pipeline onto a Developer ID really is one export. `ORE_SIGN_IDENTITY`
# (no -ING) was the old name here and stays as a deprecated alias; having two
# names one letter apart for the same thing was a trap.
DEV_IDENTITY="ORE Development"
IDENTITY="-"
if [[ -n "${ORE_SIGNING_IDENTITY:-${ORE_SIGN_IDENTITY:-}}" ]]; then
  IDENTITY="${ORE_SIGNING_IDENTITY:-$ORE_SIGN_IDENTITY}"
elif [[ "$CONFIGURATION" == "debug" ]] &&
     security find-identity -v -p codesigning 2>/dev/null | grep -qF "$DEV_IDENTITY"; then
  IDENTITY="$DEV_IDENTITY"
fi

# Nothing may be added to or changed inside the bundle below this line. Every
# write after the signature — a resource, an rpath, an Info.plist key — breaks
# the seal, and the failure surfaces on the user's Mac as "damaged and can't
# be opened", not here.
sign() {
  local target="$1"
  shift
  codesign --force --sign "$IDENTITY" "$@" "$target"
}

SIGN_OPTIONS=()
# The hardened runtime is required for notarization, and a timestamp is what
# keeps the signature valid after the certificate expires. Neither is possible
# ad-hoc.
if [[ "$IDENTITY" != "-" ]]; then
  SIGN_OPTIONS=(--options runtime --timestamp)
fi

signing_failed=0
{
  # Inside out: nested code signs first, the outermost bundle last.
  if [[ -d "$APP/Contents/Frameworks" ]]; then
    while IFS= read -r -d '' nested; do
      sign "$nested" "${SIGN_OPTIONS[@]}"
    done < <(find "$APP/Contents/Frameworks" \
      \( -name '*.xpc' -o -name 'Autoupdate' -o -name 'Updater.app' \) -print0)
    for framework in "$APP/Contents/Frameworks"/*.framework; do
      [[ -d "$framework" ]] || continue
      sign "$framework" "${SIGN_OPTIONS[@]}"
    done
  fi
  sign "$APP/Contents/MacOS/ore-cli" "${SIGN_OPTIONS[@]}"
  sign "$APP" "${SIGN_OPTIONS[@]}" --entitlements "$ROOT/Resources/ORE.entitlements"
  codesign --verify --deep --strict --verbose=2 "$APP"
} || signing_failed=1

if [[ "$signing_failed" -eq 1 ]]; then
  # A debug build that will not sign still runs, and saying so beats stopping
  # someone's afternoon. A release that will not sign is not a release: it is
  # an artifact that fails on every Mac but the one that built it.
  if [[ "$CONFIGURATION" == "release" ]]; then
    echo "error: signing or verification failed — refusing to produce a release bundle." >&2
    exit 1
  fi
  echo "note: could not sign the bundle; it will still run."
elif [[ "$IDENTITY" == "-" ]]; then
  echo "Signed ad-hoc — granted permissions will not survive the next build."
else
  echo "Signed with '$IDENTITY' and verified."
fi

echo "Built $APP"
echo "Run it with: open '$APP'"
