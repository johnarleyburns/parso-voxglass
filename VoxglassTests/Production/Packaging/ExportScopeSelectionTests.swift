import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// §13.2 scope mapping: the four export choices must each resolve onto the
/// existing `ExportScope` cases (`ExportEndToEndTests.singleChapterScopeExportsOneFile`
/// proves the builder honors `.chapters`), so the app-level picker can thread a
/// real single-section export through `ExportOptions.scope`.
@Suite struct ExportScopeSelectionTests {

    @Test func wholeBookMapsToWholeBook() {
        let project = ProjectFixtures.librivoxReady()
        let scope = PackagingSupport.scope(
            for: .wholeBook,
            project: project,
            currentChapterID: project.chapters[1].id,
            selectedChapterIDs: [project.chapters[0].id]
        )
        #expect(scope == .wholeBook)
        #expect(PackagingSupport.chapters(in: project, scope: scope).count == 3)
    }

    @Test func currentChapterResolvesToChapterOfCurrentParagraph() {
        let project = ProjectFixtures.librivoxReady()
        let chapter = project.chapters[1]
        let scope = PackagingSupport.scope(
            for: .currentChapter,
            project: project,
            currentChapterID: chapter.id,
            selectedChapterIDs: []
        )
        #expect(scope == .chapters([chapter.id]))
        let resolved = PackagingSupport.chapters(in: project, scope: scope)
        #expect(resolved.count == 1)
        #expect(resolved[0].id == chapter.id)
    }

    @Test func currentChapterFallsBackToFirstChapterWhenNoCurrent() {
        let project = ProjectFixtures.librivoxReady()
        let scope = PackagingSupport.scope(
            for: .currentChapter,
            project: project,
            currentChapterID: nil,
            selectedChapterIDs: []
        )
        #expect(scope == .chapters([project.chapters[0].id]))
    }

    @Test func selectedChaptersKeepsOnlySelected() {
        let project = ProjectFixtures.librivoxReady()
        let selected: Set<UUID> = [project.chapters[0].id, project.chapters[2].id]
        let scope = PackagingSupport.scope(
            for: .selectedChapters,
            project: project,
            currentChapterID: nil,
            selectedChapterIDs: selected
        )
        guard case .chapters(let ids) = scope else {
            Issue.record("expected .chapters, got \(scope)")
            return
        }
        #expect(Set(ids) == selected)
    }

    @Test func reviewQueueResolvesToChaptersContainingFlaggedParagraphs() {
        var project = ProjectFixtures.librivoxReady()
        // Flag one paragraph in chapter 1 and one in chapter 2.
        project.chapters[0].paragraphs[0].reviewState = .flagged
        project.chapters[2].paragraphs[3].reviewState = .flagged

        let scope = PackagingSupport.scope(
            for: .reviewQueue,
            project: project,
            currentChapterID: nil,
            selectedChapterIDs: []
        )
        guard case .chapters(let ids) = scope else {
            Issue.record("expected .chapters, got \(scope)")
            return
        }
        #expect(Set(ids) == [project.chapters[0].id, project.chapters[2].id])
        #expect(!ids.contains(project.chapters[1].id))
    }

    @Test func reviewQueueWithNoFlaggedFallsBackToWholeBook() {
        let project = ProjectFixtures.librivoxReady()
        let scope = PackagingSupport.scope(
            for: .reviewQueue,
            project: project,
            currentChapterID: nil,
            selectedChapterIDs: []
        )
        #expect(scope == .wholeBook)
    }
}
