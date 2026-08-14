#!/bin/bash
# Bumps ORE's marketing version (CFBundleShortVersionString) in Info.plist.
#
#   ./Scripts/bump-version.sh [patch|minor|major]   # default: patch
#
# CFBundleVersion (the build number) is stamped at release time from the date,
# so this only moves the human-facing X.Y.Z. Prints the new version on stdout so
# a caller (CI) can tag and release with it.
set -euo pipefail

PART="${1:-patch}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$ROOT/Resources/Info.plist"

current="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
IFS='.' read -r major minor patch <<< "$current"
major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"

case "$PART" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
  *) echo "usage: $0 [patch|minor|major]" >&2; exit 2 ;;
esac

next="$major.$minor.$patch"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $next" "$PLIST"

echo "$next"
