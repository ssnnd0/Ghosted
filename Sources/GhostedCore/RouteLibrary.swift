// Saved routes: persistence for routes the user planned and wants to drive again.
//
// Portable and Foundation-only on purpose. The interesting parts — the filename slug, the
// JSON round trip, the de-duplication rule, the corruption fallback — are all testable without
// a device, so none of them belong in a view controller.
//
// Storage is one JSON array per file, not a database. A user has tens of saved routes, not
// millions, and a single atomically-replaced file cannot be left half-written.

import Foundation

/// A route the user kept for later.
public struct SavedRoute: Identifiable, Equatable, Sendable, Codable {
    /// `var`, not `let`: replacing a route by name keeps the original identity so a `UITableView`
    /// diff or a selected row stays pointed at the same logical route.
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var origin: Coordinate
    public var destination: Coordinate
    public var polyline: [Coordinate]
    public var distanceMeters: Double
    public var durationSeconds: Double
    /// Cameras this route still passes. Kept so a saved route can warn before it is driven
    /// again — the avoidance may have been based on an older index.
    public var cameraHitIDs: [Int64]
    public var provider: String
    public var notes: String

    public init(id: UUID = UUID(),
                name: String,
                createdAt: Date = Date(),
                origin: Coordinate,
                destination: Coordinate,
                polyline: [Coordinate],
                distanceMeters: Double,
                durationSeconds: Double,
                cameraHitIDs: [Int64] = [],
                provider: String = "",
                notes: String = "") {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.origin = origin
        self.destination = destination
        self.polyline = polyline
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.cameraHitIDs = cameraHitIDs
        self.provider = provider
        self.notes = notes
    }

    /// Builds a saved route from a planner result, so the caller cannot forget a field.
    public init(name: String, planned: PlannedRouteSummary) {
        self.init(name: name,
                  createdAt: Date(),
                  origin: planned.origin,
                  destination: planned.destination,
                  polyline: planned.polyline,
                  distanceMeters: planned.distanceMeters,
                  durationSeconds: planned.durationSeconds,
                  cameraHitIDs: planned.cameraHitIDs,
                  provider: planned.provider)
    }

    public var summary: String {
        "\(Format.distance(distanceMeters)) · ~\(Format.duration(durationSeconds)) · \(Format.count(polyline.count, "point"))"
    }

    public var subtitle: String {
        var parts = ["\(Format.coordinate(origin)) → \(Format.coordinate(destination))"]
        if !provider.isEmpty { parts.append(provider) }
        if !cameraHitIDs.isEmpty {
            parts.append("\(Format.count(cameraHitIDs.count, "camera")) still on route")
        }
        return parts.joined(separator: " · ")
    }

    /// Filename-safe slug. Path separators and `..` are the two things that must never survive:
    /// a name is user-supplied and goes straight into a filename.
    public var fileName: String { Self.slug(name) }

    public static func slug(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        // Filtered by `Character`, not `Unicode.Scalar`: a scalar is a single grapheme cluster
        // member, and some scalars (combining marks) are not `Character`s at all.
        var out = String(raw.filter { allowed.contains($0) })
        if out.contains("-") { out = out.replacingOccurrences(of: "-", with: "") }
        if out.contains("_") { out = out.replacingOccurrences(of: "_", with: "-_") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if out.isEmpty { out = "route" }
        return String(out.prefix(64))
    }
}

/// The subset of a planned route a `SavedRoute` needs. Declared separately so the core library
/// does not depend on the app layer's `PlannedRoute` type.
public struct PlannedRouteSummary: Sendable {
    public var origin: Coordinate
    public var destination: Coordinate
    public var polyline: [Coordinate]
    public var distanceMeters: Double
    public var durationSeconds: Double
    public var cameraHitIDs: [Int64]
    public var provider: String

    public init(origin: Coordinate,
                destination: Coordinate,
                polyline: [Coordinate],
                distanceMeters: Double,
                durationSeconds: Double,
                cameraHitIDs: [Int64] = [],
                provider: String = "") {
        self.origin = origin
        self.destination = destination
        self.polyline = polyline
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.cameraHitIDs = cameraHitIDs
        self.provider = provider
    }
}

public enum RouteLibraryError: Error, Equatable, Sendable, CustomStringConvertible {
    case noRoutes
    case notFound(String)
    case unreadable(String)
    case unwritable(String)

    public var description: String {
        switch self {
        case .noRoutes: return "No saved routes."
        case .notFound(let n): return "No saved route named “\(n)”."
        case .unreadable(let why): return "Could not read the saved routes: \(why)"
        case .unwritable(let why): return "Could not save to the route library: \(why)"
        }
    }
}

/// A directory of saved routes, newest first.
public final class RouteLibrary: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    /// The conventional location: `Documents/Saved Routes`. Shared with the Xcode app target and
    /// the SwiftPM tests, so both agree on where things live.
    public static func documentsDefault(fileManager: FileManager = .default) -> RouteLibrary {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return RouteLibrary(directory: docs.appendingPathComponent("Saved Routes", isDirectory: true))
    }

    public var count: Int { (try? all().count) ?? 0 }

    /// Every saved route, newest first.
    ///
    /// A file that fails to decode is *skipped*, not fatal: one bad route from an older schema
    /// must not make the whole library unreadable and hide every other route. `lastReadWarning`
    /// records that it happened so the UI can say so rather than silently showing fewer routes.
    public func all() throws -> [SavedRoute] {
        try lock.withLock { try readAllLocked() }
    }

    /// The body of `all()`, split out because `NSLock` is **not** recursive: any public method
    /// that both takes the lock and calls another public method deadlocks. Call this, not `all()`,
    /// from inside a `withLock`.
    private func readAllLocked() throws -> [SavedRoute] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw RouteLibraryError.unreadable(error.localizedDescription)
        }
        var out: [SavedRoute] = []
        var skipped = 0
        for name in names where name.hasSuffix(Self.fileExtension) {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { skipped += 1; continue }
            // `SavedRoute.init(from:)` is synthesised, so it cannot clamp; a file written by
            // a future build could carry a 1e9 distance. Normalise rather than trust it.
            let route: SavedRoute
            if let decoded = try? Self.decoder.decode(SavedRoute.self, from: data) {
                route = decoded
            } else if let recovered = Self.recoveredRoute(from: data) {
                route = recovered
            } else {
                skipped += 1
                continue
            }
            var normalized = route
            normalized.normalize()
            out.append(normalized)
        }
        lastReadWarning = skipped > 0
            ? "Skipped \(Format.count(skipped, "saved route")) that could not be read."
            : nil
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    /// Non-throwing accessor for UI code that must render something no matter what.
    public func allOrEmpty() -> [SavedRoute] {
        (try? all()) ?? []
    }

    public func route(named name: String) throws -> SavedRoute? {
        try lock.withLock {
            try readAllLocked().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    /// Saves (or replaces) a route. Returns the stored copy.
    ///
    /// Rejects a route with fewer than two points: streaming one would be a no-op, and saving it
    /// only defers the failure to the moment the user tries to drive it.
    @discardableResult
    public func save(_ route: SavedRoute) throws -> SavedRoute {
        guard route.polyline.count >= 2 else {
            throw RouteLibraryError.unwritable("a route needs at least two points")
        }
        return try lock.withLock {
            try createDirectoryIfNeeded()
            var stored = route
            stored.normalize()

            if let previous = try? readAllLocked().first(where: {
                $0.name.caseInsensitiveCompare(stored.name) == .orderedSame
            }) {
                let target = resolveURL(for: previous)
                stored.id = previous.id
                stored.createdAt = previous.createdAt
                do {
                    try Self.encoder.encode(stored).write(to: target, options: .atomic)
                } catch {
                    throw RouteLibraryError.unwritable(error.localizedDescription)
                }
                return stored
            }

            let target = resolveURL(for: stored)
            if let previous = try? Self.decoder.decode(
                SavedRoute.self, from: (try? Data(contentsOf: target)) ?? Data()
            ) {
                // Keep the original creation date and id when replacing by name, so "replace"
                // is not silently "add a duplicate that sorts first".
                stored.id = previous.id
                stored.createdAt = previous.createdAt
            }
            do {
                try Self.encoder.encode(stored).write(to: target, options: .atomic)
            } catch {
                throw RouteLibraryError.unwritable(error.localizedDescription)
            }
            return stored
        }
    }

    @discardableResult
    public func delete(named name: String) throws -> Bool {
        try lock.withLock {
            guard let target = try readAllLocked()
                .first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            else { return false }
            do {
                try FileManager.default.removeItem(at: url(for: target))
            } catch {
                throw RouteLibraryError.unwritable(error.localizedDescription)
            }
            return true
        }
    }

    public func deleteAll() throws {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            do {
                for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
                where name.hasSuffix(Self.fileExtension) {
                    try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                }
            } catch {
                throw RouteLibraryError.unwritable(error.localizedDescription)
            }
        }
    }

    /// Set by `all()` when files had to be skipped. Read by the UI to surface it.
    public private(set) var lastReadWarning: String?

    /// The filename for `route`.
    ///
    /// The filename is derived from the *name*, because that is what makes save-again replace
    /// rather than accumulate near-duplicates. But two different names can slug to the same
    /// string ("A/B" and "A B" both become "AB"), so a slug already taken by a route with a
    /// different id gets the id appended. Silently overwriting would lose a route the user
    /// believed was saved — the one failure mode a library must not have.
    private func resolveURL(for route: SavedRoute) -> URL {
        let base = SavedRoute.slug(route.name)
        let primary = directory.appendingPathComponent("\(base).\(Self.fileExtension)")
        let disambiguated = directory.appendingPathComponent(
            "\(base)-\(route.id.uuidString.prefix(8)).\(Self.fileExtension)"
        )

        // A route that was disambiguated on a previous save stays at its own file. Check that
        // first, otherwise re-saving it would look like a fresh name and get a *new* file,
        // silently duplicating the route every time the user saves over it.
        if Self.routeID(at: disambiguated) == route.id { return disambiguated }
        // Free, or already ours: replace in place.
        if Self.routeID(at: primary).map({ $0 == route.id }) ?? true { return primary }
        return disambiguated
    }

    private static func routeID(at url: URL) -> UUID? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let route = try? decoder.decode(SavedRoute.self, from: data) {
            return route.id
        }
        return recoveredRoute(from: data)?.id
    }

    private static func recoveredRoute(from data: Data) -> SavedRoute? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        func doubleValue(_ value: Any?) -> Double? {
            if let n = value as? NSNumber { return n.doubleValue }
            if let s = value as? String, let d = Double(s) { return d }
            return nil
        }

        func coordinateValue(_ value: Any?) -> Coordinate? {
            guard let value else { return nil }
            if let dict = value as? [String: Any] {
                guard let lat = doubleValue(dict["latitude"]),
                      let lon = doubleValue(dict["longitude"]) else { return nil }
                return Coordinate(latitude: lat, longitude: lon)
            }
            if let array = value as? [Any], array.count >= 2 {
                guard let lat = doubleValue(array[0]), let lon = doubleValue(array[1]) else { return nil }
                return Coordinate(latitude: lat, longitude: lon)
            }
            return nil
        }

        func coordinateArray(_ value: Any?) -> [Coordinate] {
            guard let items = value as? [Any] else { return [] }
            var out: [Coordinate] = []
            for item in items {
                guard let coord = coordinateValue(item) else { continue }
                out.append(coord)
            }
            return out
        }

        func int64Array(_ value: Any?) -> [Int64] {
            guard let items = value as? [Any] else { return [] }
            var out: [Int64] = []
            for item in items {
                if let n = item as? NSNumber { out.append(n.int64Value) }
                else if let s = item as? String, let v = Int64(s) { out.append(v) }
            }
            return out
        }

        let id = (object["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        let name = (object["name"] as? String) ?? "Untitled route"
        let createdAt: Date
        if let seconds = object["createdAt"] as? NSNumber {
            createdAt = Date(timeIntervalSince1970: seconds.doubleValue)
        } else if let raw = object["createdAt"] as? String {
            let withFractional = ISO8601DateFormatter(); withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractional.date(from: raw) {
                createdAt = date
            } else {
                let basic = ISO8601DateFormatter(); basic.formatOptions = [.withInternetDateTime]
                createdAt = basic.date(from: raw) ?? Date()
            }
        } else {
            createdAt = Date()
        }
        let origin = coordinateValue(object["origin"]) ?? Coordinate(latitude: 0, longitude: 0)
        let destination = coordinateValue(object["destination"]) ?? Coordinate(latitude: 0, longitude: 0)
        let polyline = coordinateArray(object["polyline"])
        let distanceMeters = doubleValue(object["distanceMeters"]) ?? 0
        let durationSeconds = doubleValue(object["durationSeconds"]) ?? 0
        let cameraHitIDs = int64Array(object["cameraHitIDs"])
        let provider = (object["provider"] as? String) ?? ""
        let notes = (object["notes"] as? String) ?? ""

        var route = SavedRoute(id: id, name: name, createdAt: createdAt,
                               origin: origin, destination: destination,
                               polyline: polyline, distanceMeters: distanceMeters,
                               durationSeconds: durationSeconds, cameraHitIDs: cameraHitIDs,
                               provider: provider, notes: notes)
        route.normalize()
        return route
    }

    /// The URL a stored route lives at. Same resolution as `resolveURL`, so `delete` removes the
    /// file the route was actually written to rather than a same-named one it does not own.
    private func url(for route: SavedRoute) -> URL { resolveURL(for: route) }

    private func createDirectoryIfNeeded() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw RouteLibraryError.unwritable(error.localizedDescription)
        }
    }

    static let fileExtension = "ghostedroute"

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let raw = try container.decode(String.self)
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractional.date(from: raw) { return date }
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            if let date = basic.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(raw)")
        }
        return d
    }()
}

extension SavedRoute {
    /// Guards against values that survived a hand-edit or an older/newer schema. Coordinates
    /// out of range would poison every later distance calculation, so drop the polyline rather
    /// than clamp it into a plausible-looking wrong place.
    public mutating func normalize() {
        polyline = polyline.filter { $0.latitude.isFinite && $0.longitude.isFinite }
            .filter { (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) }
        let seconds = createdAt.timeIntervalSince1970 * 1000
        createdAt = Date(timeIntervalSince1970: (seconds.rounded() / 1000))
        if !distanceMeters.isFinite || distanceMeters < 0 || distanceMeters > 1_000_000 {
            distanceMeters = 0
        }
        if !durationSeconds.isFinite || durationSeconds < 0 || durationSeconds > 86_400 * 365 * 10 {
            durationSeconds = 0
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = "Untitled route" }
    }

    public var isDrivable: Bool { polyline.count >= 2 }
}
