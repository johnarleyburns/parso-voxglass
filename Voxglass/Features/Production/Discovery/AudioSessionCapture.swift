import AVFoundation
import Foundation
import UIKit
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

/// iOS concrete of the `AudioCapturing` seam (spec §7.2–§7.4). The audio tap
/// is the single producer of a lock-free `CaptureRingBuffer`; a writer task is
/// the single consumer that drains into `Autosave/takes/<uuid>.wav`. The tap
/// body therefore obeys the real-time discipline the spec and CI review for:
/// no allocation, no lock, no `Task`, no `os_log`, no `Date()`.
///
/// Interruption handling (spec §7.4) lives here as *detection*: the capture
/// observes `AVAudioSession` interruption/route notifications and app
/// lifecycle, and forwards a `CaptureInterruptionReason` to `onInterruption`
/// while recording. The owning flow calls `CaptureRecovery.handleInFlightInterruption`
/// to stop, finalize, and recover the take.
///
/// Recording requests 48 kHz / 24-bit mono PCM (§7.3); if the hardware or
/// `AVAudioFile` refuses the requested format, the actual hardware format is
/// recorded and preserved in the take's metadata. A take is never failed to
/// satisfy a preference.
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

    /// The route currently in use, snapshotted from `AVAudioSession` at
    /// `prepare` and again at `startRecording` so a take records the route it
    /// was made on (spec §7.1).
    public private(set) var currentRouteInfo = CaptureRouteInfo()

    /// Set by the owning flow to receive in-flight interruption causes.
    /// Called on the main queue (or the writer task for disk pressure).
    public var onInterruption: ((CaptureInterruptionReason) -> Void)?
    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private let writeSemaphore = DispatchSemaphore(value: 0)
    private var ring: CaptureRingBuffer?
    private var recordFile: AVAudioFile?
    private var recordURL: URL?
    private var recordFormat: RecordingDefaults?
    private var activeFormat: AVAudioFormat?
    private var tapFormat: AVAudioFormat?
    private var recordedBitDepth: Int?
    private var sampleCount: UInt64 = 0
    private var peak: Float = 0
    private var clipped = false
    private var writeFailed = false
    private var levelContinuations: [UUID: AsyncStream<CaptureLevels>.Continuation] = [:]
    private var tapInstalled = false
    private var writerTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    public init() {
        registerNotifications()
    }

    deinit {
        writerTask?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - AudioCapturing

    public func availableInputDevices() async -> [AudioDeviceInfo] {
        [AudioDeviceInfo(id: "default", name: "iPhone Microphone", channelCount: 1, supportedSampleRates: [44_100, 48_000], isDefault: true, transport: "Built-in")]
    }

    public func prepare(device: String?, format: RecordingDefaults) async throws {
        // requestRecordPermission is safe from any thread, but its completion
        // handler resumes on an arbitrary dispatch queue — and AVAudioSession
        // calls made off the main thread can fail with OSStatus -50 (paramErr).
        // Hop to the main actor for all session configuration.
        let granted: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            granted = true
        case .denied:
            granted = false
        case .undetermined:
            granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            granted = false
        }
        guard granted else {
            state = .failed("Microphone access denied")
            throw CaptureError.permissionDenied
        }

        try await MainActor.run {
            let session = AVAudioSession.sharedInstance()
            // The player can leave the session ACTIVE with .playback; on
            // recent iOS an active session can reject a category change with
            // OSStatus -50 (paramErr). Release it before reconfiguring.
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            do {
                try session.setCategory(.record, mode: .spokenAudio, options: [.duckOthers])
            } catch {
                // Some iOS versions reject the full configuration; fall back
                // to the bare record category so narration always records.
                do {
                    try session.setCategory(.record)
                } catch {
                    throw CaptureSetupError.step("setCategory", underlying: error)
                }
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
        snapshotRoute()
        state = .prepared
    }

    public func startMonitoring() async throws {
        guard state == .prepared || state == .idle else { return }
        if state == .idle {
            try await prepare(device: nil, format: recordFormat ?? RecordingDefaults())
        }
        if !engine.isRunning { try engine.start() }
        state = .monitoring
    }

    public func stopMonitoring() async {
        if !recordFormatIsActive() { engine.stop() }
        if state == .monitoring { state = .prepared }
    }

    public func startRecording(to destinationURL: URL) async throws {
        guard state == .prepared || state == .monitoring else { throw CaptureError.invalidState }

        // Write in the tap's installed format (float32 PCM mono at the
        // hardware sample rate — see installTapIfNeeded). The engine converts
        // the hardware input to this format, so the tap buffers and the file
        // can never disagree about rate, channels, or interleaving.
        guard let writeFormat = tapFormat else { throw CaptureError.formatNotSupported }

        // Pass settings only: AVAudioFile rejects non-interleaved PCM settings
        // with OSStatus -50 (paramErr), and commonFormat/interleaved must
        // match the settings dict exactly. Request the 24-bit PCM capture
        // format (§7.3); fall back to the tap's float32 format if the
        // converter refuses 24-bit — never fail a take to satisfy a
        // preference.
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: destinationURL, settings: requestedSettings(rate: writeFormat.sampleRate))
        } catch {
            do {
                file = try AVAudioFile(forWriting: destinationURL, settings: writeFormat.settings)
            } catch {
                throw CaptureSetupError.step("AVAudioFile", underlying: error)
            }
        }
        let fileBitDepth = (file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int) ?? 24

        let ring = CaptureRingBuffer(capacity: Int(writeFormat.sampleRate * 2)) // ~2 s headroom
        lock.withLock {
            recordURL = destinationURL
            recordFile = file
            activeFormat = writeFormat
            recordedBitDepth = fileBitDepth
            sampleCount = 0
            peak = 0
            clipped = false
            writeFailed = false
            self.ring = ring
        }
        snapshotRoute()

        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            lock.withLock {
                recordFile = nil
                recordURL = nil
                activeFormat = nil
                self.ring = nil
            }
            try? FileManager.default.removeItem(at: destinationURL)
            throw CaptureSetupError.step("engine.start", underlying: error)
        }
        state = .recording
        startWriter(file: file, format: writeFormat, ring: ring)
    }

    public func stopRecording() async throws -> CapturedTake {
        state = .stopping
        engine.pause()

        // Let the writer drain everything the tap already delivered, then stop.
        writerTask?.cancel()
        if let task = writerTask {
            await task.value
        }
        writerTask = nil

        let teardown: (url: URL?, format: AVAudioFormat?, file: AVAudioFile?, bitDepth: Int?, sampleCount: UInt64, peak: Float, clipped: Bool, failed: Bool) = lock.withLock {
            let result: (URL?, AVAudioFormat?, AVAudioFile?, Int?, UInt64, Float, Bool, Bool) =
                (recordURL, activeFormat, recordFile, recordedBitDepth, sampleCount, peak, clipped, writeFailed)
            recordFile = nil
            recordURL = nil
            activeFormat = nil
            recordedBitDepth = nil
            ring = nil
            return (url: result.0, format: result.1, file: result.2, bitDepth: result.3, sampleCount: result.4, peak: result.5, clipped: result.6, failed: result.7)
        }

        guard let url = teardown.url, let format = teardown.format, let file = teardown.file else {
            state = .idle
            throw CaptureError.invalidState
        }

        if teardown.failed {
            // The writer died mid-take (disk pressure). Leave the file for
            // WAVHeaderRepair and let CaptureRecovery recover the partial take.
            state = .idle
            throw CaptureError.diskFull
        }

        // Finalize the header so the take is a clean file on normal stop.
        // iOS 18+ closes explicitly; on iOS 17 AVAudioFile finalizes the
        // header on deinit, which happens the moment the writer task and this
        // local reference both release the object — a crash is the only way a
        // stale header survives (WAVHeaderRepair covers that case).
        if #available(iOS 18.0, *) {
            file.close()
        }
        let duration = Double(teardown.sampleCount) / format.sampleRate
        let peakDBFS = 20.0 * log10(max(Double(teardown.peak), 1e-7))
        if engine.isRunning { engine.stop() }
        state = .idle
        return CapturedTake(
            fileURL: url,
            duration: duration,
            format: AudioFormatDescription(
                sampleRate: format.sampleRate,
                channels: Int(format.channelCount),
                bitDepth: teardown.bitDepth,
                codec: "pcm"
            ),
            clippedDuringCapture: teardown.clipped,
            peakDBFS: peakDBFS
        )
    }

    public func cancelRecording() async {
        state = .stopping
        engine.pause()
        writerTask?.cancel()
        if let task = writerTask { await task.value }
        writerTask = nil
        lock.withLock {
            if let url = recordURL { try? FileManager.default.removeItem(at: url) }
            recordFile = nil
            recordURL = nil
            activeFormat = nil
            recordedBitDepth = nil
            ring = nil
            sampleCount = 0
        }
        if engine.isRunning { engine.stop() }
        state = .idle
    }

    public func punchIn(from offset: TimeInterval) async throws {
        throw CaptureError.punchInNotSupported
    }

    // MARK: - Engine

    /// The 24-bit PCM capture format requested by §7.3, at the given rate.
    /// Falls back through the tap format's own settings when a converter
    /// rejects 24-bit.
    private func requestedSettings(rate: Double) -> [String: Any] {
        let preferredBitDepth = recordFormat?.bitDepth ?? 24
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: preferredBitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

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
            self?.tap(buffer)
        }
        tapInstalled = true
        return true
    }

    /// Real-time thread. Pushes frames into the lock-free ring and signals the
    /// writer. No allocation, no lock, no `Task`, no `os_log`, no `Date()`.
    private func tap(_ buffer: AVAudioPCMBuffer) {
        guard let ring, let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let samples = UnsafeBufferPointer(start: data[0], count: frames)
        ring.push(samples)
        writeSemaphore.signal()
    }

    /// The writer task: drains the ring and writes into the record file,
    /// computes the level stream, and surfaces disk pressure as an
    /// interruption. Not real-time, so allocation is allowed here.
    private func startWriter(file: AVAudioFile, format: AVAudioFormat, ring: CaptureRingBuffer) {
        writerTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var scratch = [Float](repeating: 0, count: 4096)
            while !Task.isCancelled {
                let drained = scratch.withUnsafeMutableBufferPointer { ring.pop(into: $0) }
                if drained > 0 {
                    var blockPeak: Float = 0
                    var rmsSq: Double = 0
                    var blockClipped = false
                    for i in 0..<drained {
                        let s = scratch[i]
                        let a = abs(s)
                        if a > blockPeak { blockPeak = a }
                        rmsSq += Double(s) * Double(s)
                        if a >= 0.999 { blockClipped = true }
                    }
                    let frames = AVAudioFrameCount(drained)
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                        self.setWriteFailure()
                        break
                    }
                    buffer.frameLength = frames
                    if let dst = buffer.floatChannelData?[0] {
                        scratch.withUnsafeBufferPointer { src in
                            dst.update(from: src.baseAddress!, count: drained)
                        }
                    }
                    do {
                        try file.write(from: buffer)
                    } catch {
                        self.setWriteFailure()
                        break
                    }
                    let rms = Float(sqrt(rmsSq / Double(max(drained, 1))))
                    let sampleTime: TimeInterval = self.lock.withLock {
                        self.sampleCount += UInt64(drained)
                        if blockPeak > self.peak { self.peak = blockPeak }
                        if blockClipped { self.clipped = true }
                        return Double(self.sampleCount) / format.sampleRate
                    }
                    self.lock.withLock {
                        for continuation in self.levelContinuations.values {
                            continuation.yield(CaptureLevels(
                                peakDBFS: 20.0 * log10(max(blockPeak, 1e-7)),
                                rmsDBFS: 20.0 * log10(max(rms, 1e-7)),
                                isClipping: blockClipped,
                                sampleTime: sampleTime
                            ))
                        }
                    }
                } else {
                    // Nothing to write; wait for the tap or cancellation.
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
    }

    private func setWriteFailure() {
        let alreadyFailed = lock.withLock { () -> Bool in
            defer { writeFailed = true }
            return writeFailed
        }
        if !alreadyFailed {
            onInterruption?(.diskPressure)
        }
    }

    // MARK: - Route

    private func snapshotRoute() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        var transports: Set<CapturePortTransport> = []
        for port in route.inputs {
            switch port.portType {
            case .usbAudio: transports.insert(.usb)
            case .headsetMic, .headphones: transports.insert(.wiredHeadset)
            case .builtInMic: transports.insert(.builtIn)
            case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: transports.insert(.bluetooth)
            case .airPlay: transports.insert(.airPlay)
            default: transports.insert(.other)
            }
        }
        let hardwareRate = engine.inputNode.outputFormat(forBus: 0).sampleRate
        currentRouteInfo = CaptureRouteInfo(
            transports: transports.isEmpty ? [.other] : transports,
            sampleRate: hardwareRate,
            isSampleRateStable: true,
            inputLatencySeconds: session.inputLatency,
            measuredNoiseFloorDBFS: nil,
            measuredPeakDBFS: nil,
            measuredSpeechRMSDBFS: nil
        )
    }

    // MARK: - Interruption detection (spec §7.4)

    private func registerNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            switch type {
            case .began:
                self?.forward(.phoneCallOrSystem)
            case .ended:
                break
            @unknown default:
                break
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.handleRouteChange(note)
        })
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.forward(.backgroundedOrLocked)
        })
    }

    private func handleRouteChange(_ note: Notification) {
        snapshotRoute()
        let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = reasonValue.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        if let oldRoute = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
            let hadUSB = oldRoute.inputs.contains { $0.portType == .usbAudio }
            let hadHeadphones = oldRoute.inputs.contains { port in
                [.headsetMic, .headphones, .bluetoothA2DP, .bluetoothHFP].contains(port.portType)
            }
            if reason == .oldDeviceUnavailable {
                if hadUSB { forward(.deviceUnplugged) }
                else if hadHeadphones { forward(.headphonesRemoved) }
                else { forward(.routeChanged) }
                return
            }
        }
        forward(.routeChanged)
    }

    private func forward(_ reason: CaptureInterruptionReason) {
        guard state == .recording else { return }
        onInterruption?(reason)
    }

    // MARK: - State helpers

    private func recordFormatIsActive() -> Bool {
        lock.withLock { recordFile != nil }
    }
}
