import Foundation
import CoreLocation

struct MovementProfile: Sendable {
    var cruiseSpeed = 13.4                     // m/s (~30 mph) when nothing else constrains us
    var maxAccel = 2.0                         // m/s²
    var comfortableDecel = 2.5                 // m/s²
    var stopsPerKm = 0.5                       // random signal/traffic stops (Poisson process)
    var stopDwell: ClosedRange<Double> = 8...40 // seconds stopped
    var turnSpeed = 4.5                        // m/s through sharp turns
    var turnAngleThreshold = 40.0              // degrees of heading change (over ~30 m) that counts as a turn
    var speedNoiseSD = 0.8                     // m/s, stationary std-dev of the speed wobble
    var lateralNoiseSD = 1.5                   // m, stationary std-dev of GPS-like lane wander
    var multiplier = 1.0                       // simulation speed-up: 2.0 = the drive takes half as long
}

struct MovementUpdate: Sendable {
    let coordinate: CLLocationCoordinate2D
    let speed: Double
    let bearing: Double
    let distanceRemaining: Double
    let finished: Bool
}

/// Streams positions along a polyline at 1 Hz wall-clock. iOS derives speed/course from consecutive fixes,
/// so the trick is smoothness: bounded acceleration, braking distance computed from v² = v₀² + 2ad, and
/// low-pass (Ornstein–Uhlenbeck) noise instead of white noise.
actor MovementController {
    private struct RouteEvent { let s: Double; let targetSpeed: Double; let dwell: Double }

    let updates: AsyncStream<MovementUpdate>
    private let updateSink: AsyncStream<MovementUpdate>.Continuation
    private let sink: @Sendable (CLLocationCoordinate2D) async throws -> Void
    private var profile: MovementProfile
    private var task: Task<Void, Never>?
    private var paused = false

    init(profile: MovementProfile = .init(), sink: @escaping @Sendable (CLLocationCoordinate2D) async throws -> Void) {
        self.profile = profile
        self.sink = sink
        let pair = AsyncStream.makeStream(of: MovementUpdate.self)
        updates = pair.stream
        updateSink = pair.continuation
    }

    func start(polyline: [CLLocationCoordinate2D]) {
        task?.cancel()
        let path = RoutePath(polyline)
        task = Task { await self.run(path) }
    }

    func pause() { paused = true }
    func resume() { paused = false }
    func setMultiplier(_ m: Double) { profile.multiplier = max(0.1, min(m, 50)) }
    func stop() { task?.cancel(); task = nil }

    // MARK: - Simulation loop

    private func run(_ path: RoutePath) async {
        guard path.length > 5 else { return }
        var events = makeEvents(path)
        var s = 0.0, v = 0.0, dwellLeft = 0.0
        var speedNoise = 0.0, lateral = 0.0
        var hint = 0, failures = 0
        let theta = 0.5                                        // OU mean-reversion rate (1/s)
        let clock = ContinuousClock()
        var next = clock.now

        while !Task.isCancelled {
            next += .seconds(1)
            try? await clock.sleep(until: next)
            if Task.isCancelled { break }
            if paused { continue }

            // Advance `multiplier` seconds of simulated time per real second, in ≤0.5 s sub-steps.
            let simSeconds = profile.multiplier
            let steps = max(1, Int((simSeconds / 0.5).rounded(.up)))
            let dt = simSeconds / Double(steps)

            for _ in 0..<steps {
                speedNoise += -theta * speedNoise * dt
                            + profile.speedNoiseSD * (2 * theta).squareRoot() * dt.squareRoot() * gaussian()

                var target = max(2, profile.cruiseSpeed + speedNoise)
                if let e = events.first {
                    // Fastest speed from which we can still reach e.targetSpeed at e.s with comfortable braking.
                    let room = max(0, e.s - s - 2)
                    target = min(target, (e.targetSpeed * e.targetSpeed + 2 * profile.comfortableDecel * room).squareRoot())
                }
                let dv = target - v
                v += max(-profile.comfortableDecel * 1.5 * dt, min(profile.maxAccel * dt, dv))
                v = max(0, v)

                if dwellLeft > 0 {
                    dwellLeft -= dt
                    v = 0
                } else {
                    s += v * dt
                }

                if let e = events.first {
                    if e.targetSpeed == 0 {
                        if (e.s - s <= 3 && v < 0.6) || s > e.s + 5 {
                            dwellLeft = e.dwell
                            v = 0
                            events.removeFirst()
                        }
                    } else if s >= e.s {
                        events.removeFirst()
                    }
                }
                if path.length - s < 3 { break }
            }

            let (base, bearing) = path.sample(at: s, hint: &hint)
            lateral += -theta * lateral * simSeconds
                     + profile.lateralNoiseSD * (2 * theta).squareRoot() * simSeconds.squareRoot() * gaussian()
            let wander = v < 0.3 ? 0.25 : 1.0                  // parked cars drift less than moving ones
            let point = Geo.destination(from: base, bearing: bearing + 90, meters: lateral * wander)

            do {
                try await sink(point)
                failures = 0
            } catch {
                failures += 1
                if failures >= 10 { break }                     // manager already tried to recover; give up
            }
            // The sink can block for a long time during recovery. Don't burst-replay missed ticks.
            if clock.now > next { next = clock.now }

            let finished = path.length - s < 3
            updateSink.yield(MovementUpdate(coordinate: point, speed: v, bearing: bearing,
                                            distanceRemaining: max(0, path.length - s), finished: finished))
            if finished { break }
        }
    }

    // MARK: - Route events (turns to slow for, stops to make)

    private func makeEvents(_ path: RoutePath) -> [RouteEvent] {
        var events: [RouteEvent] = []
        var hint = 0

        // Sharp turns: compare heading 15 m before vs 15 m after, every 20 m.
        var s = 30.0
        while s < path.length - 30 {
            let before = path.sample(at: s - 15, hint: &hint).bearing
            let after = path.sample(at: s + 15, hint: &hint).bearing
            if Geo.angleDifference(before, after) > profile.turnAngleThreshold {
                events.append(RouteEvent(s: s, targetSpeed: profile.turnSpeed, dwell: 0))
                s += 60                                         // one event per turn
            } else {
                s += 20
            }
        }

        // Random traffic stops.
        if profile.stopsPerKm > 0 {
            let meanGap = 1000 / profile.stopsPerKm
            var pos = 0.0
            while true {
                pos += -log(Double.random(in: Double.ulpOfOne..<1)) * meanGap
                if pos > path.length - 80 { break }
                events.append(RouteEvent(s: pos, targetSpeed: 0, dwell: Double.random(in: profile.stopDwell)))
            }
        }

        events.append(RouteEvent(s: path.length, targetSpeed: 0, dwell: 0))   // come to rest at the destination
        return events.sorted { $0.s < $1.s }
    }

    private func gaussian() -> Double {
        let u1 = Double.random(in: Double.ulpOfOne..<1), u2 = Double.random(in: 0..<1)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
