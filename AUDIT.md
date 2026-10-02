# Ghosted Audit

**Scope:** structural audit of the repository as committed, plus a compile verification
pass. Claims below are labelled by how they were established, not by intent.

Labels used: **[V]** verified by compiling on a Linux host with a Swift 6.3 toolchain —
**[D]** determined by reading code/config — **[U]** unverified, needs a build.

The iOS app layer cannot be compiled without an iOS SDK. It is covered by a
type-check harness against stub modules (`Tools/IOSTypeCheck/`) instead, which is a real
compile of every source file but cannot validate `@objc`/`#selector` or SDK signature
fidelity. See that directory's README for the exact boundary.

## Build status

- **[V]** `GhostedCore` and its 52 tests compile and **all 52 pass** under Swift 6.3.
- **[V]** `Sources/Spoofing`, `Sources/Alerts` and the `#if os(iOS)` branch of
  `Sources/Ghosted` type-check clean under both `-swift-version 5` and `-swift-version 6`
  against the stub SDK. Not a build: no link, no codegen, no `@objc`.
- **[U]** The iOS app build (`.github/workflows/build-ipa.yml`) is unsigned in CI
  (`CODE_SIGNING_ALLOWED=NO` passed on the command line only, never committed into
  the project, so local Personal Team signing still works). Steps past `actool` and
  the linker remain unverified — no Apple SDK was available on this host.
- **[V]** The project file is structurally sound: every `PBXFileReference` resolves,
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
- `Sources/Ghosted/GhostedApp.swift` is the one and only entry point, and it is the
  only file both the Xcode app target and the `Ghosted` SwiftPM executable target
  compile. On iOS the entry point is `@main` on `AppDelegate`; on the host it is a
  `@main` stub struct. The hand-rolled `UIApplicationMain` wrapper it replaced needed
  `CommandLine.unsafeArgv`, which is internal to the stdlib overlay.
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

**[V] Now covered by a CI type-check.** These five files import UIKit / AVFoundation /
CoreLocation / Network / Security, so they are iOS-only by construction and sit outside
every SwiftPM target — `swift test` cannot compile them. `Tools/IOSTypeCheck/check.sh`
type-checks them against stub modules on any host with a Swift toolchain and runs on every
push via `.github/workflows/app-typecheck.yml`. The harness was validated by deliberately
injecting a type error and confirming the run failed. Its limits are documented in
`Tools/IOSTypeCheck/README.md`; `@objc`/`#selector` still require the real Xcode build.

## Known defects (open)

| # | Issue | Impact |
|---|---|---|
| 1 | ~~Swift language mode differs~~ **CLOSED** | Unified on Swift 6. The Xcode targets now set `SWIFT_VERSION = 6.0` (the stray `SWIFT_LANGUAGE_MODE = "Swift"` overrides, which silently forced Swift 5, are deleted), matching `Package.swift`. Fixing the fallout surfaced two real Swift 6 errors: `NSLock.lock()`/`unlock()` called from `async` in `IdeviceBackend`, and a non-`Sendable` `NWConnection` capture in `LocalSpoofingManager`. Both fixed. The app layer type-checks clean in both modes. |
| 2 | ~~No test or CI type-check for the app layer~~ **CLOSED** | `Tools/IOSTypeCheck/check.sh` type-checks the iOS-only layer against stub SDK modules on any host, wired into `.github/workflows/app-typecheck.yml`. |
| 3 | No Messages extension target | A `.stickersiconset` would be inert; there is no `com.apple.product-type.app-extension` target to consume it. |
| 4 | macOS + watchOS entries in `AppIcon.appiconset` | 20 PNGs, 1.27 MB, for platforms this project has no target for (`TARGETED_DEVICE_FAMILY = 1`). `actool` skips them, so they are dead weight rather than a build error. Measured, not estimated. |
| 5 | `IdeviceBackend` is a state skeleton, not a bridge | It models the state machine `LocalSpoofingManager` needs but calls no FFI. The app will reach `.ready` and then push nothing to the real location service. |

**Closed this pass:** spoofing/alert layers in no target; missing `UIBackgroundModes`;
the duplicate `Config/Info.plist`; the superseded `MovementController` duplicate; the
invalid-capture-list and `let`-outside-`init` errors in the new composition code; defects
#1 and #2 above.

**Hard build blockers found and fixed during the compile pass.** These would each have
stopped Xcode before compiling a single source file:

- **`GhostedCore` had no Info.plist.** The framework target sets
  `BUILD_LIBRARY_FOR_DISTRIBUTION = YES` but had neither `INFOPLIST_FILE` nor
  `GENERATE_INFOPLIST_FILE`, and no `Sources/GhostedCore/Info.plist` exists. Building a
  framework requires one. `GENERATE_INFOPLIST_FILE = YES` added to both configs.
- **`PBXContainerItemProxy` pointed at the wrong object.** The app target's dependency on
  `GhostedCore` used `remoteGlobalIDString = 1100000000000000`, which is the
  `GhostedCore.framework` *file reference*, not the `PBXNativeTarget`. Corrected to
  `4000000000000000`. This was the only `isa`-mismatched reference in the file.

**One judgement call worth flagging.** `IdeviceBackend` was a `final class` marked
`@unchecked Sendable` whose four mutable fields were guarded by an `NSLock` used in
exactly one method — the other three were read and written unguarded from other `async`
methods. That is a genuine data race, not merely a style problem, and the concurrency
conformance only concealed it. Converting the class to an `actor` removes the lock
entirely and makes the isolation real; every entry point was already `async` to satisfy
`DeveloperServicesBackend`, so nothing else changed. Note this is *not* a substitute for
`Synchronization.Mutex`, which would have been the obvious fix but requires iOS 18 against
this project's iOS 17.4 floor.

## Second pass — code defects and loose ends

A follow-up sweep for defects that survive compilation but misbehave, and for files
nothing references. All **[V]** verified on this host unless noted.

**Runtime defects fixed**

| # | Where | Defect |
|---|---|---|
| 1 | `RouteStreamer.start` | `Task.cancel()` is cooperative, so a superseded run can still be suspended inside `sink(...)` when its replacement is installed. Its trailing `self.task = nil` then nulled the **new** run's handle: `isRunning` reported `false` and `stop()` had nothing to cancel, while a live task kept pushing positions to the device. Fixed with a generation counter — a run only clears `task` if it is still current. |
| 2 | `BackgroundKeepAlive.start` | `startSilentAudio()` throws *after* `startUpdatingLocation()` has run. `SpoofingSession` only stored the instance on success, so a failed start left background location armed, the location indicator visible and the audio session active for the rest of the process, with no reference able to turn any of it off. `start()` now tears itself down on any throw. |
| 3 | `IdeviceBackend.mountDDI` | `contentsOfDirectory` threw a bare `NSCocoaErrorDomain` error when `Documents/DDI` did not exist — the normal case on a fresh install. Not a `LocalizedError`, so the UI rendered `Error Domain=NSCocoaErrorDomain Code=260 …`. Now every failure becomes a `SpoofError.ddiMountFailed` naming the exact folder and what to put in it. |
| 4 | `Once.run` (`LocalSpoofingManager`) | Ran `body()` — which resumes a `CheckedContinuation` — while holding a non-recursive `NSLock`. A resumed task running on the same thread and re-entering would self-deadlock. `body()` now runs after the lock is released. |

**Loose ends closed**

| Where | Was | Now |
|---|---|---|
| `Config/Ghosted.entitlements` | On disk, referenced by nothing — no file reference, no build setting | Wired in via `CODE_SIGN_ENTITLEMENTS`, given a `PBXFileReference` and a `Config` group. Still empty by design, but no longer an orphan. |
| `ExportOptions.plist` | On disk, referenced by nothing | `XCODE.md` documents the `xcodebuild -exportArchive` command that consumes it, for a locally signed archive. `build-ipa.yml` explains why CI cannot use it. |
| `.vscode/launch.json` | `cwd` was `${workspaceFolder:Ghosted}` — the resources directory, which has no `Package.swift`, so SwiftPM could not resolve the package | `${workspaceFolder}`. |
| `build-ipa.yml` | A `pod install` step guarded by `if [ -f "Podfile" ]`. There is no Podfile and never will be — there are no dependencies | Removed. |
| `ARCHITECTURE.md` | Project tree listed `Resources/cameras.geojson`, a file that does not exist and is not bundled | Replaced with a real explanation of where the camera export actually goes. |
| `Package.swift`, `XCODE.md` | Pointed at `AUDIT.md defect #2` and `#3` for questions those defects no longer answered | Updated to describe the checks that now exist. |

**Added:** `Tools/validate-pbxproj.py`, a structural check of the project file — dangling
object references, `PBXBuildFile` ownership, and file references that exist on disk but are
not reachable from `mainGroup` (i.e. would never be compiled). It runs in CI and was
verified to fail on deliberately injected damage. The iOS app layer is now checked three
ways on every push: Swift 6 type-check, Swift 5 regression type-check, project structure.

**Still true, deliberately not changed**

- `ExportOptions.plist`'s `method: development` is correct for the sideload-only,
  AltStore-re-signed workflow this project targets. Changing it to `app-store` would be
  wrong.
- `AppIcon.appiconset` keeps 20 macOS/watchOS PNGs. They are dead weight but harmless, and
  deleting them would be churn the moment a second platform is considered.
- A real feature gap, not a defect: `AvoidanceRouter`, `ExposureAnalyzer`,
  `RouteExposureStatus`, `RouteProvider` and `RouteCandidate` are implemented and tested in
  `GhostedCore`, and the app layer calls **none** of them. The README's "route-aware,
  camera-aware" claim is only half-delivered — camera proximity alerts work, route avoidance
  is library-only. Wiring it up is feature work, not cleanup, so it is left as-is and
  recorded here rather than quietly deleted or quietly ignored.

  **Resolved.** `RoutePlanner` (Sources/Ghosted) now sits between the UI and
  `AvoidanceRouter`, and `SpoofingSession.planAndDrive(from:to:)` is the entry point the
  Start button calls. Three production `RouteProvider` implementations ship in
  `Sources/GhostedCore/RouteProviders.swift` (OSRM, Valhalla, GraphHopper), selected by
  `GhostedRoutingBaseURL` / `GhostedRoutingAPIKey` in Info.plist. `URLSessionTransport` is
  the only place a real socket exists.

**One trap worth knowing:** `Sources/Ghosted` is simultaneously the Xcode app target's
source root *and* the SwiftPM `Ghosted` target's `path`. A new file dropped there is
compiled by both. `SpoofingSession.swift` and `RouteStreamer.swift` initially were not
guarded, so `swift build` on macOS would have failed to resolve
`LocalSpoofingManager` / `IdeviceBackend` / `BackgroundKeepAlive` /
`ProximityAlertManager` — classes that exist only in the Xcode target. The iOS build
did not catch this, because Xcode has all of it in one target. Both files are now
`#if os(iOS)`.

## Risk assessment
- Program structure: **[D]** coherent; the core/app split is real and enforced by the target graph.
- Core logic: **[V]** compiles and all 52 tests pass. This is the one layer with real test coverage.
- App shell: **[V]** single entry point, no duplicated `@main`, and type-checks clean in both language modes.
- Native device integration: **[U]** abstraction present and now compiled into the app, but the FFI is unwritten and nothing is hardware-validated.
- Overall: **compiles, tested, type-checked — and still not a working app.** The gap is entirely device-bound.

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
The repository **compiles, passes its tests, and type-checks its entire app layer** on
a host with no Apple toolchain. Structure, target graph and project file are sound, and
every source file is now covered by some check on every push.

What that does *not* mean: the app has never been built by Xcode, no signature has ever
been produced, and the spoofing stack is still a state skeleton with no FFI behind it, so
it reaches `.ready` and pushes nothing. Treat "implemented" in the source as
"compiles and type-checks", not "working on a device". Everything outstanding is
device-bound and listed below.

**Requires a real Xcode build to close out.** These cannot be settled on Linux and are the
only reason a Mac pass is still needed:

1. `@objc` / `#selector` on the `AppDelegate` target-action methods — no ObjC runtime here.
2. The stub SDK's fidelity against Apple's real annotations, in particular whether
   `AVAudioSession` and `CLLocationManagerDelegate` are `@MainActor`, and whether
   `NWConnection` is `Sendable`. If Apple's SDK *does* mark `NWConnection` `Sendable`, the
   `@preconcurrency import Network` in `LocalSpoofingManager.swift` becomes redundant and can
   be dropped; if it does not, it is required.
3. `build-ipa.yml` has still never been executed against this wiring.
