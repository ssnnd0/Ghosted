// Ghosted — iOS-only entry point.
//
// On Windows/Linux this target won't compile (it needs UIKit, AVFoundation, etc.).
// Build and test GhostedCore there instead:  swift build --target GhostedCore && swift test

#if os(iOS)
import Foundation
import UIKit
import GhostedCore

final class MapShellViewController: UIViewController {
    private let statusLabel = UILabel()
    private let mapPlaceholder = UIView()
    private let checklistLabel = UILabel()
    private let alertBanner = UILabel()
    private let routeSummaryLabel = UILabel()
    private let controls = UIStackView()
    private let startButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let pauseButton = UIButton(type: .system)

    // Route input. Text fields rather than a map picker because there is no map view here
    // (see the note on `mapPlaceholder`) — a `MKMapView` would need the tier-gated Maps SDK,
    // and CoreLocation alone cannot do reverse geocoding well enough to replace it.
    private let originField = UITextField()
    private let destinationField = UITextField()
    private let routeForm = UIStackView()
    private let multiplierSlider = UISlider()
    private let multiplierLabel = UILabel()

    private let session: SpoofingSession
    private let planner: RoutePlanner
    private let hasCameras: Bool

    /// Offline fallback, streamed only when the user explicitly asks for it. A planning failure
    /// must never silently substitute a different route — that would put the device on a path
    /// the user did not choose.
    private let demoRoute: [Coordinate] = [
        Coordinate(latitude: 40.7128, longitude: -74.0060),
        Coordinate(latitude: 40.7304, longitude: -73.9866),
        Coordinate(latitude: 40.7484, longitude: -73.9857),
        Coordinate(latitude: 40.7580, longitude: -73.9855),
    ]
    private static let demoOrigin = "40.7128, -74.0060"
    private static let demoDestination = "40.7580, -73.9855"

    // A missing cameras.geojson must not stop the app; proximity alerts go inert.
    override init(nibName: String?, bundle: Bundle?) {
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cameras.geojson")
        let index = (try? CameraLoader.loadGeoJSON(url)) ?? CameraQuadtree()
        hasCameras = index.count > 0
        planner = RoutePlanner.makeDefault(cameras: index)
        session = SpoofingSession(cameras: index, planner: planner)
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

        routeSummaryLabel.numberOfLines = 0
        routeSummaryLabel.font = .preferredFont(forTextStyle: .footnote)
        routeSummaryLabel.textColor = .secondaryLabel
        routeSummaryLabel.text = "No route planned yet."
        routeSummaryLabel.translatesAutoresizingMaskIntoConstraints = false

        configure(originField, placeholder: "From lat, lon")
        configure(destinationField, placeholder: "To lat, lon")
        originField.text = Self.demoOrigin
        destinationField.text = Self.demoDestination
        originField.keyboardType = .numbersAndPunctuation
        destinationField.keyboardType = .numbersAndPunctuation

        routeForm.axis = .vertical
        routeForm.spacing = 8
        routeForm.addArrangedSubview(originField)
        routeForm.addArrangedSubview(destinationField)
        routeForm.translatesAutoresizingMaskIntoConstraints = false

        startButton.setTitle("Start session", for: .normal)
        startButton.addTarget(self, action: #selector(startTapped), for: .touchUpInside)
        stopButton.setTitle("Stop", for: .normal)
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        stopButton.isEnabled = false
        pauseButton.setTitle("Pause", for: .normal)
        pauseButton.addTarget(self, action: #selector(pauseTapped), for: .touchUpInside)
        pauseButton.isEnabled = false

        controls.axis = .horizontal
        controls.spacing = 24
        controls.alignment = .center
        controls.addArrangedSubview(startButton)
        controls.addArrangedSubview(pauseButton)
        controls.addArrangedSubview(stopButton)
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        // 0.1…50× is the range RouteStreamer clamps to; the slider mirrors it so the label and
        // the accepted value cannot disagree.
        multiplierSlider.minimumValue = 0.1
        multiplierSlider.maximumValue = 50
        multiplierSlider.value = 1
        multiplierSlider.isEnabled = false
        multiplierSlider.addTarget(self, action: #selector(multiplierChanged), for: .valueChanged)
        multiplierSlider.translatesAutoresizingMaskIntoConstraints = false

        multiplierLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        multiplierLabel.textColor = .secondaryLabel
        multiplierLabel.text = "1.0×"
        multiplierLabel.translatesAutoresizingMaskIntoConstraints = false

        checklistLabel.numberOfLines = 0
        checklistLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        checklistLabel.textColor = .secondaryLabel
        checklistLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(checklistLabel)

        NSLayoutConstraint.activate([
            mapPlaceholder.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            mapPlaceholder.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            mapPlaceholder.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            mapPlaceholder.heightAnchor.constraint(equalToConstant: 300),

            routeForm.topAnchor.constraint(equalTo: mapPlaceholder.bottomAnchor, constant: 12),
            routeForm.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            routeForm.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            routeSummaryLabel.topAnchor.constraint(equalTo: routeForm.bottomAnchor, constant: 8),
            routeSummaryLabel.leadingAnchor.constraint(equalTo: routeForm.leadingAnchor),
            routeSummaryLabel.trailingAnchor.constraint(equalTo: routeForm.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: routeSummaryLabel.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            alertBanner.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            alertBanner.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            alertBanner.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),

            controls.topAnchor.constraint(equalTo: alertBanner.bottomAnchor, constant: 10),
            controls.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            multiplierSlider.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            multiplierSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            multiplierSlider.trailingAnchor.constraint(equalTo: multiplierLabel.leadingAnchor, constant: -8),
            multiplierLabel.topAnchor.constraint(equalTo: multiplierSlider.topAnchor, constant: 2),
            multiplierLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            multiplierLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),

            checklistLabel.topAnchor.constraint(equalTo: multiplierSlider.bottomAnchor, constant: 12),
            checklistLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            checklistLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            checklistLabel.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])

        view.addSubview(routeForm)
        view.addSubview(routeSummaryLabel)
        view.addSubview(multiplierSlider)
        view.addSubview(multiplierLabel)
    }

    private func configure(_ field: UITextField, placeholder: String) {
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .whileEditing
        field.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
    }

    /// Parses `"lat, lon"`. `nil` on failure; `parseError` carries the reason for the UI so it can
    /// say *why* it failed rather than silently doing nothing.
    private func parse(_ text: String?, label: String) -> Coordinate? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            parseError = "\(label) is empty."
            return nil
        }
        let parts = trimmed.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else {
            parseError = "\(label) must be two numbers, e.g. 40.7128, -74.0060."
            return nil
        }
        guard (-90...90).contains(lat), (-180...180).contains(lon) else {
            parseError = "\(label) is out of range: latitude \(lat), longitude \(lon)."
            return nil
        }
        parseError = nil
        return Coordinate(latitude: lat, longitude: lon)
    }

    private var parseError: String?

    // MARK: - Session

    private func bindSession() {
        session.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            self.statusLabel.text = "Ghosted\n\(phase.message)"
            self.startButton.isEnabled = self.session.canStart
            self.stopButton.isEnabled = (phase == .ready)
            self.refreshContract()
        }

        session.onAlert = { [weak self] alert in
            let meters = Int(alert.distance.rounded())
            self?.alertBanner.text = "Camera \(meters) m ahead"
        }

        session.onRoutePlanned = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let planned):
                self.routeSummaryLabel.text = "\(planned.summary)\n\(planned.message)"
                self.routeSummaryLabel.textColor = .secondaryLabel
            case .failure(let error):
                // Say what failed and offer the explicit offline fallback, rather than silently
                // streaming some other path.
                self.routeSummaryLabel.text =
                    "Route planning failed: \(Self.describe(error))\n\(self.demoRouteButtonTitle)"
                self.routeSummaryLabel.textColor = UIColor.systemRed
                self.alertBanner.text = ""
            }
            self.refreshControls()
        }
    }

    private var demoRouteButtonTitle: String { "No route is streaming." }

    /// Streams the built-in demo path. Only reachable via `drive(route:)` after planning has
    /// failed, so it is always an explicit user choice.
    @objc private func useDemoRoute() {
        session.drive(route: demoRoute)
        routeSummaryLabel.text = "Streaming the built-in demo route (no router call)."
        routeSummaryLabel.textColor = .secondaryLabel
        refreshControls()
    }

    /// Enable exactly the actions that make sense in the current state. Without this the user
    /// can hit Start during a failed session, or Pause with nothing streaming.
    private func refreshControls() {
        startButton.isEnabled = session.canStart
        stopButton.isEnabled = (session.phase == .ready) || session.isStreaming
        pauseButton.isEnabled = session.isStreaming
        multiplierSlider.isEnabled = session.isStreaming
        pauseButton.setTitle(isPaused ? "Resume" : "Pause", for: .normal)
    }

    private var isPaused = false

    private static func describe(_ error: Error) -> String {
        if let router = error as? RouterError { return router.description }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
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
        // Validate before bringing the session up: a malformed route should not open a
        // background-location session just to fail a text parse.
        guard let from = parse(originField.text, label: "From"),
              let to = parse(destinationField.text, label: "To") else {
            routeSummaryLabel.text = parseError ?? "Invalid route."
            routeSummaryLabel.textColor = UIColor.systemRed
            return
        }

        // Inherits MainActor isolation from this controller, so only `start()` needs a hop.
        Task { [weak self] in
            guard let self else { return }
            await self.session.start()
            guard self.session.phase == .ready else { return }
            // Plan and stream: this is what consults the camera index and, where the backend
            // supports it, sends exclusion polygons to the router.
            await self.session.planAndDrive(from: from, to: to)
            self.refreshControls()
        }
    }

    @objc private func stopTapped() {
        alertBanner.text = ""
        Task { [weak self] in
            guard let self else { return }
            await self.session.stop()
            self.isPaused = false
            self.refreshControls()
        }
    }

    @objc private func pauseTapped() {
        if isPaused {
            session.resume()
        } else {
            session.pause()
        }
        isPaused.toggle()
        refreshControls()
    }

    @objc private func multiplierChanged() {
        let value = Double(multiplierSlider.value)
        session.setMultiplier(value)
        multiplierLabel.text = String(format: "%.1f×", value)
    }
}

/// `@main` on the app delegate is the modern replacement for `@UIApplicationMain`
/// (SE-0383) — it synthesises the `UIApplicationMain` call. The hand-rolled version
/// needed `CommandLine.unsafeArgv`, which is internal to the stdlib overlay and is
/// therefore not accessible from app code.
@main
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
