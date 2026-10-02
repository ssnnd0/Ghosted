// Production `RouteProvider` implementations.
//
// GhostedCore stays free of any networking framework — it must build on Linux and Windows, where
// `URLSession` lives in `FoundationNetworking` or nowhere at all. The HTTP layer is therefore
// abstract: a provider builds an `HTTPRequest`, something else performs it. On iOS the performer is
// `URLSessionTransport` in Sources/Spoofing; in tests it is a canned responder. That is what makes
// every provider below fully unit-testable without a network.
//
// Implemented:
//
//   OSRM         GET  /route/v1/{profile}/{lon,lat;lon,lat;…}   polyline6, no key needed
//   Valhalla     POST /route  (JSON body)                       polyline6, native avoid-polygons
//   GraphHopper  POST /api/1/route (JSON body)                  raw GeoJSON points, key optional
//
// All three sit behind `RouteProvider`, so `AvoidanceRouter` never learns which one is in use.

import Foundation

// MARK: - Transport abstraction

public struct HTTPRequest: Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }

    public var method: Method
    public var url: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: Method, url: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }

    /// Best-effort text for an error body, truncated so a large HTML error page does not end up
    /// inside a UI label.
    public var bodyExcerpt: String {
        let text = String(data: body, encoding: .utf8) ?? "<\(body.count) bytes of non-UTF8 data>"
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }
}

/// Performs an `HTTPRequest`. Implementations must be safe to call from multiple tasks.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

// MARK: - Shared provider plumbing

enum ProviderSupport {
    /// Appends query items, skipping empty values so a missing API key does not become `?key=`
    /// — which some servers treat as a valid-but-wrong key rather than an absent one.
    static func addingQuery(_ items: [(String, String?)], to base: String) -> String {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))
        var pairs: [String] = []
        for (name, value) in items {
            guard let value, !value.isEmpty else { continue }
            pairs.append("\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)")
        }
        guard !pairs.isEmpty else { return base }
        return base + (base.contains("?") ? "&" : "?") + pairs.joined(separator: "&")
    }

    /// Runs a request and throws `RouterError.http` for any non-2xx. `name` only disambiguates
    /// which provider failed when several share a backend.
    static func perform(_ request: HTTPRequest, via transport: HTTPTransport, named name: String) async throws -> Data {
        let response = try await transport.send(request)
        guard response.isSuccess else {
            throw RouterError.http(response.status, "\(name) returned HTTP \(response.status): \(response.bodyExcerpt)")
        }
        return response.body
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, named name: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw RouterError.providerFailure(
                "\(name) returned JSON that does not match the expected shape: \(error)")
        }
    }

    static func encode<T: Encodable>(_ value: T, named name: String) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw RouterError.providerFailure("\(name) request body could not be encoded: \(error)")
        }
    }

    /// `Double` rounded to 6 decimals (~11 cm). Trims float noise out of request bodies and
    /// request URLs without losing any precision a router could use.
    static func rounded(_ v: Double) -> Double {
        (v * 1_000_000).rounded() / 1_000_000
    }

    /// `"lon,lat"` — the order OSRM uses in path segments and the GeoJSON order.
    static func lonLat(_ c: Coordinate) -> String {
        "\(rounded(c.longitude)),\(rounded(c.latitude))"
    }
}

// MARK: - OSRM

/// OpenStreetRM Routing Machine. Needs no API key, which is why it is the default for a
/// sideloaded build.
///
/// The public demo host (`router.project-osrm.org`) is rate-limited and explicitly not for
/// production traffic — self-host, or point this at your own instance.
public struct OSRMRouteProvider: RouteProvider {
    public var baseURL: String
    /// Must exist on the server: `"car"`, `"bike"`, `"foot"`.
    public var profile: String
    public var transport: HTTPTransport

    public init(baseURL: String = "https://router.project-osrm.org",
                profile: String = "car",
                transport: HTTPTransport) {
        self.baseURL = baseURL
        self.profile = profile
        self.transport = transport
    }

    public func routes(from origin: Coordinate,
                       to destination: Coordinate,
                       via: [Coordinate],
                       alternatives: Bool) async throws -> [RouteCandidate] {
        try await routes(from: origin, to: destination, via: via, alternatives: alternatives, excluding: [])
    }

    public func routes(from origin: Coordinate,
                       to destination: Coordinate,
                       via: [Coordinate],
                       alternatives: Bool,
                       excluding: [GeoRect]) async throws -> [RouteCandidate] {
        // OSRM has no exclude-polygons parameter, so `excluding` is ignored. That is the
        // documented fallback, not an oversight: `AvoidanceRouter` still detours via waypoints.
        let stops = [origin] + via + [destination]
        let path = stops.map(ProviderSupport.lonLat).joined(separator: ";")
        let url = ProviderSupport.addingQuery(
            [("overview", "full"), ("geometries", "polyline6"),
             ("alternatives", alternatives ? "true" : nil), ("steps", "false")],
            to: "\(baseURL)/route/v1/\(profile)/\(path)"
        )

        let data = try await ProviderSupport.perform(
            HTTPRequest(method: .get, url: url), via: transport, named: "OSRM")

        struct Route: Decodable {
            let distance: Double
            let duration: Double
            let geometry: String
        }
        struct Response: Decodable {
            let code: String
            let routes: [Route]?
            let message: String?
        }

        let decoded = try ProviderSupport.decode(Response.self, from: data, named: "OSRM")
        guard decoded.code == "Ok" else {
            throw RouterError.providerFailure("OSRM: \(decoded.message ?? decoded.code)")
        }
        guard let routes = decoded.routes, !routes.isEmpty else { throw RouterError.noRoute }

        return routes.map {
            RouteCandidate(polyline: Geo.decodePolyline($0.geometry, precision: .p1e6),
                           distanceMeters: $0.distance,
                           durationSeconds: $0.duration)
        }
    }
}

// MARK: - Valhalla

/// Valhalla — the FOSS router behind Mapbox Directions.
///
/// The only provider here with **native avoid-polygons**, so it can satisfy the hard-exclusion
/// case in ARCHITECTURE.md instead of approximating it with waypoint detours. Self-hosted; there
/// is no public shared instance.
public struct ValhallaRouteProvider: RouteProvider {
    public var baseURL: String
    /// `"auto"`, `"bicycle"`, `"pedestrian"`, `"truck"`, …
    public var costing: String
    /// Only for a hosted Valhalla (e.g. Mapbox). Self-hosted Valhalla needs none.
    public var apiKey: String?
    public var transport: HTTPTransport

    public init(baseURL: String,
                costing: String = "auto",
                apiKey: String? = nil,
                transport: HTTPTransport) {
        self.baseURL = baseURL
        self.costing = costing
        self.apiKey = apiKey
        self.transport = transport
    }

    public func routes(from origin: Coordinate,
                       to destination: Coordinate,
                       via: [Coordinate],
                       alternatives: Bool) async throws -> [RouteCandidate] {
        try await routes(from: origin, to: destination, via: via, alternatives: alternatives, excluding: [])
    }

    public func routes(from origin: Coordinate,
                       to destination: Coordinate,
                       via: [Coordinate],
                       alternatives: Bool,
                       excluding: [GeoRect]) async throws -> [RouteCandidate] {
        struct Location: Encodable {
            let lat: Double
            let lon: Double
            var type: String?
            var shape: [Location]?

            init(lat: Double, lon: Double) {
                self.lat = ProviderSupport.rounded(lat)
                self.lon = ProviderSupport.rounded(lon)
            }
            init(_ c: Coordinate) { self.init(lat: c.latitude, lon: c.longitude) }
            init(exclude rect: GeoRect) {
                let c = rect.center
                self.init(lat: c.latitude, lon: c.longitude)
                self.type = "exclude"
                self.shape = rect.cornersCounterClockwise.map { Location(lat: $0.latitude, lon: $0.longitude) }
            }
        }
        struct DirectionsOptions: Encodable {
            let units: String
            let language: String
        }
        struct Body: Encodable {
            let locations: [Location]
            let costing: String
            let directions_options: DirectionsOptions
            let alternates: Int?
        }

        // Locations are [lat, lon] objects. An exclude polygon is just another location carrying
        // a `shape` ring; Valhalla accepts them interleaved with the stops.
        var locations = [Location(origin)]
        locations += via.map(Location.init)
        locations.append(Location(destination))
        locations += excluding.map(Location.init(exclude:))

        let body = Body(locations: locations,
                        costing: costing,
                        directions_options: DirectionsOptions(units: "kilometers", language: "en-GB"),
                        alternates: alternatives ? 2 : nil)

        var headers = ["Content-Type": "application/json"]
        if let apiKey, !apiKey.isEmpty { headers["api_key"] = apiKey }

        let data = try await ProviderSupport.perform(
            HTTPRequest(method: .post, url: "\(baseURL)/route",
                        headers: headers,
                        body: try ProviderSupport.encode(body, named: "Valhalla")),
            via: transport, named: "Valhalla")

        struct Status: Decodable {
            let code: Int?
            let status_message: String?
        }
        struct Trip: Decodable {
            struct Summary: Decodable { let length: Double; let time: Double }
            struct Leg: Decodable { let shape: String }
            let summary: Summary
            let legs: [Leg]
            let status: Status?
            let status_message: String?
        }
        struct Response: Decodable {
            let trip: Trip?
            let error: String?
        }

        let decoded = try ProviderSupport.decode(Response.self, from: data, named: "Valhalla")
        if let error = decoded.error { throw RouterError.providerFailure("Valhalla: \(error)") }
        guard let trip = decoded.trip else { throw RouterError.noRoute }
        if let code = trip.status?.code, code != 0 {
            throw RouterError.providerFailure(
                "Valhalla: \(trip.status?.status_message ?? trip.status_message ?? "code \(code)")")
        }
        guard !trip.legs.isEmpty else { throw RouterError.noRoute }

        // Each leg's shape is delta-encoded *from zero*, not from the previous leg's last point.
        // Concatenating the encoded strings before decoding would splice two unrelated delta
        // streams together and produce a route in the wrong place, so decode leg by leg.
        // Consecutive legs repeat their shared endpoint exactly; drop those duplicates so the
        // simulator does not stutter at each via point.
        var polyline: [Coordinate] = []
        for leg in trip.legs {
            for point in Geo.decodePolyline(leg.shape, precision: .p1e6) where polyline.last != point {
                polyline.append(point)
            }
        }
        guard polyline.count > 1 else { throw RouterError.noRoute }

        return [RouteCandidate(polyline: polyline,
                               distanceMeters: trip.summary.length * 1000,   // units=km
                               durationSeconds: trip.summary.time)]           // already seconds
    }
}

// MARK: - GraphHopper

/// GraphHopper Directions API. The hosted free tier needs a key; self-hosted can omit it.
public struct GraphHopperRouteProvider: RouteProvider {
    public var baseURL: String
    public var apiKey: String?
    /// `"car"`, `"bike"`, `"foot"`, …
    public var vehicle: String
    public var transport: HTTPTransport

    public init(baseURL: String = "https://api.graphhopper.com",
                apiKey: String? = nil,
                vehicle: String = "car",
                transport: HTTPTransport) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.vehicle = vehicle
        self.transport = transport
    }

    public func routes(from origin: Coordinate,
                       to destination: Coordinate,
                       via: [Coordinate],
                       alternatives: Bool) async throws -> [RouteCandidate] {
        try await routes(from: origin, to: destination, via: via, alternatives: alternatives, excluding: [])
    }

    public func routes(from origin: Coordinate,
                       to destination: Coordinate,
                       via: [Coordinate],
                       alternatives: Bool,
                       excluding: [GeoRect]) async throws -> [RouteCandidate] {
        // GraphHopper has no polygon exclusion. `ch.disable=true` plus a flexible POST is what
        // makes intermediate waypoints work on a non-matrix profile.
        struct Body: Encodable {
            // GraphHopper's `points` order is [lat, lon] — the opposite of its own GeoJSON output.
            let points: [[Double]]
        }

        let stops = [origin] + via + [destination]
        let body = Body(points: stops.map { [ProviderSupport.rounded($0.latitude), ProviderSupport.rounded($0.longitude)] })

        // `alternative_route` is only honoured with no intermediate waypoints; GraphHopper
        // rejects the combination, so asking when `via` is populated is worse than not asking.
        let url = ProviderSupport.addingQuery(
            [("points_encoded", "false"), ("ch.disable", "true"),
             ("vehicle", vehicle), ("key", apiKey),
             ("algorithm", (alternatives && via.isEmpty) ? "alternative_route" : nil)],
            to: "\(baseURL)/api/1/route")

        let data = try await ProviderSupport.perform(
            HTTPRequest(method: .post, url: url,
                        headers: ["Content-Type": "application/json"],
                        body: try ProviderSupport.encode(body, named: "GraphHopper")),
            via: transport, named: "GraphHopper")

        struct Path: Decodable {
            struct Points: Decodable {
                /// GeoJSON order: [lon, lat].
                let coordinates: [[Double]]
            }
            let distance: Double
            /// Milliseconds.
            let time: Int
            let points: Points
        }
        struct Response: Decodable {
            let paths: [Path]?
            let message: String?
        }

        let decoded = try ProviderSupport.decode(Response.self, from: data, named: "GraphHopper")
        guard let paths = decoded.paths, !paths.isEmpty else {
            throw RouterError.providerFailure("GraphHopper: \(decoded.message ?? "no paths in response")")
        }

        return paths.map { path in
            let polyline = path.points.coordinates.compactMap { pair -> Coordinate? in
                guard pair.count >= 2 else { return nil }
                return Coordinate(latitude: pair[1], longitude: pair[0])
            }
            return RouteCandidate(polyline: polyline,
                                  distanceMeters: path.distance,
                                  durationSeconds: Double(path.time) / 1000)
        }
    }
}

// MARK: - GeoRect polygon support (used by Valhalla's avoid-polygons)

extension GeoRect {
    /// The rectangle's centre. Valhalla anchors an excluded polygon on any vertex of its ring, but
    /// the centre is the least surprising value to report and keeps the request deterministic.
    var center: Coordinate {
        Coordinate(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
    }

    /// The rectangle's corners in counter-clockwise order, with the first corner repeated to close
    /// the ring — Valhalla requires the ring's last vertex to equal its first.
    var cornersCounterClockwise: [Coordinate] {
        [
            Coordinate(latitude: minLat, longitude: minLon),
            Coordinate(latitude: minLat, longitude: maxLon),
            Coordinate(latitude: maxLat, longitude: maxLon),
            Coordinate(latitude: maxLat, longitude: minLon),
            Coordinate(latitude: minLat, longitude: minLon),
        ]
    }
}