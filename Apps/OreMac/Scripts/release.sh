#!/bin/bash
# Builds a signed, notarized, stapled ORE.app and the Sparkle appcast entry.
#
#   ./Scripts/release.sh 0.2.0
#
# Everything here needs credentials this repository does not and should not
# contain. Set them in the environment:
#
#   ORE_SIGNING_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#   ORE_NOTARY_PROFILE     a keychain profile made with:
#                            xcrun notarytool store-credentials ORE_NOTARY \
#                              --apple-id you@example.com --team-id TEAMID \
#                              --password <app-specific-password>
#   ORE_SPARKLE_KEY        path to the Sparkle EdDSA private key
#   ORE_APPCAST_URL        where the appcast will be served from
#
# The script refuses to produce an unsigned "release": an app that ships to
# other people and can't be verified is worse than no release, because Gatekeeper
# blocks it in a way the user can only fix by disabling a security feature.
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <version>   (e.g. $0 0.2.0)" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/.build"
APP="$BUILD/ORE.app"
DIST="$BUILD/dist"

require() {
  if [[ -z "${!1:-}" ]]; then
    echo "error: $1 is not set — see the header of this script." >&2
    exit 1
  fi
}
require ORE_SIGNING_IDENTITY
require ORE_NOTARY_PROFILE

echo "==> Building release binary"
swift build -c release --product OreMac
swift build --package-path "$ROOT/../../Packages/OreKit" -c release --product ore-cli

echo "==> Assembling the bundle"
BINARY="$(swift build -c release --product OreMac --show-bin-path)/OreMac"
rm -rf "$APP" "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST"
cp "$BINARY" "$APP/Contents/MacOS/OreMac"
ORE_CLI_BIN="$(swift build --package-path "$ROOT/../../Packages/OreKit" -c release --show-bin-path)/ore-cli"
cp "$ORE_CLI_BIN" "$APP/Contents/MacOS/ore-cli"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The version is stamped into the bundle rather than tracked in the plist, so a
# release can't disagree with its own tag.
/usr/bin/plutil -convert xml1 -o "$APP/Contents/Info.plist" "$ROOT/Resources/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"
if [[ -n "${ORE_APPCAST_URL:-}" ]]; then
  /usr/bin/plutil -replace SUFeedURL -string "$ORE_APPCAST_URL" "$APP/Contents/Info.plist"
fi

# Sparkle ships helper tools and an XPC service that must be inside the bundle
# and signed as part of it.
SPARKLE_FRAMEWORK="$(find "$BUILD/release" -maxdepth 4 -name 'Sparkle.framework' -type d | head -1 || true)"
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"
fi

echo "==> Signing"
# Nested code signs first, outermost last; the hardened runtime is required for
# notarization.
if [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]]; then
  find "$APP/Contents/Frameworks/Sparkle.framework" \
    \( -name '*.xpc' -o -name 'Autoupdate' -o -name 'Updater.app' \) -print0 |
    while IFS= read -r -d '' nested; do
      codesign --force --options runtime --timestamp \
        --sign "$ORE_SIGNING_IDENTITY" "$nested"
    done
  codesign --force --options runtime --timestamp \
    --sign "$ORE_SIGNING_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
fi

codesign --force --options runtime --timestamp \
  --sign "$ORE_SIGNING_IDENTITY" "$APP/Contents/MacOS/ore-cli"

codesign --force --options runtime --timestamp \
  --entitlements "$ROOT/Resources/ORE.entitlements" \
  --sign "$ORE_SIGNING_IDENTITY" "$APP"

echo "==> Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Creating the archive"
ARCHIVE="$DIST/ORE-$VERSION.zip"
/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$APP" "$ARCHIVE"

echo "==> Notarizing (this waits for Apple)"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$ORE_NOTARY_PROFILE" --wait

echo "==> Stapling"
# The ticket is stapled to the app, then the app is re-archived, so a user who
# downloads it offline still passes Gatekeeper.
xcrun stapler staple "$APP"
rm -f "$ARCHIVE"
/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$APP" "$ARCHIVE"
xcrun stapler validate "$APP"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$APP"

if [[ -n "${ORE_SPARKLE_KEY:-}" ]]; then
  echo "==> Signing the appcast entry"
  SIGN_TOOL="$(find "$BUILD" -name 'sign_update' -type f -perm -u+x | head -1 || true)"
  if [[ -n "$SIGN_TOOL" ]]; then
    SIGNATURE="$("$SIGN_TOOL" "$ARCHIVE" -f "$ORE_SPARKLE_KEY")"
    echo "$SIGNATURE" > "$DIST/ORE-$VERSION.signature"
    echo "    $SIGNATURE"
  else
    echo "    note: Sparkle's sign_update tool wasn't found in .build; run it manually." >&2
  fi
fi

echo
echo "Release ready: $ARCHIVE"
echo "Add the entry above to your appcast.xml and publish both."
