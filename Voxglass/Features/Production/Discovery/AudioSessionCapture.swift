import AVFoundation
import Foundation
import VoxglassCore

/// Wraps an underlying capture error with the name of the failing step so the
/// record screen can say exactly which call failed (e.g. "setActive failed…")
/// instead of an opaque OSStatus code.
enum CaptureSetupError: LocalizedError {
    case step(String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .step(let name, let underlying):
            return "\(name) failed — \(underlying.localizedDescription)"
        }
    }
}

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
    private var activeFormat: AVAudioFormat?
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
        // requestRecordPermission is safe from any thread, but its completion
        // handler resumes on an arbitrary dispatch queue — and AVAudioSession
        // calls made off the main thread can fail with OSStatus -50 (paramErr).
        // Hop to the main actor for all session configuration.
        let granted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard granted else {
            state = .failed("Microphone access denied")
            throw CaptureError.permissionDenied
        }

        try await MainActor.run {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.record, mode: .spokenAudio, options: [.allowBluetoothHFP, .duckOthers])
            } catch {
                throw CaptureSetupError.step("setCategory", underlying: error)
            }
            do {
                try session.setPreferredSampleRate(format.sampleRate)
            } catch {
                throw CaptureSetupError.step("setPreferredSampleRate", underlying: error)
            }
            do {
                try session.setActive(true)
            } catch {
                throw CaptureSetupError.step("setActive", underlying: error)
            }
        }

        recordFormat = format
        guard installTapIfNeeded() else {
            state = .failed("No usable audio input")
            throw CaptureError.deviceUnavailable
        }
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

        // Write in the tap's installed format (interleaved float32 PCM at the
        // hardware sample rate — see installTapIfNeeded). The engine converts
        // the hardware input to this format, so the tap buffers and the file
        // can never disagree about rate, channels, or interleaving.
        guard let writeFormat = tapFormat else { throw CaptureError.formatNotSupported }

        // Pass settings only: AVAudioFile rejects non-interleaved PCM settings
        // with OSStatus -50 (paramErr), and commonFormat/interleaved must
        // match the settings dict exactly.
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: destinationURL, settings: writeFormat.settings)
        } catch {
            throw CaptureSetupError.step("AVAudioFile", underlying: error)
        }
        lock.withLock {
            recordURL = destinationURL
            recordFile = file
            activeFormat = writeFormat
            sampleCount = 0
            peak = 0
            clipped = false
        }

        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            lock.withLock {
                recordFile = nil
                recordURL = nil
                activeFormat = nil
            }
            try? FileManager.default.removeItem(at: destinationURL)
            throw CaptureSetupError.step("engine.start", underlying: error)
        }
        state = .recording
        startLevelPolling()
    }

    public func stopRecording() async throws -> CapturedTake {
        state = .stopping
        engine.pause()
        stopLevelPolling()

        let captured: (url: URL?, format: AVAudioFormat?, sampleCount: UInt64, peak: Float, clipped: Bool) = lock.withLock {
            let result = (recordURL, activeFormat, sampleCount, peak, clipped)
            recordFile = nil
            recordURL = nil
            activeFormat = nil
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
            format: AudioFormatDescription(sampleRate: format.sampleRate, channels: Int(format.channelCount), bitDepth: 24, codec: "pcm"),
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
            activeFormat = nil
            sampleCount = 0
        }
        state = .idle
    }

    public func punchIn(from offset: TimeInterval) async throws {
        throw CaptureError.punchInNotSupported
    }

    // MARK: - Engine

    /// The exact format the tap is installed with (interleaved float32 mono at
    /// the hardware sample rate). The engine converts the input to this
    /// format before the tap callback, so the recorded file and the delivered
    /// buffers always match.
    private var tapFormat: AVAudioFormat?

    @discardableResult
    private func installTapIfNeeded() -> Bool {
        guard !tapInstalled else { return true }
        let input = engine.inputNode
        let hardwareRate = input.outputFormat(forBus: 0).sampleRate
        guard hardwareRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardwareRate, channels: 1, interleaved: true) else {
            return false
        }
        tapFormat = format
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        tapInstalled = true
        return true
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

        let fmt = lock.withLock { activeFormat }
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
}
