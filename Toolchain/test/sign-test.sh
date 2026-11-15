#!/bin/bash
# Signs the pipeline test's dylib with Kiln's MachOSigner and a throwaway self-signed certificate,
# then lets codesign parse and check the signature. A trust failure is expected (the certificate is
# not from Apple); a malformed signature is not.
# Usage: Toolchain/test/sign-test.sh <dylib> <work dir>
set -euo pipefail
DYLIB="$1"
WORK="$(mkdir -p "$2" && cd "$2" && pwd)"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=Kiln Test Signer/OU=KILNTEST01/O=Kiln"
openssl x509 -in "$WORK/cert.pem" -outform DER -out "$WORK/cert.der"
openssl rsa -in "$WORK/key.pem" -outform DER -traditional -out "$WORK/key.der" 2>/dev/null \
  || openssl rsa -in "$WORK/key.pem" -outform DER -out "$WORK/key.der"

xcrun swiftc -O \
  "$ROOT/Kiln/Signing/DER.swift" "$ROOT/Kiln/Signing/MachOSigner.swift" "$ROOT/Toolchain/test/SignerCLI/main.swift" \
  -o "$WORK/signer"

cp "$DYLIB" "$WORK/signed.dylib"
"$WORK/signer" "$WORK/signed.dylib" "$WORK/key.der" KILNTEST01 "$WORK/cert.der"

echo "::group::codesign -d"
codesign -d --verbose=4 "$WORK/signed.dylib" 2>&1 | tee "$WORK/display.txt"
echo "::endgroup::"
grep -q "TeamIdentifier=KILNTEST01" "$WORK/display.txt"
grep -q "Hash type=sha256" "$WORK/display.txt"

# The CMS must parse: codesign extracts its certificates, which must be our test certificate.
# (Authority shows "(unavailable)" for an untrusted, self-signed certificate.)
codesign -d --extract-certificates="$WORK/extracted-" "$WORK/signed.dylib"
ls -l "$WORK"/extracted-*
cmp "$WORK/extracted-0" "$WORK/cert.der"
echo "The CMS signature carries the test certificate."

echo "::group::codesign --verify"
VERIFY=$(codesign --verify --verbose=4 "$WORK/signed.dylib" 2>&1 || true)
echo "$VERIFY"
echo "::endgroup::"
if echo "$VERIFY" | grep -qiE "invalid signature|not signed at all|code object is not signed|invalid or unsupported format|bundle format"; then
  echo "::error::codesign reports a malformed signature"
  exit 1
fi
echo "Signature structure OK (trust errors are expected for the test certificate)."
