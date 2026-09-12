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

# A release built without this key ships with analytics off. That is the right
# default for anyone else's build and a silent disaster for ours: we would
# learn nothing for a week and only notice when a dashboard stayed flat.
if [[ -z "${ORE_POSTHOG_KEY:-}" ]]; then
  echo
  echo "warning: ORE_POSTHOG_KEY is not set."
  echo "    This release ships with analytics disabled — no installs, no DAU and"
  echo "    no activation funnel for this version."
  read -r -p "    Continue anyway? [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || exit 1
fi

echo "==> OreKit tests"
(cd "$REPO/Packages/OreKit" && swift test)

echo "==> OreMac tests"
(cd "$MAC" && xcrun --sdk macosx swift test)

echo "==> Bumping $PART version"
VERSION="$("$MAC/Scripts/bump-version.sh" "$PART")"
BUMPED=1

echo "==> Building artifacts for v$VERSION"
# One env var is the whole difference between the free path and the paid one.
# release.sh signs with a Developer ID, notarizes and staples; until that
# certificate exists, make-artifacts.sh produces the same three files ad-hoc.
if [[ -n "${ORE_SIGNING_IDENTITY:-}" ]]; then
  "$MAC/Scripts/release.sh" "$VERSION"
else
  "$MAC/Scripts/make-artifacts.sh" release
fi

DMG="$MAC/.build/ORE-$VERSION.dmg"
ZIP="$MAC/.build/ORE-$VERSION.zip"
SUMS="$MAC/.build/SHA256SUMS"
MANIFEST="$MAC/.build/RELEASE"
for artifact in "$DMG" "$ZIP" "$SUMS" "$MANIFEST"; do
  if [[ ! -f "$artifact" ]]; then
    echo "error: expected $artifact" >&2
    exit 1
  fi
done

# What the release page says about where these bytes came from.
#
# A build cut on this Mac carries no attestation whatever it is signed with —
# attestations are produced by the workflow, from a runner, against a commit.
# Saying so only in the ad-hoc case implied that a Developer ID signature was
# provenance, which it is not: it says who signed, not what was built.
release_notes() {
  if [[ -n "${ORE_SIGNING_IDENTITY:-}" ]]; then
    printf '%s\n' "Signed with a Developer ID, notarized and stapled."
  else
    printf '%s\n' "Signed ad-hoc. Gatekeeper will refuse a browser download of" \
      "this build; install it with the curl command in the README, which does" \
      "not set the quarantine attribute."
  fi
  printf '%s\n' "" \
    "Built locally and **not attested**. Builds from" \
    ".github/workflows/release.yml carry GitHub attestations that can be" \
    "verified with \`gh attestation verify\`; this one cannot." \
    "" \
    "Checksums for every file above are in \`SHA256SUMS\`."
}

echo "==> Committing v$VERSION on master"
git_repo add "$PLIST"
git_repo commit -m "chore(release): v$VERSION [skip ci]"
BUMPED=0
git_repo push origin HEAD:master

echo "==> Publishing GitHub Release v$VERSION"
(
  cd "$REPO"
  gh release create "v$VERSION" "$ZIP" "$DMG" "$SUMS" "$MANIFEST" \
    --title "ORE v$VERSION" \
    --notes "$(release_notes)" \
    --target "$(git rev-parse HEAD)"
)

# The check that would have caught the repository being private.
#
# Everything downstream — install.sh, the Homebrew cask, and the in-app
# updater's public path — fetches release assets anonymously. If the repo is
# private, or a release is left as a draft, all three break for every user
# while continuing to work perfectly for whoever cut the release. That failure
# is invisible from here, so assert it explicitly on every release instead of
# waiting for a bug report.
echo "==> Checking every published asset is downloadable anonymously"
SLUG="$(cd "$REPO" && gh repo view --json nameWithOwner --jq .nameWithOwner)"
# The fixed-name manifest is checked at `latest/download` as well as under the
# tag: that is the exact URL install.sh starts from, and it is the one that
# breaks when a release is left as a draft.
for url in \
  "https://github.com/$SLUG/releases/latest/download/RELEASE" \
  "https://github.com/$SLUG/releases/download/v$VERSION/RELEASE" \
  "https://github.com/$SLUG/releases/download/v$VERSION/SHA256SUMS" \
  "https://github.com/$SLUG/releases/download/v$VERSION/$(basename "$ZIP")" \
  "https://github.com/$SLUG/releases/download/v$VERSION/$(basename "$DMG")"
do
  status="$(curl -sSL -o /dev/null -w '%{http_code}' -H "Authorization:" "$url" || echo 000)"
  if [[ "$status" != "200" ]]; then
    echo "error: $url returned HTTP $status to an anonymous client." >&2
    echo "    install.sh, the Homebrew cask and the in-app updater are all broken" >&2
    echo "    for every user until this returns 200. Is the repository private?" >&2
    exit 1
  fi
  echo "    200 OK  $(basename "$url")"
done

# Bump the Homebrew cask.
#
# Not optional while the README tells people to `brew install`: a release that
# skips this leaves the tap a version behind, and `brew upgrade` then walks
# the user backwards onto the older build. Set ORE_TAP_SKIP=1 to publish
# without it, deliberately and visibly.
if [[ -n "${ORE_TAP_DIR:-}" ]]; then
  echo "==> Updating the Homebrew tap"
  ZIP_SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
  CASK="$ORE_TAP_DIR/Casks/ore.rb"
  cp "$MAC/../../packaging/homebrew/ore.rb" "$CASK"
  sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" \
            -e "s/^  sha256 \".*\"/  sha256 \"$ZIP_SHA\"/" "$CASK"
  # The template ships placeholders on purpose, so an unstamped cask can never
  # be mistaken for a real one. Publishing one is worse than not publishing:
  # `brew install` downloads a file whose checksum cannot match.
  if grep -qE '^  (version "0\.0\.0"|sha256 "0{64}")' "$CASK"; then
    echo "error: the cask was not stamped with v$VERSION and its checksum." >&2
    exit 1
  fi
  git -C "$ORE_TAP_DIR" add Casks/ore.rb
  if ! (git -C "$ORE_TAP_DIR" commit -m "ore $VERSION" && git -C "$ORE_TAP_DIR" push); then
    echo "error: could not publish the cask for v$VERSION to $ORE_TAP_DIR." >&2
    echo "    The release is out; Homebrew users are on the previous version" >&2
    echo "    until this is pushed. Fix the tap and push it by hand." >&2
    exit 1
  fi
elif [[ "${ORE_TAP_SKIP:-0}" == "1" ]]; then
  echo "note: ORE_TAP_SKIP=1 — Homebrew cask deliberately not updated for v$VERSION."
else
  echo "error: ORE_TAP_DIR is not set, and the README advertises Homebrew." >&2
  echo "    Clone OpenResearchh/homebrew-tap and point ORE_TAP_DIR at it, or" >&2
  echo "    set ORE_TAP_SKIP=1 to publish without refreshing the cask." >&2
  echo "    The release itself is already published; only the cask is missing." >&2
  exit 1
fi

echo
echo "Certified and published: v$VERSION"
echo "    $ZIP"
echo "    $DMG"
echo "    $(cd "$REPO" && gh release view "v$VERSION" --json url --jq .url)"
echo
echo "This release was built locally and is not attested — a Developer ID"
echo "signature says who signed it, not what was built. The workflow in"
echo ".github/workflows/release.yml produces attested builds; prefer it."
