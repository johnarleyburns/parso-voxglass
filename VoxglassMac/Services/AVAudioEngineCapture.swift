import AppKit
import AVFoundation
import CoreAudio
import AudioToolbox
import Foundation
import os
import VoxglassCore

/// A finalized take the capture produced outside the normal stop path
/// (device change, system sleep, or a write failure such as a full disk).
public struct CaptureInterruption: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case deviceChanged(name: String)
        case sleep
        case diskFull
    }

    public let kind: Kind
    /// The take file the capture finalized before the interruption. Never nil
    /// for device-change/sleep; nil only when the write failed so early that
    /// no file exists.
    public let take: CapturedTake?

    public init(kind: Kind, take: CapturedTake?) {
        self.kind = kind
        self.take = take
    }
}

public final class AVAudioEngineCapture: AudioCapturing, @unchecked Sendable {

    public private(set) var state: CaptureState = .idle

    /// Fired when a take had to be finalized outside the normal stop path
    /// (spec §11.2 rule 6, rule 8). The take is complete and preserved.
    public var onInterruption: (@Sendable (CaptureInterruption) -> Void)?

    public var levels: AsyncStream<CaptureLevels> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            levelContinuationsLock.withLock { levelContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.removeContinuation(id: id)
            }
        }
    }

    private func removeContinuation(id: UUID) {
        levelContinuationsLock.withLock { levelContinuations[id] = nil }
    }

    private let engine = AVAudioEngine()
    private var inputNode: AVAudioInputNode { engine.inputNode }
    private var outputNode: AVAudioOutputNode { engine.outputNode }
    private var monitorMixer: AVAudioMixerNode?

    // Non-render capture state, guarded by stateLock.
    private let stateLock = OSAllocatedUnfairLock()
    private var recordFile: AVAudioFile?
    private var recordURL: URL?
    private var recordFormat: RecordingDefaults?
    private var writerError: Error?
    private var stopRequested = false
    private var currentInterruption: CaptureInterruption?

    private var monitoringActive = false
    private var levelContinuations: [UUID: AsyncStream<CaptureLevels>.Continuation] = [:]
    private let levelContinuationsLock = OSAllocatedUnfairLock()
    private var levelPoller: Task<Void, Never>?
    private var currentDeviceID: String?
    private var swappedDefaultDevice: AudioDeviceID = 0

    // Real-time path: the tap copies into the ring and updates the level
    // accumulators — nothing else (spec §11.2 rule 3). A detached writer task
    // drains the ring, converts, and writes the file (rule 1).
    private var ring: CaptureRingBuffer?
    private var levelsAccumulator = CaptureLevelAccumulator()
    private var writerTask: Task<Void, Never>?
    private var writerConverter: AVAudioConverter?
    private var writerOutputFormat: AVAudioFormat?
    private var writerInputBuffer: AVAudioPCMBuffer?
    private var writerOutputBuffer: AVAudioPCMBuffer?
    private var writerScratch: UnsafeMutablePointer<Float>?
    private var tapInstalled = false

    private var interruptionObservers: [NSObjectProtocol] = []

    public init() {
        installInterruptionObservers()
    }

    deinit {
        if let scratch = writerScratch {
            scratch.deallocate()
        }
        for observer in interruptionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    public func availableInputDevices() async -> [AudioDeviceInfo] {
        let devices = enumerateAudioDevices()
        let defaultID = defaultInputDeviceID()
        return devices.filter { $0.isInput }.map { device in
            AudioDeviceInfo(
                id: device.uid,
                name: device.name,
                channelCount: device.inputChannels,
                supportedSampleRates: device.sampleRates,
                isDefault: device.id == defaultID,
                transport: "Audio Device"
            )
        }
    }

    public func prepare(device: String?, format: RecordingDefaults) async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            state = .failed("Microphone access denied")
            throw CaptureError.permissionDenied
        }

        recordFormat = format
        currentDeviceID = device
        configureEngineSession()
        try configureInputFormat(format)

        // Ring sized to 4 seconds at the record format (§11.2 rule 4).
        let ringFrames = Int(format.sampleRate * 4.0)
        let ring = CaptureRingBuffer(capacityFrames: ringFrames)
        self.ring = ring
        ring.reset()
        levelsAccumulator.reset()

        installTapIfNeeded()
        state = .prepared
    }

    public func startMonitoring() async throws {
        guard state == .prepared || state == .idle else { return }

        if state == .idle {
            try await prepare(device: currentDeviceID, format: recordFormat ?? RecordingDefaults())
        }

        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        engine.connect(inputNode, to: mixer, format: inputNode.outputFormat(forBus: 0))
        engine.connect(mixer, to: outputNode, format: outputNode.outputFormat(forBus: 0))
        mixer.volume = 0
        monitorMixer = mixer

        if !engine.isRunning {
            try engine.start()
        }
        mixer.volume = 1
        monitoringActive = true
        state = .monitoring
        startLevelPolling()
    }

    public func stopMonitoring() async {
        if let mixer = monitorMixer {
            mixer.volume = 0
            engine.disconnectNodeOutput(mixer)
            engine.detach(mixer)
            monitorMixer = nil
        }
        monitoringActive = false
        if state == .monitoring { state = .prepared }
    }

    public func startRecording(to destinationURL: URL) async throws {
        guard state == .prepared || state == .monitoring else {
            throw CaptureError.invalidState
        }

        let fmt = recordFormat ?? RecordingDefaults()

        guard let avFmt = makeFloatFormat(sampleRate: fmt.sampleRate) else {
            throw CaptureError.formatNotSupported
        }

        let file = try AVAudioFile(forWriting: destinationURL, settings: avFmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        let tapFormat = inputNode.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            throw CaptureError.formatNotSupported
        }

        // The AVAudioConverter reconciles the hardware format with the file
        // format. If conversion is impossible the write fails loudly below;
        // we never silently produce a zero-length take.
        let converter = AVAudioConverter(from: tapFormat, to: avFmt)

        let inCapacity: AVAudioFrameCount = 16_384
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: inCapacity) else {
            throw CaptureError.formatNotSupported
        }
        let ratio = avFmt.sampleRate / tapFormat.sampleRate
        let outCapacity = max(AVAudioFrameCount(Double(inCapacity) * ratio) + 16, 1024)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: avFmt, frameCapacity: outCapacity) else {
            throw CaptureError.formatNotSupported
        }

        // Rebuild the ring on every take so the 4-second window starts empty
        // and overrun counts are per-take.
        let ring = CaptureRingBuffer(capacityFrames: Int(fmt.sampleRate * 4.0))
        self.ring = ring
        levelsAccumulator.reset()
        writerScratch?.deallocate()
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: Int(inCapacity))
        writerScratch = scratch

        stateLock.withLock {
            recordURL = destinationURL
            recordFile = file
            writerError = nil
            stopRequested = false
            currentInterruption = nil
        }
        writerConverter = converter
        writerOutputFormat = avFmt
        writerInputBuffer = inputBuffer
        writerOutputBuffer = outputBuffer

        if !engine.isRunning { try engine.start() }

        state = .recording
        startWriter()
        startLevelPolling()
    }

    public func stopRecording() async throws -> CapturedTake {
        state = .stopping

        let (take, error) = await finalizeTake()

        if let interruption = currentInterruption {
            // The take was already surfaced through onInterruption; rethrow the
            // mapped error so a subsequent stop does not appear successful.
            if case .deviceChanged(let name) = interruption.kind {
                throw CaptureError.deviceChanged(name: name)
            }
        }

        if let error { throw error }
        return take
    }

    public func cancelRecording() async {
        state = .stopping
        removeTap()
        stopWriter()
        stateLock.withLock {
            if let url = recordURL { try? FileManager.default.removeItem(at: url) }
            recordFile = nil
            recordURL = nil
            writerError = nil
            stopRequested = false
        }
        writerConverter = nil
        writerOutputFormat = nil
        writerInputBuffer = nil
        writerOutputBuffer = nil
        ring = nil
        restoreDefaultDeviceIfNeeded()
        stopLevelPolling()

        if !monitoringActive, engine.isRunning { engine.stop() }
        state = .idle
    }

    public func punchIn(from offset: TimeInterval) async throws {
        throw CaptureError.punchInNotSupported
    }

    /// The take finalized by an interruption (device change, sleep, disk
    /// full). Nil once the model has consumed it.
    public func consumeInterruptedTake() -> CapturedTake? {
        stateLock.withLock {
            let take = currentInterruption?.take
            currentInterruption = nil
            return take
        }
    }

    // MARK: - Interruptions (§11.2 rule 6, rule 8)

    private func installInterruptionObservers() {
        let configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.state == .recording else { return }
            let name = self.currentDefaultDeviceName() ?? "unknown device"
            self.handleInterruption(.deviceChanged(name: name))
        }
        interruptionObservers.append(configObserver)

        let sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.state == .recording else { return }
            self.handleInterruption(.sleep)
        }
        interruptionObservers.append(sleepObserver)
    }

    private func handleInterruption(_ kind: CaptureInterruption.Kind) {
        guard state == .recording else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let (take, error) = await self.finalizeTake()
            let interruption: CaptureInterruption
            if case .deviceChanged(let name) = kind {
                interruption = CaptureInterruption(kind: .deviceChanged(name: name), take: take)
            } else {
                interruption = CaptureInterruption(kind: kind, take: take)
            }
            self.stateLock.withLock { self.currentInterruption = interruption }
            self.state = .idle
            if let onInterruption = self.onInterruption {
                onInterruption(interruption)
            }
            _ = error // the take was preserved; the write error is surfaced via the banner
        }
    }

    // MARK: - Tap and writer

    private func installTapIfNeeded() {
        guard !tapInstalled else { return }
        guard let ring else { return }
        let hwFormat = inputNode.outputFormat(forBus: 0)
        let accumulator = levelsAccumulator
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [ring, accumulator] buffer, _ in
            // Real-time thread: copy floats in and update atomics. No
            // allocation, no lock, no dispatch, no os_log, no Date().
            ring.write(buffer)
            accumulator.accumulate(buffer)
        }
        tapInstalled = true
    }

    private func removeTap() {
        guard tapInstalled else { return }
        inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func startWriter() {
        writerTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.writerLoop()
        }
    }

    private func stopWriter() {
        stateLock.withLock { stopRequested = true }
        writerTask?.cancel()
        writerTask = nil
    }

    private func writerLoop() async {
        guard let scratch = writerScratch else { return }
        while !Task.isCancelled {
            guard let ring, let inputBuffer = writerInputBuffer,
                  let outputBuffer = writerOutputBuffer,
                  let converter = writerConverter,
                  let outFormat = writerOutputFormat else { break }

            let count = ring.drain(into: scratch, maxFrames: Int(inputBuffer.frameCapacity))
            if count > 0 {
                if let data = inputBuffer.floatChannelData {
                    data[0].update(from: scratch, count: count)
                }
                inputBuffer.frameLength = AVAudioFrameCount(count)
                writeChunk(inputBuffer, converter: converter, outFormat: outFormat, outputBuffer: outputBuffer)
            } else {
                let stop = stateLock.withLock { stopRequested }
                if stop && ring.framesAvailable() == 0 { break }
                try? await Task.sleep(nanoseconds: 3_000_000)
            }
        }
    }

    private func writeChunk(
        _ input: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outFormat: AVAudioFormat,
        outputBuffer: AVAudioPCMBuffer
    ) {
        let capture: (file: AVAudioFile?, error: Error?) = stateLock.withLock {
            (recordFile, writerError)
        }
        guard let file = capture.file else { return }

        let currentInput = ConverterInputBox(buffer: input)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if let b = currentInput.buffer, b.frameLength > 0 {
                let result = b
                currentInput.buffer = nil
                outStatus.pointee = .haveData
                return result
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        var convertError: NSError?
        var done = false
        while !done {
            outputBuffer.frameLength = 0
            let status = converter.convert(to: outputBuffer, error: &convertError, withInputFrom: inputBlock)
            if outputBuffer.frameLength > 0 {
                do {
                    try file.write(from: outputBuffer)
                } catch {
                    recordWriteFailure(error)
                    return
                }
            }
            switch status {
            case .haveData:
                done = false
            case .inputRanDry, .endOfStream:
                done = true
            case .error:
                recordWriteFailure(convertError ?? CaptureError.formatNotSupported)
                return
            @unknown default:
                done = true
            }
        }
    }

    private func recordWriteFailure(_ error: Error) {
        let mapped: Error
        if let ns = error as NSError?,
           ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
            mapped = CaptureError.diskFull
        } else {
            mapped = error
        }
        stateLock.withLock {
            if writerError == nil { writerError = mapped }
            stopRequested = true
        }
    }

    // MARK: - Finalize

    private func finalizeTake() async -> (CapturedTake, Error?) {
        removeTap()
        stateLock.withLock { stopRequested = true }

        if let task = writerTask {
            await task.value
            writerTask = nil
        }

        if !monitoringActive, engine.isRunning {
            engine.stop()
        }

        stopLevelPolling()
        restoreDefaultDeviceIfNeeded()

        let snapshot: (fileURL: URL?, format: RecordingDefaults?, error: Error?,
                       peak: Float, rms: Float, clipped: Bool, sampleCount: Int64, overruns: Int) = stateLock.withLock {
            let levels = levelsAccumulator.snapshot()
            let result = (
                fileURL: recordURL,
                format: recordFormat,
                error: writerError,
                peak: levels.peak,
                rms: levels.rms,
                clipped: levels.clipping,
                sampleCount: levels.frameCount,
                overruns: ring?.overrunCount() ?? 0
            )
            recordFile = nil
            recordURL = nil
            writerError = nil
            stopRequested = false
            return result
        }

        writerConverter = nil
        writerOutputFormat = nil
        writerInputBuffer = nil
        writerOutputBuffer = nil
        ring = nil

        guard let fileURL = snapshot.fileURL, let fmt = snapshot.format else {
            state = .idle
            return (CapturedTake(
                fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-take.wav"),
                duration: 0,
                format: AudioFormatDescription(
                    sampleRate: snapshot.format?.sampleRate ?? 48_000,
                    channels: 1,
                    bitDepth: snapshot.format?.bitDepth,
                    codec: "pcm"
                ),
                clippedDuringCapture: snapshot.clipped,
                peakDBFS: 0
            ), CaptureError.invalidState)
        }

        let duration = Double(snapshot.sampleCount) / fmt.sampleRate
        let peakDBFS = 20.0 * log10(Double(max(snapshot.peak, 1e-7)))
        let take = CapturedTake(
            fileURL: fileURL,
            duration: duration,
            format: AudioFormatDescription(sampleRate: fmt.sampleRate, channels: 1, bitDepth: fmt.bitDepth, codec: "pcm"),
            clippedDuringCapture: snapshot.clipped,
            peakDBFS: peakDBFS
        )
        state = .idle
        return (take, snapshot.error)
    }

    // MARK: - Levels

    private func startLevelPolling() {
        guard levelPoller == nil else { return }
        levelPoller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self else { break }
                let s = self.levelsAccumulator.snapshot()
                let peakDB = s.peak > 0 ? 20.0 * log10(Double(max(s.peak, 1e-7))) : -120
                let rmsDB = s.rms > 0 ? 20.0 * log10(Double(max(s.rms, 1e-7))) : -120
                let sampleTime = s.frameCount > 0 ? Double(s.frameCount) / (self.recordFormat?.sampleRate ?? 48_000) : 0
                self.levelContinuationsLock.withLock {
                    for continuation in self.levelContinuations.values {
                        continuation.yield(CaptureLevels(
                            peakDBFS: Float(peakDB),
                            rmsDBFS: Float(rmsDB),
                            isClipping: s.clipping,
                            sampleTime: sampleTime
                        ))
                    }
                }
            }
        }
    }

    private func stopLevelPolling() {
        levelPoller?.cancel()
        levelPoller = nil
    }

    // MARK: - Device and format configuration

    private func configureEngineSession() {
        inputNode.volume = 1
        // AVAudioEngine has no public API to select a specific input device on
        // macOS (AUAudioUnit does not expose its underlying AudioUnit). The
        // pragmatic approach is to set the system default input device to the
        // requested one while the engine is in use, and restore it on stop.
        if let deviceID = currentDeviceID, let device = resolveAudioDevice(uid: deviceID) {
            let currentDefault = defaultInputDeviceID()
            if device.id != currentDefault {
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultInputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var id = device.id
                let result = AudioObjectSetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &addr,
                    0,
                    nil,
                    UInt32(MemoryLayout<AudioDeviceID>.size),
                    &id
                )
                if result == noErr {
                    swappedDefaultDevice = currentDefault
                }
            }
        }
    }

    private func restoreDefaultDeviceIfNeeded() {
        guard swappedDefaultDevice != 0 else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = swappedDefaultDevice
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )
        swappedDefaultDevice = 0
    }

    private func configureInputFormat(_ format: RecordingDefaults) throws {
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw CaptureError.formatNotSupported
        }
        // The requested format and the hardware format are reconciled by the
        // AVAudioConverter in the writer task (startRecording). If the
        // hardware format is unsupported the write fails loudly, never silently.
    }

    private func makeFloatFormat(sampleRate: Double) -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        return AVAudioFormat(streamDescription: &asbd)
    }

    private func currentDefaultDeviceName() -> String? {
        enumerateAudioDevices().first { $0.id == defaultInputDeviceID() }?.name
    }

    // MARK: - CoreAudio device enumeration

    private struct CADevice {
        let id: AudioDeviceID
        let name: String
        let uid: String
        let isInput: Bool
        let inputChannels: Int
        let sampleRates: [Double]
    }

    private func enumerateAudioDevices() -> [CADevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard let (name, uid) = deviceNameAndUID(id) else { return nil }
            let channels = inputChannelCount(id)
            let rates = supportedSampleRates(id)
            return CADevice(
                id: id,
                name: name,
                uid: uid,
                isInput: channels > 0,
                inputChannels: channels,
                sampleRates: rates
            )
        }
    }

    private func deviceNameAndUID(_ deviceID: AudioDeviceID) -> (String, String)? {
        let name = propertyString(deviceID, selector: kAudioObjectPropertyName) ?? "Unknown Device"
        let uid = propertyString(deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "\(deviceID)"
        return (name.isEmpty ? "Unknown Device" : name, uid)
    }

    private func propertyString(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else { return nil }
        var cfString: CFString = "" as CFString
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &cfString) == noErr else { return nil }
        return cfString as String
    }

    private func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else { return 0 }
        let layout = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { layout.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, layout) == noErr else { return 0 }
        var channels = 0
        let buffers = UnsafeMutableAudioBufferListPointer(layout)
        for i in 0..<buffers.count {
            channels += Int(buffers[i].mNumberChannels)
        }
        return channels
    }

    private func supportedSampleRates(_ deviceID: AudioDeviceID) -> [Double] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        return ranges.map { $0.mMinimum == $0.mMaximum ? $0.mMinimum : 48000 }
    }

    private func defaultInputDeviceID() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return 0 }
        return id
    }

    private func resolveAudioDevice(uid: String) -> CADevice? {
        enumerateAudioDevices().first { $0.uid == uid || $0.name == uid }
    }
}

/// Mutable box for the AVAudioConverter input closure (Sendable-safe).
private final class ConverterInputBox: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer?) {
        self.buffer = buffer
    }
}
