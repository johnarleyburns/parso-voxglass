import Foundation

/// Per-chapter progress derived from a project, shown on the project dashboard
/// (mockup 04).
public struct ChapterProgress: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let ordinal: Int
    public let title: String
    public let paragraphCount: Int
    public let recordedCount: Int
    public let approvedCount: Int
    public let flaggedCount: Int

    public var isComplete: Bool {
        paragraphCount > 0 && approvedCount == paragraphCount
    }

    public var isNotStarted: Bool {
        recordedCount == 0
    }

    public var percentRecorded: Double {
        paragraphCount == 0 ? 0 : Double(recordedCount) / Double(paragraphCount)
    }

    public init(
        id: UUID,
        ordinal: Int,
        title: String,
        paragraphCount: Int,
        recordedCount: Int,
        approvedCount: Int,
        flaggedCount: Int
    ) {
        self.id = id
        self.ordinal = ordinal
        self.title = title
        self.paragraphCount = paragraphCount
        self.recordedCount = recordedCount
        self.approvedCount = approvedCount
        self.flaggedCount = flaggedCount
    }
}

/// The derived read model for the project dashboard (mockup 04). Pure
/// derivation from an `AudiobookProject` so the iPhone UI and the watch stay
/// consistent and the per-chapter counts are testable in Core.
public struct ProjectDashboard: Sendable, Equatable {
    public let chapterCount: Int
    public let paragraphCount: Int
    public let recordedCount: Int
    public let approvedCount: Int
    public let flaggedCount: Int
    public let needsPickupCount: Int
    public let driftCount: Int
    public let chapters: [ChapterProgress]

    public var percentRecorded: Double {
        paragraphCount == 0 ? 0 : Double(recordedCount) / Double(paragraphCount)
    }

    public var chaptersComplete: Int {
        chapters.count { $0.isComplete }
    }

    /// The first paragraph in document order with no selected take; or — if
    /// everything is recorded — the first `needsPickup` (spec §15.5).
    public var recordNextParagraphID: UUID? {
        if let id = firstParagraphWithoutSelectedTake { return id }
        return firstNeedsPickupParagraphID
    }

    /// The paragraph the "Record next" action resolves to, as the dashboard
    /// caption needs it ("Record next — ¶ N, Chapter M"). `nil` when every
    /// paragraph has a selected take and none needs pickup.
    public struct RecordNext {
        public let paragraphID: UUID
        public let paragraphNumber: Int
        public let chapterOrdinal: Int
    }

    public var recordNext: RecordNext? {
        guard let id = recordNextParagraphID,
              let paragraph = orderedParagraphs.first(where: { $0.id == id }),
              let chapter = orderedChapters.first(where: { $0.paragraphs.contains { $0.id == id } }) else {
            return nil
        }
        let number = orderedParagraphs.firstIndex(where: { $0.id == id }).map { $0 + 1 } ?? 0
        return RecordNext(paragraphID: id, paragraphNumber: number, chapterOrdinal: chapter.ordinal)
    }

    private let orderedParagraphs: [Paragraph]
    private let orderedChapters: [ProductionChapter]

    public init(project: AudiobookProject) {
        var chapters: [ChapterProgress] = []
        var recordedCount = 0
        var approvedCount = 0
        var flaggedCount = 0
        var needsPickupCount = 0
        var driftCount = 0

        for chapter in project.chapters {
            let recorded = chapter.paragraphs.count { $0.selectedTakeID != nil }
            let approved = chapter.paragraphs.count { $0.reviewState == .approved }
            let flagged = chapter.paragraphs.count { $0.reviewState == .flagged }
            let pickup = chapter.paragraphs.count { $0.reviewState == .needsPickup }
            let drift = chapter.paragraphs.count { Self.hasDrift($0) }

            chapters.append(ChapterProgress(
                id: chapter.id,
                ordinal: chapter.ordinal,
                title: chapter.title,
                paragraphCount: chapter.paragraphs.count,
                recordedCount: recorded,
                approvedCount: approved,
                flaggedCount: flagged
            ))

            recordedCount += recorded
            approvedCount += approved
            flaggedCount += flagged
            needsPickupCount += pickup
            driftCount += drift
        }

        self.chapterCount = project.chapters.count
        self.paragraphCount = project.allParagraphs.count
        self.recordedCount = recordedCount
        self.approvedCount = approvedCount
        self.flaggedCount = flaggedCount
        self.needsPickupCount = needsPickupCount
        self.driftCount = driftCount
        self.chapters = chapters
        self.orderedParagraphs = project.allParagraphs
        self.orderedChapters = project.chapters
    }

    /// A paragraph is "drifted" when its selected take was recorded against
    /// different text (§9.5 step 4 / validation `textChangedAfterRecording`).
    private static func hasDrift(_ paragraph: Paragraph) -> Bool {
        guard let selected = paragraph.selectedTakeID,
              let take = paragraph.takes.first(where: { $0.id == selected }) else { return false }
        return paragraph.textHash != take.textHashAtRecording
    }

    private var firstParagraphWithoutSelectedTake: UUID? {
        orderedParagraphs.first { $0.selectedTakeID == nil }?.id
    }

    private var firstNeedsPickupParagraphID: UUID? {
        orderedParagraphs.first { $0.reviewState == .needsPickup }?.id
    }
}
