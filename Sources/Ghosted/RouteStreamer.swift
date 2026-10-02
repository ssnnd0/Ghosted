// 1 Hz driver for the portable `MovementSimulator`. iOS-only.
//
// This file sits inside the SwiftPM `Ghosted` target's path, so it must compile on
// macOS as well — hence the guard. The Xcode app target compiles it for real.

#if os(iOS)
import Foundation
import GhostedCore

/// 1 Hz driver for the portable `MovementSimulator`.
///
/// `GhostedCore.MovementSimulator` is deliberately clock-free — pure state in, one
/// `MovementUpdate` out — so it can be unit-tested on any host. This is the thin
/// iOS-side wrapper that supplies the real clock, the pause/multiplier controls, and
/// the sink every position is pushed through.
///
/// It replaces the earlier `Sources/Spoofing/MovementController` actor, which held a
/// private copy of the same physics and a private copy of `MovementProfile` /
/// `MovementUpdate`, shadowing the tested ones.
@MainActor
final class RouteStreamer {

    private var task: Task<Void, Never>?
    /// Bumped by every `start()` and `stop()`. A run that finishes on its own only clears
    /// `task` if it is still the current generation.
    ///
    /// Without this, `Task.cancel()` is cooperative: a superseded run can still be suspended
    /// inside `sink(...)` when the replacement is installed, and its trailing
    /// `self.task = nil` would null the *new* run's handle. The symptom is nasty — `isRunning`
    /// reports `false` and `stop()` has nothing to cancel, while a live task keeps pushing
    /// positions to the device with no way to shut it down.
    private var generation: UInt64 = 0
    private var paused = false
    private var multiplier: Double = 1.0
    /// Receives every simulated step. The whole `MovementUpdate` rather than just the
    /// coordinate: `bearing` is what lets `ProximityAlertManager` ignore cameras behind you,
    /// and it exists nowhere else in the pipeline.
    private let sink: @Sendable (MovementUpdate) async throws -> Void

    /// - Parameter sink: receives every simulated step. `LocalSpoofingManager.setLocation(_:)`
    ///   is the intended implementation — it is the single seam where recovery happens.
    init(sink: @escaping @Sendable (MovementUpdate) async throws -> Void) {
        self.sink = sink
    }

    var isRunning: Bool { task != nil }

    /// Replace any run in progress. Positions start flowing within one second.
    func start(polyline: [Coordinate], profile: MovementProfile = .init()) {
        stop()
        guard polyline.count > 1 else { return }

        generation &+= 1
        let run = generation
        let path = RoutePath(polyline)
        let sink = self.sink
        // Inherits MainActor isolation, so the pause/multiplier controls are readable here.
        task = Task {
            var sim = MovementSimulator(path: path, profile: profile)
            let clock = ContinuousClock()
            var failures = 0

            while !Task.isCancelled {
                try? await clock.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                if paused { continue }

                let update = sim.step(dt: self.multiplier)
                if update.finished {
                    // Push the final position before tearing down, otherwise the device is
                    // left reporting wherever the penultimate tick put it.
                    try? await sink(update)
                    break
                }
                do {
                    try await sink(update)
                    failures = 0
                } catch {
                    // The manager already attempts recovery; a long run of failures means
                    // the session is gone, so stop burning battery.
                    failures += 1
                    if failures >= 10 { break }
                }
            }
            // Only clear our own handle: a newer run may already own `task`.
            if run == self.generation { self.task = nil }
        }
    }

    func pause() { paused = true }
    func resume() { paused = false }
    func setMultiplier(_ m: Double) { multiplier = max(0.1, min(m, 50)) }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}
#endif
