import Foundation
// `NWConnection` is captured by `stateUpdateHandler` and by the timeout block in `probeLoopback`.
// Both closures are `@Sendable`, and Network.framework does not vended `NWConnection` as `Sendable`,
// so Swift 6 rejects the capture. `@preconcurrency` downgrades just that diagnostic: `NWConnection`
// really is documented as safe to `start`/`cancel` from any thread, which is all this file does.
@preconcurrency import Network
import Security
import GhostedCore

// MARK: - Errors

enum SpoofError: Error, LocalizedError, Equatable {
    case unsupportedOS(String)
    case pairingFileMissing
    case pairingRejected            // device was reset / re-trusted; the pairing file is stale
    case loopbackVPNDown
    case developerModeOff
    case ddiMountFailed(String)     // includes "BadBuildManifest"-style mismatches
    case tunnelDropped(String)
    case backendNotLinked

    /// Terminal errors need the user to do something. Retrying them just burns battery.
    var isTerminal: Bool {
        switch self {
        case .loopbackVPNDown, .tunnelDropped: return false
        default: return true
        }
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedOS(let v): return v
        case .pairingFileMissing: return "No pairing file. Import one generated on a trusted computer."
        case .pairingRejected: return "The device rejected the pairing file (reset or re-trusted?). Generate a fresh one."
        case .loopbackVPNDown: return "Can't reach the device's own services. Turn the loopback VPN on and stay on Wi-Fi."
        case .developerModeOff: return "Developer Mode is off (Settings → Privacy & Security → Developer Mode)."
        case .ddiMountFailed(let why):
            return "Developer Disk Image failed to mount: \(why). Import a DDI folder matching this iOS version " +
                   "(BuildManifest.plist + Image.dmg + Image.dmg.trustcache). If an image is already mounted, reboot first."
        case .tunnelDropped(let why): return "Developer tunnel dropped: \(why)"
        case .backendNotLinked:
            return "No native device backend is linked into this build, so nothing has been pushed to the "
                 + "device. This is expected: the libimobiledevice bridge is behind the IDEVICE_FFI_ENABLED "
                 + "flag and is off by default. See Sources/IdeviceFFI/ and XCODE.md."
        }
    }
}

// MARK: - Backend contract

/// Everything the manager needs from the native layer. Implementations must translate native errors
/// into `SpoofError` so the manager can tell "retry" from "ask the user".
protocol DeveloperServicesBackend: Sendable {
    func loadPairing(_ data: Data) async throws
    func isDeveloperModeEnabled() async throws -> Bool
    func isDDIMounted() async throws -> Bool
    func mountDDI(from directory: URL) async throws
    /// Lockdown session → CoreDeviceProxy tunnel → RSD → DVT LocationSimulation channel.
    func openLocationChannel() async throws
    func setLocation(lat: Double, lon: Double) async throws
    func clearLocation() async throws
    /// Answers the device's heartbeat. Blocks until it fails or the task is cancelled.
    func runHeartbeat() async throws
    func close() async
}

// MARK: - Pairing storage (Keychain — a pairing record grants developer-level control of the device)

enum PairingStore {
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Ghosted",
         kSecAttrAccount as String: "device-pairing-record"]
    }

    static func save(_ data: Data) throws {
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw SpoofError.pairingFileMissing }
    }

    static func load() throws -> Data {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else {
            throw SpoofError.pairingFileMissing
        }
        return d
    }
}

// MARK: - Manager

actor LocalSpoofingManager {
    enum State: Equatable, Sendable {
        case idle, checkingNetwork, preparingDevice, mountingDDI, connecting, ready
        case recovering(attempt: Int)
        case failed(String)
    }

    struct Config: Sendable {
        /// Address the loopback VPN maps to this device. Verify against your VPN app / idevice provider setup.
        var loopbackHost = "10.7.0.1"
        /// lockdownd's port; used only as a reachability probe.
        var loopbackProbePort: UInt16 = 62078
        var ddiDirectory: URL
        var maxRecoveryAttempts = 6
    }

    let states: AsyncStream<State>
    private let stateSink: AsyncStream<State>.Continuation
    private let backend: DeveloperServicesBackend
    private let config: Config

    private var state: State = .idle { didSet { stateSink.yield(state) } }
    private var heartbeat: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var recoveryTask: Task<Void, Error>?
    private var lastPushed: Coordinate?

    init(backend: DeveloperServicesBackend, config: Config) {
        self.backend = backend
        self.config = config
        let pair = AsyncStream.makeStream(of: State.self)
        self.states = pair.stream
        self.stateSink = pair.continuation
    }

    // MARK: Lifecycle

    /// Idempotent bring-up. Order matters: each step fails with a specific, actionable error.
    func start() async throws {
        do {
            try requireSupportedOS()
            state = .checkingNetwork
            try await backend.loadPairing(PairingStore.load())
            try await waitForLoopback(timeout: 10)

            state = .preparingDevice
            guard try await backend.isDeveloperModeEnabled() else { throw SpoofError.developerModeOff }
            let mounted = try await backend.isDDIMounted()
            if !mounted {
                state = .mountingDDI
                try await backend.mountDDI(from: config.ddiDirectory)
            }

            state = .connecting
            try await backend.openLocationChannel()
            beginHeartbeat()
            beginPathMonitor()
            state = .ready
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            throw error
        }
    }

    /// Always call this when a trip ends. Clears the fake location so every app sees real GPS again.
    func stop() async {
        heartbeat?.cancel(); heartbeat = nil
        pathMonitor?.cancel(); pathMonitor = nil
        try? await backend.clearLocation()
        await backend.close()
        lastPushed = nil
        state = .idle
    }

    // MARK: Pushing locations

    /// Called once per tick by `RouteStreamer`. One transparent recovery attempt per failure.
    func setLocation(_ c: Coordinate) async throws {
        lastPushed = c
        do {
            try await backend.setLocation(lat: c.latitude, lon: c.longitude)
        } catch let e as SpoofError where e.isTerminal {
            state = .failed(e.errorDescription ?? "")
            throw e
        } catch {
            try await recover()
            try await backend.setLocation(lat: c.latitude, lon: c.longitude)
        }
    }

    // MARK: Recovery

    /// Concurrent callers share one recovery run.
    private func recover() async throws {
        if let running = recoveryTask { return try await running.value }
        let t = Task { try await self.runRecovery() }
        recoveryTask = t
        defer { recoveryTask = nil }
        try await t.value
    }

    private func runRecovery() async throws {
        heartbeat?.cancel()
        await backend.close()
        var delay = 1.0
        for attempt in 1...config.maxRecoveryAttempts {
            state = .recovering(attempt: attempt)
            do {
                try await waitForLoopback(timeout: 5)
                try await backend.openLocationChannel()
                if let c = lastPushed { try await backend.setLocation(lat: c.latitude, lon: c.longitude) }
                beginHeartbeat()
                state = .ready
                return
            } catch let e as SpoofError where e.isTerminal {
                state = .failed(e.errorDescription ?? "")
                throw e
            } catch {
                try await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 15)                       // 1, 2, 4, 8, 15, 15 …
            }
        }
        let e = SpoofError.tunnelDropped("gave up after \(config.maxRecoveryAttempts) attempts")
        state = .failed(e.errorDescription ?? "")
        throw e
    }

    private func beginHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            guard let self else { return }
            do { try await self.backend.runHeartbeat() }
            catch is CancellationError { return }
            catch { await self.heartbeatFailed() }
        }
    }

    private func heartbeatFailed() async {
        guard state != .idle else { return }
        try? await recover()
    }

    /// Wi-Fi roaming, VPN toggles and airplane-mode flaps all show up as path changes; verify and repair proactively
    /// instead of waiting for the next `setLocation` to fail.
    private func beginPathMonitor() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { await self?.networkChanged() }
        }
        monitor.start(queue: DispatchQueue(label: "ghosted.path"))
        pathMonitor = monitor
    }

    private func networkChanged() async {
        guard state == .ready else { return }
        let reachable = await probeLoopback(timeout: 2)
        if !reachable { try? await recover() }
    }

    // MARK: Helpers

    private func requireSupportedOS() throws {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.majorVersion < 17 || (v.majorVersion == 17 && v.minorVersion < 4) {
            throw SpoofError.unsupportedOS(
                "This backend needs iOS 17.4+ (found \(v.majorVersion).\(v.minorVersion)). " +
                "Older versions use the legacy lockdown path, which is not implemented here.")
        }
    }

    private func waitForLoopback(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let ok = await probeLoopback(timeout: 2)
            if ok { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw SpoofError.loopbackVPNDown
    }

    /// TCP connect to the loopback address. With the VPN off this just times out.
    private nonisolated func probeLoopback(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = Once()
            let conn = NWConnection(host: NWEndpoint.Host(config.loopbackHost),
                                    port: NWEndpoint.Port(rawValue: config.loopbackProbePort)!,
                                    using: .tcp)
            conn.stateUpdateHandler = { s in
                switch s {
                case .ready:
                    once.run { cont.resume(returning: true) }
                    conn.cancel()
                case .failed, .cancelled:
                    once.run { cont.resume(returning: false) }
                default:
                    break                                   // .waiting = no route yet; the timeout decides
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run { cont.resume(returning: false) }
                conn.cancel()
            }
        }
    }
}

/// Runs a closure at most once (continuations must be resumed exactly once).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// `body` runs *outside* the lock. It resumes a `CheckedContinuation`, and the resumed task
    /// can run on this very thread — if the lock were still held, a re-entrant call would
    /// self-deadlock on this non-recursive lock.
    func run(_ body: () -> Void) {
        lock.lock()
        let alreadyFired = fired
        fired = true
        lock.unlock()
        if !alreadyFired { body() }
    }
}
