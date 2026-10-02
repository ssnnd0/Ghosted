import Testing
import Foundation
@testable import GhostedCore

// MARK: - Coordinate input

@Suite("Coordinate input")
struct CoordinateInputTests {

    @Test("Parses the comma form")
    func comma() throws {
        let c = try CoordinateInput.parse("40.7128, -74.0060", label: "From")
        #expect(abs(c.latitude - 40.7128) < 1e-9)
        #expect(abs(c.longitude + 74.0060) < 1e-9)
    }

    @Test("Accepts a space separator — what a paste from Maps produces")
    func space() throws {
        let c = try CoordinateInput.parse("  40.7128 -74.0060 ", label: "From")
        #expect(abs(c.latitude - 40.7128) < 1e-9)
    }

    @Test("Accepts a semicolon and a tab")
    func oddSeparators() throws {
        #expect(try CoordinateInput.parse("1;2", label: "X").latitude == 1)
        #expect(try CoordinateInput.parse("1\t2", label: "X").longitude == 2)
    }

    @Test("Tolerates extra internal whitespace")
    func messyWhitespace() throws {
        let c = try CoordinateInput.parse("  40.7128 ,   -74.0060  ", label: "From")
        #expect(c.longitude < 0)
    }

    @Test("Empty input names the field and says what to type")
    func empty() {
        #expect(throws: CoordinateInputError.empty("To")) {
            try CoordinateInput.parse("   ", label: "To")
        }
        do {
            _ = try CoordinateInput.parse(nil, label: "To")
            Issue.record("expected a throw")
        } catch {
            // The message is what the user sees; it has to name the offending field.
            #expect("\(error)".contains("To"))
            #expect("\(error)".contains("40.7128"))
        }
    }

    @Test("Wrong component count is rejected, not silently truncated")
    func wrongArity() {
        for bad in ["40.7128", "40.7128, -74.0060, 12", "-74.0060,"] {
            #expect(throws: CoordinateInputError.notTwoNumbers("From")) {
                try CoordinateInput.parse(bad, label: "From")
            }
        }
    }

    @Test("Non-numeric text is rejected with its own message")
    func nonNumeric() {
        #expect(throws: CoordinateInputError.notNumeric("From")) {
            try CoordinateInput.parse("north, west", label: "From")
        }
    }

    @Test("infinity is rejected — it would pass a naive abs() <= 180 range check")
    func infinityRejected() {
        // `Double("inf")` parses, and `abs(inf) <= 180` is false, but a check written as
        // `abs(lon) <= 180` guards by comparison while `(-180...180).contains(.infinity)`
        // also fails. The real risk is nan: every comparison against nan is false, so a
        // hand-rolled `if lat < -90 || lat > 90` check lets nan straight through.
        #expect(throws: CoordinateInputError.notNumeric("From")) {
            try CoordinateInput.parse("nan, nan", label: "From")
        }
        #expect(throws: CoordinateInputError.notNumeric("From")) {
            try CoordinateInput.parse("40.0, inf", label: "From")
        }
    }

    @Test("Out-of-range axes are reported per axis, with the value")
    func outOfRange() {
        #expect(throws: CoordinateInputError.latitudeOutOfRange("From", 91)) {
            try CoordinateInput.parse("91, 0", label: "From")
        }
        #expect(throws: CoordinateInputError.longitudeOutOfRange("To", -181)) {
            try CoordinateInput.parse("0, -181", label: "To")
        }
        do {
            _ = try CoordinateInput.parse("91, 0", label: "From")
            Issue.record("expected a throw")
        } catch {
            #expect("\(error)".contains("91"))
            #expect("\(error)".contains("-90"))
        }
    }

    @Test("Boundary values are valid")
    func boundaries() throws {
        let poles = try CoordinateInput.parse("90, 180", label: "X")
        #expect(poles.latitude == 90)
        let antimeridian = try CoordinateInput.parse("-90, -180", label: "X")
        #expect(antimeridian.longitude == -180)
    }

    @Test("parseIfValid is the non-throwing form of the same rules")
    func ifValid() {
        #expect(CoordinateInput.parseIfValid("40.0, -74.0") != nil)
        #expect(CoordinateInput.parseIfValid("40.0") == nil)
        #expect(CoordinateInput.parseIfValid("") == nil)
    }

    @Test("format → parse round-trips to about a centimetre")
    func roundTrip() throws {
        let original = Coordinate(latitude: 40.7128123, longitude: -74.0060432)
        let parsed = try CoordinateInput.parse(CoordinateInput.format(original), label: "X")
        #expect(Geo.haversine(original, parsed) < 0.01)
    }
}

// MARK: - Settings

@Suite("App settings")
struct AppSettingsTests {

    @Test("Defaults are usable — a fresh install can route")
    func defaults() {
        let s = AppSettings()
        #expect(s.backend == .osrm)
        #expect(s.isUsable, "the default configuration must be able to plan a route")
    }

    @Test("Out-of-range values are clamped, not stored")
    func clamping() {
        let s = AppSettings(avoidanceRadiusMeters: 99_999, alertRadiusMeters: -5, speedMultiplier: 0)
        #expect(s.avoidanceRadiusMeters == AppSettings.radiusRange.upperBound)
        #expect(s.alertRadiusMeters == AppSettings.radiusRange.lowerBound)
        #expect(s.speedMultiplier == AppSettings.multiplierRange.lowerBound)
    }

    @Test("Non-finite values clamp to the lower bound rather than propagating NaN")
    func nonFinite() {
        let s = AppSettings(speedMultiplier: .nan, avoidanceRadiusMeters: .infinity)
        #expect(s.speedMultiplier == AppSettings.multiplierRange.lowerBound)
        #expect(s.avoidanceRadiusMeters == AppSettings.radiusRange.upperBound)
    }

    @Test("Trailing slashes are stripped — providers concatenate paths onto the base URL")
    func trailingSlash() {
        #expect(AppSettings.normalizedBaseURL("https://x.example/", fallback: "d") == "https://x.example")
        #expect(AppSettings.normalizedBaseURL("https://x.example///", fallback: "d") == "https://x.example")
        #expect(AppSettings.normalizedBaseURL("  ", fallback: "d") == "d")
        #expect(AppSettings.normalizedBaseURL(nil, fallback: "d") == "d")
    }

    @Test("GraphHopper without a key is reported unusable before a drive is attempted")
    func graphhopperNeedsKey() {
        let noKey = AppSettings(backend: .graphhopper, apiKey: "")
        #expect(!noKey.isUsable)
        #expect(noKey.configurationWarning?.contains("API key") == true)

        let withKey = AppSettings(backend: .graphhopper, apiKey: "abc")
        #expect(withKey.isUsable)
        #expect(withKey.configurationWarning == nil)
    }

    @Test("OSRM and Valhalla need no key")
    func keylessBackends() {
        #expect(AppSettings(backend: .osrm, apiKey: "").isUsable)
        #expect(AppSettings(backend: .valhalla, apiKey: "").isUsable)
    }

    @Test("Only Valhalla has native exclusion; the others warn about the downgrade")
    func exclusionSupport() {
        #expect(RoutingBackend.valhalla.supportsNativeExclusion)
        #expect(!RoutingBackend.osrm.supportsNativeExclusion)
        #expect(!RoutingBackend.graphhopper.supportsNativeExclusion)

        let valhalla = AppSettings(backend: .valhalla, baseURL: "https://my.valhalla")
        #expect(valhalla.configurationWarning == nil, "a self-hosted Valhalla is the best case")

        let osrm = AppSettings(backend: .osrm, baseURL: "https://router.project-osrm.org")
        #expect(osrm.configurationWarning?.contains("demo server") == true)

        let gh = AppSettings(backend: .graphhopper, apiKey: "k", baseURL: "https://gh.example/api/1")
        #expect(gh.configurationWarning?.contains("waypoints") == true)
    }

    @Test("An empty base URL falls back to the backend's default")
    func baseURLFallback() {
        #expect(AppSettings(backend: .valhalla, baseURL: "").baseURL == RoutingBackend.valhalla.defaultBaseURL)
        #expect(AppSettings(backend: .osrm, baseURL: nil).baseURL == RoutingBackend.osrm.defaultBaseURL)
    }

    @Test("Codable round trip preserves everything")
    func codableRoundTrip() throws {
        var original = AppSettings(backend: .valhalla, baseURL: "https://v.example",
                                   apiKey: "k", avoidanceRadiusMeters: 300,
                                   alertRadiusMeters: 400, speedMultiplier: 2.5,
                                   speakAlerts: false, avoidCameras: false,
                                   followSimulatedPosition: false)
        original.normalize()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == original)
    }

    @Test("Decoding normalises: synthesised init(from:) would otherwise bypass every clamp")
    func decodeNormalises() throws {
        // Hand-written JSON with out-of-range values, as a stale or edited preferences file.
        let json = """
        {"backend":"osrm","baseURL":"https://x.example/","apiKey":"",
         "avoidanceRadiusMeters":1e9,"alertRadiusMeters":-3,"speedMultiplier":9999,
         "speakAlerts":true,"avoidCameras":true,"followSimulatedPosition":true}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.avoidanceRadiusMeters == AppSettings.radiusRange.upperBound)
        #expect(decoded.alertRadiusMeters == AppSettings.radiusRange.lowerBound)
        #expect(decoded.speedMultiplier == AppSettings.multiplierRange.upperBound)
        #expect(decoded.baseURL == "https://x.example")
    }

    @Test("An unknown backend name falls back instead of failing the whole decode")
    func unknownBackend() throws {
        // A preferences file written by a newer build, or hand-edited. Losing every other
        // setting to save one field would be a worse outcome than ignoring the field.
        let json = """
        {"backend":"routingengine7","baseURL":"https://x.example","apiKey":"","speedMultiplier":3}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.backend == .osrm)
        #expect(decoded.speedMultiplier == 3, "other fields must survive")
    }

    @Test("A partial JSON object decodes using defaults for the rest")
    func partialJSON() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"speedMultiplier": 7}"#.utf8))
        #expect(decoded.speedMultiplier == 7)
        #expect(decoded.backend == .osrm)
    }

    @Test("avoidanceConfig carries the user's radius through to the router")
    func avoidanceConfig() {
        let s = AppSettings(avoidanceRadiusMeters: 275)
        #expect(s.avoidanceConfig.radius == 275)
    }
}

// MARK: - Formatting

@Suite("Formatting")
struct FormatTests {

    @Test("Distance switches unit at a kilometre")
    func distance() {
        #expect(Format.distance(0) == "0 m")
        #expect(Format.distance(999) == "999 m")
        #expect(Format.distance(1000) == "1.0 km")
        #expect(Format.distance(12_345) == "12.3 km")
        #expect(Format.distance(.nan) == "—")
    }

    @Test("Duration reads as hours once past an hour")
    func duration() {
        #expect(Format.duration(45) == "45 s")
        #expect(Format.duration(60) == "1 min")
        #expect(Format.duration(720) == "12 min")
        #expect(Format.duration(3600) == "1 h 00 min")
        #expect(Format.duration(3900) == "1 h 05 min")
        #expect(Format.duration(-1) == "—")
        #expect(Format.duration(.nan) == "—")
    }

    @Test("Count pluralises")
    func count() {
        #expect(Format.count(1, "camera") == "1 camera")
        #expect(Format.count(2, "camera") == "2 cameras")
        #expect(Format.count(0, "match", "matches") == "0 matches")
    }
}

// MARK: - Camera enumeration

@Suite("Camera enumeration")
struct CameraEnumerationTests {

    /// Builds an index by inserting directly, which forces subdivision at a small capacity —
    /// the point is to exercise `collect` on a non-trivial tree rather than one root leaf.
    private func populatedIndex() -> CameraQuadtree {
        let tree = CameraQuadtree(capacity: 2, maxDepth: 6)
        for i in 0..<200 {
            let lat = -40 + Double(i) * 0.4
            let lon = -70 + Double(i % 97) * 1.4
            tree.insert(CameraNode(id: Int64(i), latitude: lat, longitude: lon, direction: Double(i % 360)))
        }
        return tree
    }

    @Test("allCameras returns every inserted camera exactly once")
    func allCameras() {
        let tree = populatedIndex()
        #expect(tree.count == 200)
        let all = tree.allCameras()
        #expect(all.count == 200, "walked \(all.count) of \(tree.count)")
        #expect(Set(all.map(\.id)).count == 200, "no duplicates and none lost")
    }

    @Test("allCameras on an empty index is empty, not a crash")
    func empty() {
        let tree = CameraQuadtree()
        #expect(tree.allCameras().isEmpty)
        #expect(tree.bounds == nil, "an empty index has no bounds to frame a map on")
    }

    @Test("Enumeration agrees with the range query")
    func agreesWithQuery() {
        let tree = populatedIndex()
        let everything = Set(tree.allCameras().map(\.id))
        let worldRect = GeoRect(minLat: -90, maxLat: 90, minLon: -180, maxLon: 180)
        var viaQuery: Set<Int64> = []
        tree.query(in: worldRect) { viaQuery.insert($0.id) }
        #expect(everything == viaQuery)
    }

    @Test("bounds covers every camera")
    func bounds() {
        let tree = populatedIndex()
        let all = tree.allCameras()
        guard let b = tree.bounds else { Issue.record("expected bounds"); return }
        for c in all {
            #expect(b.contains(lat: c.latitude, lon: c.longitude), "camera \(c.id) outside bounds")
        }
        #expect(b.contains(lat: all.map(\.latitude).min()!, lon: all.map(\.longitude).min()!))
        #expect(b.contains(lat: all.map(\.latitude).max()!, lon: all.map(\.longitude).max()!))
    }

    @Test("A single camera gives a degenerate but valid bounding box")
    func singleBounds() {
        let tree = CameraQuadtree()
        tree.insert(CameraNode(id: 1, latitude: 10, longitude: 20))
        let b = tree.bounds
        #expect(b?.minLat == 10 && b?.maxLat == 10)
        #expect(b?.minLon == 20 && b?.maxLon == 20)
    }
}

// MARK: - Route library

@Suite("Route library")
struct RouteLibraryTests {

    /// A fresh temporary directory per test. `RouteLibrary` creates the directory itself, so
    /// passing a path that does not exist yet also covers the create-on-first-save path.
    private func tempLibrary() -> RouteLibrary {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosted-lib-\(UUID().uuidString)", isDirectory: true)
        return RouteLibrary(directory: dir)
    }

    private func sampleRoute(name: String = "Downtown loop") -> SavedRoute {
        SavedRoute(name: name,
                   origin: Coordinate(latitude: 40.70, longitude: -74.00),
                   destination: Coordinate(latitude: 40.78, longitude: -73.98),
                   polyline: [Coordinate(latitude: 40.70, longitude: -74.00),
                              Coordinate(latitude: 40.74, longitude: -73.99),
                              Coordinate(latitude: 40.78, longitude: -73.98)],
                   distanceMeters: 9_400, durationSeconds: 780,
                   cameraHitIDs: [7], provider: "OSRM")
    }

    @Test("Save then read returns the same route")
    func saveAndRead() throws {
        let lib = tempLibrary()
        #expect(try lib.all().isEmpty, "reading a directory that does not exist is empty, not an error")
        let saved = try lib.save(sampleRoute())
        let all = try lib.all()
        #expect(all.count == 1)
        #expect(all.first?.id == saved.id)
        #expect(all.first?.name == "Downtown loop")
        #expect(all.first?.polyline.count == 3)
        #expect(all.first?.cameraHitIDs == [7])
    }

    @Test("Re-saving the same name replaces rather than duplicating")
    func replaceByName() throws {
        let lib = tempLibrary()
        let first = try lib.save(sampleRoute())
        Thread.sleep(forTimeInterval: 0.01)
        var second = sampleRoute()
        second.distanceMeters = 12_000
        second.notes = "edited"
        try lib.save(second)

        let all = try lib.all()
        #expect(all.count == 1, "saving over a name must not create a second file")
        #expect(all.first?.distanceMeters == 12_000)
        #expect(all.first?.notes == "edited")
        // Identity and creation date survive, so a selected row keeps pointing at this route.
        #expect(all.first?.id == first.id)
        #expect(all.first?.createdAt == first.createdAt)
    }

    @Test("Two names that slug to the same filename do not overwrite each other")
    func slugCollision() throws {
        let lib = tempLibrary()
        let a = try lib.save(sampleRoute(name: "A/B"))
        let b = try lib.save(sampleRoute(name: "A B"))
        #expect(a.id != b.id)

        let all = try lib.all()
        #expect(all.count == 2, "losing a route the user believed was saved is the one bug this library must not have")

        // And the disambiguated one is still re-savable in place, not duplicated again.
        var edited = b
        edited.notes = "second pass"
        try lib.save(edited)
        let after = try lib.all()
        #expect(after.count == 2, "re-saving a disambiguated route must not fork a new file")
        #expect(after.first { $0.id == b.id }?.notes == "second pass")
    }

    @Test("A name that slugifies to nothing still saves")
    func pathologicalName() throws {
        let lib = tempLibrary()
        let saved = try lib.save(sampleRoute(name: "///???///"))
        #expect(try lib.all().count == 1)
        #expect(saved.fileName == "route")
        #expect(try lib.delete(named: "///???///"))
        #expect(try lib.all().isEmpty)
    }

    @Test("Names differing only by case collide — the slug is case-preserving but lookup is not")
    func caseInsensitivity() throws {
        let lib = tempLibrary()
        try lib.save(sampleRoute(name: "My Route"))
        let found = try lib.route(named: "my route")
        #expect(found?.name == "My Route", "lookup is case-insensitive, so the delete path must find it")
        #expect(try lib.delete(named: "MY ROUTE"))
        #expect(try lib.all().isEmpty)
    }

    @Test("A route with fewer than two points is refused at save time")
    func refusesUndrivable() {
        let lib = tempLibrary()
        var bad = sampleRoute()
        bad.polyline = [Coordinate(latitude: 1, longitude: 2)]
        #expect(throws: RouteLibraryError.self) { try lib.save(bad) }
    }

    @Test("Routes come back newest first")
    func ordering() throws {
        let lib = tempLibrary()
        var older = sampleRoute(name: "Older")
        older.createdAt = Date(timeIntervalSince1970: 1_000_000)
        var newer = sampleRoute(name: "Newer")
        newer.createdAt = Date(timeIntervalSince1970: 2_000_000)
        try lib.save(older)
        try lib.save(newer)
        #expect(try lib.all().map(\.name) == ["Newer", "Older"])
    }

    @Test("One corrupt file does not hide the rest of the library")
    func corruptFileIsSkipped() throws {
        let lib = tempLibrary()
        try lib.save(sampleRoute(name: "Good one"))
        try lib.save(sampleRoute(name: "Good two"))

        let broken = lib.directory.appendingPathComponent("Broken.\(RouteLibrary.fileExtension)")
        try Data("{ not json at all".utf8).write(to: broken)

        let all = try lib.all()
        #expect(all.count == 2)
        #expect(lib.lastReadWarning?.contains("could not be read") == true)
        // The UI is expected to surface that rather than silently showing fewer routes.
    }

    @Test("Garbage inside a route is normalised rather than trusted")
    func normalisesOnRead() throws {
        let lib = tempLibrary()
        try lib.save(sampleRoute())
        // Rewrite one field to something absurd, as an older schema or a hand-edit might.
        let url = lib.directory.appendingPathComponent("Downtownloop.\(RouteLibrary.fileExtension)")
        var object = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: url)) as! [String: Any]
        object["distanceMeters"] = 1e12
        object["durationSeconds"] = -50
        object["polyline"] = [[40.0, -74.0], ["nope", 0], [200.0, 400.0]]
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let loaded = try lib.all().first
        #expect(loaded?.distanceMeters == 0, "a negative/absurd duration must not reach the UI")
        #expect(loaded?.durationSeconds == 0)
        #expect(loaded?.polyline.count == 1, "invalid coordinates are dropped, not clamped into a wrong place")
        #expect(loaded?.isDrivable == false)
    }

    @Test("deleteAll empties the library but leaves the directory")
    func deleteAll() throws {
        let lib = tempLibrary()
        try lib.save(sampleRoute(name: "A"))
        try lib.save(sampleRoute(name: "B"))
        try lib.deleteAll()
        #expect(try lib.all().isEmpty)
        #expect(FileManager.default.fileExists(atPath: lib.directory.path))
        // And it is still usable afterwards.
        #expect(try lib.save(sampleRoute(name: "C")).name == "C")
    }

    @Test("Deleting a name that is not there reports false rather than throwing")
    func deleteMissing() throws {
        let lib = tempLibrary()
        #expect(try lib.delete(named: "nothing") == false)
    }

    @Test("allOrEmpty never throws, so a UI read cannot crash on a broken directory")
    func allOrEmpty() throws {
        let lib = tempLibrary()
        #expect(lib.allOrEmpty().isEmpty)
        try lib.save(sampleRoute())
        #expect(lib.allOrEmpty().count == 1)

        // Replace the directory with a *file* — the read must degrade, not trap.
        try FileManager.default.removeItem(at: lib.directory)
        try Data("not a directory".utf8).write(to: lib.directory)
        #expect(lib.allOrEmpty().isEmpty)
    }

    @Test("Concurrent saves do not deadlock — NSLock is not recursive")
    func concurrentAccess() async throws {
        let lib = tempLibrary()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    try lib.save(self.sampleRoute(name: "Route \(i)"))
                    _ = try lib.all()
                    _ = try lib.route(named: "Route \(i)")
                }
            }
            try await group.waitForAll()
        }
        #expect(lib.allOrEmpty().count == 8)
    }

    @Test("Summary and subtitle read as a route line in a list")
    func presentation() {
        let r = sampleRoute()
        #expect(r.summary.contains("9.4 km"))
        #expect(r.summary.contains("13 min"))
        #expect(r.subtitle.contains("OSRM"))
        #expect(r.subtitle.contains("1 camera still on route"))
    }

    @Test("A route built from a planner summary carries every field")
    func fromSummary() {
        let summary = PlannedRouteSummary(
            origin: Coordinate(latitude: 1, longitude: 2),
            destination: Coordinate(latitude: 3, longitude: 4),
            polyline: [Coordinate(latitude: 1, longitude: 2), Coordinate(latitude: 3, longitude: 4)],
            distanceMeters: 100, durationSeconds: 60, cameraHitIDs: [3, 4], provider: "Valhalla")
        let r = SavedRoute(name: "T", planned: summary)
        #expect(r.origin == summary.origin)
        #expect(r.cameraHitIDs == [3, 4])
        #expect(r.provider == "Valhalla")
    }

    @Test("Slugs keep the filename safe")
    func slugSafety() {
        #expect(SavedRoute.slug("../../etc/passwd") == "etcpasswd")
        #expect(SavedRoute.slug("") == "route")
        #expect(SavedRoute.slug("...") == "route")
        // Letters, digits, dash and underscore survive; the space goes.
        #expect(SavedRoute.slug("a b-c_d") == "abc-_d")
        #expect(SavedRoute.slug("--trimmed--") == "trimmed")
        #expect(SavedRoute.slug(String(repeating: "x", count: 200)).count == 64)
    }
}
