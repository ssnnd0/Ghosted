import Foundation

// MARK: - Route provider abstraction

public struct RouteCandidate: Sendable {
    public var polyline: [Coordinate]
    public var distanceMeters: Double
    public var durationSeconds: Double

    public init(polyline: [Coordinate], distanceMeters: Double, durationSeconds: Double) {
        self.polyline = polyline
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
    }
}

/// Anything that can produce driving routes. `AvoidanceRouter` only ever sees this protocol, so
/// swapping OSRM for a self-hosted Valhalla changes nothing above it.
public protocol RouteProvider: Sendable {
    /// `via` waypoints must be treated as pass-through (not stops).
    /// `alternatives` is a hint; many APIs only return alternatives when there are no intermediate waypoints.
    func routes(from origin: Coordinate,
                to destination: Coordinate,
                via: [Coordinate],
                alternatives: Bool) async throws -> [RouteCandidate]

    /// Variants that can honour exclusion polygons natively — Valhalla among them — override this
    /// and the route never has to pass within `radius` of a rectangle. The default implementation
    /// ignores the rectangles, which leaves `AvoidanceRouter`'s waypoint-detour strategy in charge;
    /// that is a correct fallback, just a weaker guarantee.
    func routes(from origin: Coordinate,
                to destination: Coordinate,
                via: [Coordinate],
                alternatives: Bool,
                excluding: [GeoRect]) async throws -> [RouteCandidate]
}

extension RouteProvider {
    public func routes(from origin: Coordinate,
                       to destination: Coordinate,
                       via: [Coordinate],
                       alternatives: Bool,
                       excluding: [GeoRect]) async throws -> [RouteCandidate] {
        try await routes(from: origin, to: destination, via: via, alternatives: alternatives)
    }
}

// MARK: - Exposure analysis (route ↔ camera geofences)

public struct CameraHit: Sendable {
    public let camera: CameraNode
    public let along: Double        // meters along the route where the route is closest to the camera
    public let distance: Double     // closest approach in meters
    public let segment: Int         // index into RoutePath.points

    public init(camera: CameraNode, along: Double, distance: Double, segment: Int) {
        self.camera = camera
        self.along = along
        self.distance = distance
        self.segment = segment
    }
}

/// A cluster of nearby hits that one detour can plausibly fix together.
public struct ExposureZone: Sendable {
    public let cameras: [CameraNode]
    public let centroid: Coordinate
    public let routeBearing: Double
    public var key: Int64 { cameras.map(\.id).min() ?? -1 }

    public init(cameras: [CameraNode], centroid: Coordinate, routeBearing: Double) {
        self.cameras = cameras
        self.centroid = centroid
        self.routeBearing = routeBearing
    }
}

public struct ExposureAnalyzer: Sendable {
    public let index: CameraQuadtree
    public let radius: Double

    public init(index: CameraQuadtree, radius: Double) {
        self.index = index
        self.radius = radius
    }

    /// Every camera whose geofence (circle of `radius`) the path enters, ordered along the route.
    /// Cameras within `radius` of an anchor (origin/destination) are ignored: no detour can avoid them.
    public func hits(along path: RoutePath, ignoringNear anchors: [Coordinate]) -> [CameraHit] {
        guard path.points.count > 1 else { return [] }
        var best: [Int64: CameraHit] = [:]
        for i in 0..<(path.points.count - 1) {
            let a = path.points[i], b = path.points[i + 1]
            // Quadtree narrows candidates to the segment's bounding box (+radius); exact test follows.
            index.query(in: GeoRect.around(a, b).expanded(meters: radius)) { cam in
                let r = Geo.distance(from: cam.coordinate, toSegment: a, b)
                guard r.meters <= radius else { return }
                if let old = best[cam.id], old.distance <= r.meters { return }
                let along = path.cumulative[i] + r.t * (path.cumulative[i + 1] - path.cumulative[i])
                best[cam.id] = CameraHit(camera: cam, along: along, distance: r.meters, segment: i)
            }
        }
        return best.values
            .filter { h in !anchors.contains { Geo.haversine($0, h.camera.coordinate) <= radius } }
            .sorted { $0.along < $1.along }
    }

    /// Groups consecutive hits (closer than 2×radius along the route) into zones.
    public func zones(_ hits: [CameraHit], path: RoutePath) -> [ExposureZone] {
        var groups: [[CameraHit]] = []
        for h in hits {
            if let last = groups.last?.last, h.along - last.along <= radius * 2 {
                groups[groups.count - 1].append(h)
            } else {
                groups.append([h])
            }
        }
        return groups.map { g in
            let lat = g.map { $0.camera.latitude }.reduce(0, +) / Double(g.count)
            let lon = g.map { $0.camera.longitude }.reduce(0, +) / Double(g.count)
            let seg = g[g.count / 2].segment
            return ExposureZone(cameras: g.map(\.camera),
                                centroid: Coordinate(latitude: lat, longitude: lon),
                                routeBearing: Geo.bearing(path.points[seg], path.points[seg + 1]))
        }
    }
}

// MARK: - Router

public struct AvoidanceConfig: Sendable {
    /// Geofence radius. 500 m is the value from the spec, but an ALPR reads plates at tens of meters;
    /// in dense areas a 500 m hard radius will often be unsatisfiable. 100–200 m is far more practical.
    public var radius: Double
    /// One camera is treated as costing this many seconds of extra driving. Big number ⇒ "avoid at nearly any cost".
    public var cameraPenaltySeconds: Double
    /// Hard cap on Routes API requests per navigation request (each one is billed).
    public var maxRouteCalls: Int
    /// Extra clearance beyond the geofence when placing a detour waypoint.
    public var detourMargin: Double

    public init(radius: Double = 500, cameraPenaltySeconds: Double = 1800,
                maxRouteCalls: Int = 8, detourMargin: Double = 40) {
        self.radius = radius
        self.cameraPenaltySeconds = cameraPenaltySeconds
        self.maxRouteCalls = maxRouteCalls
        self.detourMargin = detourMargin
    }
}

public struct AvoidanceOutcome: Sendable {
    public let route: RouteCandidate
    public let vias: [Coordinate]
    public let remainingCameras: [CameraNode]     // cameras still inside the geofence (empty ⇒ clean route)
    public let routeCalls: Int
    public var isClean: Bool { remainingCameras.isEmpty }

    public init(route: RouteCandidate, vias: [Coordinate], remainingCameras: [CameraNode], routeCalls: Int) {
        self.route = route
        self.vias = vias
        self.remainingCameras = remainingCameras
        self.routeCalls = routeCalls
    }
}

public enum RouterError: Error, Equatable, CustomStringConvertible {
    case noRoute
    case http(Int, String)
    /// The provider answered, but the answer was not usable: an error payload, a body that does
    /// not match the documented shape, or a request that could not be built. `noRoute` means "no
    /// path exists"; this means "we could not read the answer", which is worth showing a user
    /// verbatim because it almost always names a misconfigured base URL or API key.
    case providerFailure(String)

    public var description: String {
        switch self {
        case .noRoute: return "No route found between those points."
        case .http(let status, let body): return "Routing server returned HTTP \(status): \(body)"
        case .providerFailure(let message): return message
        }
    }
}

public final class AvoidanceRouter: Sendable {
    private let provider: RouteProvider
    private let analyzer: ExposureAnalyzer
    private let config: AvoidanceConfig

    public init(provider: RouteProvider, cameras: CameraQuadtree, config: AvoidanceConfig = .init()) {
        self.provider = provider
        self.config = config
        self.analyzer = ExposureAnalyzer(index: cameras, radius: config.radius)
    }

    private struct Scored {
        let route: RouteCandidate
        let path: RoutePath
        let hits: [CameraHit]
        let score: Double
    }

    private func evaluate(_ r: RouteCandidate, _ anchors: [Coordinate]) -> Scored {
        let path = RoutePath(r.polyline)
        let hits = analyzer.hits(along: path, ignoringNear: anchors)
        return Scored(route: r, path: path, hits: hits,
                      score: Double(hits.count) * config.cameraPenaltySeconds + r.durationSeconds)
    }

    /// Strategy (propose → evaluate → accept only if better):
    ///  1. Ask for the baseline route plus alternatives; keep whichever scores best
    ///     (score = cameras × penalty + duration).
    ///  2. While cameras remain and budget allows: take the first exposure zone, propose one pass-through
    ///     waypoint on each side of it (just outside geofence + margin), re-route, and keep the result only
    ///     if its score improves. Zones that can't be improved are abandoned rather than retried forever.
    ///  3. Always evaluate the *returned* polyline against the index — a waypoint being snapped back onto the
    ///     same road can't fool the check, and the caller is told honestly what's left in `remainingCameras`.
    /// This is a heuristic. A hard guarantee needs a router that natively supports avoid-polygons.
    public func route(from origin: Coordinate, to destination: Coordinate) async throws -> AvoidanceOutcome {
        let anchors = [origin, destination]
        var calls = 1
        let initial = try await provider.routes(from: origin, to: destination, via: [], alternatives: true)
        guard var best = initial.map({ evaluate($0, anchors) }).min(by: { $0.score < $1.score }) else {
            throw RouterError.noRoute
        }
        var vias: [Coordinate] = []
        var abandoned = Set<Int64>()

        while calls < config.maxRouteCalls {
            let zones = analyzer.zones(best.hits, path: best.path).filter { !abandoned.contains($0.key) }
            guard let zone = zones.first else { break }

            var winner: (scored: Scored, vias: [Coordinate])?
            for p in detourPoints(around: zone) {
                guard calls < config.maxRouteCalls else { break }
                calls += 1
                let trial = insertVia(p, into: vias, along: best.path)
                guard let cand = (try? await provider.routes(from: origin, to: destination,
                                                             via: trial, alternatives: false))?.first else { continue }
                let s = evaluate(cand, anchors)
                if s.score < (winner?.scored.score ?? best.score) { winner = (s, trial) }
            }

            if let w = winner {
                best = w.scored
                vias = w.vias
            } else {
                abandoned.insert(zone.key)
            }
        }

        return AvoidanceOutcome(route: best.route, vias: vias,
                                remainingCameras: best.hits.map(\.camera), routeCalls: calls)
    }

    /// One candidate on each side of the route, outside the zone's geofence.
    private func detourPoints(around zone: ExposureZone) -> [Coordinate] {
        let spread = zone.cameras.map { Geo.haversine(zone.centroid, $0.coordinate) }.max() ?? 0
        let ring = config.radius + spread + config.detourMargin
        return [90.0, -90.0].map { Geo.destination(from: zone.centroid, bearing: zone.routeBearing + $0, meters: ring) }
    }

    /// Keeps waypoints ordered by where they sit along the current best route.
    private func insertVia(_ p: Coordinate,
                           into vias: [Coordinate],
                           along path: RoutePath) -> [Coordinate] {
        (vias + [p]).sorted { path.along($0) < path.along($1) }
    }
}
