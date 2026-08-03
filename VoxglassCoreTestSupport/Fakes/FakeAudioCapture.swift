import Foundation
import VoxglassCore

public enum FakeCaptureError: Error, Equatable {
    case permissionDenied
    case diskFull
    case deviceDisappeared
    case invalidState
}

/// Scripted `AudioCapturing` for the S5 recording-flow tests.
///
/// - Builds a real WAV at the requested destination on `startRecording`,
///   so takes moved into an asset store have real `sha256` / `byteCount`.
/// - Yields a scripted level stream (~30 Hz) while recording, so the meter and
///   teleprompter see live updates without hardware.
/// - Injectable failures: permission denied (`permissionDenied`), disk full on
///   start (`diskFullOnStart`), device disappearing mid-take
///   (`deviceDisappearsOnStop`), and `stopRecording` without `startRecording`
///   (always throws `.invalidState`).
public final class FakeAudioCapture: AudioCapturing, @unchecked Sendable {

    public var permissionDenied = false
    public var diskFullOnStart = false
    public var deviceDisappearsOnStop = false
    public var takeDuration: TimeInterval = 0.5
    public var takeAmplitude: Float = 0.25
    public var levelScript: [Float] = []
    public var levelRate: TimeInterval = 0.033

    public private(set) var state: CaptureState = .idle
    public private(set) var lastDestinationURL: URL?
    public private(set) var startRecordingCallCount = 0
    public private(set) var stopRecordingCallCount = 0
    public private(set) var peakDBFS: Double = -.infinity
    public private(set) var duration: TimeInterval = 0
    public private(set) var yieldCount = 0

    public var levels: AsyncStream<CaptureLevels> {
        let stream = AsyncStream<CaptureLevels>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            levelContinuationLock.withLock { levelContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.levelContinuationLock.withLock {
                    self.levelContinuations[id] = nil
                }
            }
        }
        return stream
    }

    private let levelContinuationLock = NSLock()
    private var levelContinuations: [UUID: AsyncStream<CaptureLevels>.Continuation] = [:]
    private var levelTask: Task<Void, Never>?
    private var recordedPeak: Float = 0

    public init() {}

    public func availableInputDevices() async -> [AudioDeviceInfo] {
        [AudioDeviceInfo(id: "fake-default", name: "Fake Built-In Microphone", channelCount: 1, supportedSampleRates: [48000], isDefault: true, transport: "Fake")]
    }

    public func prepare(device: String?, format: RecordingDefaults) async throws {
        if permissionDenied {
            state = .failed("Microphone access denied")
            throw FakeCaptureError.permissionDenied
        }
        state = .prepared
    }

    public func startMonitoring() async throws {
        state = .monitoring
        startLevelTask()
    }

    public func stopMonitoring() async {
        state = .prepared
    }

    public func startRecording(to destinationURL: URL) async throws {
        startRecordingCallCount += 1
        guard state == .prepared || state == .monitoring else {
            throw FakeCaptureError.invalidState
        }
        if diskFullOnStart {
            state = .failed("disk full")
            throw FakeCaptureError.diskFull
        }

        let amplitude = takeAmplitude
        try writeWAV(at: destinationURL, duration: takeDuration, amplitude: amplitude)

        lastDestinationURL = destinationURL
        recordedPeak = amplitude
        peakDBFS = 20.0 * log10(Double(max(amplitude, 1e-7)))
        duration = takeDuration
        state = .recording
        startLevelTask()
    }

    public func stopRecording() async throws -> CapturedTake {
        stopRecordingCallCount += 1
        guard state == .recording, let url = lastDestinationURL else {
            throw FakeCaptureError.invalidState
        }
        stopLevelTask()
        if deviceDisappearsOnStop {
            state = .idle
            throw FakeCaptureError.deviceDisappeared
        }
        let peak = recordedPeak
        let captured = CapturedTake(
            fileURL: url,
            duration: duration,
            format: AudioFormatDescription(sampleRate: 48_000, channels: 1, bitDepth: 16, codec: "pcm"),
            clippedDuringCapture: peak >= 0.999,
            peakDBFS: 20.0 * log10(Double(max(peak, 1e-7)))
        )
        state = .idle
        return captured
    }

    public func cancelRecording() async {
        stopLevelTask()
        if let url = lastDestinationURL {
            try? FileManager.default.removeItem(at: url)
        }
        lastDestinationURL = nil
        state = .idle
    }

    public func punchIn(from offset: TimeInterval) async throws {
        throw FakeCaptureError.invalidState
    }

    // MARK: - Levels

    private func startLevelTask() {
        guard levelTask == nil else { return }
        let rate = max(levelRate, 0.005)
        let script = levelScript.isEmpty ? nil : levelScript
        let amplitude = takeAmplitude
        levelTask = Task { [weak self] in
            var t: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(rate))
                guard let self else { return }
                let level: Float
                if let script, !script.isEmpty {
                    level = script[Int((t / rate).truncatingRemainder(dividingBy: Double(script.count)))]
                } else {
                    level = amplitude
                }
                let levels = CaptureLevels(
                    peakDBFS: 20.0 * log10(max(level, 1e-7)),
                    rmsDBFS: 20.0 * log10(max(level / sqrt(2), 1e-7)),
                    isClipping: level >= 0.999,
                    sampleTime: t
                )
                self.levelContinuationLock.withLock {
                    for (_, continuation) in self.levelContinuations {
                        continuation.yield(levels)
                    }
                    self.yieldCount += 1
                }
                t += rate
            }
        }
    }

    private func stopLevelTask() {
        levelTask?.cancel()
        levelTask = nil
    }

    // MARK: - WAV synthesis

    private func writeWAV(at url: URL, duration: TimeInterval, amplitude: Float) throws {
        let sampleRate = 48_000
        let frameCount = Int(Double(sampleRate) * duration)
        var data = Data(capacity: 44 + frameCount * 2)

        func append(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
        func appendLE32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendLE16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        append(Array("RIFF".utf8))
        appendLE32(UInt32(36 + frameCount * 2))
        append(Array("WAVE".utf8))
        append(Array("fmt ".utf8))
        appendLE32(16)
        appendLE16(1)                       // PCM
        appendLE16(1)                       // mono
        appendLE32(UInt32(sampleRate))
        appendLE32(UInt32(sampleRate * 2))  // byte rate
        appendLE16(2)                       // block align
        appendLE16(16)                      // bits per sample
        append(Array("data".utf8))
        appendLE32(UInt32(frameCount * 2))

        for i in 0..<frameCount {
            let value = Int16((Double(amplitude) * sin(2.0 * .pi * 440.0 * Double(i) / Double(sampleRate)) * 32767.0).rounded())
            appendLE16(UInt16(bitPattern: value))
        }

        try data.write(to: url, options: .atomic)
    }
}
