// Composition root for the on-device spoofing stack. iOS-only.
//
// The classes it wires together live in `Sources/Spoofing/` and `Sources/Alerts/`,
// which are in no SwiftPM target (they need UIKit / AVFoundation / Network /
// Security). This file is inside the SwiftPM `Ghosted` target's path, so it has to
// compile on macOS too — hence the guard. The Xcode app target compiles it for real.

#if os(iOS)
import Foundation
import GhostedCore

/// Composition root for the on-device spoofing stack.
///
/// The five pieces are separate by design, and this is the only place they meet:
///
/// - `IdeviceBackend`      — native bridge (state only; the idevice FFI is not wired yet)
/// - `LocalSpoofingManager`— lifecycle state machine: pairing → DDI → channel → heartbeat
/// - `RoutePlanner`         — turn start/end points into a camera-aware route
/// - `RouteStreamer`        — 1 Hz clock around the portable `MovementSimulator`
/// - `BackgroundKeepAlive` — holds the background privileges the stream needs
/// - `ProximityAlertManager`— consumes the *simulated* position, never CoreLocation's
///
/// Every simulated position flows through one seam, `LocalSpoofingManager.setLocation(_:)`,
/// which is where recovery is handled. Nothing here talks to the real GPS stack.
@MainActor
final class SpoofingSession {

    enum Phase: Equatable {
        case idle
        case starting
        case ready
        case failed(String)

        var message: String {
            switch self {
            case .idle: return "Idle — no route streaming"
            case .starting: return "Starting: checking loopback, pairing, DDI…"
            case .ready: return "Ready — location channel open, heartbeat live"
            case .failed(let why): return "Blocked: \(why)"
            }
        }
    }

    private(set) var phase: Phase = .idle { didSet { onPhaseChange?(phase) } }

    /// A failed session is retryable; a ready or in-flight one is not.
    var canStart: Bool {
        switch phase {
        case .ready, .starting: return false
        case .idle, .failed: return true
        }
    }

    var onPhaseChange: (@MainActor (Phase) -> Void)?
    var onAlert: (@MainActor (ProximityAlertManager.Alert) -> Void)?
    /// Fired when a route finishes planning, successfully or not.
    var onRoutePlanned: (@MainActor (Result<PlannedRoute, Error>) -> Void)?

    private let manager: LocalSpoofingManager
    private let planner: RoutePlanner
    private let alerts: ProximityAlertManager?
    private var streamer: RouteStreamer?
    private var keepAlive: BackgroundKeepAlive?

    /// The route currently streaming, so the UI can show exposure progress against it.
    private(set) var activeRoute: PlannedRoute?

    /// - Parameter cameras: prebuilt camera index. Pass an empty quadtree when no
    ///   GeoJSON export is present — proximity alerts are then simply inert and route
    ///   planning skips avoidance rather than failing.
    init(cameras: CameraQuadtree, planner: RoutePlanner? = nil) {
        let ddi = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DDI", isDirectory: true)

        manager = LocalSpoofingManager(
            backend: IdeviceBackend(),
            config: LocalSpoofingManager.Config(ddiDirectory: ddi)
        )

        let resolvedPlanner = planner ?? RoutePlanner.makeDefault(cameras: cameras)
        self.planner = resolvedPlanner

        let built: ProximityAlertManager? = cameras.count > 0
            ? ProximityAlertManager(index: cameras)
            : nil
        alerts = built

        // Only safe once every stored property is initialised.
        built?.onAlert = { [weak self] alert in self?.onAlert?(alert) }
    }

    /// Bring the device session up, then arm the background privileges.
    /// Every failure surfaces as `phase = .failed` with an actionable message —
    /// `SpoofError` distinguishes "retry" from "the user must fix something".
    func start() async {
        guard canStart else { return }
        phase = .starting
        do {
            try await manager.start()

            // Must come after the channel opens, and only works because Info.plist
            // declares both background modes — see BackgroundKeepAlive's doc comment.
            let keep = BackgroundKeepAlive()
            try keep.start()
            keepAlive = keep

            phase = .ready
        } catch {
            // Don't leave a heartbeat running behind a failed start.
            await manager.stop()
            phase = .failed(Self.describe(error))
        }
    }

    /// Plan a route from `origin` to `destination` and stream it, avoiding camera geofences.
    ///
    /// This is the entry point the UI should use. It reports through `onRoutePlanned` rather
    /// than throwing, so a routing failure cannot take down a button handler, and it streams
    /// nothing if planning fails — an unroutable request must not leave the device streaming a
    /// stale path.
    func planAndDrive(from origin: Coordinate, to destination: Coordinate) async {
        do {
            let planned = try await planner.plan(from: origin, to: destination)
            guard planned.polyline.count > 1 else { throw RouterError.noRoute }
            onRoutePlanned?(.success(planned))
            drive(route: planned.polyline)
            activeRoute = planned
        } catch {
            // Fail closed: stop whatever was streaming before reporting the failure.
            stopStreaming()
            activeRoute = nil
            onRoutePlanned?(.failure(error))
        }
    }

    /// Stream `route` through the manager at 1 Hz. Replaces any run in progress.
    ///
    /// Prefer `planAndDrive(from:to:)` — this takes an already-planned polyline and therefore
    /// performs no camera avoidance of its own.
    func drive(route: [Coordinate]) {
        streamer?.stop()          // the old Task would otherwise keep streaming

        let manager = self.manager
        let alerts = self.alerts
        let streamer = RouteStreamer { update in
            // The one seam: the manager owns recovery, so a dropped tunnel is repaired here.
            try await manager.setLocation(update.coordinate)
            // The heading is what makes the manager ignore cameras behind you; passing nil
            // here would silently disable that filter.
            await alerts?.update(position: update.coordinate, heading: update.bearing)
        }
        self.streamer = streamer
        streamer.start(polyline: route)
    }

    /// Exposure of the route currently streaming, for a progress readout.
    func exposureStatus() -> RouteExposureStatus? {
        guard let activeRoute else { return nil }
        return planner.previewExposure(of: activeRoute.polyline)
    }

    var isStreaming: Bool { streamer?.isRunning ?? false }

    func pause() { streamer?.pause() }
    func resume() { streamer?.resume() }

    func setMultiplier(_ m: Double) {
        streamer?.setMultiplier(m)
    }

    /// Stops the position stream but leaves the device session open. `stop()` tears everything
    /// down; this is what "end this drive" should call, so the session survives a re-plan.
    func stopStreaming() {
        streamer?.stop()
        streamer = nil
        activeRoute = nil
    }

    /// Always call this when a trip ends — it clears the simulated position so every
    /// other app sees real GPS again.
    func stop() async {
        stopStreaming()
        keepAlive?.stop()
        keepAlive = nil
        await manager.stop()
        phase = .idle
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
#endif
