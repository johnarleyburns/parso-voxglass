import AudioToolbox
import AVFoundation
import Foundation

final class EQAudioProcessor {
    private var tap: Unmanaged<MTAudioProcessingTap>?
    private var engine = EQEngine()
    private var isActive = false

    var onEngaged: (() -> Void)?
    var onDisengaged: (() -> Void)?

    var isEngaged: Bool { isActive }
    var currentGains: [Float] { engine.gains }

    func applyPreset(_ preset: EQPreset) {
        guard ProFeature.isEnabled(.eq) else { return }
        engine = EQEngine(gains: preset.gains)
    }

    func setGain(_ gain: Float, at band: Int) {
        guard ProFeature.isEnabled(.eq) else { return }
        engine.setGain(gain, at: band)
    }

    func attach(to playerItem: AVPlayerItem) {
        guard ProFeature.isEnabled(.eq) else { return }
        guard !isActive else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: selfPtr,
            init: { tap, clientInfo, tapStorageOut in
                let processor = Unmanaged<EQAudioProcessor>.fromOpaque(clientInfo!).takeUnretainedValue()
                tapStorageOut.pointee = Unmanaged.passRetained(processor).toOpaque()
            },
            finalize: { tap in
                let raw = MTAudioProcessingTapGetStorage(tap)
                Unmanaged<EQAudioProcessor>.fromOpaque(raw).release()
            },
            prepare: { tap, maxFrames, processingFormat in
                let raw = MTAudioProcessingTapGetStorage(tap)
                let processor = Unmanaged<EQAudioProcessor>.fromOpaque(raw).takeUnretainedValue()
                processor.engine.reset()
            },
            unprepare: { _ in },
            process: { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
                let raw = MTAudioProcessingTapGetStorage(tap)
                let processor = Unmanaged<EQAudioProcessor>.fromOpaque(raw).takeUnretainedValue()

                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                guard status == noErr, processor.isActive else { return }

                let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)
                for buffer in abl {
                    guard let data = buffer.mData else { continue }
                    let count = Int(numberFrames) * Int(buffer.mNumberChannels)
                    let samples = data.bindMemory(to: Float.self, capacity: count)
                    for j in 0..<count {
                        samples[j] = processor.engine.process(samples[j])
                    }
                }
            }
        )

        var rawTap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &rawTap
        )

        guard status == noErr, let rawTap else { return }
        tap = Unmanaged.passUnretained(rawTap)
        isActive = true
        let retainedTap = rawTap

        let audioTrack = playerItem.asset.tracks.first { $0.mediaType == .audio }
        let inputParams = AVMutableAudioMixInputParameters(track: audioTrack)
        inputParams.setValue(retainedTap, forKey: "audioTapProcessor")

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [inputParams]
        playerItem.audioMix = audioMix

        onEngaged?()
    }

    func detach(from playerItem: AVPlayerItem) {
        guard isActive else { return }
        isActive = false

        playerItem.audioMix = nil
        tap?.release()
        tap = nil
        engine.reset()

        onDisengaged?()
    }
}
