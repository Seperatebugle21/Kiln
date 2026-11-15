# Kiln

An iOS IDE for writing, compiling and running SwiftUI apps right on your iPhone, with Claude built in.

- **Open** an Xcode project, a Swift package or a folder of Swift files from the Files app.
- **Edit** with a code editor made for touch: Swift colouring, auto-indent and a symbol bar.
- **Run** without building an IPA: Kiln compiles on the device and loads the app into itself.
- **Ask Claude** to add features, explain code or fix build errors. Claude reads and edits your
  files and builds the project; you approve every change.

Kiln requires iOS or iPadOS 26.

## Status

Kiln compiles, links, signs and runs SwiftUI apps on the iPhone itself: the Swift compiler and lld
run inside Kiln, the app is signed with your developer or enterprise certificate (Settings › Build)
and loaded without JIT. Macros in your own code (`@Observable`, `#Preview`) are not supported yet.
See [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md) for how it works and the plan.

## Install

1. Open the latest **Build Kiln** workflow run under Actions and download `Kiln-unsigned-ipa`.
2. Sign and install `Kiln.ipa` with SideStore or your own development certificate.
3. In Kiln, open Settings › Build and import the same .p12 certificate Kiln is signed with.
4. Optionally add your Anthropic API key (Claude) or a GitHub token (sync) in Settings.

## Build from source

```sh
brew install xcodegen
xcodegen generate
open Kiln.xcodeproj
```
