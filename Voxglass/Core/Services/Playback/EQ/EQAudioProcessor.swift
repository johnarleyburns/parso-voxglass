import AudioToolbox
import AVFoundation
import Foundation

/// Applies a 10-band EQ to playback via one `MTAudioProcessingTap` per player
/// item. One-tap-per-item (tracked by `EQTapRegistry`, keyed by object identity)
/// is the fix for EQ silently dying on every gapless auto-advance: the preloaded
/// item receives its own tap while the current item keeps playing through its
/// own, so `AVQueuePlayer` advancing no longer drops the `audioMix`.
public final class EQAudioProcessor {
    private let registry = EQTapRegistry()
    private var contexts: [ObjectIdentifier: TapContext] = [:]
    private var gains: [Float] = Array(repeating: 0, count: EQEngine.isoBands.count)
    private var engaged = false
    private let silenceDetector: SilenceDetector
    private var previousSilenceState: SilenceDetector.State = .speech

    public var onEngaged: (() -> Void)?
    public var onDisengaged: (() -> Void)?
    public var onSilenceChanged: (@MainActor (Bool) -> Void)?

    public var isEngaged: Bool { engaged }
    public var currentGains: [Float] { gains }

    public init(silenceDetector: SilenceDetector = SilenceDetector()) {
        self.silenceDetector = silenceDetector
    }

    /// Number of items with a live tap — lets tests prove two taps coexist across
    /// a gapless preload.
    public var activeTapCount: Int { registry.count }

    /// Per-item tap state. Retained by the tap's storage so each item's `EQEngine`
    /// (and thus its biquad filter history) is independent.
    public final class TapContext {
        let engine: EQEngine
        weak var item: AVPlayerItem?
        weak var processor: EQAudioProcessor?
        var tap: Unmanaged<MTAudioProcessingTap>?

        init(gains: [Float], item: AVPlayerItem, processor: EQAudioProcessor) {
            self.engine = EQEngine(gains: gains, eqStagesEnabled: ProFeature.isEnabled(.eq))
            self.item = item
            self.processor = processor
        }
    }

    public func applyPreset(_ preset: EQPreset) {
        guard ProFeature.isEnabled(.eq) else { return }
        gains = preset.gains
        for context in contexts.values {
            context.engine.gains = preset.gains
            context.engine.reconfigure()
        }
    }

    public func setGain(_ gain: Float, at band: Int) {
        guard ProFeature.isEnabled(.eq) else { return }
        guard band >= 0, band < gains.count else { return }
        gains[band] = gain
        for context in contexts.values {
            context.engine.setGain(gain, at: band)
        }
    }

    public func attach(to playerItem: AVPlayerItem) {
        engaged = true
        let key = ObjectIdentifier(playerItem)
        guard contexts[key] == nil else { return }   // already tapped

        let context = TapContext(gains: gains, item: playerItem, processor: self)
        guard let tap = makeTap(for: context) else { return }
        // Ownership: detach/detachAll/pruneTaps call `context.tap?.release()`, so
        // the stored reference MUST carry its own +1 (`passRetained`). Storing it
        // unretained releases a retain owned by the item's audioMix/MediaToolbox,
        // and the over-released tap then crashes MediaToolbox's own CFRelease in
        // remoteXPCItem_Invalidate (field crash: EXC_BREAKPOINT, FigPlayer_RemoteXPC.m).
        context.tap = Unmanaged.passRetained(tap)
        contexts[key] = context
        registry.attach(playerItem)
        applyMix(tap: tap, to: playerItem)
        resetSilenceDetector()
        onEngaged?()
    }

    public func detach(from playerItem: AVPlayerItem) {
        let key = ObjectIdentifier(playerItem)
        guard let context = contexts[key] else { return }
        context.tap?.release()
        contexts[key] = nil
        registry.evict(playerItem)
        if contexts.isEmpty {
            didDisengage()
        }
    }

    /// Removes taps from every item and clears state (used when disengaging EQ).
    public func detachAll() {
        for context in contexts.values {
            context.tap?.release()
        }
        contexts.removeAll()
        registry.evictAll()
        didDisengage()
        resetSilenceDetector()
    }

    /// Evicts taps for items no longer present in `items` (e.g. after a gapless
    /// auto-advance leaves the previous chapter's item behind).
    public func pruneTaps(keeping items: [AVPlayerItem]) {
        let live = Set(items.map(ObjectIdentifier.init))
        for (key, context) in contexts where !live.contains(key) {
            context.tap?.release()
            contexts[key] = nil
            registry.evict(identifier: key)
        }
        if contexts.isEmpty {
            didDisengage()
        }
    }

    private func didDisengage() {
        guard engaged else { return }
        engaged = false
        onDisengaged?()
    }

    public func setEQStagesEnabled(_ enabled: Bool) {
        for context in contexts.values {
            context.engine.eqStagesEnabled = enabled
        }
    }

    public func resetSilenceDetector() {
        silenceDetector.reset()
        previousSilenceState = .speech
    }

    // MARK: - Tap plumbing

    private func makeTap(for context: TapContext) -> MTAudioProcessingTap? {
        let contextPtr = Unmanaged.passUnretained(context).toOpaque()

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: contextPtr,
            init: { _, clientInfo, tapStorageOut in
                let ctx = Unmanaged<TapContext>.fromOpaque(clientInfo!).takeUnretainedValue()
                tapStorageOut.pointee = Unmanaged.passRetained(ctx).toOpaque()
            },
            finalize: { tap in
                let raw = MTAudioProcessingTapGetStorage(tap)
                Unmanaged<TapContext>.fromOpaque(raw).release()
            },
            prepare: { tap, _, _ in
                let raw = MTAudioProcessingTapGetStorage(tap)
                let ctx = Unmanaged<TapContext>.fromOpaque(raw).takeUnretainedValue()
                ctx.engine.reset()
            },
            unprepare: { _ in },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                let raw = MTAudioProcessingTapGetStorage(tap)
                let ctx = Unmanaged<TapContext>.fromOpaque(raw).takeUnretainedValue()

                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                guard status == noErr else { return }

                let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)
                var rmsSum: Float = 0
                var rmsCount: Int = 0
                for buffer in abl {
                    guard let data = buffer.mData else { continue }
                    let count = Int(numberFrames) * Int(buffer.mNumberChannels)
                    let samples = data.bindMemory(to: Float.self, capacity: count)
                    for j in 0..<count {
                        let sample = ctx.engine.process(samples[j])
                        samples[j] = sample
                        rmsSum += sample * sample
                        rmsCount += 1
                    }
                }
                guard rmsCount > 0, let processor = ctx.processor else { return }
                let rms = sqrt(rmsSum / Float(rmsCount))
                let newState = processor.silenceDetector.process(rms: rms)
                if newState != processor.previousSilenceState {
                    processor.previousSilenceState = newState
                    DispatchQueue.main.async { [weak processor] in
                        processor?.onSilenceChanged?(newState == .silent)
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
        guard status == noErr, let rawTap else { return nil }
        return rawTap
    }

    /// Attaches `tap` to `playerItem`'s audio track. For a remote `AVURLAsset` the
    /// tracks are often not loaded synchronously (the tap would attach to nothing),
    /// so fall back to async track loading and set the mix once tracks are ready.
    private func applyMix(tap: MTAudioProcessingTap, to playerItem: AVPlayerItem) {
        let asset = playerItem.asset
        if let track = asset.tracks.first(where: { $0.mediaType == .audio }) {
            setMix(tap: tap, track: track, on: playerItem)
            return
        }
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) { [weak self, weak playerItem] in
            DispatchQueue.main.async {
                guard let self, let playerItem, self.contexts[ObjectIdentifier(playerItem)] != nil else { return }
                let track = asset.tracks.first { $0.mediaType == .audio }
                self.setMix(tap: tap, track: track, on: playerItem)
            }
        }
    }

    private func setMix(tap: MTAudioProcessingTap, track: AVAssetTrack?, on playerItem: AVPlayerItem) {
        let inputParams = AVMutableAudioMixInputParameters(track: track)
        inputParams.audioTapProcessor = tap
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [inputParams]
        playerItem.audioMix = audioMix
    }
}
