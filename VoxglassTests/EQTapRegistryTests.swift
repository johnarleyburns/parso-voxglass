import Testing
import Foundation
import AVFoundation
import ParsoAudioPlayback
@testable import VoxglassCore

/// Tests the "which items have a tap" bookkeeping (Step 0b) with plain objects —
/// no AVFoundation. Proves the current + preloaded items can both hold taps
/// (the gapless-advance fix) and that item-changed evicts the old one.
@Suite struct EQTapRegistryTests {

    @Test func attachCurrentAndPreloadedYieldsTwoLiveEntries() {
        let registry = EQTapRegistry()
        let current = NSObject()
        let preloaded = NSObject()

        #expect(registry.attach(current))
        #expect(registry.attach(preloaded))

        #expect(registry.count == 2)
        #expect(registry.isAttached(current))
        #expect(registry.isAttached(preloaded))
    }

    @Test func itemChangedEvictsTheOldOne() {
        let registry = EQTapRegistry()
        let previous = NSObject()
        let next = NSObject()
        registry.attach(previous)
        registry.attach(next)

        // Gapless auto-advance: the previous chapter's item leaves the queue.
        #expect(registry.evict(previous))

        #expect(registry.count == 1)
        #expect(!(registry.isAttached(previous)))
        #expect(registry.isAttached(next))  // The now-playing item keeps its tap
    }

    @Test func attachIsIdempotent() {
        let registry = EQTapRegistry()
        let item = NSObject()
        #expect(registry.attach(item))
        #expect(!(registry.attach(item)))  // Re-attaching an already-tapped item is a no-op
        #expect(registry.count == 1)
    }

    @Test func evictAllClears() {
        let registry = EQTapRegistry()
        registry.attach(NSObject())
        registry.attach(NSObject())
        registry.evictAll()
        #expect(registry.isEmpty)
        #expect(registry.count == 0)
    }

    @Test func evictNonMemberReturnsFalse() {
        let registry = EQTapRegistry()
        #expect(!(registry.evict(NSObject())))
    }
}

/// Phase 4 (audio-engine unification): `EQAudioProcessor` now drives the shared
/// `EQTapInstaller` through a `RealtimeAudioProcessor` conformer. This exercises
/// that DSP path without AVPlayer — the EQ still shapes the buffer and the RMS
/// silence detector still fires.
#if !os(watchOS)
@Suite struct EQAudioProcessorSharedTapTests {

    private func monoBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for i in 0..<samples.count { buffer.floatChannelData![0][i] = samples[i] }
        return buffer
    }

    @Test func boostingEQChangesTheBufferInPlace() {
        let processor = EQAudioProcessor()
        processor.setGain(12, at: 0)          // heavy low-band boost
        processor.setGain(12, at: 1)
        let context = EQAudioProcessor.TapContext(gains: processor.currentGains, processor: processor)
        context.prepareRealtime()

        let tone: [Float] = (0..<4096).map { i in
            let phase = 2.0 * Double.pi * 60.0 * Double(i) / 44_100.0
            return Float(0.2 * sin(phase))
        }
        let buffer = monoBuffer(tone)
        context.processRealtime(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                                frameCount: 4096)

        var changed = false
        for i in 0..<4096 where abs(buffer.floatChannelData![0][i] - tone[i]) > 1e-4 { changed = true; break }
        #expect(changed)
    }

    private final class Box: @unchecked Sendable { var value: Bool? }

    @Test func silenceDetectorFiresThroughTheSharedPath() async {
        let processor = EQAudioProcessor()
        let reported = Box()
        processor.onSilenceChanged = { reported.value = $0 }
        let context = EQAudioProcessor.TapContext(gains: processor.currentGains, processor: processor)
        context.prepareRealtime()

        let silence = [Float](repeating: 0, count: 4096)
        for _ in 0..<10 {
            let b = monoBuffer(silence)
            context.processRealtime(UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList),
                                    frameCount: 4096)
        }
        // onSilenceChanged hops to the main queue.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(reported.value == true)
    }
}
#endif
