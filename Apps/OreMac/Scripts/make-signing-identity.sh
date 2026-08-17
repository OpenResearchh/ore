#!/bin/bash
# Creates the local code-signing identity that keeps granted permissions from
# evaporating on every rebuild.
#
#   ./Scripts/make-signing-identity.sh
#
# An ad-hoc signature — what bundle.sh falls back to — carries no certificate
# and no Team ID, so macOS has nothing to identify the app by except the hash
# of its own binary:
#
#   $ codesign -d -r- ORE.app
#   # designated => cdhash H"ecc04a60df…"
#
# TCC stores permission grants against that requirement. Rebuilding changes the
# hash, so to macOS the new build is an unrelated program and every permission
# you granted — Screen Recording, the microphone, notifications — silently
# stops applying. Signing with a stable certificate instead yields
#
#   identifier "dev.ore.OreMac" and certificate leaf H"…"
#
# which survives rebuilds, so each permission is granted once and stays.
#
# This adds a certificate to your login keychain and marks it trusted for code
# signing, which macOS will ask you to authorise. To undo it, delete "ORE
# Development" from Keychain Access; bundle.sh then falls back to ad-hoc.
set -euo pipefail

NAME="${ORE_SIGN_IDENTITY:-ORE Development}"
KEYCHAIN="$(security default-keychain -d user | sed -e 's/^ *"//' -e 's/"$//')"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$NAME"; then
  echo "Already have a '$NAME' identity — nothing to do."
  security find-identity -v -p codesigning | grep -F "$NAME"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A self-signed leaf with the code-signing EKU. `codesign` rejects a
# certificate without it, and Keychain Access's Certificate Assistant produces
# the same shape from its "Code Signing" preset.
cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[dn]
CN = $NAME
[ext]
basicConstraints     = critical, CA:false
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> Generating a self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$WORK/openssl.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

openssl pkcs12 -export -legacy \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/identity.p12" -passout pass:ore 2>/dev/null

# `-T /usr/bin/codesign` puts codesign on the private key's access list, so
# signing does not pop a keychain prompt on every single build.
echo "==> Importing it into $KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P ore \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# A self-signed certificate is its own root, and codesign will not use a root
# it does not trust for code signing. macOS asks for authorisation here.
echo "==> Trusting it for code signing (macOS will ask you to authorise this)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
if security find-identity -v -p codesigning | grep -qF "$NAME"; then
  security find-identity -v -p codesigning | grep -F "$NAME"
  echo
  echo "Done. Rebuild with ./Scripts/bundle.sh and grant permissions once more —"
  echo "they will survive every rebuild after that."
else
  echo "The identity did not come out valid. bundle.sh will keep using an" >&2
  echo "ad-hoc signature, which still runs." >&2
  exit 1
fi
