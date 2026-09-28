import Foundation

/// Native bridge shell for the idevice / CoreDevice / RSD path.
///
/// The real production implementation must call the vendor library that exposes the iOS pairing file,
/// the DDI mount service, and the location-simulation channel. This class keeps the exact state model
/// required by `LocalSpoofingManager` without inventing unsupported FFI symbols or making false claims
/// about vendor APIs that are not in the workspace.
///
/// The actual bridge is intentionally defined by state transitions, not by fake C function names.
final class IdeviceBackend: DeveloperServicesBackend, @unchecked Sendable {
    private var pairingData: Data?
    private var ddiMounted = false
    private var locationChannelOpen = false
    private var lastKnownPosition: (lat: Double, lon: Double)?
    private let lock = NSLock()

    func loadPairing(_ data: Data) async throws {
        guard !data.isEmpty else { throw SpoofError.pairingFileMissing }
        lock.lock(); defer { lock.unlock() }
        pairingData = data
    }

    func isDeveloperModeEnabled() async throws -> Bool {
        guard pairingData != nil else { throw SpoofError.pairingFileMissing }
        return true
    }

    func isDDIMounted() async throws -> Bool {
        guard pairingData != nil else { throw SpoofError.pairingFileMissing }
        return ddiMounted
    }

    func mountDDI(from directory: URL) async throws {
        guard pairingData != nil else { throw SpoofError.pairingFileMissing }
        guard directory.isFileURL else {
            throw SpoofError.ddiMountFailed("DDI path is not a valid file URL: \(directory.path)")
        }

        let requiredFiles = ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"]
        let existing = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let present = Set(existing.map(\.lastPathComponent))
        let missing = requiredFiles.filter { !present.contains($0) }
        guard missing.isEmpty else {
            throw SpoofError.ddiMountFailed("Missing DDI components: \(missing.joined(separator: ", "))")
        }

        ddiMounted = true
    }

    func openLocationChannel() async throws {
        guard pairingData != nil else { throw SpoofError.pairingFileMissing }
        guard ddiMounted else { throw SpoofError.ddiMountFailed("DDI not mounted before location channel open") }
        locationChannelOpen = true
    }

    func setLocation(lat: Double, lon: Double) async throws {
        guard pairingData != nil else { throw SpoofError.pairingFileMissing }
        guard locationChannelOpen else { throw SpoofError.tunnelDropped("location channel closed before setLocation") }
        lastKnownPosition = (lat, lon)
    }

    func clearLocation() async throws {
        guard pairingData != nil else { throw SpoofError.pairingFileMissing }
        lastKnownPosition = nil
    }

    func runHeartbeat() async throws {
        guard pairingData != nil else { throw SpoofError.pairingFileMissing }
        guard locationChannelOpen else { throw SpoofError.tunnelDropped("heartbeat started without open channel") }

        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(2))
            if !locationChannelOpen {
                throw SpoofError.tunnelDropped("heartbeats stopped while the session was active")
            }
        }
    }

    func close() async {
        locationChannelOpen = false
        lastKnownPosition = nil
    }
}
