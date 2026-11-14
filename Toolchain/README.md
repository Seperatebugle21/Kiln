# Kiln toolchain

Kiln compiles apps on the device. iOS apps cannot start other programs, so the compiler and linker
are built for iOS as libraries and called in-process. The **Toolchain** workflow builds them.

## Stages

| Stage | What | Status |
|---|---|---|
| 1 | LLVM, Clang and lld (Mach-O) from `swiftlang/llvm-project`, as static libraries for `arm64-apple-ios`, plus a link test | Done (Swift 6.3) |
| 2 | The Swift compiler for iOS, built against stage 1, first without its Swift-written parts (no macros yet), plus a link test of `swift::mainEntry` | In progress |
| 3 | The iPhoneOS SDK interfaces (`.swiftinterface`, `.tbd`, headers) the compiler reads | Planned |
| 4 | Kiln links the libraries, compiles with `swift-frontend`, links with lld, signs and loads the dylib | Planned |

The Swift version follows the runner's Xcode, so the compiler can read that Xcode's SDK interfaces.

## Running it

Actions › Toolchain › Run workflow. It also runs when files in `Toolchain/` change on a `claude/` branch.
The result is the artifact `llvm-ios-<version>`. A compiler cache makes later runs much faster.

## Scripts

- `build-llvm.sh` builds host tablegen tools, then LLVM, Clang and lld for iOS.
- `build-swift.sh` builds cmark and the Swift compiler libraries for iOS.
- `smoke/link-swift-smoke.sh` links a dylib that exports `swift::mainEntry`, the swift-frontend entry point.
- `smoke/link-smoke.sh` links a small iOS dylib that calls Clang and `lld::macho::link`, which proves every
  symbol resolves for iOS.
