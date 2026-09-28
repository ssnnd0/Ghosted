# Xcode Setup for Ghosted

## Repository

The Ghosted project is hosted at: https://github.com/ssnnd0/Ghosted

## Project Structure

`Ghosted.xcodeproj` defines exactly **two** targets and **one** shared scheme. There is
no test target in the Xcode project — the unit tests are a SwiftPM concern (see below).

### Targets

1. **GhostedCore** (`com.apple.product-type.framework`)
   - Cross-platform Swift library for geodesy, routing, and movement simulation
   - Imports only `Foundation` — no UIKit/AVFoundation, so it builds on macOS, Linux and Windows
   - Location: `Sources/GhostedCore/` (6 files)
   - No framework dependencies. Its *Frameworks* build phase is deliberately empty:
     a framework that links itself fails at link time.

2. **Ghosted** (`com.apple.product-type.application`)
   - iOS-only app shell that composes the on-device spoofing stack
   - Depends on the GhostedCore framework
   - Sources: `Sources/Ghosted/` (entry point, composition root, 1 Hz clock),
     `Sources/Spoofing/` (lifecycle state machine, native bridge, keep-alive),
     `Sources/Alerts/` (proximity warnings)
   - These are compiled by the Xcode target only. They import
     UIKit/AVFoundation/CoreLocation, so neither the portable `GhostedCore` target
     nor the SwiftPM `Ghosted` target can type-check them — `swift test` does not
     cover this code.
   - `Sources/Ghosted/` *is* also compiled by the SwiftPM `Ghosted` target, so the
     app has a single `@main` shared by both build systems.

### Scheme

Only `Ghosted.xcscheme` is shared. Its Test action has **no testables** — the 52
`GhostedCore` tests live in `Tests/GhostedTests/` and run through SwiftPM
(`swift test`), not `xcodebuild test`.

## Build Configuration

### iOS App Target

- **Product Name:** Ghosted
- **Bundle Identifier:** com.ssnn.Ghosted
- **Deployment Target:** iOS 17.4 (set once at project level, inherited by both targets)
- **SDK:** iphoneos
- **Device Family:** iPhone only (`TARGETED_DEVICE_FAMILY = 1`)
- **Swift Language Version:** 5.9
- **Main Interface:** `LaunchScreen` (`UILaunchStoryboardName`)
- **Signing:** `CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM = ""` — set your Personal
  Team in Xcode for local device builds. CI bypasses signing on the command line only,
  so nothing in the project disables it.

### Framework Target

- **Product Name:** GhostedCore
- **Bundle Identifier:** com.ssnn.GhostedCore
- **Build Library for Distribution:** YES
- **Swift Language Mode:** `Swift` (Swift 5)

> SwiftPM builds this same code in `swiftLanguageModes: [.v6]`. The two toolchains
> therefore type-check `GhostedCore` under different concurrency rules, and the
> looser one is what produces the shipping binary. See AUDIT.md defect #3.

## App Resources

- **Launch Screen:** `Ghosted/LaunchScreen.storyboard`
- **App Configuration:** `Ghosted/Info.plist`
- **Assets Catalog:** `Ghosted/Assets.xcassets/`
  - `AppIcon.appiconset/` — iOS icons only; the macOS/watchOS entries are unreferenced
  - `AccentColor.colorset/`

`Config/Ghosted.entitlements` is **not** wired into the build. It is empty by
design — the design requires no private entitlements, and `ARCHITECTURE.md` points
at it as an example.

`Ghosted/Info.plist` is the only Info.plist. It declares
`UIBackgroundModes = [audio, location]`, which `BackgroundKeepAlive` requires:
setting `allowsBackgroundLocationUpdates = true` without the `location` mode raises
an Objective-C exception and crashes the app. File sharing is enabled so the pairing
file, the DDI folder and `cameras.geojson` can be dropped into Documents.

## Key Build Phases

### iOS App Target (`Ghosted`)

| Order | Phase | Contents |
|---|---|---|
| 1 | Sources | `GhostedApp.swift`, `SpoofingSession.swift`, `RouteStreamer.swift`, `RuntimeContract.swift`, `LocalSpoofingManager.swift`, `IdeviceBackend.swift`, `BackgroundKeepAlive.swift`, `ProximityAlertManager.swift` |
| 2 | Resources | `LaunchScreen.storyboard`, `Assets.xcassets` |
| 3 | Frameworks | `UIKit.framework` (SDKROOT), `GhostedCore.framework` |
| 4 | Embed Frameworks | `GhostedCore.framework` (`CodeSignOnCopy`, `RemoveHeadersOnCopy`) |

Notes:
- `Info.plist` is **not** in Copy Bundle Resources. It is referenced only by
  `INFOPLIST_FILE`; copying it produces a `duplicate output file` error.
- `GhostedCore.framework` must be both linked *and* embedded, or the app builds
  cleanly and then crashes at launch with a missing-framework dyld error.
- A `PBXBuildFile` entry may belong to exactly one phase. Sharing one ID across the
  app's and the framework's Frameworks phases makes the framework link itself.
- `AVFoundation`, `CoreLocation`, `Network` and `Security` are **not** listed in the
  Frameworks phase. Swift emits autolink flags from each `import`, so explicit entries
  would be redundant.

### GhostedCore Framework

- Sources: all 6 `.swift` files in `Sources/GhostedCore/`
- Frameworks: empty (by design)
- Public interfaces exposed via module definition

## SwiftPM (host-side tests)

```
swift build --target GhostedCore
swift test
```

`Package.swift` declares `platforms: [.iOS(.v17), .macOS(.v13)]` and the
`GhostedCore`, `Ghosted` (executable stub off-iOS) and `GhostedTests` targets.
`.github/workflows/swift.yml` runs `swift build` and `swift test` on macOS.

The 52 tests cover `GhostedCore` only. `Sources/Spoofing`, `Sources/Alerts` and most
of `Sources/Ghosted` are iOS-only and outside every SwiftPM target, so **no test or
CI job type-checks them.** The iOS build in `build-ipa.yml` is their only check.

## Opening in Xcode

1. Clone the repository
2. Open `Ghosted.xcodeproj`
3. Select the **Ghosted** scheme and an iOS device or simulator
4. For a physical device: set your Personal Team under Signing & Capabilities, and
   install the app's provisioning profile on the phone (Settings → General → VPN &
   Device Management → trust the developer)

## Using the app

The shell has a **Start session** button that runs the real bring-up sequence —
loopback probe, pairing load, Developer Mode check, DDI mount, channel open, then
background privileges. **On a simulator or a phone without Developer Mode, Developer
VPN and a DDI folder in `Documents/DDI/`, it will fail**, and the status line shows
which step blocked. That is the intended behaviour: `SpoofError` distinguishes
"retry later" from "the user must fix something first".

Drop these into the app's `Documents` folder (file sharing is on):
- `cameras.geojson` — camera export; without it proximity alerts are inert
- `DDI/` — containing `BuildManifest.plist`, `Image.dmg`, `Image.dmg.trustcache`

## Deployment Requirements

The iOS app requires:

- iOS 17.4 or newer
- Developer Mode enabled on device
- Fresh pairing file for DDI management
- Loopback VPN active and connected to Wi-Fi
- Matching DDI mounted for the installed iOS build
- CoreDevice/RSD location channel opened and heartbeat maintained
- Background audio + location execution — **enabled** in `Ghosted/Info.plist` and
  armed by `BackgroundKeepAlive` once the session is up. Silent-audio keep-alive
  violates App Store guidelines, so this build is sideload-only.

See ARCHITECTURE.md and AUDIT.md for the runtime contract and current state.
