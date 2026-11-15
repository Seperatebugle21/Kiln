#!/bin/bash
# Builds the Swift compiler (swift-frontend and its driver) as static libraries for iOS (arm64),
# against the LLVM/Clang build from build-llvm.sh.
#
# The parts of the compiler written in Swift (the new optimizer passes and swift-syntax, which
# macros need, even to read the iOS SDK's interfaces) are compiled for iOS with Xcode's swiftc
# (BOOTSTRAPPING_MODE=HOSTTOOLS). swift-syntax is built as dylibs (_Compiler*.dylib) that Kiln embeds.
# The regex literal parser comes from swift-experimental-string-processing, checked out next to swift.
#
# Usage: Toolchain/build-swift.sh <swift checkout> <swift-cmark checkout> <swift-syntax checkout> <llvm work dir> <work dir>
set -euo pipefail

SWIFT_SRC="$(cd "$1" && pwd)"
CMARK_SRC="$(cd "$2" && pwd)"
SYNTAX_SRC="$(cd "$3" && pwd)"
LLVM_WORK="$(cd "$4" && pwd)"
WORK="$(mkdir -p "$5" && cd "$5" && pwd)"
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
  # CMake checks Xcode's swiftc even when no Swift code is built; without a target it
  # compiles for macOS against the iOS SDK and fails.
  -DCMAKE_Swift_COMPILER_TARGET="arm64-apple-ios$DEPLOYMENT_TARGET"
  "${LAUNCHER[@]}"
)

echo "::group::cmark for iOS"
# BUILD_TESTING=OFF leaves out cmark's test programs, which call system() (unavailable on iOS).
# Swift finds cmark through the package config that only an install creates.
cmake -S "$CMARK_SRC" -B "$WORK/cmark" "${IOS[@]}" \
  -DBUILD_TESTING=OFF -DCMARK_TESTS=OFF -DCMARK_SHARED=OFF -DCMARK_STATIC=ON \
  -DCMAKE_INSTALL_PREFIX="$WORK/cmark-install"
ninja -C "$WORK/cmark" install
ls -R "$WORK/cmark-install/lib/cmake"
echo "::endgroup::"

# Swift's CMake decides "Apple or not" with CMAKE_SYSTEM_NAME STREQUAL "Darwin" (system dispatch, uuid in
# libSystem, …), so configure it as Darwin and get iOS from the SDK and an explicit target, as Apple's
# own build-script does. Swift adds its host target flags from SWIFT_HOST_VARIANT_SDK=IOS.
SWIFT_IOS=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_SYSTEM_NAME=Darwin
  -DCMAKE_OSX_SYSROOT="$IOS_SDK"
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_C_COMPILER_TARGET="arm64-apple-ios$DEPLOYMENT_TARGET"
  -DCMAKE_CXX_COMPILER_TARGET="arm64-apple-ios$DEPLOYMENT_TARGET"
  -DCMAKE_ASM_COMPILER_TARGET="arm64-apple-ios$DEPLOYMENT_TARGET"
  -DCMAKE_Swift_COMPILER_TARGET="arm64-apple-ios$DEPLOYMENT_TARGET"
  -DCMAKE_MACOSX_BUNDLE=OFF
  "${LAUNCHER[@]}"
)

echo "::group::Configure Swift for iOS"
cmake -S "$SWIFT_SRC" -B "$WORK/swift" "${SWIFT_IOS[@]}" \
  -DLLVM_DIR="$LLVM_WORK/ios/lib/cmake/llvm" \
  -DClang_DIR="$LLVM_WORK/ios/lib/cmake/clang" \
  -DLLVM_TABLEGEN="$LLVM_WORK/host/bin/llvm-tblgen" \
  -DLLVM_TABLEGEN_EXE="$LLVM_WORK/host/bin/llvm-tblgen" \
  -DSWIFT_NATIVE_LLVM_TOOLS_PATH="$LLVM_WORK/host/bin" \
  -DSWIFT_NATIVE_CLANG_TOOLS_PATH="$(dirname "$(xcrun -f clang)")" \
  -DSWIFT_PATH_TO_CMARK_SOURCE="$CMARK_SRC" \
  -DSWIFT_PATH_TO_CMARK_BUILD="$WORK/cmark" \
  -DSWIFT_CMARK_LIBRARY_DIR="$WORK/cmark-install/lib" \
  -Dcmark-gfm_DIR="$WORK/cmark-install/lib/cmake" \
  -DSWIFT_ENABLE_DISPATCH=OFF \
  -DCMAKE_PROJECT_INCLUDE="$(cd "$(dirname "$0")" && pwd)/cmake/swift-ios-overrides.cmake" \
  -DCMAKE_DISABLE_FIND_PACKAGE_LibEdit=ON \
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
  -DSWIFT_ENABLE_SWIFT_IN_SWIFT=ON \
  -DBOOTSTRAPPING_MODE=HOSTTOOLS \
  -DSWIFT_BUILD_SWIFT_SYNTAX=ON \
  -DSWIFT_PATH_TO_SWIFT_SYNTAX_SOURCE="$SYNTAX_SRC" \
  -DSWIFT_PATH_TO_STRING_PROCESSING_SOURCE="$(dirname "$SWIFT_SRC")/swift-experimental-string-processing"
echo "::endgroup::"

echo "::group::Build Swift compiler libraries for iOS"
LIBRARIES=($(ninja -C "$WORK/swift" -t targets all | sed -n 's#^\(lib/lib[^:]*\.a\):.*#\1#p' | sort -u))
echo "Building ${#LIBRARIES[@]} libraries"
ninja -C "$WORK/swift" "${LIBRARIES[@]}"
# swift-syntax for the compiler: shared libraries under lib/swift/host/compiler.
SYNTAX_TARGETS=($(ninja -C "$WORK/swift" -t targets all | sed -n 's#^\(lib/swift/host/compiler/[^:]*\.dylib\):.*#\1#p' | sort -u))
echo "swift-syntax libraries: ${SYNTAX_TARGETS[*]}"
ninja -C "$WORK/swift" "${SYNTAX_TARGETS[@]}"
echo "::endgroup::"

echo "::group::Collect"
INSTALL="$WORK/install"
rm -rf "$INSTALL"
mkdir -p "$INSTALL/lib" "$INSTALL/include"
cp "$WORK/swift"/lib/*.a "$INSTALL/lib/"
mkdir -p "$INSTALL/lib/host"
cp "$WORK/swift"/lib/swift/host/compiler/*.dylib "$INSTALL/lib/host/"
ls -l "$INSTALL/lib/host"
otool -L "$INSTALL/lib/host/lib_CompilerSwiftSyntax.dylib" || true
cp "$WORK/cmark-install"/lib/*.a "$INSTALL/lib/"
for dir in "$SWIFT_SRC/include" "$WORK/swift/include"; do
  rsync -a --include='*/' --include='*.h' --include='*.def' --include='*.inc' --exclude='*' "$dir/" "$INSTALL/include/"
done
# The compiler's resource directory (-resource-dir), read at compile time:
#   shims/  Swift's runtime shim headers and their module map
#   clang/  Clang's builtin headers (from the LLVM build)
RESOURCES="$INSTALL/resources"
mkdir -p "$RESOURCES/clang"
rsync -a --include='*/' --include='*.h' --include='*.modulemap' --exclude='*' \
  "$SWIFT_SRC/stdlib/public/SwiftShims/swift/shims/" "$RESOURCES/shims/"
cp -R "$LLVM_WORK/install/clang-resources/include" "$RESOURCES/clang/include"
ls "$RESOURCES" "$RESOURCES/shims" | head -40
du -sh "$RESOURCES"
echo "::endgroup::"

echo "Libraries: $(ls "$INSTALL"/lib/*.a | wc -l)"
du -sh "$INSTALL"
