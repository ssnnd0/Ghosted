# Ghosted

Ghosted is a Swift package and iOS app shell for route-aware, camera-aware location simulation. The project keeps the portable routing and movement logic separate from the device-specific spoofing mechanisms.

> **⚠️ DISCLAIMER:** This application is provided for educational and authorized testing purposes only. Users are responsible for ensuring their use complies with all applicable laws and regulations in their jurisdiction. See the LICENSE file for full liability disclaimers.

## Project status

- Core library: complete and tested
- App shell: finished as a minimal iOS entry surface
- Device runtime contract: implemented as a clean boundary, but final live validation must happen on a real iPhone

## Architecture

The repo is intentionally split:

- **GhostedCore**: geodesy, route/path logic, quadtree camera indexing, route avoidance, movement simulation, route risk summary
- **Ghosted app**: minimal iOS shell and runtime entry point
- **Spoofing layer**: pairing, DDI management, route streaming, loopback reachability, heartbeat and recovery
- **Alert layer**: proximity warning logic while a fake GPS stream is active

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
swift test
```

The current suite is passing with 52 tests in 10 suites and 0 failures.

## Files included

- ARCHITECTURE.md
- AUDIT.md
- README.md
- LICENSE
- App/
- Config/
- Sources/
- Tests/
- Dolphin/

## Dolphin companion files

The Dolphin folder contains the runtime checklist and companion notes for the on-device validation pass.

## License

This project is licensed under a modified MIT License with enhanced liability disclaimers. See the LICENSE file for details.

## Legal Notice

By using this software, you agree that:
- The authors and contributors assume no liability for any damages or legal consequences resulting from your use of this application.
- You are solely responsible for ensuring your use complies with all applicable local, state, and federal laws.
- You use this software at your own risk.
