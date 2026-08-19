import Foundation

public struct SegmenterOptions: Sendable, Equatable {
    public var mergeShortBlocksUnderChars: Int
    public var splitLongBlocksOverChars: Int
    public var treatHeadingsAsParagraphs: Bool
    public var sceneBreaksBecomeMarkers: Bool
    public var dropEmpty: Bool

    public init(
        mergeShortBlocksUnderChars: Int = 0,
        splitLongBlocksOverChars: Int = 0,
        treatHeadingsAsParagraphs: Bool = true,
        sceneBreaksBecomeMarkers: Bool = true,
        dropEmpty: Bool = true
    ) {
        self.mergeShortBlocksUnderChars = mergeShortBlocksUnderChars
        self.splitLongBlocksOverChars = splitLongBlocksOverChars
        self.treatHeadingsAsParagraphs = treatHeadingsAsParagraphs
        self.sceneBreaksBecomeMarkers = sceneBreaksBecomeMarkers
        self.dropEmpty = dropEmpty
    }
}

public struct SegmentationResult: Sendable {
    public var chapters: [ProductionChapter]
    public var warnings: [ImportWarning]
    public var stats: SegmentationStats
    public var reidentification: ReidentificationReport?

    public init(
        chapters: [ProductionChapter] = [],
        warnings: [ImportWarning] = [],
        stats: SegmentationStats = SegmentationStats(),
        reidentification: ReidentificationReport? = nil
    ) {
        self.chapters = chapters
        self.warnings = warnings
        self.stats = stats
        self.reidentification = reidentification
    }
}

public struct SegmentationStats: Sendable {
    public var chapterCount: Int = 0
    public var paragraphCount: Int = 0
    public var averageParagraphChars: Int = 0
    public var longestParagraphChars: Int = 0
    public var estimatedDuration: TimeInterval = 0

    public init(
        chapterCount: Int = 0,
        paragraphCount: Int = 0,
        averageParagraphChars: Int = 0,
        longestParagraphChars: Int = 0,
        estimatedDuration: TimeInterval = 0
    ) {
        self.chapterCount = chapterCount
        self.paragraphCount = paragraphCount
        self.averageParagraphChars = averageParagraphChars
        self.longestParagraphChars = longestParagraphChars
        self.estimatedDuration = estimatedDuration
    }
}

public struct Segmenter: Sendable {
    public init() {}

    public func segment(
        _ doc: ExtractedDocument,
        options: SegmenterOptions = SegmenterOptions(),
        existing: AudiobookProject? = nil,
        ids: any IDGenerator,
        clock: any Clock
    ) -> SegmentationResult {
        var warnings = doc.warnings
        var chapters: [ProductionChapter] = []
        var totalChars = 0
        var maxChars = 0
        var paragraphCount = 0

        let bodySections = partitionSections(doc.sections, &warnings)

        if bodySections.isEmpty {
            warnings.append(ImportWarning(kind: .emptySection, message: "Document contains no prose content"))
            return SegmentationResult(
                chapters: [],
                warnings: warnings,
                stats: SegmentationStats(chapterCount: 0, paragraphCount: 0, averageParagraphChars: 0, longestParagraphChars: 0, estimatedDuration: 0)
            )
        }

        let filteredBlocks = filterBlocks(bodySections, options: options)

        var reidentification: ReidentificationReport? = nil
        if let existing = existing {
            let matcher = ParagraphReidentifier()
            reidentification = matcher.match(existing: existing.allParagraphs, incoming: filteredBlocks)
        }
        let exByID = existing.map { Dictionary(uniqueKeysWithValues: $0.allParagraphs.map { ($0.id, $0) }) } ?? [:]

        let sourceHash = doc.plainText.isEmpty ? "" : TextNormalizer.hash(doc.plainText)
        var incomingIndex = 0

        for (secIndex, section) in bodySections.enumerated() {
            var chapterParagraphs: [Paragraph] = []
            var ordinal = 0
            var pendingSceneBreak = false

            for block in section.blocks {
                if block.kind == .sceneBreak {
                    if options.sceneBreaksBecomeMarkers {
                        pendingSceneBreak = true
                    }
                    continue
                }

                if block.kind == .heading && !options.treatHeadingsAsParagraphs {
                    continue
                }

                let blockText = block.text
                if options.dropEmpty && blockText.trimmingCharacters(in: .whitespaces).isEmpty {
                    continue
                }

                let role: ParagraphRole = block.kind == .heading ? .chapterHeading : .body

                let paragraphID = reusedID(from: reidentification, at: incomingIndex, ids: ids)
                var reviewState: ReviewState = .unreviewed
                if let exID = reidentification?.assignments[incomingIndex],
                   let drift = reidentification?.driftedIDs[exID],
                   drift == .semantic {
                    reviewState = .needsPickup
                }
                incomingIndex += 1

                let existingParagraph = reidentification?.assignments[incomingIndex - 1].flatMap { exByID[$0] }
                let hash = TextNormalizer.hash(blockText)
                let paragraph = Paragraph(
                    id: paragraphID,
                    ordinal: ordinal,
                    text: blockText,
                    textHash: hash,
                    role: role,
                    directionNote: existingParagraph?.directionNote,
                    pronunciationRefs: existingParagraph?.pronunciationRefs ?? [],
                    takes: existingParagraph?.takes ?? [],
                    selectedTakeID: existingParagraph?.selectedTakeID,
                    reviewState: reviewState,
                    sourceRange: SourceRange(
                        startOffset: block.sourceRange.lowerBound,
                        endOffset: block.sourceRange.upperBound,
                        sourceFileHash: sourceHash
                    ),
                    isSceneBreak: pendingSceneBreak
                )

                chapterParagraphs.append(paragraph)
                totalChars += blockText.count
                maxChars = max(maxChars, blockText.count)
                ordinal += 1
                pendingSceneBreak = false
            }

            if chapterParagraphs.isEmpty {
                warnings.append(ImportWarning(kind: .emptySection, message: "Chapter \"\(section.heading ?? "Untitled")\" has no paragraphs"))
                continue
            }

            let chapterTitle = secIndex == 0 && section.heading == nil
                ? "Front Matter"
                : (section.heading ?? "Chapter \(secIndex + 1)")

            let chapter = ProductionChapter(
                id: UUID(uuidString: ids.next().uuidString) ?? ids.next(),
                ordinal: chapters.count,
                title: chapterTitle,
                role: secIndex == 0 && section.heading == nil ? .frontMatter : .body,
                paragraphs: chapterParagraphs
            )
            chapters.append(chapter)
            paragraphCount += chapterParagraphs.count
        }

        if let report = reidentification, !report.retiredIDs.isEmpty {
            let retired = report.retiredIDs.compactMap { exByID[$0] }
            if !retired.isEmpty {
                chapters.append(ProductionChapter(
                    id: UUID(uuidString: ids.next().uuidString) ?? ids.next(),
                    ordinal: chapters.count,
                    title: "Orphaned Recordings",
                    role: .backMatter,
                    paragraphs: retired
                ))
            }
        }

        let avgChars = paragraphCount > 0 ? totalChars / paragraphCount : 0
        let estimatedDuration: TimeInterval = Double(totalChars) / 14.5

        return SegmentationResult(
            chapters: chapters,
            warnings: warnings,
            stats: SegmentationStats(
                chapterCount: chapters.count,
                paragraphCount: paragraphCount,
                averageParagraphChars: avgChars,
                longestParagraphChars: maxChars,
                estimatedDuration: estimatedDuration
            ),
            reidentification: reidentification
        )
    }

    private func filterBlocks(_ sections: [ExtractedSection], options: SegmenterOptions) -> [ExtractedBlock] {
        var result: [ExtractedBlock] = []
        for section in sections {
            for block in section.blocks {
                if block.kind == .sceneBreak { continue }
                if block.kind == .heading && !options.treatHeadingsAsParagraphs { continue }
                if options.dropEmpty && block.text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                result.append(block)
            }
        }
        return result
    }

    private func reusedID(from report: ReidentificationReport?, at index: Int, ids: any IDGenerator) -> UUID {
        if let existingID = report?.assignments[index] { return existingID }
        return UUID(uuidString: ids.next().uuidString) ?? ids.next()
    }

    private func partitionSections(
        _ sections: [ExtractedSection],
        _ warnings: inout [ImportWarning]
    ) -> [ExtractedSection] {
        var result: [ExtractedSection] = []
        var currentBlocks: [ExtractedBlock] = []
        var currentHeading: String? = nil
        var currentStart = 0

        func flush() {
            if !currentBlocks.isEmpty {
                result.append(ExtractedSection(heading: currentHeading, blocks: currentBlocks, sourceStart: currentStart))
                currentBlocks = []
                currentHeading = nil
                currentStart = 0
            }
        }

        for section in sections {
            var sectionOpensWithHeading = false
            if section.heading != nil,
               let first = section.blocks.first, first.kind == .heading,
               let level = first.headingLevel, level <= 2 {
                sectionOpensWithHeading = true
            }

            if section.heading != nil, !sectionOpensWithHeading, !section.blocks.isEmpty {
                flush()
                currentHeading = section.heading
                currentStart = section.sourceStart
            }

            for block in section.blocks {
                // A .heading block at level 1 or 2 starts a new chapter (spec §9.2).
                if block.kind == .heading, let level = block.headingLevel, level <= 2 {
                    flush()
                    currentHeading = block.text
                    currentStart = block.sourceRange.lowerBound
                    currentBlocks = [block]
                } else {
                    currentBlocks.append(block)
                }
            }
        }

        flush()
        return result
    }
}
