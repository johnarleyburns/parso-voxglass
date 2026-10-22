import Testing
import Foundation
@testable import VoxglassCore

@Suite struct FindSearchLifecycleTests {
    private func surface(_ l: FindSearchLifecycle, _ draft: String, collection: Bool = false,
                         searching: Bool = false, results: Bool = false) -> Bool {
        l.showsResultsSurface(draft: draft, hasSelectedCollection: collection, isSearching: searching, hasResults: results)
    }

    @Test func freshFindShowsInstructionalState() {
        let l = FindSearchLifecycle()
        #expect(!surface(l, ""))
    }

    @Test func unsubmittedDraftKeepsInstructionalState() {
        let l = FindSearchLifecycle()
        #expect(!surface(l, "mob"))
        #expect(!l.isCurrent(draft: "mob"))
        #expect(l.emptyState(draft: "mob") == .instructional)
    }

    @Test func submittedEmptyQueryShowsNoResultsOnlyAfterSubmit() {
        var l = FindSearchLifecycle()
        #expect(l.submit(draft: "  zzz ") == "zzz")
        #expect(surface(l, "zzz", searching: true))
        #expect(l.emptyState(draft: "zzz") == .noResults)
    }

    @Test func submittedResultsShowSurface() {
        var l = FindSearchLifecycle()
        l.submit(draft: "moby")
        #expect(surface(l, "moby", results: true))
    }

    @Test func editingAfterSubmitDoesNotAttributeEmptyResultToDraft() {
        var l = FindSearchLifecycle()
        l.submit(draft: "zzz")
        #expect(l.emptyState(draft: "zzzz") == .instructional)
        #expect(!surface(l, "zzzz"))
        #expect(!l.isCurrent(draft: "zzzz"))
    }

    @Test func scopeChangeRerunsOnlyForCurrentSubmission() {
        var l = FindSearchLifecycle()
        #expect(!l.isCurrent(draft: "moby"))
        l.submit(draft: "moby")
        #expect(l.isCurrent(draft: "moby"))
    }

    @Test func clearRestoresInstructionalState() {
        var l = FindSearchLifecycle()
        l.submit(draft: "zzz")
        l.reset()
        #expect(!surface(l, ""))
        #expect(!surface(l, "zzz"))
        #expect(l.emptyState(draft: "zzz") == .instructional)
        #expect(l.submit(draft: "   ") == nil)
    }

    @Test func collectionBrowseKeepsNoBooksAndNeverSaysNoResultsForDraft() {
        var l = FindSearchLifecycle()
        #expect(surface(l, "", collection: true))
        #expect(l.emptyState(draft: "") == .noBooks)
        #expect(l.emptyState(draft: "ab") == .instructional)
        l.submit(draft: "ab")
        #expect(l.emptyState(draft: "ab") == .noResults)
    }
}
