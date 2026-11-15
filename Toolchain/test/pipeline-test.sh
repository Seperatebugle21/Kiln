#!/bin/bash
# Runs Kiln's on-device build pipeline on a Mac, with an open-source Swift toolchain of the same
# version as Kiln's iOS compiler:
#   1. swift-frontend in frontend mode (no driver: iOS apps cannot start the frontend as a process)
#   2. ld64.lld into a dylib that exports kiln_entry
# Usage: Toolchain/test/pipeline-test.sh <swift-frontend> <ld64.lld> <work dir>
set -euo pipefail
FRONTEND="$1"
LLD="$2"
WORK="$(mkdir -p "$3" && cd "$3" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
TARGET="arm64-apple-ios26.0"
SOURCES=("$HERE"/HelloKiln/*.swift)

"$FRONTEND" --version

echo "::group::Compile (frontend mode, whole module)"
START=$(date +%s)
"$FRONTEND" -frontend -c \
  "${SOURCES[@]}" \
  -target "$TARGET" \
  -sdk "$SDK" \
  -module-name HelloKiln \
  -parse-as-library \
  -Onone \
  -module-cache-path "$WORK/ModuleCache" \
  -o "$WORK/HelloKiln.o"
echo "Compiled in $(( $(date +%s) - START ))s (module cache was empty)"
file "$WORK/HelloKiln.o"
du -sh "$WORK/ModuleCache"
echo "::endgroup::"

echo "::group::Compile again (warm module cache)"
START=$(date +%s)
"$FRONTEND" -frontend -c "${SOURCES[@]}" -target "$TARGET" -sdk "$SDK" -module-name HelloKiln \
  -parse-as-library -Onone -module-cache-path "$WORK/ModuleCache" -o "$WORK/HelloKiln.o"
echo "Compiled in $(( $(date +%s) - START ))s"
echo "::endgroup::"

echo "::group::Link"
"$LLD" -dylib -arch arm64 \
  -platform_version ios 26.0 "$SDK_VERSION" \
  -syslibroot "$SDK" \
  -L "$SDK/usr/lib/swift" \
  -install_name @rpath/HelloKiln.dylib \
  -lSystem \
  "$WORK/HelloKiln.o" \
  -o "$WORK/HelloKiln.dylib"
echo "::endgroup::"

file "$WORK/HelloKiln.dylib"
otool -L "$WORK/HelloKiln.dylib"
nm -gU "$WORK/HelloKiln.dylib" | grep kiln_entry
ls -lh "$WORK/HelloKiln.dylib"
