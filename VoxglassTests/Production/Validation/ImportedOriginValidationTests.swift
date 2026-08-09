import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// P6 acceptance (spec §10): an imported non-human-origin take blocks LibriVox
/// validation; a human import keeps eligibility. The origin declaration is
/// compliance metadata — the engine reads it from the selected take.
@Suite struct ImportedOriginValidationTests {

    private static func importedProject(origin: AudioOrigin) -> AudiobookProject {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let paragraphID = ids.next()
        let takeID = ids.next()
        let text = "An imported paragraph."
        let hash = SHA256Hex.hex(Data(text.utf8))
        let take = Take(
            id: takeID,
            paragraphID: paragraphID,
            assetRef: AudioAssetReference(sha256: "imported", relativePath: "Audio/Original/im/po/imported.wav", byteCount: 500, contentType: "public.wav"),
            origin: origin,
            recordedAt: clock.now,
            duration: 3.0,
            format: AudioFormatDescription(sampleRate: 44_100, channels: 1, codec: "pcm"),
            textHashAtRecording: hash
        )
        let paragraph = Paragraph(id: paragraphID, ordinal: 0, text: text, textHash: hash, takes: [take], selectedTakeID: takeID)
        let chapter = ProductionChapter(id: ids.next(), ordinal: 0, title: "Chapter 1", paragraphs: [paragraph])
        return AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(title: "Imported Book", author: "Author", narrator: "Narrator"),
            chapters: [chapter],
            createdAt: clock.now,
            modifiedAt: clock.now
        )
    }

    private static func run(_ project: AudiobookProject, target: DestinationID) -> [ValidationIssue] {
        ValidationRuleEngine().evaluate(
            project: project,
            metrics: PackagingSupport.selectedTakeMetrics(project),
            profile: DestinationProfile.profile(for: target),
            eligibility: EligibilityProfile.evaluate(project),
            assembly: project.profile.assembly
        )
    }

    @Test func importedAITakeBlocksLibriVoxValidation() {
        let issues = Self.run(Self.importedProject(origin: .aiImported(providerLabel: "sample.wav")), target: .librivox)
        let origin = issues.filter { $0.code == .aiOriginInLibriVoxProject }
        #expect(!origin.isEmpty)
        #expect(origin.allSatisfy { $0.severity == .blocking })
    }

    @Test func unknownImportTakeBlocksLibriVoxValidation() {
        let issues = Self.run(Self.importedProject(origin: .unknownImport(sourceFilename: "mystery.wav")), target: .librivox)
        let origin = issues.filter { $0.code == .unknownOriginTakeSelected }
        #expect(!origin.isEmpty)
        #expect(origin.allSatisfy { $0.severity == .blocking })
    }

    @Test func importedHumanTakeKeepsLibriVoxEligibility() {
        let issues = Self.run(Self.importedProject(origin: .importedHuman(sourceFilename: "myself.wav")), target: .librivox)
        #expect(issues.filter { $0.code == .aiOriginInLibriVoxProject }.isEmpty)
        #expect(issues.filter { $0.code == .unknownOriginTakeSelected }.isEmpty)
        #expect(EligibilityProfile.evaluate(Self.importedProject(origin: .importedHuman(sourceFilename: "myself.wav"))).librivoxEligible)
    }

    @Test func importedAITakeNeedsDisclosureForInternetArchive() {
        let project = Self.importedProject(origin: .aiImported(providerLabel: "sample.wav"))
        let undisclosed = Self.run(project, target: .internetArchive)
        #expect(undisclosed.contains { $0.code == .undisclosedAINarration && $0.severity == .blocking })
    }
}
