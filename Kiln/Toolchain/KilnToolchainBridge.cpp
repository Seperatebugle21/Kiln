// Bridges Kiln to the Swift compiler and lld, which are linked into the app as static libraries.
// iOS apps cannot start other programs, so both run inside Kiln's process.
//
// KILN_HAS_TOOLCHAIN is defined by Configuration/Toolchain.generated.xcconfig when the Build Kiln
// workflow has downloaded the toolchain libraries. Without it, Kiln builds with stubs.
#include "KilnToolchainBridge.h"

#include <cstdlib>
#include <cstring>
#include <string>

#if KILN_HAS_TOOLCHAIN

#include "lld/Common/Driver.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/Support/raw_ostream.h"

LLD_HAS_DRIVER(macho)

namespace swift {
int mainEntry(int argc, const char **argv);
}

int kiln_toolchain_available(void) { return 1; }

int kiln_swift_frontend(int argc, const char **argv) {
    return swift::mainEntry(argc, argv);
}

int kiln_lld_link(int argc, const char **argv, char **output) {
    std::string text;
    llvm::raw_string_ostream stream(text);
    lld::Result result = lld::lldMain(llvm::ArrayRef<const char *>(argv, argc), stream, stream,
                                      {{lld::Darwin, &lld::macho::link}});
    stream.flush();
    if (output) {
        *output = strdup(text.c_str());
    }
    return result.retCode;
}

#else

int kiln_toolchain_available(void) { return 0; }

int kiln_swift_frontend(int, const char **) { return -1; }

int kiln_lld_link(int, const char **, char **output) {
    if (output) {
        *output = strdup("This build of Kiln does not include the linker.");
    }
    return -1;
}

#endif
