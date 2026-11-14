# Kiln

An iOS IDE for writing, compiling and running SwiftUI apps right on your iPhone, with Claude built in.

- **Open** an Xcode project, a Swift package or a folder of Swift files from the Files app.
- **Edit** with a code editor made for touch: Swift colouring, auto-indent and a symbol bar.
- **Run** without building an IPA: Kiln compiles on the device and loads the app into itself.
- **Ask Claude** to add features, explain code or fix build errors. Claude reads and edits your
  files and builds the project; you approve every change.

Kiln requires iOS or iPadOS 26.

## Status

Kiln is in early development. The editor, project handling, Claude integration, syntax checking and
the run pipeline are in place. The on-device Swift compiler is the next phase; until it is bundled,
Run stops after the syntax check with a clear message. See
[Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md) for how it works and the plan.

## Install

1. Open the latest **Build Kiln** workflow run under Actions and download `Kiln-unsigned-ipa`.
2. Sign and install `Kiln.ipa` with SideStore or your own development certificate.
3. In Kiln, open Settings and add your Anthropic API key to use Claude.

## Build from source

```sh
brew install xcodegen
xcodegen generate
open Kiln.xcodeproj
```
