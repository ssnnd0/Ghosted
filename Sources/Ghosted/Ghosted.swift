// Ghosted — iOS-only entry point.
//
// On Windows/Linux this target won't compile (it needs UIKit, AVFoundation, etc.).
// Build and test GhostedCore there instead:  swift build --target GhostedCore && swift test

#if os(iOS)
import UIKit
import GhostedCore

@main
struct GhostedApp {
    static func main() {
        UIApplicationMain(
            CommandLine.argc,
            CommandLine.unsafeArgv,
            nil,
            NSStringFromClass(AppDelegate.self)
        )
    }
}

final class MapShellViewController: UIViewController {
    private let statusLabel = UILabel()
    private let mapPlaceholder = UIView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        mapPlaceholder.backgroundColor = UIColor.systemGray6
        mapPlaceholder.layer.cornerRadius = 18
        mapPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mapPlaceholder)

        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .label
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            mapPlaceholder.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            mapPlaceholder.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            mapPlaceholder.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            mapPlaceholder.heightAnchor.constraint(equalToConstant: 420),

            statusLabel.topAnchor.constraint(equalTo: mapPlaceholder.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            statusLabel.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])

        let summary = RouteExposureStatus.summary(
            totalDistanceMeters: 2400,
            remainingDistanceMeters: 800,
            cameraHits: []
        )
        statusLabel.text = "Ghosted running\n\(summary.message)"
        mapPlaceholder.layer.borderWidth = 1
        mapPlaceholder.layer.borderColor = UIColor.separator.cgColor
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let root = MapShellViewController()
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
