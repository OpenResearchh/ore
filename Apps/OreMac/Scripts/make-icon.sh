#!/bin/bash
# Regenerates Resources/AppIcon.icns from Resources/AppIcon.svg.
#
#   ./Scripts/make-icon.sh
#
# The SVG is the source of truth; edit it and re-run to update the app icon.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="$ROOT/Resources/AppIcon.svg"
ICONSET="$(mktemp -d)/AppIcon.iconset"

swift "$ROOT/Scripts/render-appicon.swift" "$SVG" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
echo "Wrote $ROOT/Resources/AppIcon.icns"
