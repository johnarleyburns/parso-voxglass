import Foundation
import VoxglassCore

#if DEBUG

/// Scripted `AudioCapturing` for the iPhone smoke test (`-uiTestFakeCapture`).
/// Never touches a microphone — it writes a silent WAV so takes ingest and
/// play back cleanly, and recording state transitions match the real capture.
/// Mirrors the Studio's `UITestAudioCapture` (NARRATION_NEEDS_SPEC §12.3:
/// the iPhone flow runs end-to-end "via fake capture … with no network or
/// mic" — simulator audio input is unreliable since iOS 17).
final class UITestAudioCapture: AudioCapturing, @unchecked Sendable {
    private(set) var state: CaptureState = .idle
    let levels: AsyncStream<CaptureLevels>

    private var format = RecordingDefaults()
    private var lastDestinationURL: URL?

    init() {
        levels = AsyncStream { _ in }
    }

    func availableInputDevices() async -> [AudioDeviceInfo] {
        [AudioDeviceInfo(id: "ui-test-input", name: "UI Test Input", channelCount: 1, supportedSampleRates: [44_100, 48_000], isDefault: true, transport: "virtual")]
    }

    func prepare(device: String?, format: RecordingDefaults) async throws {
        self.format = format
        state = .prepared
    }

    func startMonitoring() async throws {
        state = .monitoring
    }

    func stopMonitoring() async {
        state = .prepared
    }

    func startRecording(to destinationURL: URL) async throws {
        state = .recording
        lastDestinationURL = destinationURL
        let sampleRate = Int(format.sampleRate)
        let frames = sampleRate * 2
        let dataSize = Int32(frames * 2)
        var wav = Data("RIFF".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: (dataSize + 36).littleEndian) { Data($0) })
        wav.append(Data("WAVE".utf8))
        wav.append(Data("fmt ".utf8))
        wav.append(contentsOf: withUnsafeBytes(of: Int32(16).littleEndian) { Data($0) })
        wav.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian) { Data($0) })
        wav.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian) { Data($0) })
        wav.append(contentsOf: withUnsafeBytes(of: Int32(sampleRate).littleEndian) { Data($0) })
        wav.append(contentsOf: withUnsafeBytes(of: Int32(sampleRate * 2).littleEndian) { Data($0) })
        wav.append(contentsOf: withUnsafeBytes(of: Int16(2).littleEndian) { Data($0) })
        wav.append(contentsOf: withUnsafeBytes(of: Int16(16).littleEndian) { Data($0) })
        wav.append(Data("data".utf8))
        wav.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        wav.append(Data(repeating: 0, count: frames * 2))
        try wav.write(to: destinationURL)
    }

    func stopRecording() async throws -> CapturedTake {
        state = .prepared
        return CapturedTake(
            fileURL: lastDestinationURL ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ui-test-take.wav"),
            duration: 2.0,
            format: AudioFormatDescription(sampleRate: format.sampleRate, channels: 1, bitDepth: format.bitDepth, codec: "pcm"),
            clippedDuringCapture: false,
            peakDBFS: -60
        )
    }

    func cancelRecording() async {
        state = .prepared
    }

    func punchIn(from offset: TimeInterval) async throws {
        throw CaptureError.punchInNotSupported
    }
}

#endif
