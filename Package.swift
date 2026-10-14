// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Ghosted",
    // iOS floor matches IPHONEOS_DEPLOYMENT_TARGET in Ghosted.xcodeproj (17.4, rounded
    // down to SPM's major.minor granularity). macOS is listed because swift.yml runs
    // `swift test` there; without a platforms clause SPM silently assumes macOS 10.13.
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        // xtool packages this library product as the iOS application. Its @main entry point
        // is active on iOS; the host-only stub remains available for non-iOS Swift builds.
        .library(name: "Ghosted", targets: ["Ghosted"]),
    ],
    targets: [
        // Cross-platform library: geodesy, quadtree, route avoidance, movement simulation.
        // Compiles on macOS, Linux and Windows (no UIKit / AVFoundation / CoreLocation dependency).
        .target(
            name: "GhostedCore",
            path: "Sources/GhostedCore"
        ),

        // App module shared by Xcode and xtool. iOS-only files guard their imports and
        // declarations so host Swift builds retain the non-iOS @main stub.
        .target(
            name: "Ghosted",
            dependencies: ["GhostedCore"],
            path: "Sources",
            exclude: ["GhostedCore", "IdeviceFFI"],
            sources: ["Ghosted", "Spoofing", "Alerts"]
        ),

        .testTarget(
            name: "GhostedTests",
            dependencies: ["GhostedCore"],
            path: "Tests/GhostedTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
