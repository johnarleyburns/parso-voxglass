#if !os(watchOS)
import AudioToolbox
#endif
@preconcurrency import AVFoundation
import Foundation
import ParsoAudioPlayback

#if !os(watchOS)
/// Applies a 10-band EQ to playback via one `MTAudioProcessingTap` per player
/// item. The tap lifecycle (create / attach / one-tap-per-item registry /
/// gapless-advance prune / the `passRetained` storage-ownership fix for the
/// FigPlayer_RemoteXPC field crash) is `ParsoAudioPlayback.EQTapInstaller`;
/// this type supplies the per-item DSP (`EQEngine` + `SilenceDetector` RMS).
public final class EQAudioProcessor: @unchecked Sendable {
    private let installer = EQTapInstaller(placement: .preEffects)
    private var contexts: [ObjectIdentifier: TapContext] = [:]
    private var gains: [Float] = Array(repeating: 0, count: EQEngine.isoBands.count)
    private var engaged = false
    let silenceDetector: SilenceDetector
    var previousSilenceState: SilenceDetector.State = .speech

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
    public var activeTapCount: Int { installer.activeTapCount }

    /// Per-item tap state, driven on the realtime audio thread by the shared
    /// installer. Each item's `EQEngine` (and thus its biquad filter history) is
    /// independent.
    public final class TapContext: RealtimeAudioProcessor {
        let engine: EQEngine
        weak var processor: EQAudioProcessor?

        init(gains: [Float], processor: EQAudioProcessor) {
            self.engine = EQEngine(gains: gains, eqStagesEnabled: true)
            self.processor = processor
        }

        public func prepareRealtime() {
            engine.reset()
        }

        public func processRealtime(_ bufferList: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
            var rmsSum: Float = 0
            var rmsCount = 0
            for buffer in bufferList {
                guard let data = buffer.mData else { continue }
                let count = frameCount * Int(buffer.mNumberChannels)
                let samples = data.bindMemory(to: Float.self, capacity: count)
                for j in 0..<count {
                    let sample = engine.process(samples[j])
                    samples[j] = sample
                    rmsSum += sample * sample
                    rmsCount += 1
                }
            }
            guard rmsCount > 0, let processor else { return }
            let rms = (rmsSum / Float(rmsCount)).squareRoot()
            let newState = processor.silenceDetector.process(rms: rms)
            if newState != processor.previousSilenceState {
                processor.previousSilenceState = newState
                DispatchQueue.main.async { [weak processor] in
                    processor?.onSilenceChanged?(newState == .silent)
                }
            }
        }
    }

    public func applyPreset(_ preset: EQPreset) {
        gains = preset.floatGains
        for context in contexts.values {
            context.engine.gains = preset.floatGains
            context.engine.reconfigure()
        }
    }

    public func setGain(_ gain: Float, at band: Int) {
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

        let context = TapContext(gains: gains, processor: self)
        guard installer.install(on: playerItem, processor: context) else { return }
        contexts[key] = context
        resetSilenceDetector()
        onEngaged?()
    }

    public func detach(from playerItem: AVPlayerItem) {
        let key = ObjectIdentifier(playerItem)
        guard contexts[key] != nil else { return }
        installer.remove(from: playerItem)
        contexts[key] = nil
        if contexts.isEmpty {
            didDisengage()
        }
    }

    /// Removes taps from every item and clears state (used when disengaging EQ).
    public func detachAll() {
        installer.removeAll()
        contexts.removeAll()
        didDisengage()
        resetSilenceDetector()
    }

    /// Evicts taps for items no longer present in `items` (e.g. after a gapless
    /// auto-advance leaves the previous chapter's item behind).
    public func pruneTaps(keeping items: [AVPlayerItem]) {
        installer.prune(keeping: items)
        let live = Set(items.map(ObjectIdentifier.init))
        for key in contexts.keys where !live.contains(key) {
            contexts[key] = nil
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
}
#endif
