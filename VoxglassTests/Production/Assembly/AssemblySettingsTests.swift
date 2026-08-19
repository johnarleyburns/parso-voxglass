import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// Mockup 10 toggles (§11.1): trim-at-edges and normalise-loudness are part of
/// the assembly plan. The new settings are optional so projects persisted
/// before they existed decode unchanged; the segment builder applies them from
/// the take's own measurements (never guessed).
@Suite struct AssemblySettingsTests {

    @Test func newTogglesDefaultOn() {
        let settings = AssemblySettings()
        #expect(settings.isTrimmingSilenceAtEdges)
        #expect(settings.isNormalizingLoudness)
    }

    @Test func legacyJSONDecodesWithDefaults() throws {
        // A project saved before the toggles existed has no keys for them.
        let legacy = """
        {"paragraphGap":0.45,"sentenceGapBonus":0.0,"chapterHeadSilence":0.75,"chapterTailSilence":1.5,"sceneBreakExtraGap":1.0,"normalizeGapsFromTakeSilence":true}
        """
        let settings = try JSONDecoder().decode(AssemblySettings.self, from: Data(legacy.utf8))
        #expect(settings.trimSilenceAtEdges == nil)
        #expect(settings.isTrimmingSilenceAtEdges)
        #expect(settings.isNormalizingLoudness)
        #expect(settings.paragraphGap == 0.45)
    }

    @Test func explicitToggleSurvivesRoundTrip() throws {
        var settings = AssemblySettings()
        settings.trimSilenceAtEdges = false
        settings.normalizeLoudness = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AssemblySettings.self, from: data)
        #expect(!decoded.isTrimmingSilenceAtEdges)
        #expect(!decoded.isNormalizingLoudness)
    }

    @Test func trimAndNormaliseShapeSegments() {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()

        // A take whose measured edges are quiet (leading 0.4 s, trailing 0.3 s)
        // and whose ReplayGain says +2.0 dB.
        let paragraphID = ids.next()
        let takeID = ids.next()
        let text = "A paragraph with measurable edge silence and loudness."
        let hash = SHA256Hex.hex(Data(text.utf8))
        let metrics = AudioQualityMetrics(
            peakDBFS: -4, truePeakDBFS: -4.5, rmsDBFS: -20, noiseFloorDBFS: -62,
            noiseFloorReliable: true, replayGainDB: 2.0, clipCount: 0, dcOffset: 0,
            leadingSilence: 0.4, trailingSilence: 0.3, duration: 5,
            sampleRate: 44_100, channels: 1, computedAt: clock.now,
            analyzerVersion: AudioMetricsCalculator.analyzerVersion
        )
        let take = Take(
            id: takeID, paragraphID: paragraphID,
            assetRef: AudioAssetReference(sha256: "h", relativePath: "Audio/Original/hh/ee/h.wav", byteCount: 100, contentType: "public.wav"),
            origin: .recorded, recordedAt: clock.now, duration: 5,
            format: AudioFormatDescription(sampleRate: 44_100, channels: 1, codec: "pcm"),
            metrics: metrics, textHashAtRecording: hash
        )
        let paragraph = Paragraph(id: paragraphID, ordinal: 0, text: text, textHash: hash, takes: [take], selectedTakeID: takeID)
        let chapter = ProductionChapter(id: ids.next(), ordinal: 0, title: "C", paragraphs: [paragraph])
        let project = AudiobookProject(
            id: ids.next(), metadata: BookMetadata(title: "B", author: "A", narrator: "N"),
            chapters: [chapter], createdAt: clock.now, modifiedAt: clock.now
        )

        let trimmed = SegmentQueueBuilder().build(.chapter(chapter.id), from: project, settings: AssemblySettings(trimSilenceAtEdges: true, normalizeLoudness: true))
        #expect(trimmed.count == 1)
        let segment = trimmed[0]
        #expect(abs(segment.trim.lowerBound - 0.4) < 0.001)
        #expect(abs(segment.trim.upperBound - 4.7) < 0.001)
        // ReplayGain is the gain *to apply* to reach the reference level
        // (`ReplayGainCalculator`: gainDB = -25.4885 - L95), so normalization
        // adds it. Subtracting it — which this assertion used to require —
        // doubled the deviation instead of removing it, and is why
        // `perceivedVolumeOutOfBand` never cleared (field report 2026-08-19).
        // The +2.0 dB request fits inside the peak head room (-4.5 dBFS), so
        // the clamp does not bite here.
        #expect(abs(segment.gainDB - 2.0) < 0.001)

        // Toggling both off leaves the take untouched in the plan.
        let raw = SegmentQueueBuilder().build(.chapter(chapter.id), from: project, settings: AssemblySettings(trimSilenceAtEdges: false, normalizeLoudness: false))
        #expect(raw[0].trim == 0.0..<5.0)
        #expect(raw[0].gainDB == 0)
    }
}
