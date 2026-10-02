import Foundation

public struct CameraNode: Hashable, Sendable {
    public let id: Int64
    public let latitude: Double
    public let longitude: Double
    /// Facing direction in degrees if the source data has it (ALPRs are directional). Optional.
    public let direction: Double?
    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }

    public init(id: Int64, latitude: Double, longitude: Double, direction: Double? = nil) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.direction = direction
    }
}

public struct GeoRect: Sendable {
    public var minLat: Double, maxLat: Double, minLon: Double, maxLon: Double

    public init(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        self.minLat = minLat
        self.maxLat = maxLat
        self.minLon = minLon
        self.maxLon = maxLon
    }

    public static func around(_ a: Coordinate, _ b: Coordinate) -> GeoRect {
        GeoRect(minLat: min(a.latitude, b.latitude), maxLat: max(a.latitude, b.latitude),
                minLon: min(a.longitude, b.longitude), maxLon: max(a.longitude, b.longitude))
    }

    public func contains(lat: Double, lon: Double) -> Bool {
        lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
    }

    public func intersects(_ o: GeoRect) -> Bool {
        !(o.minLat > maxLat || o.maxLat < minLat || o.minLon > maxLon || o.maxLon < minLon)
    }

    /// Grows the rect by `m` meters on every side (conservative in longitude at high latitudes).
    public func expanded(meters m: Double) -> GeoRect {
        let dLat = m / Geo.metersPerDegree
        let worstLat = max(abs(minLat), abs(maxLat))
        let dLon = m / (Geo.metersPerDegree * max(0.01, cos(worstLat.radians)))
        return GeoRect(minLat: minLat - dLat, maxLat: maxLat + dLat, minLon: minLon - dLon, maxLon: maxLon + dLon)
    }
}

/// Point quadtree. Build once, then treat as read-only (safe to query from any thread).
/// Even 100k cameras is only a few MB here — the OOM risk is in *rendering* them as map markers,
/// not in indexing them. See ARCHITECTURE.md → "Map layer".
public final class CameraQuadtree: @unchecked Sendable {
    private final class Node {
        let rect: GeoRect
        let depth: Int
        var items: [CameraNode] = []
        var children: [Node] = []
        var isLeaf: Bool { children.isEmpty }
        init(rect: GeoRect, depth: Int) { self.rect = rect; self.depth = depth }
    }

    private let root: Node
    private let capacity: Int
    private let maxDepth: Int
    public private(set) var count = 0

    public init(capacity: Int = 32, maxDepth: Int = 18) {
        self.capacity = capacity
        self.maxDepth = maxDepth
        root = Node(rect: GeoRect(minLat: -90, maxLat: 90, minLon: -180, maxLon: 180), depth: 0)
    }

    public func insert(_ cam: CameraNode) {
        insert(cam, into: root)
        count += 1
    }

    /// Calls `visit` for every camera inside `rect`.
    public func query(in rect: GeoRect, _ visit: (CameraNode) -> Void) {
        query(rect, root, visit)
    }

    public func query(near p: Coordinate, radius: Double) -> [CameraNode] {
        var out: [CameraNode] = []
        query(in: GeoRect.around(p, p).expanded(meters: radius)) { cam in
            if Geo.haversine(p, cam.coordinate) <= radius { out.append(cam) }
        }
        return out
    }

    /// Every camera in the index, in unspecified order.
    ///
    /// Walked by walking the leaves, so this is O(count) and allocates the whole index — fine
    /// for a browser list or a map render, and deliberately *not* how the routing path reads
    /// the index (that queries a rect or a radius and never materialises everything).
    public func allCameras() -> [CameraNode] {
        var out: [CameraNode] = []
        out.reserveCapacity(count)
        collect(into: &out, root)
        return out
    }

    /// The bounding box of everything inserted, or `nil` for an empty index.
    /// Used to frame the map on the camera data when no route is streaming.
    public var bounds: GeoRect? {
        guard count > 0 else { return nil }
        var r = GeoRect(minLat: .greatestFiniteMagnitude, maxLat: -.greatestFiniteMagnitude,
                        minLon: .greatestFiniteMagnitude, maxLon: -.greatestFiniteMagnitude)
        allCameras().forEach { c in
            r.minLat = min(r.minLat, c.latitude); r.maxLat = max(r.maxLat, c.latitude)
            r.minLon = min(r.minLon, c.longitude); r.maxLon = max(r.maxLon, c.longitude)
        }
        return r
    }

    // MARK: - Internals

    private func childIndex(_ node: Node, _ cam: CameraNode) -> Int {
        let midLat = (node.rect.minLat + node.rect.maxLat) / 2
        let midLon = (node.rect.minLon + node.rect.maxLon) / 2
        return (cam.latitude >= midLat ? 2 : 0) + (cam.longitude >= midLon ? 1 : 0)
    }

    private func insert(_ cam: CameraNode, into node: Node) {
        if !node.isLeaf {
            insert(cam, into: node.children[childIndex(node, cam)])
            return
        }
        node.items.append(cam)
        if node.items.count > capacity && node.depth < maxDepth { subdivide(node) }
    }

    private func subdivide(_ node: Node) {
        let r = node.rect
        let midLat = (r.minLat + r.maxLat) / 2, midLon = (r.minLon + r.maxLon) / 2
        let d = node.depth + 1
        // index = (north ? 2 : 0) + (east ? 1 : 0)
        node.children = [
            Node(rect: GeoRect(minLat: r.minLat, maxLat: midLat, minLon: r.minLon, maxLon: midLon), depth: d),
            Node(rect: GeoRect(minLat: r.minLat, maxLat: midLat, minLon: midLon, maxLon: r.maxLon), depth: d),
            Node(rect: GeoRect(minLat: midLat, maxLat: r.maxLat, minLon: r.minLon, maxLon: midLon), depth: d),
            Node(rect: GeoRect(minLat: midLat, maxLat: r.maxLat, minLon: midLon, maxLon: r.maxLon), depth: d),
        ]
        let moved = node.items
        node.items = []
        for cam in moved { insert(cam, into: node.children[childIndex(node, cam)]) }
    }

    private func collect(into out: inout [CameraNode], _ node: Node) {
        if node.isLeaf {
            out.append(contentsOf: node.items)
        } else {
            for child in node.children { collect(into: &out, child) }
        }
    }

    private func query(_ rect: GeoRect, _ node: Node, _ visit: (CameraNode) -> Void) {
        guard node.rect.intersects(rect) else { return }
        if node.isLeaf {
            for c in node.items where rect.contains(lat: c.latitude, lon: c.longitude) { visit(c) }
        } else {
            for child in node.children { query(rect, child, visit) }
        }
    }
}

// MARK: - GeoJSON ingestion

public enum CameraLoader {
    /// Loads a GeoJSON FeatureCollection of Point features (e.g. an Overpass/DeFlock export).
    /// Reads the whole file into memory — fine up to a few tens of MB. For bigger datasets, prebuild a
    /// SQLite database with an R*Tree virtual table and query by viewport/corridor instead.
    public static func loadGeoJSON(_ url: URL) throws -> CameraQuadtree {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try loadGeoJSON(data: data)
    }

    /// Loads from raw GeoJSON Data (useful for tests without a file).
    public static func loadGeoJSON(data: Data) throws -> CameraQuadtree {
        let collection = try JSONDecoder().decode(FeatureCollection.self, from: data)
        let tree = CameraQuadtree()
        for (i, f) in collection.features.enumerated() {
            guard f.geometry?.type == "Point", let c = f.geometry?.coordinates, c.count >= 2 else { continue }
            tree.insert(CameraNode(id: Int64(i), latitude: c[1], longitude: c[0], direction: f.properties?.direction?.value))
        }
        return tree
    }

    private struct FeatureCollection: Decodable { let features: [Feature] }

    private struct Feature: Decodable {
        let geometry: Geometry?
        let properties: Properties?
    }

    private struct Geometry: Decodable {
        let type: String
        let coordinates: [Double]?
        enum CodingKeys: String, CodingKey { case type, coordinates }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            coordinates = try? c.decode([Double].self, forKey: .coordinates)   // nil for non-Point geometry
        }
    }

    private struct Properties: Decodable { let direction: LooseDouble? }

    /// OSM `direction` can be "90", 90, or "N". Only numeric forms are kept.
    private struct LooseDouble: Decodable {
        let value: Double?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { value = d }
            else if let s = try? c.decode(String.self) { value = Double(s) }
            else { value = nil }
        }
    }
}
