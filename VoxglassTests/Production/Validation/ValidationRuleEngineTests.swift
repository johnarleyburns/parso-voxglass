import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// One test per rule code in §15.3 (§19.3). The test named
/// `test_aiOriginBlocksLibriVox_AIblocksLibriVox` is required by CI grep gate G-6.
@Suite struct ValidationRuleEngineTests {

    // MARK: - Fixture helpers

    private func validMetadata(
        title: String = "Test Book",
        cover: AudioAssetReference? = AudioAssetReference(sha256: "c", relativePath: "a/b.wav", byteCount: 1, contentType: "image/jpeg")
    ) -> BookMetadata {
        BookMetadata(
            title: title, author: "Author", narrator: "Narrator", language: "en-US",
            description: "A test book.", publisher: "Publisher", copyrightYear: 2026,
            coverRef: cover, archiveIdentifier: "test_book_author_narrator"
        )
    }

    private func validRights(
        basis: RightsBasis = .publicDomainUS,
        attested: Bool = true
    ) -> RightsEvidence {
        RightsEvidence(
            basis: basis,
            sourceURL: URL(string: "https://www.gutenberg.org/ebooks/1"),
            editionYear: 1926,
            attestedAt: attested ? Date() : nil,
            attestedBy: "Test"
        )
    }

    private func baseProject(
        chapters: [ProductionChapter],
        metadata: BookMetadata? = nil,
        rights: RightsEvidence? = nil,
        profile: ProductionProfile = ProductionProfile()
    ) -> AudiobookProject {
        AudiobookProject(
            id: UUID(),
            metadata: metadata ?? validMetadata(),
            rights: rights ?? validRights(),
            profile: profile,
            chapters: chapters
        )
    }

    private func chapter(_ paragraphs: [Paragraph], title: String = "Chapter 1", role: ChapterRole = .body) -> ProductionChapter {
        ProductionChapter(id: UUID(), ordinal: 0, title: title, role: role, paragraphs: paragraphs)
    }

    private func bareParagraph(_ text: String, role: ParagraphRole = .body, state: ReviewState = .unreviewed, ordinal: Int = 0) -> Paragraph {
        Paragraph(id: UUID(), ordinal: ordinal, text: text, textHash: TextNormalizer.hash(text), role: role, reviewState: state)
    }

    private func recordedParagraph(
        _ text: String,
        paragraphID: UUID = UUID(),
        takeID: UUID = UUID(),
        origin: AudioOrigin = .recorded,
        duration: TimeInterval = 5,
        metrics: AudioQualityMetrics? = nil,
        state: ReviewState = .unreviewed,
        sampleRate: Double = 48_000,
        channels: Int = 1,
        recordedHash: String? = nil,
        ordinal: Int = 0
    ) -> Paragraph {
        let hash = TextNormalizer.hash(text)
        let take = Take(
            id: takeID, paragraphID: paragraphID,
            assetRef: AudioAssetReference(sha256: "a", relativePath: "Audio/Original/a.wav", byteCount: 100, contentType: "public.wav"),
            origin: origin, recordedAt: Date(), duration: duration,
            format: AudioFormatDescription(sampleRate: sampleRate, channels: channels, bitDepth: 24, codec: "pcm"),
            metrics: metrics, textHashAtRecording: recordedHash ?? hash
        )
        return Paragraph(
            id: paragraphID, ordinal: ordinal, text: text, textHash: hash,
            takes: [take], selectedTakeID: takeID, reviewState: state
        )
    }

    private func metrics(
        peak: Double = -3, truePeak: Double = -4, rms: Double = -20,
        noiseFloor: Double = -65, noiseReliable: Bool = true,
        replayGain: Double = 0, clips: Int = 0, dc: Double = 0,
        leading: TimeInterval = 0.1, trailing: TimeInterval = 0.2,
        duration: TimeInterval = 5, sampleRate: Double = 48_000,
        channels: Int = 1, version: Int = 1
    ) -> AudioQualityMetrics {
        AudioQualityMetrics(
            peakDBFS: peak, truePeakDBFS: truePeak, rmsDBFS: rms,
            noiseFloorDBFS: noiseFloor, noiseFloorReliable: noiseReliable,
            replayGainDB: replayGain, clipCount: clips, dcOffset: dc,
            leadingSilence: leading, trailingSilence: trailing,
            duration: duration, sampleRate: sampleRate, channels: channels,
            analyzerVersion: version
        )
    }

    private func run(
        project: AudiobookProject,
        target: DestinationID,
        metrics: [UUID: AudioQualityMetrics] = [:],
        context: ValidationContext = ValidationContext(),
        assembly: AssemblySettings? = nil
    ) -> [ValidationIssue] {
        let profile = DestinationProfile.profile(for: target)
        let eligibility = EligibilityProfile.evaluate(project)
        let settings = assembly ?? project.profile.assembly
        return ValidationRuleEngine().evaluate(
            project: project, metrics: metrics, profile: profile,
            eligibility: eligibility, assembly: settings, context: context
        )
    }

    private func issues(_ code: IssueCode, _ list: [ValidationIssue]) -> [ValidationIssue] {
        list.filter { $0.code == code }
    }

    // MARK: - Group 1 — Metadata and rights

    @Test func missingTitle() {
        let project = baseProject(chapters: [], metadata: validMetadata(title: "  "))
        #expect(issues(.missingTitle, run(project: project, target: .librivox)).count == 1)
        #expect(issues(.missingTitle, run(project: project, target: .librivox)).first?.severity == .blocking)
        #expect(issues(.missingTitle, run(project: project, target: .personalMaster)).first?.severity == .warning)
    }

    @Test func missingAuthorAndNarrator() {
        var metadata = validMetadata()
        metadata.author = ""
        metadata.narrator = ""
        let project = baseProject(chapters: [], metadata: metadata)
        #expect(issues(.missingAuthor, run(project: project, target: .librivox)).count == 1)
        #expect(issues(.missingNarrator, run(project: project, target: .librivox)).count == 1)
        #expect(issues(.missingAuthor, run(project: project, target: .personalMaster)).isEmpty)
    }

    @Test func missingLanguage() {
        var metadata = validMetadata()
        metadata.language = ""
        let empty = baseProject(chapters: [], metadata: metadata)
        #expect(issues(.missingLanguage, run(project: empty, target: .librivox)).count == 1)

        var bad = validMetadata()
        bad.language = "!!"
        let invalid = baseProject(chapters: [], metadata: bad)
        #expect(issues(.missingLanguage, run(project: invalid, target: .acx)).count == 1)
    }

    @Test func missingDescription() {
        var metadata = validMetadata()
        metadata.description = ""
        let project = baseProject(chapters: [], metadata: metadata)
        #expect(issues(.missingDescription, run(project: project, target: .librivox)).first?.severity == .warning)
        #expect(issues(.missingDescription, run(project: project, target: .acx)).first?.severity == .blocking)
    }

    @Test func missingSourceURL() {
        let project = baseProject(chapters: [], rights: validRights().settingSourceURL(nil))
        #expect(issues(.missingSourceURL, run(project: project, target: .librivox)).first?.severity == .blocking)
        #expect(issues(.missingSourceURL, run(project: project, target: .internetArchive)).first?.severity == .warning)
    }

    @Test func missingRightsBasisNeverFires() {
        let project = baseProject(chapters: [])
        #expect(issues(.missingRightsBasis, run(project: project, target: .librivox)).isEmpty)
    }

    @Test func personalRightsForPublicTarget() {
        let project = baseProject(chapters: [], rights: validRights(basis: .personalUseOnly))
        #expect(issues(.personalRightsForPublicTarget, run(project: project, target: .librivox)).count == 1)
    }

    @Test func unattestedRights() {
        let project = baseProject(chapters: [], rights: validRights(attested: false))
        #expect(issues(.unattestedRights, run(project: project, target: .librivox)).count == 1)
        #expect(issues(.unattestedRights, run(project: project, target: .personalMaster)).isEmpty)
    }

    @Test func missingCoverArt() {
        let project = baseProject(chapters: [], metadata: validMetadata(cover: nil))
        #expect(issues(.missingCoverArt, run(project: project, target: .librivox)).first?.severity == .warning)
        #expect(issues(.missingCoverArt, run(project: project, target: .acx)).first?.severity == .blocking)
    }

    @Test func artworkTooSmall() {
        let project = baseProject(chapters: [])
        let context = ValidationContext(artworkPixelSize: (900, 900))
        #expect(issues(.artworkTooSmall, run(project: project, target: .internetArchive, context: context)).first?.severity == .warning)
        #expect(issues(.artworkTooSmall, run(project: project, target: .acx, context: context)).first?.severity == .blocking)
    }

    @Test func artworkNotSquare() {
        let project = baseProject(chapters: [])
        let context = ValidationContext(artworkPixelSize: (1000, 500))
        #expect(issues(.artworkNotSquare, run(project: project, target: .acx, context: context)).count == 1)
        let contextOK = ValidationContext(artworkPixelSize: (2400, 2400))
        #expect(issues(.artworkNotSquare, run(project: project, target: .acx, context: contextOK)).isEmpty)
    }

    @Test func missingCopyrightYear() {
        var metadata = validMetadata()
        metadata.copyrightYear = nil
        let project = baseProject(chapters: [], metadata: metadata)
        #expect(issues(.missingCopyrightYear, run(project: project, target: .internetArchive)).first?.severity == .warning)
        #expect(issues(.missingCopyrightYear, run(project: project, target: .acx)).first?.severity == .blocking)
    }

    @Test func missingPublisher() {
        var metadata = validMetadata()
        metadata.publisher = nil
        let project = baseProject(chapters: [], metadata: metadata)
        #expect(issues(.missingPublisher, run(project: project, target: .acx)).count == 1)
        #expect(issues(.missingPublisher, run(project: project, target: .librivox)).isEmpty)
    }

    @Test func missingArchiveIdentifier() {
        var metadata = validMetadata()
        metadata.archiveIdentifier = nil
        let project = baseProject(chapters: [], metadata: metadata)
        #expect(issues(.missingArchiveIdentifier, run(project: project, target: .internetArchive)).count == 1)
        #expect(issues(.missingArchiveIdentifier, run(project: project, target: .librivox)).isEmpty)
    }

    @Test func invalidArchiveIdentifier() {
        var metadata = validMetadata()
        metadata.archiveIdentifier = "bad id!"
        let project = baseProject(chapters: [], metadata: metadata)
        #expect(issues(.invalidArchiveIdentifier, run(project: project, target: .internetArchive)).count == 1)
    }

    // MARK: - Group 2 — Narration origin and eligibility

    @Test func test_aiOriginBlocksLibriVox_AIblocksLibriVox() {
        let project = ProjectFixtures.aiTainted()
        let result = run(project: project, target: .librivox)
        #expect(issues(.aiOriginInLibriVoxProject, result).count == 1)
        #expect(issues(.aiOriginInLibriVoxProject, result).first?.severity == .blocking)
    }

    @Test func unknownOriginTakeSelected() {
        let paragraph = recordedParagraph("Hi there.", origin: .unknownImport(sourceFilename: "x.wav"))
        let project = baseProject(chapters: [chapter([paragraph])])
        #expect(issues(.unknownOriginTakeSelected, run(project: project, target: .internetArchive)).count == 1)
        #expect(issues(.unknownOriginTakeSelected, run(project: project, target: .internetArchive)).first?.severity == .warning)
    }

    @Test func undisclosedAINarration() {
        let project = ProjectFixtures.aiTainted()
        let result = run(project: project, target: .internetArchive)
        #expect(issues(.undisclosedAINarration, result).count == 1)
        let disclosed = run(project: project, target: .internetArchive, context: ValidationContext(aiDisclosurePresent: true))
        #expect(issues(.undisclosedAINarration, disclosed).isEmpty)
    }

    // MARK: - Group 3 — Completeness and structure

    @Test func missingAcceptedTake() {
        let project = baseProject(chapters: [chapter([bareParagraph("Unrecorded text")])])
        #expect(issues(.missingAcceptedTake, run(project: project, target: .librivox)).count == 1)
        #expect(issues(.missingAcceptedTake, run(project: project, target: .librivox)).first?.severity == .blocking)
        #expect(issues(.missingAcceptedTake, run(project: project, target: .personalMaster)).first?.severity == .warning)
    }

    @Test func unresolvedNeedsPickup() {
        let paragraph = recordedParagraph("Pick me up", state: .needsPickup)
        let project = baseProject(chapters: [chapter([paragraph])])
        #expect(issues(.unresolvedNeedsPickup, run(project: project, target: .librivox)).count == 1)
        #expect(issues(.unresolvedNeedsPickup, run(project: project, target: .librivox)).first?.severity == .blocking)
    }

    @Test func unapprovedParagraphs() {
        let paragraph = recordedParagraph("Recorded but not approved", state: .unreviewed)
        let project = baseProject(chapters: [chapter([paragraph])])
        let result = run(project: project, target: .librivox)
        #expect(issues(.unapprovedParagraphs, result).count == 1)
        #expect(issues(.unapprovedParagraphs, result).first?.severity == .warning)

        let approved = recordedParagraph("Approved", state: .approved)
        let clean = baseProject(chapters: [chapter([approved])])
        #expect(issues(.unapprovedParagraphs, run(project: clean, target: .librivox)).isEmpty)
    }

    @Test func textChangedAfterRecording() {
        let takeID = UUID()
        let paragraph = recordedParagraph(
            "Completely rewritten sentence now.",
            takeID: takeID,
            state: .needsPickup,
            recordedHash: TextNormalizer.hash("The original sentence was different.")
        )
        let project = baseProject(chapters: [chapter([paragraph])])
        #expect(issues(.textChangedAfterRecording, run(project: project, target: .librivox)).count == 1)
        #expect(issues(.textChangedAfterRecording, run(project: project, target: .librivox)).first?.severity == .blocking)
    }

    @Test func textChangedCosmetically() {
        let takeID = UUID()
        let paragraph = recordedParagraph(
            "A minor change to this text.",
            takeID: takeID,
            state: .unreviewed,
            recordedHash: TextNormalizer.hash("A minor change to that text.")
        )
        let project = baseProject(chapters: [chapter([paragraph])])
        #expect(issues(.textChangedCosmetically, run(project: project, target: .librivox)).count == 1)
        #expect(issues(.textChangedCosmetically, run(project: project, target: .librivox)).first?.severity == .warning)
    }

    @Test func emptyChapter() {
        let project = baseProject(chapters: [ProductionChapter(id: UUID(), ordinal: 0, title: "Empty", paragraphs: [])])
        #expect(issues(.emptyChapter, run(project: project, target: .librivox)).count == 1)
        #expect(issues(.emptyChapter, run(project: project, target: .personalMaster)).first?.severity == .warning)
    }

    @Test func duplicateOrdinal() {
        let project = baseProject(chapters: [])
        let finding = IntegrityFinding(severity: .blocking, code: .duplicateChapterOrdinal, message: "dup")
        let context = ValidationContext(integrityFindings: [finding])
        #expect(issues(.duplicateOrdinal, run(project: project, target: .librivox, context: context)).count == 1)
    }

    @Test func missingOrdinal() {
        let project = baseProject(chapters: [])
        let finding = IntegrityFinding(severity: .warning, code: .missingChapterOrdinal, message: "missing")
        let context = ValidationContext(integrityFindings: [finding])
        #expect(issues(.missingOrdinal, run(project: project, target: .librivox, context: context)).count == 1)
    }

    @Test func assetMissing() {
        let project = baseProject(chapters: [])
        let finding = IntegrityFinding(severity: .blocking, code: .takeAssetMissing, message: "gone")
        let context = ValidationContext(integrityFindings: [finding])
        #expect(issues(.assetMissing, run(project: project, target: .acx, context: context)).count == 1)
    }

    @Test func assetHashMismatch() {
        let project = baseProject(chapters: [])
        let finding = IntegrityFinding(severity: .blocking, code: .takeAssetHashMismatch, message: "hash")
        let context = ValidationContext(integrityFindings: [finding])
        #expect(issues(.assetHashMismatch, run(project: project, target: .acx, context: context)).count == 1)
    }

    @Test func missingDisclaimerParagraph() {
        let project = baseProject(chapters: [chapter([bareParagraph("Body text")])])
        let result = run(project: project, target: .librivox)
        #expect(issues(.missingDisclaimerParagraph, result).count == 2)  // intro + outro
        #expect(issues(.missingDisclaimerParagraph, result).first?.severity == .blocking)
    }

    @Test func unrecordedDisclaimer() {
        let intro = bareParagraph("Chapter 1 of Test Book. This is a LibriVox recording.", role: .libriVoxIntro)
        let outro = bareParagraph("End of Chapter 1.", role: .libriVoxOutro)
        let body = recordedParagraph("Body")
        let project = baseProject(chapters: [chapter([intro, body, outro])])
        let result = run(project: project, target: .librivox)
        #expect(issues(.unrecordedDisclaimer, result).count == 2)
    }

    @Test func staleDisclaimerText() {
        let intro = recordedParagraph(
            "This text has drifted from what the generator would produce.",
            paragraphID: UUID(), takeID: UUID(), state: .approved
        )
        var introPara = intro
        introPara.role = .libriVoxIntro
        // The outro matches the generator exactly, so only the intro is stale.
        let outroText = "End of Chapter 1.\nEnd of Test Book, by Author."
        let outro = recordedParagraph(outroText, state: .approved)
        var outroPara = outro
        outroPara.role = .libriVoxOutro
        let project = baseProject(chapters: [chapter([introPara, outroPara])])
        let result = run(project: project, target: .librivox)
        #expect(issues(.staleDisclaimerText, result).count == 1)  // only the intro drifted
        #expect(issues(.staleDisclaimerText, result).first?.paragraphID == introPara.id)
    }

    @Test func missingOpeningAndClosingCredits() {
        let project = baseProject(chapters: [chapter([recordedParagraph("Body")])])
        let result = run(project: project, target: .acx)
        #expect(issues(.missingOpeningCredits, result).count == 1)
        #expect(issues(.missingClosingCredits, result).count == 1)
    }

    @Test func recordedCreditsPass() {
        let opening = recordedParagraph("Test Book. Written by Author. Narrated by Narrator.", state: .approved)
        var openingPara = opening
        openingPara.role = .retailOpeningCredits
        let closing = recordedParagraph("The end.", state: .approved)
        var closingPara = closing
        closingPara.role = .retailClosingCredits
        let openingChapter = ProductionChapter(id: UUID(), ordinal: 0, title: "Opening Credits", role: .openingCredits, paragraphs: [openingPara])
        let closingChapter = ProductionChapter(id: UUID(), ordinal: 1, title: "Closing Credits", role: .closingCredits, paragraphs: [closingPara])
        let project = baseProject(chapters: [openingChapter, closingChapter])
        let result = run(project: project, target: .acx, context: ValidationContext(retailSample: RetailSampleSelection(startParagraphID: UUID(), duration: 120)))
        #expect(issues(.missingOpeningCredits, result).isEmpty)
        #expect(issues(.missingClosingCredits, result).isEmpty)
    }

    @Test func missingRetailSample() {
        let project = baseProject(chapters: [])
        #expect(issues(.missingRetailSample, run(project: project, target: .acx)).count == 1)
    }

    @Test func retailSampleTooShortAndTooLong() {
        let project = baseProject(chapters: [])
        let short = ValidationContext(retailSample: RetailSampleSelection(startParagraphID: UUID(), duration: 30))
        #expect(issues(.retailSampleTooShort, run(project: project, target: .acx, context: short)).count == 1)
        let long = ValidationContext(retailSample: RetailSampleSelection(startParagraphID: UUID(), duration: 400))
        #expect(issues(.retailSampleTooLong, run(project: project, target: .acx, context: long)).count == 1)
        let ok = ValidationContext(retailSample: RetailSampleSelection(startParagraphID: UUID(), duration: 120))
        #expect(issues(.retailSampleTooShort, run(project: project, target: .acx, context: ok)).isEmpty)
        #expect(issues(.retailSampleTooLong, run(project: project, target: .acx, context: ok)).isEmpty)
    }

    @Test func retailSampleStartsInCredits() {
        let credits = recordedParagraph("Credits text", state: .approved)
        var creditsPara = credits
        creditsPara.role = .retailOpeningCredits
        let project = baseProject(chapters: [chapter([creditsPara])])
        let context = ValidationContext(retailSample: RetailSampleSelection(startParagraphID: creditsPara.id, duration: 120))
        #expect(issues(.retailSampleStartsInCredits, run(project: project, target: .acx, context: context)).count == 1)
    }

    @Test func chapterTooLong() {
        let longTake = recordedParagraph("Body with a long take", duration: 8000)
        let project = baseProject(chapters: [chapter([longTake])])
        let result = run(project: project, target: .acx)
        #expect(issues(.chapterTooLong, result).count == 1)
        #expect(issues(.chapterTooLong, result).first?.severity == .blocking)
        // LibriVox has no hard cap → warning-level rule never fires as blocking.
        #expect(issues(.chapterTooLong, run(project: project, target: .librivox)).isEmpty)
    }

    @Test func chapterVeryLong() {
        let longTake = recordedParagraph("Body", duration: 4000)
        let project = baseProject(chapters: [chapter([longTake])])
        #expect(issues(.chapterVeryLong, run(project: project, target: .librivox)).count == 1)
    }

    // MARK: - Group 4 — Audio quality

    @Test func clipping() {
        let takeID = UUID()
        let paragraph = recordedParagraph("Clipped", takeID: takeID, metrics: metrics(clips: 2))
        let project = baseProject(chapters: [chapter([paragraph])])
        let result = run(project: project, target: .librivox, metrics: [takeID: metrics(clips: 2)])
        #expect(issues(.clipping, result).count == 1)
        #expect(issues(.clipping, result).first?.severity == .blocking)
    }

    @Test func peakTooHot() {
        let takeID = UUID()
        let paragraph = recordedParagraph("Hot", takeID: takeID)
        let project = baseProject(chapters: [chapter([paragraph])])
        let hot = metrics(truePeak: -2.0)
        let result = run(project: project, target: .acx, metrics: [takeID: hot])
        #expect(issues(.peakTooHot, result).count == 1)
        #expect(issues(.peakTooHot, result).first?.severity == .blocking)
        let cool = metrics(truePeak: -6.0)
        #expect(issues(.peakTooHot, run(project: project, target: .acx, metrics: [takeID: cool])).isEmpty)
    }

    @Test func peakTooLow() {
        let takeID = UUID()
        let paragraph = recordedParagraph("Quiet", takeID: takeID)
        let project = baseProject(chapters: [chapter([paragraph])])
        let result = run(project: project, target: .librivox, metrics: [takeID: metrics(peak: -30)])
        #expect(issues(.peakTooLow, result).count == 1)
    }

    @Test func rmsOutOfRange() {
        let takeID = UUID()
        let paragraph = recordedParagraph("Too quiet", takeID: takeID)
        let project = baseProject(chapters: [chapter([paragraph])])
        let result = run(project: project, target: .acx, metrics: [takeID: metrics(rms: -30)])
        #expect(issues(.rmsOutOfRange, result).count == 1)
        #expect(issues(.rmsOutOfRange, result).first?.severity == .blocking)
        let inBand = metrics(rms: -20)
        #expect(issues(.rmsOutOfRange, run(project: project, target: .acx, metrics: [takeID: inBand])).isEmpty)
        #expect(issues(.rmsOutOfRange, run(project: project, target: .librivox, metrics: [takeID: metrics(rms: -30)])).isEmpty)
    }

    @Test func noiseFloorTooHigh() {
        let takeID = UUID()
        let paragraph = recordedParagraph("Noisy", takeID: takeID)
        let project = baseProject(chapters: [chapter([paragraph])])
        let result = run(project: project, target: .acx, metrics: [takeID: metrics(noiseFloor: -50)])
        #expect(issues(.noiseFloorTooHigh, result).count == 1)
        #expect(issues(.noiseFloorTooHigh, result).first?.severity == .blocking)
    }

    @Test func noiseFloorUnreliable() {
        let takeID = UUID()
        let paragraph = recordedParagraph("No silence", takeID: takeID)
        let project = baseProject(chapters: [chapter([paragraph])])
        let result = run(project: project, target: .librivox, metrics: [takeID: metrics(noiseReliable: false)])
        #expect(issues(.noiseFloorUnreliable, result).count == 1)
    }

    @Test func dcOffset() {
        let takeID = UUID()
        let paragraph = recordedParagraph("Offset", takeID: takeID)
        let project = baseProject(chapters: [chapter([paragraph])])
        let result = run(project: project, target: .librivox, metrics: [takeID: metrics(dc: 0.005)])
        #expect(issues(.dcOffset, result).count == 1)
    }

    @Test func sampleRateMismatch() {
        let idA = UUID(), idB = UUID(), idC = UUID()
        let a = recordedParagraph("A", takeID: idA, sampleRate: 48_000)
        let b = recordedParagraph("B", takeID: idB, sampleRate: 48_000)
        let c = recordedParagraph("C", takeID: idC, sampleRate: 44_100)
        let project = baseProject(chapters: [chapter([a, b, c])])
        let result = run(project: project, target: .librivox, metrics: [idA: metrics(sampleRate: 48_000), idB: metrics(sampleRate: 48_000), idC: metrics(sampleRate: 44_100)])
        #expect(issues(.sampleRateMismatch, result).count == 1)
    }

    @Test func channelInconsistency() {
        let idA = UUID(), idB = UUID(), idC = UUID()
        let a = recordedParagraph("A", takeID: idA, channels: 1)
        let b = recordedParagraph("B", takeID: idB, channels: 1)
        let c = recordedParagraph("C", takeID: idC, channels: 2)
        let project = baseProject(chapters: [chapter([a, b, c])])
        let result = run(project: project, target: .librivox, metrics: [idA: metrics(channels: 1), idB: metrics(channels: 1), idC: metrics(channels: 2)])
        #expect(issues(.channelInconsistency, result).count == 1)
        #expect(issues(.channelInconsistency, result).first?.severity == .blocking)
    }

    @Test func stereoWhereMonoExpected() {
        let takeID = UUID()
        let paragraph = recordedParagraph("Stereo", takeID: takeID, channels: 2)
        let project = baseProject(chapters: [chapter([paragraph])])
        let result = run(project: project, target: .librivox, metrics: [takeID: metrics(channels: 2)])
        #expect(issues(.stereoWhereMonoExpected, result).count == 1)
    }

    @Test func bitDepthMismatch() {
        let idA = UUID(), idB = UUID()
        let a = recordedParagraph("A", takeID: idA)
        let b = recordedParagraph("B", takeID: idB)
        var a2 = a
        a2.takes[0].format.bitDepth = 24
        var b2 = b
        b2.takes[0].format.bitDepth = 16
        let project = baseProject(chapters: [chapter([a2, b2])])
        #expect(issues(.bitDepthMismatch, run(project: project, target: .internetArchive)).count == 1)
        #expect(issues(.bitDepthMismatch, run(project: project, target: .librivox)).isEmpty)
    }

    @Test func loudnessDiscontinuity() {
        let idA = UUID(), idB = UUID()
        let a = recordedParagraph("Loud", takeID: idA)
        let b = recordedParagraph("Quiet", takeID: idB)
        let project = baseProject(chapters: [chapter([a, b])])
        let result = run(project: project, target: .librivox, metrics: [idA: metrics(rms: -20), idB: metrics(rms: -40)])
        #expect(!issues(.loudnessDiscontinuity, result).isEmpty)
    }

    @Test func durationOutlier() {
        let takeID = UUID()
        let paragraph = recordedParagraph("hi", takeID: takeID, duration: 30)
        let project = baseProject(chapters: [chapter([paragraph])])
        let result = run(project: project, target: .librivox, metrics: [takeID: metrics(duration: 30)])
        #expect(issues(.durationOutlier, result).count == 1)
    }

    @Test func suspectedTruncation() {
        let takeID = UUID()
        let paragraph = recordedParagraph("Truncated", takeID: takeID)
        let project = baseProject(chapters: [chapter([paragraph])])
        let context = ValidationContext(truncationEdgeLevels: [takeID: EdgeLevels(leadingDBFS: -20, trailingDBFS: -80)])
        let result = run(project: project, target: .acx, metrics: [takeID: metrics()], context: context)
        #expect(issues(.suspectedTruncation, result).count == 1)
        #expect(issues(.suspectedTruncation, result).first?.severity == .blocking)
    }

    @Test func excessiveLeadingSilence() {
        let takeID = UUID()
        let paragraph = recordedParagraph("Silence", takeID: takeID)
        let project = baseProject(chapters: [chapter([paragraph])])
        let result = run(project: project, target: .librivox, metrics: [takeID: metrics(leading: 3.5)])
        #expect(issues(.excessiveLeadingSilence, result).count == 1)
    }

    @Test func headRoomToneOutOfRange() {
        let takeID = UUID()
        let paragraph = recordedParagraph("Head", takeID: takeID)
        var assembly = AssemblySettings()
        assembly.chapterHeadSilence = 2.5
        let project = baseProject(chapters: [chapter([paragraph])])
        let result = run(project: project, target: .acx, metrics: [takeID: metrics()], assembly: assembly)
        #expect(issues(.headRoomToneOutOfRange, result).count == 1)
    }

    @Test func tailRoomToneOutOfRange() {
        let takeID = UUID()
        let paragraph = recordedParagraph("Tail", takeID: takeID)
        var assembly = AssemblySettings()
        assembly.chapterTailSilence = 8.0
        let project = baseProject(chapters: [chapter([paragraph])])
        let result = run(project: project, target: .acx, metrics: [takeID: metrics()], assembly: assembly)
        #expect(issues(.tailRoomToneOutOfRange, result).count == 1)
    }

    @Test func missingMetrics() {
        let takeID = UUID()
        let paragraph = recordedParagraph("No metrics", takeID: takeID)
        let project = baseProject(chapters: [chapter([paragraph])])
        let result = run(project: project, target: .acx)
        #expect(issues(.missingMetrics, result).count == 1)
        #expect(issues(.missingMetrics, result).first?.severity == .blocking)

        let stale = run(project: project, target: .acx, metrics: [takeID: metrics(version: 0)])
        #expect(issues(.missingMetrics, stale).count == 1)
    }

    // MARK: - Group 5 — LibriVox perceived loudness

    @Test func perceivedVolumeOutOfBand() {
        let takeID = UUID()
        let paragraph = recordedParagraph("Loudness", takeID: takeID)
        let project = baseProject(chapters: [chapter([paragraph])])
        var raw = AssemblySettings()
        raw.normalizeLoudness = false

        let result = run(project: project, target: .librivox, metrics: [takeID: metrics(replayGain: -5)], assembly: raw)
        #expect(issues(.perceivedVolumeOutOfBand, result).count == 1)
        // The narrator is handed a control, not just a warning.
        #expect(issues(.perceivedVolumeOutOfBand, result).first?.fix == .normalizeLoudness)

        let inBand = run(project: project, target: .librivox, metrics: [takeID: metrics(replayGain: 0)], assembly: raw)
        #expect(issues(.perceivedVolumeOutOfBand, inBand).isEmpty)
        #expect(issues(.perceivedVolumeOutOfBand, run(project: project, target: .acx, metrics: [takeID: metrics(replayGain: -5)], assembly: raw)).isEmpty)

        // With render-time normalization on — the default — the exported audio
        // is brought into the band, so there is nothing to warn about
        // (field report 2026-08-19, item 13).
        var normalizing = AssemblySettings()
        normalizing.normalizeLoudness = true
        let normalized = run(project: project, target: .librivox, metrics: [takeID: metrics(replayGain: -5)], assembly: normalizing)
        #expect(issues(.perceivedVolumeOutOfBand, normalized).isEmpty)
    }

    @Test func fixActionsAreAttached() {
        let project = baseProject(chapters: [chapter([bareParagraph("Unrecorded")])])
        let result = run(project: project, target: .librivox)
        let issue = issues(.missingAcceptedTake, result).first
        #expect(issue?.fix != nil)
    }
}

// MARK: - Test helpers

private extension RightsEvidence {
    func settingSourceURL(_ url: URL?) -> RightsEvidence {
        var copy = self
        copy.sourceURL = url
        return copy
    }
}
