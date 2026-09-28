import Foundation

public enum RuntimeContractStatus: String, Sendable {
    case ready = "Ready"
    case pending = "Pending"
    case blocked = "Blocked"
    case warning = "Warning"
}

public struct RuntimeContractCheck: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let requirement: String
    public let status: RuntimeContractStatus
    public let detail: String

    public init(id: String, title: String, requirement: String, status: RuntimeContractStatus, detail: String) {
        self.id = id
        self.title = title
        self.requirement = requirement
        self.status = status
        self.detail = detail
    }
}

public enum RuntimeContractAudit {
    public static func checklist() -> [RuntimeContractCheck] {
        [
            RuntimeContractCheck(
                id: "ios-version",
                title: "iOS 17.4+",
                requirement: "Device OS must be iOS 17.4 or newer.",
                status: .pending,
                detail: "The runtime is only supported on iOS 17.4+ because the developer-service path and DDI flow differ below this floor."
            ),
            RuntimeContractCheck(
                id: "developer-mode",
                title: "Developer Mode",
                requirement: "Enable Developer Mode in Settings → Privacy & Security.",
                status: .pending,
                detail: "If off, the device blocks the pairing and tunnel flow required by the local spoofing backend."
            ),
            RuntimeContractCheck(
                id: "pairing-file",
                title: "Pairing file",
                requirement: "Import a valid pairing file generated on a trusted computer.",
                status: .pending,
                detail: "A stale or mismatched pairing record is terminal until a fresh one is generated and re-imported."
            ),
            RuntimeContractCheck(
                id: "loopback-vpn",
                title: "Loopback VPN",
                requirement: "Keep the loopback VPN active and connected to Wi‑Fi.",
                status: .pending,
                detail: "The app reaches the device's own developer services through a loopback address and must be reachable from inside the app."
            ),
            RuntimeContractCheck(
                id: "ddi-mount",
                title: "Developer Disk Image",
                requirement: "Mount the DDI matching the installed iOS version.",
                status: .pending,
                detail: "The DDI must include BuildManifest.plist, Image.dmg, and Image.dmg.trustcache. Bad manifests or mismatches are terminal."
            ),
            RuntimeContractCheck(
                id: "location-channel",
                title: "Location channel",
                requirement: "Open the RSD/CoreDevice location-simulation channel and keep the heartbeat alive.",
                status: .pending,
                detail: "This is the live device runtime contract that translates the simulated route into the system location service."
            ),
            RuntimeContractCheck(
                id: "background-mode",
                title: "Background keep-alive",
                requirement: "Leave silent-audio and location background modes enabled.",
                status: .pending,
                detail: "Background execution is required for a continuous 1 Hz spoofed GPS stream while the phone is locked."
            )
        ]
    }

    public static func summary() -> String {
        let checks = checklist()
        let ready = checks.filter { $0.status == .ready }.count
        let blocked = checks.filter { $0.status == .blocked }.count
        if blocked > 0 {
            return "Runtime contract is blocked; fix the required device checks before launching the route."
        }
        if ready == checks.count {
            return "Runtime contract is ready on-device."
        }
        return "Runtime contract is in progress: \(ready)/\(checks.count) checks are ready; the remaining checks must be validated on the iPhone."
    }
}
