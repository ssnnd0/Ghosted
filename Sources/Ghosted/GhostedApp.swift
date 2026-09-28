// Ghosted — iOS-only entry point.
//
// On Windows/Linux this target won't compile (it needs UIKit, AVFoundation, etc.).
// Build and test GhostedCore there instead:  swift build --target GhostedCore && swift test

#if os(iOS)
import Foundation
import UIKit
import GhostedCore

@main
struct GhostedApp {
    static func main() {
        UIApplicationMain(
            CommandLine.argc,
            CommandLine.unsafeArgV,
            nil,
            NSStringFromClass(AppDelegate.self)
        )
    }
}

final class MapShellViewController: UIViewController {
    private let statusLabel = UILabel()
    private let mapPlaceholder = UIView()
    private let checklistLabel = UILabel()
    private let alertBanner = UILabel()
    private let controls = UIStackView()
    private let startButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)

    private let session: SpoofingSession
    private let hasCameras: Bool

    /// Sample polyline so the 1 Hz stream has something to follow. A real build
    /// feeds this from `Geo.decodePolyline` on a Routes API response.
    private let demoRoute: [Coordinate] = [
        Coordinate(latitude: 40.7128, longitude: -74.0060),
        Coordinate(latitude: 40.7304, longitude: -73.9866),
        Coordinate(latitude: 40.7484, longitude: -73.9857),
        Coordinate(latitude: 40.7580, longitude: -73.9855),
    ]

    // A missing cameras.geojson must not stop the app; proximity alerts go inert.
    override init(nibName: String?, bundle: Bundle?) {
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cameras.geojson")
        let index = (try? CameraLoader.loadGeoJSON(url)) ?? CameraQuadtree()
        hasCameras = index.count > 0
        session = SpoofingSession(cameras: index)
        super.init(nibName: nibName, bundle: bundle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildLayout()
        bindSession()
        refreshContract()
    }

    // MARK: - Layout

    private func buildLayout() {
        mapPlaceholder.backgroundColor = UIColor.systemGray6
        mapPlaceholder.layer.cornerRadius = 18
        mapPlaceholder.layer.borderWidth = 1
        mapPlaceholder.layer.borderColor = UIColor.separator.cgColor
        mapPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mapPlaceholder)

        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .label
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        alertBanner.numberOfLines = 0
        alertBanner.font = .preferredFont(forTextStyle: .footnote)
        alertBanner.textColor = .systemOrange
        alertBanner.text = ""
        alertBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(alertBanner)

        startButton.setTitle("Start session", for: .normal)
        startButton.addTarget(self, action: #selector(startTapped), for: .touchUpInside)
        stopButton.setTitle("Stop", for: .normal)
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        stopButton.isEnabled = false

        controls.axis = .horizontal
        controls.spacing = 24
        controls.alignment = .center
        controls.addArrangedSubview(startButton)
        controls.addArrangedSubview(stopButton)
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        checklistLabel.numberOfLines = 0
        checklistLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        checklistLabel.textColor = .secondaryLabel
        checklistLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(checklistLabel)

        NSLayoutConstraint.activate([
            mapPlaceholder.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            mapPlaceholder.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            mapPlaceholder.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            mapPlaceholder.heightAnchor.constraint(equalToConstant: 420),

            statusLabel.topAnchor.constraint(equalTo: mapPlaceholder.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            alertBanner.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            alertBanner.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            alertBanner.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),

            controls.topAnchor.constraint(equalTo: alertBanner.bottomAnchor, constant: 10),
            controls.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            checklistLabel.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            checklistLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            checklistLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            checklistLabel.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])
    }

    // MARK: - Session

    private func bindSession() {
        session.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            self.statusLabel.text = "Ghosted\n\(phase.message)"
            self.startButton.isEnabled = session.canStart
            self.stopButton.isEnabled = (phase == .ready)
            self.refreshContract()
        }

        session.onAlert = { [weak self] alert in
            let meters = Int(alert.distance.rounded())
            self?.alertBanner.text = "Camera \(meters) m ahead"
        }
    }

    /// Map live session state onto the runtime contract. Anything the app genuinely
    /// cannot observe is left `.pending` rather than optimistically marked ready.
    private func refreshContract() {
        var overrides: [String: RuntimeContractStatus] = [:]
        if session.phase == .ready { overrides["background-mode"] = .ready }
        if hasCameras { overrides["proximity-alerts"] = .ready }

        switch session.phase {
        case .ready:
            overrides["location-channel"] = .ready
        case .failed:
            overrides["location-channel"] = .blocked
        case .idle, .starting:
            break
        }

        let items = RuntimeContractAudit.checklist(overrides: overrides)
            .map { "• \($0.title): \($0.status.rawValue)" }
            .joined(separator: "\n")
        checklistLabel.text = "Runtime contract\n\(items)\n\n\(RuntimeContractAudit.summary(overrides: overrides))"
    }

    @objc private func startTapped() {
        // Inherits MainActor isolation from this controller, so only `start()` needs a hop.
        Task { [weak self] in
            guard let self else { return }
            await self.session.start()
            guard self.session.phase == .ready else { return }
            self.session.drive(route: self.demoRoute)
        }
    }

    @objc private func stopTapped() {
        alertBanner.text = ""
        Task { [weak self] in
            await self?.session.stop()
        }
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let root = MapShellViewController(nibName: nil, bundle: nil)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
#else
// Stub entry point for non-iOS platforms so `swift build` can link the executable.
@main
struct GhostedApp {
    static func main() {
        print("Ghosted — iOS navigation & location-simulation app")
        print("This executable is a stub on non-iOS platforms.")
        print("Build and test the core library with: swift test")
    }
}
#endif
