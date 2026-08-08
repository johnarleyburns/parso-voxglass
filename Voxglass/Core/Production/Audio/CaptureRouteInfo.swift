import Foundation

/// The transport class of an audio input port, populated by the app from
/// `AVAudioSession.currentRoute` (spec §7.1). The classifier keys off this
/// value type so Core never touches `AVAudioSession`.
public enum CapturePortTransport: String, Codable, Sendable, CaseIterable {
    /// USB-C class-compliant interface or USB microphone (retail-capable).
    case usb
    /// Wired headset or wired headphones-with-mic (community-capable).
    case wiredHeadset
    /// The built-in iPhone microphone.
    case builtIn
    /// Any Bluetooth microphone / AirPods route. Never blocked; classified
    /// as draft and told the truth at retail export time (§7.1).
    case bluetooth
    /// AirPlay or other streamed route.
    case airPlay
    /// Anything not otherwise classified.
    case other
}

/// A pure, `Sendable` snapshot of the capture route plus any room-test
/// measurements, fed to `CaptureRouteClassifier`. The app populates it from
/// `AVAudioSession.currentRoute` and the 10-second room test (spec §7.1).
public struct CaptureRouteInfo: Sendable, Equatable {
    /// The transports present on the current route, in no particular order.
    public var transports: Set<CapturePortTransport>
    /// The actual hardware input sample rate, in Hz (0 when unknown).
    public var sampleRate: Double
    /// Whether the sample rate held steady across the observation window.
    /// Unstable sample rate disqualifies a route from retail readiness.
    public var isSampleRateStable: Bool
    /// The input latency reported by the hardware, in seconds.
    public var inputLatencySeconds: TimeInterval
    /// Noise floor measured by the 10-second room test, in dBFS. `nil` when
    /// the room test has not been run.
    public var measuredNoiseFloorDBFS: Double?
    /// Peak level measured during the room test, in dBFS. `nil` when the room
    /// test has not been run.
    public var measuredPeakDBFS: Double?
    /// Speech RMS measured by the room test, in dBFS. `nil` when the room test
    /// has not been run.
    public var measuredSpeechRMSDBFS: Double?

    public init(
        transports: Set<CapturePortTransport> = [.builtIn],
        sampleRate: Double = 0,
        isSampleRateStable: Bool = true,
        inputLatencySeconds: TimeInterval = 0,
        measuredNoiseFloorDBFS: Double? = nil,
        measuredPeakDBFS: Double? = nil,
        measuredSpeechRMSDBFS: Double? = nil
    ) {
        self.transports = transports
        self.sampleRate = sampleRate
        self.isSampleRateStable = isSampleRateStable
        self.inputLatencySeconds = inputLatencySeconds
        self.measuredNoiseFloorDBFS = measuredNoiseFloorDBFS
        self.measuredPeakDBFS = measuredPeakDBFS
        self.measuredSpeechRMSDBFS = measuredSpeechRMSDBFS
    }
}
