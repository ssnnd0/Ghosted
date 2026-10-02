# IOSTypeCheck

Type-checks the iOS-only app layer on any host with a Swift toolchain — **no iOS SDK and no macOS required.**

```sh
Tools/IOSTypeCheck/check.sh        # Swift 6 (what the Xcode targets now use)
Tools/IOSTypeCheck/check.sh 5      # Swift 5, for regression comparison
```

## Why this exists

Roughly half of `Sources/` — all of `Sources/Spoofing`, all of `Sources/Alerts`, and the
`#if os(iOS)` branch of `Sources/Ghosted` — is compiled by exactly one target: the iOS app target in
`Ghosted.xcodeproj`. It is invisible to `swift build`, which compiles only the `Package.swift`
targets (`GhostedCore` and its test suite).

Until `.github/workflows/build-ipa.yml` existed, that meant a change to those files could break the
iOS build without any local command or any CI job noticing. AUDIT.md logged this as defect #2.
This script is the cheap, fast signal that closes it, running in well under a minute on a Linux
container.

## How it works

1. `swift build --target GhostedCore` — produces the `GhostedCore.swiftmodule` the app layer imports.
2. Compiles `Stubs/*.swift` into fake `UIKit`, `CoreLocation`, `AVFoundation`, `Network` and
   `Security` modules. Each stub declares only the API surface these files actually touch.
3. Copies the app-layer sources to a temp dir with `#if os(iOS)` rewritten to `#if true`.
4. Runs `swiftc -typecheck -swift-version 6` over the copies against the stubs.

## What it does NOT check

Be precise about this, because a green run is weaker than "the app builds":

- **It is not a build.** `-typecheck` only. No linking, code generation, asset catalog, storyboard
  compilation, or code signing. Nothing here proves the app can be produced or installed.
- **No Objective-C runtime.** On Linux and on macOS's Swift toolchain, `@objc`, `#selector`, and the
  `@main`-synthesised `UIApplicationMain` call on `AppDelegate` cannot be compiled. `check.sh`
  rewrites those three away, so they are **not** verified here. The real Xcode build in
  `build-ipa.yml` is still the only thing that checks them.
- **Stub fidelity is unverified.** If the real SDK's signature differs from a stub, this harness will
  report the stub's view and miss the mismatch. When a stub disagrees with the real SDK, the harness
  is wrong, not the app. `Stubs/*.swift` carries a comment block per file listing the fidelity traps
  already hit, so extend them the same way.
- **No `@testable` coverage of the app layer.** There are unit tests for `GhostedCore` only.

## When it gives a false positive

Almost always one of these, in order of likelihood:

1. A stub is missing a member — add it to the relevant `Stubs/*.swift`.
2. A stub has the member in the wrong place (e.g. a static factory on the wrong class).
3. A stub's isolation annotation is wrong. Swift 6 infers `@MainActor` for a bare top-level `let`,
   so SDK constants must be declared `nonisolated(unsafe)`; real SDK types that are `@MainActor`
   (UIKit's, in practice) must be marked as such or isolation errors get missed entirely.
4. An SDK type is genuinely not `Sendable` and the code needs `@preconcurrency` or a box.

Do **not** "fix" a real source file to satisfy a stub until you have confirmed against the real SDK.