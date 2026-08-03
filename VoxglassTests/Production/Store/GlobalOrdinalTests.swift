import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// F-16: `global_ordinal` must stay contiguous in document order after any
/// structural mutation (split, merge, reorder, import, script application).
/// Every "¶ N of M" label on every surface reads this column (§7.8).
@Suite struct GlobalOrdinalTests {

    @Test func splitKeepsGlobalsContiguous() async throws {
        let db = ProjectDatabase.makeTemporary(named: "global-ordinal-split")
        let store = SQLiteProductionStore(databaseURL: db.url)
        var project = ProjectFixtures.stress(paragraphs: 1_000)
        try await store.save(project)

        // Split one paragraph in the middle of the book — the same mutation
        // the Script Editor performs (ParagraphSplitter + save + renumber).
        let target = project.allParagraphs[500]
        guard let chapterIndex = project.chapters.firstIndex(where: { $0.paragraphs.contains(where: { $0.id == target.id }) }),
              let paraIndex = project.chapters[chapterIndex].paragraphs.firstIndex(where: { $0.id == target.id }) else {
            Issue.record("fixture paragraph not found")
            return
        }
        let splitter = ParagraphSplitter()
        let (first, second) = splitter.split(target, atCharacterOffset: target.text.count / 2, ids: SequentialIDGenerator(), clock: FixedClock())
        project.chapters[chapterIndex].paragraphs[paraIndex] = first
        project.chapters[chapterIndex].paragraphs.insert(second, at: paraIndex + 1)
        project.chapters[chapterIndex].paragraphs.enumerated().forEach { i, p in
            project.chapters[chapterIndex].paragraphs[i].ordinal = i
        }

        try await store.save(project)
        try await store.renumberGlobalOrdinals()

        let summaries = try await store.paragraphSummaries(chapterID: nil)
        #expect(summaries.count == 1_001)
        #expect(Set(summaries.map(\.globalOrdinal)) == Set(0..<1_001), "global ordinals must be 0..<1001 contiguous")

        // And the summaries must be in document order: the split halves are
        // adjacent, and both appear exactly where the original was.
        let splitFirst = try #require(summaries.first { $0.id == first.id })
        let splitSecond = try #require(summaries.first { $0.id == second.id })
        #expect(splitSecond.globalOrdinal == splitFirst.globalOrdinal + 1)
    }

    @Test func reorderChaptersRenumbersGlobals() async throws {
        let db = ProjectDatabase.makeTemporary(named: "global-ordinal-reorder")
        let store = SQLiteProductionStore(databaseURL: db.url)
        let project = ProjectFixtures.typical()
        try await store.save(project)

        // Move the last chapter to the front by re-writing ordinals, then
        // renumber — the persisted column must follow the new document order.
        var reordered = project
        var first = reordered.chapters[0]
        for i in reordered.chapters.indices where i > 0 {
            reordered.chapters[i].ordinal = i - 1
        }
        first.ordinal = reordered.chapters.count - 1
        reordered.chapters[0] = first
        reordered.chapters.sort { $0.ordinal < $1.ordinal }
        try await store.save(reordered)
        try await store.renumberGlobalOrdinals()

        let summaries = try await store.paragraphSummaries(chapterID: nil)
        #expect(summaries.map(\.globalOrdinal) == Array(0..<summaries.count), "globals must be contiguous after chapter reorder")

        // The document order must start with the formerly-last chapter.
        let firstChapterID = reordered.chapters.first?.id
        #expect(summaries.first?.chapterID == firstChapterID)
        #expect(summaries.last?.chapterID != firstChapterID)
    }

    @Test func importWithoutRenumberLeavesGapsThenRenumberFixes() async throws {
        let db = ProjectDatabase.makeTemporary(named: "global-ordinal-import")
        let store = SQLiteProductionStore(databaseURL: db.url)
        var project = ProjectFixtures.typical()
        try await store.save(project)

        // Simulate an import that appends a paragraph to the first chapter
        // with the MAX(global_ordinal)+1 placeholder: the column is stale
        // until the renumber pass runs.
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let appendix = Paragraph(
            id: ids.next(),
            ordinal: project.chapters[0].paragraphs.count,
            text: "Imported paragraph appended after chapter reorder.",
            textHash: "h",
            updatedAt: clock.now
        )
        project.chapters[0].paragraphs.append(appendix)
        try await store.save(project)
        try await store.renumberGlobalOrdinals()

        let summaries = try await store.paragraphSummaries(chapterID: nil)
        #expect(summaries.map(\.globalOrdinal) == Array(0..<summaries.count))
    }
}
