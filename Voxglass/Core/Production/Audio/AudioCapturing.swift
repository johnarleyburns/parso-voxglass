import Foundation

public protocol AudioCapturing: AnyObject, Sendable {
    var state: CaptureState { get }
    var levels: AsyncStream<CaptureLevels> { get }
    /// The route the capture is using, fed by the app from
    /// `AVAudioSession.currentRoute` (spec §7.1). Snapshotted at `prepare` and
    /// again at `startRecording` so a take can record the route it was made on.
    var currentRouteInfo: CaptureRouteInfo { get }
    /// Set by the owning flow to receive in-flight interruption causes while
    /// recording (spec §7.4). The concrete observes `AVAudioSession` route /
    /// interruption notifications and app lifecycle and forwards the cause.
    var onInterruption: ((CaptureInterruptionReason) -> Void)? { get set }
    func availableInputDevices() async -> [AudioDeviceInfo]
    func prepare(device: String?, format: RecordingDefaults) async throws
    func startMonitoring() async throws
    func stopMonitoring() async
    func startRecording(to destinationURL: URL) async throws
    func stopRecording() async throws -> CapturedTake
    func cancelRecording() async
    func punchIn(from offset: TimeInterval) async throws
}

public enum CaptureState: Sendable, Equatable {
    case idle
    case prepared
    case monitoring
    case recording
    case stopping
    case failed(String)
}

public struct CaptureLevels: Sendable, Equatable {
    public var peakDBFS: Float
    public var rmsDBFS: Float
    public var isClipping: Bool
    public var sampleTime: TimeInterval
    /// A coarse, log-spaced magnitude spectrum (roughly 60 Hz–8 kHz, in dB)
    /// for a live "mic check" frequency display. Empty when the producer
    /// didn't compute one for this block (e.g. too few samples).
    public var bandMagnitudesDB: [Float]

    public init(peakDBFS: Float, rmsDBFS: Float, isClipping: Bool, sampleTime: TimeInterval, bandMagnitudesDB: [Float] = []) {
        self.peakDBFS = peakDBFS
        self.rmsDBFS = rmsDBFS
        self.isClipping = isClipping
        self.sampleTime = sampleTime
        self.bandMagnitudesDB = bandMagnitudesDB
    }
}

public struct CapturedTake: Sendable, Equatable {
    public var fileURL: URL
    public var duration: TimeInterval
    public var format: AudioFormatDescription
    public var clippedDuringCapture: Bool
    public var peakDBFS: Double

    public init(fileURL: URL, duration: TimeInterval, format: AudioFormatDescription, clippedDuringCapture: Bool, peakDBFS: Double) {
        self.fileURL = fileURL
        self.duration = duration
        self.format = format
        self.clippedDuringCapture = clippedDuringCapture
        self.peakDBFS = peakDBFS
    }
}

public struct AudioDeviceInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var channelCount: Int
    public var supportedSampleRates: [Double]
    public var isDefault: Bool
    public var transport: String

    public init(id: String, name: String, channelCount: Int, supportedSampleRates: [Double], isDefault: Bool, transport: String) {
        self.id = id
        self.name = name
        self.channelCount = channelCount
        self.supportedSampleRates = supportedSampleRates
        self.isDefault = isDefault
        self.transport = transport
    }
}

public enum CaptureError: Error, Equatable, LocalizedError {
    case permissionDenied
    case invalidState
    case formatNotSupported
    case deviceUnavailable
    case punchInNotSupported
    case deviceChanged(name: String)
    case diskFull

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "Microphone access is denied.", bundle: .module)
        case .invalidState:
            return String(localized: "The audio recorder is not ready.", bundle: .module)
        case .formatNotSupported:
            return String(localized: "The current microphone format is not supported.", bundle: .module)
        case .deviceUnavailable:
            return String(localized: "No usable microphone is available.", bundle: .module)
        case .punchInNotSupported:
            return String(localized: "Punch-in recording is not supported.", bundle: .module)
        case .deviceChanged(let name):
            return String(localized: "The recording device changed to \(name).", bundle: .module)
        case .diskFull:
            return String(localized: "There is not enough storage space to save the recording.", bundle: .module)
        }
    }
}
