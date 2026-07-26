import Testing
import Foundation
@testable import VoxglassCore

@Suite struct VolumeNormalizerTests {

    @Test func initialGainIsUnity() {
        let normalizer = VolumeNormalizer()
        #expect(normalizer.gain == 1.0)
    }

    @Test func gainDoesNotChaseZeroCrossings() {
        let normalizer = VolumeNormalizer()
        let sampleRate: Float = 44100
        let frequency: Float = 440
        let amplitude: Float = 0.3
        let period = Int(sampleRate / frequency)

        var gains: [Float] = []
        for i in 0..<(period * 2) {
            let t = Float(i) / sampleRate
            let sample = amplitude * sin(2 * Float.pi * frequency * t)
            _ = normalizer.process(sample)
            if i >= period && i < period + period / 4 {
                gains.append(normalizer.gain)
            }
        }

        let variance = gains.map { abs($0 - gains.first!) }.reduce(0, +) / Float(gains.count)
        #expect(variance < 0.05)
    }

    @Test func convergesForQuietInput() {
        let normalizer = VolumeNormalizer()
        let amplitude: Float = 0.02  // well below targetRMS

        for _ in 0..<4096 {
            _ = normalizer.process(amplitude)
        }

        #expect(normalizer.gain > 1.0)
        #expect(normalizer.gain <= 4.0)
    }

    @Test func limiterNeverClips() {
        let normalizer = VolumeNormalizer()
        var maxOutput: Float = 0

        for _ in 0..<4096 {
            let output = normalizer.process(0.9)
            maxOutput = max(maxOutput, abs(output))
        }

        #expect(maxOutput <= 1.0)
    }

    @Test func silenceDoesNotWindGainUp() {
        let normalizer = VolumeNormalizer()
        for _ in 0..<4096 {
            _ = normalizer.process(0)
        }
        #expect(normalizer.gain == 1.0)  // Gain should stay at unity on silence
    }

    @Test func resetRestoresUnity() {
        let normalizer = VolumeNormalizer()
        let amplitude: Float = 0.02
        for _ in 0..<4096 {
            _ = normalizer.process(amplitude)
        }
        #expect(normalizer.gain > 1.0)

        normalizer.reset()
        #expect(normalizer.gain == 1.0)
    }

    @Test func gainStaysWithinBounds() {
        let normalizer = VolumeNormalizer()

        for _ in 0..<4096 {
            _ = normalizer.process(0.00001)
        }
        #expect(normalizer.gain >= 0.25)
        #expect(normalizer.gain <= 4.0)

        normalizer.reset()
        for _ in 0..<4096 {
            _ = normalizer.process(0.99)
        }
        #expect(normalizer.gain >= 0.25)
        #expect(normalizer.gain <= 4.0)
    }
}
