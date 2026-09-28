# Ghosted Audit

## Build status
- Swift package builds successfully with `swift test`.
- Core library and routing logic remain portable and testable on non-iOS hosts.
- iOS app shell and device-specific spoofing path are intentionally isolated behind platform gates.

## Architecture compliance
### ✅ Core library
The following modules conform to the architecture split and remain reusable outside of the app runtime:
- `GhostedCore` geodesy and path logic
- `CameraQuadtree` camera indexing and GeoJSON loading
- `AvoidanceRouter` route exposure evaluation and waypoint detour heuristics
- `MovementSimulator` realistic route driving simulation
- `RouteExposureStatus` runtime risk summary for route alerts and UI status

### ✅ App boundary
The app layer is intentionally minimal and architecture friendly:
- `App/GhostedApp.swift` boots the native app shell.
- `Sources/Ghosted/Ghosted.swift` contains the iOS entry point and shell UI placeholder.
- The app does not directly own the routing logic; it is built over the core library contract.

### ✅ Spoofing boundary
The on-device spoofing stack is isolated behind the backend protocol and state machine:
- `LocalSpoofingManager` handles reachability, pairing, DDI mounting, recovery, and heartbeat logic.
- `IdeviceBackend` is the native bridge shell for the idevice/CoreDevice/RSD route.
- `BackgroundKeepAlive` preserves app execution while the spoofed GPS stream is active.
- `ProximityAlertManager` reads the simulated position and emits alert warnings without depending on real GPS state.

## Remaining device-bound constraints
These items cannot be fully proven or executed in this Windows host environment:
1. Real idevice pairing and developer-service tunnel authentication
2. Actual CoreDevice / RSD / DVT location-simulation channel negotiation
3. Local loopback VPN + device-private service reachability
4. iOS background execution under real sideloaded conditions
5. Live route sending to the system location service on hardware

These are not code defects; they are runtime prerequisites for the iPhone device environment.

## Risk assessment
- Program structure: compliant
- Core logic: complete and validated
- App shell: scaffolded and architecture-aligned
- Native device integration: implemented as a proper abstraction, but still requires real-device validation
- Overall production readiness: architecture-ready, device-ready, not fully hardware-validated on this host

## Final verdict
The repo is in a good audited state: the architecture is preserved, the core logic is verified, the app shell is in place, and the live spoofing adapter is correctly isolated behind the backend contract. The remaining work is device-runtime validation on an actual iPhone + loopback VPN + pairing flow.

## Concrete iPhone checklist
1. Confirm the phone is on iOS 17.4 or newer.
2. Turn on Developer Mode: Settings → Privacy & Security → Developer Mode.
3. Generate a fresh pairing file from a trusted computer and import it into the app.
4. Keep the loopback VPN running and ensure the device is on Wi‑Fi.
5. Mount the correct DDI for the installed iOS build: BuildManifest.plist + Image.dmg + Image.dmg.trustcache.
6. Verify the app can open the CoreDevice/RSD location-simulation channel and keep the heartbeat alive.
7. Confirm the app can push a live route while the screen is locked and the app stays alive in the background.
8. Validate the route stream from the simulated movement controller appears as the system location source to other apps.

## Runtime contract summary
The runtime contract is intentionally separated from the core route engine. The portable route logic and spoofing simulation are complete and test-validated; the remaining acceptance criteria are all device-side and must be checked on hardware before claiming live spoofing success.
