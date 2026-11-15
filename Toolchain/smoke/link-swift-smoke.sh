#!/bin/bash
# Links SwiftSmoke.cpp into an iOS dylib against the Swift, LLVM and Clang static libraries.
# Usage: Toolchain/smoke/link-swift-smoke.sh <swift install dir> <llvm install dir> <output dylib>
set -euo pipefail
SWIFT="$(cd "$1" && pwd)"
LLVM="$(cd "$2" && pwd)"
OUT="$3"
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

xcrun --sdk iphoneos clang++ -std=c++17 -target arm64-apple-ios26.0 -isysroot "$SDK" \
  -fno-rtti -dynamiclib -O1 \
  "$HERE/SwiftSmoke.cpp" \
  "$SWIFT"/lib/*.a "$LLVM"/lib/*.a \
  -L "$SWIFT/lib/host" -L "$SDK/usr/lib/swift" \
  -L "$(dirname "$(xcrun -f swiftc)")/../lib/swift/iphoneos" \
  -Wl,-rpath,@executable_path/Frameworks \
  -o "$OUT" 2>&1 | tee "$OUT.link.log" | tail -80
test -f "$OUT"

file "$OUT"
otool -L "$OUT"
ls -lh "$OUT"
