import XCTest
@testable import VoxglassCore

final class VolumeNormalizerTests: XCTestCase {

    func testInitialGainIsUnity() {
        let normalizer = VolumeNormalizer()
        XCTAssertEqual(normalizer.gain, 1.0)
    }

    func testGainDoesNotChaseZeroCrossings() {
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
        XCTAssertLessThan(variance, 0.05, "Gain should not chase zero crossings of a steady sine wave")
    }

    func testConvergesForQuietInput() {
        let normalizer = VolumeNormalizer()
        let amplitude: Float = 0.02  // well below targetRMS

        for _ in 0..<4096 {
            _ = normalizer.process(amplitude)
        }

        XCTAssertGreaterThan(normalizer.gain, 1.0, "Gain should rise for quiet input")
        XCTAssertLessThanOrEqual(normalizer.gain, 4.0)
    }

    func testLimiterNeverClips() {
        let normalizer = VolumeNormalizer()
        var maxOutput: Float = 0

        for _ in 0..<4096 {
            let output = normalizer.process(0.9)
            maxOutput = max(maxOutput, abs(output))
        }

        XCTAssertLessThanOrEqual(maxOutput, 1.0)
    }

    func testSilenceDoesNotWindGainUp() {
        let normalizer = VolumeNormalizer()
        for _ in 0..<4096 {
            _ = normalizer.process(0)
        }
        XCTAssertEqual(normalizer.gain, 1.0, "Gain should stay at unity on silence")
    }

    func testResetRestoresUnity() {
        let normalizer = VolumeNormalizer()
        let amplitude: Float = 0.02
        for _ in 0..<4096 {
            _ = normalizer.process(amplitude)
        }
        XCTAssertGreaterThan(normalizer.gain, 1.0)

        normalizer.reset()
        XCTAssertEqual(normalizer.gain, 1.0)
    }

    func testGainStaysWithinBounds() {
        let normalizer = VolumeNormalizer()

        for _ in 0..<4096 {
            _ = normalizer.process(0.00001)
        }
        XCTAssertGreaterThanOrEqual(normalizer.gain, 0.25)
        XCTAssertLessThanOrEqual(normalizer.gain, 4.0)

        normalizer.reset()
        for _ in 0..<4096 {
            _ = normalizer.process(0.99)
        }
        XCTAssertGreaterThanOrEqual(normalizer.gain, 0.25)
        XCTAssertLessThanOrEqual(normalizer.gain, 4.0)
    }
}
