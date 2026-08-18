import Foundation
import Testing
import VoxglassCore

@Suite struct NarrationReviewCountsTests {
    @Test func recordedAndApprovedCountsRemainDistinct() {
        let progress = ChapterProgress(
            id: UUID(),
            ordinal: 0,
            title: "Chapter One",
            paragraphCount: 5,
            recordedCount: 4,
            approvedCount: 3,
            flaggedCount: 1
        )
        #expect(progress.recordedCount == 4)
        #expect(progress.approvedCount == 3)
        #expect(!progress.isComplete)
        let label = "\(progress.recordedCount) recorded · \(progress.approvedCount) approved"
        #expect(label == "4 recorded · 3 approved")
        #expect(!label.contains("/"))
    }
}
