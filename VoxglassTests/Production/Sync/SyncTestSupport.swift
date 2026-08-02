import Foundation
import VoxglassCore

/// Computes `ProjectCounts` from a project the same way the Studio's store does,
/// so projection tests share one counting definition.
func counts(for project: AudiobookProject) -> ProjectCounts {
    var flagged = 0
    var needsPickup = 0
    var approved = 0
    var unreviewed = 0
    var recorded = 0
    var aiOriginSelected = 0
    var duration: TimeInterval = 0

    for paragraph in project.allParagraphs {
        switch paragraph.reviewState {
        case .flagged: flagged += 1
        case .needsPickup: needsPickup += 1
        case .approved: approved += 1
        case .unreviewed: unreviewed += 1
        }
        if let selectedID = paragraph.selectedTakeID,
           let take = paragraph.takes.first(where: { $0.id == selectedID }) {
            recorded += 1
            duration += take.duration
            if !take.origin.isHumanNarration { aiOriginSelected += 1 }
        }
    }

    return ProjectCounts(
        paragraphs: project.totalCount,
        recorded: recorded,
        flagged: flagged,
        needsPickup: needsPickup,
        approved: approved,
        unreviewed: unreviewed,
        chapters: project.chapters.count,
        totalRecordedDuration: duration,
        aiOriginSelected: aiOriginSelected
    )
}
