import Foundation
import Testing
import VoxglassCore

@Suite(.serialized) struct MetricsCalculatorTests {

    @Test func peakOfFullScaleIsZero() {
        let samples: [Float] = [1.0, -1.0, 0.5, -0.5]
        let peak = AudioMetricsCalculator.computePeak(samples)
        #expect(abs(peak - 0.0) < 0.01)
    }

    @Test func peakOfHalfScale() {
        let samples: [Float] = [0.5, -0.5]
        let peak = AudioMetricsCalculator.computePeak(samples)
        #expect(abs(peak - (-6.02)) < 0.1)
    }

    @Test func peakOfSilence() {
        let samples: [Float] = Array(repeating: 0, count: 100)
        let peak = AudioMetricsCalculator.computePeak(samples)
        #expect(peak < -100)
    }

    @Test func truePeak_halfAmplitudeSine_returnsMinus6dB() {
        let samples = sine(rate: 48000, freq: 1000, dur: 1.0, amp: 0.5)
        let tp = AudioMetricsCalculator.computeTruePeak(samples)
        #expect(abs(tp - (-6.02)) < 0.1)
    }

    @Test func truePeak_notLessThanPeakDBFS() {
        let samples = sine(rate: 48000, freq: 500, dur: 1.0, amp: 0.5)
        let peak = AudioMetricsCalculator.computePeak(samples)
        let tp = AudioMetricsCalculator.computeTruePeak(samples)
        #expect(tp >= peak - 0.01)
    }

    @Test func truePeak_fullScaleSine() {
        let samples = sine(rate: 48000, freq: 997, dur: 1.0, amp: 1.0)
        let tp = AudioMetricsCalculator.computeTruePeak(samples)
        #expect(tp > -1.0)
    }

    @Test func rmsOfSineWave() {
        let rate = 48000.0
        let freq = 1000.0
        let n = Int(rate * 1.0)
        let amplitude: Float = 0.5
        var samples: [Float] = []
        for i in 0..<n {
            samples.append(amplitude * Float(sin(2 * .pi * freq * Double(i) / rate)))
        }
        let (rms, _, _) = AudioMetricsCalculator.computeRMS(samples)
        let expected = 20.0 * log10(0.5 / sqrt(2.0))
        #expect(abs(rms - expected) < 0.1)
    }

    @Test func rmsOfSilence() {
        let samples: [Float] = Array(repeating: 0, count: 1000)
        let (rms, _, _) = AudioMetricsCalculator.computeRMS(samples)
        #expect(!rms.isFinite)
    }

    @Test func noiseFloorWithLowNoiseDetectsCorrectly() {
        let rate = 48000.0
        let noiseLevel = Float(pow(10.0, -60.0 / 20.0))
        let totalLen = Int(rate * 3.0)
        var samples: [Float] = []
        for _ in 0..<totalLen {
            samples.append(Float.random(in: -1...1) * noiseLevel)
        }
        let result = AudioMetricsCalculator.computeNoiseFloor(samples, sampleRate: rate, firstNonSilent: 0, lastNonSilent: totalLen - 1)
        #expect(result.isReliable)
        #expect(abs(result.value - (-60.0)) < 5.0)
    }

    @Test func noiseFloorReliableWithEnoughSilence() {
        let rate = 48000.0
        let totalLen = Int(rate * 2.0)
        let speechLen = Int(rate * 0.3)

        var samples: [Float] = []
        for _ in 0..<totalLen {
            samples.append(0)
        }
        for i in 0..<speechLen {
            samples.append(0.5 * Float(sin(2 * .pi * 440 * Double(i) / rate)))
        }
        for _ in 0..<totalLen {
            samples.append(0)
        }

        let first = totalLen
        let last = totalLen + speechLen - 1
        let result = AudioMetricsCalculator.computeNoiseFloor(samples, sampleRate: rate, firstNonSilent: first, lastNonSilent: last)
        #expect(result.isReliable)
    }

    @Test func clipCountZeroForCleanSignal() {
        let samples: [Float] = Array(repeating: 0.5, count: 1000)
        let clips = AudioMetricsCalculator.computeClipCount(samples)
        #expect(clips == 0)
    }

    @Test func clipCountDetectsRun() {
        var samples = [Float](repeating: 0, count: 100)
        samples.append(contentsOf: [1.0, 1.0, 1.0])
        samples.append(contentsOf: Array(repeating: 0, count: 100))
        let clips = AudioMetricsCalculator.computeClipCount(samples)
        #expect(clips == 1)
    }

    @Test func clipCountIgnoresShortRun() {
        var samples = [Float](repeating: 0, count: 100)
        samples.append(contentsOf: [1.0, 1.0])
        samples.append(contentsOf: Array(repeating: 0, count: 100))
        let clips = AudioMetricsCalculator.computeClipCount(samples)
        #expect(clips == 0)
    }

    @Test func clipCountCountsMultipleRuns() {
        var samples: [Float] = [1.0, 1.0, 1.0]
        samples.append(contentsOf: Array(repeating: 0, count: 50))
        samples.append(contentsOf: [0.9995, 0.9995, 0.9995])
        samples.append(contentsOf: Array(repeating: 0, count: 50))
        let clips = AudioMetricsCalculator.computeClipCount(samples)
        #expect(clips == 2)
    }

    @Test func dcOffsetZeroForBalancedSignal() {
        let samples: [Float] = [1.0, -1.0, 1.0, -1.0]
        let dc = AudioMetricsCalculator.computeDCOffset(samples)
        #expect(abs(dc) < 1e-6)
    }

    @Test func dcOffsetDetectsPositiveBias() {
        let samples: [Float] = [0.5, 0.5, 0.5, 0.5]
        let dc = AudioMetricsCalculator.computeDCOffset(samples)
        #expect(abs(dc - 0.5) < 1e-6)
    }

    @Test func fullMetricsOnSineWave() {
        let rate = 48000.0
        let freq = 1000.0
        let n = Int(rate * 1.0)
        let amplitude: Float = 0.1
        var samples: [Float] = []
        for i in 0..<n {
            samples.append(amplitude * Float(sin(2 * .pi * freq * Double(i) / rate)))
        }

        let calc = AudioMetricsCalculator(decoder: PlaceholderAudioDecoder())
        let metrics = calc.metrics(for: samples, sampleRate: rate, channels: 1)

        #expect(abs(metrics.peakDBFS - (20.0 * log10(0.1))) < 0.01)
        #expect(metrics.clipCount == 0)
        #expect(abs(metrics.dcOffset) < 0.01)
        #expect(abs(metrics.duration - 1.0) < 0.01)
        #expect(metrics.sampleRate == rate)
        #expect(metrics.channels == 1)
    }

    @Test func emptySamplesReturnsZeroDuration() {
        let calc = AudioMetricsCalculator(decoder: PlaceholderAudioDecoder())
        let metrics = calc.metrics(for: [], sampleRate: 48000, channels: 1)
        #expect(metrics.duration == 0)
        #expect(!metrics.peakDBFS.isFinite)
    }

    @Test func silenceBoundsDetectLeadingSilence() {
        let rate = 48000.0
        var samples = [Float](repeating: 0, count: Int(rate * 0.5))
        for i in 0..<Int(rate * 1.0) {
            samples.append(0.5 * Float(sin(2 * .pi * 1000 * Double(i) / rate)))
        }
        samples.append(contentsOf: Array(repeating: 0 as Float, count: Int(rate * 0.3)))
        let (leading, trailing) = AudioMetricsCalculator.computeSilenceBounds(samples, sampleRate: rate)
        #expect(leading > 0.3)
        #expect(trailing > 0.2)
    }

    @Test func fullMetricsIncludesReplayGain() {
        let rate = 48000.0
        let samples = sine(rate: rate, freq: 440, dur: 3.0, amp: 0.1)
        let calc = AudioMetricsCalculator(decoder: PlaceholderAudioDecoder())
        let metrics = calc.metrics(for: samples, sampleRate: rate, channels: 1)
        #expect(metrics.replayGainDB.isFinite)
        #expect(metrics.replayGainDB > -50 && metrics.replayGainDB < 50)
    }

    private func sine(rate: Double, freq: Double, dur: Double, amp: Float) -> [Float] {
        let n = Int(rate * dur)
        var s = [Float]()
        s.reserveCapacity(n)
        for i in 0..<n {
            s.append(amp * Float(sin(2.0 * .pi * freq * Double(i) / rate)))
        }
        return s
    }
}
