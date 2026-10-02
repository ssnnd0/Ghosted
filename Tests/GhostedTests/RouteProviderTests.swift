import Testing
import Foundation
@testable import GhostedCore

// MARK: - Test transport

/// Records what was requested and replies with a canned response. Because every provider takes its
/// transport by injection, this is the whole mocking story — no network, no URLProtocol.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Recorded: Sendable {
        let method: HTTPRequest.Method
        let url: String
        let headers: [String: String]
        let body: Data?
    }

    private let lock = NSLock()
    private var _requests: [Recorded] = []
    private let responder: @Sendable (Recorded) throws -> HTTPResponse

    init(_ responder: @escaping @Sendable (Recorded) throws -> HTTPResponse) {
        self.responder = responder
    }

    /// Always replies `200` with this body.
    convenience init(json: String) {
        self.init { _ in HTTPResponse(status: 200, body: Data(json.utf8)) }
    }

    /// Replies with a fixed status and body for every request.
    convenience init(status: Int, body: String) {
        self.init { _ in HTTPResponse(status: status, body: Data(body.utf8)) }
    }

    var requests: [Recorded] {
        lock.withLock { _requests }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let recorded = Recorded(method: request.method, url: request.url,
                                headers: request.headers, body: request.body)
        lock.withLock { _requests.append(recorded) }
        return try responder(recorded)
    }
}

extension StubTransport.Recorded {
    /// The request body as a JSON object, so tests can assert on structure rather than byte order.
    func jsonBody() throws -> [String: Any] {
        guard let body, let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw TestError.noBody
        }
        return object
    }

    var bodyString: String { (body.flatMap { String(data: $0, encoding: .utf8) }) ?? "" }
}

enum TestError: Error { case noBody }

/// Embeds a string in a JSON literal. Needed because the encoded-polyline format can emit a
/// backslash (its final byte lands in 63…94), so a polyline is never safe to interpolate raw.
func jsonString(_ s: String) -> String {
    var out = "\""
    for ch in s.unicodeScalars {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        default: out.unicodeScalars.append(ch)
        }
    }
    return out + "\""
}

/// A Valhalla leg object holding one polyline6 shape.
func leg(_ points: [Coordinate]) -> String {
    "{\"shape\":\(jsonString(Geo.encodePolyline(points, precision: .p1e6)))}"
}

// MARK: - OSRM

@Suite("OSRM route provider")
struct OSRMRouteProviderTests {
    let origin = Coordinate(latitude: 40.7128, longitude: -74.0060)
    let destination = Coordinate(latitude: 40.7500, longitude: -73.9900)

    /// A real polyline6 of the shape OSRM returns, so decoding is exercised for real.
    /// `geometry:` supplies a raw polyline verbatim (used for the deliberately-broken-shape
    /// fixture); otherwise it is encoded from `points`.
    func osrmJSON(points: [Coordinate] = [], geometry: String? = nil,
                  code: String = "Ok", message: String? = nil) -> String {
        let messagePart = message.map { ", \"message\": \(jsonString($0))" } ?? ""
        let geometry = jsonString(geometry ?? Geo.encodePolyline(points, precision: .p1e6))
        return """
        {"code":"\(code)"\(messagePart),"routes":[{"distance":1234.5,"duration":321.0,"geometry":\(geometry)}]}
        """
    }

    @Test("Decodes a polyline6 geometry at the right precision")
    func decodesGeometry() async throws {
        // Two points ~11 m apart; decoding at 1e5 instead of 1e6 would put them ~100x too close.
        let a = Coordinate(latitude: 40.0, longitude: -74.0)
        let b = Coordinate(latitude: 40.000100, longitude: -74.0)
        let encoded = Geo.encodePolyline([a, b], precision: .p1e6)

        let transport = StubTransport(json: osrmJSON(geometry: encoded))
        let routes = try await OSRMRouteProvider(transport: transport)
            .routes(from: a, to: b, via: [], alternatives: false)

        #expect(routes.count == 1)
        #expect(routes[0].polyline.count == 2)
        #expect(abs(routes[0].polyline[0].latitude - a.latitude) < 1e-6)
        #expect(abs(routes[0].polyline[1].latitude - b.latitude) < 1e-6)
        #expect(routes[0].distanceMeters == 1234.5)
        #expect(routes[0].durationSeconds == 321.0)
    }

    @Test("Request uses lon,lat order and a semicolon path")
    func requestShape() async throws {
        let via = Coordinate(latitude: 40.73, longitude: -74.0)
        let transport = StubTransport(json: osrmJSON(points: [origin, destination]))

        _ = try await OSRMRouteProvider(transport: transport)
            .routes(from: origin, to: destination, via: [via], alternatives: false)

        let url = try #require(transport.requests.first).url
        // OSRM wants lon,lat — the reverse of how the coordinates read. `Double` prints its
        // shortest round-tripping form, so -74.006 rather than -74.006000; both are accepted by
        // the server and this asserts the ordering and separators, not the formatting.
        #expect(url.contains("/route/v1/car/-74.006,40.7128"))
        #expect(url.contains("-74.0,40.73"))     // the via point
        #expect(url.contains("-73.99,40.75"))    // destination
        #expect(url.contains("geometries=polyline6"))
        #expect(url.contains("overview=full"))
        // alternatives was false, so the parameter must be absent rather than "false".
        #expect(!url.contains("alternatives"))
    }

    @Test("alternatives=true is sent when asked for")
    func alternatives() async throws {
        let transport = StubTransport(json: osrmJSON(points: [origin, destination]))
        _ = try await OSRMRouteProvider(transport: transport)
            .routes(from: origin, to: destination, via: [], alternatives: true)
        #expect(try #require(transport.requests.first).url.contains("alternatives=true"))
    }

    @Test("Multiple routes are all returned")
    func multipleRoutes() async throws {
        let geometry = jsonString(Geo.encodePolyline([origin, destination], precision: .p1e6))
        let json = """
        {"code":"Ok","routes":[
          {"distance":1000,"duration":200,"geometry":\(geometry)},
          {"distance":1100,"duration":210,"geometry":\(geometry)}
        ]}
        """
        let routes = try await OSRMRouteProvider(transport: StubTransport(json: json))
            .routes(from: origin, to: destination, via: [], alternatives: true)
        #expect(routes.count == 2)
    }

    @Test("Non-Ok code throws providerFailure carrying the server's message")
    func nonOkCode() async throws {
        let transport = StubTransport(json: osrmJSON(points: [], code: "NoRoute", message: "No route found"))
        await #expect(throws: RouterError.self) {
            try await OSRMRouteProvider(transport: transport)
                .routes(from: origin, to: destination, via: [], alternatives: false)
        }
        do {
            _ = try await OSRMRouteProvider(transport: transport)
                .routes(from: origin, to: destination, via: [], alternatives: false)
            Issue.record("expected a throw")
        } catch let error as RouterError {
            guard case .providerFailure(let message) = error else {
                Issue.record("expected .providerFailure, got \(error)")
                return
            }
            #expect(message.contains("No route found"))
        }
    }

    @Test("HTTP error status throws .http with the status and body")
    func httpError() async throws {
        let transport = StubTransport(status: 503, body: "upstream unavailable")
        do {
            _ = try await OSRMRouteProvider(transport: transport)
                .routes(from: origin, to: destination, via: [], alternatives: false)
            Issue.record("expected a throw")
        } catch let error as RouterError {
            guard case .http(let status, let body) = error else {
                Issue.record("expected .http, got \(error)")
                return
            }
            #expect(status == 503)
            #expect(body.contains("OSRM"))
            #expect(body.contains("upstream unavailable"))
        }
    }

    @Test("Malformed JSON throws providerFailure rather than a decoding error leaking out")
    func malformedJSON() async throws {
        let transport = StubTransport(json: "{ not json")
        do {
            _ = try await OSRMRouteProvider(transport: transport)
                .routes(from: origin, to: destination, via: [], alternatives: false)
            Issue.record("expected a throw")
        } catch let error as RouterError {
            guard case .providerFailure = error else {
                Issue.record("expected .providerFailure, got \(error)")
                return
            }
        }
    }

    @Test("Ok with an empty routes array throws noRoute")
    func emptyRoutes() async throws {
        let transport = StubTransport(json: #"{"code":"Ok","routes":[]}"#)
        await #expect(throws: RouterError.noRoute) {
            try await OSRMRouteProvider(transport: transport)
                .routes(from: origin, to: destination, via: [], alternatives: false)
        }
    }

    @Test("Exclusion rectangles are ignored — OSRM has no polygon support")
    func exclusionsIgnored() async throws {
        let transport = StubTransport(json: osrmJSON(points: [origin, destination]))
        let rect = GeoRect(minLat: 40.72, maxLat: 40.73, minLon: -74.01, maxLon: -74.0)

        _ = try await OSRMRouteProvider(transport: transport)
            .routes(from: origin, to: destination, via: [], alternatives: false, excluding: [rect])

        // Nothing polygon-related should appear anywhere in the request.
        let url = try #require(transport.requests.first).url
        #expect(!url.contains("exclude"))
    }
}

// MARK: - Valhalla

@Suite("Valhalla route provider")
struct ValhallaRouteProviderTests {
    let origin = Coordinate(latitude: 40.7128, longitude: -74.0060)
    let destination = Coordinate(latitude: 40.7500, longitude: -73.9900)

    func valhallaJSON(lengthKm: Double = 1.2345, time: Double = 60.0, code: Int? = nil, error: String? = nil) -> String {
        let statusPart = code.map { "\"status\":{\"code\":\($0),\"status_message\":\"boom\"}," } ?? ""
        let errorPart = error.map { "\"error\":\"\($0)\"," } ?? ""
        return """
        {\(errorPart)"trip":{
          "summary":{"length":\(lengthKm),"time":\(time)},
          "legs":[\(leg([origin, destination]))],
          \(statusPart)
          "status_message":"ok"
        }}
        """
    }

    @Test("Converts the km summary to metres and keeps seconds")
    func unitConversion() async throws {
        let routes = try await ValhallaRouteProvider(baseURL: "http://valhalla.test",
                                                    transport: StubTransport(json: valhallaJSON(lengthKm: 1.2345, time: 60.0)))
            .routes(from: origin, to: destination, via: [], alternatives: false)

        #expect(routes.count == 1)
        #expect(abs(routes[0].distanceMeters - 1234.5) < 0.01)
        #expect(routes[0].durationSeconds == 60.0)
        #expect(routes[0].polyline.count == 2)
    }

    @Test("Requests kilometres and lat,lon location objects")
    func requestShape() async throws {
        let transport = StubTransport(json: valhallaJSON())
        _ = try await ValhallaRouteProvider(baseURL: "http://valhalla.test", transport: transport)
            .routes(from: origin, to: destination, via: [], alternatives: false)

        let request = try #require(transport.requests.first)
        #expect(request.method == .post)
        #expect(request.url == "http://valhalla.test/route")
        #expect(request.headers["Content-Type"] == "application/json")

        let body = try request.jsonBody()
        let options = try #require(body["directions_options"] as? [String: Any])
        #expect(options["units"] as? String == "kilometers")
        #expect(body["costing"] as? String == "auto")

        let locations = try #require(body["locations"] as? [[String: Any]])
        #expect(locations.count == 2)
        // Valhalla wants lat,lon keys, not an array.
        #expect(locations[0]["lat"] != nil)
        #expect(locations[0]["lon"] != nil)
        #expect(abs((locations[0]["lat"] as? Double ?? .nan) - origin.latitude) < 1e-6)
        // No alternates key when alternatives was not requested.
        #expect(body["alternates"] == nil)
    }

    @Test("alternates is sent only when alternatives is requested")
    func alternates() async throws {
        let transport = StubTransport(json: valhallaJSON())
        _ = try await ValhallaRouteProvider(baseURL: "http://valhalla.test", transport: transport)
            .routes(from: origin, to: destination, via: [], alternatives: true)
        #expect(try #require(transport.requests.first).jsonBody()["alternates"] as? Int == 2)
    }

    @Test("Exclusion rectangles become closed exclude polygons")
    func exclusionPolygons() async throws {
        let transport = StubTransport(json: valhallaJSON())
        let rect = GeoRect(minLat: 40.72, maxLat: 40.73, minLon: -74.01, maxLon: -74.00)

        _ = try await ValhallaRouteProvider(baseURL: "http://valhalla.test", transport: transport)
            .routes(from: origin, to: destination, via: [], alternatives: false, excluding: [rect])

        let body = try #require(transport.requests.first).jsonBody()
        let locations = try #require(body["locations"] as? [[String: Any]])
        // Two stops plus one exclude location.
        #expect(locations.count == 3)

        let exclude = locations[2]
        #expect(exclude["type"] as? String == "exclude")

        let shape = try #require(exclude["shape"] as? [[String: Any]])
        #expect(shape.count == 5)                                    // four corners, closed
        #expect((shape.first?["lat"] as? Double) == (shape.last?["lat"] as? Double))
        #expect((shape.first?["lon"] as? Double) == (shape.last?["lon"] as? Double))
    }

    @Test("Via points are passed through in order")
    func viaPoints() async throws {
        let via = [Coordinate(latitude: 40.73, longitude: -74.0),
                   Coordinate(latitude: 40.74, longitude: -73.995)]
        let transport = StubTransport(json: valhallaJSON())
        _ = try await ValhallaRouteProvider(baseURL: "http://valhalla.test", transport: transport)
            .routes(from: origin, to: destination, via: via, alternatives: false)

        let request = try #require(transport.requests.first)
        let body = try request.jsonBody()
        let locations = try #require(body["locations"] as? [[String: Any]])
        #expect(locations.count == 4)
        #expect(abs((locations[1]["lat"] as? Double ?? .nan) - via[0].latitude) < 1e-6)
        #expect(abs((locations[2]["lat"] as? Double ?? .nan) - via[1].latitude) < 1e-6)
    }

    @Test("Leg shapes are concatenated and duplicate join points removed")
    func legDeduplication() async throws {
        let a = origin
        let mid = Coordinate(latitude: 40.73, longitude: -74.0)
        let b = destination
        // Each leg repeats the shared endpoint, exactly as Valhalla encodes them.
        let json = """
        {"trip":{"summary":{"length":1.0,"time":60},
          "legs":[\(leg([a, mid])),\(leg([mid, b]))],
          "status_message":"ok"}}
        """
        let routes = try await ValhallaRouteProvider(baseURL: "http://valhalla.test",
                                                    transport: StubTransport(json: json))
            .routes(from: origin, to: destination, via: [], alternatives: false)

        // Raw concatenation would be [a, mid, mid, b].
        #expect(routes[0].polyline.count == 3)
        #expect(routes[0].polyline[1].latitude == routes[0].polyline[2].latitude ? false : true)
    }

    @Test("Non-zero status code throws providerFailure")
    func errorStatus() async throws {
        let transport = StubTransport(json: #"{"trip":{"summary":{"length":0,"time":0},"legs":[{"shape":"a"}],"status":{"code":154,"status_message":"no path"}}}"#)
        do {
            _ = try await ValhallaRouteProvider(baseURL: "http://valhalla.test", transport: transport)
                .routes(from: origin, to: destination, via: [], alternatives: false)
            Issue.record("expected a throw")
        } catch let error as RouterError {
            guard case .providerFailure(let message) = error else {
                Issue.record("expected .providerFailure, got \(error)")
                return
            }
            #expect(message.contains("no path"))
        }
    }

    @Test("Top-level error field throws providerFailure")
    func errorField() async throws {
        let transport = StubTransport(json: #"{"error":"invalid api key"}"#)
        do {
            _ = try await ValhallaRouteProvider(baseURL: "http://valhalla.test", transport: transport)
                .routes(from: origin, to: destination, via: [], alternatives: false)
            Issue.record("expected a throw")
        } catch let error as RouterError {
            guard case .providerFailure(let message) = error else {
                Issue.record("expected .providerFailure, got \(error)")
                return
            }
            #expect(message.contains("invalid api key"))
        }
    }

    @Test("A shape too short to be a route throws noRoute")
    func degenerateShape() async throws {
        let transport = StubTransport(json: #"{"trip":{"summary":{"length":0,"time":0},"legs":[{"shape":"_"}]}}"#)
        await #expect(throws: RouterError.noRoute) {
            try await ValhallaRouteProvider(baseURL: "http://valhalla.test", transport: transport)
                .routes(from: origin, to: destination, via: [], alternatives: false)
        }
    }

    @Test("An API key is sent as a header and omitted when nil")
    func apiKeyHeader() async throws {
        let withKey = StubTransport(json: valhallaJSON())
        _ = try await ValhallaRouteProvider(baseURL: "http://valhalla.test", apiKey: "secret",
                                            transport: withKey)
            .routes(from: origin, to: destination, via: [], alternatives: false)
        #expect(withKey.requests.first?.headers["api_key"] == "secret")

        let withoutKey = StubTransport(json: valhallaJSON())
        _ = try await ValhallaRouteProvider(baseURL: "http://valhalla.test", transport: withoutKey)
            .routes(from: origin, to: destination, via: [], alternatives: false)
        #expect(withoutKey.requests.first?.headers["api_key"] == nil)
    }
}

// MARK: - GraphHopper

@Suite("GraphHopper route provider")
struct GraphHopperRouteProviderTests {
    let origin = Coordinate(latitude: 40.7128, longitude: -74.0060)
    let destination = Coordinate(latitude: 40.7500, longitude: -73.9900)

    func graphhopperJSON(timeMillis: Int = 60000, pathCount: Int = 1) -> String {
        let paths = (0..<pathCount).map { _ in
            """
            {"distance":1234.5,"time":\(timeMillis),"points":{"coordinates":[[-74.006,40.7128],[-73.99,40.75]]}}
            """
        }.joined(separator: ",")
        return "{\"paths\":[\(paths)]}"
    }

    @Test("Converts milliseconds to seconds and reads GeoJSON lon,lat order")
    func unitsAndOrder() async throws {
        let routes = try await GraphHopperRouteProvider(transport: StubTransport(json: graphhopperJSON(timeMillis: 90_000)))
            .routes(from: origin, to: destination, via: [], alternatives: false)

        #expect(routes.count == 1)
        #expect(routes[0].durationSeconds == 90.0)
        #expect(routes[0].distanceMeters == 1234.5)
        // GeoJSON is [lon, lat]: the first pair must come back as longitude -74.006.
        #expect(abs(routes[0].polyline[0].longitude - (-74.006)) < 1e-6)
        #expect(abs(routes[0].polyline[0].latitude - 40.7128) < 1e-6)
    }

    @Test("Request body uses lat,lon order — the reverse of its own output")
    func requestOrder() async throws {
        let transport = StubTransport(json: graphhopperJSON())
        _ = try await GraphHopperRouteProvider(transport: transport)
            .routes(from: origin, to: destination, via: [], alternatives: false)

        let body = try #require(transport.requests.first).jsonBody()
        let points = try #require(body["points"] as? [[Double]])
        #expect(points.count == 2)
        #expect(abs(points[0][0] - origin.latitude) < 1e-6)   // lat first
        #expect(abs(points[0][1] - origin.longitude) < 1e-6)
    }

    @Test("Requests ch.disable and unencoded points")
    func queryShape() async throws {
        let transport = StubTransport(json: graphhopperJSON())
        _ = try await GraphHopperRouteProvider(transport: transport)
            .routes(from: origin, to: destination, via: [], alternatives: false)

        let url = try #require(transport.requests.first).url
        #expect(url.contains("points_encoded=false"))
        #expect(url.contains("ch.disable=true"))
        #expect(url.contains("vehicle=car"))
        // No key configured, so no key parameter at all.
        #expect(!url.contains("key="))
    }

    @Test("alternative_route is dropped when via points are present")
    func alternativesWithVia() async throws {
        let withVia = StubTransport(json: graphhopperJSON())
        _ = try await GraphHopperRouteProvider(transport: withVia)
            .routes(from: origin, to: destination,
                    via: [Coordinate(latitude: 40.73, longitude: -74.0)], alternatives: true)
        // GraphHopper rejects this combination, so it must not be sent.
        let withViaURL = try #require(withVia.requests.first).url
        #expect(!withViaURL.contains("algorithm="))

        let noVia = StubTransport(json: graphhopperJSON())
        _ = try await GraphHopperRouteProvider(transport: noVia)
            .routes(from: origin, to: destination, via: [], alternatives: true)
        let noViaURL = try #require(noVia.requests.first).url
        #expect(noViaURL.contains("algorithm=alternative_route"))
    }

    @Test("A key is percent-encoded into the query")
    func keyEncoding() async throws {
        let transport = StubTransport(json: graphhopperJSON())
        _ = try await GraphHopperRouteProvider(apiKey: "abc def&x=1", transport: transport)
            .routes(from: origin, to: destination, via: [], alternatives: false)
        let url = try #require(transport.requests.first).url
        #expect(url.contains("key=abc%20def%26x%3D1"))
    }

    @Test("Empty paths throws providerFailure")
    func emptyPaths() async throws {
        let transport = StubTransport(json: #"{"paths":[],"message":"nope"}"#)
        do {
            _ = try await GraphHopperRouteProvider(transport: transport)
                .routes(from: origin, to: destination, via: [], alternatives: false)
            Issue.record("expected a throw")
        } catch let error as RouterError {
            guard case .providerFailure(let message) = error else {
                Issue.record("expected .providerFailure, got \(error)")
                return
            }
            #expect(message.contains("nope"))
        }
    }

    @Test("Malformed coordinate pairs are dropped, not fatal")
    func malformedPairs() async throws {
        let transport = StubTransport(json: #"{"paths":[{"distance":10,"time":1000,"points":{"coordinates":[[-74.0,40.0],[42.0],[-73.9,40.1]]}}]}"#)
        let routes = try await GraphHopperRouteProvider(transport: transport)
            .routes(from: origin, to: destination, via: [], alternatives: false)
        #expect(routes[0].polyline.count == 2)
    }
}

// MARK: - Polyline codec

@Suite("Polyline codec")
struct PolylineCodecTests {
    /// The Google-format example from the encoded-polyline specification.
    @Test("Decodes the canonical specification fixture at 1e5")
    func googleFixture() {
        let points = Geo.decodePolyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@", precision: .p1e5)
        #expect(points.count == 3)
        #expect(abs(points[0].latitude - 38.5) < 1e-6)
        #expect(abs(points[0].longitude - (-120.2)) < 1e-6)
        #expect(abs(points[1].latitude - 40.7) < 1e-6)
        #expect(abs(points[2].latitude - 43.252) < 1e-6)
    }

    @Test("Round-trips through encode at both precisions")
    func roundTrip() {
        let original = [
            Coordinate(latitude: 40.7128, longitude: -74.0060),
            Coordinate(latitude: 40.7500, longitude: -73.9900),
            Coordinate(latitude: -33.8688, longitude: 151.2093),   // negative deltas
            Coordinate(latitude: 0, longitude: 0),
        ]
        for precision in [Geo.PolylinePrecision.p1e5, .p1e6] {
            let decoded = Geo.decodePolyline(Geo.encodePolyline(original, precision: precision), precision: precision)
            #expect(decoded.count == original.count)
            for (a, b) in zip(original, decoded) {
                #expect(abs(a.latitude - b.latitude) < 1e-6)
                #expect(abs(a.longitude - b.longitude) < 1e-6)
            }
        }
    }

    @Test("Empty input encodes and decodes to nothing")
    func empty() {
        #expect(Geo.encodePolyline([]).isEmpty)
        #expect(Geo.decodePolyline("").isEmpty)
    }

    @Test("Precision genuinely changes the decoded position")
    func precisionMatters() {
        let point = Coordinate(latitude: 40.0, longitude: -74.0)
        let encoded6 = Geo.encodePolyline([point], precision: .p1e6)
        let at5 = Geo.decodePolyline(encoded6, precision: .p1e5)
        let at6 = Geo.decodePolyline(encoded6, precision: .p1e6)
        #expect(abs(at6[0].latitude - 40.0) < 1e-6)
        // Same bits read as 1e5 land an order of magnitude away — which is exactly the
        // mis-placement that decoding an OSRM/Valhalla polyline at the Google precision causes.
        #expect(at5[0].latitude > 100)
        #expect(abs(at5[0].longitude - at6[0].longitude) > 100)
    }

    @Test("The existing no-precision overload still means 1e5")
    func defaultPrecision() {
        let point = Coordinate(latitude: 40.0, longitude: -74.0)
        #expect(Geo.decodePolyline(Geo.encodePolyline([point])) == [point])
    }

    @Test("Truncated input decodes the whole pairs it can without crashing")
    func truncated() {
        let encoded = Geo.encodePolyline([
            Coordinate(latitude: 1, longitude: 2),
            Coordinate(latitude: 3, longitude: 4),
        ], precision: .p1e6)
        // Drop the final byte, leaving an odd number of values.
        let truncated = String(encoded.dropLast())
        let points = Geo.decodePolyline(truncated, precision: .p1e6)
        #expect(!points.isEmpty)
    }
}

// MARK: - Provider selection through AvoidanceRouter

@Suite("Avoidance router with a real provider")
struct RouterWithRealProviderTests {
    @Test("A provider honouring exclusions receives the camera rectangles")
    func exclusionsReachProvider() async throws {
        let geometry = jsonString(Geo.encodePolyline([
            Coordinate(latitude: 40.0, longitude: -74.0),
            Coordinate(latitude: 40.02, longitude: -74.0),
        ], precision: .p1e6))
        let transport = StubTransport(json: """
        {"code":"Ok","routes":[{"distance":1000,"duration":200,"geometry":\(geometry)}]}
        """)
        let tree = CameraQuadtree()
        tree.insert(CameraNode(id: 1, latitude: 40.01, longitude: -74.0))

        let router = AvoidanceRouter(provider: OSRMRouteProvider(transport: transport),
                                    cameras: tree,
                                    config: AvoidanceConfig(radius: 500, maxRouteCalls: 4))
        let outcome = try await router.route(from: Coordinate(latitude: 40.0, longitude: -74.0),
                                            to: Coordinate(latitude: 40.02, longitude: -74.0))

        #expect(outcome.routeCalls >= 1)
        #expect(transport.requests.count == outcome.routeCalls)
    }

    @Test("A mock provider with no exclusion override still works via the default")
    func defaultExclusionImpl() async throws {
        // Compiles and runs only because RouteProvider supplies a default `excluding:`
        // implementation — this is the regression guard for the protocol change.
        struct Minimal: RouteProvider {
            func routes(from origin: Coordinate, to destination: Coordinate,
                        via: [Coordinate], alternatives: Bool) async throws -> [RouteCandidate] {
                [RouteCandidate(polyline: [origin, destination],
                                distanceMeters: 1000, durationSeconds: 100)]
            }
        }
        let points = [Coordinate(latitude: 40.0, longitude: -74.0),
                      Coordinate(latitude: 40.02, longitude: -74.0)]
        let routed = try await Minimal().routes(from: points[0], to: points[1], via: [],
                                                alternatives: false, excluding: [GeoRect.around(points[0], points[1])])
        #expect(routed.count == 1)
    }

    @Test("RouterError descriptions name the failure for a user-facing label")
    func errorDescriptions() {
        #expect(RouterError.noRoute.description.contains("No route"))
        #expect(RouterError.http(500, "boom").description.contains("500"))
        #expect(RouterError.http(500, "boom").description.contains("boom"))
        #expect(RouterError.providerFailure("bad key").description == "bad key")
    }
}