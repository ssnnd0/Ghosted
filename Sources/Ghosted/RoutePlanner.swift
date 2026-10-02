// Route planning for the app layer: turns user input into a camera-aware route. iOS-only.
//
// Like the other files here this sits inside the SwiftPM `Ghosted` target's path and must also
// compile on macOS, hence the guard. The Xcode app target compiles it for real.

#if os(iOS)
import Foundation
import GhostedCore

/// Plans a route from a chosen provider and, when a camera index is available, routes around
/// the geofences it contains.
///
/// This is the piece that makes `AvoidanceRouter` reachable from the UI. It owns no state of
/// its own beyond its dependencies, so it is safe to hold as a `let`.
struct RoutePlanner: Sendable {
    /// The routing backend. Any of the `GhostedCore` providers works; only ones implementing
    /// `routes(from:to:via:alternatives:excluding:)` honour the camera exclusion polygons
    /// natively — the others fall back to `AvoidanceRouter`'s waypoint detours.
    let provider: any RouteProvider

    /// Camera index. Empty means "plan the route, skip avoidance entirely" rather than
    /// failing: a missing GeoJSON export should degrade the feature, not block it.
    let cameras: CameraQuadtree

    var config: AvoidanceConfig

    init(provider: any RouteProvider,
         cameras: CameraQuadtree,
         config: AvoidanceConfig = .init()) {
        self.provider = provider
        self.cameras = cameras
        self.config = config
    }

    /// Builds the provider the app ships with by default.
    ///
    /// OSRM is the default because it needs no API key, which matters for a sideloaded build
    /// that cannot carry a provisioning profile or a key. Point `GhostedRoutingBaseURL` and
    /// `GhostedRoutingAPIKey` in Info.plist at your own Valhalla or GraphHopper to change that
    /// without touching code.
    static func makeDefault(cameras: CameraQuadtree) -> RoutePlanner {
        let transport = URLSessionTransport.makeDefault()
        let info = Bundle.main.infoDictionary ?? [:]
        let baseURL = (info["GhostedRoutingBaseURL"] as? String) ?? "https://router.project-osrm.org"
        let key = info["GhostedRoutingAPIKey"] as? String

        let provider: any RouteProvider
        if let key, !key.isEmpty, baseURL.contains("graphhopper") {
            provider = GraphHopperRouteProvider(baseURL: baseURL, apiKey: key, transport: transport)
        } else if baseURL.contains("valhalla") {
            provider = ValhallaRouteProvider(baseURL: baseURL, apiKey: key, transport: transport)
        } else {
            provider = OSRMRouteProvider(baseURL: baseURL, transport: transport)
        }
        return RoutePlanner(provider: provider, cameras: cameras)
    }

    /// Plans a route and avoids what it can.
    ///
    /// - Returns: the polyline to stream, plus what could not be avoided. `remainingCameras` is
    ///   reported rather than hidden: a route that still passes a camera is a legitimate
    ///   outcome when detours do not help, and the caller needs to warn about it.
    func plan(from origin: Coordinate,
              to destination: Coordinate) async throws -> PlannedRoute {
        guard cameras.count > 0 else {
            // No index, so nothing to avoid. Still a real routing call — the demo route is not
            // a fallback, it is a separate thing.
            let candidates = try await provider.routes(from: origin, to: destination,
                                                       via: [], alternatives: true)
            guard let best = candidates.min(by: { $0.durationSeconds < $1.durationSeconds }) else {
                throw RouterError.noRoute
            }
            return PlannedRoute(polyline: best.polyline,
                                distanceMeters: best.distanceMeters,
                                durationSeconds: best.durationSeconds,
                                cameraHits: [],
                                viaWaypoints: [],
                                routeCalls: 1,
                                avoidanceApplied: false,
                                message: "No camera index loaded — camera avoidance is inactive.")
        }

        let router = AvoidanceRouter(provider: provider, cameras: cameras, config: config)
        let outcome = try await router.route(from: origin, to: destination)
        return PlannedRoute(
            polyline: outcome.route.polyline,
            distanceMeters: outcome.route.distanceMeters,
            durationSeconds: outcome.route.durationSeconds,
            cameraHits: outcome.remainingCameras,
            viaWaypoints: outcome.vias,
            routeCalls: outcome.routeCalls,
            avoidanceApplied: !outcome.vias.isEmpty,
            message: Self.summarize(outcome)
        )
    }

    /// Reads the planned route against the index without calling the router — used to show the
    /// user what a straight route would cost before they commit to streaming it.
    func previewExposure(of polyline: [Coordinate]) -> RouteExposureStatus {
        let path = RoutePath(polyline)
        let analyzer = ExposureAnalyzer(index: cameras, radius: config.radius)
        return RouteExposureStatus.summary(
            totalDistanceMeters: path.length,
            remainingDistanceMeters: path.length,
            cameraHits: analyzer.hits(along: path, ignoringNear: [])
        )
    }

    private static func summarize(_ outcome: AvoidanceOutcome) -> String {
        let total = outcome.routeCalls
        let detours = outcome.vias.count
        var parts = ["Planned in \(total) routing call\(total == 1 ? "" : "s")"]
        if detours > 0 {
            parts.append("routed around camera geofences via \(detours) waypoint\(detours == 1 ? "" : "s")")
        } else {
            parts.append("no detour needed")
        }
        if outcome.remainingCameras.isEmpty {
            parts.append("no cameras remain on the route")
        } else {
            // CameraNode carries only an id, not a human-readable name — the source data has no labels.
            let ids = outcome.remainingCameras.map { String($0.id) }.joined(separator: ", ")
            parts.append("still passes \(outcome.remainingCameras.count) camera\(outcome.remainingCameras.count == 1 ? "" : "s") (#\(ids))")
        }
        return parts.joined(separator: "; ") + "."
    }
}

/// The result of a planning call: what to stream, and an honest account of what could not be avoided.
struct PlannedRoute: Sendable {
    let polyline: [Coordinate]
    let distanceMeters: Double
    let durationSeconds: Double
    /// Cameras the returned polyline still passes within `AvoidanceConfig.radius` of.
    let cameraHits: [CameraNode]
    /// Pass-through waypoints the avoidance algorithm inserted.
    let viaWaypoints: [Coordinate]
    /// How many times the provider was asked for a route — the cost of the avoidance search.
    let routeCalls: Int
    let avoidanceApplied: Bool
    let message: String

    var pointCount: Int { polyline.count }

    /// Human-readable distance and duration for a route preview.
    var summary: String {
        let km = distanceMeters / 1000
        let minutes = Int((durationSeconds / 60).rounded())
        let distanceText = km < 1
            ? "\(Int(distanceMeters.rounded())) m"
            : String(format: "%.1f km", km)
        return "\(distanceText) · ~\(minutes) min · \(pointCount) points"
    }
}
#endif