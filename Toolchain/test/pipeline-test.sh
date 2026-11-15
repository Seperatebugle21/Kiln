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

# Clang's runtime helpers (compiler-rt), e.g. __isPlatformVersionAtLeast for #available checks.
# The clang driver adds this archive automatically; Kiln has to pass it itself.
BUILTINS="$(xcrun --sdk iphoneos clang -print-resource-dir)/lib/darwin/libclang_rt.ios.a"
ls -lh "$BUILTINS"

echo "::group::Link"
"$LLD" -dylib -arch arm64 \
  -platform_version ios 26.0 "$SDK_VERSION" \
  -syslibroot "$SDK" \
  -L "$SDK/usr/lib/swift" \
  -install_name @rpath/HelloKiln.dylib \
  -adhoc_codesign \
  -lSystem \
  "$WORK/HelloKiln.o" \
  "$BUILTINS" \
  -o "$WORK/HelloKiln.dylib"
echo "::endgroup::"

file "$WORK/HelloKiln.dylib"
otool -L "$WORK/HelloKiln.dylib"
nm -gU "$WORK/HelloKiln.dylib" | grep kiln_entry
ls -lh "$WORK/HelloKiln.dylib"

# Every Kiln build gives its modules unique names (Greeting_k1234) and keeps `import Greeting`
# working through -module-alias, so a second Run loaded next to the first has distinct types.
echo "::group::Per-build module names with -module-alias"
ALIAS="$WORK/alias"
mkdir -p "$ALIAS/Modules" "$ALIAS/src"
cat > "$ALIAS/src/Greeting.swift" <<'SWIFT'
public final class Greeter {
    public init() {}
    public var text: String { "Hello" }
}
SWIFT
cat > "$ALIAS/src/App.swift" <<'SWIFT'
import Greeting
@_cdecl("alias_check") public func aliasCheck() -> Int { Greeter().text.count }
SWIFT
for TAG in _ka _kb; do
  "$FRONTEND" -frontend -c "$ALIAS/src/Greeting.swift" -target "$TARGET" -sdk "$SDK" -parse-as-library -Onone \
    -module-cache-path "$WORK/ModuleCache" -module-name "Greeting$TAG" \
    -emit-module-path "$ALIAS/Modules/Greeting$TAG.swiftmodule" -o "$ALIAS/Greeting$TAG.o"
  "$FRONTEND" -frontend -c "$ALIAS/src/App.swift" -target "$TARGET" -sdk "$SDK" -parse-as-library -Onone \
    -module-cache-path "$WORK/ModuleCache" -I "$ALIAS/Modules" -module-alias "Greeting=Greeting$TAG" \
    -module-name "App$TAG" -o "$ALIAS/App$TAG.o"
  nm "$ALIAS/Greeting$TAG.o" | grep -q "8Greeting${TAG}7Greeter" || nm "$ALIAS/Greeting$TAG.o" | grep -q "Greeting$TAG"
done
echo "module-alias builds compiled for both tags"
echo "::endgroup::"
