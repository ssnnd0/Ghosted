// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Ghosted",
    // iOS floor matches IPHONEOS_DEPLOYMENT_TARGET in Ghosted.xcodeproj (17.4, rounded
    // down to SPM's major.minor granularity). macOS is listed because swift.yml runs
    // `swift test` there; without a platforms clause SPM silently assumes macOS 10.13.
    platforms: [.iOS(.v17), .macOS(.v13)],
    targets: [
        // Cross-platform library: geodesy, quadtree, route avoidance, movement simulation.
        // Compiles on macOS, Linux and Windows (no UIKit / AVFoundation / CoreLocation dependency).
        .target(
            name: "GhostedCore",
            path: "Sources/GhostedCore"
        ),

        // iOS-only executable: spoofing manager, background keep-alive, proximity alerts, app entry.
        // This target won't compile on Windows; that's expected — build GhostedCore + tests there.
        .executableTarget(
            name: "Ghosted",
            dependencies: ["GhostedCore"],
            path: "Sources/Ghosted"
        ),

        .testTarget(
            name: "GhostedTests",
            dependencies: ["GhostedCore"],
            path: "Tests/GhostedTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
