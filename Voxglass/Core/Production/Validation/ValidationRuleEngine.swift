import Foundation

/// A configured retail-sample selection for the `retailSample*` rules
/// (§3.4.3). The actual sample duration is resolved by the export pipeline
/// (S8); validation receives it so the [60 s, 300 s] band can be enforced.
public struct RetailSampleSelection: Sendable, Equatable {
    public var startParagraphID: UUID
    public var duration: TimeInterval

    public init(startParagraphID: UUID, duration: TimeInterval) {
        self.startParagraphID = startParagraphID
        self.duration = duration
    }
}

/// Edge loudness of a take, in dBFS, measured over the first and last
/// `ValidationThresholds.truncationEdgeSeconds` of the *trimmed* take. Populated
/// by the analyzer layer (it needs samples, which a pure engine must not touch);
/// absent entries skip the `suspectedTruncation` rule.
public struct EdgeLevels: Sendable, Equatable {
    public var leadingDBFS: Double
    public var trailingDBFS: Double

    public init(leadingDBFS: Double, trailingDBFS: Double) {
        self.leadingDBFS = leadingDBFS
        self.trailingDBFS = trailingDBFS
    }
}

/// External data the engine needs for rules the domain model cannot express
/// alone. Defaults keep the common path (metadata + structure + audio metrics)
/// dependency-free; the Validation screen and export pipeline populate the rest.
public struct ValidationContext: Sendable {
    public var integrityFindings: [IntegrityFinding]
    public var aiDisclosurePresent: Bool
    public var retailSample: RetailSampleSelection?
    public var artworkPixelSize: (width: Int, height: Int)?
    public var truncationEdgeLevels: [UUID: EdgeLevels]

    public var exportPreflight: ExportPreflightContext?

    public init(
        integrityFindings: [IntegrityFinding] = [],
        aiDisclosurePresent: Bool = false,
        retailSample: RetailSampleSelection? = nil,
        artworkPixelSize: (width: Int, height: Int)? = nil,
        truncationEdgeLevels: [UUID: EdgeLevels] = [:],
        exportPreflight: ExportPreflightContext? = nil
    ) {
        self.integrityFindings = integrityFindings
        self.aiDisclosurePresent = aiDisclosurePresent
        self.retailSample = retailSample
        self.artworkPixelSize = artworkPixelSize
        self.truncationEdgeLevels = truncationEdgeLevels
        self.exportPreflight = exportPreflight
    }
}

/// Export-pipeline inputs for the four iPhone issue codes (§12.2, §13.2).
/// Populated by the storage and hydration preflight before validation runs; an
/// absent `ValidationContext.exportPreflight` leaves the preflight rules
/// unevaluated, so pure metadata/structure validation never touches I/O.
public struct ExportPreflightContext: Sendable, Equatable {
    /// Bytes of selected-take audio that live only in iCloud and must hydrate
    /// before export. `> 0` fires `assetRemoteOnlyForExport`.
    public var remoteHydrationBytes: Int64
    /// Chapters whose selected-take audio must hydrate (display only).
    public var remoteHydrationChapterCount: Int
    /// Bytes of export staging the working volume must be able to hold.
    public var storageRequiredBytes: Int64
    /// Bytes currently available on the working volume.
    public var storageAvailableBytes: Int64
    /// SHA-256 of selected takes whose assets are still `.localOnly` — never
    /// verified against iCloud, so never backed up (§6.1). Non-empty fires
    /// `backupNotVerified`.
    public var unverifiedSelectedTakeHashes: Set<String>

    public init(
        remoteHydrationBytes: Int64 = 0,
        remoteHydrationChapterCount: Int = 0,
        storageRequiredBytes: Int64 = 0,
        storageAvailableBytes: Int64 = 0,
        unverifiedSelectedTakeHashes: Set<String> = []
    ) {
        self.remoteHydrationBytes = remoteHydrationBytes
        self.remoteHydrationChapterCount = remoteHydrationChapterCount
        self.storageRequiredBytes = storageRequiredBytes
        self.storageAvailableBytes = storageAvailableBytes
        self.unverifiedSelectedTakeHashes = unverifiedSelectedTakeHashes
    }
}

/// The complete rule catalogue of §15.3, evaluated purely: project graph +
/// per-take metrics + destination profile + eligibility in, issues out. No I/O,
/// no file access, no clock.
public struct ValidationRuleEngine: Sendable {

    public init() {}

    /// Convenience entry point with an empty `ValidationContext`.
    public func evaluate(
        project: AudiobookProject,
        metrics: [UUID: AudioQualityMetrics],
        profile: DestinationProfile,
        eligibility: EligibilityProfile,
        assembly: AssemblySettings
    ) -> [ValidationIssue] {
        evaluate(project: project, metrics: metrics, profile: profile, eligibility: eligibility, assembly: assembly, context: ValidationContext())
    }

    public func evaluate(
        project: AudiobookProject,
        metrics: [UUID: AudioQualityMetrics],
        profile: DestinationProfile,
        eligibility: EligibilityProfile,
        assembly: AssemblySettings,
        context: ValidationContext
    ) -> [ValidationIssue] {
        var engine = Evaluator(
            project: project,
            metrics: metrics,
            profile: profile,
            eligibility: eligibility,
            assembly: assembly,
            context: context
        )
        return engine.run()
    }
}

/// Private stateful driver. Struct-scoped so the many rules share one issue
/// list and precomputed aggregates without threading parameters everywhere.
private struct Evaluator {
    let project: AudiobookProject
    let metrics: [UUID: AudioQualityMetrics]
    let profile: DestinationProfile
    let eligibility: EligibilityProfile
    let assembly: AssemblySettings
    let context: ValidationContext
    var issues: [ValidationIssue] = []
    /// Ids already emitted. A set, not a scan of `issues`: the engine evaluates
    /// thousands of paragraphs and a linear membership check per issue makes the
    /// whole run quadratic (`PerformanceBudgetTests`).
    var emittedIssueIDs: Set<UUID> = []

    private var isLibrivox: Bool { profile.id == .librivox }
    private var isArchive: Bool { profile.id == .internetArchive }
    private var isRetail: Bool { profile.id == .acx || profile.id == .appleBooksAggregator }
    private var isPersonal: Bool { profile.id == .personalMaster }

    private var analyzerVersion: Int { AudioMetricsCalculator.analyzerVersion }

    /// Document-ordered `(paragraph, selectedTake)` pairs.
    private var orderedTakes: [(paragraph: Paragraph, take: Take)] {
        project.allParagraphs.compactMap { p in
            guard let sid = p.selectedTakeID, let take = p.takes.first(where: { $0.id == sid }) else { return nil }
            return (p, take)
        }
    }

    mutating func run() -> [ValidationIssue] {
        evaluateMetadata()
        evaluateOriginAndEligibility()
        evaluateIntegrity()
        evaluateStructure()
        evaluateScripts()
        evaluateRetail()
        evaluateChapterDurations()
        evaluateAudio()
        evaluateLoudness()
        evaluateRouteReadiness()
        evaluatePreflight()
        return issues
    }

    // MARK: - Group 1 — Metadata and rights

    private mutating func evaluateMetadata() {
        let m = project.metadata

        if m.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.missingTitle, String(localized: "Missing title", bundle: .module), String(localized: "The book has no title.", bundle: .module))
        }
        if m.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.missingAuthor, String(localized: "Missing author", bundle: .module), String(localized: "The book has no author.", bundle: .module))
        }
        if m.narrator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.missingNarrator, String(localized: "Missing narrator", bundle: .module), String(localized: "The book has no narrator.", bundle: .module))
        }
        if m.language.isEmpty || !isValidBCP47(m.language) {
            add(.missingLanguage, String(localized: "Missing or invalid language", bundle: .module), String(localized: "\"\(m.language)\" is not a valid BCP-47 language tag.", bundle: .module), measured: nil, expected: String(localized: "BCP-47, e.g. en-US", bundle: .module))
        }
        if m.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.missingDescription, String(localized: "Missing description", bundle: .module), String(localized: "A description is required for this destination.", bundle: .module))
        }

        let rights = project.rights
        if rights.sourceURL == nil {
            add(.missingSourceURL, String(localized: "Missing source URL", bundle: .module), String(localized: "The authorized source edition URL is required.", bundle: .module))
        }
        // `.missingRightsBasis` never fires: `RightsBasis` is non-optional and
        // always populated by the wizard. `personalUseOnly` for a public
        // destination is the real hazard, handled below.
        if rights.basis == .personalUseOnly {
            add(.personalRightsForPublicTarget, String(localized: "Personal-use rights", bundle: .module), String(localized: "Personal use only is not valid for a public destination.", bundle: .module))
        }
        if !rights.isAttested {
            add(.unattestedRights, String(localized: "Rights not attested", bundle: .module), String(localized: "The rights attestation has not been confirmed.", bundle: .module))
        }

        if m.coverRef == nil {
            add(.missingCoverArt, String(localized: "Missing cover art", bundle: .module), String(localized: "This destination requires cover art.", bundle: .module))
        }
        if let size = context.artworkPixelSize {
            let minPx: Int
            switch profile.artwork {
            case .none: minPx = 0
            case .optionalSquare(let px), .requiredSquare(let px, _, _): minPx = px
            }
            let shortest = min(size.width, size.height)
            if minPx > 0, shortest < minPx {
                add(.artworkTooSmall, String(localized: "Cover art too small", bundle: .module), String(localized: "Cover is \(size.width)×\(size.height); this destination needs at least \(minPx) px on the short side.", bundle: .module), measured: Double(shortest), expected: "≥ \(minPx) px")
            }
            if minPx > 0 {
                let ratio = Double(size.width) / Double(max(1, size.height))
                if ratio < 0.99 || ratio > 1.01 {
                    add(.artworkNotSquare, String(localized: "Cover art not square", bundle: .module), String(localized: "Cover aspect ratio is \(String(format: "%.2f", ratio)); this destination requires 1:1.", bundle: .module), measured: ratio, expected: "1.0 ± 0.01")
                }
            }
        }

        if m.copyrightYear == nil {
            add(.missingCopyrightYear, String(localized: "Missing copyright year", bundle: .module), String(localized: "The copyright year is required for this destination.", bundle: .module))
        }
        if m.publisher == nil || m.publisher?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            add(.missingPublisher, String(localized: "Missing publisher", bundle: .module), String(localized: "A publisher is expected for this destination.", bundle: .module))
        }

        if m.archiveIdentifier == nil || m.archiveIdentifier?.isEmpty == true {
            add(.missingArchiveIdentifier, String(localized: "Missing archive identifier", bundle: .module), String(localized: "An Internet Archive identifier is required.", bundle: .module))
        } else if let id = m.archiveIdentifier, !IdentifierSuggester().isValid(id) {
            add(.invalidArchiveIdentifier, String(localized: "Invalid archive identifier", bundle: .module), String(localized: "\"\(id)\" is not a valid archive.org identifier.", bundle: .module))
        }
    }

    // MARK: - Group 2 — Narration origin and eligibility

    private mutating func evaluateOriginAndEligibility() {
        if isLibrivox && !eligibility.librivoxEligible {
            add(.aiOriginInLibriVoxProject, String(localized: "AI audio in LibriVox project", bundle: .module), LegalStrings.librivoxHumanOnly)
        }

        for (paragraph, take) in orderedTakes where take.origin.storageKind == "unknownImport" {
            add(.unknownOriginTakeSelected, String(localized: "Unknown-origin take selected", bundle: .module), String(localized: "Paragraph \(paragraph.ordinal) has a selected take with an undeclared origin.", bundle: .module), paragraphID: paragraph.id, takeID: take.id)
        }

        if eligibility.narrationOrigin == .containsImportedAI, !context.aiDisclosurePresent {
            add(.undisclosedAINarration, String(localized: "AI narration not disclosed", bundle: .module), String(localized: "This project contains AI-origin narration; the disclosure line must appear in the delivered manifest and metadata.", bundle: .module))
        }
    }

    // MARK: - Group 3 — Completeness and structure (integrity-derived)

    private mutating func evaluateIntegrity() {
        for finding in context.integrityFindings {
            switch finding.code {
            case .duplicateChapterOrdinal, .duplicateParagraphOrdinal:
                add(.duplicateOrdinal, String(localized: "Duplicate ordinal", bundle: .module), finding.message, chapterID: finding.chapterID, paragraphID: finding.paragraphID)
            case .missingChapterOrdinal, .missingParagraphOrdinal:
                add(.missingOrdinal, String(localized: "Missing ordinal", bundle: .module), finding.message, chapterID: finding.chapterID, paragraphID: finding.paragraphID)
            case .takeAssetMissing:
                add(.assetMissing, String(localized: "Missing audio asset", bundle: .module), finding.message, chapterID: finding.chapterID, paragraphID: finding.paragraphID)
            case .takeAssetHashMismatch:
                add(.assetHashMismatch, String(localized: "Audio asset hash mismatch", bundle: .module), finding.message, chapterID: finding.chapterID, paragraphID: finding.paragraphID)
            default:
                break
            }
        }
    }

    // MARK: - Group 3 — Completeness and structure

    private mutating func evaluateStructure() {
        var unapproved = 0

        for chapter in project.chapters {
            if chapter.paragraphs.isEmpty {
                add(.emptyChapter, String(localized: "Empty chapter", bundle: .module), String(localized: "Chapter \(chapter.title) has no paragraphs.", bundle: .module), chapterID: chapter.id)
                continue
            }

            for paragraph in chapter.paragraphs {
                let isRecordedTarget = paragraph.role == .body || paragraph.role == .chapterHeading

                if isRecordedTarget && paragraph.selectedTakeID == nil {
                    add(.missingAcceptedTake, String(localized: "Missing accepted take", bundle: .module), String(localized: "Paragraph \(paragraph.ordinal) of \(chapter.title) has no selected audio.", bundle: .module), chapterID: chapter.id, paragraphID: paragraph.id, fix: .recordParagraph(paragraph.id))
                }

                if paragraph.reviewState == .needsPickup {
                    add(.unresolvedNeedsPickup, String(localized: "Unresolved needs pickup", bundle: .module), String(localized: "Paragraph \(paragraph.ordinal) of \(chapter.title) must be re-recorded.", bundle: .module), chapterID: chapter.id, paragraphID: paragraph.id, fix: .clearPickup(paragraph.id))
                }

                if paragraph.selectedTakeID != nil && paragraph.reviewState != .approved {
                    unapproved += 1
                }

                if let takeID = paragraph.selectedTakeID,
                   let take = paragraph.takes.first(where: { $0.id == takeID }),
                   paragraph.textHash != take.textHashAtRecording {
                    if paragraph.reviewState == .needsPickup {
                        add(.textChangedAfterRecording, String(localized: "Text changed after recording", bundle: .module), String(localized: "Paragraph \(paragraph.ordinal) of \(chapter.title) was recorded against older text and must be re-recorded.", bundle: .module), chapterID: chapter.id, paragraphID: paragraph.id, takeID: take.id, fix: .recordParagraph(paragraph.id))
                    } else {
                        add(.textChangedCosmetically, String(localized: "Text changed", bundle: .module), String(localized: "Paragraph \(paragraph.ordinal) of \(chapter.title) changed after it was recorded.", bundle: .module), chapterID: chapter.id, paragraphID: paragraph.id, takeID: take.id, fix: .recordParagraph(paragraph.id))
                    }
                }
            }
        }

        if unapproved > 0 {
            add(.unapprovedParagraphs, String(localized: "Unapproved paragraphs", bundle: .module), String(localized: "\(unapproved) recorded paragraphs are not yet approved.", bundle: .module))
        }
    }

    // MARK: - Scripted disclaimers and credits (§10.5)

    private mutating func evaluateScripts() {
        if isLibrivox {
            let plan = LibriVoxScriptGenerator().plan(for: project)
            let scriptChapters = project.chapters.filter { $0.role == .body || $0.role == .frontMatter || $0.role == .backMatter }
            for chapter in scriptChapters {
                let intro = chapter.paragraphs.first { $0.role == .libriVoxIntro }
                let outro = chapter.paragraphs.last { $0.role == .libriVoxOutro }

                for (kind, paragraph) in [(ParagraphRole.libriVoxIntro, intro), (.libriVoxOutro, outro)] {
                    // Name the part everywhere: the intro and the outro used to
                    // emit the same title and the same message, which read as
                    // one duplicated error (field report 2026-08-19, item 5).
                    let isIntro = kind == .libriVoxIntro
                    if let paragraph {
                        if paragraph.selectedTakeID == nil {
                            add(.unrecordedDisclaimer,
                                isIntro ? String(localized: "Unrecorded intro", bundle: .module) : String(localized: "Unrecorded outro", bundle: .module),
                                isIntro
                                    ? String(localized: "The LibriVox intro for \(chapter.title) has no recording.", bundle: .module)
                                    : String(localized: "The LibriVox outro for \(chapter.title) has no recording.", bundle: .module), chapterID: chapter.id, paragraphID: paragraph.id, fix: .recordParagraph(paragraph.id), variant: kind.rawValue)
                        }
                        let expected = kind == .libriVoxIntro ? plan.chapterIntros[chapter.id] : plan.chapterOutros[chapter.id]
                        if let expected, paragraph.text != expected {
                            add(.staleDisclaimerText,
                                isIntro ? String(localized: "Stale intro disclaimer", bundle: .module) : String(localized: "Stale outro disclaimer", bundle: .module),
                                isIntro
                                    ? String(localized: "The LibriVox intro for \(chapter.title) no longer matches the current metadata.", bundle: .module)
                                    : String(localized: "The LibriVox outro for \(chapter.title) no longer matches the current metadata.", bundle: .module), chapterID: chapter.id, paragraphID: paragraph.id, fix: .regenerateDisclaimers, variant: kind.rawValue)
                        }
                    } else {
                        add(.missingDisclaimerParagraph,
                            isIntro ? String(localized: "Missing intro disclaimer", bundle: .module) : String(localized: "Missing outro disclaimer", bundle: .module),
                            isIntro
                                ? String(localized: "\(chapter.title) has no LibriVox intro paragraph.", bundle: .module)
                                : String(localized: "\(chapter.title) has no LibriVox outro paragraph.", bundle: .module), chapterID: chapter.id, fix: .regenerateDisclaimers, variant: kind.rawValue)
                    }
                }
            }
        }
    }

    private mutating func evaluateRetail() {
        guard isRetail else { return }

        for role in [ChapterRole.openingCredits, .closingCredits] {
            let chapter = project.chapters.first { $0.role == role }
            let recorded = chapter?.paragraphs.contains { $0.selectedTakeID != nil } ?? false
            let code: IssueCode = role == .openingCredits ? .missingOpeningCredits : .missingClosingCredits
            if !recorded {
                let isOpening = role == .openingCredits
                add(code,
                    isOpening ? String(localized: "Missing opening credits", bundle: .module) : String(localized: "Missing closing credits", bundle: .module),
                    isOpening
                        ? String(localized: "The opening credits paragraph must be recorded for a retail deliverable.", bundle: .module)
                        : String(localized: "The closing credits paragraph must be recorded for a retail deliverable.", bundle: .module), chapterID: chapter?.id, fix: .regenerateCredits)
            }
        }

        guard let sampleRule = profile.retailSample else { return }
        guard let selection = context.retailSample else {
            add(.missingRetailSample, String(localized: "Missing retail sample", bundle: .module), String(localized: "A \(Int(sampleRule.minDuration))–\(Int(sampleRule.maxDuration)) second retail sample is required.", bundle: .module))
            return
        }

        if selection.duration < sampleRule.minDuration {
            add(.retailSampleTooShort, String(localized: "Retail sample too short", bundle: .module), String(localized: "The retail sample is \(Int(selection.duration)) s; the minimum is \(Int(sampleRule.minDuration)) s.", bundle: .module), measured: selection.duration, expected: "≥ \(Int(sampleRule.minDuration)) s", fix: .setRetailSample)
        }
        if selection.duration > sampleRule.maxDuration {
            add(.retailSampleTooLong, String(localized: "Retail sample too long", bundle: .module), String(localized: "The retail sample is \(Int(selection.duration)) s; the maximum is \(Int(sampleRule.maxDuration)) s.", bundle: .module), measured: selection.duration, expected: "≤ \(Int(sampleRule.maxDuration)) s", fix: .setRetailSample)
        }
        if let start = project.allParagraphs.first(where: { $0.id == selection.startParagraphID }),
           start.role == .retailOpeningCredits || start.role == .retailClosingCredits {
            add(.retailSampleStartsInCredits, String(localized: "Retail sample starts in credits", bundle: .module), String(localized: "The retail sample must begin with narration, not credits.", bundle: .module), paragraphID: start.id, fix: .setRetailSample)
        }
    }

    // MARK: - Assembly-derived rules (§15.4): chapter duration and room tone

    private mutating func evaluateChapterDurations() {
        let builder = SegmentQueueBuilder()

        for chapter in project.chapters {
            let segments = builder.build(.chapter(chapter.id), from: project, settings: assembly)
            let duration = AssemblyDuration.duration(of: segments)

            if let max = profile.maxFileDuration, duration > max {
                add(.chapterTooLong, String(localized: "Chapter too long", bundle: .module), String(localized: "\(chapter.title) is \(Int(duration)) s; this destination caps files at \(Int(max)) s.", bundle: .module), chapterID: chapter.id, measured: duration, expected: "≤ \(Int(max)) s", fix: .splitChapter(chapter.id, atParagraph: chapter.paragraphs.first?.id ?? chapter.id))
            }
            if duration > ValidationThresholds.veryLongChapterSeconds {
                add(.chapterVeryLong, String(localized: "Chapter very long", bundle: .module), String(localized: "\(chapter.title) exceeds \(Int(ValidationThresholds.veryLongChapterSeconds / 60)) minutes; consider splitting it.", bundle: .module), chapterID: chapter.id, measured: duration)
            }

            if isRetail, let rule = profile.headroomSilence, !segments.isEmpty {
                let head = segments.first!.leadingSilence
                if head < rule.headMin || head > rule.headMax {
                    add(.headRoomToneOutOfRange, String(localized: "Head room tone out of range", bundle: .module), String(localized: "\(chapter.title) has \(String(format: "%.2f", head)) s of head silence; expected \(String(format: "%.2f", rule.headMin))–\(String(format: "%.2f", rule.headMax)) s.", bundle: .module), chapterID: chapter.id, measured: head)
                }
                let tail = segments.last!.trailingSilence
                if tail < rule.tailMin || tail > rule.tailMax {
                    add(.tailRoomToneOutOfRange, String(localized: "Tail room tone out of range", bundle: .module), String(localized: "\(chapter.title) has \(String(format: "%.2f", tail)) s of tail silence; expected \(String(format: "%.2f", rule.tailMin))–\(String(format: "%.2f", rule.tailMax)) s.", bundle: .module), chapterID: chapter.id, measured: tail)
                }
            }
        }
    }

    // MARK: - Group 4 — Audio quality

    private mutating func evaluateAudio() {
        let takes = orderedTakes
        let majorityRate = mostCommon(takes.map { $0.take.format.sampleRate })
        let majorityChannels = mostCommon(takes.map { $0.take.format.channels })

        let rmsSequence = takes.compactMap { (p, take) -> (paragraphID: UUID, rmsDBFS: Double)? in
            guard let m = metrics[take.id], m.analyzerVersion == analyzerVersion else { return nil }
            return (p.id, m.rmsDBFS)
        }

        let window = ValidationThresholds.discontinuityNeighborWindow
        for index in rmsSequence.indices {
            // Direct index arithmetic — a sliding window is O(1) per paragraph;
            // scanning the whole array per paragraph would be O(n²) and blow the
            // §15.4 validation budget on large projects.
            var neighbors: [Double] = []
            let low = max(0, index - window)
            let high = min(rmsSequence.count - 1, index + window)
            if low <= high {
                for j in low...high where j != index {
                    neighbors.append(rmsSequence[j].rmsDBFS)
                }
            }
            let entry = rmsSequence[index]
            if let median = median(neighbors), abs(entry.rmsDBFS - median) > ValidationThresholds.loudnessDiscontinuityDB {
                add(.loudnessDiscontinuity, String(localized: "Loudness discontinuity", bundle: .module), String(localized: "Paragraph is approximately \(String(format: "%.1f", abs(entry.rmsDBFS - median))) dB louder or quieter than adjacent paragraphs.", bundle: .module), paragraphID: entry.paragraphID, measured: abs(entry.rmsDBFS - median), expected: "≤ \(ValidationThresholds.loudnessDiscontinuityDB) dB")
            }
        }

        for (paragraph, take) in takes {
            guard let m = metrics[take.id] else {
                add(.missingMetrics, String(localized: "Missing quality metrics", bundle: .module), String(localized: "Paragraph \(paragraph.ordinal) has no audio-quality metrics.", bundle: .module), paragraphID: paragraph.id, takeID: take.id, fix: .reanalyzeTake(take.id))
                continue
            }
            guard m.analyzerVersion == analyzerVersion else {
                add(.missingMetrics, String(localized: "Stale quality metrics", bundle: .module), String(localized: "Paragraph \(paragraph.ordinal) has metrics from an older analyzer.", bundle: .module), paragraphID: paragraph.id, takeID: take.id, fix: .reanalyzeTake(take.id))
                continue
            }

            if m.clipCount > 0 {
                add(.clipping, String(localized: "Clipping detected", bundle: .module), String(localized: "Paragraph \(paragraph.ordinal) contains \(m.clipCount) clipped runs.", bundle: .module), paragraphID: paragraph.id, takeID: take.id, measured: Double(m.clipCount), expected: "0", fix: .recordParagraph(paragraph.id))
            }
            if let ceiling = profile.peakCeilingDBFS, m.truePeakDBFS > ceiling {
                add(.peakTooHot, String(localized: "Peak too hot", bundle: .module), String(localized: "Paragraph \(paragraph.ordinal) peaks at \(String(format: "%.1f", m.truePeakDBFS)) dBFS; the ceiling is \(String(format: "%.1f", ceiling)) dBFS.", bundle: .module), paragraphID: paragraph.id, takeID: take.id, measured: m.truePeakDBFS, expected: "≤ \(String(format: "%.1f", ceiling)) dBFS")
            }
            if m.peakDBFS < ValidationThresholds.peakTooLowDBFS {
                add(.peakTooLow, String(localized: "Suspiciously quiet capture", bundle: .module), String(localized: "Paragraph \(paragraph.ordinal) peaks at \(String(format: "%.1f", m.peakDBFS)) dBFS.", bundle: .module), paragraphID: paragraph.id, takeID: take.id, measured: m.peakDBFS)
            }
            if let ceiling = profile.noiseFloorCeilingDBFS, m.noiseFloorDBFS > ceiling {
                add(.noiseFloorTooHigh, String(localized: "Noise floor too high", bundle: .module), String(localized: "Paragraph \(paragraph.ordinal) has a \(String(format: "%.1f", m.noiseFloorDBFS)) dBFS noise floor; the ceiling is \(String(format: "%.1f", ceiling)) dBFS.", bundle: .module), paragraphID: paragraph.id, takeID: take.id, measured: m.noiseFloorDBFS, expected: "≤ \(String(format: "%.1f", ceiling)) dBFS")
            }
            if !m.noiseFloorReliable {
                add(.noiseFloorUnreliable, String(localized: "Noise floor unreliable", bundle: .module), String(localized: "Paragraph \(paragraph.ordinal) has too little silence to measure a reliable noise floor.", bundle: .module), paragraphID: paragraph.id, takeID: take.id)
            }
            if abs(m.dcOffset) > ValidationThresholds.dcOffsetWarnThreshold {
                add(.dcOffset, String(localized: "DC offset", bundle: .module), String(localized: "Paragraph \(paragraph.ordinal) has a DC offset of \(String(format: "%.4f", m.dcOffset)).", bundle: .module), paragraphID: paragraph.id, takeID: take.id, measured: m.dcOffset)
            }

            if let majority = majorityRate, take.format.sampleRate != majority {
                add(.sampleRateMismatch, String(localized: "Sample rate mismatch", bundle: .module), String(localized: "Paragraph \(paragraph.ordinal) is \(Int(take.format.sampleRate)) Hz while the rest of the project is \(Int(majority)) Hz.", bundle: .module), paragraphID: paragraph.id, takeID: take.id, measured: take.format.sampleRate, expected: String(localized: "\(Int(majority)) Hz", bundle: .module))
            }
            if let majority = majorityChannels, take.format.channels != majority {
                add(.channelInconsistency, String(localized: "Channel inconsistency", bundle: .module), String(localized: "Paragraph \(paragraph.ordinal) has \(take.format.channels) channels while the rest of the project has \(majority).", bundle: .module), paragraphID: paragraph.id, takeID: take.id, measured: Double(take.format.channels), expected: String(localized: "\(majority)", bundle: .module))
            }
            if m.channels == 2, let expected = profile.audio.channels, expected == 1 {
                add(.stereoWhereMonoExpected, String(localized: "Stereo where mono expected", bundle: .module), String(localized: "Paragraph \(paragraph.ordinal) is stereo; this destination expects mono.", bundle: .module), paragraphID: paragraph.id, takeID: take.id, measured: 2, expected: "1")
            }

            if let edge = context.truncationEdgeLevels[take.id],
               edge.leadingDBFS > ValidationThresholds.truncationEdgeDBFS || edge.trailingDBFS > ValidationThresholds.truncationEdgeDBFS {
                add(.suspectedTruncation, String(localized: "Suspected truncated take", bundle: .module), String(localized: "Paragraph \(paragraph.ordinal) starts or ends abruptly at the file edge.", bundle: .module), paragraphID: paragraph.id, takeID: take.id, measured: max(edge.leadingDBFS, edge.trailingDBFS), expected: "≤ \(ValidationThresholds.truncationEdgeDBFS) dBFS")
            }
            if m.leadingSilence > ValidationThresholds.excessiveLeadingSilenceSeconds {
                add(.excessiveLeadingSilence, String(localized: "Excessive leading silence", bundle: .module), String(localized: "Paragraph \(paragraph.ordinal) has \(String(format: "%.1f", m.leadingSilence)) s of leading silence.", bundle: .module), paragraphID: paragraph.id, takeID: take.id, measured: m.leadingSilence, expected: "≤ \(ValidationThresholds.excessiveLeadingSilenceSeconds) s")
            }

            let estimate = Double(paragraph.text.count) / ValidationThresholds.estimatedCharsPerSecond
            let deviation = estimate == 0 ? 0 : abs(take.duration - estimate) / estimate
            if deviation > ValidationThresholds.durationOutlierFraction {
                add(.durationOutlier, String(localized: "Duration outlier", bundle: .module), String(localized: "Paragraph \(paragraph.ordinal) is \(String(format: "%.0f", take.duration)) s against an estimated \(Int(estimate)) s of text.", bundle: .module), paragraphID: paragraph.id, takeID: take.id, measured: take.duration, expected: "≈ \(Int(estimate)) s")
            }
        }

        // Chapter-level file rules (retail RMS per delivered file, §15.6).
        if isRetail, case .rmsWindow(let minDB, let maxDB, _) = profile.loudness {
            for chapter in project.chapters {
                let chapterTakes = chapter.paragraphs.compactMap { p -> (Paragraph, Take)? in
                    guard let sid = p.selectedTakeID, let take = p.takes.first(where: { $0.id == sid }) else { return nil }
                    return (p, take)
                }
                var weightedSum = 0.0
                var durationSum = 0.0
                for (_, take) in chapterTakes {
                    guard let m = metrics[take.id], m.analyzerVersion == analyzerVersion else { continue }
                    let linear = pow(10, m.rmsDBFS / 20)
                    weightedSum += linear * linear * m.duration
                    durationSum += m.duration
                }
                guard durationSum > 0 else { continue }
                let chapterRMS = 20 * log10(sqrt(weightedSum / durationSum))
                if chapterRMS < minDB || chapterRMS > maxDB {
                    add(.rmsOutOfRange, String(localized: "Chapter RMS out of range", bundle: .module), String(localized: "\(chapter.title) measures \(String(format: "%.1f", chapterRMS)) dBFS RMS; expected \(Int(minDB)) to \(Int(maxDB)) dBFS.", bundle: .module), chapterID: chapter.id, measured: chapterRMS, expected: String(localized: "\(Int(minDB)) to \(Int(maxDB)) dBFS", bundle: .module))
                }
            }
        }

        // Mixed bit depth across the project's originals.
        let bitDepths = Set(takes.compactMap { $0.take.format.bitDepth })
        if bitDepths.count > 1 {
            add(.bitDepthMismatch, String(localized: "Mixed bit depths", bundle: .module), String(localized: "The project mixes bit depths: \(bitDepths.sorted().map(String.init).joined(separator: ", ")).", bundle: .module))
        }
    }

    // MARK: - Group 5 — LibriVox perceived loudness

    private mutating func evaluateLoudness() {
        guard isLibrivox, case .replayGainBand(let low, let high, let target) = profile.loudness else { return }
        let isNormalizing = assembly.isNormalizingLoudness
        for (paragraph, take) in orderedTakes {
            guard let m = metrics[take.id], m.analyzerVersion == analyzerVersion else { continue }
            // Judge the audio the narrator will actually export: with
            // normalization on, the render applies a gain, so a take that is
            // quiet on disk can still land inside the band.
            let perceived = AssemblyLoudness.perceivedVolumeDB(for: m, target: target, isNormalizing: isNormalizing)
            guard perceived < low || perceived > high else { continue }
            let remedy = isNormalizing
                ? String(localized: "Normalization is already on and cannot reach the band — re-record this paragraph closer to the others.", bundle: .module)
                : String(localized: "Turn on take-to-take normalization to bring it into the band without re-recording.", bundle: .module)
            add(
                .perceivedVolumeOutOfBand,
                String(localized: "Estimated perceived volume out of band", bundle: .module),
                String(localized: "Estimated perceived volume is \(Int(perceived.rounded())) dB (LibriVox prefers \(Int(low))–\(Int(high)) dB). \(remedy) This is an estimate; the LibriVox checker is authoritative.", bundle: .module),
                paragraphID: paragraph.id,
                takeID: take.id,
                measured: perceived,
                expected: "\(Int(low))–\(Int(high)) dB",
                fix: isNormalizing ? .recordParagraph(paragraph.id) : .normalizeLoudness
            )
        }
    }

    // MARK: - Group 6 — iPhone preflight (§12.2)

    /// `routeNotRetailReady`: computed from the *recorded* route history, not
    /// the route at export time (§7.1). Draft-only routes are never blocked —
    /// the honest warning appears only on a retail destination, where it would
    /// actually fail submission. LibriVox / Internet Archive are unaffected.
    private mutating func evaluateRouteReadiness() {
        guard isRetail else { return }
        let draftTakes = orderedTakes.filter { $0.take.routeClass == .draftOnly }
        if !draftTakes.isEmpty {
            let first = draftTakes[0]
            add(
                .routeNotRetailReady,
                String(localized: "Recorded on a draft-quality input", bundle: .module),
                String(localized: "\(draftTakes.count) takes were recorded on a Bluetooth or built-in input; this deliverable may not pass retail review.", bundle: .module),
                paragraphID: first.paragraph.id,
                takeID: first.take.id,
                fix: .openAudioSetup
            )
        }
    }

    /// The hydration, storage, and backup preflight codes. These are
    /// operational — they gate *starting* an export — not quality findings.
    private mutating func evaluatePreflight() {
        guard let preflight = context.exportPreflight else { return }

        if preflight.remoteHydrationBytes > 0 {
            let chapterCount = preflight.remoteHydrationChapterCount
            add(
                .assetRemoteOnlyForExport,
                String(localized: "\(chapterCount) chapters are in iCloud", bundle: .module),
                String(localized: "\(PackagingSupport.formattedBytes(preflight.remoteHydrationBytes)) must download before export can start.", bundle: .module),
                measured: Double(preflight.remoteHydrationBytes),
                expected: "all selected-take audio local",
                fix: .hydrateAssets
            )
        }

        if preflight.storageRequiredBytes > preflight.storageAvailableBytes {
            add(
                .localStorageInsufficient,
                String(localized: "Not enough free space", bundle: .module),
                String(localized: "Export needs \(PackagingSupport.formattedBytes(preflight.storageRequiredBytes)) but only \(PackagingSupport.formattedBytes(preflight.storageAvailableBytes)) is free.", bundle: .module),
                measured: Double(preflight.storageRequiredBytes),
                expected: "≤ \(PackagingSupport.formattedBytes(preflight.storageAvailableBytes)) available",
                fix: .manageStorage
            )
        }

        if !preflight.unverifiedSelectedTakeHashes.isEmpty {
            let count = preflight.unverifiedSelectedTakeHashes.count
            add(
                .backupNotVerified,
                String(localized: "Not backed up yet", bundle: .module),
                String(localized: "\(count) takes exist only on this iPhone; iCloud backup has not verified.", bundle: .module),
                fix: .backupNow
            )
        }
    }

    // MARK: - Plumbing

    /// Append an issue iff this destination evaluates the code at all.
    private mutating func add(
        _ code: IssueCode,
        _ title: String,
        _ message: String,
        chapterID: UUID? = nil,
        paragraphID: UUID? = nil,
        takeID: UUID? = nil,
        measured: Double? = nil,
        expected: String? = nil,
        fix: FixAction? = nil,
        variant: String = ""
    ) {
        guard let severity = Self.severity(for: profile.id, code: code) else { return }
        let id = ValidationIssue.deterministicID(code: code, chapterID: chapterID, paragraphID: paragraphID, variant: variant)
        // One issue per instance. `ValidationIssue` is `Identifiable`, and two
        // rows sharing an id inside a `ForEach` render as an undefined
        // duplicate (field report 2026-08-19, item 5).
        guard emittedIssueIDs.insert(id).inserted else { return }
        issues.append(ValidationIssue(
            id: id,
            severity: severity,
            code: code,
            title: title,
            message: message,
            chapterID: chapterID,
            paragraphID: paragraphID,
            takeID: takeID,
            measured: measured,
            expected: expected,
            fix: fix
        ))
    }

    /// Severity per (destination, code). `nil` means the rule is not evaluated
    /// for that destination (the `–` cells of §15.3's tables).
    static func severity(for destination: DestinationID, code: IssueCode) -> Severity? {
        switch (destination, code) {
        // Group 1 — metadata & rights
        case (.librivox, .missingTitle), (.internetArchive, .missingTitle),
             (.acx, .missingTitle), (.appleBooksAggregator, .missingTitle): return .blocking
        case (.personalMaster, .missingTitle): return .warning
        case (.librivox, .missingAuthor), (.internetArchive, .missingAuthor),
             (.acx, .missingAuthor), (.appleBooksAggregator, .missingAuthor),
             (.librivox, .missingNarrator), (.internetArchive, .missingNarrator),
             (.acx, .missingNarrator), (.appleBooksAggregator, .missingNarrator),
             (.librivox, .missingLanguage), (.internetArchive, .missingLanguage),
             (.acx, .missingLanguage), (.appleBooksAggregator, .missingLanguage): return .blocking
        case (.librivox, .missingDescription), (.internetArchive, .missingDescription): return .warning
        case (.acx, .missingDescription), (.appleBooksAggregator, .missingDescription): return .blocking
        case (.librivox, .missingSourceURL): return .blocking
        case (.internetArchive, .missingSourceURL): return .warning
        case (.librivox, .personalRightsForPublicTarget), (.internetArchive, .personalRightsForPublicTarget),
             (.acx, .personalRightsForPublicTarget), (.appleBooksAggregator, .personalRightsForPublicTarget),
             (.librivox, .unattestedRights), (.internetArchive, .unattestedRights),
             (.acx, .unattestedRights), (.appleBooksAggregator, .unattestedRights): return .blocking
        case (.librivox, .missingCoverArt), (.internetArchive, .missingCoverArt): return .warning
        case (.acx, .missingCoverArt), (.appleBooksAggregator, .missingCoverArt): return .blocking
        case (.internetArchive, .artworkTooSmall), (.internetArchive, .artworkNotSquare): return .warning
        case (.acx, .artworkTooSmall), (.appleBooksAggregator, .artworkTooSmall),
             (.acx, .artworkNotSquare), (.appleBooksAggregator, .artworkNotSquare): return .blocking
        case (.internetArchive, .missingCopyrightYear): return .warning
        case (.acx, .missingCopyrightYear), (.appleBooksAggregator, .missingCopyrightYear): return .blocking
        case (.acx, .missingPublisher), (.appleBooksAggregator, .missingPublisher): return .warning
        case (.internetArchive, .missingArchiveIdentifier), (.internetArchive, .invalidArchiveIdentifier): return .blocking

        // Group 2 — origin & eligibility
        case (.librivox, .aiOriginInLibriVoxProject): return .blocking
        case (.librivox, .unknownOriginTakeSelected): return .blocking
        case (.internetArchive, .unknownOriginTakeSelected), (.acx, .unknownOriginTakeSelected),
             (.appleBooksAggregator, .unknownOriginTakeSelected): return .warning
        case (.internetArchive, .undisclosedAINarration), (.acx, .undisclosedAINarration),
             (.appleBooksAggregator, .undisclosedAINarration): return .blocking

        // Group 3 — completeness & structure
        case (.librivox, .missingAcceptedTake), (.internetArchive, .missingAcceptedTake),
             (.acx, .missingAcceptedTake), (.appleBooksAggregator, .missingAcceptedTake): return .blocking
        case (.personalMaster, .missingAcceptedTake): return .warning
        case (.librivox, .unresolvedNeedsPickup), (.internetArchive, .unresolvedNeedsPickup),
             (.acx, .unresolvedNeedsPickup), (.appleBooksAggregator, .unresolvedNeedsPickup): return .blocking
        case (.personalMaster, .unresolvedNeedsPickup): return .warning
        case (.librivox, .unapprovedParagraphs), (.internetArchive, .unapprovedParagraphs),
             (.acx, .unapprovedParagraphs), (.appleBooksAggregator, .unapprovedParagraphs): return .warning
        case (.librivox, .textChangedAfterRecording), (.acx, .textChangedAfterRecording),
             (.appleBooksAggregator, .textChangedAfterRecording): return .blocking
        case (.internetArchive, .textChangedAfterRecording), (.personalMaster, .textChangedAfterRecording): return .warning
        case (.librivox, .textChangedCosmetically), (.acx, .textChangedCosmetically),
             (.appleBooksAggregator, .textChangedCosmetically), (.personalMaster, .textChangedCosmetically): return .warning
        case (.librivox, .emptyChapter), (.internetArchive, .emptyChapter),
             (.acx, .emptyChapter), (.appleBooksAggregator, .emptyChapter): return .blocking
        case (.personalMaster, .emptyChapter): return .warning
        case (.librivox, .duplicateOrdinal), (.internetArchive, .duplicateOrdinal),
             (.acx, .duplicateOrdinal), (.appleBooksAggregator, .duplicateOrdinal),
             (.personalMaster, .duplicateOrdinal), (.librivox, .missingOrdinal),
             (.internetArchive, .missingOrdinal), (.acx, .missingOrdinal),
             (.appleBooksAggregator, .missingOrdinal), (.personalMaster, .missingOrdinal),
             (.librivox, .assetMissing), (.internetArchive, .assetMissing),
             (.acx, .assetMissing), (.appleBooksAggregator, .assetMissing),
             (.personalMaster, .assetMissing), (.librivox, .assetHashMismatch),
             (.internetArchive, .assetHashMismatch), (.acx, .assetHashMismatch),
             (.appleBooksAggregator, .assetHashMismatch), (.personalMaster, .assetHashMismatch): return .blocking
        case (.librivox, .missingDisclaimerParagraph), (.librivox, .unrecordedDisclaimer),
             (.librivox, .staleDisclaimerText): return .blocking
        case (.acx, .missingOpeningCredits), (.appleBooksAggregator, .missingOpeningCredits),
             (.acx, .missingClosingCredits), (.appleBooksAggregator, .missingClosingCredits),
             (.acx, .missingRetailSample), (.appleBooksAggregator, .missingRetailSample),
             (.acx, .retailSampleTooShort), (.appleBooksAggregator, .retailSampleTooShort),
             (.acx, .retailSampleTooLong), (.appleBooksAggregator, .retailSampleTooLong),
             (.acx, .retailSampleStartsInCredits), (.appleBooksAggregator, .retailSampleStartsInCredits): return .blocking
        case (.librivox, .chapterTooLong): return .warning
        case (.acx, .chapterTooLong), (.appleBooksAggregator, .chapterTooLong): return .blocking
        case (.librivox, .chapterVeryLong), (.internetArchive, .chapterVeryLong),
             (.acx, .chapterVeryLong), (.appleBooksAggregator, .chapterVeryLong),
             (.personalMaster, .chapterVeryLong): return .warning

        // Group 4 — audio quality
        case (.librivox, .clipping), (.acx, .clipping), (.appleBooksAggregator, .clipping): return .blocking
        case (.internetArchive, .clipping), (.personalMaster, .clipping): return .warning
        case (.librivox, .peakTooHot), (.internetArchive, .peakTooHot), (.personalMaster, .peakTooHot): return .warning
        case (.acx, .peakTooHot), (.appleBooksAggregator, .peakTooHot): return .blocking
        case (.librivox, .peakTooLow), (.acx, .peakTooLow), (.appleBooksAggregator, .peakTooLow): return .warning
        case (.librivox, .noiseFloorTooHigh), (.internetArchive, .noiseFloorTooHigh), (.personalMaster, .noiseFloorTooHigh): return .warning
        case (.acx, .noiseFloorTooHigh), (.appleBooksAggregator, .noiseFloorTooHigh): return .blocking
        case (.librivox, .noiseFloorUnreliable), (.internetArchive, .noiseFloorUnreliable),
             (.acx, .noiseFloorUnreliable), (.appleBooksAggregator, .noiseFloorUnreliable),
             (.personalMaster, .noiseFloorUnreliable): return .warning
        case (.librivox, .dcOffset), (.internetArchive, .dcOffset), (.acx, .dcOffset),
             (.appleBooksAggregator, .dcOffset), (.personalMaster, .dcOffset): return .warning
        case (.librivox, .sampleRateMismatch), (.acx, .sampleRateMismatch), (.appleBooksAggregator, .sampleRateMismatch): return .warning
        case (.librivox, .channelInconsistency), (.acx, .channelInconsistency), (.appleBooksAggregator, .channelInconsistency): return .blocking
        case (.internetArchive, .channelInconsistency), (.personalMaster, .channelInconsistency): return .warning
        case (.librivox, .stereoWhereMonoExpected), (.acx, .stereoWhereMonoExpected), (.appleBooksAggregator, .stereoWhereMonoExpected): return .warning
        case (.internetArchive, .bitDepthMismatch), (.personalMaster, .bitDepthMismatch): return .warning
        case (.librivox, .loudnessDiscontinuity), (.internetArchive, .loudnessDiscontinuity),
             (.acx, .loudnessDiscontinuity), (.appleBooksAggregator, .loudnessDiscontinuity),
             (.personalMaster, .loudnessDiscontinuity): return .warning
        case (.librivox, .durationOutlier), (.internetArchive, .durationOutlier),
             (.acx, .durationOutlier), (.appleBooksAggregator, .durationOutlier): return .warning
        case (.librivox, .suspectedTruncation), (.internetArchive, .suspectedTruncation), (.personalMaster, .suspectedTruncation): return .warning
        case (.acx, .suspectedTruncation), (.appleBooksAggregator, .suspectedTruncation): return .blocking
        case (.librivox, .excessiveLeadingSilence), (.acx, .excessiveLeadingSilence), (.appleBooksAggregator, .excessiveLeadingSilence): return .warning
        case (.acx, .rmsOutOfRange), (.appleBooksAggregator, .rmsOutOfRange): return .blocking
        case (.acx, .headRoomToneOutOfRange), (.appleBooksAggregator, .headRoomToneOutOfRange),
             (.acx, .tailRoomToneOutOfRange), (.appleBooksAggregator, .tailRoomToneOutOfRange): return .warning
        case (.librivox, .missingMetrics), (.internetArchive, .missingMetrics), (.personalMaster, .missingMetrics): return .warning
        case (.acx, .missingMetrics), (.appleBooksAggregator, .missingMetrics): return .blocking

        // Group 5 — loudness
        case (.librivox, .perceivedVolumeOutOfBand): return .warning

        // Group 6 — iPhone preflight (§12.2). These are export-operational
        // gates, never quality findings, and they apply to every destination
        // that needs local audio to start.
        case (.librivox, .assetRemoteOnlyForExport), (.internetArchive, .assetRemoteOnlyForExport),
             (.acx, .assetRemoteOnlyForExport), (.appleBooksAggregator, .assetRemoteOnlyForExport),
             (.personalMaster, .assetRemoteOnlyForExport): return .blocking
        case (.librivox, .localStorageInsufficient), (.internetArchive, .localStorageInsufficient),
             (.acx, .localStorageInsufficient), (.appleBooksAggregator, .localStorageInsufficient),
             (.personalMaster, .localStorageInsufficient): return .blocking
        case (.librivox, .backupNotVerified), (.internetArchive, .backupNotVerified),
             (.acx, .backupNotVerified), (.appleBooksAggregator, .backupNotVerified),
             (.personalMaster, .backupNotVerified): return .warning
        case (.acx, .routeNotRetailReady), (.appleBooksAggregator, .routeNotRetailReady): return .warning

        default: return nil
        }
    }

    // MARK: - Small math helpers

    private func mostCommon<T: Hashable>(_ values: [T]) -> T? {
        guard !values.isEmpty else { return nil }
        var counts: [T: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Lightweight BCP-47 check: a 2–8 letter primary subtag with optional
    /// hyphen-separated 1–8 character subtags.
    private func isValidBCP47(_ s: String) -> Bool {
        let pattern = "^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$"
        return s.range(of: pattern, options: .regularExpression) != nil
    }
}
