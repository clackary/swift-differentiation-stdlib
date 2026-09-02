# swift-differentiation-stdlib

This repo wraps a precompiled build of the `_Differentiation` module from the Swift standard library, packaged as an XCFramework with macOS, iOS, and iOS simulator slices (arm64).

This is a required dependency for working with swift-differentiation on OS versions 26.4 and above. As of 26.4 the OSses no longer ship with the `_Differentiation` module as part of the system libraries.

Versioning of this library works similar to [swift-syntax](https://github.com/swiftlang/swift-syntax) where every compiler version will get a matching release. For example the matching release for Swift 6.3 will be `"603.0.0"`.

The XCFramework is not committed. Each release publishes it as a release asset, and `Package.swift` points at that URL with a SHA256 that SwiftPM verifies on download.

## Adopting

While this package can be adopted directly, it can also be adopted by importing the `Differentiation` module from [swift-differentiation](https://github.com/differentiable-swift/swift-differentiation), which re-exports `_Differentiation` with additional apis.

## Releasing

Two scripts, run in order. `Tools/build-library.sh` produces and verifies the XCFramework; `Tools/release.sh` publishes it and updates `Package.swift`. Neither one calls the other, so you can inspect the artifact before deciding to release it.

### Prerequisites

**1. Check out the Swift sources at the target tag.**

```sh
git clone https://github.com/swiftlang/swift.git
cd swift
git checkout swift-6.3.3-RELEASE
```

**2. Install the matching toolchain with swiftly.**

```sh
swiftly install 6.3.3
```

This lands in `~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain`, which is the path you pass to `--toolchain` below.

**3. Install and authenticate the GitHub CLI — optional.**

```sh
brew install gh
gh auth login
```

Only needed if you intend to publish the framework as a release asset. Building and verifying an XCFramework needs nothing from GitHub, and `Tools/release.sh --dry-run` skips the check too.

### Build

```sh
./Tools/build-library.sh \
  --swift-source <swift checkout> \
  --toolchain ~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain \
  --output /tmp/_Differentiation.xcframework
```

### Publish

```sh
Tools/release.sh \
  --artifact /tmp/_Differentiation.xcframework \
  --swift-version swift-6.3.3-RELEASE \
  --package-version 603.3.0
```

Add `--dry-run` first. That zips the artifact and prints the asset name, URL, and checksum without touching git or GitHub, which is enough to confirm the release will land where you expect.

The real run zips the artifact, writes the URL and checksum into `Package.swift`, commits and tags, pushes, and creates the GitHub release with the zip attached. It requires a clean working tree and refuses to reuse an existing tag.

Two notes on the arguments:

- `--swift-version` is just a label. It is used to name the asset and in the release notes. There are no hard checks it actually built the artifact, allowing for some customization. It has been necessary in the past to modify compiler sources, due to rare cases when Xcode and open source toolchains disagree about the module causing mismatched SDK failures. Any changes from the tagged swift version should be documented in release notes.

## Layout

```
_Differentiation.xcframework/
├── Info.plist                  lists the three slices below
├── macos-arm64/
│   ├── _Differentiation.framework/
│   └── dSYMs/
├── ios-arm64/
│   ├── _Differentiation.framework/
│   └── dSYMs/
└── ios-arm64-simulator/
    ├── _Differentiation.framework/
    └── dSYMs/
```

`Tools/build-library.sh` builds each slice as a `.framework` bundle with a matching dSYM, then hands them to `xcodebuild -create-xcframework`, which assembles the directory above. xcodebuild names each slice directory itself, deriving the platform, architecture and variant from the binary's Mach-O load commands, and records them in the top-level `Info.plist` along with a `DebugSymbolsPath` pointing at each `dSYMs/`. The macOS framework uses the versioned bundle layout while the iOS ones are flat, which is platform convention rather than a choice the build makes.
