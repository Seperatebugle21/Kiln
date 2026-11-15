// C entry points into the on-device toolchain, callable from Swift (see the bridging header setting).
#ifndef KILN_TOOLCHAIN_BRIDGE_H
#define KILN_TOOLCHAIN_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/// 1 when this build of Kiln links the Swift compiler and lld, otherwise 0.
int kiln_toolchain_available(void);

/// Runs the Swift compiler in-process, exactly like `swift-frontend <arguments>`.
/// argv[0] is the program name; pass "-frontend" as argv[1]. Diagnostics go to stderr.
int kiln_swift_frontend(int argc, const char *_Nonnull *_Nonnull argv);

/// Runs lld's Mach-O linker in-process, like `ld64.lld <arguments>` (argv[0] must be "ld64.lld").
/// Writes the linker's messages to *output (free it with free()).
int kiln_lld_link(int argc, const char *_Nonnull *_Nonnull argv, char *_Nullable *_Nullable output);

#ifdef __cplusplus
}
#endif

#endif
