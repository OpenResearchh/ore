#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
exec /usr/bin/env xcrun --sdk macosx swift test
