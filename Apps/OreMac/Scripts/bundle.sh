#!/bin/bash
# Builds ORE.app.
#
# SwiftPM produces a bare executable; macOS needs a bundle with an Info.plist
# before the app gets a dock icon, a menu bar, or the ability to be the active
# application. This assembles one.
#
#   ./Scripts/bundle.sh [debug|release]   → .build/ORE.app
#
# Signing and notarization are not done here — that belongs in a release
# pipeline with real credentials. This produces an ad-hoc signed bundle, which
# is enough to run locally.
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

# Ad-hoc signature: without one, macOS refuses to grant the app the permissions
# it needs (notifications, and keeping its own preferences).
codesign --force --sign - "$APP" >/dev/null 2>&1 || \
  echo "note: could not sign the bundle; it will still run."

echo "Built $APP"
echo "Run it with: open '$APP'"
