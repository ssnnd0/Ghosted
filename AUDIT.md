# Ghosted Audit

**Scope:** structural audit of the repository as committed. Performed on a Linux host
with no Swift toolchain and no iOS SDK, so **nothing in this repo was compiled during
the audit.** Claims below are labelled by how they were established, not by intent.

Labels used: **[V]** verified mechanically on this host — **[D]** determined by reading
code/config — **[U]** unverified, needs a build.

## Build status

- **[U]** `GhostedCore` and its 52 tests have never been compiled. `ARCHITECTURE.md`
  records this ("none of this has been compiled"); the previous revision of this file
  claimed `swift test` passed, which nothing in the repository substantiates.
  `.github/workflows/swift.yml` runs `swift build` / `swift test` on macOS, but its
  result is not recorded in the repo.
- **[U]** The iOS app build (`.github/workflows/build-ipa.yml`) is unsigned in CI
  (`CODE_SIGNING_ALLOWED=NO` passed on the command line only, never committed into
  the project, so local Personal Team signing still works). Steps past `actool` and
  the linker are unverified.
- **[D]** The project file is structurally sound: every `PBXFileReference` resolves,
  every build-file entry is owned by exactly one phase, and the app target links and
  embeds `GhostedCore.framework`.

## Architecture compliance

### Core library — [D] clean
`Sources/GhostedCore/` is portable, imports only `Foundation`, and is in no UI
framework. It is the single implementation of:
- `GeoMath` geodesy
- `CameraIndex` quadtree indexing and GeoJSON loading
- `AvoidanceRouter` exposure evaluation and waypoint detour heuristics
- `MovementSimulator` route driving simulation
- `RouteExposureStatus` runtime risk summary

The earlier `Sources/Routing/` copies of `GeoMath` / `CameraIndex` / `AvoidanceRouter`
were a pre-refactor set written against `CLLocationCoordinate2D`. They were
referenced by no build target, package, or workflow, and have been deleted.

### App boundary — [D] clean, now single-sourced
- `Sources/Ghosted/GhostedApp.swift` is the one and only `@main`. Both the Xcode app
  target and the `Ghosted` SwiftPM executable target compile this same file.
- `Sources/Ghosted/RuntimeContract.swift` backs the on-screen contract checklist. It
  now takes live status overrides instead of hardcoding every row to `.pending`.
- `Sources/Ghosted/SpoofingSession.swift` is the composition root.
- `Sources/Ghosted/RouteStreamer.swift` is the 1 Hz clock around `MovementSimulator`.
- The app owns no routing logic; it reads the `GhostedCore` contract.

This was previously two near-identical copies (`App/GhostedApp.swift` and
`Sources/Ghosted/Ghosted.swift`) that had already drifted — the Xcode copy had gained
the runtime-contract checklist, the package copy had not. The Xcode-only `App/`
directory is gone.

### Spoofing boundary — [D] now compiled by the app target
`Sources/Spoofing/` and `Sources/Alerts/` were documented design intent compiled by
nothing. They are now in the Xcode app target and connected:
- `IdeviceBackend` — native bridge shell for the idevice/CoreDevice/RSD route
- `LocalSpoofingManager` — reachability, pairing, DDI mounting, recovery, heartbeat
- `BackgroundKeepAlive` — keeps execution alive across the spoofed stream
- `ProximityAlertManager` — simulated-position proximity warnings
- `SpoofingSession` (`Sources/Ghosted/`) — the only place the five above meet. Every
  position flows through `LocalSpoofingManager.setLocation(_:)`, the single seam where
  recovery happens.

Three things had to change to make them compile:

1. **[D] Wrong coordinate type.** All five were written against
   `CLLocationCoordinate2D`, but `GhostedCore` was refactored to the `Coordinate`
   value type. `Geo.haversine`, `Geo.bearing`, `Geo.destination`, `RoutePath.init`,
   `RoutePath.sample` and `CameraQuadtree.query` all take `Coordinate`. Neither
   `MovementController` nor `ProximityAlertManager` even imported `GhostedCore`.
2. **[D] A third superseded duplicate.** `Sources/Spoofing/MovementController` was an
   actor holding a private copy of the movement physics plus private `MovementProfile`
   and `MovementUpdate` types that **shadowed the tested ones**. `GhostedCore.MovementSimulator`
   is the same algorithm made clock-free and seedable, covered by the 52 tests. The
   actor version was deleted and replaced by `RouteStreamer`. This is the same
   pre/post-refactor pattern as the deleted `Sources/Routing/` copies.
3. **[D] `UIBackgroundModes`.** `BackgroundKeepAlive` sets
   `allowsBackgroundLocationUpdates = true`, which raises an Objective-C exception and
   **crashes the app** unless the `location` mode is declared. `Ghosted/Info.plist` now
   declares `audio` and `location`, plus `NSLocalNetworkUsageDescription` (the loopback
   probe) and file sharing (pairing file, DDI, `cameras.geojson` land in Documents).

`Config/Info.plist` was a second, divergent Info.plist that was *richer* than the active
one. Its functional keys have been merged into `Ghosted/Info.plist` and it was deleted;
only `$(GMS_API_KEY)` was unique to it, and no Google Maps SDK is linked, so nothing
read it. `Config/Ghosted.entitlements` remains — empty by design and referenced by
`ARCHITECTURE.md` as an example.

**[D] Not covered by any test or CI type-check.** These five files import UIKit /
AVFoundation / CoreLocation / Network / Security, so they are iOS-only by construction
and sit outside every SwiftPM target. `swift test` does not compile them, and
`swift.yml` does not either. The only thing that type-checks them is the iOS build in
`build-ipa.yml`. **[U]** That build has not been run against this wiring.

## Known defects (open)

| # | Issue | Impact |
|---|---|---|
| 1 | Swift language mode differs: Xcode `SWIFT_VERSION = 5.9` / `SWIFT_LANGUAGE_MODE = "Swift"` vs `Package.swift` `swiftLanguageModes: [.v6]` | `GhostedCore` is type-checked under strict Swift 6 concurrency by `swift.yml` but under Swift 5 in the app build. The weaker check is the one that produces the shipping binary. Unifying on Swift 6 is a real behaviour change and cannot be validated on this host. |
| 2 | The wired app layer has **no test or CI type-check** | `Sources/Spoofing`, `Sources/Alerts` and most of `Sources/Ghosted` are iOS-only and outside every SwiftPM target. Nothing but the iOS build compiles them, so a signature slip can reach `master` unnoticed. |
| 3 | No Messages extension target | A `.stickersiconset` would be inert; there is no `com.apple.product-type.app-extension` target to consume it. |
| 4 | macOS + watchOS entries in `AppIcon.appiconset` | 30 files, ~2.7 MB, unreferenced by an iPhone-only target (`TARGETED_DEVICE_FAMILY = 1`). They still carry an alpha channel, which would matter if a Mac Catalyst target were ever added. |
| 5 | `IdeviceBackend` is a state skeleton, not a bridge | It models the state machine `LocalSpoofingManager` needs but calls no FFI. The app will reach `.ready` and then push nothing to the real location service. |

**Closed this pass:** spoofing/alert layers in no target; missing `UIBackgroundModes`;
the duplicate `Config/Info.plist`; the superseded `MovementController` duplicate; the
invalid-capture-list and `let`-outside-`init` errors in the new composition code.

## Risk assessment
- Program structure: **[D]** coherent; the core/app split is real and enforced by the target graph.
- Core logic: **[U]** written and unit-tested in intent, never compiled. Treat as a reasoned first draft.
- App shell: **[D]** single entry point, no duplicated `@main`, and the spoofing stack is now actually composed rather than merely written.
- Native device integration: **[U]** abstraction present and now compiled into the app, but the FFI is unwritten and nothing is hardware-validated.
- Overall: **architecture-complete, still unbuilt, not device-ready.**

## Remaining device-bound constraints
These cannot be settled on any host, only on an iPhone:
1. Real idevice pairing and developer-service tunnel authentication
2. CoreDevice / RSD / DVT location-simulation channel negotiation
3. Local loopback VPN + device-private service reachability
4. iOS background execution under real sideloaded conditions
5. Live route sending to the system location service on hardware

## Concrete iPhone checklist
1. Confirm the phone runs iOS 17.4 or newer (the project floor).
2. Turn on Developer Mode: Settings → Privacy & Security → Developer Mode.
3. Generate a fresh pairing file from a trusted computer and import it into the app.
4. Keep the loopback VPN running and ensure the device is on Wi-Fi.
5. Mount the correct DDI for the installed iOS build: `BuildManifest.plist`, `Image.dmg`, `Image.dmg.trustcache`.
6. Verify the app can open the CoreDevice/RSD location-simulation channel and keep the heartbeat alive.
7. Confirm the app can push a live route while the screen is locked and stays alive in the background.
8. Validate the route stream appears to other apps as the system location source.

Steps 1–6 are reachable from the app's **Start session** button, which reports the
blocking step in `SpoofError.errorDescription` instead of failing silently. Steps 7 and
8 cannot pass until `IdeviceBackend` speaks to the real channel — today the state
machine completes and pushes nowhere.

## Verdict
The repository is a well-organised **unbuilt draft**. Structure, target graph and
project file are sound, and every source file is now compiled by some target. Nothing
has been built: the core library has never compiled, the 52 tests have never run, and
the spoofing stack is a state skeleton with no FFI behind it. Treat "implemented" in
the source as "written", not "working".
