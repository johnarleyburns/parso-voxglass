import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct NarrationNeedsLifecycleTests {

    @Test func noProjectsShowsStartShelves() {
        #expect(!hasRecordedContent(in: []))
    }

    @Test func draftOnlyProjectsStillShowStartShelves() {
        #expect(!ProjectFixtures.tiny().hasRecordedContent)
        #expect(!hasRecordedContent(in: [ProjectFixtures.tiny()]))
    }

    @Test func anyRecordedProjectHidesShortAndLongShelves() {
        let recorded = ProjectFixtures.typical()

        #expect(recorded.hasRecordedContent)
        #expect(hasRecordedContent(in: [ProjectFixtures.tiny(), recorded]))
    }

    private func hasRecordedContent(in projects: [AudiobookProject]) -> Bool {
        projects.contains { $0.recordedCount > 0 }
    }
}
