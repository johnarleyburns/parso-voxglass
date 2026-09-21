import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import VoxglassCore

/// Native macOS implementation of the shared capture seam. macOS exposes the
/// current default input through the AVAudioEngine input node; device selection
/// is kept behind this type so Core never imports AppKit or CoreAudio UI types.
final class MacAudioCapture: AudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var startedAt: Date?
    private var peak: Float = 0
    private var clipped = false
    private var levelContinuations: [UUID: AsyncStream<CaptureLevels>.Continuation] = [:]
    private var _state: CaptureState = .idle
    private var _route = CaptureRouteInfo(transports: [.other])
    private var selectedFormat = RecordingDefaults()
    private var preferredDeviceID: String?
    private var configurationObserver: NSObjectProtocol?

    init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.state == .recording else { return }
            self.onInterruption?(.routeChanged)
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    var state: CaptureState { lock.withLock { _state } }
    var currentRouteInfo: CaptureRouteInfo { lock.withLock { _route } }
    var onInterruption: ((CaptureInterruptionReason) -> Void)?

    func setPreferredInputDevice(_ id: String?) {
        lock.withLock { preferredDeviceID = id }
    }

    var levels: AsyncStream<CaptureLevels> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.withLock { levelContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.levelContinuations[id] = nil }
            }
        }
    }

    func availableInputDevices() async -> [AudioDeviceInfo] {
        let defaultID = defaultInputDeviceID()
        return deviceIDs().compactMap { id in
            let channels = inputChannelCount(for: id)
            guard channels > 0 else { return nil }
            return AudioDeviceInfo(
                id: String(id),
                name: deviceName(for: id),
                channelCount: channels,
                supportedSampleRates: [deviceSampleRate(for: id)],
                isDefault: id == defaultID,
                transport: deviceTransport(for: id)
            )
        }
    }

    func prepare(device: String?, format: RecordingDefaults) async throws {
        let deviceID = try resolveDeviceID(device ?? lock.withLock { preferredDeviceID })
        if let audioUnit = engine.inputNode.audioUnit {
            var mutableID = deviceID
            let result = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &mutableID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard result == noErr else { throw CaptureError.deviceUnavailable }
        }
        guard engine.inputNode.inputFormat(forBus: 0).channelCount > 0 else { throw CaptureError.deviceUnavailable }
        selectedFormat = format
        let hardware = engine.inputNode.inputFormat(forBus: 0)
        lock.withLock {
            _route = CaptureRouteInfo(
                transports: [routeTransport(for: deviceID)],
                sampleRate: hardware.sampleRate,
                isSampleRateStable: true,
                inputLatencySeconds: 0
            )
            _state = .prepared
        }
    }

    func startMonitoring() async throws {
        guard state == .prepared || state == .monitoring else { throw CaptureError.invalidState }
        lock.withLock { _state = .monitoring }
    }

    func stopMonitoring() async {
        guard state != .recording else { return }
        lock.withLock { _state = .prepared }
    }

    func startRecording(to destinationURL: URL) async throws {
        guard state == .prepared || state == .monitoring else { throw CaptureError.invalidState }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0 else { throw CaptureError.deviceUnavailable }
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: selectedFormat.bitDepth,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = try AVAudioFile(forWriting: destinationURL, settings: settings)
        lock.withLock {
            file = output
            startedAt = Date()
            peak = 0
            clipped = false
            _state = .recording
        }
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            do {
                let output = self.lock.withLock { self.file }
                try output?.write(from: buffer)
            } catch { self.onInterruption?(.diskPressure) }
            self.publishLevels(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            lock.withLock { _state = .failed(error.localizedDescription) }
            throw error
        }
    }

    func stopRecording() async throws -> CapturedTake {
        guard state == .recording else { throw CaptureError.invalidState }
        lock.withLock { _state = .stopping }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let duration = Date().timeIntervalSince(startedAt ?? Date())
        let url = file?.url
        file = nil
        guard let url else { throw CaptureError.invalidState }
        let format = AudioFormatDescription(
            sampleRate: engine.inputNode.inputFormat(forBus: 0).sampleRate,
            channels: Int(engine.inputNode.inputFormat(forBus: 0).channelCount),
            bitDepth: selectedFormat.bitDepth,
            codec: "lpcm"
        )
        lock.withLock { _state = .prepared }
        return CapturedTake(
            fileURL: url,
            duration: max(0, duration),
            format: format,
            clippedDuringCapture: clipped,
            peakDBFS: Double(peak)
        )
    }

    func cancelRecording() async {
        if state == .recording { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        file = nil
        lock.withLock { _state = .prepared }
    }

    func punchIn(from offset: TimeInterval) async throws {
        _ = offset
        throw CaptureError.punchInNotSupported
    }

    private func publishLevels(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?.pointee else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var localPeak: Float = 0
        var sum: Float = 0
        for index in 0..<count {
            let value = abs(data[index])
            localPeak = max(localPeak, value)
            sum += value * value
        }
        let rms = sqrt(sum / Float(count))
        lock.withLock {
            peak = max(peak, localPeak)
            clipped = clipped || localPeak >= 0.999
            let sampleTime = Date().timeIntervalSince(startedAt ?? Date())
            let levels = CaptureLevels(
                peakDBFS: 20 * log10(max(localPeak, 0.000_001)),
                rmsDBFS: 20 * log10(max(rms, 0.000_001)),
                isClipping: localPeak >= 0.999,
                sampleTime: sampleTime
            )
            for continuation in levelContinuations.values { continuation.yield(levels) }
        }
    }

    private func resolveDeviceID(_ requested: String?) throws -> AudioDeviceID {
        if let requested, let rawValue = UInt32(requested), let value = AudioDeviceID(exactly: rawValue) {
            guard deviceIDs().contains(value), inputChannelCount(for: value) > 0 else {
                throw CaptureError.deviceUnavailable
            }
            return value
        }
        guard let value = defaultInputDeviceID(), inputChannelCount(for: value) > 0 else {
            throw CaptureError.deviceUnavailable
        }
        return value
    }

    private func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount) == noErr else { return [] }
        let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.stride
        var values = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, &values) == noErr else { return [] }
        return values
    }

    private func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioDeviceID(0)
        var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, &value) == noErr,
              value != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return value
    }

    private func inputChannelCount(for device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &byteCount) == noErr else { return 0 }
        var data = Data(count: Int(byteCount))
        return data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &byteCount, baseAddress) == noErr else { return 0 }
            let list = baseAddress.assumingMemoryBound(to: AudioBufferList.self)
            return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
        }
    }

    private func deviceName(for device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &byteCount, &value) == noErr,
              let value else { return "Audio input" }
        return value.takeUnretainedValue() as String
    }

    private func deviceTransport(for device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var byteCount = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &byteCount, &value) == noErr else { return "Core Audio" }
        switch value {
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        default: return "Core Audio"
        }
    }

    private func deviceSampleRate(for device: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = 0.0
        var byteCount = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &byteCount, &value) == noErr else { return 48_000 }
        return value
    }

    private func routeTransport(for device: AudioDeviceID) -> CapturePortTransport {
        switch deviceTransport(for: device) {
        case "USB": return .usb
        case "Bluetooth": return .bluetooth
        case "Built-in": return .builtIn
        default: return .other
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
