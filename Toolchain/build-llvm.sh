#!/bin/bash
# Builds LLVM, Clang and lld from swiftlang/llvm-project as static libraries for iOS (arm64).
# These are the base of Kiln's on-device toolchain: the Swift compiler is built on top of them,
# and lld links the compiled app into a dylib.
#
# Usage: Toolchain/build-llvm.sh <llvm-project checkout> <work dir>
set -euo pipefail

SRC="$(cd "$1" && pwd)"
WORK="$(mkdir -p "$2" && cd "$2" && pwd)"
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
DEPLOYMENT_TARGET="26.0"
LAUNCHER=()
if command -v ccache >/dev/null; then
  LAUNCHER=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi

COMMON=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DLLVM_TARGETS_TO_BUILD=AArch64
  -DLLVM_ENABLE_ZLIB=OFF
  -DLLVM_ENABLE_ZSTD=OFF
  -DLLVM_ENABLE_LIBXML2=OFF
  -DLLVM_ENABLE_TERMINFO=OFF
  -DLLVM_ENABLE_LIBEDIT=OFF
  -DLLVM_INCLUDE_TESTS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF
  -DLLVM_INCLUDE_BENCHMARKS=OFF
  -DLLVM_INCLUDE_DOCS=OFF
  -DCLANG_INCLUDE_TESTS=OFF
  -DCLANG_INCLUDE_DOCS=OFF
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF
  "${LAUNCHER[@]}"
)

echo "::group::Patch lld"
# Swift's LLVM fork disables linking for Apple platforms in lld ("This version of lld does not
# support linking for platform iOS") by failing before the upstream platform check. Kiln links its
# own iOS objects with lld, so drop that early error and keep the upstream check.
INPUT_FILES="$SRC/lld/MachO/InputFiles.cpp"
if grep -q "Swift LLVM fork downstream change start" "$INPUT_FILES"; then
  perl -0pi -e 's|// Swift LLVM fork downstream change start.*?// Swift LLVM fork downstream change end|// Kiln: Swift fork restriction removed; the upstream platform check below applies.|s' "$INPUT_FILES"
  grep -n "Kiln: Swift fork restriction removed" "$INPUT_FILES"
fi
echo "::endgroup::"

echo "::group::Host tablegen tools"
# Cross-compiling needs tablegen tools that run on this Mac.
cmake -S "$SRC/llvm" -B "$WORK/host" "${COMMON[@]}" -DLLVM_ENABLE_PROJECTS=clang
HOST_TOOLS=(llvm-tblgen clang-tblgen)
if ninja -C "$WORK/host" -t targets all | grep -q '^llvm-min-tblgen:'; then
  HOST_TOOLS+=(llvm-min-tblgen)
fi
ninja -C "$WORK/host" "${HOST_TOOLS[@]}"
echo "::endgroup::"

echo "::group::Configure for iOS"
cmake -S "$SRC/llvm" -B "$WORK/ios" "${COMMON[@]}" \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$IOS_SDK" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_MACOSX_BUNDLE=OFF \
  -DLLVM_HOST_TRIPLE=arm64-apple-ios \
  -DLLVM_DEFAULT_TARGET_TRIPLE="arm64-apple-ios$DEPLOYMENT_TARGET" \
  -DLLVM_NATIVE_TOOL_DIR="$WORK/host/bin" \
  -DLLVM_TABLEGEN="$WORK/host/bin/llvm-tblgen" \
  -DCLANG_TABLEGEN="$WORK/host/bin/clang-tblgen" \
  -DLLVM_BUILD_TOOLS=OFF \
  -DLLVM_BUILD_UTILS=OFF \
  -DCLANG_BUILD_TOOLS=OFF \
  -DLLVM_ENABLE_PIC=ON \
  -DCMAKE_INSTALL_PREFIX="$WORK/install"
echo "::endgroup::"

echo "::group::Build static libraries for iOS"
# Only the static libraries: some tools and shared libraries (such as libIndexStore.dylib) are
# linked with ELF-only flags when targeting iOS, and Kiln needs none of them.
# (macOS ships bash 3.2, which has no mapfile; the paths contain no spaces.)
LIBRARIES=($(ninja -C "$WORK/ios" -t targets all | sed -n 's#^\(lib/lib[^:]*\.a\):.*#\1#p' | sort -u))
echo "Building ${#LIBRARIES[@]} libraries"
ninja -C "$WORK/ios" "${LIBRARIES[@]}"
echo "::endgroup::"

echo "::group::Clang resource headers"
# Clang's builtin headers (stddef.h, arm_neon.h, …), some generated with clang-tblgen.
# The Swift compiler reads them through its resource directory when it imports C modules.
ninja -C "$WORK/ios" clang-resource-headers
echo "::endgroup::"

echo "::group::Collect"
INSTALL="$WORK/install"
rm -rf "$INSTALL"
mkdir -p "$INSTALL/lib" "$INSTALL/include"
cp "$WORK/ios"/lib/*.a "$INSTALL/lib/"
# Headers: the sources, plus the ones generated during the build.
for dir in "$SRC/llvm/include" "$SRC/clang/include" "$SRC/lld/include" \
           "$WORK/ios/include" "$WORK/ios/tools/clang/include"; do
  rsync -a --include='*/' --include='*.h' --include='*.def' --include='*.inc' --include='*.td' --exclude='*' "$dir/" "$INSTALL/include/"
done
echo "::endgroup::"

mkdir -p "$INSTALL/clang-resources"
cp -R "$WORK/ios"/lib/clang/*/include "$INSTALL/clang-resources/include"

echo "Libraries: $(ls "$INSTALL"/lib/*.a | wc -l)"
du -sh "$INSTALL"
