import Foundation
import Testing
import VoxglassCore

/// §16.7 / §19.3 — the mastering chain's acceptance contract:
/// 1. −30 dBFS RMS in → −20 ± 0.3 dBFS out.
/// 2. A +0 dBFS transient → true peak ≤ −3.5 dBFS (ceiling − 0.5 headroom).
/// 3. Idempotent to within 0.1 dB when run twice.
@Suite struct MasteringChainTests {

    private let target = MasteringTarget(
        targetRMSDBFS: -20,
        peakCeilingDBFS: -3.0,
        headSeconds: 0.75,
        tailSeconds: 2.0
    )

    @Test func normalizesLowSignalToTargetRMS() {
        // Sine at −30 dBFS RMS: amplitude = √2 · 10^(-30/20) ≈ 0.0447.
        let samples = sine(amplitude: 0.0447, seconds: 2, sampleRate: 44_100, frequency: 440)
        let inputRMS = AudioMetricsCalculator.computeRMS(samples).dbfs
        #expect(inputRMS < -29.5 && inputRMS > -30.5, "fixture RMS was \(inputRMS)")

        let result = MasteringChain.master(samples: samples, sampleRate: 44_100, target: target)
        #expect(result.rmsDBFS >= -20.3 && result.rmsDBFS <= -19.7, "RMS out of band: \(result.rmsDBFS)")
        // +10 dB of gain should have been applied.
        #expect(abs(result.appliedGainDB - 10) < 0.5, "applied gain \(result.appliedGainDB)")
    }

    @Test func limitsZeroDBFSTransientToCeiling() {
        // Quiet tone with a single full-scale transient; the limiter must keep
        // the true peak at or below −3.5 dBFS.
        var samples = sine(amplitude: 0.1, seconds: 1, sampleRate: 44_100, frequency: 440)
        samples[10_000] = 1.0
        samples[10_001] = 1.0
        samples[10_002] = 1.0

        let result = MasteringChain.master(samples: samples, sampleRate: 44_100, target: target)
        #expect(result.truePeakDBFS <= -3.5, "true peak \(result.truePeakDBFS) exceeded ceiling")
    }

    @Test func isIdempotentWithinTolerance() {
        // Acceptance (§16.7): running the chain twice must not change the
        // delivered level by more than 0.1 dB, and peak compliance must hold on
        // both passes.
        let samples = sine(amplitude: 0.3, seconds: 1.5, sampleRate: 44_100, frequency: 1000)
        let once = MasteringChain.master(samples: samples, sampleRate: 44_100, target: target)
        let twice = MasteringChain.master(samples: once.samples, sampleRate: 44_100, target: target)
        #expect(abs(once.rmsDBFS - twice.rmsDBFS) < 0.1, "RMS drifted \(once.rmsDBFS) → \(twice.rmsDBFS)")
        #expect(once.truePeakDBFS <= -3.5)
        #expect(twice.truePeakDBFS <= -3.5)
    }

    @Test func preservesOrExtendsSampleCount() {
        let samples = sine(amplitude: 0.2, seconds: 1, sampleRate: 48_000, frequency: 300)
        let result = MasteringChain.master(samples: samples, sampleRate: 48_000, target: target)
        // Room-tone normalization may pad the head/tail, so the mastered file
        // is never shorter than the input.
        #expect(result.samples.count >= samples.count)
        #expect(result.samples.count > samples.count, "room-tone pad should add head/tail samples")
    }

    @Test func tpdfDitherStaysWithinOneLSB() {
        let samples = sine(amplitude: 0.5, seconds: 0.2, sampleRate: 44_100, frequency: 440)
        let dithered = MasteringChain.tpdfDither(samples, bitDepth: 16)
        let lsb = 1.0 / 32767.0
        for i in samples.indices {
            #expect(abs(Double(dithered[i]) - Double(samples[i])) <= lsb)
        }
    }

    private func sine(amplitude: Double, seconds: Double, sampleRate: Double, frequency: Double) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { i in
            Float(amplitude * sin(2 * Double.pi * frequency * Double(i) / sampleRate))
        }
    }
}
