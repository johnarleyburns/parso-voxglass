import Foundation

/// The result of building a narration project from an imported document:
/// the project plus the segmentation stats and any warnings surfaced during
/// import, so the flow's source-review step can show counts first (§8.2).
public struct NarrationProjectBuild: Sendable {
    public var project: AudiobookProject
    public var stats: SegmentationStats
    public var warnings: [ImportWarning]

    public init(
        project: AudiobookProject,
        stats: SegmentationStats = SegmentationStats(),
        warnings: [ImportWarning] = []
    ) {
        self.project = project
        self.stats = stats
        self.warnings = warnings
    }
}

/// Builds an `AudiobookProject` from an imported `ExtractedDocument`: runs the
/// `Segmenter` to derive chapters, then applies the LibriVox script plan so the
/// generated disclaimers land as intro/outro paragraphs (spec §8.4, §5).
///
/// This is the Core counterpart of the flow's text-only single-chapter builder:
/// file imports (EPUB, TXT, Markdown, DOCX) keep their chapter structure instead
/// of being flattened into one chapter, so a 12-chapter TXT reaches the project
/// dashboard with correct per-chapter counts.
public struct NarrationProjectBuilder: Sendable {
    public init() {}

    /// Builds a project from a segmented document. `narrator` is best-effort;
    /// the LibriVox plan is applied so intro/outro disclaimers exist before
    /// recording starts, exactly as the LibriVox script generator dictates.
    public func build(
        document: ExtractedDocument,
        title: String,
        author: String,
        narrator: String,
        sourceURL: URL?,
        purpose: ProjectPurpose = .publicDomainCommunity,
        ids: any IDGenerator,
        clock: any Clock
    ) -> NarrationProjectBuild {
        let segmenter = Segmenter()
        let segmented = segmenter.segment(document, options: SegmenterOptions(), ids: ids, clock: clock)

        let finalTitle = title.isEmpty ? "This work" : title
        let finalAuthor = author.isEmpty ? "Unknown" : author

        var project = AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(
                title: finalTitle,
                author: finalAuthor,
                narrator: narrator,
                language: document.language ?? "en-US",
                description: BookMetadata.defaultDescription(title: finalTitle, author: finalAuthor, narrator: narrator)
            ),
            rights: RightsEvidence(basis: .publicDomainUS, sourceURL: sourceURL),
            profile: ProductionProfile(
                purpose: purpose,
                recording: RecordingDefaults(),
                intendedDestination: DestinationProfile.destination(for: purpose)
            ),
            source: nil,
            chapters: segmented.chapters,
            createdAt: clock.now,
            modifiedAt: clock.now
        )

        // Generated LibriVox disclaimers become intro/outro paragraphs in each
        // chapter (mockup 03: "generated LibriVox disclaimer added").
        let plan = LibriVoxScriptGenerator().plan(for: project)
        _ = ScriptApplier().apply(plan, to: &project, ids: ids, clock: clock)

        // Renumber paragraph ordinals within each chapter so the flow's
        // previous/next traversal stays in document order.
        for chapterIndex in project.chapters.indices {
            for paragraphIndex in project.chapters[chapterIndex].paragraphs.indices {
                project.chapters[chapterIndex].paragraphs[paragraphIndex].ordinal = paragraphIndex
            }
        }

        return NarrationProjectBuild(project: project, stats: segmented.stats, warnings: segmented.warnings)
    }
}
