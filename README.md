# Ghosted

Ghosted is a Swift package and iOS app shell for route-aware, camera-aware location simulation. The project keeps the portable routing and movement logic separate from the device-specific spoofing mechanisms.

> **⚠️ DISCLAIMER:** This application is provided for educational and authorized testing purposes only. Users are responsible for ensuring their use complies with all applicable laws and regulations in their jurisdiction. See the LICENSE file for full liability disclaimers.

## Project status

Everything in this repo compiles and the test suite passes, but **it is still not a working app.** See AUDIT.md.

- Core library: builds clean under Swift 6. 52 unit tests in 10 suites, all passing.
- App shell: every source file is compiled by a target, and the spoofing stack is
  composed rather than merely written.
- Spoofing and alert layers: iOS-only, so invisible to `swift build`. They are type-checked
  on every push by `Tools/IOSTypeCheck/check.sh`, wired into `.github/workflows/app-typecheck.yml`.
- Device runtime contract: not implemented in compiled code; live validation must
  happen on a real iPhone. `IdeviceBackend` is a state skeleton with no FFI behind it,
  so the session will reach "ready" and then push nothing.

## Architecture

The repo is intentionally split:

- **GhostedCore**: geodesy, route/path logic, quadtree camera indexing, route avoidance, movement simulation, route risk summary
- **Ghosted app**: UIKit shell, composition root, 1 Hz clock, runtime entry point
- **Spoofing layer**: pairing, DDI management, route streaming, loopback reachability, heartbeat and recovery
- **Alert layer**: proximity warning logic while a fake GPS stream is active

`Sources/Spoofing/`, `Sources/Alerts/` and `Sources/Ghosted/` are compiled by the
Xcode app target only — they import UIKit/AVFoundation/CoreLocation, so neither
`GhostedCore` nor the SwiftPM `Ghosted` target can type-check them.

## Quick start

1. Open the package in Xcode or SwiftPM.
2. Run the tests locally:

   ```bash
   swift test
   ```

3. Use the iOS app only on a device that satisfies the runtime contract below.

## Runtime checklist for the iPhone

Use this on the actual device before claiming the spoofing flow works.

1. iOS 17.4 or newer
2. Developer Mode enabled
3. Fresh pairing file generated on a trusted computer and imported
4. Loopback VPN active and device connected to Wi‑Fi
5. Matching DDI mounted for the installed iOS build
6. CoreDevice/RSD location channel opened and heartbeat maintained
7. Background audio + location modes — **enabled** in `Ghosted/Info.plist` and armed
   by `BackgroundKeepAlive` once the session is up
8. Real route push validated while the screen is locked
9. Route and camera logic confirmed against the actual device GPS stream

Steps 1–6 are reachable from the app's **Start session** button, which names the
blocking step instead of failing silently. Steps 7–9 need a real device.

## Device-runtime contract

The live runtime contract is defined by these requirements:

- Pairing must be valid and accepted by the device.
- The loopback address must be reachable from inside the app.
- Developer Mode must be enabled.
- The DDI must match the running iOS build.
- The location-simulation channel must be opened and remain alive.
- The app must recover gracefully from path changes, VPN drops, and tunnel resets.

## Verification

Two independent checks cover the repo, because `swift build` cannot see the iOS app layer:

```bash
swift test                        # 52 tests, 10 suites, all against GhostedCore
Tools/IOSTypeCheck/check.sh 6     # type-check Sources/Spoofing, Sources/Alerts, GhostedApp
python3 Tools/validate-pbxproj.py # check the Xcode project file for structural errors
```

`swift test` covers the portable logic. It compiles only the `Package.swift` targets, so on its
own it says nothing about the roughly half of `Sources/` that belongs to the Xcode app target.
`check.sh` closes that gap on any host with a Swift toolchain, using stub modules in place of the
iOS SDK. It is a type-check, not a build, and it cannot check `@objc`/`#selector` — see
`Tools/IOSTypeCheck/README.md` for exactly what it does and does not prove.

CI runs all of them: `swift.yml` for the package, `app-typecheck.yml` for the app layer
and project structure, and `build-ipa.yml` for a real Xcode build of the app itself.

## Files included

- ARCHITECTURE.md
- AUDIT.md
- README.md
- XCODE.md
- LICENSE
- Ghosted.xcodeproj/     Xcode app + framework targets
- Config/                an intentionally empty entitlements file
- Ghosted/               Info.plist, storyboard, asset catalog
- Sources/               GhostedCore (portable), Ghosted (app shell), Spoofing, Alerts
- Tests/                 SwiftPM tests for GhostedCore
- Config/                the app's entitlements file (empty by design — no private entitlements needed)
- ExportOptions.plist    for a signed local archive (`xcodebuild -exportArchive`)
- Tools/IOSTypeCheck/    stub-SDK type-check harness for the iOS-only app layer
- Tools/validate-pbxproj.py  structural check of the Xcode project file
- .github/workflows/     iOS IPA build + SwiftPM test run + app-layer type-check

## License

This project is licensed under a modified MIT License with enhanced liability disclaimers. See the LICENSE file for details.

## Legal Notice

By using this software, you agree that:
- The authors and contributors assume no liability for any damages or legal consequences resulting from your use of this application.
- You are solely responsible for ensuring your use complies with all applicable local, state, and federal laws.
- You use this software at your own risk.
