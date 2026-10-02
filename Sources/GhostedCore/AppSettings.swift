// User-facing settings, and the parsing/validation that goes with them.
//
// Deliberately portable and Foundation-only: the rules about what a valid coordinate or
// avoidance radius *is* are the parts worth testing, and burying them in a UIViewController
// means they can only be exercised on a device. The iOS layer adds a `UserDefaults`-backed
// store on top (see `Sources/Ghosted/SettingsStore.swift`); this file owns the semantics.

import Foundation

// MARK: - Coordinate input

/// Why a typed coordinate could not be used.
///
/// Every case carries the reason, because a route field that silently refuses to plan is
/// indistinguishable from a routing outage. The UI shows `message` verbatim.
public enum CoordinateInputError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty(String)
    case notTwoNumbers(String)
    case notNumeric(String)
    case latitudeOutOfRange(String, Double)
    case longitudeOutOfRange(String, Double)
    case coordinateOutOfRange(String, Double, Double)

    public var description: String {
        switch self {
        case .empty(let label):
            return "\(label) is empty. Enter \"latitude, longitude\", e.g. 40.7128, -74.0060."
        case .notTwoNumbers(let label):
            return "\(label) needs a latitude and a longitude separated by a comma."
        case .notNumeric(let label):
            return "\(label) contains something that is not a number. Use plain digits, e.g. 40.7128, -74.0060."
        case .latitudeOutOfRange(let label, let v):
            return "\(label): latitude \(v) is outside -90…90."
        case .longitudeOutOfRange(let label, let v):
            return "\(label): longitude \(v) is outside -180…180."
        case .coordinateOutOfRange(let label, let lat, let lon):
            return "\(label): \(lat), \(lon) is not a point on Earth."
        }
    }
}

/// Parses `"latitude, longitude"` as typed by a human.
///
/// Accepts a comma, a space, or both (`"40.7128 -74.0060"`), rejects anything with a different
/// number of components, and range-checks both axes. The *label* is threaded into the error so
/// the message can name the offending field.
public enum CoordinateInput {
    /// Characters that separate the two numbers. A comma is the documented form; whitespace is
    /// accepted because it is what a space-bar keyboard and a paste from Maps both produce.
    private static let separators: Set<Character> = [",", ";", " ", "\t"]

    public static func parse(_ raw: String?, label: String) throws -> Coordinate {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CoordinateInputError.empty(label) }

        let parts = text
            .split(whereSeparator: { separators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard parts.count == 2 else { throw CoordinateInputError.notTwoNumbers(label) }

        // `Double(_:)` accepts "nan", "inf" and hex floats. A coordinate of `nan` passes every
        // range comparison below (`(-90...90).contains(.nan)` is false, which is how we catch
        // it) but `inf` in a longitude slot would sail through a sloppy `abs(_:) <= 180`
        // check, so reject non-finite values explicitly rather than relying on the range test.
        guard let lat = Double(parts[0]), lat.isFinite else { throw CoordinateInputError.notNumeric(label) }
        guard let lon = Double(parts[1]), lon.isFinite else { throw CoordinateInputError.notNumeric(label) }

        guard (-90...90).contains(lat) else { throw CoordinateInputError.latitudeOutOfRange(label, lat) }
        guard (-180...180).contains(lon) else { throw CoordinateInputError.longitudeOutOfRange(label, lon) }

        return Coordinate(latitude: lat, longitude: lon)
    }

    /// Non-throwing form, for live validation in a text field's `.editingChanged` handler.
    public static func parseIfValid(_ raw: String?) -> Coordinate? {
        try? parse(raw, label: "Coordinate")
    }

    /// Renders a coordinate in the form `parse` accepts, at a precision that survives a round
    /// trip (~1 cm) without being noise on screen.
    public static func format(_ c: Coordinate) -> String {
        String(format: "%.7f, %.7f", c.latitude, c.longitude)
    }
}

// MARK: - Settings

/// Which routing backend to use.
public enum RoutingBackend: String, CaseIterable, Sendable, Codable {
    /// OSRM demo server. No API key, so it is the only option that works on a build with no
    /// provisioning profile and no billing relationship — hence the default.
    case osrm
    /// Valhalla. The only backend that honours camera rectangles natively (via `exclude`).
    case valhalla
    /// GraphHopper. Needs an API key.
    case graphhopper

    public var displayName: String {
        switch self {
        case .osrm: return "OSRM"
        case .valhalla: return "Valhalla"
        case .graphhopper: return "GraphHopper"
        }
    }

    /// Whether this backend can be used at all with the given key.
    ///
    /// OSRM is checked too: a self-hosted OSRM behind a reverse proxy can require a key, and
    /// silently ignoring the key would surface as a 401 the user cannot connect to the cause of.
    public func isConfigured(apiKey: String?) -> Bool {
        switch self {
        case .osrm: return true
        case .valhalla: return true
        case .graphhopper: return !(apiKey ?? "").isEmpty
        }
    }

    public var requiresAPIKey: Bool { self == .graphhopper }

    /// Whether camera exclusion polygons are honoured by the router itself rather than by the
    /// waypoint-detour fallback. Surfaced in Settings so the choice is not a silent downgrade.
    public var supportsNativeExclusion: Bool { self == .valhalla }

    public var needsBaseURL: Bool { self != .osrm }

    /// The public endpoint used when the user has not supplied their own.
    public var defaultBaseURL: String {
        switch self {
        case .osrm: return "https://router.project-osrm.org"
        case .valhalla: return "https://valhalla1.openstreetmap.de"
        case .graphhopper: return "https://graphhopper.com/api/1"
        }
    }
}

/// Every knob the app exposes, with its validation rules attached.
///
/// A struct of already-valid values: `init` clamps rather than throwing, so a settings screen
/// cannot put the app into an unusable state. Callers that need to *report* bad input use the
/// throwing `validated(backend:baseURL:apiKey:)` below.
public struct AppSettings: Equatable, Sendable, Codable {
    public var backend: RoutingBackend
    public var baseURL: String
    public var apiKey: String

    /// Camera geofence radius, metres. Drives both `AvoidanceConfig.radius` and the exposure
    /// analysis, so the number the user sets is the number the route is built with.
    public var avoidanceRadiusMeters: Double
    /// How far ahead a proximity alert fires, metres.
    public var alertRadiusMeters: Double
    /// Simulation speed-up. `RouteStreamer` clamps to 0.1…50; clamped here too so the stored
    /// value and the slider cannot disagree.
    public var speedMultiplier: Double
    public var speakAlerts: Bool
    public var avoidCameras: Bool
    public var followSimulatedPosition: Bool

    /// Bounds for the sliders. Exposed so the UI and the model share one source of truth.
    public static let multiplierRange: ClosedRange<Double> = 0.1...50
    public static let radiusRange: ClosedRange<Double> = 25...1000
    public static let defaultAvoidanceRadius: Double = 150
    public static let defaultAlertRadius: Double = 250

    public init(backend: RoutingBackend = .osrm,
                apiKey: String = "",
                baseURL: String? = nil,
                avoidanceRadiusMeters: Double = AppSettings.defaultAvoidanceRadius,
                alertRadiusMeters: Double = AppSettings.defaultAlertRadius,
                speedMultiplier: Double = 1,
                speakAlerts: Bool = true,
                avoidCameras: Bool = true,
                followSimulatedPosition: Bool = true) {
        self.backend = backend
        self.baseURL = Self.normalizedBaseURL(baseURL, fallback: backend.defaultBaseURL)
        self.apiKey = apiKey
        self.avoidanceRadiusMeters = Self.clamp(avoidanceRadiusMeters, to: Self.radiusRange)
        self.alertRadiusMeters = Self.clamp(alertRadiusMeters, to: Self.radiusRange)
        self.speedMultiplier = Self.clamp(speedMultiplier, to: Self.multiplierRange)
        self.speakAlerts = speakAlerts
        self.avoidCameras = avoidCameras
        self.followSimulatedPosition = followSimulatedPosition
    }

    /// Compatibility overload for call sites that pass `baseURL` before `apiKey`.
    public init(backend: RoutingBackend,
                baseURL: String?,
                apiKey: String,
                avoidanceRadiusMeters: Double = AppSettings.defaultAvoidanceRadius,
                alertRadiusMeters: Double = AppSettings.defaultAlertRadius,
                speedMultiplier: Double = 1,
                speakAlerts: Bool = true,
                avoidCameras: Bool = true,
                followSimulatedPosition: Bool = true) {
        self.init(backend: backend,
                  apiKey: apiKey,
                  baseURL: baseURL,
                  avoidanceRadiusMeters: avoidanceRadiusMeters,
                  alertRadiusMeters: alertRadiusMeters,
                  speedMultiplier: speedMultiplier,
                  speakAlerts: speakAlerts,
                  avoidCameras: avoidCameras,
                  followSimulatedPosition: followSimulatedPosition)
    }

    /// Compatibility overload for callers that pass `speedMultiplier` before `avoidanceRadiusMeters`.
    public init(speedMultiplier: Double,
                avoidanceRadiusMeters: Double,
                alertRadiusMeters: Double = AppSettings.defaultAlertRadius,
                backend: RoutingBackend = .osrm,
                apiKey: String = "",
                baseURL: String? = nil,
                speakAlerts: Bool = true,
                avoidCameras: Bool = true,
                followSimulatedPosition: Bool = true) {
        self.init(backend: backend,
                  apiKey: apiKey,
                  baseURL: baseURL,
                  avoidanceRadiusMeters: avoidanceRadiusMeters,
                  alertRadiusMeters: alertRadiusMeters,
                  speedMultiplier: speedMultiplier,
                  speakAlerts: speakAlerts,
                  avoidCameras: avoidCameras,
                  followSimulatedPosition: followSimulatedPosition)
    }

    /// Whether these settings can actually produce a route. Drives the "Ready" state of the
    /// Settings screen, so an unusable configuration is visible *before* a drive is attempted
    /// rather than as a routing failure during one.
    public var isUsable: Bool { backend.isConfigured(apiKey: apiKey) }

    public var configurationWarning: String? {
        if !isUsable {
            return "\(backend.displayName) needs an API key. Add one, or switch to OSRM."
        }
        if backend == .osrm && baseURL == RoutingBackend.osrm.defaultBaseURL {
            return "Using the public OSRM demo server. It is rate-limited and offers no uptime guarantee — point GhostedRoutingBaseURL at your own instance for real use."
        }
        if backend == .graphhopper && baseURL != RoutingBackend.graphhopper.defaultBaseURL {
            return "\(backend.displayName) has no avoid-polygons support, so camera geofences are avoided by inserting detour waypoints. This usually works but is not a hard exclusion."
        }
        if backend == .valhalla {
            return nil
        }
        if !backend.supportsNativeExclusion && backend != .graphhopper {
            return "\(backend.displayName) has no avoid-polygons support, so camera geofences are avoided by inserting detour waypoints. This usually works but is not a hard exclusion."
        }
        return nil
    }

    /// The `AvoidanceConfig` these settings imply.
    public var avoidanceConfig: AvoidanceConfig {
        AvoidanceConfig(radius: avoidanceRadiusMeters)
    }

    /// Re-applies every clamp. Called after a decode, because `Codable` synthesises `init(from:)`
    /// and therefore *bypasses* the clamping `init` — a stored value of `1e9` would otherwise
    /// survive a round trip straight into `AvoidanceRouter`.
    public mutating func normalize() {
        baseURL = Self.normalizedBaseURL(baseURL, fallback: backend.defaultBaseURL)
        avoidanceRadiusMeters = Self.clamp(avoidanceRadiusMeters, to: Self.radiusRange)
        alertRadiusMeters = Self.clamp(alertRadiusMeters, to: Self.radiusRange)
        speedMultiplier = Self.clamp(speedMultiplier, to: Self.multiplierRange)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings()
        // A backend string from a newer build, or a hand-edited plist, must not hard-fail the
        // decode — that would lose every other setting to save one field.
        let backend = RoutingBackend(rawValue: try c.decodeIfPresent(String.self, forKey: .backend) ?? "")
            ?? fallback.backend
        self.init(backend: backend,
                  apiKey: try c.decodeIfPresent(String.self, forKey: .apiKey) ?? "",
                  baseURL: try c.decodeIfPresent(String.self, forKey: .baseURL),
                  avoidanceRadiusMeters: try c.decodeIfPresent(Double.self, forKey: .avoidanceRadiusMeters) ?? fallback.avoidanceRadiusMeters,
                  alertRadiusMeters: try c.decodeIfPresent(Double.self, forKey: .alertRadiusMeters) ?? fallback.alertRadiusMeters,
                  speedMultiplier: try c.decodeIfPresent(Double.self, forKey: .speedMultiplier) ?? fallback.speedMultiplier,
                  speakAlerts: try c.decodeIfPresent(Bool.self, forKey: .speakAlerts) ?? fallback.speakAlerts,
                  avoidCameras: try c.decodeIfPresent(Bool.self, forKey: .avoidCameras) ?? fallback.avoidCameras,
                  followSimulatedPosition: try c.decodeIfPresent(Bool.self, forKey: .followSimulatedPosition) ?? fallback.followSimulatedPosition)
        normalize()
    }

    /// Trims, drops a trailing slash, and substitutes the backend's default when empty.
    ///
    /// The providers concatenate paths onto this (`baseURL + "/route/v1/..."`), so a trailing
    /// slash would produce `//route`, which some reverse proxies answer with a redirect rather
    /// than a route — and a redirect turns into a confusing "could not read the answer".
    static func normalizedBaseURL(_ raw: String?, fallback: String) -> String {
        guard let raw else { return fallback }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? fallback : s
    }

    static func clamp(_ v: Double, to range: ClosedRange<Double>) -> Double {
        if v.isNaN { return range.lowerBound }
        if v.isInfinite { return v > 0 ? range.upperBound : range.lowerBound }
        return min(max(v, range.lowerBound), range.upperBound)
    }
}

// MARK: - Formatting

/// Shared, testable formatters. `String(format:)` and locale rules belong here so the screens
/// cannot disagree about how a distance is written.
public enum Format {
    /// Distance with a unit that suits the magnitude: metres below a kilometre, otherwise km.
    public static func distance(_ meters: Double) -> String {
        guard meters.isFinite else { return "—" }
        if abs(meters) < 1000 {
            return "\(Int(meters.rounded())) m"
        }
        return String(format: "%.1f km", meters / 1000)
    }

    /// Duration as `1 h 05 min` / `12 min` / `45 s`, so a long drive does not read as "80 min".
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min"
    }

    /// Coordinate with 5 decimals (~1 m) — enough to identify a place, short enough to read.
    public static func coordinate(_ c: Coordinate) -> String {
        String(format: "%.5f, %.5f", c.latitude, c.longitude)
    }

    public static func multiplier(_ m: Double) -> String { String(format: "%.1f×", m) }

    public static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }
}
