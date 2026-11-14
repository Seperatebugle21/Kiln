// Links against the iOS builds of lld and Clang to prove that every symbol they need resolves
// for iOS. Kiln will call these entry points in-process, because iOS apps cannot run other programs.
#include "clang/Basic/Version.h"
#include "lld/Common/Driver.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/Support/raw_ostream.h"

LLD_HAS_DRIVER(macho)

extern "C" int kiln_toolchain_smoke(const char **args, int count) {
    llvm::outs() << clang::getClangFullVersion() << "\n";
    llvm::ArrayRef<const char *> arguments(args, count);
    bool ok = lld::macho::link(arguments, llvm::outs(), llvm::errs(), /*exitEarly=*/false, /*disableOutput=*/false);
    return ok ? 0 : 1;
}
