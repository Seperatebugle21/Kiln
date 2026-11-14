#!/bin/bash
# Builds the Swift compiler (swift-frontend and its driver) as static libraries for iOS (arm64),
# against the LLVM/Clang build from build-llvm.sh.
#
# This first version leaves out the parts of the compiler written in Swift (SWIFT_ENABLE_SWIFT_IN_SWIFT=OFF):
# they would need a second, cross-compiled Swift toolchain. Without them, macros and a few
# optimizer passes are unavailable; plain Swift and SwiftUI code compiles.
#
# Usage: Toolchain/build-swift.sh <swift checkout> <swift-cmark checkout> <llvm work dir> <work dir>
set -euo pipefail

SWIFT_SRC="$(cd "$1" && pwd)"
CMARK_SRC="$(cd "$2" && pwd)"
LLVM_WORK="$(cd "$3" && pwd)"
WORK="$(mkdir -p "$4" && cd "$4" && pwd)"
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
DEPLOYMENT_TARGET="26.0"
LAUNCHER=()
if command -v ccache >/dev/null; then
  LAUNCHER=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi

IOS=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_SYSTEM_NAME=iOS
  -DCMAKE_OSX_SYSROOT="$IOS_SDK"
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
  -DCMAKE_MACOSX_BUNDLE=OFF
  "${LAUNCHER[@]}"
)

echo "::group::cmark for iOS"
cmake -S "$CMARK_SRC" -B "$WORK/cmark" "${IOS[@]}" -DCMARK_TESTS=OFF -DCMARK_SHARED=OFF -DCMARK_STATIC=ON
ninja -C "$WORK/cmark"
echo "::endgroup::"

echo "::group::Configure Swift for iOS"
cmake -S "$SWIFT_SRC" -B "$WORK/swift" "${IOS[@]}" \
  -DLLVM_DIR="$LLVM_WORK/ios/lib/cmake/llvm" \
  -DClang_DIR="$LLVM_WORK/ios/lib/cmake/clang" \
  -DLLVM_TABLEGEN="$LLVM_WORK/host/bin/llvm-tblgen" \
  -DLLVM_TABLEGEN_EXE="$LLVM_WORK/host/bin/llvm-tblgen" \
  -DSWIFT_NATIVE_LLVM_TOOLS_PATH="$LLVM_WORK/host/bin" \
  -DSWIFT_NATIVE_CLANG_TOOLS_PATH="$(dirname "$(xcrun -f clang)")" \
  -Dcmark-gfm_DIR="$WORK/cmark/src" \
  -DSWIFT_HOST_VARIANT=iphoneos \
  -DSWIFT_HOST_VARIANT_SDK=IOS \
  -DSWIFT_HOST_VARIANT_ARCH=arm64 \
  -DSWIFT_PRIMARY_VARIANT_SDK=IOS \
  -DSWIFT_PRIMARY_VARIANT_ARCH=arm64 \
  -DSWIFT_SDKS=IOS \
  -DSWIFT_DARWIN_DEPLOYMENT_VERSION_IOS="$DEPLOYMENT_TARGET" \
  -DSWIFT_INCLUDE_TOOLS=ON \
  -DSWIFT_BUILD_STDLIB=OFF \
  -DSWIFT_BUILD_SDK_OVERLAY=OFF \
  -DSWIFT_BUILD_DYNAMIC_STDLIB=OFF \
  -DSWIFT_BUILD_STATIC_STDLIB=OFF \
  -DSWIFT_BUILD_DYNAMIC_SDK_OVERLAY=OFF \
  -DSWIFT_BUILD_STATIC_SDK_OVERLAY=OFF \
  -DSWIFT_BUILD_REMOTE_MIRROR=OFF \
  -DSWIFT_BUILD_SOURCEKIT=OFF \
  -DSWIFT_INCLUDE_TESTS=OFF \
  -DSWIFT_INCLUDE_TEST_BINARIES=OFF \
  -DSWIFT_INCLUDE_DOCS=OFF \
  -DSWIFT_ENABLE_SWIFT_IN_SWIFT=OFF \
  -DSWIFT_BUILD_SWIFT_SYNTAX=OFF
echo "::endgroup::"

echo "::group::Build Swift compiler libraries for iOS"
LIBRARIES=($(ninja -C "$WORK/swift" -t targets all | sed -n 's#^\(lib/lib[^:]*\.a\):.*#\1#p' | sort -u))
echo "Building ${#LIBRARIES[@]} libraries"
ninja -C "$WORK/swift" "${LIBRARIES[@]}"
echo "::endgroup::"

echo "::group::Collect"
INSTALL="$WORK/install"
rm -rf "$INSTALL"
mkdir -p "$INSTALL/lib" "$INSTALL/include"
cp "$WORK/swift"/lib/*.a "$INSTALL/lib/"
cp "$WORK/cmark"/src/*.a "$INSTALL/lib/" 2>/dev/null || find "$WORK/cmark" -name '*.a' -exec cp {} "$INSTALL/lib/" \;
for dir in "$SWIFT_SRC/include" "$WORK/swift/include"; do
  rsync -a --include='*/' --include='*.h' --include='*.def' --include='*.inc' --exclude='*' "$dir/" "$INSTALL/include/"
done
# The compiler's resource directory: clang's builtin headers and Swift's shims, read at compile time.
mkdir -p "$INSTALL/resources"
cp -R "$SWIFT_SRC/stdlib/public/SwiftShims/swift/shims" "$INSTALL/resources/shims" 2>/dev/null || true
echo "::endgroup::"

echo "Libraries: $(ls "$INSTALL"/lib/*.a | wc -l)"
du -sh "$INSTALL"
