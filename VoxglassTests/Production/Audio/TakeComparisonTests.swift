import Foundation
import Testing
import VoxglassCore

/// Spec §9.5 (mockup 08): A/B take comparison at matched loudness using the
/// ReplayGain values already computed on each take. The quieter take receives
/// the positive boost; equal or unavailable gains produce zero.
@Suite struct TakeComparisonTests {

    private static func side(
        id: UUID = UUID(),
        replayGain: Double?,
        selected: Bool = false,
        archived: Bool = false,
        peak: Double? = -6,
        rms: Double? = -20,
        noise: Double? = -60
    ) -> TakeComparison.Side {
        TakeComparison.Side(
            takeID: id,
            label: "Take",
            isSelected: selected,
            isArchived: archived,
            recordedAt: Date(timeIntervalSince1970: 0),
            duration: 4,
            peakDBFS: peak,
            rmsDBFS: rms,
            noiseFloorDBFS: noise,
            replayGainDB: replayGain
        )
    }

    @Test func quieterTakeReceivesTheBoost() {
        // Take A needs +1.4 dB to reach reference loudness; take B is already
        // at reference. A is quieter, so the +1.4 dB applies to A (mockup 08).
        let a = Self.side(id: UUID(), replayGain: 1.4)
        let b = Self.side(id: UUID(), replayGain: 0)
        let comparison = TakeComparison(takeA: a, takeB: b)
        #expect(abs(comparison.matchedLoudnessGainDB - 1.4) < 0.001)
        #expect(comparison.gainAppliedToTakeID == a.takeID)
    }

    @Test func louderTakeIsNotBoosted() {
        let a = Self.side(id: UUID(), replayGain: -2.0)
        let b = Self.side(id: UUID(), replayGain: 0)
        let comparison = TakeComparison(takeA: a, takeB: b)
        #expect(abs(comparison.matchedLoudnessGainDB - 2.0) < 0.001)
        #expect(comparison.gainAppliedToTakeID == b.takeID)
    }

    @Test func equalGainsProduceNoBoost() {
        let a = Self.side(id: UUID(), replayGain: -0.5)
        let b = Self.side(id: UUID(), replayGain: -0.5)
        let comparison = TakeComparison(takeA: a, takeB: b)
        #expect(comparison.matchedLoudnessGainDB == 0)
    }

    @Test func missingMetricsProduceNoBoost() {
        let a = Self.side(id: UUID(), replayGain: nil)
        let b = Self.side(id: UUID(), replayGain: nil)
        let comparison = TakeComparison(takeA: a, takeB: b)
        #expect(comparison.matchedLoudnessGainDB == 0)
    }

    @Test func selectedAndArchivedFlagsAreReflected() {
        let a = Self.side(id: UUID(), replayGain: 0, selected: true)
        let b = Self.side(id: UUID(), replayGain: 0, archived: true)
        let comparison = TakeComparison(takeA: a, takeB: b)
        #expect(comparison.takeA.isSelected)
        #expect(!comparison.takeA.isArchived)
        #expect(comparison.takeB.isArchived)
        #expect(!comparison.takeB.isSelected)
    }
}
