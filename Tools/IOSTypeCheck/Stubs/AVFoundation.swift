// Stub AVFoundation for the type-check harness. NOT part of any shipped product.
// Covers only what BackgroundKeepAlive.swift uses: the silent-audio keep-alive and speech output.
//
// Two fidelity details that matter:
//   * `+[AVAudioFormat standardFormatWithSampleRate:channels:]` is imported by Swift as a
//     failable *initializer* (`AVAudioFormat(standardFormatWithSampleRate:channels:)`), so it is
//     declared as `init?` rather than a static factory returning an optional.
//   * `setActive(_:)` has a default for `options` in the real SDK; BackgroundKeepAlive.swift
//     relies on that when it calls `try session.setActive(true)`.
//
// The `kAVAudioSessionInterruptionTypeKey`-style global is marked nonisolated(unsafe) for the same
// reason as the CoreLocation constants: Swift 6 otherwise infers MainActor isolation.

@_exported import Foundation

public typealias AVAudioFrameCount = UInt32
open class AVAudioTime: NSObject {}

open class AVAudioNode: NSObject {
    open func stop() {}
}

public final class AVAudioMixerNode: AVAudioNode {}

open class AVAudioEngine: NSObject {
    open var mainMixerNode: AVAudioMixerNode { AVAudioMixerNode() }
    open func attach(_ node: AVAudioNode) {}
    open func connect(_ node: AVAudioNode, to dest: AVAudioNode, format: AVAudioFormat?) {}
    open func start() throws {}
    open func stop() {}
}

open class AVAudioPlayerNode: AVAudioNode {
    public struct BufferOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let loops = BufferOptions(rawValue: 1)
    }
    open func scheduleBuffer(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime?, options: BufferOptions) {}
    open func play() {}
}

open class AVAudioFormat: NSObject {
    public init?(standardFormatWithSampleRate sampleRate: Double, channels: AVAudioChannelCount) {}
}
public typealias AVAudioChannelCount = UInt32

open class AVAudioPCMBuffer: NSObject {
    public init?(pcmFormat format: AVAudioFormat, frameCapacity: AVAudioFrameCount) {}
    open var frameLength: AVAudioFrameCount = 0
    open var floatChannelData: UnsafeMutablePointer<UnsafeMutablePointer<Float>>? {
        let p = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1)
        p.pointee = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        return p
    }
}

open class AVAudioSession: NSObject {
    public enum Category: String, Sendable { case playback, record, playAndRecord, ambient }
    public enum Mode: String, Sendable { case `default`, spokenAudio }
    public struct CategoryOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let mixWithOthers = CategoryOptions(rawValue: 1)
    }
    public struct SetActiveOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let notifyOthersOnDeactivation = SetActiveOptions(rawValue: 1)
    }
    public enum InterruptionType: UInt, Sendable { case began, ended }
    public static let interruptionNotification = Notification.Name("AVAudioSessionInterruptionNotification")
    public static let mediaServicesWereResetNotification = Notification.Name("AVAudioSessionMediaServicesWereResetNotification")
    public static func sharedInstance() -> AVAudioSession { AVAudioSession() }
    open func setCategory(_ category: Category, mode: Mode, options: CategoryOptions) throws {}
    open func setActive(_ active: Bool, options: SetActiveOptions = []) throws {}
}

public nonisolated(unsafe) let AVAudioSessionInterruptionTypeKey = "AVAudioSessionInterruptionTypeKey"

open class AVSpeechUtterance: NSObject {
    public init(string: String) {}
}
open class AVSpeechSynthesizer: NSObject {
    public override init() {}
    open func speak(_ utterance: AVSpeechUtterance) {}
}
