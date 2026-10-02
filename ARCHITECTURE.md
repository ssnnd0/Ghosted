# Ghosted — architecture notes

**Status:** the portable library compiles and its 52 tests pass; the iOS app layer is type-checked on every push against stub SDK modules (`Tools/IOSTypeCheck/`). The native `idevice` layer is still a skeleton with no FFI behind it. Swift 6 language mode, iOS 17.4+.

## Where the original prompt's premises were wrong

| Prompt says | Reality |
|---|---|
| "Zero external hardware / no connected Mac" | Only true *after* a one-time setup. You need a pairing file generated from a trusted computer (Mac, Windows or Linux tool). Everything after that runs on the phone. |
| "Replace lockdownd with RSD over QUIC; write the bridging logic" | Don't hand-roll this. On-device tools use the `idevice` library (Rust with a C FFI) for pairing, tunnel, RSD and the location service. StikDebug's stack covers iOS 17.4+; 17.3 and below use different protocols and aren't covered. |
| "Local loopback/Wi-Fi pairing" | Reaching the device's own services from inside an app needs a **loopback VPN** app (e.g. LocalDevVPN) running alongside. Reuse it. Building your own needs the Network Extension entitlement, which free accounts lack. |
| "Private entitlements in Info.plist" | Entitlements aren't Info.plist keys. This design needs none (see `Config/Ghosted.entitlements`). TrollStore, as far as I know, only exists for iOS ≤ 17.0, which is below the 17.4 floor of this stack. |
| "GoogleMaps SDK … turn-by-turn overlay" | The standard Maps SDK draws maps, traffic and polylines. Turn-by-turn is a separate, access-gated product (Navigation SDK). Without it, build the overlay from the Routes API's step instructions plus your own progress tracking. |
| "Quadtree so thousands of pins don't OOM" | The *data* is tiny (100k points ≈ a few MB). The OOM risk is creating thousands of `GMSMarker`s. The fix is viewport-limited, clustered rendering (below). The quadtree earns its keep on the routing side. |
| "Insert waypoints to detour around a 500 m radius" | Works as a heuristic, not a guarantee: waypoints snap to roads, and dense cities may have no route clear of a 500 m circle. `AvoidanceRouter` verifies every returned polyline and reports what's left. For hard exclusion, use a router with avoid-polygons — `ValhallaRouteProvider` does this natively and receives the camera rectangles via `RouteProvider.routes(from:to:via:alternatives:excluding:)`. |

Licensing: StikDebug is AGPL-3.0. Copying its code makes your app AGPL. Check the licenses of `idevice` and Google-Maps-iOS-Utils before distributing.

## Project layout

```
Ghosted/
├── ARCHITECTURE.md
├── Config/
│   └── Ghosted.entitlements            intentionally empty — this design needs none
├── Sources/
│   ├── GhostedCore/                    portable, Foundation-only, host-testable
│   │   ├── GeoMath.swift                haversine, bearings, segment distance, RoutePath, polyline codec
│   │   ├── CameraIndex.swift            CameraNode, quadtree, GeoJSON loader
│   │   ├── AvoidanceRouter.swift        RouteProvider protocol, exposure analysis, detour search
│   │   ├── RouteProviders.swift         HTTPTransport + OSRM / Valhalla / GraphHopper providers
│   │   ├── MovementSimulator.swift      route driving simulation (clock-free, seedable)
│   │   ├── RouteExposureStatus.swift    runtime risk summary
│   │   └── Coordinate.swift             value-type coordinate
│   ├── Ghosted/                        the app shell; the single entry point
│   │   ├── GhostedApp.swift             UIKit entry point, shell UI, runtime contract
│   │   ├── SpoofingSession.swift        composition root — the only place the pieces meet
│   │   ├── RoutePlanner.swift           origin/destination → camera-aware route
│   │   ├── RouteStreamer.swift          1 Hz clock around the portable MovementSimulator
│   │   └── RuntimeContract.swift        on-screen runtime contract checklist
│   ├── Spoofing/
│   │   ├── LocalSpoofingManager.swift   state machine, recovery, pairing store
│   │   ├── IdeviceBackend.swift         state-tracking adapter; refuses rather than fakes a session
│   │   ├── IdeviceFFIBackend.swift      libimobiledevice adapter — behind IDEVICE_FFI_ENABLED (off)
│   │   ├── URLSessionTransport.swift    URLSession → GhostedCore.HTTPTransport
│   │   └── BackgroundKeepAlive.swift    silent audio + background location
│   └── Alerts/
│       └── ProximityAlertManager.swift
├── Sources/IdeviceFFI/                 C shim over libimobiledevice — NOT in any build target
├── Ghosted/                            Info.plist, LaunchScreen.storyboard, Assets.xcassets
├── ExportOptions.plist                 for a *signed* local archive (xcodebuild -exportArchive)
├── Tests/GhostedTests/                 87 tests, GhostedCore only
└── Tools/
    ├── IOSTypeCheck/                   stub-SDK type-check harness for the iOS-only layer
    └── validate-pbxproj.py             structural check of the Xcode project file
```

There is no bundled `cameras.geojson`: drop your own DeFlock/OSM export into the app's
Documents folder (exposed over Finder via `UIFileSharingEnabled`). Until then the camera
index is empty and proximity alerts are inert — the route stream still works.

Everything under `Sources/Spoofing` and `Sources/Alerts` is compiled by the **Xcode app
target only**. Those files import UIKit/AVFoundation/CoreLocation/Network/Security, so
they are iOS-only by construction and belong to neither the portable `GhostedCore`
target nor the SwiftPM `Ghosted` target. `swift test` does not type-check them;
`Tools/IOSTypeCheck/check.sh` does, against stub SDK modules, on every push.

`Sources/Ghosted` is compiled by *both* the Xcode app target and the SwiftPM `Ghosted`
target, so the two build systems share one entry point. Because the SwiftPM target also
builds for macOS, every iOS-only file there wraps itself in `#if os(iOS)`:
`GhostedApp.swift` has a host stub, and `SpoofingSession.swift` / `RouteStreamer.swift`
resolve to nothing off-iOS. Adding a new file to `Sources/Ghosted` without that guard
will break `swift build`, because its dependencies live in targets SwiftPM cannot see.

On iOS the entry point is `@main` on `AppDelegate`; off-iOS it is a `@main` stub
struct. The same file, one logical entry point per platform.

Two earlier locations were superseded and removed:

- The routing logic lived in `Sources/Routing/`. It now lives in `Sources/GhostedCore/`
  so it stays portable and unit-testable on non-iOS hosts.
- The 1 Hz movement loop was a `Sources/Spoofing/MovementController` actor holding its
  own copy of the physics plus private `MovementProfile` / `MovementUpdate` types that
  shadowed the tested ones. `GhostedCore.MovementSimulator` is the same algorithm made
  clock-free and seedable; `Sources/Ghosted/RouteStreamer.swift` now supplies the clock.

## One-time setup (needs a computer, once)

1. Generate a pairing file for the phone on a trusted Mac/PC; AirDrop or copy it to the phone.
2. Enable Developer Mode: Settings → Privacy & Security → Developer Mode (reboots).
3. Install a loopback VPN app; keep it connected.
4. Sideload Ghosted (AltStore/SideStore), import the pairing file (stored in the Keychain), and import a DDI folder for your iOS version (`BuildManifest.plist`, `Image.dmg`, `Image.dmg.trustcache` kept together).

## Runtime flow

```
route request ─► AvoidanceRouter ─► polyline ─► MovementController ─(1 Hz)─► LocalSpoofingManager ─► IdeviceBackend ─► system location
                       ▲                              │                              │
                CameraQuadtree                  ProximityAlertManager        heartbeat + NWPathMonitor + recovery
```

- **Spoofing is system-wide**, so every app (including this one's own `CLLocationManager`) sees the fake fix. Track your own position from `MovementController`, not CoreLocation.
- Location is derived by iOS from consecutive fixes; only lat/lon is sent. Keep ticks steady and jumps small or apps will see absurd speeds. `multiplier` speeds up *simulated time*, not the tick rate.
- Call `LocalSpoofingManager.stop()` at trip end, and clear at launch too, in case the app was killed mid-drive. Whether a simulation survives the connection closing is something to verify on-device.
- While a simulation runs, everything sees the fake location, including apps you may rely on for safety. Reset before you depend on real GPS.

## Failure matrix

| Symptom | Classified as | Behavior |
|---|---|---|
| Loopback address unreachable | `loopbackVPNDown` (retryable) | Probe with timeout; exponential backoff 1→15 s, 6 attempts |
| Wi-Fi roam / VPN flap | path change | `NWPathMonitor` → re-probe → recover, then resend last fix |
| Heartbeat stops | `tunnelDropped` (retryable) | Same recovery path |
| Pairing rejected | `pairingRejected` (terminal) | Stop, ask for a fresh pairing file |
| Developer Mode off | `developerModeOff` (terminal) | Stop, show the Settings path |
| DDI mismatch / manifest error | `ddiMountFailed` (terminal) | Stop; import a matching DDI. If an image is already mounted, reboot first |
| iOS < 17.4 | `unsupportedOS` (terminal) | Stop |

## Map layer (not implemented; recommended shape)

- Never add all cameras as markers. On `mapView(_:idleAt:)`, if zoom < ~10 draw nothing (or a coarse count overlay); otherwise query `CameraQuadtree.query(in:)` for the visible rect, cap at ~1–2k items, and hand them to `GMUClusterManager` (Google-Maps-iOS-Utils) with a custom `GMUClusterItem`.
- Reuse item objects between passes and clear the cluster manager before re-adding.
- For datasets far beyond GeoJSON-in-memory, prebuild SQLite with an R*Tree table and query by viewport/route corridor.

## Camera data

DeFlock crowd-sources ALPR locations into OpenStreetMap (roughly `man_made=surveillance` + `surveillance:type=ALPR`; check the current tagging). Export via Overpass or the project's own data, as GeoJSON Points. OSM data is ODbL: attribute it, and note that coverage is incomplete and drifts over time.

## Background execution

`UIBackgroundModes` needs both `audio` and `location`. The silent-loop trick is sideload-only (App Store would reject it), costs battery, and can still lose to Low Power Mode or thermal pressure. `BackgroundKeepAlive` restarts audio after interruptions and media-services resets.
