import Foundation

public extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}

/// Small geodesy toolkit. Distances in meters, bearings in degrees clockwise from north.
/// Ignores antimeridian wrapping (irrelevant for road navigation).
public enum Geo {
    public static let earthRadius = 6_371_008.8
    public static let metersPerDegree = earthRadius * .pi / 180

    public static func haversine(_ a: Coordinate, _ b: Coordinate) -> Double {
        let p1 = a.latitude.radians, p2 = b.latitude.radians
        let dp = p2 - p1, dl = (b.longitude - a.longitude).radians
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadius * asin(min(1, h.squareRoot()))
    }

    public static func bearing(_ a: Coordinate, _ b: Coordinate) -> Double {
        let p1 = a.latitude.radians, p2 = b.latitude.radians
        let dl = (b.longitude - a.longitude).radians
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (atan2(y, x).degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    public static func destination(from a: Coordinate, bearing: Double, meters: Double) -> Coordinate {
        let d = meters / earthRadius, brg = bearing.radians
        let p1 = a.latitude.radians, l1 = a.longitude.radians
        let p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(brg))
        let l2 = l1 + atan2(sin(brg) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
        let lon = (l2.degrees + 540).truncatingRemainder(dividingBy: 360) - 180
        return Coordinate(latitude: p2.degrees, longitude: lon)
    }

    /// Distance from point `p` to segment `a`–`b`, and the fraction `t` (0...1) along the segment of the closest point.
    /// Uses a local flat projection centered on `p`, which is accurate to well under a meter at these ranges.
    public static func distance(from p: Coordinate,
                                toSegment a: Coordinate,
                                _ b: Coordinate) -> (meters: Double, t: Double) {
        let k = cos(p.latitude.radians) * metersPerDegree
        let ax = (a.longitude - p.longitude) * k, ay = (a.latitude - p.latitude) * metersPerDegree
        let bx = (b.longitude - p.longitude) * k, by = (b.latitude - p.latitude) * metersPerDegree
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / len2))
        let cx = ax + t * dx, cy = ay + t * dy
        return ((cx * cx + cy * cy).squareRoot(), t)
    }

    /// Smallest absolute difference between two bearings, 0...180.
    public static func angleDifference(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    /// Decimal places encoded in a polyline string.
    ///
    /// Google and Mapbox emit precision 1e5; OSRM, Valhalla and GraphHopper emit 1e6
    /// (`polyline6`). Decoding with the wrong precision puts every point in the wrong place
    /// by up to ~11 m, which is enough to put a route on the wrong street.
    public enum PolylinePrecision: Int, Sendable {
        case p1e5 = 5
        case p1e6 = 6
    }

    /// Decodes an encoded polyline. Defaults to Google's 1e5 format.
    public static func decodePolyline(_ encoded: String) -> [Coordinate] {
        decodePolyline(encoded, precision: .p1e5)
    }

    /// Decodes an encoded polyline at the given precision.
    public static func decodePolyline(_ encoded: String, precision: PolylinePrecision) -> [Coordinate] {
        let bytes = Array(encoded.utf8)
        let scale = Double(pow(10.0, Double(precision.rawValue)))
        var i = 0, lat = 0, lon = 0
        var out: [Coordinate] = []

        func nextValue() -> Int? {
            var result = 0, shift = 0
            while i < bytes.count {
                let b = Int(bytes[i]) - 63
                i += 1
                result |= (b & 0x1f) << shift
                shift += 5
                if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : (result >> 1) }
            }
            return nil
        }

        while i < bytes.count {
            guard let dlat = nextValue(), let dlon = nextValue() else { break }
            lat += dlat
            lon += dlon
            out.append(Coordinate(latitude: Double(lat) / scale, longitude: Double(lon) / scale))
        }
        return out
    }

    /// Encodes a polyline at the given precision — the inverse of `decodePolyline(_:precision:)`.
    /// Used to hand a route to an API that wants polyline6, and by tests.
    public static func encodePolyline(_ points: [Coordinate], precision: PolylinePrecision = .p1e5) -> String {
        let scale = pow(10.0, Double(precision.rawValue))
        var out: [UInt8] = []
        var lastLat = 0, lastLon = 0
        for p in points {
            let lat = Int((p.latitude * scale).rounded())
            let lon = Int((p.longitude * scale).rounded())
            out.append(contentsOf: encodeValue(lat - lastLat))
            out.append(contentsOf: encodeValue(lon - lastLon))
            lastLat = lat
            lastLon = lon
        }
        // Every byte emitted above is < 0x80, so the bytes are already a valid UTF-8 sequence.
        return String(decoding: out, as: UTF8.self)
    }

    /// Encodes one signed delta into 5-bit groups, offset into printable ASCII.
///
/// Both halves of that offset are load-bearing and must agree exactly with `nextValue`, which
/// subtracts 63 and stops at the first group below 0x20:
///
///   * continuation groups are `(0x20 | chunk) + 63` → bytes 95…126, which read back as
///     32…63, i.e. always "keep going". The 0x20 bit is what guarantees that; a group whose low
///     five bits happen to be zero must still not look like a terminator.
///   * the final group is `chunk + 63` with no 0x20 bit → bytes 63…94, which read back below
///     0x20 and therefore terminate the value.
///
/// Note the final byte can be 92 (backslash), so this output is *not* guaranteed to be safe to
/// paste into a JSON string literal without escaping. That is inherent to the format, not a
/// defect here; callers embedding a polyline in JSON must escape it like any other string.
private static func encodeValue(_ value: Int) -> [UInt8] {
        var v = value < 0 ? ~(value << 1) : (value << 1)
        var out: [UInt8] = []
        while v >= 0x20 {
            out.append(UInt8(truncatingIfNeeded: (0x20 | (v & 0x1f)) + 63))
            v >>= 5
        }
        out.append(UInt8(truncatingIfNeeded: v + 63))
        return out
    }
}

/// A polyline with cumulative distances, so callers can talk in "meters along the route".
public struct RoutePath: Sendable {
    public let points: [Coordinate]
    public let cumulative: [Double]          // cumulative[i] = meters from points[0] to points[i]
    public var length: Double { cumulative.last ?? 0 }

    public init(_ raw: [Coordinate]) {
        var pts: [Coordinate] = []
        var cum: [Double] = []
        var total = 0.0
        for p in raw {
            if let last = pts.last {
                let d = Geo.haversine(last, p)
                if d < 0.5 { continue }               // drop duplicate vertices (they break bearings)
                total += d
            }
            pts.append(p)
            cum.append(total)
        }
        points = pts
        cumulative = cum
    }

    /// Meters along the path of the point on the path closest to `p`.
    public func along(_ p: Coordinate) -> Double {
        guard points.count > 1 else { return 0 }
        var best = (meters: Double.infinity, s: 0.0)
        for i in 0..<(points.count - 1) {
            let r = Geo.distance(from: p, toSegment: points[i], points[i + 1])
            if r.meters < best.meters {
                best = (r.meters, cumulative[i] + r.t * (cumulative[i + 1] - cumulative[i]))
            }
        }
        return best.s
    }

    /// Coordinate and bearing at `s` meters along the path. `hint` is a segment cursor that makes
    /// repeated (mostly monotonic) sampling O(1) — pass the same variable each call.
    public func sample(at s: Double, hint: inout Int) -> (coordinate: Coordinate, bearing: Double) {
        guard points.count > 1 else { return (points.first ?? Coordinate(latitude: 0, longitude: 0), 0) }
        let s = max(0, min(length, s))
        hint = min(max(hint, 0), points.count - 2)
        while hint < points.count - 2 && cumulative[hint + 1] < s { hint += 1 }
        while hint > 0 && cumulative[hint] > s { hint -= 1 }
        let a = points[hint], b = points[hint + 1]
        let seg = cumulative[hint + 1] - cumulative[hint]
        let t = seg > 0 ? (s - cumulative[hint]) / seg : 0
        let c = Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                           longitude: a.longitude + (b.longitude - a.longitude) * t)
        return (c, Geo.bearing(a, b))
    }
}
