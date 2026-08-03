import Foundation

public protocol AudioCapturing: AnyObject, Sendable {
    var state: CaptureState { get }
    var levels: AsyncStream<CaptureLevels> { get }
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

    public init(peakDBFS: Float, rmsDBFS: Float, isClipping: Bool, sampleTime: TimeInterval) {
        self.peakDBFS = peakDBFS
        self.rmsDBFS = rmsDBFS
        self.isClipping = isClipping
        self.sampleTime = sampleTime
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

public enum CaptureError: Error, Equatable {
    case permissionDenied
    case invalidState
    case formatNotSupported
    case deviceUnavailable
    case punchInNotSupported
    case deviceChanged(name: String)
    case diskFull
}
