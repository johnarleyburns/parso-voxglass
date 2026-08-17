import Foundation
import Observation
import VoxglassCore

/// Backs the Project Dashboard (spec §18.1.5). All figures are derived from
/// the in-memory project so the screen is correct even before the store
/// catches up; `load()` recomputes after store-backed changes.
@Observable @MainActor
public final class ProjectDashboardModel {
    public struct ChapterRow: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let ordinal: Int
        public let title: String
        public let recorded: Int
        public let total: Int

        public init(id: UUID, ordinal: Int, title: String, recorded: Int, total: Int) {
            self.id = id
            self.ordinal = ordinal
            self.title = title
            self.recorded = recorded
            self.total = total
        }
    }

    public struct RecordNext: Equatable, Sendable {
        public let paragraphID: UUID
        public let kind: Kind

        public enum Kind: String, Sendable {
            case fresh
            case pickup
        }
    }

    public private(set) var counts: ProjectCounts
    public private(set) var chapterRows: [ChapterRow] = []
    public private(set) var recordNext: RecordNext?

    private let store: any ProductionStore
    private var project: AudiobookProject

    public init(project: AudiobookProject, store: any ProductionStore) {
        self.project = project
        self.store = store
        self.counts = ProjectCounts()
        rebuild()
    }

    public func load() async {
        rebuild()
    }

    /// "Record Next" resolves to the first paragraph in document order with no
    /// selected take, or the first `needsPickup` if everything is recorded
    /// (spec §18.1.5).
    public func refreshRecordNext() {
        recordNext = resolveRecordNext()
    }

    // MARK: - Private

    private func rebuild() {
        counts = computeCounts()
        chapterRows = project.chapters
            .sorted { $0.ordinal < $1.ordinal }
            .map { chapter in
                let total = chapter.paragraphs.count
                let recorded = chapter.paragraphs.count { $0.selectedTakeID != nil }
                return ChapterRow(
                    id: chapter.id,
                    ordinal: chapter.ordinal,
                    title: chapter.title,
                    recorded: recorded,
                    total: total
                )
            }
        recordNext = resolveRecordNext()
    }

    private func computeCounts() -> ProjectCounts {
        var c = ProjectCounts()
        for chapter in project.chapters {
            c.chapters += 1
            for para in chapter.paragraphs {
                c.paragraphs += 1
                if let take = selectedTake(of: para) {
                    c.recorded += 1
                    c.totalRecordedDuration += take.duration
                    if !take.origin.isHumanNarration {
                        c.aiOriginSelected += 1
                    }
                }
                switch para.reviewState {
                case .flagged: c.flagged += 1
                case .needsPickup: c.needsPickup += 1
                case .approved: c.approved += 1
                case .unreviewed: c.unreviewed += 1
                }
            }
        }
        return c
    }

    private func resolveRecordNext() -> RecordNext? {
        for chapter in project.chapters.sorted(by: { $0.ordinal < $1.ordinal }) {
            for para in chapter.paragraphs where para.selectedTakeID == nil {
                return RecordNext(paragraphID: para.id, kind: .fresh)
            }
        }
        for chapter in project.chapters.sorted(by: { $0.ordinal < $1.ordinal }) {
            for para in chapter.paragraphs where para.reviewState == .needsPickup {
                return RecordNext(paragraphID: para.id, kind: .pickup)
            }
        }
        return nil
    }

    private func selectedTake(of para: Paragraph) -> Take? {
        guard let id = para.selectedTakeID else { return nil }
        return para.takes.first { $0.id == id }
    }
}
