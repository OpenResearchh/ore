#!/bin/bash
# Pre-commit certified release: run the compute here, then publish master.
#
#   ./Scripts/certify-release.sh [patch|minor|major]   # default: patch
#
# Master is what ships. This refuses to cut from a workspace branch or a dirty
# tree. Tests and the DMG build run on this Mac (the same SDK the app needs);
# GitHub only receives the version-bump commit and the DMG as a Release. The
# in-app updater checks those releases.
set -euo pipefail

PART="${1:-patch}"
case "$PART" in
  patch|minor|major) ;;
  *) echo "usage: $0 [patch|minor|major]" >&2; exit 2 ;;
esac

MAC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$MAC/../.." && pwd)"
PLIST="Apps/OreMac/Resources/Info.plist"
BUMPED=0

git_repo() { git -C "$REPO" "$@"; }

restore_plist() {
  if [[ "$BUMPED" -eq 1 ]]; then
    git_repo checkout -- "$PLIST"
    BUMPED=0
  fi
}
trap restore_plist EXIT

echo "==> Checking this is a clean master"
if [[ -n "$(git_repo status --porcelain)" ]]; then
  echo "error: working tree is dirty — certify from a clean master." >&2
  git_repo status --short >&2
  exit 1
fi

branch="$(git_repo rev-parse --abbrev-ref HEAD)"
if [[ "$branch" != "master" ]]; then
  echo "error: on '$branch', not master. Merge first, then certify." >&2
  exit 1
fi

git_repo fetch origin master
local_head="$(git_repo rev-parse HEAD)"
remote_head="$(git_repo rev-parse origin/master)"
if [[ "$local_head" != "$remote_head" ]]; then
  echo "error: local master is not origin/master." >&2
  echo "    local  $local_head" >&2
  echo "    origin $remote_head" >&2
  echo "    pull or push until they match, then certify what is on master." >&2
  exit 1
fi

if ! command -v gh >/dev/null; then
  echo "error: gh is not on PATH." >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh is not authenticated. Run gh auth login." >&2
  exit 1
fi

echo "==> OreKit tests"
(cd "$REPO/Packages/OreKit" && swift test)

echo "==> OreMac tests"
(cd "$MAC" && xcrun --sdk macosx swift test)

echo "==> Bumping $PART version"
VERSION="$("$MAC/Scripts/bump-version.sh" "$PART")"
BUMPED=1

echo "==> Building DMG for v$VERSION"
"$MAC/Scripts/make-dmg.sh" release
DMG="$MAC/.build/ORE-$VERSION.dmg"
if [[ ! -f "$DMG" ]]; then
  echo "error: expected $DMG" >&2
  exit 1
fi

echo "==> Committing v$VERSION on master"
git_repo add "$PLIST"
git_repo commit -m "chore(release): v$VERSION [skip ci]"
BUMPED=0
git_repo push origin HEAD:master

echo "==> Publishing GitHub Release v$VERSION"
(
  cd "$REPO"
  gh release create "v$VERSION" "$DMG" \
    --title "ORE v$VERSION" \
    --generate-notes \
    --target "$(git rev-parse HEAD)"
)

echo
echo "Certified and published: v$VERSION"
echo "    $DMG"
echo "    $(cd "$REPO" && gh release view "v$VERSION" --json url --jq .url)"
