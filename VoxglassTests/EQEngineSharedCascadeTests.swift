import Testing
import Foundation
@testable import VoxglassCore

/// Integration cover for the Phase 3 adoption of `parso-audio-engine`'s
/// `GraphicEQ`: Voxglass's `EQEngine` now wraps the shared RBJ peaking cascade
/// (at Q 1.0) plus the realtime `VolumeNormalizer`. Runs on every commit via the
/// pre-commit `swift test`, so a PAE change that breaks the EQ path is caught
/// here as well as in PAE's own suite.
@Suite struct EQEngineSharedCascadeTests {
    private func signal(_ n: Int = 4096) -> [Float] {
        (0..<n).map { Float(0.4 * sin(2 * .pi * 1000 * Double($0) / 44_100)) }
    }

    @Test func flatBypassedCascadeIsTransparentBeforeNormalizer() {
        let engine = EQEngine(gains: Array(repeating: 0, count: 10))
        #expect(engine.isFlat)
        #expect(engine.isBypassed)
        // eqStagesEnabled off => only the normalizer runs; with a quiet steady
        // tone the normalizer gain rides toward a constant but the EQ contributes
        // nothing. Assert the EQ stage itself is a no-op by disabling stages.
        engine.eqStagesEnabled = false
        let input = signal()
        let output = input.map { engine.process($0) }
        // Normalizer may scale; EQ must not colour. Re-run with a fresh flat,
        // stages ENABLED, and confirm identical output (EQ added nothing).
        let ref = EQEngine(gains: Array(repeating: 0, count: 10))
        ref.eqStagesEnabled = true
        let refOut = input.map { ref.process($0) }
        #expect(output == refOut)
    }

    @Test func nonFlatBandColoursTheSignal() {
        let engine = EQEngine(gains: [0, 0, 0, 0, 0, 8, 0, 0, 0, 0])
        engine.eqStagesEnabled = true
        let flat = EQEngine(gains: Array(repeating: 0, count: 10))
        flat.eqStagesEnabled = true
        let input = signal()
        let coloured = input.map { engine.process($0) }
        let plain = input.map { flat.process($0) }
        let maxDiff = zip(coloured, plain).map { abs($0 - $1) }.max() ?? 0
        #expect(maxDiff > 0.001)
    }

    @Test func isoBandsAreTheStandardTenBand() {
        #expect(EQEngine.isoBands == [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000])
    }

    @Test func setGainRebuildsCascade() {
        let engine = EQEngine(gains: Array(repeating: 0, count: 10))
        engine.setGain(6, at: 4)
        #expect(engine.gains[4] == 6)
        #expect(!engine.isFlat)
        #expect(!engine.isBypassed)
    }
}
