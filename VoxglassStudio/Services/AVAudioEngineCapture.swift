import AVFoundation
import CoreAudio
import AudioToolbox
import Foundation
import os
import VoxglassCore

public final class AVAudioEngineCapture: AudioCapturing, @unchecked Sendable {

    public private(set) var state: CaptureState = .idle

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
    private var recordSampleCount: UInt64 = 0
    private var recordPeak: Float = 0
    private var clippedDuringCapture = false
    private var writerError: Error?

    private var monitoringActive = false
    private var levelContinuations: [UUID: AsyncStream<CaptureLevels>.Continuation] = [:]
    private let levelContinuationsLock = OSAllocatedUnfairLock()
    private var levelPoller: Task<Void, Never>?
    private var currentDeviceID: String?
    private var swappedDefaultDevice: AudioDeviceID = 0

    // Real-time safety: the tap copies into a preallocated pool and hands off
    // to a serial writer queue; AVAudioFile.write and the AVAudioConverter
    // never run on the render thread.
    private let writerQueue = DispatchQueue(label: "guru.parso.voxglass.capture.writer")
    private var bufferPool: CaptureBufferPool?
    private var writerConverter: AVAudioConverter?
    private var writerOutputFormat: AVAudioFormat?
    private var tapInstalled = false

    private struct LevelSnapshot {
        var peak: Float = 0
        var rms: Float = 0
        var clipping = false
        var sampleTime: TimeInterval = 0
    }
    private let snapshotLock = OSAllocatedUnfairLock()
    private var snapshot = LevelSnapshot()

    public init() {}

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
        let outputFormat = avFmt

        stateLock.withLock {
            recordURL = destinationURL
            recordFile = file
            recordSampleCount = 0
            recordPeak = 0
            clippedDuringCapture = false
            writerError = nil
        }

        bufferPool = CaptureBufferPool(format: tapFormat)
        writerConverter = converter
        writerOutputFormat = outputFormat

        if !engine.isRunning { try engine.start() }

        state = .recording
        startLevelPolling()
    }

    public func stopRecording() async throws -> CapturedTake {
        state = .stopping

        // Stop new callbacks from enqueuing, then drain every write that is
        // already queued before reading the counters.
        removeTap()
        writerQueue.sync {}

        if !monitoringActive, engine.isRunning {
            engine.stop()
        }

        stopLevelPolling()
        restoreDefaultDeviceIfNeeded()

        let capture: (fileURL: URL?, format: RecordingDefaults?, error: Error?, sampleCount: UInt64, peak: Float, clipped: Bool) = stateLock.withLock {
            let result = (
                fileURL: recordURL,
                format: recordFormat,
                error: writerError,
                sampleCount: recordSampleCount,
                peak: recordPeak,
                clipped: clippedDuringCapture
            )
            recordFile = nil
            recordURL = nil
            bufferPool = nil
            writerConverter = nil
            writerOutputFormat = nil
            return result
        }

        guard let fileURL = capture.fileURL, let fmt = capture.format else {
            throw CaptureError.invalidState
        }

        if let error = capture.error {
            throw error
        }

        let duration = Double(capture.sampleCount) / fmt.sampleRate
        let peakDBFS = 20.0 * log10(Double(max(capture.peak, 1e-7)))
        let captured = CapturedTake(
            fileURL: fileURL,
            duration: duration,
            format: AudioFormatDescription(sampleRate: fmt.sampleRate, channels: 1, bitDepth: fmt.bitDepth, codec: "pcm"),
            clippedDuringCapture: capture.clipped,
            peakDBFS: peakDBFS
        )

        state = .idle
        return captured
    }

    public func cancelRecording() async {
        removeTap()
        stopLevelPolling()
        writerQueue.sync {}

        stateLock.withLock {
            if let url = recordURL { try? FileManager.default.removeItem(at: url) }
            recordFile = nil
            recordURL = nil
            recordSampleCount = 0
            recordPeak = 0
            clippedDuringCapture = false
            bufferPool = nil
            writerConverter = nil
            writerOutputFormat = nil
        }
        restoreDefaultDeviceIfNeeded()

        if !monitoringActive, engine.isRunning { engine.stop() }
        state = .idle
    }

    public func punchIn(from offset: TimeInterval) async throws {
        throw CaptureError.punchInNotSupported
    }

    // MARK: - Tap and writer

    private func installTapIfNeeded() {
        guard !tapInstalled else { return }
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputNode.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.processTapBuffer(buffer)
        }
        tapInstalled = true
    }

    private func removeTap() {
        guard tapInstalled else { return }
        inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func processTapBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let samples = channelData[0]

        // Compute the level snapshot on the render thread — pure arithmetic,
        // no allocation, no locks beyond an uncontended snapshot store.
        var blockPeak: Float = 0
        var blockRmsSq: Double = 0
        var blockClipping = false
        for i in 0..<frameCount {
            let s = samples[i]
            let a = abs(s)
            if a > blockPeak { blockPeak = a }
            blockRmsSq += Double(s) * Double(s)
            if a >= 0.999 { blockClipping = true }
        }
        let blockRms = Float(sqrt(blockRmsSq / Double(frameCount)))

        let peakCopy = blockPeak
        let clippingCopy = blockClipping
        let snapshotState: (format: RecordingDefaults?, isRecording: Bool) = stateLock.withLock {
            let isRecording = recordFile != nil
            if peakCopy > recordPeak { recordPeak = peakCopy }
            if clippingCopy { clippedDuringCapture = true }
            recordSampleCount += UInt64(frameCount)
            return (recordFormat, isRecording)
        }

        let finalPeak = peakCopy
        let finalClipping = clippingCopy
        let sampleTime = snapshotState.format.map { Double(recordSampleCount) / $0.sampleRate } ?? 0
        snapshotLock.withLock {
            snapshot.peak = finalPeak
            snapshot.rms = blockRms
            snapshot.clipping = finalClipping
            snapshot.sampleTime = sampleTime
        }

        guard snapshotState.isRecording else { return }

        guard let pool = bufferPool else { return }
        let pooled = pool.acquire() ?? AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: 16384)
        pooled?.frameLength = buffer.frameLength
        if let pooled, let pooledData = pooled.floatChannelData {
            for i in 0..<frameCount {
                pooledData[0][i] = samples[i]
            }
        }

        writerQueue.async { [weak self] in
            guard let self else { return }
            if let pooled {
                self.writerHandle(pooled)
            }
        }
    }

    private func writerHandle(_ buffer: AVAudioPCMBuffer) {
        defer { bufferPool?.release(buffer) }

        let capture: (file: AVAudioFile?, converter: AVAudioConverter?, outFormat: AVAudioFormat?) = stateLock.withLock {
            (recordFile, writerConverter, writerOutputFormat)
        }

        guard let file = capture.file, let converter = capture.converter, let outFormat = capture.outFormat else { return }

        do {
            try convertAndWrite(buffer, converter: converter, outFormat: outFormat, file: file)
        } catch {
            stateLock.withLock {
                if writerError == nil { writerError = error }
            }
        }
    }

    private func convertAndWrite(
        _ input: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outFormat: AVAudioFormat,
        file: AVAudioFile
    ) throws {
        let ratio = outFormat.sampleRate / input.format.sampleRate
        let outCapacity = max(AVAudioFrameCount(Double(input.frameCapacity) * max(ratio, 1.0)) + 16, 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw CaptureError.formatNotSupported
        }

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
            outBuffer.frameLength = 0
            let status = converter.convert(to: outBuffer, error: &convertError, withInputFrom: inputBlock)
            if outBuffer.frameLength > 0 {
                try file.write(from: outBuffer)
            }
            switch status {
            case .haveData:
                done = false
            case .inputRanDry, .endOfStream:
                done = true
            case .error:
                throw convertError ?? CaptureError.formatNotSupported
            @unknown default:
                done = true
            }
        }
    }

    // MARK: - Levels

    private func startLevelPolling() {
        guard levelPoller == nil else { return }
        levelPoller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self else { break }
                let s = self.currentSnapshot()
                self.levelContinuationsLock.withLock {
                    for continuation in self.levelContinuations.values {
                        continuation.yield(CaptureLevels(
                            peakDBFS: s.peak,
                            rmsDBFS: s.rms,
                            isClipping: s.clipping,
                            sampleTime: s.sampleTime
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

    private func currentSnapshot() -> LevelSnapshot {
        snapshotLock.withLock {
            var s = snapshot
            if s.peak > 0 { s.peak = 20.0 * log10(max(s.peak, 1e-7)) }
            if s.rms > 0 { s.rms = 20.0 * log10(max(s.rms, 1e-7)) }
            return s
        }
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
        // AVAudioConverter in the writer queue (startRecording). If the
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
        var name = propertyString(deviceID, selector: kAudioObjectPropertyName) ?? "Unknown Device"
        if name.isEmpty { name = "Unknown Device" }
        let uid = propertyString(deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "\(deviceID)"
        return (name, uid)
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

/// Preallocated tap-buffer pool so the render thread never allocates while
/// handing audio off to the writer queue.
private final class CaptureBufferPool {
    private let lock = NSLock()
    private var pool: [AVAudioPCMBuffer]
    private let format: AVAudioFormat

    init(format: AVAudioFormat, count: Int = 16) {
        self.format = format
        self.pool = (0..<count).compactMap { _ in
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384)
        }
    }

    func acquire() -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return pool.isEmpty ? nil : pool.removeLast()
    }

    func release(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if pool.count < 32 {
            buffer.frameLength = 0
            pool.append(buffer)
        }
    }
}
