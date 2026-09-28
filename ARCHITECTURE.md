# Ghosted — architecture notes

**Status:** none of this has been compiled (no Swift toolchain was available while writing it), and the native `idevice` layer is a skeleton. Treat the Swift as a carefully reasoned first draft, not a working build. Written for Swift 5 language mode, iOS 17.4+.

## Where the original prompt's premises were wrong

| Prompt says | Reality |
|---|---|
| "Zero external hardware / no connected Mac" | Only true *after* a one-time setup. You need a pairing file generated from a trusted computer (Mac, Windows or Linux tool). Everything after that runs on the phone. |
| "Replace lockdownd with RSD over QUIC; write the bridging logic" | Don't hand-roll this. On-device tools use the `idevice` library (Rust with a C FFI) for pairing, tunnel, RSD and the location service. StikDebug's stack covers iOS 17.4+; 17.3 and below use different protocols and aren't covered. |
| "Local loopback/Wi-Fi pairing" | Reaching the device's own services from inside an app needs a **loopback VPN** app (e.g. LocalDevVPN) running alongside. Reuse it. Building your own needs the Network Extension entitlement, which free accounts lack. |
| "Private entitlements in Info.plist" | Entitlements aren't Info.plist keys. This design needs none (see `Config/Ghosted.entitlements`). TrollStore, as far as I know, only exists for iOS ≤ 17.0, which is below the 17.4 floor of this stack. |
| "GoogleMaps SDK … turn-by-turn overlay" | The standard Maps SDK draws maps, traffic and polylines. Turn-by-turn is a separate, access-gated product (Navigation SDK). Without it, build the overlay from the Routes API's step instructions plus your own progress tracking. |
| "Quadtree so thousands of pins don't OOM" | The *data* is tiny (100k points ≈ a few MB). The OOM risk is creating thousands of `GMSMarker`s. The fix is viewport-limited, clustered rendering (below). The quadtree earns its keep on the routing side. |
| "Insert waypoints to detour around a 500 m radius" | Works as a heuristic, not a guarantee: waypoints snap to roads, and dense cities may have no route clear of a 500 m circle. `AvoidanceRouter` verifies every returned polyline and reports what's left. For hard exclusion, use a router with avoid-polygons (Valhalla, GraphHopper, OpenRouteService) behind the same `RouteProvider` protocol. |

Licensing: StikDebug is AGPL-3.0. Copying its code makes your app AGPL. Check the licenses of `idevice` and Google-Maps-iOS-Utils before distributing.

## Project layout

```
Ghosted/
├── ARCHITECTURE.md
├── Config/
│   ├── Info.plist
│   └── Ghosted.entitlements
├── Sources/
│   ├── Spoofing/
│   │   ├── LocalSpoofingManager.swift   state machine, recovery, pairing store
│   │   ├── IdeviceBackend.swift         native adapter (skeleton — wire to idevice FFI)
│   │   ├── MovementController.swift     polyline → 1 Hz stream, multiplier, stops, jitter
│   │   └── BackgroundKeepAlive.swift    silent audio + background location
│   ├── Routing/
│   │   ├── GeoMath.swift                haversine, bearings, segment distance, RoutePath
│   │   ├── CameraIndex.swift            CameraNode, quadtree, GeoJSON loader
│   │   └── AvoidanceRouter.swift        exposure analysis, detour search, Google Routes provider
│   └── Alerts/
│       └── ProximityAlertManager.swift
├── App/                                 not written: SwiftUI shell, GMSMapView wrapper, bottom sheet
└── Resources/cameras.geojson            not included: your DeFlock/OSM export
```

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
