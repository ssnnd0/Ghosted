import Foundation

/// Native bridge shell for the idevice / CoreDevice / RSD path.
///
/// This class keeps the exact state model required by `LocalSpoofingManager` without inventing
/// unsupported FFI symbols or making false claims about vendor APIs that are not in the workspace.
/// The actual bridge is intentionally defined by state transitions, not by fake C function names.
///
/// ## It does not talk to a device, and it says so
///
/// There is no FFI here. Every method below validates the session's state and then records it.
/// `setLocation` does not move a device; `openLocationChannel` does not open a channel. So this
/// backend **throws `SpoofError.backendNotLinked` from the first call that would need real
/// hardware** rather than reporting a successful session that pushes nothing. An app that claims
/// `.ready` while silently doing nothing is worse than one that refuses to start.
///
/// Which methods refuse, and why:
///
///   | Method                  | Behaviour                                   |
///   |-------------------------|---------------------------------------------|
///   | `isDDIMounted`          | Answers from state — safe, never false-claims|
///   | `mountDDI`              | **Validates the DDI folder, then refuses**   |
///   | `isDeveloperModeEnabled`| Answers from state                           |
///   | `loadPairing`           | Validates the record is non-empty            |
///   | `openLocationChannel`   | **Refuses**                                  |
///   | `setLocation`           | **Refuses**                                  |
///   | `runHeartbeat`          | **Refuses**                                  |
///
/// The DDI *validation* is real work, not a stub: it checks for the three files a mount needs and
/// reports precisely which are missing, which is the single most common setup mistake. It is done
/// before the refusal so the user gets the actionable half of the answer even with no backend.
///
/// ## The real bridge
///
/// `IdeviceFFIBackend.swift` implements the same `DeveloperServicesBackend` protocol against the
/// C shim in `Sources/IdeviceFFI/`, behind the `IDEVICE_FFI_ENABLED` compilation condition. It is
/// off by default and has never been compiled — see that file's header. To use it, swap the one
/// `IdeviceBackend()` in `SpoofingSession.init` for `IdeviceFFIBackend(ddiDirectory:)`.
///
/// ## This is an `actor`, not a `final class` with an `NSLock`
///
/// The state below is shared mutable state, and every entry point is already `async` to satisfy
/// `DeveloperServicesBackend`, so actor isolation expresses the requirement directly. A lock is
/// not equivalent: only `loadPairing` was guarded by one, while `ddiMounted`, `locationChannelOpen`
/// and `lastKnownPosition` were read and written unguarded from other `async` methods under an
/// `@unchecked Sendable` conformance — an unsound data race that the conformance merely concealed.
/// It is also why no `Synchronization.Mutex` is needed (that would require iOS 18; this project
/// targets 17.4).
actor IdeviceBackend: DeveloperServicesBackend {
    private var pairingData: Data?
    private var ddiMounted = false
    private var locationChannelOpen = false
    private var lastKnownPosition: (lat: Double, lon: Double)?

    func loadPairing(_ data: Data) async throws {
        guard !data.isEmpty else { throw SpoofError.pairingFileMissing }
        pairingData = data
    }

    func isDeveloperModeEnabled() async throws -> Bool {
        guard pairingData != nil else { throw SpoofError.pairingFileMissing }
        // True here means "a pairing record is present", which is the only fact available without
        // a device. It is NOT a claim that the device's Developer Mode is on — `openLocationChannel`
        // is where that would have to be verified, and it refuses.
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

        // The folder is inside the app container, which a fresh install simply does not have.
        // `contentsOfDirectory` would otherwise throw a bare NSCocoaErrorDomain, which is not a
        // LocalizedError, so the caller would render "Error Domain=NSCocoaErrorDomain Code=260
        // …" — technically accurate and useless. Name the exact folder instead.
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw SpoofError.ddiMountFailed("No DDI folder at \(directory.path). Create it and copy "
                + "BuildManifest.plist, Image.dmg and Image.dmg.trustcache into it. "
                + "(The app's Documents folder is visible via Finder / the Files app because "
                + "UIFileSharingEnabled is set.)")
        }

        let requiredFiles = ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"]
        let existing: [URL]
        do {
            existing = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            throw SpoofError.ddiMountFailed("Can't read \(directory.path): \(error.localizedDescription)")
        }
        let present = Set(existing.map(\.lastPathComponent))
        let missing = requiredFiles.filter { !present.contains($0) }
        guard missing.isEmpty else {
            throw SpoofError.ddiMountFailed("Missing DDI components in \(directory.lastPathComponent): "
                + "\(missing.joined(separator: ", ")). The DDI must match the iOS build on this device.")
        }

        // The folder is valid — but there is still no native layer to mount it with, so the
        // session must not proceed. `ddiMounted` stays false.
        throw SpoofError.backendNotLinked
    }

    func openLocationChannel() async throws {
        guard pairingData != nil else { throw SpoofError.pairingFileMissing }
        guard ddiMounted else { throw SpoofError.ddiMountFailed("DDI not mounted before location channel open") }
        throw SpoofError.backendNotLinked
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
