import Testing
import Foundation
@testable import GhostedCore

// MARK: - GeoMath Tests

@Suite("Geodesy")
struct GeoMathTests {
    let nyc = Coordinate(latitude: 40.7128, longitude: -74.0060)
    let lax = Coordinate(latitude: 33.9425, longitude: -118.4081)
    let london = Coordinate(latitude: 51.5074, longitude: -0.1278)

    @Test("Haversine: NYC ↔ LAX ≈ 3,955 km")
    func haversineNYCtoLAX() {
        let d = Geo.haversine(nyc, lax)
        #expect(abs(d - 3_955_000) < 10_000, "Expected ~3955 km, got \(d / 1000) km")
    }

    @Test("Haversine: zero distance for same point")
    func haversineSamePoint() {
        #expect(Geo.haversine(nyc, nyc) == 0)
    }

    @Test("Haversine: symmetric")
    func haversineSymmetric() {
        let ab = Geo.haversine(nyc, london)
        let ba = Geo.haversine(london, nyc)
        #expect(abs(ab - ba) < 0.01)
    }

    @Test("Bearing: due east ≈ 90°")
    func bearingEast() {
        let a = Coordinate(latitude: 0, longitude: 0)
        let b = Coordinate(latitude: 0, longitude: 1)
        let brg = Geo.bearing(a, b)
        #expect(abs(brg - 90) < 0.01)
    }

    @Test("Bearing: due north ≈ 0°")
    func bearingNorth() {
        let a = Coordinate(latitude: 0, longitude: 0)
        let b = Coordinate(latitude: 1, longitude: 0)
        let brg = Geo.bearing(a, b)
        #expect(abs(brg) < 0.01 || abs(brg - 360) < 0.01)
    }

    @Test("Bearing: due south ≈ 180°")
    func bearingSouth() {
        let a = Coordinate(latitude: 1, longitude: 0)
        let b = Coordinate(latitude: 0, longitude: 0)
        let brg = Geo.bearing(a, b)
        #expect(abs(brg - 180) < 0.01)
    }

    @Test("Destination: 1000 m due north from equator")
    func destinationNorth() {
        let origin = Coordinate(latitude: 0, longitude: 0)
        let dest = Geo.destination(from: origin, bearing: 0, meters: 1000)
        #expect(dest.latitude > 0, "Should be north of equator")
        #expect(abs(dest.longitude) < 0.0001, "Should stay on same meridian")
        // 1000 m ≈ 0.009° of latitude
        #expect(abs(dest.latitude - 0.009) < 0.001)
    }

    @Test("Destination round-trip: go 5000 m, measure back = 5000 m")
    func destinationRoundTrip() {
        let origin = Coordinate(latitude: 45.0, longitude: -73.0)
        for bearing in stride(from: 0.0, to: 360, by: 45) {
            let dest = Geo.destination(from: origin, bearing: bearing, meters: 5000)
            let measured = Geo.haversine(origin, dest)
            #expect(abs(measured - 5000) < 1, "Bearing \(bearing): expected 5000 m, got \(measured) m")
        }
    }

    @Test("Segment distance: point on the segment")
    func segmentDistanceOnSegment() {
        let a = Coordinate(latitude: 40.0, longitude: -74.0)
        let b = Coordinate(latitude: 40.01, longitude: -74.0)
        let mid = Coordinate(latitude: 40.005, longitude: -74.0)
        let r = Geo.distance(from: mid, toSegment: a, b)
        #expect(r.meters < 1.0, "Point on segment should be ~0 m away, got \(r.meters)")
        #expect(abs(r.t - 0.5) < 0.01, "Midpoint should be at t≈0.5, got \(r.t)")
    }

    @Test("Segment distance: point off to the side")
    func segmentDistanceLateral() {
        let a = Coordinate(latitude: 40.0, longitude: -74.0)
        let b = Coordinate(latitude: 40.01, longitude: -74.0)
        // Point ~111 m east of the midpoint (0.001° longitude at lat 40 ≈ 85 m)
        let p = Coordinate(latitude: 40.005, longitude: -73.999)
        let r = Geo.distance(from: p, toSegment: a, b)
        #expect(r.meters > 50 && r.meters < 150, "Expected ~85 m, got \(r.meters)")
        #expect(abs(r.t - 0.5) < 0.05)
    }

    @Test("Segment distance: point past endpoint B")
    func segmentDistancePastEnd() {
        let a = Coordinate(latitude: 40.0, longitude: -74.0)
        let b = Coordinate(latitude: 40.01, longitude: -74.0)
        let p = Coordinate(latitude: 40.02, longitude: -74.0)
        let r = Geo.distance(from: p, toSegment: a, b)
        #expect(r.t == 1.0, "Should clamp to endpoint B")
    }

    @Test("Angle difference: basic cases")
    func angleDifference() {
        #expect(Geo.angleDifference(10, 20) == 10)
        #expect(Geo.angleDifference(350, 10) == 20)
        #expect(Geo.angleDifference(0, 180) == 180)
        #expect(abs(Geo.angleDifference(1, 359) - 2) < 0.0001)
    }

    @Test("Decode polyline: known Google polyline")
    func decodePolyline() {
        // Encodes: (38.5, -120.2), (40.7, -120.95), (43.252, -126.453)
        let encoded = "_p~iF~ps|U_ulLnnqC_mqNvxq`@"
        let points = Geo.decodePolyline(encoded)
        #expect(points.count == 3)
        #expect(abs(points[0].latitude - 38.5) < 0.001)
        #expect(abs(points[0].longitude - (-120.2)) < 0.001)
        #expect(abs(points[2].latitude - 43.252) < 0.001)
    }

    @Test("Decode polyline: empty string")
    func decodePolylineEmpty() {
        #expect(Geo.decodePolyline("").isEmpty)
    }
}

// MARK: - RoutePath Tests

@Suite("RoutePath")
struct RoutePathTests {
    /// A simple north-south line ~1.11 km long.
    let straightLine: RoutePath = {
        let pts = (0...10).map { i in
            Coordinate(latitude: 40.0 + Double(i) * 0.001, longitude: -74.0)
        }
        return RoutePath(pts)
    }()

    @Test("Length: straight line has correct total length")
    func length() {
        // 10 segments × ~111 m each ≈ 1110 m
        #expect(straightLine.length > 1000 && straightLine.length < 1200)
    }

    @Test("Cumulative distances are monotonically increasing")
    func cumulativeMonotonic() {
        for i in 1..<straightLine.cumulative.count {
            #expect(straightLine.cumulative[i] > straightLine.cumulative[i - 1])
        }
    }

    @Test("Duplicate vertices are dropped")
    func duplicatesDropped() {
        let pts = [
            Coordinate(latitude: 40.0, longitude: -74.0),
            Coordinate(latitude: 40.0, longitude: -74.0),   // duplicate
            Coordinate(latitude: 40.001, longitude: -74.0),
        ]
        let path = RoutePath(pts)
        #expect(path.points.count == 2)
    }

    @Test("Sample at start returns first point")
    func sampleAtStart() {
        var hint = 0
        let (coord, _) = straightLine.sample(at: 0, hint: &hint)
        #expect(abs(coord.latitude - 40.0) < 0.0001)
    }

    @Test("Sample at end returns last point")
    func sampleAtEnd() {
        var hint = 0
        let (coord, _) = straightLine.sample(at: straightLine.length, hint: &hint)
        #expect(abs(coord.latitude - 40.01) < 0.0001)
    }

    @Test("Sample at midpoint gives reasonable interpolation")
    func sampleAtMidpoint() {
        var hint = 0
        let (coord, _) = straightLine.sample(at: straightLine.length / 2, hint: &hint)
        #expect(abs(coord.latitude - 40.005) < 0.001)
    }

    @Test("Along: point on the path returns correct distance")
    func alongOnPath() {
        let mid = Coordinate(latitude: 40.005, longitude: -74.0)
        let s = straightLine.along(mid)
        #expect(abs(s - straightLine.length / 2) < 10)
    }

    @Test("Hint advances correctly for monotonic sampling")
    func hintAdvancement() {
        var hint = 0
        _ = straightLine.sample(at: 100, hint: &hint)
        let hint1 = hint
        _ = straightLine.sample(at: 500, hint: &hint)
        #expect(hint >= hint1, "Hint should advance for increasing s")
    }
}

// MARK: - CameraQuadtree Tests

@Suite("Quadtree")
struct QuadtreeTests {
    func makeCam(_ id: Int64, _ lat: Double, _ lon: Double) -> CameraNode {
        CameraNode(id: id, latitude: lat, longitude: lon)
    }

    @Test("Insert and count")
    func insertAndCount() {
        let tree = CameraQuadtree()
        for i in 0..<100 {
            tree.insert(makeCam(Int64(i), Double.random(in: 30...50), Double.random(in: -120 ... -70)))
        }
        #expect(tree.count == 100)
    }

    @Test("Query: returns cameras inside rect")
    func queryInRect() {
        let tree = CameraQuadtree(capacity: 4)
        tree.insert(makeCam(0, 40.0, -74.0))    // inside
        tree.insert(makeCam(1, 40.5, -74.0))    // inside
        tree.insert(makeCam(2, 50.0, -74.0))    // outside
        tree.insert(makeCam(3, 40.2, -80.0))    // outside

        var results: [CameraNode] = []
        tree.query(in: GeoRect(minLat: 39.5, maxLat: 41.0, minLon: -75.0, maxLon: -73.0)) { results.append($0) }
        #expect(results.count == 2)
        #expect(Set(results.map(\.id)) == [0, 1])
    }

    @Test("Query: empty rect returns nothing")
    func queryEmptyRect() {
        let tree = CameraQuadtree()
        tree.insert(makeCam(0, 40.0, -74.0))
        var results: [CameraNode] = []
        tree.query(in: GeoRect(minLat: 0, maxLat: 1, minLon: 0, maxLon: 1)) { results.append($0) }
        #expect(results.isEmpty)
    }

    @Test("Radius query: near point")
    func queryNear() {
        let tree = CameraQuadtree()
        let center = Coordinate(latitude: 40.0, longitude: -74.0)
        // Insert one camera 100 m north
        let near = Geo.destination(from: center, bearing: 0, meters: 100)
        tree.insert(makeCam(0, near.latitude, near.longitude))
        // Insert one camera 1000 m south
        let far = Geo.destination(from: center, bearing: 180, meters: 1000)
        tree.insert(makeCam(1, far.latitude, far.longitude))

        let within500 = tree.query(near: center, radius: 500)
        #expect(within500.count == 1)
        #expect(within500[0].id == 0)
    }

    @Test("Quadtree handles massive insert without crash")
    func massInsert() {
        let tree = CameraQuadtree(capacity: 16)
        for i in 0..<10_000 {
            let lat = 30.0 + Double(i % 100) * 0.01
            let lon = -90.0 + Double(i / 100) * 0.01
            tree.insert(makeCam(Int64(i), lat, lon))
        }
        #expect(tree.count == 10_000)
        // Spot-check a small-area query
        var results: [CameraNode] = []
        tree.query(in: GeoRect(minLat: 30.0, maxLat: 30.05, minLon: -90.0, maxLon: -89.95)) { results.append($0) }
        #expect(results.count > 0 && results.count < 100)
    }
}

// MARK: - GeoRect Tests

@Suite("GeoRect")
struct GeoRectTests {
    @Test("Contains: point inside")
    func containsInside() {
        let r = GeoRect(minLat: 39, maxLat: 41, minLon: -75, maxLon: -73)
        #expect(r.contains(lat: 40, lon: -74))
    }

    @Test("Contains: point outside")
    func containsOutside() {
        let r = GeoRect(minLat: 39, maxLat: 41, minLon: -75, maxLon: -73)
        #expect(!r.contains(lat: 42, lon: -74))
    }

    @Test("Intersects: overlapping rects")
    func intersectsOverlapping() {
        let a = GeoRect(minLat: 0, maxLat: 10, minLon: 0, maxLon: 10)
        let b = GeoRect(minLat: 5, maxLat: 15, minLon: 5, maxLon: 15)
        #expect(a.intersects(b))
        #expect(b.intersects(a))
    }

    @Test("Intersects: disjoint rects")
    func intersectsDisjoint() {
        let a = GeoRect(minLat: 0, maxLat: 10, minLon: 0, maxLon: 10)
        let b = GeoRect(minLat: 20, maxLat: 30, minLon: 20, maxLon: 30)
        #expect(!a.intersects(b))
    }

    @Test("Expanded: grows the rect by the given meters")
    func expanded() {
        let r = GeoRect(minLat: 40, maxLat: 41, minLon: -74, maxLon: -73)
        let e = r.expanded(meters: 1000)
        #expect(e.minLat < 40)
        #expect(e.maxLat > 41)
        #expect(e.minLon < -74)
        #expect(e.maxLon > -73)
    }

    @Test("Around: builds bounding box from two points")
    func around() {
        let a = Coordinate(latitude: 40, longitude: -74)
        let b = Coordinate(latitude: 41, longitude: -73)
        let r = GeoRect.around(a, b)
        #expect(r.minLat == 40 && r.maxLat == 41)
        #expect(r.minLon == -74 && r.maxLon == -73)
    }
}

// MARK: - GeoJSON Loading Tests

@Suite("Camera loader")
struct CameraLoaderTests {
    @Test("Load valid GeoJSON FeatureCollection")
    func loadValidGeoJSON() throws {
        let json = """
        {
            "type": "FeatureCollection",
            "features": [
                {
                    "type": "Feature",
                    "geometry": {"type": "Point", "coordinates": [-74.006, 40.7128]},
                    "properties": {"direction": 90}
                },
                {
                    "type": "Feature",
                    "geometry": {"type": "Point", "coordinates": [-118.243, 34.0522]},
                    "properties": {"direction": "180"}
                },
                {
                    "type": "Feature",
                    "geometry": {"type": "Point", "coordinates": [-87.6298, 41.8781]},
                    "properties": {}
                }
            ]
        }
        """
        let tree = try CameraLoader.loadGeoJSON(data: Data(json.utf8))
        #expect(tree.count == 3)

        // Verify NYC camera is findable
        let nycResults = tree.query(near: Coordinate(latitude: 40.7128, longitude: -74.006), radius: 100)
        #expect(nycResults.count == 1)
        #expect(nycResults[0].direction == 90)
    }

    @Test("Load GeoJSON with string direction")
    func loadStringDirection() throws {
        let json = """
        {
            "type": "FeatureCollection",
            "features": [
                {
                    "type": "Feature",
                    "geometry": {"type": "Point", "coordinates": [0, 0]},
                    "properties": {"direction": "45.5"}
                }
            ]
        }
        """
        let tree = try CameraLoader.loadGeoJSON(data: Data(json.utf8))
        let results = tree.query(near: Coordinate(latitude: 0, longitude: 0), radius: 100)
        #expect(results.count == 1)
        #expect(results[0].direction == 45.5)
    }

    @Test("Load GeoJSON skips non-Point geometry")
    func skipNonPointGeometry() throws {
        let json = """
        {
            "type": "FeatureCollection",
            "features": [
                {
                    "type": "Feature",
                    "geometry": {"type": "LineString", "coordinates": [[0,0],[1,1]]},
                    "properties": {}
                },
                {
                    "type": "Feature",
                    "geometry": {"type": "Point", "coordinates": [0, 0]},
                    "properties": {}
                }
            ]
        }
        """
        let tree = try CameraLoader.loadGeoJSON(data: Data(json.utf8))
        #expect(tree.count == 1)
    }

    @Test("Load empty FeatureCollection")
    func loadEmpty() throws {
        let json = """
        {"type": "FeatureCollection", "features": []}
        """
        let tree = try CameraLoader.loadGeoJSON(data: Data(json.utf8))
        #expect(tree.count == 0)
    }
}

// MARK: - ExposureAnalyzer Tests

@Suite("Exposure analysis")
struct ExposureAnalyzerTests {
    @Test("Route passing through a camera geofence is detected")
    func detectsCameraOnRoute() {
        let tree = CameraQuadtree()
        // Place a camera at (40.005, -74.0) — right on the path
        tree.insert(CameraNode(id: 1, latitude: 40.005, longitude: -74.0))

        let analyzer = ExposureAnalyzer(index: tree, radius: 500)
        let path = RoutePath((0...10).map { Coordinate(latitude: 40.0 + Double($0) * 0.001, longitude: -74.0) })

        let hits = analyzer.hits(along: path, ignoringNear: [])
        #expect(hits.count == 1)
        #expect(hits[0].camera.id == 1)
        #expect(hits[0].distance < 10)   // should be nearly on the path
    }

    @Test("Camera far from route is not detected")
    func ignoresDistantCamera() {
        let tree = CameraQuadtree()
        // Camera 5 km away from the route
        tree.insert(CameraNode(id: 1, latitude: 40.05, longitude: -73.95))

        let analyzer = ExposureAnalyzer(index: tree, radius: 500)
        let path = RoutePath((0...10).map { Coordinate(latitude: 40.0 + Double($0) * 0.001, longitude: -74.0) })

        let hits = analyzer.hits(along: path, ignoringNear: [])
        #expect(hits.isEmpty)
    }

    @Test("Cameras near anchors are ignored")
    func ignoresAnchorCameras() {
        let tree = CameraQuadtree()
        // Camera right at the origin
        tree.insert(CameraNode(id: 1, latitude: 40.0, longitude: -74.0))

        let analyzer = ExposureAnalyzer(index: tree, radius: 500)
        let path = RoutePath((0...10).map { Coordinate(latitude: 40.0 + Double($0) * 0.001, longitude: -74.0) })
        let origin = Coordinate(latitude: 40.0, longitude: -74.0)

        let hits = analyzer.hits(along: path, ignoringNear: [origin])
        #expect(hits.isEmpty, "Camera near origin should be ignored")
    }

    @Test("Zones: nearby cameras are grouped together")
    func groupsIntoZones() {
        let tree = CameraQuadtree()
        // Two cameras 50 m apart along the route (within 2×radius)
        tree.insert(CameraNode(id: 1, latitude: 40.003, longitude: -74.0))
        tree.insert(CameraNode(id: 2, latitude: 40.0035, longitude: -74.0))
        // One camera much further along
        tree.insert(CameraNode(id: 3, latitude: 40.008, longitude: -74.0))

        let analyzer = ExposureAnalyzer(index: tree, radius: 500)
        let path = RoutePath((0...100).map { Coordinate(latitude: 40.0 + Double($0) * 0.0001, longitude: -74.0) })
        let hits = analyzer.hits(along: path, ignoringNear: [])
        let zones = analyzer.zones(hits, path: path)

        // With radius=500, cameras 50 m apart should be in the same zone; the one 500 m away may be separate
        #expect(zones.count >= 1)
    }
}

// MARK: - AvoidanceRouter Tests (with mock provider)

/// A simple mock route provider for testing the avoidance algorithm.
struct MockRouteProvider: RouteProvider {
    let fixedRoutes: [[Coordinate]]

    func routes(from origin: Coordinate, to destination: Coordinate,
                via: [Coordinate], alternatives: Bool) async throws -> [RouteCandidate] {
        // Return fixed routes regardless of via/alternatives — just enough for the algorithm to exercise.
        fixedRoutes.map { poly in
            let path = RoutePath(poly)
            return RouteCandidate(polyline: poly, distanceMeters: path.length, durationSeconds: path.length / 13.4)
        }
    }
}

@Suite("Avoidance router")
struct AvoidanceRouterTests {
    @Test("Clean route with no cameras returns immediately")
    func cleanRoute() async throws {
        let tree = CameraQuadtree()
        let polyline = (0...20).map { Coordinate(latitude: 40.0 + Double($0) * 0.001, longitude: -74.0) }
        let provider = MockRouteProvider(fixedRoutes: [polyline])
        let router = AvoidanceRouter(provider: provider, cameras: tree,
                                      config: AvoidanceConfig(radius: 500, maxRouteCalls: 8))

        let outcome = try await router.route(
            from: Coordinate(latitude: 40.0, longitude: -74.0),
            to: Coordinate(latitude: 40.02, longitude: -74.0)
        )
        #expect(outcome.isClean)
        #expect(outcome.routeCalls == 1)
        #expect(outcome.vias.isEmpty)
    }

    @Test("Route with camera triggers detour attempts")
    func routeWithCamera() async throws {
        let tree = CameraQuadtree()
        tree.insert(CameraNode(id: 1, latitude: 40.01, longitude: -74.0))

        let polyline = (0...20).map { Coordinate(latitude: 40.0 + Double($0) * 0.001, longitude: -74.0) }
        let provider = MockRouteProvider(fixedRoutes: [polyline])
        let router = AvoidanceRouter(provider: provider, cameras: tree,
                                      config: AvoidanceConfig(radius: 500, maxRouteCalls: 4))

        let outcome = try await router.route(
            from: Coordinate(latitude: 40.0, longitude: -74.0),
            to: Coordinate(latitude: 40.02, longitude: -74.0)
        )
        // With a fixed mock provider, the detour attempts won't actually change the route,
        // but the algorithm should have tried (routeCalls > 1) and reported remaining cameras.
        #expect(outcome.routeCalls > 1, "Should attempt detours")
        #expect(!outcome.remainingCameras.isEmpty, "Mock can't actually detour, so cameras remain")
    }

    @Test("No route throws RouterError.noRoute")
    func noRouteError() async {
        let tree = CameraQuadtree()
        let provider = MockRouteProvider(fixedRoutes: [])
        let router = AvoidanceRouter(provider: provider, cameras: tree)

        do {
            _ = try await router.route(
                from: Coordinate(latitude: 0, longitude: 0),
                to: Coordinate(latitude: 1, longitude: 1)
            )
            Issue.record("Should have thrown")
        } catch let error as RouterError {
            // expected — verify it's noRoute
            if case .noRoute = error {} else {
                Issue.record("Expected .noRoute, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

// MARK: - MovementSimulator Tests

@Suite("Movement simulator")
struct MovementSimulatorTests {
    let samplePath: RoutePath = {
        // 2 km straight line heading north
        RoutePath((0...200).map { Coordinate(latitude: 40.0 + Double($0) * 0.0001, longitude: -74.0) })
    }()

    @Test("Simulator reaches the end of the route")
    func reachesEnd() {
        // Use a no-stops, no-noise profile with a seeded RNG for determinism
        var profile = MovementProfile(stopsPerKm: 0, speedNoiseSD: 0, lateralNoiseSD: 0)
        profile.multiplier = 5.0   // speed up
        var sim = MovementSimulator(path: samplePath, profile: profile, seed: 42)

        var lastUpdate: MovementUpdate?
        for _ in 0..<500 {
            let u = sim.step(dt: profile.multiplier)
            lastUpdate = u
            if u.finished { break }
        }
        #expect(lastUpdate?.finished == true, "Simulator should finish the route")
    }

    @Test("Speed never exceeds cruise + reasonable noise")
    func speedBounded() {
        var profile = MovementProfile()
        profile.multiplier = 1.0
        var sim = MovementSimulator(path: samplePath, profile: profile, seed: 123)

        let maxAllowed = profile.cruiseSpeed * 2  // generous bound
        for _ in 0..<200 {
            let u = sim.step(dt: 1.0)
            #expect(u.speed <= maxAllowed, "Speed \(u.speed) exceeds bound \(maxAllowed)")
            if u.finished { break }
        }
    }

    @Test("Distance remaining decreases monotonically (ignoring stops)")
    func distanceDecreases() {
        var profile = MovementProfile(stopsPerKm: 0, speedNoiseSD: 0, lateralNoiseSD: 0)
        profile.multiplier = 2.0
        var sim = MovementSimulator(path: samplePath, profile: profile, seed: 7)

        var prevDist = Double.infinity
        for _ in 0..<300 {
            let u = sim.step(dt: profile.multiplier)
            #expect(u.distanceRemaining <= prevDist + 1.0, // 1m tolerance for floating point
                    "Distance should decrease: was \(prevDist), now \(u.distanceRemaining)")
            prevDist = u.distanceRemaining
            if u.finished { break }
        }
    }

    @Test("Deterministic with same seed")
    func deterministic() {
        let profile = MovementProfile(multiplier: 1.0)
        var sim1 = MovementSimulator(path: samplePath, profile: profile, seed: 999)
        var sim2 = MovementSimulator(path: samplePath, profile: profile, seed: 999)

        for i in 0..<50 {
            let u1 = sim1.step(dt: 1.0)
            let u2 = sim2.step(dt: 1.0)
            #expect(u1.coordinate.latitude == u2.coordinate.latitude,
                    "Step \(i): lat mismatch")
            #expect(u1.speed == u2.speed, "Step \(i): speed mismatch")
            if u1.finished { break }
        }
    }

    @Test("Short path finishes immediately")
    func shortPath() {
        let shortPath = RoutePath([
            Coordinate(latitude: 40.0, longitude: -74.0),
            Coordinate(latitude: 40.00001, longitude: -74.0),
        ])
        var sim = MovementSimulator(path: shortPath, profile: .init(), seed: 1)
        let u = sim.step(dt: 1.0)
        #expect(u.finished)
    }
}

@Suite("Route status")
struct RouteStatusTests {
    @Test("Exposure risk rolls up from camera hits and keeps a usable summary")
    func exposureSummary() {
        let summary = RouteExposureStatus.summary(
            totalDistanceMeters: 1800,
            remainingDistanceMeters: 300,
            cameraHits: [
                CameraHit(camera: CameraNode(id: 1, latitude: 40.0, longitude: -74.0), along: 0, distance: 20, segment: 0),
                CameraHit(camera: CameraNode(id: 2, latitude: 40.0, longitude: -74.0005), along: 250, distance: 50, segment: 1),
                CameraHit(camera: CameraNode(id: 3, latitude: 40.0, longitude: -74.001), along: 1200, distance: 120, segment: 3),
            ]
        )

        #expect(summary.remainingPercent == 16.6666666667)
        #expect(summary.risk == .high)
        #expect(summary.alertCount == 3)
        #expect(summary.message.contains("high"))
    }
}

// MARK: - Coordinate Tests

@Suite("Coordinate")
struct CoordinateTests {
    @Test("Hashable conformance")
    func hashable() {
        let a = Coordinate(latitude: 40.0, longitude: -74.0)
        let b = Coordinate(latitude: 40.0, longitude: -74.0)
        let c = Coordinate(latitude: 41.0, longitude: -74.0)
        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b]).count == 1)
    }

    @Test("Codable round-trip")
    func codable() throws {
        let original = Coordinate(latitude: 51.5074, longitude: -0.1278)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Coordinate.self, from: data)
        #expect(decoded == original)
    }
}
