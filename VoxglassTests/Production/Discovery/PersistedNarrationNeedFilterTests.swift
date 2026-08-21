import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct PersistedNarrationNeedFilterTests {

    @Test func stableNeedIDExcludesEquivalentSourceRow() {
        let need = makeNeed(title: "The Work", author: "An Author", host: "gutenberg.org", text: "text")
        let unrelated = makeNeed(title: "Another Work", author: "An Author", host: "archive.org", text: "text")
        let project = ProjectFixtures.tiny()

        let remaining = NarrationNeed.excludingPersistedProjects(
            [need, unrelated], projects: [project], persistedNeedIDs: [need.id]
        )

        #expect(remaining.map(\.workIdentity) == [unrelated.workIdentity])
    }

    @Test func normalizedTitleAuthorFallbackExcludesLegacyProject() {
        let need = makeNeed(title: "The  Works", author: "Émile  Zola", text: "text")
        var project = ProjectFixtures.tiny()
        project.metadata.title = "the works"
        project.metadata.author = "Emile Zola"

        let remaining = NarrationNeed.excludingPersistedProjects(
            [need], projects: [project], persistedNeedIDs: []
        )

        #expect(remaining.isEmpty)
    }

    @Test func unrelatedWorkRemainsAvailable() {
        let persisted = makeNeed(title: "Already Narrated", author: "One Author", text: "text")
        let unrelated = makeNeed(title: "Still Available", author: "Another Author", text: "text")
        var project = ProjectFixtures.tiny()
        project.metadata.title = persisted.work.title
        project.metadata.author = persisted.work.author

        let remaining = NarrationNeed.excludingPersistedProjects(
            [persisted, unrelated], projects: [project], persistedNeedIDs: []
        )

        #expect(remaining.map(\.workIdentity) == [unrelated.workIdentity])
    }

    @Test func incompleteProjectWithRecordedTakeIsStillExcluded() {
        let need = makeNeed(title: "Partly Recorded", author: "Reader", text: "text")
        var project = ProjectFixtures.typical()
        project.metadata.title = need.work.title
        project.metadata.author = need.work.author

        #expect(project.recordedCount > 0)
        #expect(project.recordedCount < project.totalCount)
        #expect(NarrationNeed.excludingPersistedProjects([need], projects: [project], persistedNeedIDs: []).isEmpty)
    }
}
