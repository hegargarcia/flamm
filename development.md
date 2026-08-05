# Development

This guide covers building, testing, installing, and packaging Flamm from
source.

## Requirements

- macOS 13 Ventura or newer
- Swift 5.9 or a compatible Xcode toolchain
- An SSH target configured for non-interactive authentication when testing a
  live tunnel

The build uses only tools included with macOS and the Swift toolchain. Full
Xcode is not required when the Swift command-line tools are installed.

## Run during development

```sh
swift run Flamm
```

Because Flamm is a menu-bar app, it does not open a Dock icon or a normal app
window. Use its status item to open the menu and **Settings**.

## Test

```sh
./Scripts/test.sh
```

The script runs focused self-tests for port models, reachability checks, and SSH
config parsing, then verifies the full Swift package builds.

## Build the app

```sh
./Scripts/build-app.sh
open build/Flamm.app
```

This creates an ad-hoc signed Release app at `build/Flamm.app`. Pass `debug` to
the script for a Debug bundle. Release metadata can be overridden when needed:

```sh
FLAMM_VERSION=1.1.0 FLAMM_BUILD_NUMBER=2 ./Scripts/build-app.sh release
```

## Install from source

```sh
./Scripts/install.sh
```

This builds Flamm, copies it to `~/Applications/Flamm.app`, and opens it.

## Package a disk image

```sh
./Scripts/package-dmg.sh
```

The script builds the Release app and writes a compressed `.dmg` plus its
SHA-256 checksum to `Artifacts/`. The image contains **Flamm.app** and an
**Applications** shortcut for drag-and-drop installation.

## Project layout

```text
Sources/Flamm/       App, menu, settings, SSH, and reachability code
Tests/FlammTests/    Focused executable self-tests
assets/              App icon source and README banner
Scripts/             Build, test, install, and packaging tools
```
