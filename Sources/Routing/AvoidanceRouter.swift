import CoreLocation

// MARK: - Route provider abstraction

struct RouteCandidate: Sendable {
    var polyline: [CLLocationCoordinate2D]
    var distanceMeters: Double
    var durationSeconds: Double
}

/// Anything that can produce driving routes. `GoogleRoutesProvider` is included; a Valhalla/GraphHopper
/// implementation (which can take avoid-polygons natively) can be dropped in without touching the algorithm.
protocol RouteProvider: Sendable {
    /// `via` waypoints must be treated as pass-through (not stops).
    /// `alternatives` is a hint; many APIs only return alternatives when there are no intermediate waypoints.
    func routes(from origin: CLLocationCoordinate2D,
                to destination: CLLocationCoordinate2D,
                via: [CLLocationCoordinate2D],
                alternatives: Bool) async throws -> [RouteCandidate]
}

// MARK: - Exposure analysis (route ↔ camera geofences)

struct CameraHit {
    let camera: CameraNode
    let along: Double        // meters along the route where the route is closest to the camera
    let distance: Double     // closest approach in meters
    let segment: Int         // index into RoutePath.points
}

/// A cluster of nearby hits that one detour can plausibly fix together.
struct ExposureZone {
    let cameras: [CameraNode]
    let centroid: CLLocationCoordinate2D
    let routeBearing: Double
    var key: Int64 { cameras.map(\.id).min() ?? -1 }
}

struct ExposureAnalyzer {
    let index: CameraQuadtree
    let radius: Double

    /// Every camera whose geofence (circle of `radius`) the path enters, ordered along the route.
    /// Cameras within `radius` of an anchor (origin/destination) are ignored: no detour can avoid them.
    func hits(along path: RoutePath, ignoringNear anchors: [CLLocationCoordinate2D]) -> [CameraHit] {
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
    func zones(_ hits: [CameraHit], path: RoutePath) -> [ExposureZone] {
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
                                centroid: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                routeBearing: Geo.bearing(path.points[seg], path.points[seg + 1]))
        }
    }
}

// MARK: - Router

struct AvoidanceConfig: Sendable {
    /// Geofence radius. 500 m is the value from the spec, but an ALPR reads plates at tens of meters;
    /// in dense areas a 500 m hard radius will often be unsatisfiable. 100–200 m is far more practical.
    var radius: Double = 500
    /// One camera is treated as costing this many seconds of extra driving. Big number ⇒ "avoid at nearly any cost".
    var cameraPenaltySeconds: Double = 1800
    /// Hard cap on Routes API requests per navigation request (each one is billed).
    var maxRouteCalls: Int = 8
    /// Extra clearance beyond the geofence when placing a detour waypoint.
    var detourMargin: Double = 40
}

struct AvoidanceOutcome {
    let route: RouteCandidate
    let vias: [CLLocationCoordinate2D]
    let remainingCameras: [CameraNode]     // cameras still inside the geofence (empty ⇒ clean route)
    let routeCalls: Int
    var isClean: Bool { remainingCameras.isEmpty }
}

enum RouterError: Error { case noRoute, http(Int, String) }

final class AvoidanceRouter {
    private let provider: RouteProvider
    private let analyzer: ExposureAnalyzer
    private let config: AvoidanceConfig

    init(provider: RouteProvider, cameras: CameraQuadtree, config: AvoidanceConfig = .init()) {
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

    private func evaluate(_ r: RouteCandidate, _ anchors: [CLLocationCoordinate2D]) -> Scored {
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
    func route(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async throws -> AvoidanceOutcome {
        let anchors = [origin, destination]
        var calls = 1
        let initial = try await provider.routes(from: origin, to: destination, via: [], alternatives: true)
        guard var best = initial.map({ evaluate($0, anchors) }).min(by: { $0.score < $1.score }) else {
            throw RouterError.noRoute
        }
        var vias: [CLLocationCoordinate2D] = []
        var abandoned = Set<Int64>()

        while calls < config.maxRouteCalls {
            let zones = analyzer.zones(best.hits, path: best.path).filter { !abandoned.contains($0.key) }
            guard let zone = zones.first else { break }

            var winner: (scored: Scored, vias: [CLLocationCoordinate2D])?
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
    private func detourPoints(around zone: ExposureZone) -> [CLLocationCoordinate2D] {
        let spread = zone.cameras.map { Geo.haversine(zone.centroid, $0.coordinate) }.max() ?? 0
        let ring = config.radius + spread + config.detourMargin
        return [90.0, -90.0].map { Geo.destination(from: zone.centroid, bearing: zone.routeBearing + $0, meters: ring) }
    }

    /// Keeps waypoints ordered by where they sit along the current best route.
    private func insertVia(_ p: CLLocationCoordinate2D,
                           into vias: [CLLocationCoordinate2D],
                           along path: RoutePath) -> [CLLocationCoordinate2D] {
        (vias + [p]).sorted { path.along($0) < path.along($1) }
    }
}

// MARK: - Google Routes API provider

struct GoogleRoutesProvider: RouteProvider {
    let apiKey: String

    func routes(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D,
                via: [CLLocationCoordinate2D], alternatives: Bool) async throws -> [RouteCandidate] {
        func waypoint(_ c: CLLocationCoordinate2D, via: Bool = false) -> [String: Any] {
            var w: [String: Any] = ["location": ["latLng": ["latitude": c.latitude, "longitude": c.longitude]]]
            if via { w["via"] = true }
            return w
        }
        var body: [String: Any] = [
            "origin": waypoint(origin),
            "destination": waypoint(destination),
            "travelMode": "DRIVE",
            "routingPreference": "TRAFFIC_AWARE",
            "polylineQuality": "HIGH_QUALITY",
            // Alternatives are only requested on the first (waypoint-free) call.
            "computeAlternativeRoutes": alternatives && via.isEmpty,
        ]
        if !via.isEmpty { body["intermediates"] = via.map { waypoint($0, via: true) } }

        var req = URLRequest(url: URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        req.setValue("routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline",
                     forHTTPHeaderField: "X-Goog-FieldMask")
        // Needed if the API key is restricted to an iOS bundle ID in Google Cloud Console.
        if let bundle = Bundle.main.bundleIdentifier { req.setValue(bundle, forHTTPHeaderField: "X-Ios-Bundle-Identifier") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RouterError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        struct Response: Decodable {
            struct Route: Decodable {
                struct Poly: Decodable { let encodedPolyline: String }
                let duration: String            // e.g. "1234s"
                let distanceMeters: Int
                let polyline: Poly
            }
            let routes: [Route]?
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return (decoded.routes ?? []).map {
            RouteCandidate(polyline: Geo.decodePolyline($0.polyline.encodedPolyline),
                           distanceMeters: Double($0.distanceMeters),
                           durationSeconds: Double($0.duration.dropLast()) ?? 0)
        }
    }
}
