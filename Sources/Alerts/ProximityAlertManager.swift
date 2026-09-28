import AVFoundation
import CoreLocation
import UIKit

/// Fires once per camera as you enter its geofence ahead of you, then re-arms after you've moved clear.
/// Feed it the position from `MovementController` (your source of truth), not from CLLocationManager.
@MainActor
final class ProximityAlertManager {
    struct Alert {
        let camera: CameraNode
        let distance: Double
    }

    var onAlert: ((Alert) -> Void)?
    var speaks = true

    private let index: CameraQuadtree
    private let radius: Double
    private var suppressed = Set<Int64>()
    private let synthesizer = AVSpeechSynthesizer()

    init(index: CameraQuadtree, radius: Double = 500) {
        self.index = index
        self.radius = radius
    }

    func update(position: CLLocationCoordinate2D, heading: Double?) {
        let nearby = index.query(near: position, radius: radius * 1.3)
        // Hysteresis: a camera stays suppressed until it falls outside 1.3× radius, so GPS wobble at the
        // boundary can't re-trigger it.
        suppressed.formIntersection(nearby.map(\.id))

        for cam in nearby where !suppressed.contains(cam.id) {
            let d = Geo.haversine(position, cam.coordinate)
            guard d <= radius else { continue }
            // Ignore cameras behind us (more than 80° off our heading).
            if let h = heading, Geo.angleDifference(h, Geo.bearing(position, cam.coordinate)) > 80 { continue }
            suppressed.insert(cam.id)
            fire(Alert(camera: cam, distance: d))
        }
    }

    private func fire(_ alert: Alert) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        if speaks {
            let rounded = max(50, Int((alert.distance / 50).rounded()) * 50)
            synthesizer.speak(AVSpeechUtterance(string: "Camera ahead, \(rounded) meters"))
        }
        onAlert?(alert)                                   // drive the on-screen banner from here
    }
}
