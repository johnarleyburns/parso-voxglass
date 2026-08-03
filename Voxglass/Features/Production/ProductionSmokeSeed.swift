import Foundation
import VoxglassCore

/// Deterministic production-preview seed for the iPhone smoke test
/// (`-uiTestSeed onePreviewProject`, §19.6). Gives the app one previewable
/// project with recorded and flagged paragraphs so the reachability test can
/// assert `production.<slug>`, `detail.playWholeBook`, and
/// `detail.reviewFlagged`. Fixed IDs keep the smoke path deterministic.
enum ProductionSmokeSeed {

    static let projectID = UUID(uuidString: "0CA6F57D-6B41-4C38-A8F9-0000000000AA")!

    static let title = "The Murder of Roger Ackroyd"
    static let slug = "themurderofrogerackroyd"

    static let chapterIDs = (0..<3).map { UUID(uuidString: "0CA6F57D-6B41-4C38-A8F9-0000000000B\($0)")! }

    static func projection() -> SyncProjection {
        var paragraphs: [ParagraphProjection] = []
        var ordinal = 0
        for chapterIndex in 0..<3 {
            for local in 0..<4 {
                let isFlagged = chapterIndex == 0 && local == 0
                paragraphs.append(ParagraphProjection(
                    id: UUID(uuidString: "0CA6F57D-6B41-4C38-A8F9-000000000\(100 + ordinal)")!,
                    chapterID: chapterIDs[chapterIndex],
                    projectID: projectID,
                    ordinal: local,
                    globalOrdinal: ordinal,
                    text: "Sample paragraph \(ordinal) of the preview project.",
                    reviewState: isFlagged ? .flagged : .unreviewed,
                    takeID: UUID(),
                    duration: 8.0,
                    proxySourceSHA: "seed-proxy-\(ordinal)",
                    originKind: "recorded"
                ))
                ordinal += 1
            }
        }
        return SyncProjection(
            project: ProjectSummary(
                id: projectID,
                title: title,
                author: "Agatha Christie",
                narrator: "A. Narrator",
                percentRecorded: 0.5,
                recordedCount: 12,
                totalCount: 12,
                flaggedCount: 1,
                needsPickupCount: 0,
                unapprovedCount: 12,
                readyToExport: false,
                purpose: .publicDomainCommunity,
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                coverRef: nil,
                isHiddenFromDevices: false,
                projectionRevision: 7
            ),
            chapters: chapterIDs.enumerated().map { index, id in
                ChapterProjection(
                    id: id,
                    projectID: projectID,
                    ordinal: index,
                    title: "Chapter \(index + 1)",
                    paragraphCount: 4,
                    recordedCount: 4,
                    duration: 32
                )
            },
            paragraphs: paragraphs,
            revision: 7,
            narrationOrigin: .humanOnly,
            watchPinnedParagraphIDs: []
        )
    }
}
