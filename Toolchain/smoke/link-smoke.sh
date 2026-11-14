#!/bin/bash
# Links ToolchainSmoke.cpp into an iOS dylib against the installed static libraries.
# Usage: Toolchain/smoke/link-smoke.sh <install dir> <output dylib>
set -euo pipefail
INSTALL="$(cd "$1" && pwd)"
OUT="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

xcrun --sdk iphoneos clang++ -std=c++17 -target arm64-apple-ios26.0 -isysroot "$SDK" \
  -fno-rtti -dynamiclib -O1 \
  -I "$INSTALL/include" \
  "$HERE/ToolchainSmoke.cpp" \
  "$INSTALL"/lib/liblld*.a "$INSTALL"/lib/libclang*.a "$INSTALL"/lib/libLLVM*.a \
  -o "$OUT"

file "$OUT"
otool -L "$OUT"
ls -lh "$OUT"
