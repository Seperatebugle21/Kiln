# Kiln architecture

Kiln is an iOS IDE for SwiftUI apps. You open an Xcode project, a Swift package or a folder of Swift
files, edit it, and press Run: Kiln compiles the app **on the device** and loads it straight into
its own process, without building or installing an IPA. Claude is built in and can read, edit and
build the project.

## How Run works

```
Save → Syntax check → Entry point → Compile → Link → Sign → dlopen → show
```

1. **Syntax check** (`Build/SyntaxChecker.swift`). SwiftSyntax parses every source file and reports
   syntax errors in under a second, before the compiler runs.
2. **Entry point** (`Build/EntryPointGenerator.swift`). A dylib cannot have its own `@main`, because
   Kiln is already running. The generator removes `@main` from the `App` struct and adds
   `__KilnEntryPoint.swift`, which exports `kiln_entry()`. That function returns a
   `UIHostingController` that shows the content of the app's `WindowGroup`. The App struct's
   properties (for example `@State` models) are copied into that root view.
3. **Compile and link** (`Build/LocalToolchainBackend.swift`, phase 2). The bundled
   `swift-frontend` compiles the prepared sources against the iPhoneOS SDK interfaces, and `lld`
   links them into a dylib. Both run in-process as libraries, because iOS apps cannot start other
   processes.
4. **Sign** (phase 2). iOS only loads a dylib signed by the same team as the app. Kiln signs the
   dylib with the user's development certificate (`.p12`, imported once and stored in the Keychain).
   No JIT is needed for this.
5. **Run** (`Runner/AppRunner.swift`). The dylib is copied to a unique path (dyld caches images by
   path), loaded with `dlopen`, and `kiln_entry` provides the view controller shown full screen.

## Claude

`Assistant/` contains a small Messages API client (Swift has no official Anthropic SDK, so it uses
HTTP) and a tool loop. Claude gets five tools: `list_files`, `read_file`, `edit_file`,
`write_file` and `build_project`. Every file change shows a diff that the user applies or rejects,
unless "Apply Changes Without Asking" is on. The API key is stored in the Keychain.

Requests use adaptive thinking, the effort chosen in Settings, prompt caching, and server-side
refusal fallbacks. Response content (including thinking blocks) is sent back unchanged.

## Phases

| Phase | Scope | Status |
|---|---|---|
| 1 | Editor, project opening, file tree, build pipeline up to the entry point, runner, Claude with tools, CI that builds an unsigned IPA | In progress |
| 2 | Swift toolchain (`swift-frontend` with swift-syntax + `lld`) built for iOS by the Toolchain workflow and linked into Kiln; SDK (as an archive) and compiler resources bundled; Run compiles, links, signs with the user's .p12 and loads on the device | Done |
| 2b | Prebuilt module cache for a fast first build; macro plug-ins (`@Observable`, `#Preview`) | Planned |
| 3 | Incremental builds, SwiftUI macros that are closed source (`#Preview`, `@Entry`), console for `print`, asset catalogs, a relaunch mode for full-fidelity runs | Planned |

### Phase 2 notes

- The Swift compiler is built from `swiftlang/swift` for `arm64-apple-ios`, as static libraries
  with an in-process entry point (`swift::performFrontend`). LLVM's `lld` (Mach-O) does the linking.
- Building the toolchain takes hours, so it gets its own workflow with caching, and its output is
  bundled as `Toolchain/` in the app. Expect an app of 200–400 MB.
- The SDK's `.swiftinterface` and `.tbd` files come from Xcode's iPhoneOS SDK. The frameworks
  themselves are already on the device.
- Macros run as plug-ins. Open-source ones (such as Observation's `@Observable`) are loaded
  in-process; Apple's closed SwiftUI macros need Kiln's own implementations.
- Compiling SwiftUI needs a lot of memory; the app should request the
  `com.apple.developer.kernel.increased-memory-limit` entitlement.

## Building Kiln

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
open Kiln.xcodeproj
```

The **Build Kiln** workflow builds an unsigned IPA on every push. Download it from the workflow run
and sign it with SideStore or your own certificate.
