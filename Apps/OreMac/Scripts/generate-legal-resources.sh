#!/bin/bash
# Gathers ORE's legal texts into the app's resources, so they ship inside the
# binary rather than only in each project's source distribution. MIT, BSD and
# Apache all ask for their notices to travel with the software itself.
#
#   Resources/Legal/LICENSE.txt             ORE's own license
#   Resources/Legal/NOTICE.txt              ORE's notice file
#   Resources/Legal/ThirdPartyLicenses.txt  every pinned package's license, verbatim
#
# Run after changing dependencies (`swift package resolve` first) or editing
# LICENSE / NOTICE. The output is checked in; LegalResourcesTests fails when it
# falls out of step with Package.resolved or the repository's files.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$ROOT/../.." && pwd)"
OUT="$ROOT/Sources/OreMac/Resources/Legal"
CHECKOUTS="$ROOT/.build/checkouts"

if [[ ! -d "$CHECKOUTS" ]]; then
  echo "error: no package checkouts — run 'swift package resolve' in $ROOT first" >&2
  exit 1
fi

mkdir -p "$OUT"
cp "$REPO/LICENSE" "$OUT/LICENSE.txt"
cp "$REPO/NOTICE" "$OUT/NOTICE.txt"

python3 - "$ROOT/Package.resolved" "$CHECKOUTS" > "$OUT/ThirdPartyLicenses.txt" <<'PY'
import json
import os
import sys

resolved, checkouts = sys.argv[1], sys.argv[2]
pins = sorted(json.load(open(resolved))["pins"], key=lambda pin: pin["identity"])
directories = {name.lower(): name for name in os.listdir(checkouts)}
rule = "-" * 78

print("Third-party software in ORE")
print("===========================")
print()
print("ORE includes the following open-source packages. Each license is")
print("reproduced in full, as its terms require.")

for pin in pins:
    directory = directories.get(pin["identity"])
    if directory is None:
        sys.exit(f"error: no checkout for {pin['identity']}")
    path = os.path.join(checkouts, directory)
    licenses = sorted(
        name for name in os.listdir(path)
        if name.lower().split(".")[0] in ("license", "licence", "copying")
    )
    if not licenses:
        sys.exit(f"error: {directory} has no license file")
    state = pin["state"]
    version = state.get("version") or state.get("revision", "")[:12]
    print()
    print(rule)
    print(f"{directory} {version}")
    print(pin["location"].removesuffix(".git"))
    print(rule)
    print()
    with open(os.path.join(path, licenses[0]), encoding="utf-8") as handle:
        print(handle.read().rstrip())

print()
print(rule)
print("Pocket TTS (neural narration voice model)")
print("https://huggingface.co/kyutai/pocket-tts")
print(rule)
print()
print("Pocket TTS by Kyutai, licensed under the Creative Commons Attribution 4.0")
print("International License (CC BY 4.0):")
print("https://creativecommons.org/licenses/by/4.0/")
print()
print("ORE's optional neural narration voice uses FluidInference's Core ML")
print("conversion of the model (https://huggingface.co/FluidInference/pocket-tts-coreml).")
print("The weights are downloaded on demand when that voice is chosen and are not")
print("part of the app download.")
PY

echo "Wrote $OUT"
