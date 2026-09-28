// MARK: - Portable coordinate type (replaces CLLocationCoordinate2D)

/// Lightweight lat/lon pair that compiles everywhere.
/// On iOS the app can freely convert to/from `CLLocationCoordinate2D`.
public struct Coordinate: Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}
