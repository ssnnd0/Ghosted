import Foundation

public struct MovementProfile: Sendable {
    public var cruiseSpeed: Double               // m/s (~30 mph) when nothing else constrains us
    public var maxAccel: Double                  // m/s²
    public var comfortableDecel: Double          // m/s²
    public var stopsPerKm: Double               // random signal/traffic stops (Poisson process)
    public var stopDwellMin: Double              // seconds stopped, lower bound
    public var stopDwellMax: Double              // seconds stopped, upper bound
    public var turnSpeed: Double                 // m/s through sharp turns
    public var turnAngleThreshold: Double        // degrees of heading change (over ~30 m) that counts as a turn
    public var speedNoiseSD: Double              // m/s, stationary std-dev of the speed wobble
    public var lateralNoiseSD: Double            // m, stationary std-dev of GPS-like lane wander
    public var multiplier: Double                // simulation speed-up: 2.0 = the drive takes half as long

    public init(cruiseSpeed: Double = 13.4, maxAccel: Double = 2.0, comfortableDecel: Double = 2.5,
                stopsPerKm: Double = 0.5, stopDwellMin: Double = 8, stopDwellMax: Double = 40,
                turnSpeed: Double = 4.5, turnAngleThreshold: Double = 40.0,
                speedNoiseSD: Double = 0.8, lateralNoiseSD: Double = 1.5, multiplier: Double = 1.0) {
        self.cruiseSpeed = cruiseSpeed
        self.maxAccel = maxAccel
        self.comfortableDecel = comfortableDecel
        self.stopsPerKm = stopsPerKm
        self.stopDwellMin = stopDwellMin
        self.stopDwellMax = stopDwellMax
        self.turnSpeed = turnSpeed
        self.turnAngleThreshold = turnAngleThreshold
        self.speedNoiseSD = speedNoiseSD
        self.lateralNoiseSD = lateralNoiseSD
        self.multiplier = multiplier
    }
}

public struct MovementUpdate: Sendable {
    public let coordinate: Coordinate
    public let speed: Double
    public let bearing: Double
    public let distanceRemaining: Double
    public let finished: Bool

    public init(coordinate: Coordinate, speed: Double, bearing: Double,
                distanceRemaining: Double, finished: Bool) {
        self.coordinate = coordinate
        self.speed = speed
        self.bearing = bearing
        self.distanceRemaining = distanceRemaining
        self.finished = finished
    }
}

/// Pure simulation state machine. Given a RoutePath and a profile, advances the simulation by
/// a given time delta each step and emits `MovementUpdate`s. No timers, no I/O — the caller
/// drives the clock (making this trivially testable on any platform).
public struct MovementSimulator: Sendable {
    public struct RouteEvent: Sendable {
        public let s: Double
        public let targetSpeed: Double
        public let dwell: Double
    }

    public private(set) var s: Double = 0              // meters along the route
    public private(set) var v: Double = 0              // current speed m/s
    public private(set) var dwellLeft: Double = 0      // seconds remaining at a stop
    public private(set) var speedNoise: Double = 0     // OU process state
    public private(set) var lateral: Double = 0        // OU lateral wander state
    public private(set) var hint: Int = 0              // segment cursor for sampling
    public private(set) var events: [RouteEvent]
    public private(set) var finished: Bool = false

    public let path: RoutePath
    public var profile: MovementProfile

    /// A deterministic random source for testability (pass `nil` for real randomness).
    private var rng: RandomSource

    public init(path: RoutePath, profile: MovementProfile = .init(), seed: UInt64? = nil) {
        self.path = path
        self.profile = profile
        self.rng = seed.map { RandomSource.seeded($0) } ?? .system
        self.events = Self.makeEvents(path, profile, &rng)
    }

    /// Advance the simulation by `dt` seconds of *simulated* time. Call at 1 Hz with `dt = profile.multiplier`
    /// for real-time playback, or with small fixed steps for tests.
    public mutating func step(dt totalDt: Double) -> MovementUpdate {
        guard path.length > 5 else {
            finished = true
            return MovementUpdate(coordinate: path.points.first ?? Coordinate(latitude: 0, longitude: 0),
                                  speed: 0, bearing: 0, distanceRemaining: 0, finished: true)
        }

        let theta = 0.5  // OU mean-reversion rate
        let steps = max(1, Int((totalDt / 0.5).rounded(.up)))
        let dt = totalDt / Double(steps)

        for _ in 0..<steps {
            speedNoise += -theta * speedNoise * dt
                        + profile.speedNoiseSD * (2 * theta).squareRoot() * dt.squareRoot() * rng.gaussian()

            var target = max(2, profile.cruiseSpeed + speedNoise)
            if let e = events.first {
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
        lateral += -theta * lateral * totalDt
                 + profile.lateralNoiseSD * (2 * theta).squareRoot() * totalDt.squareRoot() * rng.gaussian()
        let wander = v < 0.3 ? 0.25 : 1.0
        let point = Geo.destination(from: base, bearing: bearing + 90, meters: lateral * wander)

        finished = path.length - s < 3
        return MovementUpdate(coordinate: point, speed: v, bearing: bearing,
                              distanceRemaining: max(0, path.length - s), finished: finished)
    }

    // MARK: - Route events (turns to slow for, stops to make)

    private static func makeEvents(_ path: RoutePath, _ profile: MovementProfile, _ rng: inout RandomSource) -> [RouteEvent] {
        var events: [RouteEvent] = []
        var hint = 0

        // Sharp turns: compare heading 15 m before vs 15 m after, every 20 m.
        var ms = 30.0
        while ms < path.length - 30 {
            let before = path.sample(at: ms - 15, hint: &hint).bearing
            let after = path.sample(at: ms + 15, hint: &hint).bearing
            if Geo.angleDifference(before, after) > profile.turnAngleThreshold {
                events.append(RouteEvent(s: ms, targetSpeed: profile.turnSpeed, dwell: 0))
                ms += 60
            } else {
                ms += 20
            }
        }

        // Random traffic stops.
        if profile.stopsPerKm > 0 {
            let meanGap = 1000 / profile.stopsPerKm
            var pos = 0.0
            while true {
                pos += -log(rng.nextDouble(in: Double.ulpOfOne..<1)) * meanGap
                if pos > path.length - 80 { break }
                let dwell = rng.nextDouble(in: profile.stopDwellMin...profile.stopDwellMax)
                events.append(RouteEvent(s: pos, targetSpeed: 0, dwell: dwell))
            }
        }

        events.append(RouteEvent(s: path.length, targetSpeed: 0, dwell: 0))   // come to rest at the destination
        return events.sorted { $0.s < $1.s }
    }
}

// MARK: - Pluggable random source

/// Wrapper so the simulator can use either a seeded deterministic RNG (for tests) or system randomness.
/// This is a value type — all RNG state is owned by the instance, no global mutable storage.
public struct RandomSource: Sendable {
    // xoshiro256** state for deterministic mode
    private struct Xoshiro: Sendable {
        var s: (UInt64, UInt64, UInt64, UInt64)

        init(seed: UInt64) {
            // SplitMix64 to expand a single seed into four state words
            var z = seed
            func next() -> UInt64 {
                z &+= 0x9E3779B97F4A7C15
                var r = z
                r = (r ^ (r >> 30)) &* 0xBF58476D1CE4E5B9
                r = (r ^ (r >> 27)) &* 0x94D049BB133111EB
                return r ^ (r >> 31)
            }
            s = (next(), next(), next(), next())
        }

        mutating func next() -> UInt64 {
            let result = rotl(s.1 &* 5, 7) &* 9
            let t = s.1 << 17
            s.2 ^= s.0; s.3 ^= s.1; s.1 ^= s.2; s.0 ^= s.3
            s.2 ^= t; s.3 = rotl(s.3, 45)
            return result
        }

        private func rotl(_ x: UInt64, _ k: Int) -> UInt64 {
            (x << k) | (x >> (64 - k))
        }
    }

    private var xoshiro: Xoshiro?
    private let isSeeded: Bool

    /// Create a system-random source (non-deterministic).
    public static var system: RandomSource { RandomSource(xoshiro: nil, isSeeded: false) }

    /// Create a seeded deterministic source for reproducible results.
    public static func seeded(_ seed: UInt64) -> RandomSource {
        RandomSource(xoshiro: Xoshiro(seed: seed), isSeeded: true)
    }

    public mutating func nextDouble(in range: Range<Double>) -> Double {
        let raw = nextRaw()
        let unit = Double(raw >> 11) * 0x1.0p-53 // [0, 1)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    public mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        let raw = nextRaw()
        let unit = Double(raw >> 11) * 0x1.0p-53
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    private mutating func nextRaw() -> UInt64 {
        if isSeeded {
            return xoshiro!.next()
        } else {
            return UInt64.random(in: .min ... .max)
        }
    }

    public mutating func gaussian() -> Double {
        let u1 = nextDouble(in: Double.ulpOfOne..<1)
        let u2 = nextDouble(in: 0.0..<1.0)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
