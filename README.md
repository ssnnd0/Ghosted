# Ghosted

Ghosted is a Swift package and iOS app shell for route-aware, camera-aware location simulation. The project keeps the portable routing and movement logic separate from the device-specific spoofing layer so it can be tested on a normal machine while the final live-device handshake remains isolated to the iPhone runtime.

## Project status

- Core library: complete and tested
- App shell: finished as a minimal iOS entry surface
- Device runtime contract: implemented as a clean boundary, but final live validation must happen on a real iPhone

## Architecture

The repo is intentionally split:

- GhostedCore: geodesy, route/path logic, quadtree camera indexing, route avoidance, movement simulation, route risk summary
- Ghosted app: minimal iOS shell and runtime entry point
- Spoofing layer: pairing, DDI management, route streaming, loopback reachability, heartbeat and recovery
- Alert layer: proximity warning logic while a fake GPS stream is active

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
7. Background audio + location modes enabled
8. Real route push validated while the screen is locked
9. Route and camera logic confirmed against the actual device GPS stream

## Device-runtime contract

The live runtime contract is defined by these requirements:

- Pairing must be valid and accepted by the device.
- The loopback address must be reachable from inside the app.
- Developer Mode must be enabled.
- The DDI must match the running iOS build.
- The location-simulation channel must be opened and remain alive.
- The app must recover gracefully from path changes, VPN drops, and tunnel resets.

## Verification

The project is kept green with Swift tests and the portable logic remains validation-ready on the host machine.

```bash
cd c:/Users/Sandro/Documents/GitHub/Ghosted
swift test
```

The current suite is passing with 52 tests in 10 suites and 0 failures.

## Files included

- ARCHITECTURE.md
- AUDIT.md
- README.md
- App/
- Config/
- Sources/
- Tests/
- Dolphin/

## Dolphin companion files

The Dolphin folder contains the runtime checklist and companion notes for the on-device validation pass.
