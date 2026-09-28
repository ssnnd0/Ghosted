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
final class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate {
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let location = CLLocationManager()
    private var observers: [NSObjectProtocol] = []

    func start() throws {
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
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        player.stop()
        engine.stop()
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
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
        // Intentionally empty. The app's own source of truth is MovementController, not CoreLocation.
    }
}
