import CoreLocation

extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}

/// Small geodesy toolkit. Distances in meters, bearings in degrees clockwise from north.
/// Ignores antimeridian wrapping (irrelevant for road navigation).
enum Geo {
    static let earthRadius = 6_371_008.8
    static let metersPerDegree = earthRadius * .pi / 180

    static func haversine(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let p1 = a.latitude.radians, p2 = b.latitude.radians
        let dp = p2 - p1, dl = (b.longitude - a.longitude).radians
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadius * asin(min(1, h.squareRoot()))
    }

    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let p1 = a.latitude.radians, p2 = b.latitude.radians
        let dl = (b.longitude - a.longitude).radians
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (atan2(y, x).degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    static func destination(from a: CLLocationCoordinate2D, bearing: Double, meters: Double) -> CLLocationCoordinate2D {
        let d = meters / earthRadius, brg = bearing.radians
        let p1 = a.latitude.radians, l1 = a.longitude.radians
        let p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(brg))
        let l2 = l1 + atan2(sin(brg) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
        let lon = (l2.degrees + 540).truncatingRemainder(dividingBy: 360) - 180
        return CLLocationCoordinate2D(latitude: p2.degrees, longitude: lon)
    }

    /// Distance from point `p` to segment `a`–`b`, and the fraction `t` (0...1) along the segment of the closest point.
    /// Uses a local flat projection centered on `p`, which is accurate to well under a meter at these ranges.
    static func distance(from p: CLLocationCoordinate2D,
                         toSegment a: CLLocationCoordinate2D,
                         _ b: CLLocationCoordinate2D) -> (meters: Double, t: Double) {
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
    static func angleDifference(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    /// Decodes a Google encoded polyline (precision 1e5).
    static func decodePolyline(_ encoded: String) -> [CLLocationCoordinate2D] {
        let bytes = Array(encoded.utf8)
        var i = 0, lat = 0, lon = 0
        var out: [CLLocationCoordinate2D] = []

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
            out.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e5, longitude: Double(lon) / 1e5))
        }
        return out
    }
}

/// A polyline with cumulative distances, so callers can talk in "meters along the route".
struct RoutePath {
    let points: [CLLocationCoordinate2D]
    let cumulative: [Double]          // cumulative[i] = meters from points[0] to points[i]
    var length: Double { cumulative.last ?? 0 }

    init(_ raw: [CLLocationCoordinate2D]) {
        var pts: [CLLocationCoordinate2D] = []
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
    func along(_ p: CLLocationCoordinate2D) -> Double {
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
    func sample(at s: Double, hint: inout Int) -> (coordinate: CLLocationCoordinate2D, bearing: Double) {
        guard points.count > 1 else { return (points.first ?? CLLocationCoordinate2D(), 0) }
        let s = max(0, min(length, s))
        hint = min(max(hint, 0), points.count - 2)
        while hint < points.count - 2 && cumulative[hint + 1] < s { hint += 1 }
        while hint > 0 && cumulative[hint] > s { hint -= 1 }
        let a = points[hint], b = points[hint + 1]
        let seg = cumulative[hint + 1] - cumulative[hint]
        let t = seg > 0 ? (s - cumulative[hint]) / seg : 0
        let c = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                       longitude: a.longitude + (b.longitude - a.longitude) * t)
        return (c, Geo.bearing(a, b))
    }
}
