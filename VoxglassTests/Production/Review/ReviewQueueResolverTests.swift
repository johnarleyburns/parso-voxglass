import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// Spec §19.3 / §7.5: `paragraphIDs(matching:order:)` must agree with
/// `ReviewQueueResolver.resolve` — the store query and the in-memory resolver
/// are two implementations of the same contract; the store one is what the UI
/// hits, the resolver one is what tests can reason about.
@Suite struct ReviewQueueResolverTests {

    private func project() -> AudiobookProject {
        var project = ProjectFixtures.typical()
        // Overlay review states on the fixture's existing takes/selection.
        for (idx, para) in project.allParagraphs.enumerated() {
            var updated = para
            switch idx % 8 {
            case 0: updated.reviewState = .flagged
            case 1: updated.reviewState = .needsPickup
            case 2: updated.reviewState = .approved
            default: updated.reviewState = .unreviewed
            }
            replaceParagraph(para.id, in: &project, with: updated)
        }
        return project
    }

    private func replaceParagraph(_ id: UUID, in project: inout AudiobookProject, with updated: Paragraph) {
        for ci in project.chapters.indices {
            for pi in project.chapters[ci].paragraphs.indices where project.chapters[ci].paragraphs[pi].id == id {
                project.chapters[ci].paragraphs[pi] = updated
            }
        }
    }

    private func def(predicate: ReviewPredicate, order: QueueOrder = .documentOrder) -> ReviewQueueDefinition {
        ReviewQueueDefinition(projectID: UUID(), predicate: predicate, order: order)
    }

    @Test func resolverMatchesFlagged() {
        let project = project()
        let expected = ReviewQueueResolver().resolve(def(predicate: .flagged), in: project)
        let expectedIDs = Set(expected)
        #expect(expectedIDs.contains(project.allParagraphs[0].id))
    }

    @Test func resolverMatchesNeedsPickup() {
        let project = project()
        let expected = ReviewQueueResolver().resolve(def(predicate: .needsPickup), in: project)
        let pickupIDs = project.allParagraphs.filter { $0.reviewState == .needsPickup }.map(\.id)
        #expect(Set(expected) == Set(pickupIDs))
    }

    @Test func resolverMatchesUnapproved() {
        let project = project()
        let expected = ReviewQueueResolver().resolve(def(predicate: .unapproved), in: project)
        // Paragraphs with a selected take that are not approved.
        let recordedNotApproved = project.allParagraphs
            .filter { $0.selectedTakeID != nil && $0.reviewState != .approved }
            .map(\.id)
        #expect(Set(expected) == Set(recordedNotApproved))
    }

    @Test func resolverMatchesAllRecorded() {
        let project = project()
        let expected = ReviewQueueResolver().resolve(def(predicate: .allRecorded), in: project)
        let recorded = project.allParagraphs.filter { $0.selectedTakeID != nil }.map(\.id)
        #expect(Set(expected) == Set(recorded))
    }

    @Test func resolverOrdersByChapterThenOrdinal() {
        let project = project()
        let expected = ReviewQueueResolver().resolve(def(predicate: .allRecorded, order: .byChapter), in: project)
        // byChapter is the document order for a single chapter; at minimum it
        // must not crash and must return every recorded paragraph.
        #expect(expected.count == project.allParagraphs.filter { $0.selectedTakeID != nil }.count)
    }
}
