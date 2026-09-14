#!/bin/bash
# Builds a signed, notarized, stapled ORE.app and packages it for release.
#
#   ./Scripts/release.sh 0.2.0
#       → .build/dist/ORE-<version>.zip   (stapled)
#       → .build/dist/ORE-<version>.dmg   (stapled)
#       → .build/dist/SHA256SUMS
#       → .build/dist/RELEASE
#
# Same three artifacts, same names, same packaging code as the ad-hoc route —
# see make-artifacts.sh. The only difference is the signature and the trip to
# Apple's notary. This script used to assemble its own bundle, which is how
# the two routes ended up shipping subtly different apps.
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
# other people and can't be verified is worse than no release, because
# Gatekeeper blocks it in a way the user can only fix by disabling a security
# feature.
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

require() {
  if [[ -z "${!1:-}" ]]; then
    echo "error: $1 is not set — see the header of this script." >&2
    exit 1
  fi
}
require ORE_SIGNING_IDENTITY
require ORE_NOTARY_PROFILE

echo "==> Building and signing the bundle"
ORE_VERSION="$VERSION" "$ROOT/Scripts/bundle.sh" release

# Notarization takes an archive, not a bundle. This one is a throwaway: the
# ticket has to be stapled to the app and the app archived *again* afterwards,
# or an offline user's copy carries no ticket and Gatekeeper refuses it.
echo "==> Notarizing (this waits for Apple)"
SUBMISSION="$BUILD/notarize-$VERSION.zip"
rm -f "$SUBMISSION"
/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$APP" "$SUBMISSION"
xcrun notarytool submit "$SUBMISSION" --keychain-profile "$ORE_NOTARY_PROFILE" --wait
rm -f "$SUBMISSION"

echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$APP"

# The stapled bundle is what gets packaged — hence --no-build.
echo "==> Packaging"
"$ROOT/Scripts/make-artifacts.sh" release --no-build

ARCHIVE="$BUILD/dist/ORE-$VERSION.zip"

if [[ -n "${ORE_SPARKLE_KEY:-}" ]]; then
  echo "==> Signing the appcast entry"
  SIGN_TOOL="$(find "$BUILD" -name 'sign_update' -type f -perm -u+x | head -1 || true)"
  if [[ -n "$SIGN_TOOL" ]]; then
    SIGNATURE="$("$SIGN_TOOL" "$ARCHIVE" -f "$ORE_SPARKLE_KEY")"
    echo "$SIGNATURE" > "$BUILD/ORE-$VERSION.signature"
    echo "    $SIGNATURE"
  else
    echo "    note: Sparkle's sign_update tool wasn't found in .build; run it manually." >&2
  fi
fi

echo
echo "Release ready: $ARCHIVE"
echo "Signed, notarized and stapled. Provenance is Developer ID only —"
echo "attestations come from the release workflow, not from this Mac."
