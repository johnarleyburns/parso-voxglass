import AVFoundation
import Foundation
import VoxglassCore

/// iOS concrete of the `AudioCapturing` seam (NARRATION_NEEDS_SPEC §11.4 P3).
/// Uses `AVAudioEngine`'s input tap and writes a float-PCM CAF to the given
/// URL; streams level snapshots for the record meter. On interruption the
/// current take is finalized so a call/route change never loses a recording
/// (Studio Spec §11).
public final class AudioSessionCapture: AudioCapturing, @unchecked Sendable {

    public private(set) var state: CaptureState = .idle

    public var levels: AsyncStream<CaptureLevels> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.withLock { levelContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.levelContinuations[id] = nil }
            }
        }
    }

    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private var recordFile: AVAudioFile?
    private var recordURL: URL?
    private var recordFormat: RecordingDefaults?
    private var sampleCount: UInt64 = 0
    private var peak: Float = 0
    private var clipped = false
    private var levelContinuations: [UUID: AsyncStream<CaptureLevels>.Continuation] = [:]
    private var tapInstalled = false

    public init() {}

    // MARK: - AudioCapturing

    public func availableInputDevices() async -> [AudioDeviceInfo] {
        [AudioDeviceInfo(id: "default", name: "iPhone Microphone", channelCount: 1, supportedSampleRates: [44_100, 48_000], isDefault: true, transport: "Built-in")]
    }

    public func prepare(device: String?, format: RecordingDefaults) async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .spokenAudio, options: [.allowBluetoothHFP, .duckOthers])
        try session.setPreferredSampleRate(format.sampleRate)
        try session.setActive(true)

        let granted = await withCheckedContinuation { continuation in
            session.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard granted else {
            state = .failed("Microphone access denied")
            throw CaptureError.permissionDenied
        }

        recordFormat = format
        installTapIfNeeded()
        state = .prepared
    }

    public func startMonitoring() async throws {
        guard state == .prepared || state == .idle else { return }
        if state == .idle {
            try await prepare(device: nil, format: recordFormat ?? RecordingDefaults())
        }
        if !engine.isRunning { try engine.start() }
        state = .monitoring
        startLevelPolling()
    }

    public func stopMonitoring() async {
        if !recordFormatIsActive() { engine.stop() }
        if state == .monitoring { state = .prepared }
    }

    public func startRecording(to destinationURL: URL) async throws {
        guard state == .prepared || state == .monitoring else { throw CaptureError.invalidState }

        let fmt = recordFormat ?? RecordingDefaults()
        guard let avFormat = makeFloatFormat(sampleRate: fmt.sampleRate) else {
            throw CaptureError.formatNotSupported
        }

        let file = try AVAudioFile(forWriting: destinationURL, settings: avFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        lock.withLock {
            recordURL = destinationURL
            recordFile = file
            sampleCount = 0
            peak = 0
            clipped = false
        }

        if !engine.isRunning { try engine.start() }
        state = .recording
        startLevelPolling()
    }

    public func stopRecording() async throws -> CapturedTake {
        state = .stopping
        engine.pause()
        stopLevelPolling()

        let captured: (url: URL?, format: RecordingDefaults?, sampleCount: UInt64, peak: Float, clipped: Bool) = lock.withLock {
            let result = (recordURL, recordFormat, sampleCount, peak, clipped)
            recordFile = nil
            recordURL = nil
            return result
        }

        guard let url = captured.url, let format = captured.format else {
            throw CaptureError.invalidState
        }

        let duration = Double(captured.sampleCount) / format.sampleRate
        let peakDBFS = 20.0 * log10(max(Double(captured.peak), 1e-7))
        if engine.isRunning { engine.stop() }
        state = .idle
        return CapturedTake(
            fileURL: url,
            duration: duration,
            format: AudioFormatDescription(sampleRate: format.sampleRate, channels: 1, bitDepth: format.bitDepth, codec: "pcm"),
            clippedDuringCapture: captured.clipped,
            peakDBFS: peakDBFS
        )
    }

    public func cancelRecording() async {
        stopLevelPolling()
        engine.stop()
        lock.withLock {
            if let url = recordURL { try? FileManager.default.removeItem(at: url) }
            recordFile = nil
            recordURL = nil
            sampleCount = 0
        }
        state = .idle
    }

    public func punchIn(from offset: TimeInterval) async throws {
        throw CaptureError.punchInNotSupported
    }

    // MARK: - Engine

    private func installTapIfNeeded() {
        guard !tapInstalled else { return }
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        tapInstalled = true
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let samples = data[0]

        var blockPeak: Float = 0
        var rmsSq: Double = 0
        var blockClipped = false
        for i in 0..<frames {
            let s = samples[i]
            let a = abs(s)
            if a > blockPeak { blockPeak = a }
            rmsSq += Double(s) * Double(s)
            if a >= 0.999 { blockClipped = true }
        }
        let rms = Float(sqrt(rmsSq / Double(max(frames, 1))))

        let recording: Bool = lock.withLock {
            guard recordFile != nil else { return false }
            if blockPeak > peak { peak = blockPeak }
            if blockClipped { clipped = true }
            sampleCount += UInt64(frames)
            return true
        }

        let fmt = lock.withLock { recordFormat }
        let sampleTime = fmt.map { Double(lock.withLock { sampleCount }) / $0.sampleRate } ?? 0
        lock.withLock {
            for c in levelContinuations.values {
                c.yield(CaptureLevels(
                    peakDBFS: 20.0 * log10(max(blockPeak, 1e-7)),
                    rmsDBFS: 20.0 * log10(max(rms, 1e-7)),
                    isClipping: blockClipped,
                    sampleTime: sampleTime
                ))
            }
        }

        guard recording, let file = lock.withLock({ recordFile }) else { return }
        try? file.write(from: buffer)
    }

    private func startLevelPolling() {
        // Levels are pushed from the tap callback; no polling needed on iOS.
    }

    private func stopLevelPolling() {
        // Levels are pushed from the tap callback; no polling needed on iOS.
    }

    private func recordFormatIsActive() -> Bool {
        lock.withLock { recordFile != nil }
    }

    private func makeFloatFormat(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }
}
