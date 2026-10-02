import AVFoundation
import CoreLocation

/// Keeps the process alive while the screen is locked so the 1 Hz location stream never stalls.
///
/// Two independent mechanisms, because either one alone can be revoked by iOS:
///  1. `UIBackgroundModes: audio` + an always-running silent AVAudioEngine loop.
///  2. `UIBackgroundModes: location` + `allowsBackgroundLocationUpdates`. (Location updates arrive from the
///     simulated position, which is fine — we only want the background-execution privilege.)
///
/// Both modes MUST be declared in Info.plist. Setting `allowsBackgroundLocationUpdates = true` without the
/// `location` background mode raises an Objective-C exception and crashes the app.
///
/// Sideload-only: silent-audio keep-alive violates App Store guidelines. Expect noticeable battery drain, and
/// note that Low Power Mode and thermal pressure can still get the app suspended.
///
/// `@unchecked Sendable`: the two `NotificationCenter` observers below are `@Sendable` closures, so they capture
/// `self` and require a Sendable type. The instance is genuinely main-thread-confined — only
/// `SpoofingSession` (itself `@MainActor`) creates and drives it, and both observers use `queue: .main` — so
/// marking it `@MainActor` would express that more precisely. `@unchecked` is used instead because it is the
/// minimal change that satisfies Swift 6 without making the observer bodies hop to the main actor. Revisit if
/// the notification handling ever moves off the main queue.
final class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let location = CLLocationManager()
    private var observers: [NSObjectProtocol] = []

    /// - Throws: if the audio engine or session cannot be armed. On any throw the receiver is
    ///   left fully torn down — see the `catch` below.
    func start() throws {
        do {
            location.delegate = self
            location.desiredAccuracy = kCLLocationAccuracyKilometer          // we don't need precision, just the privilege
            location.pausesLocationUpdatesAutomatically = false
            location.allowsBackgroundLocationUpdates = true
            location.showsBackgroundLocationIndicator = true
            if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
            location.startUpdatingLocation()

            try startSilentAudio()

            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                try? self?.startSilentAudio()                                // phone call / Siri ended → resume
            })
            observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                try? self?.startSilentAudio()                                // mediaserverd restarted → rebuild everything
            })
        } catch {
            // `startSilentAudio()` throws *after* location updates are already running. Without
            // this the caller is left holding an instance it never stored, so nothing can ever
            // call `stop()` — the background location indicator stays on and the audio session
            // stays active for the rest of the process, even though the session failed to start.
            stop()
            throw error
        }
    }

    /// Idempotent. Safe to call on a partially-started instance and more than once.
    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        player.stop()
        engine.stop()
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationIndicator = false
        location.allowsBackgroundLocationUpdates = false
        location.delegate = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startSilentAudio() throws {
        player.stop()
        engine.stop()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])   // don't pause the user's music
        try session.setActive(true)

        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let frames: AVAudioFrameCount = 44_100                             // 1 s buffer, looped forever
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData?[0].update(repeating: 0, count: Int(frames))   // explicit zeros = silence

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Intentionally empty. The app's own source of truth is RouteStreamer, not CoreLocation.
    }
}
