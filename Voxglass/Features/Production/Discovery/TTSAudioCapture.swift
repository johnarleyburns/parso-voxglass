#if DEBUG
import AVFoundation
import Foundation
import VoxglassCore

/// Test-only scripting seam used by the hosted narration harness.
protocol TestCaptureScripting: AnyObject {
    func stage(text: String)
}

/// Renders staged text with the simulator's built-in Apple voice and writes a
/// real mono 48 kHz, 24-bit WAV through the same ingestion path as a microphone
/// take. It is never selected by a shipping build.
final class TTSAudioCapture: AudioCapturing, TestCaptureScripting, @unchecked Sendable {
    private(set) var state: CaptureState = .idle
    let levels: AsyncStream<CaptureLevels> = AsyncStream { $0.finish() }
    private(set) var currentRouteInfo = CaptureRouteInfo(
        transports: [.builtIn], sampleRate: 48_000, isSampleRateStable: true, inputLatencySeconds: 0
    )
    var onInterruption: ((CaptureInterruptionReason) -> Void)?

    private let lock = NSLock()
    private var stagedText = ""
    private var destinationURL: URL?
    private var capturedDuration: TimeInterval = 0
    private var capturedPeak: Double = -60
    private var synthesizer: AVSpeechSynthesizer?

    func stage(text: String) {
        lock.withLock { stagedText = text }
    }

    func availableInputDevices() async -> [AudioDeviceInfo] {
        [AudioDeviceInfo(id: "apple-tts", name: "Apple Speech Synthesis", channelCount: 1, supportedSampleRates: [48_000], isDefault: true, transport: "virtual")]
    }

    func prepare(device: String?, format: RecordingDefaults) async throws {
        state = .prepared
    }

    func startMonitoring() async throws { state = .monitoring }
    func stopMonitoring() async { state = .prepared }

    func startRecording(to destinationURL: URL) async throws {
        let text = lock.withLock { stagedText }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CaptureError.invalidState
        }
        state = .recording
        self.destinationURL = destinationURL

        let rendered = try await synthesize(text)
        let samples = Self.resample(rendered.samples, from: rendered.sampleRate, to: 48_000)
        try Self.writeWAV24(samples: samples, sampleRate: 48_000, to: destinationURL)
        capturedDuration = Double(samples.count) / 48_000
        let peak = samples.lazy.map { abs(Double($0)) }.max() ?? 0
        capturedPeak = peak > 0 ? 20 * log10(peak) : -60
    }

    func stopRecording() async throws -> CapturedTake {
        state = .prepared
        guard let destinationURL else { throw CaptureError.invalidState }
        return CapturedTake(
            fileURL: destinationURL,
            duration: capturedDuration,
            format: AudioFormatDescription(sampleRate: 48_000, channels: 1, bitDepth: 24, codec: "pcm"),
            clippedDuringCapture: capturedPeak >= -0.1,
            peakDBFS: capturedPeak
        )
    }

    func cancelRecording() async {
        synthesizer?.stopSpeaking(at: .immediate)
        state = .prepared
    }

    func punchIn(from offset: TimeInterval) async throws {
        throw CaptureError.punchInNotSupported
    }

    private func synthesize(_ text: String) async throws -> (samples: [Float], sampleRate: Double) {
        let box = SpeechSampleBox()
        let speech = AVSpeechSynthesizer()
        synthesizer = speech
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5

        return try await withCheckedThrowingContinuation { continuation in
            speech.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                guard pcm.frameLength > 0 else {
                    guard let result = box.finish() else { return }
                    if result.samples.isEmpty {
                        continuation.resume(throwing: CaptureError.invalidState)
                    } else {
                        continuation.resume(returning: result)
                    }
                    return
                }
                box.append(pcm)
            }
        }
    }

    private static func resample(_ input: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !input.isEmpty, sourceRate > 0, sourceRate != targetRate else { return input }
        let count = max(1, Int((Double(input.count) * targetRate / sourceRate).rounded()))
        return (0..<count).map { index in
            let position = Double(index) * sourceRate / targetRate
            let lower = min(Int(position), input.count - 1)
            let upper = min(lower + 1, input.count - 1)
            let fraction = Float(position - Double(lower))
            return input[lower] + (input[upper] - input[lower]) * fraction
        }
    }

    private static func writeWAV24(samples: [Float], sampleRate: Int, to url: URL) throws {
        let dataSize = UInt32(samples.count * 3)
        var data = Data("RIFF".utf8)
        data.appendLE(dataSize + 36)
        data.append(Data("WAVEfmt ".utf8))
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(1))
        data.appendLE(UInt32(sampleRate))
        data.appendLE(UInt32(sampleRate * 3))
        data.appendLE(UInt16(3))
        data.appendLE(UInt16(24))
        data.append(Data("data".utf8))
        data.appendLE(dataSize)
        for sample in samples {
            let value = Int32((max(-1, min(1, sample)) * 8_388_607).rounded())
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value >> 16))
        }
        try data.write(to: url, options: .atomic)
    }
}

private final class SpeechSampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 0
    private var didFinish = false

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            sampleRate = buffer.format.sampleRate
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            guard frames > 0, channels > 0 else { return }
            if let channelData = buffer.floatChannelData {
                for frame in 0..<frames {
                    var value: Float = 0
                    for channel in 0..<channels { value += channelData[channel][frame] }
                    samples.append(value / Float(channels))
                }
            } else if let channelData = buffer.int16ChannelData {
                for frame in 0..<frames {
                    var value: Float = 0
                    for channel in 0..<channels { value += Float(channelData[channel][frame]) / Float(Int16.max) }
                    samples.append(value / Float(channels))
                }
            }
        }
    }

    func finish() -> (samples: [Float], sampleRate: Double)? {
        lock.withLock {
            guard !didFinish else { return nil }
            didFinish = true
            return (samples, sampleRate)
        }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
#endif
