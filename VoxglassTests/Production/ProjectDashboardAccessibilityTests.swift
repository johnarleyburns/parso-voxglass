import Foundation
import Testing
import VoxglassCore

@Suite struct ProjectDashboardAccessibilityTests {
    @Test func chapterStatusIsTextualNotColorOnly() {
        func chapter(recorded: Int, approved: Int) -> ChapterProgress {
            ChapterProgress(id: UUID(), ordinal: 0, title: "One", paragraphCount: 4,
                            recordedCount: recorded, approvedCount: approved, flaggedCount: 0)
        }
        #expect(chapter(recorded: 0, approved: 0).statusDescription == "Not started")
        #expect(chapter(recorded: 4, approved: 4).statusDescription == "Complete")
        #expect(chapter(recorded: 2, approved: 0).statusDescription == "50 percent recorded")
        let label = chapter(recorded: 2, approved: 0).accessibilityLabel
        #expect(label.contains("Chapter 1"))
        #expect(label.contains("One"))
        #expect(label.contains("4 paragraphs"))
        #expect(label.contains("50 percent recorded"))
    }
}
