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

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(self).toOpaque(),
            init: { tap, clientInfo, tapStorageOut in
                let processor = Unmanaged<EQAudioProcessor>.fromOpaque(clientInfo!).takeUnretainedValue()
                tapStorageOut?.pointee = Unmanaged.passRetained(processor).toOpaque()
            },
            finalize: { tap in
                var storage: UnsafeMutableRawPointer? = nil
                MTAudioProcessingTapGetStorage(tap, &storage)
                if let raw = storage {
                    Unmanaged<EQAudioProcessor>.fromOpaque(raw).release()
                }
            },
            prepare: { tap, maxFrames, processingFormat in
                // reset filter state for new format
                var storage: UnsafeMutableRawPointer? = nil
                MTAudioProcessingTapGetStorage(tap, &storage)
                if let raw = storage {
                    let processor = Unmanaged<EQAudioProcessor>.fromOpaque(raw).takeUnretainedValue()
                    processor.engine.reset()
                }
            },
            unprepare: { _ in },
            process: { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
                var storage: UnsafeMutableRawPointer? = nil
                MTAudioProcessingTapGetStorage(tap, &storage)
                guard let raw = storage else { return }

                let processor = Unmanaged<EQAudioProcessor>.fromOpaque(raw).takeUnretainedValue()
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                guard status == noErr, processor.isActive else { return }

                let bufferList = bufferListInOut.pointee
                for i in 0..<Int(bufferList.mNumberBuffers) {
                    let buffer = bufferList.mBuffers.advanced(by: i).pointee
                    guard let data = buffer.mData else { continue }
                    let count = Int(numberFrames) * Int(buffer.mNumberChannels)
                    let samples = data.bindMemory(to: Float.self, capacity: count)
                    for j in 0..<count {
                        samples[j] = processor.engine.process(samples[j])
                    }
                }
            }
        )

        var tapRef: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tapRef
        )

        guard status == noErr, let tapRef else { return }

        tap = tapRef
        isActive = true

        let inputParams = AVMutableAudioMixInputParameters(track: playerItem.assetTrack)
        inputParams.audioTapProcessor = tapRef.takeUnretainedValue()

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [inputParams]
        playerItem.audioMix = audioMix

        onEngaged?()
    }

    func detach(from playerItem: AVPlayerItem) {
        guard isActive else { return }
        isActive = false

        if let audioMix = playerItem.audioMix?.mutableCopy() as? AVMutableAudioMix {
            for params in audioMix.inputParameters {
                params.audioTapProcessor = nil
            }
        }
        playerItem.audioMix = nil

        tap?.release()
        tap = nil
        engine.reset()

        onDisengaged?()
    }
}
