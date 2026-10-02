// Stub CoreLocation for the type-check harness. NOT part of any shipped product.
// Only the CLLocationManager surface that BackgroundKeepAlive.swift uses is declared.
//
// Swift 6 infers @MainActor isolation for a bare top-level `let`, so the `kCLLocationAccuracy*`
// constants are marked `nonisolated(unsafe)`. That matches the real SDK, where they are Sendable
// CFString/CFNumber constants, and it stops the harness reporting a false actor-isolation error.

@_exported import Foundation

public typealias CLLocationAccuracy = Double
public nonisolated(unsafe) let kCLLocationAccuracyKilometer: CLLocationAccuracy = 1000
public nonisolated(unsafe) let kCLLocationAccuracyBest: CLLocationAccuracy = -1

public enum CLAuthorizationStatus: Int32, Sendable {
    case notDetermined = 0
    case restricted = 1
    case denied = 2
    case authorizedAlways = 3
    case authorizedWhenInUse = 4
}

open class CLLocation: NSObject {}

open class CLLocationManager: NSObject {
    weak open var delegate: (any CLLocationManagerDelegate)?
    open var desiredAccuracy: CLLocationAccuracy = 0
    open var distanceFilter: CLLocationAccuracy = 0
    open var pausesLocationUpdatesAutomatically: Bool = true
    open var allowsBackgroundLocationUpdates: Bool = false
    open var showsBackgroundLocationIndicator: Bool = false
    open var authorizationStatus: CLAuthorizationStatus { .notDetermined }
    open func requestWhenInUseAuthorization() {}
    open func requestAlwaysAuthorization() {}
    open func startUpdatingLocation() {}
    open func stopUpdatingLocation() {}
}

public protocol CLLocationManagerDelegate: NSObjectProtocol {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager)
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation])
}
