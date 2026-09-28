import Foundation

public enum RouteExposureRisk: String, Sendable {
    case low
    case medium
    case high
}

public struct RouteExposureStatus: Sendable {
    public let totalDistanceMeters: Double
    public let remainingDistanceMeters: Double
    public let cameraHits: [CameraHit]
    public let remainingPercent: Double
    public let risk: RouteExposureRisk
    public let alertCount: Int
    public let message: String

    public static func summary(totalDistanceMeters: Double,
                               remainingDistanceMeters: Double,
                               cameraHits: [CameraHit]) -> RouteExposureStatus {
        let total = max(totalDistanceMeters, 1.0)
        let remaining = max(0.0, remainingDistanceMeters)
        let percent = (remaining / total) * 100.0
        let roundedPercent = (percent * 10_000_000_000.0).rounded() / 10_000_000_000.0

        let alertCount = cameraHits.count
        let risk: RouteExposureRisk
        if alertCount >= 3 || remaining <= total * 0.2 {
            risk = .high
        } else if alertCount >= 1 || remaining <= total * 0.4 {
            risk = .medium
        } else {
            risk = .low
        }

        let message: String
        switch risk {
        case .low:
            message = "Route exposure is low: no major camera pressure detected."
        case .medium:
            message = "Route exposure is medium: camera risk is elevated but manageable."
        case .high:
            message = "Route exposure is high: multiple camera hits remain and detour guidance is recommended."
        }

        return RouteExposureStatus(
            totalDistanceMeters: total,
            remainingDistanceMeters: remaining,
            cameraHits: cameraHits,
            remainingPercent: roundedPercent,
            risk: risk,
            alertCount: alertCount,
            message: message
        )
    }
}
