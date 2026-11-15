// Bridges Kiln to the Swift compiler and lld, which are linked into the app as static libraries.
// iOS apps cannot start other programs, so both run inside Kiln's process.
//
// KILN_HAS_TOOLCHAIN is defined by Configuration/Toolchain.generated.xcconfig when the Build Kiln
// workflow has downloaded the toolchain libraries. Without it, Kiln builds with stubs.
#include "KilnToolchainBridge.h"

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>

#if KILN_HAS_TOOLCHAIN

#include "lld/Common/Driver.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/Support/LLVMDriver.h"
#include "llvm/Support/PrettyStackTrace.h"
#include "llvm/Support/Signals.h"
#include "llvm/Support/raw_ostream.h"

#if KILN_HAS_CLANG_DRIVER
// From clang/tools/driver/driver.cpp, archived as libKilnClangDriver.a.
int clang_main(int Argc, char **Argv, const llvm::ToolContext &ToolContext);
#endif

LLD_HAS_DRIVER(macho)

// The compiler's parts written in Swift (SwiftCompilerSources) register themselves here.
extern "C" void initializeSwiftModules();

namespace swift {
class FrontendObserver;
int performFrontend(llvm::ArrayRef<const char *> args, const char *argv0, void *mainAddr, FrontendObserver *observer);
}

int kiln_toolchain_available(void) { return 1; }

int kiln_swift_frontend(int argc, const char **argv) {
    // swift-frontend's main (swift::mainEntry) registers the Swift-written compiler classes on every
    // start. That is fine for a process that compiles once, but Kiln compiles many modules in one
    // process, and the second registration aborts ("Double registration of class
    // MultipleValueInstructionResult"). So Kiln registers once and calls the frontend directly.
    static std::once_flag once;
    std::call_once(once, [&] {
        initializeSwiftModules();
        // Print a stack dump (into the captured compiler output) if the compiler crashes.
        llvm::sys::PrintStackTraceOnErrorSignal(argv[0]);
        llvm::EnablePrettyStackTrace();
    });
    int skip = (argc >= 2 && std::strcmp(argv[1], "-frontend") == 0) ? 2 : 1;
    if (argc < skip) {
        return 1;
    }
    return swift::performFrontend(llvm::ArrayRef<const char *>(argv + skip, argv + argc), argv[0],
                                  reinterpret_cast<void *>(&kiln_swift_frontend), nullptr);
}

int kiln_clang(int argc, const char **argv) {
#if KILN_HAS_CLANG_DRIVER
    llvm::ToolContext context{argv[0], nullptr, false};
    return clang_main(argc, const_cast<char **>(argv), context);
#else
    (void)argc;
    (void)argv;
    return -1;
#endif
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

int kiln_clang(int, const char **) { return -1; }

int kiln_lld_link(int, const char **, char **output) {
    if (output) {
        *output = strdup("This build of Kiln does not include the linker.");
    }
    return -1;
}

#endif
