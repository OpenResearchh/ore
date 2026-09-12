#!/bin/bash
# Builds ORE.app and packages it into a drag-to-install DMG.
#
#   ./Scripts/make-dmg.sh [debug|release]   → .build/ORE-<version>.dmg
#
# Kept for muscle memory. make-artifacts.sh does the real work and also emits
# the zip and SHA256SUMS that install.sh and the Homebrew cask need; there is
# no reason to build the app twice to get one of its outputs.
#
# The bundle is ad-hoc signed (see bundle.sh), so on another Mac Gatekeeper
# blocks the DMG path until the user goes to System Settings → Privacy &
# Security → "Open Anyway". Installing via install.sh skips that entirely.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/Scripts/make-artifacts.sh" "${1:-release}"
