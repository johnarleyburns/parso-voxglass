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

    public init(
        integrityFindings: [IntegrityFinding] = [],
        aiDisclosurePresent: Bool = false,
        retailSample: RetailSampleSelection? = nil,
        artworkPixelSize: (width: Int, height: Int)? = nil,
        truncationEdgeLevels: [UUID: EdgeLevels] = [:]
    ) {
        self.integrityFindings = integrityFindings
        self.aiDisclosurePresent = aiDisclosurePresent
        self.retailSample = retailSample
        self.artworkPixelSize = artworkPixelSize
        self.truncationEdgeLevels = truncationEdgeLevels
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
        return issues
    }

    // MARK: - Group 1 — Metadata and rights

    private mutating func evaluateMetadata() {
        let m = project.metadata

        if m.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.missingTitle, "Missing title", "The book has no title.")
        }
        if m.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.missingAuthor, "Missing author", "The book has no author.")
        }
        if m.narrator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.missingNarrator, "Missing narrator", "The book has no narrator.")
        }
        if m.language.isEmpty || !isValidBCP47(m.language) {
            add(.missingLanguage, "Missing or invalid language", "\"\(m.language)\" is not a valid BCP-47 language tag.", measured: nil, expected: "BCP-47, e.g. en-US")
        }
        if m.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.missingDescription, "Missing description", "A description is required for this destination.")
        }

        let rights = project.rights
        if rights.sourceURL == nil {
            add(.missingSourceURL, "Missing source URL", "The authorized source edition URL is required.")
        }
        // `.missingRightsBasis` never fires: `RightsBasis` is non-optional and
        // always populated by the wizard. `personalUseOnly` for a public
        // destination is the real hazard, handled below.
        if rights.basis == .personalUseOnly {
            add(.personalRightsForPublicTarget, "Personal-use rights", "Personal use only is not valid for a public destination.")
        }
        if !rights.isAttested {
            add(.unattestedRights, "Rights not attested", "The rights attestation has not been confirmed.")
        }

        if m.coverRef == nil {
            add(.missingCoverArt, "Missing cover art", "This destination requires cover art.")
        }
        if let size = context.artworkPixelSize {
            let minPx: Int
            switch profile.artwork {
            case .none: minPx = 0
            case .optionalSquare(let px), .requiredSquare(let px, _, _): minPx = px
            }
            let shortest = min(size.width, size.height)
            if minPx > 0, shortest < minPx {
                add(.artworkTooSmall, "Cover art too small", "Cover is \(size.width)×\(size.height); this destination needs at least \(minPx) px on the short side.", measured: Double(shortest), expected: "≥ \(minPx) px")
            }
            if minPx > 0 {
                let ratio = Double(size.width) / Double(max(1, size.height))
                if ratio < 0.99 || ratio > 1.01 {
                    add(.artworkNotSquare, "Cover art not square", "Cover aspect ratio is \(String(format: "%.2f", ratio)); this destination requires 1:1.", measured: ratio, expected: "1.0 ± 0.01")
                }
            }
        }

        if m.copyrightYear == nil {
            add(.missingCopyrightYear, "Missing copyright year", "The copyright year is required for this destination.")
        }
        if m.publisher == nil || m.publisher?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            add(.missingPublisher, "Missing publisher", "A publisher is expected for this destination.")
        }

        if m.archiveIdentifier == nil || m.archiveIdentifier?.isEmpty == true {
            add(.missingArchiveIdentifier, "Missing archive identifier", "An Internet Archive identifier is required.")
        } else if let id = m.archiveIdentifier, !IdentifierSuggester().isValid(id) {
            add(.invalidArchiveIdentifier, "Invalid archive identifier", "\"\(id)\" is not a valid archive.org identifier.")
        }
    }

    // MARK: - Group 2 — Narration origin and eligibility

    private mutating func evaluateOriginAndEligibility() {
        if isLibrivox && !eligibility.librivoxEligible {
            add(.aiOriginInLibriVoxProject, "AI audio in LibriVox project", LegalStrings.librivoxHumanOnly)
        }

        for (paragraph, take) in orderedTakes where take.origin.storageKind == "unknownImport" {
            add(.unknownOriginTakeSelected, "Unknown-origin take selected", "Paragraph \(paragraph.ordinal) has a selected take with an undeclared origin.", paragraphID: paragraph.id, takeID: take.id)
        }

        if eligibility.narrationOrigin == .containsImportedAI, !context.aiDisclosurePresent {
            add(.undisclosedAINarration, "AI narration not disclosed", "This project contains AI-origin narration; the disclosure line must appear in the delivered manifest and metadata.")
        }
    }

    // MARK: - Group 3 — Completeness and structure (integrity-derived)

    private mutating func evaluateIntegrity() {
        for finding in context.integrityFindings {
            switch finding.code {
            case .duplicateChapterOrdinal, .duplicateParagraphOrdinal:
                add(.duplicateOrdinal, "Duplicate ordinal", finding.message, chapterID: finding.chapterID, paragraphID: finding.paragraphID)
            case .missingChapterOrdinal, .missingParagraphOrdinal:
                add(.missingOrdinal, "Missing ordinal", finding.message, chapterID: finding.chapterID, paragraphID: finding.paragraphID)
            case .takeAssetMissing:
                add(.assetMissing, "Missing audio asset", finding.message, chapterID: finding.chapterID, paragraphID: finding.paragraphID)
            case .takeAssetHashMismatch:
                add(.assetHashMismatch, "Audio asset hash mismatch", finding.message, chapterID: finding.chapterID, paragraphID: finding.paragraphID)
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
                add(.emptyChapter, "Empty chapter", "Chapter \(chapter.title) has no paragraphs.", chapterID: chapter.id)
                continue
            }

            for paragraph in chapter.paragraphs {
                let isRecordedTarget = paragraph.role == .body || paragraph.role == .chapterHeading

                if isRecordedTarget && paragraph.selectedTakeID == nil {
                    add(.missingAcceptedTake, "Missing accepted take", "Paragraph \(paragraph.ordinal) of \(chapter.title) has no selected audio.", chapterID: chapter.id, paragraphID: paragraph.id, fix: .recordParagraph(paragraph.id))
                }

                if paragraph.reviewState == .needsPickup {
                    add(.unresolvedNeedsPickup, "Unresolved needs pickup", "Paragraph \(paragraph.ordinal) of \(chapter.title) must be re-recorded.", chapterID: chapter.id, paragraphID: paragraph.id, fix: .clearPickup(paragraph.id))
                }

                if paragraph.selectedTakeID != nil && paragraph.reviewState != .approved {
                    unapproved += 1
                }

                if let takeID = paragraph.selectedTakeID,
                   let take = paragraph.takes.first(where: { $0.id == takeID }),
                   paragraph.textHash != take.textHashAtRecording {
                    if paragraph.reviewState == .needsPickup {
                        add(.textChangedAfterRecording, "Text changed after recording", "Paragraph \(paragraph.ordinal) of \(chapter.title) was recorded against older text and must be re-recorded.", chapterID: chapter.id, paragraphID: paragraph.id, takeID: take.id, fix: .recordParagraph(paragraph.id))
                    } else {
                        add(.textChangedCosmetically, "Text changed", "Paragraph \(paragraph.ordinal) of \(chapter.title) changed after it was recorded.", chapterID: chapter.id, paragraphID: paragraph.id, takeID: take.id, fix: .recordParagraph(paragraph.id))
                    }
                }
            }
        }

        if unapproved > 0 {
            add(.unapprovedParagraphs, "Unapproved paragraphs", "\(unapproved) recorded paragraph\(unapproved == 1 ? "" : "s") \(unapproved == 1 ? "is" : "are") not yet approved.")
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
                    if let paragraph {
                        if paragraph.selectedTakeID == nil {
                            add(.unrecordedDisclaimer, "Unrecorded \(kind == .libriVoxIntro ? "intro" : "outro")", "The LibriVox \(kind == .libriVoxIntro ? "intro" : "outro") for \(chapter.title) has no recording.", chapterID: chapter.id, paragraphID: paragraph.id, fix: .recordParagraph(paragraph.id))
                        }
                        let expected = kind == .libriVoxIntro ? plan.chapterIntros[chapter.id] : plan.chapterOutros[chapter.id]
                        if let expected, paragraph.text != expected {
                            add(.staleDisclaimerText, "Stale disclaimer text", "The LibriVox disclaimer for \(chapter.title) does not match the current metadata.", chapterID: chapter.id, paragraphID: paragraph.id, fix: .regenerateDisclaimers)
                        }
                    } else {
                        add(.missingDisclaimerParagraph, "Missing \(kind == .libriVoxIntro ? "intro" : "outro") disclaimer", "\(chapter.title) has no LibriVox \(kind == .libriVoxIntro ? "intro" : "outro") paragraph.", chapterID: chapter.id, fix: .regenerateDisclaimers, variant: kind.rawValue)
                    }
                }
            }
        }
    }

    private mutating func evaluateRetail() {
        guard isRetail else { return }

        for (role, title) in [(ChapterRole.openingCredits, "opening credits"), (.closingCredits, "closing credits")] {
            let chapter = project.chapters.first { $0.role == role }
            let recorded = chapter?.paragraphs.contains { $0.selectedTakeID != nil } ?? false
            let code: IssueCode = role == .openingCredits ? .missingOpeningCredits : .missingClosingCredits
            if !recorded {
                add(code, "Missing \(title)", "The \(title) paragraph must be recorded for a retail deliverable.", chapterID: chapter?.id, fix: .regenerateCredits)
            }
        }

        guard let sampleRule = profile.retailSample else { return }
        guard let selection = context.retailSample else {
            add(.missingRetailSample, "Missing retail sample", "A \(Int(sampleRule.minDuration))–\(Int(sampleRule.maxDuration)) second retail sample is required.")
            return
        }

        if selection.duration < sampleRule.minDuration {
            add(.retailSampleTooShort, "Retail sample too short", "The retail sample is \(Int(selection.duration)) s; the minimum is \(Int(sampleRule.minDuration)) s.", measured: selection.duration, expected: "≥ \(Int(sampleRule.minDuration)) s", fix: .setRetailSample)
        }
        if selection.duration > sampleRule.maxDuration {
            add(.retailSampleTooLong, "Retail sample too long", "The retail sample is \(Int(selection.duration)) s; the maximum is \(Int(sampleRule.maxDuration)) s.", measured: selection.duration, expected: "≤ \(Int(sampleRule.maxDuration)) s", fix: .setRetailSample)
        }
        if let start = project.allParagraphs.first(where: { $0.id == selection.startParagraphID }),
           start.role == .retailOpeningCredits || start.role == .retailClosingCredits {
            add(.retailSampleStartsInCredits, "Retail sample starts in credits", "The retail sample must begin with narration, not credits.", paragraphID: start.id, fix: .setRetailSample)
        }
    }

    // MARK: - Assembly-derived rules (§15.4): chapter duration and room tone

    private mutating func evaluateChapterDurations() {
        let builder = SegmentQueueBuilder()

        for chapter in project.chapters {
            let segments = builder.build(.chapter(chapter.id), from: project, settings: assembly)
            let duration = AssemblyDuration.duration(of: segments)

            if let max = profile.maxFileDuration, duration > max {
                add(.chapterTooLong, "Chapter too long", "\(chapter.title) is \(Int(duration)) s; this destination caps files at \(Int(max)) s.", chapterID: chapter.id, measured: duration, expected: "≤ \(Int(max)) s", fix: .splitChapter(chapter.id, atParagraph: chapter.paragraphs.first?.id ?? chapter.id))
            }
            if duration > ValidationThresholds.veryLongChapterSeconds {
                add(.chapterVeryLong, "Chapter very long", "\(chapter.title) exceeds \(Int(ValidationThresholds.veryLongChapterSeconds / 60)) minutes; consider splitting it.", chapterID: chapter.id, measured: duration)
            }

            if isRetail, let rule = profile.headroomSilence, !segments.isEmpty {
                let head = segments.first!.leadingSilence
                if head < rule.headMin || head > rule.headMax {
                    add(.headRoomToneOutOfRange, "Head room tone out of range", "\(chapter.title) has \(String(format: "%.2f", head)) s of head silence; expected \(String(format: "%.2f", rule.headMin))–\(String(format: "%.2f", rule.headMax)) s.", chapterID: chapter.id, measured: head)
                }
                let tail = segments.last!.trailingSilence
                if tail < rule.tailMin || tail > rule.tailMax {
                    add(.tailRoomToneOutOfRange, "Tail room tone out of range", "\(chapter.title) has \(String(format: "%.2f", tail)) s of tail silence; expected \(String(format: "%.2f", rule.tailMin))–\(String(format: "%.2f", rule.tailMax)) s.", chapterID: chapter.id, measured: tail)
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
                add(.loudnessDiscontinuity, "Loudness discontinuity", "Paragraph is approximately \(String(format: "%.1f", abs(entry.rmsDBFS - median))) dB louder or quieter than adjacent paragraphs.", paragraphID: entry.paragraphID, measured: abs(entry.rmsDBFS - median), expected: "≤ \(ValidationThresholds.loudnessDiscontinuityDB) dB")
            }
        }

        for (paragraph, take) in takes {
            guard let m = metrics[take.id] else {
                add(.missingMetrics, "Missing quality metrics", "Paragraph \(paragraph.ordinal) has no audio-quality metrics.", paragraphID: paragraph.id, takeID: take.id, fix: .reanalyzeTake(take.id))
                continue
            }
            guard m.analyzerVersion == analyzerVersion else {
                add(.missingMetrics, "Stale quality metrics", "Paragraph \(paragraph.ordinal) has metrics from an older analyzer.", paragraphID: paragraph.id, takeID: take.id, fix: .reanalyzeTake(take.id))
                continue
            }

            if m.clipCount > 0 {
                add(.clipping, "Clipping detected", "Paragraph \(paragraph.ordinal) contains \(m.clipCount) clipped run\(m.clipCount == 1 ? "" : "s").", paragraphID: paragraph.id, takeID: take.id, measured: Double(m.clipCount), expected: "0", fix: .recordParagraph(paragraph.id))
            }
            if let ceiling = profile.peakCeilingDBFS, m.truePeakDBFS > ceiling {
                add(.peakTooHot, "Peak too hot", "Paragraph \(paragraph.ordinal) peaks at \(String(format: "%.1f", m.truePeakDBFS)) dBFS; the ceiling is \(String(format: "%.1f", ceiling)) dBFS.", paragraphID: paragraph.id, takeID: take.id, measured: m.truePeakDBFS, expected: "≤ \(String(format: "%.1f", ceiling)) dBFS")
            }
            if m.peakDBFS < ValidationThresholds.peakTooLowDBFS {
                add(.peakTooLow, "Suspiciously quiet capture", "Paragraph \(paragraph.ordinal) peaks at \(String(format: "%.1f", m.peakDBFS)) dBFS.", paragraphID: paragraph.id, takeID: take.id, measured: m.peakDBFS)
            }
            if let ceiling = profile.noiseFloorCeilingDBFS, m.noiseFloorDBFS > ceiling {
                add(.noiseFloorTooHigh, "Noise floor too high", "Paragraph \(paragraph.ordinal) has a \(String(format: "%.1f", m.noiseFloorDBFS)) dBFS noise floor; the ceiling is \(String(format: "%.1f", ceiling)) dBFS.", paragraphID: paragraph.id, takeID: take.id, measured: m.noiseFloorDBFS, expected: "≤ \(String(format: "%.1f", ceiling)) dBFS")
            }
            if !m.noiseFloorReliable {
                add(.noiseFloorUnreliable, "Noise floor unreliable", "Paragraph \(paragraph.ordinal) has too little silence to measure a reliable noise floor.", paragraphID: paragraph.id, takeID: take.id)
            }
            if abs(m.dcOffset) > ValidationThresholds.dcOffsetWarnThreshold {
                add(.dcOffset, "DC offset", "Paragraph \(paragraph.ordinal) has a DC offset of \(String(format: "%.4f", m.dcOffset)).", paragraphID: paragraph.id, takeID: take.id, measured: m.dcOffset)
            }

            if let majority = majorityRate, take.format.sampleRate != majority {
                add(.sampleRateMismatch, "Sample rate mismatch", "Paragraph \(paragraph.ordinal) is \(Int(take.format.sampleRate)) Hz while the rest of the project is \(Int(majority)) Hz.", paragraphID: paragraph.id, takeID: take.id, measured: take.format.sampleRate, expected: "\(Int(majority)) Hz")
            }
            if let majority = majorityChannels, take.format.channels != majority {
                add(.channelInconsistency, "Channel inconsistency", "Paragraph \(paragraph.ordinal) has \(take.format.channels) channel\(take.format.channels == 1 ? "" : "s") while the rest of the project has \(majority).", paragraphID: paragraph.id, takeID: take.id, measured: Double(take.format.channels), expected: "\(majority)")
            }
            if m.channels == 2, let expected = profile.audio.channels, expected == 1 {
                add(.stereoWhereMonoExpected, "Stereo where mono expected", "Paragraph \(paragraph.ordinal) is stereo; this destination expects mono.", paragraphID: paragraph.id, takeID: take.id, measured: 2, expected: "1")
            }

            if let edge = context.truncationEdgeLevels[take.id],
               edge.leadingDBFS > ValidationThresholds.truncationEdgeDBFS || edge.trailingDBFS > ValidationThresholds.truncationEdgeDBFS {
                add(.suspectedTruncation, "Suspected truncated take", "Paragraph \(paragraph.ordinal) starts or ends abruptly at the file edge.", paragraphID: paragraph.id, takeID: take.id, measured: max(edge.leadingDBFS, edge.trailingDBFS), expected: "≤ \(ValidationThresholds.truncationEdgeDBFS) dBFS")
            }
            if m.leadingSilence > ValidationThresholds.excessiveLeadingSilenceSeconds {
                add(.excessiveLeadingSilence, "Excessive leading silence", "Paragraph \(paragraph.ordinal) has \(String(format: "%.1f", m.leadingSilence)) s of leading silence.", paragraphID: paragraph.id, takeID: take.id, measured: m.leadingSilence, expected: "≤ \(ValidationThresholds.excessiveLeadingSilenceSeconds) s")
            }

            let estimate = Double(paragraph.text.count) / ValidationThresholds.estimatedCharsPerSecond
            let deviation = estimate == 0 ? 0 : abs(take.duration - estimate) / estimate
            if deviation > ValidationThresholds.durationOutlierFraction {
                add(.durationOutlier, "Duration outlier", "Paragraph \(paragraph.ordinal) is \(String(format: "%.0f", take.duration)) s against an estimated \(Int(estimate)) s of text.", paragraphID: paragraph.id, takeID: take.id, measured: take.duration, expected: "≈ \(Int(estimate)) s")
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
                    add(.rmsOutOfRange, "Chapter RMS out of range", "\(chapter.title) measures \(String(format: "%.1f", chapterRMS)) dBFS RMS; expected \(Int(minDB)) to \(Int(maxDB)) dBFS.", chapterID: chapter.id, measured: chapterRMS, expected: "\(Int(minDB)) to \(Int(maxDB)) dBFS")
                }
            }
        }

        // Mixed bit depth across the project's originals.
        let bitDepths = Set(takes.compactMap { $0.take.format.bitDepth })
        if bitDepths.count > 1 {
            add(.bitDepthMismatch, "Mixed bit depths", "The project mixes bit depths: \(bitDepths.sorted().map(String.init).joined(separator: ", ")).")
        }
    }

    // MARK: - Group 5 — LibriVox perceived loudness

    private mutating func evaluateLoudness() {
        guard isLibrivox, case .replayGainBand(let low, let high, let target) = profile.loudness else { return }
        for (paragraph, take) in orderedTakes {
            guard let m = metrics[take.id], m.analyzerVersion == analyzerVersion else { continue }
            let perceived = target - m.replayGainDB
            if perceived < low || perceived > high {
                add(.perceivedVolumeOutOfBand, "Estimated perceived volume out of band", "Estimated perceived volume is \(Int(perceived.rounded())) dB (LibriVox prefers \(Int(low))–\(Int(high)) dB). This is an estimate; the LibriVox checker is authoritative.", paragraphID: paragraph.id, takeID: take.id, measured: perceived, expected: "\(Int(low))–\(Int(high)) dB")
            }
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
        issues.append(ValidationIssue(
            id: ValidationIssue.deterministicID(code: code, chapterID: chapterID, paragraphID: paragraphID, variant: variant),
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
