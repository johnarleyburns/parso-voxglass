import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// Spec §11.5 / §19.4: an AI-origin take flips LibriVox eligibility once it is
/// the selected take; a human import keeps eligibility; an unselected AI take
/// does not count.
struct AIOriginLabelTests {

    @Test func aiImportedSelectedTakeFlipsEligibility() {
        let profile = EligibilityProfile.evaluate(ProjectFixtures.aiTainted())
        #expect(profile.narrationOrigin == .containsImportedAI)
        #expect(!profile.librivoxEligible)
        #expect(profile.aiParagraphCount == 1)
        #expect(profile.aiParagraphIDs.count == 1)
    }

    @Test func unselectedAITakeDoesNotFlipEligibility() {
        let profile = EligibilityProfile.evaluate(ProjectFixtures.aiUnselected())
        #expect(profile.narrationOrigin == .humanOnly)
        #expect(profile.librivoxEligible)
        #expect(profile.aiParagraphCount == 0)
    }

    @Test func importedHumanTakeKeepsEligibility() {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let paragraphID = ids.next()
        let take = Take(
            id: ids.next(),
            paragraphID: paragraphID,
            assetRef: AudioAssetReference(sha256: "h", relativePath: "Audio/Original/h.wav", byteCount: 10, contentType: "audio/wav"),
            origin: .importedHuman(sourceFilename: "narration.wav"),
            recordedAt: clock.now,
            duration: 2.0,
            format: AudioFormatDescription(sampleRate: 48_000, channels: 1, codec: "pcm"),
            textHashAtRecording: "hash"
        )
        let paragraph = Paragraph(id: paragraphID, ordinal: 0, text: "T", textHash: "hash", takes: [take], selectedTakeID: take.id)
        let chapter = ProductionChapter(id: ids.next(), ordinal: 0, title: "C", paragraphs: [paragraph])
        let project = AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(title: "B", author: "A", narrator: "N"),
            chapters: [chapter],
            createdAt: clock.now,
            modifiedAt: clock.now
        )

        let profile = EligibilityProfile.evaluate(project)
        #expect(profile.librivoxEligible)
        #expect(profile.humanParagraphCount == 1)
    }

    @Test func unknownImportIsNotHumanNarration() {
        let origin = AudioOrigin.unknownImport(sourceFilename: "x.wav")
        #expect(!origin.isHumanNarration)
        #expect(AudioOrigin.importedHuman(sourceFilename: "y.wav").isHumanNarration)
        #expect(AudioOrigin.recorded.isHumanNarration)
    }
}
