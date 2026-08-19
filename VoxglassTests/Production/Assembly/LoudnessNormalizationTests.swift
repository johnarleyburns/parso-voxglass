import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// 2026-08-19 field report, item 13: "Estimated perceived volume out of band
/// always happens but I'm not given any review controls to normalize".
/// The render gain was also applied with the wrong sign, so normalization made
/// the deviation worse instead of removing it.
@Suite struct LoudnessNormalizationTests {

    private func metrics(replayGainDB: Double, truePeakDBFS: Double = -12) -> AudioQualityMetrics {
        AudioQualityMetrics(
            peakDBFS: truePeakDBFS,
            truePeakDBFS: truePeakDBFS,
            rmsDBFS: -24,
            noiseFloorDBFS: -60,
            noiseFloorReliable: true,
            replayGainDB: replayGainDB,
            clipCount: 0,
            dcOffset: 0,
            leadingSilence: 0.2,
            trailingSilence: 0.4,
            duration: 12,
            sampleRate: 44_100,
            channels: 1,
            analyzerVersion: AudioMetricsCalculator.analyzerVersion
        )
    }

    @Test func normalizationAddsReplayGainRatherThanSubtractingIt() {
        // ReplayGain is the gain *to apply*; the old code negated it.
        #expect(AssemblyLoudness.normalizationGainDB(for: metrics(replayGainDB: 8)) == 8)
        #expect(AssemblyLoudness.normalizationGainDB(for: metrics(replayGainDB: -5)) == -5)
    }

    @Test func normalizationNeverPushesTruePeakPastTheCeiling() {
        let gain = AssemblyLoudness.normalizationGainDB(for: metrics(replayGainDB: 8, truePeakDBFS: -2))
        #expect(gain == 1, "the clamp must leave 1 dB of head room, not apply the full 8 dB")
    }

    @Test func silentOrUnmeasuredTakesGetNoGain() {
        #expect(AssemblyLoudness.normalizationGainDB(for: metrics(replayGainDB: 0)) == 0)
        #expect(AssemblyLoudness.normalizationGainDB(for: metrics(replayGainDB: 6, truePeakDBFS: -.infinity)) == 0)
    }

    @Test func perceivedVolumeAccountsForNormalization() {
        let quiet = metrics(replayGainDB: 6)
        #expect(AssemblyLoudness.perceivedVolumeDB(for: quiet, target: 89, isNormalizing: false) == 83)
        #expect(AssemblyLoudness.perceivedVolumeDB(for: quiet, target: 89, isNormalizing: true) == 89)
    }

    // MARK: - Rule behaviour

    private func loudnessIssues(replayGainDB: Double, isNormalizing: Bool) -> [ValidationIssue] {
        var project = ProjectFixtures.typical()
        project.profile.intendedDestination = .librivox
        project.profile.assembly.normalizeLoudness = isNormalizing

        var perTake: [UUID: AudioQualityMetrics] = [:]
        for paragraph in project.allParagraphs {
            guard let takeID = paragraph.selectedTakeID else { continue }
            perTake[takeID] = metrics(replayGainDB: replayGainDB)
        }
        #expect(!perTake.isEmpty, "fixture must have selected takes to measure")

        return ValidationRuleEngine().evaluate(
            project: project,
            metrics: perTake,
            profile: DestinationProfile.profile(for: .librivox),
            eligibility: EligibilityProfile.evaluate(project),
            assembly: project.profile.assembly
        ).filter { $0.code == .perceivedVolumeOutOfBand }
    }

    @Test func aQuietTakeOutOfBandOffersNormalizationAsTheFix() {
        let issues = loudnessIssues(replayGainDB: 12, isNormalizing: false)
        #expect(!issues.isEmpty)
        #expect(issues.allSatisfy { $0.fix == .normalizeLoudness },
                "the narrator must be given a control, not just a warning")
    }

    @Test func normalizationBringingATakeIntoBandClearsTheIssue() {
        // 89 − 6 = 83 dB, below the 86–92 band; normalization lands it on 89.
        #expect(!loudnessIssues(replayGainDB: 6, isNormalizing: false).isEmpty)
        #expect(loudnessIssues(replayGainDB: 6, isNormalizing: true).isEmpty,
                "validation must judge the audio that will actually be exported")
    }

    @Test func aTakeNormalizationCannotRescueAsksForARetake() {
        // The clamp caps the gain, so a take this quiet stays out of band.
        let issues = loudnessIssues(replayGainDB: 40, isNormalizing: true)
        #expect(!issues.isEmpty)
        #expect(issues.allSatisfy {
            if case .recordParagraph = $0.fix { return true }
            return false
        })
    }
}
