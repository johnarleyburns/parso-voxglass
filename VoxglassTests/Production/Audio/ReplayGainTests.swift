import Foundation
import Testing
import VoxglassCore

struct ReplayGainTests {

    @Test func emptySamplesReturnsZero() {
        let gain = ReplayGainCalculator.analyze(samples: [], sampleRate: 48000)
        #expect(gain == 0)
    }

    @Test func analyzeFullReturnsPeakFromSamples() {
        let samples: [Float] = [0.8, -0.8, 0.5, -0.5]
        let (_, peakDBFS) = ReplayGainCalculator.analyzeFull(samples: samples, sampleRate: 48000)
        #expect(peakDBFS.isFinite)
        #expect(peakDBFS > -10)
    }

    @Test func gainIsDeterministic() {
        let a = sine(rate: 48000, freq: 440, dur: 1.0, amp: 0.3)
        let g1 = ReplayGainCalculator.analyze(samples: a, sampleRate: 48000)
        let g2 = ReplayGainCalculator.analyze(samples: a, sampleRate: 48000)
        #expect(abs(g1 - g2) < 0.0001)
    }

    @Test func quieterSignalHasHigherGain() {
        let loud = sine(rate: 48000, freq: 500, dur: 2.0, amp: 0.5)
        let quiet = sine(rate: 48000, freq: 500, dur: 2.0, amp: 0.05)
        let gainLoud = ReplayGainCalculator.analyze(samples: loud, sampleRate: 48000)
        let gainQuiet = ReplayGainCalculator.analyze(samples: quiet, sampleRate: 48000)
        #expect(gainQuiet > gainLoud)
    }

    @Test func frequencyWeighting100HzGetsMoreGainThan1kHz() {
        let tone100Hz = sine(rate: 48000, freq: 100, dur: 3.0, amp: 0.1)
        let tone1kHz = sine(rate: 48000, freq: 1000, dur: 3.0, amp: 0.1)
        let gain100Hz = ReplayGainCalculator.analyze(samples: tone100Hz, sampleRate: 48000)
        let gain1kHz = ReplayGainCalculator.analyze(samples: tone1kHz, sampleRate: 48000)
        #expect(gain100Hz - gain1kHz >= 5.0)
    }

    @Test func oneKHzSineMinus20dBFS_gainIsFiniteAndPositive() {
        let amp = Float(pow(10.0, -20.0 / 20.0))
        let samples = sine(rate: 48000, freq: 1000, dur: 5.0, amp: amp)
        let (gain, _) = ReplayGainCalculator.analyzeFull(samples: samples, sampleRate: 48000)
        #expect(gain.isFinite)
        #expect(gain > 0)
    }

    @Test func oneHundredHzSineMinus20dBFS_gainHigherThan1kHz() {
        let amp = Float(pow(10.0, -20.0 / 20.0))
        let tone100 = sine(rate: 48000, freq: 100, dur: 5.0, amp: amp)
        let tone1k = sine(rate: 48000, freq: 1000, dur: 5.0, amp: amp)
        let gain100 = ReplayGainCalculator.analyze(samples: tone100, sampleRate: 48000)
        let gain1k = ReplayGainCalculator.analyze(samples: tone1k, sampleRate: 48000)
        #expect(gain100 > gain1k + 5.0)
    }

    @Test func perceivedVolumeReasonable() {
        let amp = Float(pow(10.0, -20.0 / 20.0))
        let samples = sine(rate: 48000, freq: 1000, dur: 5.0, amp: amp)
        let (gain, _) = ReplayGainCalculator.analyzeFull(samples: samples, sampleRate: 48000)
        let perceivedVolume = 89.0 - gain
        #expect(perceivedVolume > 80.0 && perceivedVolume < 89.0)
    }

    @Test func sixtyPercentSilence_agreesWithinTolerance() {
        let rate = 48000.0
        let amp = Float(pow(10.0, -20.0 / 20.0))
        var samples = [Float](repeating: 0, count: Int(rate * 3.0))
        samples.append(contentsOf: sine(rate: rate, freq: 1000, dur: 2.0, amp: amp))
        let (gain, _) = ReplayGainCalculator.analyzeFull(samples: samples, sampleRate: rate)
        let ref = sine(rate: rate, freq: 1000, dur: 2.0, amp: amp)
        let (refGain, _) = ReplayGainCalculator.analyzeFull(samples: ref, sampleRate: rate)
        #expect(abs(gain - refGain) < 0.5)
    }

    @Test func sampleRateIndependence_44k1vs48k() {
        let amp = Float(pow(10.0, -20.0 / 20.0))
        let a48k = sine(rate: 48000, freq: 1000, dur: 5.0, amp: amp)
        let a44k1 = sine(rate: 44100, freq: 1000, dur: 5.0, amp: amp)
        let (g48k, _) = ReplayGainCalculator.analyzeFull(samples: a48k, sampleRate: 48000)
        let (g44k1, _) = ReplayGainCalculator.analyzeFull(samples: a44k1, sampleRate: 44100)
        #expect(abs(g48k - g44k1) < 0.3)
    }

    @Test func unsupportedSampleRateReturnsInfinity() {
        let samples = sine(rate: 8000, freq: 440, dur: 1.0, amp: 0.3)
        let (gain, _) = ReplayGainCalculator.analyzeFull(samples: samples, sampleRate: 8000)
        #expect(gain == .infinity)
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
