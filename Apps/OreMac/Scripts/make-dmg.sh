#!/bin/bash
# Builds ORE.app and packages it into a drag-to-install DMG.
#
#   ./Scripts/make-dmg.sh [debug|release]   → .build/ORE-<version>.dmg
#
# The bundle is ad-hoc signed (see bundle.sh), so on another Mac Gatekeeper will
# ask the user to right-click → Open the first time. Notarization belongs in a
# real release pipeline with credentials.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"

"$ROOT/Scripts/bundle.sh" "$CONFIGURATION"

APP="$ROOT/.build/ORE.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "0.1.0")"
DMG="$ROOT/.build/ORE-$VERSION.dmg"

STAGE_ROOT="$(mktemp -d)"
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

rm -rf "$STAGE_ROOT"
echo "Wrote $DMG"
echo "Open it, then drag ORE onto Applications."
