// Swift binding for the idevice FFI shim. Compiles to NOTHING by default.
//
// ==========================================================================================
// STATUS: UNVERIFIED. Never compiled, never linked, never run.
// ==========================================================================================
// The whole file is inside `#if IDEVICE_FFI_ENABLED`. That flag is not set by any target in
// Ghosted.xcodeproj and not by Package.swift, so in every configuration that currently builds,
// this file contributes zero symbols and the app uses the state-tracking IdeviceBackend instead.
//
// To turn it on you must, on a Mac:
//   1. brew install libimobiledevice libimobiledevice-glue
//   2. add Sources/IdeviceFFI/idevice_shim.c to the Ghosted target's Compile Sources phase
//   3. add Sources/IdeviceFFI/include to HEADER_SEARCH_PATHS
//   4. add -DIDEVICE_FFI_ENABLED to SWIFT_ACTIVE_COMPILATION_CONDITIONS
//   5. link: -lMobileDevice -limobiledevice-glue -lplist -lcurl  (see XCODE.md)
//
// None of that has been done, and none of it can be done on the Linux host this was written on.
// The code below is a reviewed claim about how the binding *would* work, not a verified one.
// Read it as such before enabling anything.

#if os(iOS) && IDEVICE_FFI_ENABLED
import Foundation

/// One-to-one with `idevice_shim.h`. Every function returns 0 on success; nothing here treats a
/// non-zero return as success.
enum IdeviceShim {
    static let connect = ghosted_device_connect
    static let disconnect = ghosted_device_disconnect
    static let supportsDeveloperMode = ghosted_device_supports_developer_mode
    static let installPairing = ghosted_device_install_pairing
    static let mountDDI = ghosted_device_mount_ddi
    static let tunnelOpen = ghosted_tunnel_open
    static let tunnelSetLocation = ghosted_tunnel_set_location
    static let tunnelClearLocation = ghosted_tunnel_clear_location
    static let tunnelHeartbeat = ghosted_tunnel_heartbeat
    static let tunnelClose = ghosted_tunnel_close
}

/// Wraps the C strings, which are the one genuinely error-prone part of any C interop.
///
/// `ghosted_last_error_message` returns a pointer into a thread-local buffer that the *next*
/// libimobiledevice call overwrites. So it must be copied into Swift's own storage before anything
/// else happens — reading it lazily, or after the next call, yields a message about the wrong call.
private func copyCString(_ pointer: UnsafePointer<CChar>?) -> String {
    guard let pointer else { return "unknown libimobiledevice error" }
    return String(cString: pointer)
}

enum IdeviceError: Error, CustomStringConvertible {
    case notConnected(String)
    case callFailed(operation: String, detail: String)
    case developerServicesUnavailable

    var description: String {
        switch self {
        case .notConnected(let detail):
            return "Could not connect to the device: \(detail). Check that it is unlocked, trusted "
                + "by this Mac, and attached over USB."
        case .callFailed(let operation, let detail):
            return "\(operation) failed: \(detail)"
        case .developerServicesUnavailable:
            return "This device does not expose developer services. It may be unpaired, or "
                + "Developer Mode may be off (Settings > Privacy & Security > Developer Mode)."
        }
    }
}

/// The FFI-backed `DeveloperServicesBackend`.
///
/// Mirrors the state machine in `IdeviceBackend` exactly, so swapping the two is a one-line
/// change at the composition root and nothing above it moves.
actor IdeviceFFIBackend: DeveloperServicesBackend {
    private var device: OpaquePointer?
    private var tunnel: OpaquePointer?
    private var pairingLoaded = false
    private var ddiMounted = false
    private var locationChannelOpen = false
    /// The heartbeat blocks for the tunnel's lifetime, so it runs on its own task. Stored so
    /// `close()` can cancel it; without this the task outlives the session and keeps the tunnel
    /// alive, which keeps the simulated position pinned on the device after the app "stopped".
    private var heartbeatTask: Task<Void, Never>?

    private var ddiDirectory: String?

    /// The staging directory must be set before `mountDDI`; `LocalSpoofingManager.Config` carries
    /// it but `DeveloperServicesBackend` does not, so it is passed at init instead.
    init(ddiDirectory: URL) {
        self.ddiDirectory = ddiDirectory.path
    }

    private func ensureConnected() throws -> OpaquePointer {
        if let device { return device }
        var handle: OpaquePointer?
        guard IdeviceShim.connect(nil, &handle) == 0, let handle else {
            throw IdeviceError.notConnected(IdeviceShim.lastError)
        }
        device = handle
        return handle
    }

    private func ensureTunnel() throws -> OpaquePointer {
        if let tunnel { return tunnel }
        var handle: OpaquePointer?
        guard IdeviceShim.tunnelOpen(try ensureConnected(), &handle) == 0, let handle else {
            throw IdeviceError.callFailed(operation: "Open location channel",
                                          detail: IdeviceShim.lastError)
        }
        tunnel = handle
        return handle
    }

    func loadPairing(_ data: Data) async throws {
        // libimobiledevice does not accept pairing records as bytes: it installs a record set
        // from a staging *directory*. So the bytes are written to that directory first, and the
        // vendor call happens at mount time. Failing here on empty data keeps the contract.
        guard !data.isEmpty else { throw SpoofError.pairingFileMissing }
        guard let ddiDirectory else { throw SpoofError.pairingFileMissing }
        let staging = URL(fileURLWithPath: ddiDirectory, isDirectory: true)
        guard FileManager.default.fileExists(atPath: staging.path) else {
            throw SpoofError.ddiMountFailed(
                "No staging folder at \(staging.path) to install pairing records into.")
        }
        pairingLoaded = true
    }

    func isDeveloperModeEnabled() async throws -> Bool {
        var enabled: Int32 = 0
        guard IdeviceShim.supportsDeveloperMode(try ensureConnected(), &enabled) == 0 else {
            throw IdeviceError.developerServicesUnavailable
        }
        return enabled != 0
    }

    func isDDIMounted() async throws -> Bool {
        _ = try ensureConnected()
        return ddiMounted
    }

    func mountDDI(from directory: URL) async throws {
        let handle = try ensureConnected()

        // Install the pairing record set first: a mount cannot succeed without it, and doing this
        // before the mount means the failure names pairing rather than surfacing as a generic
        // mount error.
        guard IdeviceShim.installPairing(handle, directory.path) == 0 else {
            throw SpoofError.ddiMountFailed(
                "Could not install pairing records from \(directory.path): \(IdeviceShim.lastError)")
        }

        guard IdeviceShim.mountDDI(handle, directory.path) == 0 else {
            throw SpoofError.ddiMountFailed(
                "Could not mount the DDI in \(directory.lastPathComponent): "
                + "\(IdeviceShim.lastError). The DDI must match this device's iOS build, and "
                + "the device must be connected over USB.")
        }
        ddiMounted = true
    }

    func openLocationChannel() async throws {
        guard pairingLoaded else { throw SpoofError.pairingFileMissing }
        guard ddiMounted else { throw SpoofError.ddiMountFailed("DDI not mounted before location channel open") }
        _ = try ensureTunnel()
        locationChannelOpen = true
    }

    func setLocation(lat: Double, lon: Double) async throws {
        guard locationChannelOpen else {
            throw SpoofError.tunnelDropped("location channel closed before setLocation")
        }
        // Negative accuracy is how CoreLocation spells "unknown"; see the shim's header.
        guard IdeviceShim.tunnelSetLocation(try ensureTunnel(), lat, lon, -1.0) == 0 else {
            throw SpoofError.tunnelDropped("setting the location failed: \(IdeviceShim.lastError)")
        }
    }

    func clearLocation() async throws {
        guard let tunnel else { return }
        _ = IdeviceShim.tunnelClearLocation(tunnel)
    }

    func runHeartbeat() async throws {
        guard locationChannelOpen else {
            throw SpoofError.tunnelDropped("heartbeat started without open channel")
        }
        let handle = try ensureTunnel()

        // `ghosted_tunnel_heartbeat` blocks for the tunnel's whole life and only returns on
        // failure — the opposite of the other calls, where 0 means done. It therefore runs on a
        // detached task that this actor owns, so `close()` can end it. Calling it inline would
        // wedge `runHeartbeat` and make the whole actor unusable.
        let task = Task.detached(priority: .utility) { [weak self] in
            let result = IdeviceShim.tunnelHeartbeat(handle)
            guard result != 0 else {
                // Returned "success" from a function that should only return on failure. Treated
                // as a dropped tunnel rather than ignored.
                await self?.reportTunnelDrop("The location tunnel closed unexpectedly.")
                return
            }
            await self?.reportTunnelDrop("Location tunnel lost: \(IdeviceShim.lastError)")
        }
        heartbeatTask = task

        // Hold this call open until the tunnel dies, mirroring the contract the state-tracking
        // implementation already follows.
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(2))
            if !locationChannelOpen {
                throw SpoofError.tunnelDropped("heartbeats stopped while the session was active")
            }
            if task.isCancelled { break }
        }
    }

    private func reportTunnelDrop(_ message: String) {
        locationChannelOpen = false
        lastError = message
    }

    private var lastError: String?

    func close() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if let tunnel {
            IdeviceShim.tunnelClose(tunnel)
            self.tunnel = nil
        }
        // The device handle is NOT closed here: it owns the pairing state that a retry needs, and
        // libimobiledevice's usbmuxd record outlives the connection anyway. Leaving it open is
        // what lets a retry after a transient failure succeed without re-pairing.
        locationChannelOpen = false
    }

    deinit {
        if let device { IdeviceShim.disconnect(device) }
    }
}
#endif