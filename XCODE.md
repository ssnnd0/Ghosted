# Xcode Setup for Ghosted

## Repository

The Ghosted project is hosted at: https://github.com/ssnnd0/Ghosted

## Project Structure

The repository contains a complete Xcode project with the following targets:

### Targets

1. **GhostedCore** (Framework)
   - Cross-platform Swift library for geodesy, routing, and movement simulation
   - Compiles on macOS, Linux, and Windows (no UIKit/AVFoundation dependencies)
   - Location: `Sources/GhostedCore/`

2. **GhostedApp** (iOS Application)
   - iOS-only app shell with minimal UIKit-based entry point
   - Depends on GhostedCore framework
   - Location: `Sources/Ghosted/` and `App/`

3. **GhostedTests** (Unit Tests)
   - Test suite for GhostedCore functionality
   - Location: `Tests/GhostedTests/`

## Build Configuration

### iOS App Target Settings

- **Product Name:** Ghosted
- **Bundle Identifier:** com.ssnn.Ghosted
- **Deployment Target:** iOS 17.0
- **SDK:** iOS
- **Swift Language Version:** 6
- **Main Interface:** LaunchScreen
- **Signing:** Automatic

### Framework Target Settings

- **Product Name:** GhostedCore
- **Bundle Identifier:** com.ssnn.GhostedCore
- **Library for Distribution:** YES
- **Swift Language Version:** 6

## App Resources

- **Launch Screen:** `Ghosted/LaunchScreen.storyboard`
- **App Configuration:** `Ghosted/Info.plist`
- **Assets Catalog:** `Ghosted/Assets.xcassets/`
  - App Icon: `AppIcon.appiconset/`

## Key Build Phases

### iOS App Target

1. Link Binary With Libraries
   - UIKit.framework
   - GhostedCore.framework

2. Copy Bundle Resources
   - LaunchScreen.storyboard
   - Info.plist
   - Assets.xcassets

3. Sources Build Phase
   - `GhostedApp.swift`

### GhostedCore Framework

- Sources: All `.swift` files in `Sources/GhostedCore/`
- Public interfaces exposed via module definition
- No external framework dependencies

## Opening in Xcode

1. Clone the repository
2. Open `Ghosted.xcodeproj` in Xcode
3. Select the **GhostedApp** scheme to build the iOS application
4. Select the **GhostedCore** scheme to build the framework independently
5. Select the **GhostedTests** scheme to run tests

## Deployment Requirements

The iOS app requires:

- iOS 17.4 or newer
- Developer Mode enabled on device
- Fresh pairing file for DDI management
- Loopback VPN active and connected to Wi‑Fi
- Matching DDI mounted for the installed iOS build
- CoreDevice/RSD location channel opened and heartbeat maintained
- Background audio + location modes enabled

See ARCHITECTURE.md and README.md for detailed runtime contract information.
