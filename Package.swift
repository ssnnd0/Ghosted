// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Ghosted",
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
