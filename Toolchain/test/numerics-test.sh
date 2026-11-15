#!/bin/bash
# Builds swift-numerics (RealModule, then ComplexModule) the way Kiln builds packages, with and
# without -module-alias, to find out which one makes the compiler crash on the iPhone.
# Usage: Toolchain/test/numerics-test.sh <swift-frontend> <work dir>
set -uo pipefail
FRONTEND="$1"
WORK="$(mkdir -p "$2" && cd "$2" && pwd)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TARGET="arm64-apple-ios26.0"

git clone -q --depth 1 https://github.com/apple/swift-numerics "$WORK/numerics"
SRC="$WORK/numerics/Sources"
SHIMS="$SRC/_NumericsShims/include"
ls "$SHIMS"
MAP="$SHIMS/module.modulemap"
if [ ! -f "$MAP" ]; then
  mkdir -p "$WORK/maps"
  printf 'module _NumericsShims {\n    umbrella "%s"\n    export *\n}\n' "$SHIMS" > "$WORK/maps/module.modulemap"
  MAP="$WORK/maps/module.modulemap"
fi
COMMON=(-target "$TARGET" -sdk "$SDK" -parse-as-library -Onone -module-cache-path "$WORK/mc"
        -Xcc "-fmodule-map-file=$MAP" -Xcc -I -Xcc "$SHIMS")

build() { # <label> <real-name suffix> <use alias: yes/no>
  local LABEL="$1" SUFFIX="$2" ALIAS="$3" OUT="$WORK/$1"
  mkdir -p "$OUT/Modules"
  echo "::group::$LABEL"
  "$FRONTEND" -frontend -c $(find "$SRC/RealModule" -name '*.swift') "${COMMON[@]}" -I "$OUT/Modules" \
    -enable-experimental-feature BuiltinModule \
    -module-name "RealModule$SUFFIX" -emit-module-path "$OUT/Modules/RealModule$SUFFIX.swiftmodule" -o "$OUT/Real.o"
  echo "RealModule: exit $?"
  local ALIASES=()
  if [ "$ALIAS" = yes ]; then ALIASES=(-module-alias "RealModule=RealModule$SUFFIX"); fi
  "$FRONTEND" -frontend -c $(find "$SRC/ComplexModule" -name '*.swift') "${COMMON[@]}" -I "$OUT/Modules" \
    ${ALIASES[@]+"${ALIASES[@]}"} -module-name "ComplexModule$SUFFIX" -emit-module-path "$OUT/Modules/ComplexModule$SUFFIX.swiftmodule" \
    -o "$OUT/Complex.o"
  echo "RESULT $LABEL ComplexModule: exit $?"
  echo "::endgroup::"
}

build plain "" no
build aliased "_p1a2b3c" yes
