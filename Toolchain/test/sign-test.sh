#!/bin/bash
# Signs the pipeline test's dylib with Kiln's MachOSigner and a throwaway self-signed certificate,
# then lets codesign parse and check the signature. A trust failure is expected (the certificate is
# not from Apple); a malformed signature is not.
# Usage: Toolchain/test/sign-test.sh <dylib> <work dir>
set -euo pipefail
DYLIB="$1"
WORK="$(mkdir -p "$2" && cd "$2" && pwd)"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Like Apple's signing certificates: a code signing leaf, not a CA.
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=Kiln Test Signer/OU=KILNTEST01/O=Kiln" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
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

echo "::group::CMS structure"
python3 "$ROOT/Toolchain/test/extract-cms.py" "$WORK/signed.dylib" "$WORK/cms.der"
openssl asn1parse -inform DER -in "$WORK/cms.der" -i | head -80 || true
openssl cms -cmsout -print -inform DER -in "$WORK/cms.der" | head -60 || true
# The CMS must verify against the CodeDirectory (signature and messageDigest).
openssl cms -verify -inform DER -in "$WORK/cms.der" -binary -noverify \
  -content "$WORK/cd.bin" -out /dev/null
echo "::endgroup::"

# Informational: the certificates codesign itself extracts from the signature.
codesign -d --extract-certificates="$WORK/extracted-" "$WORK/signed.dylib" || true
if [ -f "$WORK/extracted-0" ] && cmp -s "$WORK/extracted-0" "$WORK/cert.der"; then
  echo "codesign extracted the test certificate from the CMS."
else
  echo "::warning::codesign did not extract the certificate (it may skip untrusted certificates)."
fi

echo "::group::codesign --verify"
VERIFY=$(codesign --verify --verbose=4 "$WORK/signed.dylib" 2>&1 || true)
echo "$VERIFY"
echo "::endgroup::"
if echo "$VERIFY" | grep -qiE "invalid signature|not signed at all|code object is not signed|invalid or unsupported format|bundle format"; then
  echo "::error::codesign reports a malformed signature"
  exit 1
fi
echo "Signature structure OK (trust errors are expected for the test certificate)."
